"""USOSKBC.COM script op 6 (pix) in Unicorn: the plane-0 hash of a VGA mode
12h rectangle equals tools/usos_keyscript.pixel_hash, the step advances only
on a match (or after its timeout), the graphics controller registers the op
touches (index, read map select, mode) are put back and the interrupted
code's 32-bit registers survive. No Microsoft files; the VGA is a Python
stand-in (4 planes, read map select chooses the plane CPU reads see)."""
from pathlib import Path
import struct
import sys
import unittest
from unicorn import Uc, UC_ARCH_X86, UC_MODE_16, UC_HOOK_INSN, UC_HOOK_MEM_READ
from unicorn.x86_const import *

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))
sys.path.insert(0, str(ROOT / 'tools/tests'))
import depguard  # noqa: F401
from build_win3_usb_keyboard import build_kbc, elf_symbols
import usos_keyscript as ks

TSR = 0x1000
STUB = 0x0f00          # call script / pixhash; hlt (inside the TSR segment)


class Vga:
    def __init__(self):
        self.index = 0x77
        self.regs = {4: 2, 5: 0x08}   # read map 2, read mode 1: must be restored
        self.planes = [bytearray(0x10000) for _ in range(4)]

    def inb(self, port):
        if port == 0x3ce:
            return self.index
        if port == 0x3cf:
            return self.regs.get(self.index, 0)
        return 0xff

    def outb(self, port, value):
        if port == 0x3ce:
            self.index = value
        elif port == 0x3cf:
            self.regs[self.index] = value


class Machine:
    def __init__(self, com, sym):
        self.u = Uc(UC_ARCH_X86, UC_MODE_16)
        self.u.mem_map(0, 0x110000)
        self.sym = sym
        self.u.mem_write(TSR * 16 + 0x100, com)
        self.u.mem_write(0x449, b'\x12')            # BDA video mode 12h
        self.vga = Vga()
        self.reads_wrong_mode = 0
        self.u.hook_add(UC_HOOK_INSN, self.on_in, None, 1, 0, UC_X86_INS_IN)
        self.u.hook_add(UC_HOOK_INSN, self.on_out, None, 1, 0, UC_X86_INS_OUT)
        self.u.hook_add(UC_HOOK_MEM_READ, self.on_read, None, 0xa0000, 0xaffff)

    def on_in(self, uc, port, size, _):
        return self.vga.inb(port)

    def on_out(self, uc, port, size, value, _):
        self.vga.outb(port, value & 0xff)

    def on_read(self, uc, access, address, size, value, _):
        if self.vga.regs.get(5, 0) & 0x08:
            self.reads_wrong_mode += 1
        plane = self.vga.regs.get(4, 0) & 3
        off = address - 0xa0000
        uc.mem_write(address, bytes(self.vga.planes[plane][off:off + size]))

    def call(self, name, si=None, eax=0x12345678):
        u = self.u
        target = self.sym[name]
        stub = bytes([0xe8]) + struct.pack('<h', target - (STUB + 3)) + b'\xf4'
        u.mem_write(TSR * 16 + STUB, stub)
        for reg, v in ((UC_X86_REG_CS, TSR), (UC_X86_REG_DS, TSR), (UC_X86_REG_ES, 0), (UC_X86_REG_SS, 0x5000)):
            u.reg_write(reg, v)
        u.reg_write(UC_X86_REG_SP, 0xfffe)
        u.reg_write(UC_X86_REG_EAX, eax)
        u.reg_write(UC_X86_REG_EFLAGS, 0x2)
        if si is not None:
            u.reg_write(UC_X86_REG_SI, si)
        u.emu_start(TSR * 16 + STUB, TSR * 16 + STUB + 3, count=200000)
        return u.reg_read(UC_X86_REG_EFLAGS) & 1

    def word(self, name):
        return struct.unpack('<H', self.u.mem_read(TSR * 16 + self.sym[name], 2))[0]

    def set_word(self, name, v):
        self.u.mem_write(TSR * 16 + self.sym[name], struct.pack('<H', v))


class PixTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import tempfile
        cls.tmp = Path(tempfile.mkdtemp(prefix='usoskbc-pix-'))
        com = build_kbc(cls.tmp, cls.tmp)
        cls.com = com.read_bytes()
        cls.sym = {k: v for k, v in elf_symbols(cls.tmp / 'usoskbc.elf').items()}

    def machine(self, picture):
        m = Machine(self.com, self.sym)
        x, y, w, h = 3, 398, 60, 12
        for row in range(h):
            off = (y + row) * 80 + x
            m.vga.planes[0][off:off + w] = picture[row * w:(row + 1) * w]
            m.vga.planes[1][off:off + w] = bytes(w)          # other planes differ
            m.vga.planes[2][off:off + w] = b'\xff' * w
        return m

    def script_op(self, digest, timeout=600.0):
        data = ks.compile_script('pix 3 398 60 12 %08x %g\n' % (digest, timeout))
        return data[4:]

    def test_hash_matches_python_and_restores_registers(self):
        picture = bytes((i * 37 + 11) & 0xff for i in range(60 * 12))
        digest = ks.pixel_hash(picture, 60)
        m = self.machine(picture)
        op = self.script_op(digest)
        m.u.mem_write(TSR * 16 + 0x0e00, op)
        self.assertEqual(m.call('pixhash', si=0x0e00, eax=0xdeadbeef), 1)
        self.assertEqual(m.u.reg_read(UC_X86_REG_EAX), 0xdeadbeef)
        self.assertEqual((m.vga.index, m.vga.regs[4], m.vga.regs[5]), (0x77, 2, 0x08))
        self.assertEqual(m.reads_wrong_mode, 0)
        wrong = self.script_op(digest ^ 1)
        m.u.mem_write(TSR * 16 + 0x0e00, wrong)
        self.assertEqual(m.call('pixhash', si=0x0e00), 0)
        self.assertEqual((m.vga.index, m.vga.regs[4], m.vga.regs[5]), (0x77, 2, 0x08))

    def test_script_waits_for_the_picture_then_times_out(self):
        picture = bytes(60 * 12)
        m = self.machine(picture)
        op = self.script_op(0x0bad0bad, timeout=1.0)     # never matches; 5 checks
        base = 0x0e00
        m.u.mem_write(TSR * 16 + base, op + b'\x00')
        m.set_word('spos', base)
        m.set_word('swait', 0)
        steps = 0
        while m.word('spos') == base and steps < 200:
            m.call('script')
            steps += 1
        self.assertEqual(m.word('spos'), base + 11)       # past op 6 (settle delay next)
        self.assertTrue(4 * 4 <= steps <= 6 * 4 + 4, steps)
        self.assertEqual(m.word('pcount'), 0)

    def test_script_goes_on_at_the_match(self):
        picture = bytes((i * 5) & 0xff for i in range(60 * 12))
        m = self.machine(picture)
        op = self.script_op(ks.pixel_hash(picture, 60))
        base = 0x0e00
        m.u.mem_write(TSR * 16 + base, op + b'\x00')
        m.set_word('spos', base)
        for _ in range(4):
            m.call('script')
        self.assertEqual(m.word('spos'), base + 11)
        m.u.mem_write(0x449, b'\x03')                     # text mode: no check
        m.u.mem_write(TSR * 16 + base, op + b'\x00')
        m.set_word('spos', base)
        for _ in range(8):
            m.call('script')
        self.assertEqual(m.word('spos'), base)


if __name__ == '__main__':
    unittest.main()
