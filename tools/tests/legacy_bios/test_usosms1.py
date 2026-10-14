"""USOSMS1.DRV (Windows 1.0x mouse driver on the BIOS pointing device,
src/platform/win1/usosms1.S) in Unicorn, without Microsoft files: the NE
file shape Setup's binder expects (as NOMOUSE.DRV: module MOUSE, one fixed
segment, no relocations, ordinals 1-3), Inquire (14-byte MOUSEINFO, mouse
present only when INT 15h C205h succeeds), Enable (C205h/C207h/C200h, INT 08h
and 74h hooked), packets the BIOS hands to the C207h handler from its timer
(as SeaBIOS under CSMWrap does for a USB mouse) reaching USER's event
procedure with the register interface of the shipped 1.0x drivers (AX flags,
BX/CX movement with Y down positive, DX buttons), the software INT 74h of
USOSKBC /M, and Disable restoring the vectors.

USOSMS1_DRV=<file> tests a prebuilt driver; otherwise it is built."""
from pathlib import Path
import os
import struct
import sys
import tempfile
import unittest
from unicorn import Uc, UC_ARCH_X86, UC_MODE_16, UC_HOOK_INTR
from unicorn.x86_const import *

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))

BIOS = 0xF000
DRV = 0x2000
APP = 0x3000
USER = 0x4000
STACK = 0x5000
INFO = 0x0800           # APP:0800 MOUSEINFO buffer
FCP = 0x0300            # BIOS:0300 far pointer to the C207h handler

# BIOS INT 08h: int F8h (Python: packet pending? -> DX=1, AX status, BX X,
# CX Y), then the C207h far call with status, X, Y, 0 on the stack.
BIOS08 = bytes([0x50, 0x53, 0x51, 0x52, 0xcd, 0xf8, 0x85, 0xd2, 0x74, 0x0f,
                0x50, 0x53, 0x51, 0x6a, 0x00, 0xfb, 0x2e, 0xff, 0x1e, 0x00, 0x03,
                0x83, 0xc4, 0x08, 0xfa, 0x5a, 0x59, 0x5b, 0x58, 0xcf])


def driver_file() -> bytes:
    pre = os.environ.get('USOSMS1_DRV')
    if pre:
        return Path(pre).read_bytes()
    from build_win3_usb_keyboard import build_win1_mouse
    work = Path(tempfile.mkdtemp(prefix='usosms1-'))
    return build_win1_mouse(work, work).read_bytes()


def parse_ne(data: bytes):
    ne = struct.unpack_from('<H', data, 0x3c)[0]
    assert data[ne:ne + 2] == b'NE'
    enttab, = struct.unpack_from('<H', data, ne + 4)
    nseg, nmod = struct.unpack_from('<HH', data, ne + 0x1c)
    segtab, _, restab = struct.unpack_from('<HHH', data, ne + 0x22)
    align, = struct.unpack_from('<H', data, ne + 0x32)
    off, ln, fl, mn = struct.unpack_from('<HHHH', data, ne + segtab)
    name = data[ne + restab + 1:ne + restab + 1 + data[ne + restab]]
    p = ne + enttab
    count, seg = data[p], data[p + 1]
    entries = [struct.unpack_from('<BH', data, p + 2 + 3 * i) for i in range(count)]
    return dict(ver=data[ne + 2], flags=struct.unpack_from('<H', data, ne + 0xc)[0], nseg=nseg, nmod=nmod,
                seg_flags=fl, name=name, seg=seg, entries=entries,
                code=data[off << align:(off << align) + ln])


