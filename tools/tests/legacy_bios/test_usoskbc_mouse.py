"""USOSKBC.COM /M (USB mouse for the PS/2 path of MOUSE.DRV in Windows 2.x
and 3.0) in Unicorn, without Microsoft files: the install, the INT 15h C207h
trampoline (the caller's handler gets the BIOS packet words; the caller keeps
ES:BX and gets the BIOS's CF/AH), the software INT 74h after a packet that
the BIOS delivered from its timer interrupt (as SeaBIOS under CSMWrap does
for a USB mouse) into a driver that dispatches from its own INT 74h handler
after chaining the previous one (the MOUSE.DRV pattern, rebuilt here from
its described behaviour), and a real IRQ 12 still reaching the BIOS."""
from pathlib import Path
import struct
import sys
import unittest
from unicorn import Uc, UcError, UC_ARCH_X86, UC_MODE_16, UC_HOOK_INTR, UC_HOOK_INSN
from unicorn.x86_const import *

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))
sys.path.insert(0, str(ROOT / 'tools/tests'))
import depguard
from build_win3_usb_keyboard import build_kbc, elf_symbols

TSR = 0x1000          # PSP of USOSKBC (COM image at TSR:0100)
BIOS = 0xF000
DRV = 0x2000          # the Windows mouse driver stand-in
APP = 0x3000          # small programs that issue the calls
STACK = 0x5000
REGS = dict(ax=UC_X86_REG_AX, bx=UC_X86_REG_BX, cx=UC_X86_REG_CX, dx=UC_X86_REG_DX,
            si=UC_X86_REG_SI, di=UC_X86_REG_DI, bp=UC_X86_REG_BP, sp=UC_X86_REG_SP,
            ds=UC_X86_REG_DS, es=UC_X86_REG_ES, ss=UC_X86_REG_SS, cs=UC_X86_REG_CS,
            ip=UC_X86_REG_IP, fl=UC_X86_REG_EFLAGS)

# BIOS stand-ins. Magic INTs F0h-FFh are handled in Python (not delivered).
BIOS15 = bytes([0xcd, 0xf5, 0xcf])                      # int F5h; iret
BIOS08 = bytes([0x50, 0x53, 0x51, 0x52,                 # push ax, bx, cx, dx
                0xcd, 0xf8,                             # int F8h: packet? -> DX=1, AX/BX/CX
                0x85, 0xd2, 0x74, 0x0f,                 # test dx,dx; jz +15
                0x50, 0x53, 0x51, 0x6a, 0x00,           # push status, X, Y, 0
                0xfb,                                   # sti (as SeaBIOS)
                0x2e, 0xff, 0x1e, 0x00, 0x03,           # call far cs:[0300h]
                0x83, 0xc4, 0x08, 0xfa,                 # add sp,8; cli
                0x5a, 0x59, 0x5b, 0x58, 0xcf])          # pop dx, cx, bx, ax; iret
BIOS74 = bytes([0xcd, 0xf4, 0xcf])                      # int F4h (count); iret
FCP = 0x0300                                            # BIOS far call pointer

# Driver stand-in: C207h callback stores the packet and a flag; its INT 74h
# handler chains the previous vector first, then dispatches (int F7h).
DRV_CB = bytes([0x55, 0x89, 0xe5, 0x50,                 # push bp; mov bp,sp; push ax
                0x8b, 0x46, 0x0a, 0x2e, 0xa3, 0x10, 0x00,   # X -> cs:0010
                0x8b, 0x46, 0x08, 0x2e, 0xa3, 0x12, 0x00,   # Y -> cs:0012
                0x8b, 0x46, 0x0c, 0x2e, 0xa3, 0x14, 0x00,   # status -> cs:0014
                0x2e, 0xc6, 0x06, 0x16, 0x00, 0xff,         # flag
                0x58, 0x5d, 0xcb])                          # pop ax; pop bp; retf
DRV_74 = bytes([0x9c, 0x2e, 0xff, 0x1e, 0x20, 0x00,     # pushf; call far cs:[0020h]
                0x2e, 0xf6, 0x06, 0x16, 0x00, 0xff,     # test byte cs:[0016h],FFh
                0x74, 0x08,                             # jz iret
                0x2e, 0xc6, 0x06, 0x16, 0x00, 0x00,     # flag off
                0xcd, 0xf7,                             # int F7h: event to "Windows"
                0xcf])                                  # iret

