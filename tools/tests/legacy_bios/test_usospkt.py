"""USOSPKT.COM (own DOS packet driver for Intel igb NICs) in Unicorn: the
resident packet-driver interface (Packet Driver Specification 1.11 class 1)
against a register file behind the IOADDR/IODATA window - driver_info,
access_type / release_type, get_address, send_pkt (TX descriptor and TDT),
the receive upcalls from the timer poll (AX=0 buffer request, copy, AX=1),
receive modes and error codes. The hardware bring-up (reset, PHY, PLL) is
covered by the QEMU runs in docs/dos-usospkt-2026-10-23.md, not here."""
from pathlib import Path
import struct
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))
sys.path.insert(0, str(ROOT / 'tools/tests'))
import depguard

try:
    from unicorn import Uc, UC_ARCH_X86, UC_MODE_16, UC_HOOK_INSN
    from unicorn.x86_const import *
except ImportError:                                   # pragma: no cover
    Uc = None

TSR = 0x1000          # resident segment (PSP)
APP = 0x3000          # caller: INT stub at 0, receiver at 0100h, buffer 0400h
STUB = 0xF000         # old INT 08h = IRET at F000:0000
IOBASE = 0xC000
TDT0, RDT0, RCTL = 0xE018, 0xC018, 0x0100
MAC = bytes.fromhex('525400123456')
REGS = dict(ax=UC_X86_REG_AX, bx=UC_X86_REG_BX, cx=UC_X86_REG_CX, dx=UC_X86_REG_DX,
            si=UC_X86_REG_SI, di=UC_X86_REG_DI, sp=UC_X86_REG_SP, ds=UC_X86_REG_DS,
            es=UC_X86_REG_ES, ss=UC_X86_REG_SS, fl=UC_X86_REG_EFLAGS) if Uc else {}

# receiver: AX=0 -> ES:DI = APP:0400 (length to [0300]); AX=1 -> DS:SI to
# [0302]/[0304], count in [0306]
RECEIVER = bytes([0x3D, 0x00, 0x00, 0x75, 0x0B, 0xBF, 0x00, 0x04, 0x0E, 0x07,
                  0x2E, 0x89, 0x0E, 0x00, 0x03, 0xCB,
                  0x2E, 0x89, 0x36, 0x02, 0x03, 0x2E, 0x8C, 0x1E, 0x04, 0x03,
                  0x2E, 0xFE, 0x06, 0x06, 0x03, 0xCB])
# a receiver that refuses every frame (ES:DI = 0:0)
REFUSER = bytes([0x31, 0xFF, 0x8E, 0xC7, 0xCB])      # xor di,di; mov es,di; retf


class Built:
    com = sym = None


def build():
    if Built.com is None:
        depguard.require_zig()
        from build_dos_network import build_usospkt
        from build_win3_usb_keyboard import elf_symbols
        tmp = Path(tempfile.mkdtemp(prefix='usospkt-'))
        com = build_usospkt(ROOT, tmp, tmp)
        Built.com, Built.sym = com.read_bytes(), elf_symbols(tmp / 'usospkt.elf')
    return Built.com, Built.sym