class Machine:
    def __init__(self, ne, bios_mouse=True, divisor=1):
        self.u = Uc(UC_ARCH_X86, UC_MODE_16)
        self.u.mem_map(0, 0x110000)
        self.ne = ne
        self.bios_mouse = bios_mouse
        self.calls15, self.events, self.pending = [], [], []
        self.bios74 = 0
        self.u.mem_write(DRV * 16, ne['code'])
        # the movement divisor follows the "USM1" signature and its version
        self.u.mem_write(DRV * 16 + ne['code'].index(b'USM1') + 6, struct.pack('<H', divisor))
        self.u.mem_write(BIOS * 16 + 0x100, bytes([0xcd, 0xf5, 0xcf]))   # INT 15h
        self.u.mem_write(BIOS * 16 + 0x200, BIOS08)
        self.u.mem_write(BIOS * 16 + 0x400, bytes([0xcd, 0xf4, 0xcf]))   # INT 74h (BIOS IRQ 12)
        self.u.mem_write(USER * 16, bytes([0xcd, 0xf7, 0xcb]))            # event proc: int F7h; retf
        for n, off in ((0x15, 0x100), (0x08, 0x200), (0x74, 0x400)):
            self.ivt(n, BIOS, off)
        self.u.hook_add(UC_HOOK_INTR, self.intr)

    def ivt(self, n, seg=None, off=None):
        if seg is None:
            o, s = struct.unpack('<HH', self.u.mem_read(n * 4, 4))
            return s, o
        self.u.mem_write(n * 4, struct.pack('<HH', off, seg))

    def r(self, reg):
        return self.u.reg_read(reg)

    def intr(self, uc, n, _data=None):
        if n == 0xf5:
            ax, bx, es = self.r(UC_X86_REG_AX), self.r(UC_X86_REG_BX), self.r(UC_X86_REG_ES)
            self.calls15.append((ax, bx >> 8, es, bx))
            fl = self.r(UC_X86_REG_EFLAGS)
            if (ax >> 8) == 0xc2 and self.bios_mouse:
                if ax == 0xc207:
                    uc.mem_write(BIOS * 16 + FCP, struct.pack('<HH', bx, es))
                # the handler's IRET reloads FLAGS from the stack: CF there
                sp = self.r(UC_X86_REG_SP)
                f, = struct.unpack('<H', uc.mem_read(self.r(UC_X86_REG_SS) * 16 + sp + 4, 2))
                uc.mem_write(self.r(UC_X86_REG_SS) * 16 + sp + 4, struct.pack('<H', f & ~1))
                uc.reg_write(UC_X86_REG_AX, ax & 0xff)
            else:
                sp = self.r(UC_X86_REG_SP)
                f, = struct.unpack('<H', uc.mem_read(self.r(UC_X86_REG_SS) * 16 + sp + 4, 2))
                uc.mem_write(self.r(UC_X86_REG_SS) * 16 + sp + 4, struct.pack('<H', f | 1))
                uc.reg_write(UC_X86_REG_AX, 0x8600)
        elif n == 0xf8:
            if self.pending:
                st, x, y = self.pending.pop(0)
                uc.reg_write(UC_X86_REG_AX, st)
                uc.reg_write(UC_X86_REG_BX, x)
                uc.reg_write(UC_X86_REG_CX, y)
                uc.reg_write(UC_X86_REG_DX, 1)
            else:
                uc.reg_write(UC_X86_REG_DX, 0)
        elif n == 0xf7:
            s = lambda v: v - 0x10000 if v & 0x8000 else v
            self.events.append((self.r(UC_X86_REG_AX), s(self.r(UC_X86_REG_BX)), s(self.r(UC_X86_REG_CX)),
                                self.r(UC_X86_REG_DX)))
        elif n == 0xf4:
            self.bios74 += 1
        elif n == 0xff:
            uc.emu_stop()
        else:                                   # real-mode delivery through the IVT
            ss, sp = self.r(UC_X86_REG_SS), self.r(UC_X86_REG_SP)
            fl = self.r(UC_X86_REG_EFLAGS) & 0xffff
            frame = struct.pack('<HHH', self.r(UC_X86_REG_IP), self.r(UC_X86_REG_CS), fl)
            sp = (sp - 6) & 0xffff
            uc.mem_write(ss * 16 + sp, frame)
            uc.reg_write(UC_X86_REG_SP, sp)
            uc.reg_write(UC_X86_REG_EFLAGS, fl & ~0x0300)
            seg, off = self.ivt(n)
            uc.reg_write(UC_X86_REG_CS, seg)
            uc.reg_write(UC_X86_REG_IP, off)

    def run(self, code: bytes):
        """Run code in APP (ends with int FFh); every run at a new offset, so
        Unicorn never executes a stale translation of earlier code."""
        self.slot = getattr(self, 'slot', 0x1000) + 0x40
        self.u.mem_write(APP * 16 + self.slot, code + b'\xcd\xff')
        self.u.reg_write(UC_X86_REG_CS, APP)
        self.u.reg_write(UC_X86_REG_SS, STACK)
        self.u.reg_write(UC_X86_REG_SP, 0xfffe)
        self.u.reg_write(UC_X86_REG_DS, APP)
        self.u.reg_write(UC_X86_REG_ES, APP)
        self.u.reg_write(UC_X86_REG_EFLAGS, 0x0202)
        start = APP * 16 + self.slot
        self.u.emu_start(start, start + len(code) + 2, count=200000)

    def entry(self, ordinal):
        return self.ne['entries'][ordinal - 1][1]

    def far_call(self, off, *words):
        code = b''.join(bytes([0x68]) + struct.pack('<H', w) for w in words)
        return code + bytes([0x9a]) + struct.pack('<HH', off, DRV)

    def inquire(self):
        self.run(self.far_call(self.entry(1), APP, INFO))
        return self.r(UC_X86_REG_AX), bytes(self.u.mem_read(APP * 16 + INFO, 16))

    def enable(self):
        self.run(self.far_call(self.entry(2), USER, 0))

    def disable(self):
        self.run(self.far_call(self.entry(3)))

    def tick(self, irq=0x08):
        self.run(bytes([0xcd, irq]))


