"""Run the whole NT 3.x MBR (nt3_e820_mbr.S, boot sector part) in unicorn.

Checks the two 2026-10-29 additions (nt351fresh2, X470):
- CMOS century: the pre-ACPI HAL reads the century from CMOS 37h when the
  classic CMOS checksum fails (CSMWrap rewrites 15h-18h without it), so the
  X470 HAL returned Year = 26.  The MBR copies a BCD century in 32h to 37h
  when 37h is 00h or FFh, and never touches 37h otherwise.
- E820 record: the firmware map goes to disk sector 2 (INT 13h AH=43h),
  "E8" at bytes 510-511, before the hook is installed.
The BIOS is a set of IRET stubs at F000:xxxx whose services Python performs
(INT 13h AH=08h/42h/43h, INT 15h E820, INT 1Ah B101h).
"""
from pathlib import Path
import os
import struct
import subprocess
import sys
import unittest
from unicorn import Uc, UC_ARCH_X86, UC_MODE_16, UC_HOOK_CODE, UC_HOOK_INTR, UC_HOOK_INSN
from unicorn.x86_const import *

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/tests'))
import depguard
OUT = ROOT / 'zig-out/nt3-mbr-cmos-test'
SRC = ROOT / 'src/platform/bios/nt3'
BIOS_SEG = 0xF000
X470_MAP = [(0, 0x9FC00, 1), (0x9FC00, 0x400, 2), (0xA0000, 0x60000, 2),
            (0x100000, 0x7F00000, 1), (0x8000000, 0x8000, 4), (0x8008000, 0xB0000000, 1),
            (0xFEC00000, 0x1000, 2), (0x1_0000_0000, 0x7_4000_0000, 1)]


def build():
    depguard.require_zig()
    OUT.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env['ZIG_GLOBAL_CACHE_DIR'] = str(ROOT / 'tools/cache/zig-global')
    zig = str(ROOT / 'tools/zig/zig.exe')
    elf = OUT / 'nt3-e820-mbr.elf'
    subprocess.run([zig, 'cc', '-target', 'x86-freestanding-none', '-mcpu=i386', '-nostdlib',
                    '-nodefaultlibs', '-Wl,-T,' + str(SRC / 'nt3_e820_mbr.ld'),
                    '-Wl,--entry=nt3_e820_mbr_start', str(SRC / 'nt3_e820_mbr.S'), '-o', str(elf)],
                   env=env, check=True)
    parts = {}
    for name in ('.text', '.hook'):
        out = OUT / (name.strip('.') + '.bin')
        subprocess.run([zig, 'objcopy', '-O', 'binary', '-j', name, str(elf), str(out)], env=env, check=True)
        parts[name] = out.read_bytes()
    return parts['.text'], parts['.hook']