class Machine:
    def __init__(self, tx_done=True):
        com, self.s = build()
        self.u = Uc(UC_ARCH_X86, UC_MODE_16)
        self.u.mem_map(0, 0x110000)
        self.u.mem_write(TSR * 16 + 0x100, com)
        self.u.mem_write(APP * 16, b'\xcd\x60\xf4\xcd\x08\xf4')   # int 60h / int 08h
        self.u.mem_write(APP * 16 + 0x100, RECEIVER)
        self.u.mem_write(APP * 16 + 0x200, REFUSER)
        self.u.mem_write(STUB * 16, b'\xcf')
        lin = TSR * 16
        self.area = ((lin + self.s['image_end'] + 127) & ~127) - lin
        self.phys = lin + self.area
        self.poke('acc', b'\x01')
        self.poke('irq', b'\xff')
        self.poke('iobase', struct.pack('<H', IOBASE))
        self.poke('area', struct.pack('<H', self.area))
        self.poke('phys', struct.pack('<I', self.phys))
        self.poke('mac', MAC)
        self.poke('old08', struct.pack('<HH', 0, STUB))
        self.ivt(0x60, TSR, self.s['pkt_entry'])
        self.ivt(0x08, TSR, self.s['int08'])
        for i in range(16):                       # RX descriptors as nic_start leaves them
            self.u.mem_write(self.phys + i * 16, struct.pack('<IIII', self.phys + 2048 + i * 2048, 0, 0, 0))
        self.regs, self.ioaddr, self.tdh, self.sent, self.tx_done = {RCTL: 0x04008002}, 0, 0, [], tx_done
        self.u.hook_add(UC_HOOK_INSN, self.port_in, None, 1, 0, UC_X86_INS_IN)
        self.u.hook_add(UC_HOOK_INSN, self.port_out, None, 1, 0, UC_X86_INS_OUT)

    def poke(self, name, data):
        self.u.mem_write(TSR * 16 + self.s[name], data)

    def peek(self, name, n):
        return bytes(self.u.mem_read(TSR * 16 + self.s[name], n))

    def ivt(self, n, seg, off):
        self.u.mem_write(n * 4, struct.pack('<HH', off, seg))

    def port_in(self, uc, port, size, user):
        if port == IOBASE + 4:
            return self.regs.get(self.ioaddr, 0)
        return 0

    def port_out(self, uc, port, size, value, user):
        if port == IOBASE:
            self.ioaddr = value
        elif port == IOBASE + 4:
            self.regs[self.ioaddr] = value
            if self.ioaddr == TDT0:
                while self.tdh != value:
                    d = self.phys + 256 + self.tdh * 16
                    addr, _, cmd, pay = struct.unpack('<IIII', self.u.mem_read(d, 16))
                    self.sent.append((cmd, pay, bytes(self.u.mem_read(addr, cmd & 0xFFFF))))
                    if self.tx_done:
                        self.u.mem_write(d + 12, struct.pack('<I', pay | 1))
                    self.tdh = (self.tdh + 1) % 8

    def call(self, vector=0x60, **r):
        u = self.u
        for k in ('ax', 'bx', 'cx', 'dx', 'si', 'di'):
            u.reg_write(REGS[k], r.get(k, 0))
        u.reg_write(REGS['ds'], r.get('ds', APP))
        u.reg_write(REGS['es'], r.get('es', APP))
        # the INT as real mode does it: FLAGS, CS, IP (APP:0002 = HLT) pushed,
        # CS:IP from the vector; runs until the handler's IRET lands there
        u.reg_write(REGS['ss'], APP)
        u.reg_write(REGS['sp'], 0xFFF0 - 6)
        u.mem_write(APP * 16 + 0xFFF0 - 6, struct.pack('<HHH', 2, APP, 0x202))
        u.reg_write(REGS['fl'], 0x002)
        off, seg = struct.unpack('<HH', u.mem_read(vector * 4, 4))
        u.reg_write(UC_X86_REG_CS, seg)
        u.reg_write(UC_X86_REG_IP, off)
        u.emu_start(seg * 16 + off, APP * 16 + 2, count=2_000_000)
        out = {k: u.reg_read(v) for k, v in REGS.items()}
        out['cf'] = out['fl'] & 1
        out['dh'] = out['dx'] >> 8
        return out

    def mem(self, seg, off, n):
        return bytes(self.u.mem_read(seg * 16 + off, n))

    def put(self, seg, off, data):
        self.u.mem_write(seg * 16 + off, data)

    def access(self, ethertype, receiver=0x100):
        self.put(APP, 0x500, ethertype)
        return self.call(ax=0x0201, bx=0xFFFF, cx=len(ethertype), dx=0, si=0x500, es=APP, di=receiver)

    def rx_frame(self, index, frame, status=0x3):
        self.u.mem_write(self.phys + 2048 + index * 2048, frame)
        self.u.mem_write(self.phys + index * 16 + 8, struct.pack('<II', status, len(frame)))