C207 = lambda es, bx: bytes([0xb8, 0x07, 0xc2, 0xbb]) + struct.pack('<H', es) + bytes([
    0x8e, 0xc3, 0xbb]) + struct.pack('<H', bx) + bytes([0xcd, 0x15, 0xcd, 0xff])


class Machine:
    def __init__(self, com, sym):
        self.u = Uc(UC_ARCH_X86, UC_MODE_16)
        self.u.mem_map(0, 0x110000)
        self.com, self.sym = com, sym
        self.u.mem_write(BIOS * 16 + 0x100, BIOS15)
        self.u.mem_write(BIOS * 16 + 0x200, BIOS08)
        self.u.mem_write(BIOS * 16 + 0x400, BIOS74)
        for n, off in ((0x15, 0x100), (0x08, 0x200), (0x74, 0x400), (0x09, 0x500), (0x2f, 0x500)):
            self.set_ivt(n, BIOS, off)
        self.u.mem_write(BIOS * 16 + 0x500, b'\xcf')
        self.u.mem_write(DRV * 16 + 0x100, DRV_CB)
        self.u.mem_write(DRV * 16 + 0x200, DRV_74)
        self.packets, self.events, self.bios74, self.out = [], [], 0, b''
        self.bios_cf = None
        self.resident = False

        def port_in(uc, port, size, data):
            return 0xff                     # no 8042 (port 64h reads FFh)

        def port_out(uc, port, size, value, data):
            pass
        self.u.hook_add(UC_HOOK_INSN, port_in, None, 1, 0, UC_X86_INS_IN)
        self.u.hook_add(UC_HOOK_INSN, port_out, None, 1, 0, UC_X86_INS_OUT)

    def r(self, n):
        return self.u.reg_read(REGS[n])

    def w(self, n, v):
        self.u.reg_write(REGS[n], v & 0xffff)

    def set_ivt(self, n, seg, off):
        self.u.mem_write(n * 4, struct.pack('<HH', off, seg))

    def ivt(self, n):
        off, seg = struct.unpack('<HH', self.u.mem_read(n * 4, 4))
        return seg, off

    def word(self, seg, off):
        return struct.unpack('<H', self.u.mem_read(seg * 16 + off, 2))[0]

    def shared(self, name, size=2):
        raw = self.u.mem_read(TSR * 16 + self.sym[name], size)
        return int.from_bytes(raw, 'little')

    def deliver(self, n):
        sp = (self.r('sp') - 6) & 0xffff
        fl = self.r('fl') & 0xffff
        self.u.mem_write(self.r('ss') * 16 + sp, struct.pack('<HHH', self.r('ip'), self.r('cs'), fl))
        self.w('sp', sp)
        self.w('fl', fl & ~0x300)
        seg, off = self.ivt(n)
        self.w('cs', seg)
        self.w('ip', off)

    def dos(self):
        ah, al = self.r('ax') >> 8, self.r('ax') & 0xff
        if ah == 0x35:
            seg, off = self.ivt(al)
            self.w('es', seg)
            self.w('bx', off)
        elif ah == 0x25:
            self.set_ivt(al, self.r('ds'), self.r('dx'))
        elif ah == 0x09:
            lin = self.r('ds') * 16 + self.r('dx')
            raw = bytes(self.u.mem_read(lin, 200))
            self.out += raw[:raw.index(b'$')]
        elif ah == 0x49:
            self.w('fl', self.r('fl') & ~1)
        elif ah == 0x31:
            self.resident = True
            return 'tsr'
        elif ah == 0x4c:
            return 'exit'
        else:
            raise AssertionError('INT 21h AH=%02Xh' % ah)
        return None

    def magic(self, n):
        if n == 0xf5:                       # BIOS INT 15h
            ax = self.r('ax')
            fl_lin = self.r('ss') * 16 + ((self.r('sp') + 4) & 0xffff)
            fl, = struct.unpack('<H', self.u.mem_read(fl_lin, 2))
            if ax == 0xc207:
                if self.bios_cf:
                    self.w('ax', (self.bios_cf << 8) | (ax & 0xff))
                    fl |= 1
                else:
                    self.u.mem_write(BIOS * 16 + FCP, struct.pack('<HH', self.r('bx'), self.r('es')))
                    self.w('ax', ax & 0xff)
                    fl &= ~1
            self.u.mem_write(fl_lin, struct.pack('<H', fl))
        elif n == 0xf8:                     # BIOS timer: USB mouse packet due?
            if self.packets and self.word(BIOS, FCP + 2):
                status, x, y = self.packets.pop(0)
                self.w('ax', status)
                self.w('bx', x)
                self.w('cx', y)
                self.w('dx', 1)
            else:
                self.w('dx', 0)
        elif n == 0xf4:
            self.bios74 += 1
        elif n == 0xf7:
            self.events.append((self.word(DRV, 0x10), self.word(DRV, 0x12), self.word(DRV, 0x14)))
        elif n == 0xff:
            return 'done'
        return None

    def run(self, seg, off, limit=200000):
        self.w('cs', seg)
        self.w('ip', off)
        stop = []

        def intr(uc, n, data):
            stop.append(n)
            uc.emu_stop()
        h = self.u.hook_add(UC_HOOK_INTR, intr)
        try:
            steps = 0
            while steps < limit:
                stop.clear()
                lin = self.r('cs') * 16 + self.r('ip')
                try:
                    self.u.emu_start(lin, 0x10ffff, count=500)
                except UcError as e:
                    return 'error %s at %04x:%04x' % (e, self.r('cs'), self.r('ip'))
                steps += 500
                if not stop:
                    continue
                n = stop[0]
                if n >= 0xf0:
                    res = self.magic(n)
                elif n == 0x21:
                    res = self.dos()
                elif n == 0x2f and not self.resident:
                    self.w('ax', self.r('ax') & 0xff00)
                    res = None
                else:
                    self.deliver(n)
                    res = None
                if res:
                    return res
            return 'limit'
        finally:
            self.u.hook_del(h)

    def install(self, tail):
        psp = TSR * 16
        self.u.mem_write(psp, b'\xcd\x20' + bytes(0x7e))
        self.u.mem_write(psp + 0x2c, struct.pack('<H', 0x0f00))
        args = (' ' + tail).encode() + b'\r'
        self.u.mem_write(psp + 0x80, bytes([len(args) - 1]) + args)
        self.u.mem_write(psp + 0x100, self.com)
        for n in ('ds', 'es', 'ss'):
            self.w(n, TSR)
        self.w('sp', 0xfffe)
        return self.run(TSR, 0x100)

    def call(self, code):
        self.u.mem_write(APP * 16, code)
        # Unicorn keeps translated blocks across mem_write: drop the old ones
        self.u.ctl_remove_cache(APP * 16, APP * 16 + 0x1000)
        self.w('ss', STACK)
        self.w('sp', 0x1000)
        self.w('ds', APP)
        self.w('fl', 0x202)
        return self.run(APP, 0)

    def driver_hooks_74(self):
        seg, off = self.ivt(0x74)
        self.u.mem_write(DRV * 16 + 0x20, struct.pack('<HH', off, seg))
        self.set_ivt(0x74, DRV, 0x200)


