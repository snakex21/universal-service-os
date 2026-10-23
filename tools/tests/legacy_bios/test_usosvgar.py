"""USOSVGAR.COM (VGA register readback / latch probe) in Unicorn against a
small planar VGA model: a faithful VGA gives RESULT OK, a card whose graphics
controller or sequencer data reads do not return the written value gives
RESULT READBACK-BAD, broken off-screen latch storage gives
RESULT MEMORY-OR-LATCH-BAD; the previous text mode is set again."""
from pathlib import Path
import os
import struct
import sys
import tempfile
import unittest
from unicorn import Uc, UC_ARCH_X86, UC_MODE_16, UC_HOOK_INTR, UC_HOOK_INSN
from unicorn.x86_const import *

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))
import build_win9x_support
if os.environ.get('USOS_TOOLS_ROOT'):
    # Worktrees without tools/zig: take the toolchain from another checkout.
    build_win9x_support.ROOT = Path(os.environ['USOS_TOOLS_ROOT'])

PSP = 0x1000


class Vga:
    """Planar VGA: SEQ 2 map mask, GC 0-8, write modes 0/1, read mode 0,
    latches. bad_gc / bad_seq make data reads return a wrong value."""

    def __init__(self, bad_gc=None, bad_seq=False, bad_offscreen=False):
        self.planes = [bytearray(0x10000) for _ in range(4)]
        self.latch = [0, 0, 0, 0]
        self.seq = [3, 1, 0x0f, 0, 6]
        self.gc = [0, 0, 0, 0, 0, 0, 5, 0x0f, 0xff]
        self.si = self.gi = 0
        self.bad_gc, self.bad_seq, self.bad_off = bad_gc, bad_seq, bad_offscreen

    def out(self, port, v):
        if port == 0x3c4:
            self.si = v & 7
        elif port == 0x3c5 and self.si < 5:
            self.seq[self.si] = v
        elif port == 0x3ce:
            self.gi = v & 15
        elif port == 0x3cf and self.gi < 9:
            self.gc[self.gi] = v

    def inp(self, port):
        if port == 0x3c4:
            return self.si
        if port == 0x3ce:
            return self.gi
        if port == 0x3c5:
            v = self.seq[self.si] if self.si < 5 else 0xff
            return (v ^ 0x05) if self.bad_seq and self.si == 2 else v
        if port == 0x3cf:
            v = self.gc[self.gi] if self.gi < 9 else 0xff
            return 0xff if self.bad_gc is not None and self.gi == self.bad_gc else v
        return 0xff

    def read(self, off):
        if self.bad_off and off >= 0xbf00:
            self.latch = [0x00] * 4
            return 0
        self.latch = [p[off] for p in self.planes]
        return self.latch[self.gc[4] & 3]

    def write(self, off, v):
        if self.bad_off and off >= 0xbf00:
            return
        mode = self.gc[5] & 3
        for i in range(4):
            if not self.seq[2] & (1 << i):
                continue
            if mode == 1:
                self.planes[i][off] = self.latch[i]
            else:
                bm = self.gc[8]
                self.planes[i][off] = (v & bm) | (self.latch[i] & ~bm & 0xff)


class Machine:
    def __init__(self, com, vga):
        self.vga, self.mode, self.out, self.modes = vga, 3, b'', []
        u = self.u = Uc(UC_ARCH_X86, UC_MODE_16)
        u.mem_map(0, 0xa0000)
        u.mmio_map(0xa0000, 0x10000, self._mr, None, self._mw, None)
        u.mem_map(0xb0000, 0x50000)
        u.mem_write(PSP * 16 + 0x100, com)
        u.mem_write(0xf0000, b'\xcf')
        for n in range(256):
            u.mem_write(n * 4, struct.pack('<HH', 0, 0xf000))
        for r, v in ((UC_X86_REG_CS, PSP), (UC_X86_REG_DS, PSP), (UC_X86_REG_ES, PSP),
                     (UC_X86_REG_SS, PSP), (UC_X86_REG_SP, 0xfffe), (UC_X86_REG_IP, 0x100)):
            u.reg_write(r, v)
        u.hook_add(UC_HOOK_INTR, self._int)
        u.hook_add(UC_HOOK_INSN, self._in, None, 1, 0, UC_X86_INS_IN)
        u.hook_add(UC_HOOK_INSN, self._outh, None, 1, 0, UC_X86_INS_OUT)
        self.done = False

    def _mr(self, uc, off, size, data):
        v = 0
        for i in range(size):
            v |= self.vga.read(off + i) << (8 * i)
        return v

    def _mw(self, uc, off, size, value, data):
        for i in range(size):
            self.vga.write(off + i, (value >> (8 * i)) & 0xff)

    def _in(self, uc, port, size, data):
        return self.vga.inp(port)

    def _outh(self, uc, port, size, value, data):
        self.vga.out(port, value & 0xff)

    def _int(self, uc, n, data):
        ax = uc.reg_read(UC_X86_REG_AX)
        if n == 0x10:
            ah = ax >> 8
            if ah == 0x0f:
                uc.reg_write(UC_X86_REG_AX, (ax & 0xff00) | self.mode)
            elif ah == 0:
                self.mode = ax & 0x7f
                self.modes.append(self.mode)
        elif n == 0x21:
            ah = ax >> 8
            if ah == 0x40:
                ds = uc.reg_read(UC_X86_REG_DS)
                dx, cx = uc.reg_read(UC_X86_REG_DX), uc.reg_read(UC_X86_REG_CX)
                self.out += bytes(uc.mem_read(ds * 16 + dx, cx))
                uc.reg_write(UC_X86_REG_AX, cx)
            elif ah == 0x4c:
                self.done = True
                uc.emu_stop()

    def run(self):
        self.u.emu_start(PSP * 16 + 0x100, 0, count=2_000_000)
        return self.out.decode('ascii')


class UsosVgarTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        out = Path(cls.tmp.name)
        cls.com = build_win9x_support.build_usosvgar(out, out).read_bytes()

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_with(self, vga):
        m = Machine(self.com, vga)
        text = m.run()
        self.assertTrue(m.done, text)
        self.assertEqual(m.modes, [0x12, 3], text)
        return text

    def test_faithful_vga_ok(self):
        text = self.run_with(Vga())
        self.assertIn('readback tests 0075 mismatches 0000', text)
        self.assertIn('RESULT OK', text)
        self.assertIn('implicit index (SEQ2 via 3C5, GC8 via 3CF): 05 0F 3C FF', text)

    def test_bad_gc8_readback(self):
        text = self.run_with(Vga(bad_gc=8))
        self.assertIn('RESULT READBACK-BAD', text)
        self.assertIn('bad 03CE:08 wrote 00 read FF', text)

    def test_bad_seq_readback(self):
        text = self.run_with(Vga(bad_seq=True))
        self.assertIn('RESULT READBACK-BAD', text)
        self.assertIn('bad 03C4:02', text)

    def test_bad_offscreen_latches(self):
        text = self.run_with(Vga(bad_offscreen=True))
        self.assertIn('RESULT MEMORY-OR-LATCH-BAD', text)

    def test_restores_registers(self):
        vga = Vga()
        self.run_with(vga)
        self.assertEqual(vga.gc[5] & 3, 0)
        self.assertEqual(vga.gc[8], 0xff)
        self.assertEqual(vga.seq[2], 0x0f)


if __name__ == '__main__':
    unittest.main()