class Machine:
    def __init__(self, mbr, hook, cmos, memory_map, with_hook=True):
        self.cmos = dict(cmos)
        self.index = 0
        self.writes = {}
        self.cmos_writes = []
        self.map = memory_map
        self.done = False
        u = self.u = Uc(UC_ARCH_X86, UC_MODE_16)
        u.mem_map(0, 0x100000)
        u.mem_map(0xFED00000, 0x1000)
        u.mem_write(0xFED00000, b'\xff' * 0x1000)        # no HPET
        sector0 = bytearray(512)
        sector0[:len(mbr)] = mbr
        sector0[446:462] = bytes([0x80, 1, 1, 0, 6, 0xFE, 0x3F, 0xFE]) + struct.pack('<II', 63, 1000)
        sector0[510:] = b'\x55\xaa'
        self.disk = {0: bytes(sector0), 63: b'\xf4' + bytes(509) + b'\x55\xaa'}
        if with_hook:
            hs = bytearray(512)
            hs[:len(hook)] = hook
            hs[510:] = b'U3'
            self.disk[1] = bytes(hs)
        u.mem_write(0x7C00, bytes(sector0))
        # IVT: every vector -> an IRET stub F000:(4 * n); BDA 413h = 640 KiB.
        for n in range(256):
            u.mem_write(n * 4, struct.pack('<HH', n * 4, BIOS_SEG))
            u.mem_write((BIOS_SEG << 4) + n * 4, b'\xcf')
        u.mem_write(0x413, struct.pack('<H', 640))
        u.hook_add(UC_HOOK_INTR, self.intr)
        u.hook_add(UC_HOOK_CODE, self.code)
        u.hook_add(UC_HOOK_INSN, self.port_in, None, 1, 0, UC_X86_INS_IN)
        u.hook_add(UC_HOOK_INSN, self.port_out, None, 1, 0, UC_X86_INS_OUT)

    # --- ports: CMOS index 70h / data 71h -----------------------------------
    def port_in(self, uc, port, size, user):
        if port == 0x71:
            return self.cmos.get(self.index & 0x7F, 0)
        return 0xFF

    def port_out(self, uc, port, size, value, user):
        if port == 0x70:
            self.index = value
        elif port == 0x71:
            self.cmos[self.index & 0x7F] = value & 0xFF
            self.cmos_writes.append((self.index & 0x7F, value & 0xFF))

    # --- INT n: the real-mode IVT dispatch ----------------------------------
    def intr(self, uc, intno, user):
        cs, ip = struct.unpack('<HH', uc.mem_read(intno * 4, 4))[::-1]
        sp = uc.reg_read(UC_X86_REG_SP)
        ss = uc.reg_read(UC_X86_REG_SS)
        frame = struct.pack('<HHH', uc.reg_read(UC_X86_REG_IP), uc.reg_read(UC_X86_REG_CS),
                            uc.reg_read(UC_X86_REG_EFLAGS) & 0xFFFF)
        sp = (sp - 6) & 0xFFFF
        uc.mem_write((ss << 4) + sp, frame)
        uc.reg_write(UC_X86_REG_SP, sp)
        uc.reg_write(UC_X86_REG_CS, cs)
        uc.reg_write(UC_X86_REG_IP, ip)

    def set_cf(self, cf):
        uc = self.u
        sp = uc.reg_read(UC_X86_REG_SP) + (uc.reg_read(UC_X86_REG_SS) << 4)
        flags = struct.unpack('<H', uc.mem_read(sp + 4, 2))[0] & ~1
        uc.mem_write(sp + 4, struct.pack('<H', flags | (1 if cf else 0)))

    def code(self, uc, address, size, user):
        if address == 0x7C00 and uc.reg_read(UC_X86_REG_CS) == 0 and self.started:
            self.done = True
            uc.emu_stop()
            return
        if address < (BIOS_SEG << 4) or address >= (BIOS_SEG << 4) + 1024:
            return
        n = (address - (BIOS_SEG << 4)) // 4
        r = uc.reg_read
        ah = (r(UC_X86_REG_EAX) >> 8) & 0xFF
        if n == 0x13:
            if ah == 0x08:
                uc.reg_write(UC_X86_REG_ECX, 0xFFFF)
                uc.reg_write(UC_X86_REG_EDX, 0xFE01)
                uc.reg_write(UC_X86_REG_EAX, 0)
                self.set_cf(False)
            elif ah in (0x42, 0x43):
                pkt = (r(UC_X86_REG_DS) << 4) + (r(UC_X86_REG_ESI) & 0xFFFF)
                size_, _, count, off, seg, lba = struct.unpack('<BBHHHQ', uc.mem_read(pkt, 16))
                assert size_ == 16 and count == 1, (size_, count)
                buf = (seg << 4) + off
                if ah == 0x42:
                    uc.mem_write(buf, self.disk.get(lba, bytes(512)))
                else:
                    assert r(UC_X86_REG_EAX) & 0xFF == 0, 'write with verify flag'
                    self.writes[lba] = bytes(uc.mem_read(buf, 512))
                uc.reg_write(UC_X86_REG_EAX, 0)
                self.set_cf(False)
            else:
                self.set_cf(True)
        elif n == 0x15 and r(UC_X86_REG_EAX) & 0xFFFF == 0xE820:
            i = r(UC_X86_REG_EBX)
            if i >= len(self.map):
                self.set_cf(True)
                return
            dst = (r(UC_X86_REG_ES) << 4) + (r(UC_X86_REG_EDI) & 0xFFFF)
            uc.mem_write(dst, struct.pack('<QQI', *self.map[i]))
            uc.reg_write(UC_X86_REG_EAX, 0x534D4150)
            uc.reg_write(UC_X86_REG_ECX, 20)
            uc.reg_write(UC_X86_REG_EBX, 0 if i + 1 == len(self.map) else i + 1)
            self.set_cf(False)
        elif n == 0x1A:
            uc.reg_write(UC_X86_REG_EAX, 0x8100)          # no PCI BIOS
            self.set_cf(True)
        else:
            self.set_cf(True)

    def run(self, count=200000):
        u = self.u
        u.reg_write(UC_X86_REG_EDX, 0x80)
        self.started = False
        u.reg_write(UC_X86_REG_CS, 0)
        u.reg_write(UC_X86_REG_IP, 0x7C00)

        def arm(uc, address, size, user):
            if address >= 0x600 and address < 0x800:
                self.started = True
        h = u.hook_add(UC_HOOK_CODE, arm)
        try:
            u.emu_start(0x7C00, 0xFFFFF, count=count)
        except Exception:
            if not self.done:
                raise
        assert self.done, 'MBR did not jump to the VBR at 0000:7C00'
        return self