class Usosms1(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = driver_file()
        cls.ne = parse_ne(cls.data)

    def test_ne_shape(self):
        ne = self.ne
        self.assertEqual(ne['name'], b'MOUSE')
        self.assertEqual(ne['ver'], 4)
        self.assertEqual(ne['flags'], 0x8004)
        self.assertEqual((ne['nseg'], ne['nmod']), (1, 0))
        self.assertEqual(ne['seg_flags'], 0x0040)          # fixed, preload, no relocations
        self.assertEqual(ne['seg'], 1)
        self.assertEqual(len(ne['entries']), 3)
        self.assertTrue(all(f == 1 for f, _ in ne['entries']))
        self.assertIn(b'INQUIRE', self.data)

    def test_inquire_present(self):
        m = Machine(self.ne)
        ax, info = m.inquire()
        self.assertEqual(ax, 14)
        self.assertEqual(info[0], 0xff)
        self.assertEqual(struct.unpack_from('<H', info, 2)[0], 2)
        self.assertEqual(info[14:16], b'\0\0')              # no byte past the 14
        self.assertEqual(m.calls15[0][:2], (0xc205, 3))

    def test_inquire_no_bios_mouse(self):
        m = Machine(self.ne, bios_mouse=False)
        ax, info = m.inquire()
        self.assertEqual((ax, info[0]), (14, 0))
        m.enable()
        self.assertEqual(m.ivt(0x08), (BIOS, 0x200))       # nothing hooked

    def test_events(self):
        m = Machine(self.ne)
        m.inquire()
        m.enable()
        self.assertEqual([c[0] for c in m.calls15[-3:]], [0xc205, 0xc207, 0xc200])
        self.assertEqual(m.calls15[-1][1], 1)
        self.assertEqual(m.ivt(0x08)[0], DRV)
        self.assertEqual(m.ivt(0x74)[0], DRV)
        # move right 5, up 3 (PS/2 Y positive = up)
        m.pending.append((0x08, 5, 3))
        m.tick()
        self.assertEqual(m.events, [(1, 5, -3, 2)])
        # left down with movement left 2 (X sign bit)
        m.pending.append((0x19, 0xfe, 0))
        m.tick()
        self.assertEqual(m.events[-1], (0x03, -2, 0, 2))
        # left up, right down
        m.pending.append((0x0a, 0, 0))
        m.tick()
        self.assertEqual(m.events[-1], (0x04 | 0x08, 0, 0, 2))
        # right up, movement down 4 (Y sign bit: -4 -> +4 on screen)
        m.pending.append((0x28, 0, 0xfc))
        m.tick()
        self.assertEqual(m.events[-1], (0x10 | 0x01, 0, 4, 2))
        # overflow packet ignored, no event
        n = len(m.events)
        m.pending.append((0xc8, 0x7f, 0x7f))
        m.tick()
        self.assertEqual(len(m.events), n)
        # USOSKBC /M style: packet delivered in the timer without our INT 08h
        # dispatch (BIOS vector called directly), then software INT 74h.
        m.pending.append((0x08, 1, 0))
        m.run(bytes([0x9c, 0x9a, 0x00, 0x02, 0x00, 0xf0]))  # pushf; call far BIOS INT 08h
        self.assertEqual(len(m.events), n)
        m.tick(0x74)
        self.assertEqual(m.events[-1], (1, 1, 0, 2))
        self.assertEqual(m.bios74, 1)                       # the previous INT 74h was chained
        m.disable()
        self.assertEqual(m.ivt(0x08), (BIOS, 0x200))
        self.assertEqual(m.ivt(0x74), (BIOS, 0x400))
        self.assertEqual(m.calls15[-2][:2], (0xc200, 0))
        self.assertEqual(m.calls15[-1][0], 0xc207)
        self.assertEqual((m.calls15[-1][2], m.calls15[-1][3]), (0, 0))
        m.pending.append((0x08, 1, 0))
        n = len(m.events)
        m.tick()
        self.assertEqual(len(m.events), n)

    def test_default_divisor_carries_remainder(self):
        code = self.ne['code']
        self.assertEqual(struct.unpack_from('<H', code, code.index(b'USM1') + 6)[0], 2)
        m = Machine(self.ne, divisor=2)
        m.inquire()
        m.enable()
        m.pending.append((0x08, 5, 3))
        m.tick()
        self.assertEqual(m.events, [(1, 2, -1, 2)])     # 5/2, -3/2; 1 and -1 carried
        m.pending.append((0x28, 1, 0xff))                # X +1, Y -1 (sign set) -> +1 on screen
        m.tick()
        self.assertEqual(m.events[-1], (1, 1, 0, 2))     # (1+1)/2, (-1+1)/2
        m.pending.append((0x09, 1, 0))                   # left down: below one pixel, button only
        m.tick()
        self.assertEqual(m.events[-1], (0x02, 0, 0, 2))

    def test_disable_keeps_foreign_hook(self):
        m = Machine(self.ne)
        m.inquire()
        m.enable()
        m.ivt(0x08, 0x6000, 0x10)                           # someone hooked INT 08h after us
        m.u.mem_write(0x6000 * 16 + 0x10, b'\xcf')
        m.disable()
        self.assertEqual(m.ivt(0x08), (0x6000, 0x10))
        self.assertEqual(m.ivt(0x74)[0], DRV)               # stays as a plain chain
        m.tick(0x74)
        self.assertEqual(m.bios74, 1)


if __name__ == '__main__':
    unittest.main()