class UsosKbcMouse(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        depguard.require_zig()
        out = ROOT / 'zig-out/usoskbc-mouse-test'
        out.mkdir(parents=True, exist_ok=True)
        cls.com = build_kbc(out, out).read_bytes()
        cls.sym = elf_symbols(out / 'usoskbc.elf')

    def machine(self, tail='/M'):
        m = Machine(self.com, self.sym)
        self.assertEqual(m.install(tail), 'tsr', m.out)
        return m

    def test_install(self):
        m = self.machine('/R /M')
        self.assertIn(b'USB mouse for MOUSE.DRV', m.out)
        self.assertEqual(m.ivt(0x74), (TSR, self.sym['int74']))
        self.assertEqual(m.ivt(0x15), (TSR, self.sym['int15']))
        self.assertEqual(m.ivt(0x08), (TSR, self.sym['int08']))
        self.assertEqual(m.shared('old74', 4), (BIOS << 16) | 0x400)
        self.assertEqual(m.shared('shared', 4).to_bytes(4, 'little'), b'UKBC')
        self.assertEqual(m.word(TSR, self.sym['shared'] + 4), 2)     # version
        self.assertEqual(m.shared('kflags', 1) & 8, 8)
        self.assertEqual(m.shared('kflags', 1) & 1, 0)               # no 8042: no relay

    def test_without_m_nothing_changes(self):
        m = self.machine('/R')
        self.assertNotIn(b'mouse', m.out)
        self.assertEqual(m.ivt(0x74), (BIOS, 0x400))
        self.assertEqual(m.call(C207(DRV, 0x100)), 'done')
        self.assertEqual(m.word(BIOS, FCP), 0x100)                   # straight through
        self.assertEqual(m.word(BIOS, FCP + 2), DRV)

    def test_c207_trampoline(self):
        m = self.machine()
        self.assertEqual(m.call(C207(DRV, 0x100)), 'done')
        self.assertEqual((m.word(BIOS, FCP + 2), m.word(BIOS, FCP)), (TSR, self.sym['mtramp']))
        self.assertEqual(m.shared('mcb', 4), (DRV << 16) | 0x100)
        self.assertEqual((m.r('es'), m.r('bx')), (DRV, 0x100))       # caller's ES:BX kept
        self.assertEqual(m.r('fl') & 1, 0)
        self.assertEqual(m.r('ax') >> 8, 0)

    def test_c207_error_passed_back(self):
        m = self.machine()
        m.bios_cf = 0x04
        self.assertEqual(m.call(C207(DRV, 0x100)), 'done')
        self.assertEqual(m.r('fl') & 1, 1)
        self.assertEqual(m.r('ax') >> 8, 0x04)
        self.assertEqual((m.r('es'), m.r('bx')), (DRV, 0x100))

    def test_c207_remove_goes_through(self):
        m = self.machine()
        self.assertEqual(m.call(C207(DRV, 0x100)), 'done')
        self.assertEqual(m.call(C207(0, 0)), 'done')
        self.assertEqual((m.word(BIOS, FCP + 2), m.word(BIOS, FCP)), (0, 0))

    def test_timer_packet_reaches_driver_through_int74(self):
        m = self.machine()
        self.assertEqual(m.call(C207(DRV, 0x100)), 'done')
        m.driver_hooks_74()
        m.packets.append((0x09, 0x0005, 0x00fd))
        self.assertEqual(m.call(b'\xcd\x08\xcd\xff'), 'done')
        self.assertEqual(m.events, [(0x0005, 0x00fd, 0x09)])
        self.assertEqual(m.bios74, 0)                  # software INT 74h stops at our stub
        self.assertEqual(m.shared('mpackets', 4), 1)
        self.assertEqual(m.shared('mkicks', 4), 1)
        self.assertEqual(m.shared('msoft', 1), 0)
        # a tick without a packet: no INT 74h
        self.assertEqual(m.call(b'\xcd\x08\xcd\xff'), 'done')
        self.assertEqual(len(m.events), 1)
        self.assertEqual(m.shared('mkicks', 4), 1)
        # two more packets on two ticks: two events in order
        m.packets += [(0x08, 0x0001, 0x0000), (0x19, 0x00fe, 0x0002)]
        self.assertEqual(m.call(b'\xcd\x08\xcd\x08\xcd\xff'), 'done')
        self.assertEqual(m.events[1:], [(1, 0, 0x08), (0xfe, 2, 0x19)])
        self.assertEqual(m.shared('mkicks', 4), 3)

    def test_no_int74_hook_no_kick(self):
        m = self.machine()
        self.assertEqual(m.call(C207(DRV, 0x100)), 'done')
        m.packets.append((0x08, 3, 4))
        self.assertEqual(m.call(b'\xcd\x08\xcd\xff'), 'done')
        self.assertEqual(m.word(DRV, 0x10), 3)        # callback ran
        self.assertEqual(m.events, [])
        self.assertEqual(m.shared('mkicks', 4), 0)
        self.assertEqual(m.shared('mpackets', 4), 1)

    def test_real_irq12_reaches_bios(self):
        m = self.machine()
        m.driver_hooks_74()
        self.assertEqual(m.call(b'\xcd\x74\xcd\xff'), 'done')
        self.assertEqual(m.bios74, 1)
        self.assertEqual(m.events, [])


if __name__ == '__main__':
    unittest.main()