class Nt3MbrCmosE820(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mbr, cls.hook = build()
        assert len(cls.mbr) <= 440, len(cls.mbr)

    def boot(self, cmos, memory_map=X470_MAP, with_hook=True):
        return Machine(self.mbr, self.hook, cmos, memory_map, with_hook).run()

    def test_x470_century_copied_to_37h(self):
        # X470 (RtcDiag): 32h = 20h, 37h = 00h -> HAL year 26.
        m = self.boot({0x32: 0x20, 0x37: 0x00})
        self.assertEqual(m.cmos[0x37], 0x20)
        self.assertEqual(m.cmos_writes, [(0x37, 0x20)])

    def test_ff_and_other_centuries(self):
        self.assertEqual(self.boot({0x32: 0x19, 0x37: 0xFF}).cmos[0x37], 0x19)
        self.assertEqual(self.boot({0x32: 0x21, 0x37: 0x00}).cmos[0x37], 0x21)

    def test_37h_in_use_or_no_century_untouched(self):
        for cmos in ({0x32: 0x20, 0x37: 0x5A}, {0x32: 0x20, 0x37: 0x20},
                     {0x32: 0x00, 0x37: 0x00}, {0x32: 0x26, 0x37: 0x00},
                     {0x32: 0xFF, 0x37: 0xFF}, {0x32: 0x1A, 0x37: 0x00}):
            m = self.boot(cmos)
            self.assertEqual(m.cmos_writes, [], cmos)
            self.assertEqual(m.cmos[0x37], cmos[0x37])

    def test_e820_record_in_sector_2(self):
        m = self.boot({0x32: 0x20, 0x37: 0x00})
        self.assertEqual(sorted(m.writes), [2])
        rec = m.writes[2]
        self.assertEqual(rec[510:], b'E8')
        got = [struct.unpack_from('<QQI', rec, 20 * i) for i in range(len(X470_MAP))]
        self.assertEqual(got, X470_MAP)
        self.assertEqual(rec[20 * len(X470_MAP):510], bytes(510 - 20 * len(X470_MAP)))

    def test_e820_record_caps_at_25_entries(self):
        big = [(0x100000 * (i + 1), 0x1000, 1 + i % 2) for i in range(40)]
        rec = self.boot({}, memory_map=big).writes[2]
        got = [struct.unpack_from('<QQI', rec, 20 * i) for i in range(25)]
        self.assertEqual(got, big[:25])
        self.assertEqual(rec[500:510], bytes(10))

    def test_without_hook_sector_still_boots_and_records(self):
        m = self.boot({0x32: 0x20, 0x37: 0x00}, with_hook=False)
        self.assertEqual(m.cmos[0x37], 0x20)
        self.assertEqual(sorted(m.writes), [2])
        # BDA 413h restored (no hook resident).
        self.assertEqual(struct.unpack('<H', m.u.mem_read(0x413, 2))[0], 640)

    def test_hook_installed_after_record(self):
        m = self.boot({})
        seg = struct.unpack('<HH', m.u.mem_read(0x15 * 4, 4))
        self.assertEqual(seg, (0, 639 << 6))
        self.assertEqual(struct.unpack('<H', m.u.mem_read(0x413, 2))[0], 639)


if __name__ == '__main__':
    unittest.main()