@unittest.skipIf(Uc is None, 'unicorn missing')
class UsospktTest(unittest.TestCase):
    def setUp(self):
        self.m = Machine()

    def test_layout(self):
        from build_dos_network import check_usospkt
        com, sym = build()
        check_usospkt(com)
        entry = sym['pkt_entry'] - 0x100
        self.assertEqual(com[entry], 0xE9)
        self.assertEqual(com[entry + 3:entry + 12], b'PKT DRVR\0')
        # the resident part (stack included) ends before the install code
        self.assertLess(sym['resident_end'], sym['install'])

    def test_driver_info(self):
        r = self.m.call(ax=0x01FF)
        self.assertEqual(r['cf'], 0)
        self.assertEqual((r['bx'], r['cx'] >> 8, r['dx'], r['ax'] & 0xFF), (1, 1, 0x5553, 1))
        self.assertEqual(self.m.mem(r['ds'], r['si'], 12), b'USOSPKT igb\0')

    def test_access_and_errors(self):
        ip = self.m.access(b'\x08\x00')
        arp = self.m.access(b'\x08\x06')
        self.assertEqual((ip['cf'], ip['ax'], arp['cf'], arp['ax']), (0, 1, 0, 2))
        dup = self.m.access(b'\x08\x00')
        self.assertEqual((dup['cf'], dup['dh']), (1, 10))                 # TYPE_INUSE
        self.m.put(APP, 0x500, b'\x08\x00')
        r = self.m.call(ax=0x0202, bx=0xFFFF, cx=2, si=0x500, di=0x100)
        self.assertEqual((r['cf'], r['dh']), (1, 2))                      # NO_CLASS
        r = self.m.call(ax=0x0201, bx=0xFFFF, cx=9, si=0x500, di=0x100)
        self.assertEqual((r['cf'], r['dh']), (1, 5))                      # BAD_TYPE
        r = self.m.call(ax=0x0201, bx=0x1234, cx=2, si=0x500, di=0x100)
        self.assertEqual((r['cf'], r['dh']), (1, 3))                      # NO_TYPE
        self.assertEqual(self.m.call(ax=0x0300, bx=1)['cf'], 0)           # release
        r = self.m.call(ax=0x0300, bx=1)
        self.assertEqual((r['cf'], r['dh']), (1, 1))                      # BAD_HANDLE
        r = self.m.call(ax=0x0500, bx=2)
        self.assertEqual((r['cf'], r['dh']), (1, 7))                      # CANT_TERMINATE
        r = self.m.call(ax=0x1E00)
        self.assertEqual((r['cf'], r['dh']), (1, 11))                     # BAD_COMMAND
        for i in range(4):                                             # all four slots free again
            self.assertEqual(self.m.access(bytes([i, 1]))['cf'], 0)
        r = self.m.access(b'\x99\x99')
        self.assertEqual((r['cf'], r['dh']), (1, 9))                      # NO_SPACE

    def test_get_address(self):
        r = self.m.call(ax=0x0600, bx=1, cx=6, es=APP, di=0x600)
        self.assertEqual((r['cf'], r['cx']), (0, 6))
        self.assertEqual(self.m.mem(APP, 0x600, 6), MAC)
        r = self.m.call(ax=0x0600, bx=1, cx=4, es=APP, di=0x600)
        self.assertEqual((r['cf'], r['dh']), (1, 9))

    def test_send(self):
        frame = bytes(range(60))
        self.m.put(APP, 0x800, frame)
        r = self.m.call(ax=0x0400, cx=60, si=0x800)
        self.assertEqual(r['cf'], 0)
        self.assertEqual(self.m.regs[TDT0], 1)
        cmd, pay, data = self.m.sent[0]
        self.assertEqual(data, frame)
        self.assertEqual(cmd, 60 | 0x2B300000)                         # DEXT RS IFCS EOP, data
        self.assertEqual(pay >> 14, 60)
        stats = struct.unpack('<7I', self.m.peek('stats', 28))
        self.assertEqual(stats[1], 1)
        self.assertEqual(stats[3], 60)
        r = self.m.call(ax=0x0400, cx=1515, si=0x800)
        self.assertEqual((r['cf'], r['dh']), (1, 12))
        for i in range(9):                                             # ring wraps (8)
            self.assertEqual(self.m.call(ax=0x0400, cx=60, si=0x800)['cf'], 0)
        self.assertEqual(self.m.regs[TDT0], 10 % 8)

    def test_send_timeout(self):
        m = Machine(tx_done=False)
        m.put(APP, 0x800, bytes(64))
        r = m.call(ax=0x0400, cx=64, si=0x800)
        self.assertEqual((r['cf'], r['dh']), (1, 12))
        self.assertEqual(struct.unpack('<7I', m.peek('stats', 28))[5], 1)

    def test_receive_upcall(self):
        self.assertEqual(self.m.access(b'\x08\x06')['ax'], 1)
        self.assertEqual(self.m.access(b'\x08\x00')['ax'], 2)
        frame = MAC + bytes(6) + b'\x08\x00' + bytes(range(100))
        self.m.rx_frame(0, frame)
        other = MAC + bytes(6) + b'\x86\xdd' + bytes(50)               # IPv6: nobody
        self.m.rx_frame(1, other)
        r = self.m.call(vector=0x08)
        self.assertEqual(r['ss'], APP)                                 # stack restored
        self.assertEqual(r['sp'], 0xFFF0)
        self.assertEqual(self.m.mem(APP, 0x300, 2), struct.pack('<H', len(frame)))
        self.assertEqual(self.m.mem(APP, 0x400, len(frame)), frame)
        self.assertEqual(self.m.mem(APP, 0x302, 4), struct.pack('<HH', 0x400, APP))
        self.assertEqual(self.m.mem(APP, 0x306, 1), b'\x01')
        self.assertEqual(self.m.regs[RDT0], 1)                         # both given back
        d0 = struct.unpack('<IIII', self.m.u.mem_read(self.m.phys, 16))
        self.assertEqual(d0, (self.m.phys + 2048, 0, 0, 0))
        stats = struct.unpack('<7I', self.m.peek('stats', 28))
        self.assertEqual((stats[0], stats[2], stats[6]), (1, len(frame), 1))
        self.assertEqual(struct.unpack('<H', self.m.peek('rx_next', 2))[0], 2)

    def test_receive_errors_and_refusal(self):
        self.m.access(b'\x08\x00', receiver=0x200)                     # refuses
        self.m.rx_frame(0, MAC + bytes(6) + b'\x08\x00' + bytes(40))
        self.m.rx_frame(1, MAC + bytes(6) + b'\x08\x00' + bytes(40), status=0x01000003)  # CRC error
        self.m.rx_frame(2, MAC + bytes(6) + b'\x08\x00' + bytes(40), status=0x1)         # no EOP
        self.m.call(vector=0x08)
        stats = struct.unpack('<7I', self.m.peek('stats', 28))
        self.assertEqual((stats[0], stats[4], stats[6]), (0, 2, 1))
        self.assertEqual(self.m.regs[RDT0], 2)

    def test_busy_guard(self):
        self.m.access(b'\x08\x00')
        self.m.rx_frame(0, MAC + bytes(6) + b'\x08\x00' + bytes(40))
        self.m.poke('busy', b'\x01')                                   # poll already running
        self.m.call(vector=0x08)
        self.assertEqual(self.m.mem(APP, 0x306, 1), b'\x00')
        self.assertNotIn(RDT0, self.m.regs)

    def test_receive_modes(self):
        r = self.m.call(ax=0x1400, bx=1, cx=6)
        self.assertEqual(r['cf'], 0)
        self.assertEqual(self.m.regs[RCTL] & 0x801A, 0x801A)           # EN UPE MPE BAM
        self.assertEqual(self.m.call(ax=0x1500, bx=1)['ax'], 6)
        self.m.call(ax=0x1400, bx=1, cx=2)
        self.assertEqual(self.m.regs[RCTL] & 0x801A, 0x0002)
        self.m.call(ax=0x1400, bx=1, cx=1)
        self.assertEqual(self.m.regs[RCTL] & 0x801A, 0)
        r = self.m.call(ax=0x1400, bx=1, cx=7)
        self.assertEqual((r['cf'], r['dh']), (1, 8))
        self.assertTrue(self.m.regs[RCTL] & 0x04000000)                # SECRC kept

    def test_statistics_pointer(self):
        r = self.m.call(ax=0x1800, bx=1)
        self.assertEqual((r['cf'], r['ds'], r['si']), (0, TSR, self.m.s['stats']))


if __name__ == '__main__':
    unittest.main()
