"""Execute the actual DOS disk boundary and installed MBR without real disks."""
from pathlib import Path
import os
import struct
import subprocess
import unittest
from unicorn import Uc, UC_ARCH_X86, UC_MODE_16, UC_HOOK_CODE, UC_HOOK_INTR
from unicorn.x86_const import *

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'zig-out/dos-disk-filter'


def build(name, section):
    OUT.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env['ZIG_GLOBAL_CACHE_DIR'] = str(ROOT / 'tools/cache/zig-global')
    zig = str(ROOT / 'tools/zig/zig.exe')
    obj = OUT / (name + '.o')
    binary = OUT / (name + '.bin')
    subprocess.run([zig, 'cc', '-target', 'x86-freestanding-none', '-mcpu=i386',
                    '-c', str(ROOT / ('src/platform/bios/' + name + '.S')),
                    '-o', str(obj)], env=env, check=True)
    subprocess.run([zig, 'objcopy', '-O', 'binary', '-j', section,
                    str(obj), str(binary)], env=env, check=True)
    return binary.read_bytes()


class DosDiskBoundary(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.filter = build('dos_disk_filter', '.rodata.dos_filter')
        cls.mbr = build('dos_target_mbr', '.rodata.dos_mbr')
        cls.source_mbr = build('dos_source_mbr', '.rodata.dos_source_mbr')
        assert len(cls.filter) == 256 and len(cls.mbr) == 512

    def call(self, drive, function, fail=False, target=0x82, visible_count=1):
        u = Uc(UC_ARCH_X86, UC_MODE_16)
        u.mem_map(0, 0x100000)
        u.mem_write(0x475, bytes([visible_count]))
        code = bytearray(self.filter)
        struct.pack_into('<HHB', code, 0xf0, 0, 0xf000, target)
        u.mem_write(0x9e000, bytes(code))
        u.mem_write(0xf0000, b'\xcf')
        u.reg_write(UC_X86_REG_CS, 0x9e00)
        u.reg_write(UC_X86_REG_SS, 0x8000)
        u.reg_write(UC_X86_REG_SP, 0xeffa)
        u.mem_write(0x8effa, struct.pack('<HHH', 0, 0x7000, 0x202))
        u.reg_write(UC_X86_REG_AX, function << 8)
        u.reg_write(UC_X86_REG_DX, drive)
        calls = []
        def firmware(uc, address, size, data):
            if address != 0xf0000:
                return
            calls.append(uc.reg_read(UC_X86_REG_DX) & 255)
            if function == 8:
                uc.reg_write(UC_X86_REG_DX, 0xfe04)
            if function == 0x15:
                uc.reg_write(UC_X86_REG_DX, 0x1234)
            sp = uc.reg_read(UC_X86_REG_SP)
            at = 0x80000 + sp + 4
            flags = struct.unpack('<H', uc.mem_read(at, 2))[0]
            uc.mem_write(at, struct.pack('<H', (flags & ~1) | int(fail)))
        u.hook_add(UC_HOOK_CODE, firmware)
        u.emu_start(0x9e000, 0x70000, count=1000)
        self.assertEqual(u.reg_read(UC_X86_REG_SP), 0xf000)
        return calls, u.reg_read(UC_X86_REG_DX), u.reg_read(UC_X86_REG_EFLAGS) & 1

    def test_reads_writes_and_geometry_reach_only_selected_target(self):
        for fn in (2, 3, 0x42, 0x43, 0x48):
            self.assertEqual(self.call(0x80, fn), ([0x82], 0x80, 0))
        self.assertEqual(self.call(0x80, 8), ([0x82], 0xfe01, 0))
        self.assertEqual(self.call(0x80, 8, visible_count=2), ([0x82], 0xfe02, 0))
        self.assertEqual(self.call(0x80, 0x15), ([0x82], 0x1234, 0))
        self.assertEqual(self.call(0x80, 0x43, True)[2], 1)

    def test_other_hard_disks_cannot_be_read_or_written(self):
        for drive in (0x81, 0x82, 0x83, 0x8f, 0xff):
            for fn in (2, 3, 0x42, 0x43, 0x48):
                self.assertEqual(self.call(drive, fn), ([], drive, 1))
        self.assertEqual(self.call(0, 2), ([0], 0, 0))

    def test_live_dos_exposes_no_physical_hard_disks(self):
        for drive in range(0x80, 0x100):
            for fn in (2, 3, 8, 0x42, 0x43, 0x48):
                self.assertEqual(self.call(drive, fn, target=0xff), ([], drive, 1))

    def test_installed_mbr_relocates_and_loads_active_partition(self):
        self.check_mbr(self.mbr, 0x80, 2048)

    def test_ram_source_mbr_starts_prepared_target_without_swapping_disks(self):
        self.check_mbr(self.source_mbr, 0x81, 0)

    def check_mbr(self, code, drive, wanted_lba):
        u = Uc(UC_ARCH_X86, UC_MODE_16)
        u.mem_map(0, 0x100000)
        mbr = bytearray(code)
        struct.pack_into('<I', mbr, 454, 2048)
        u.mem_write(0x7c00, bytes(mbr))
        u.reg_write(UC_X86_REG_DX, drive)
        reads = []
        def interrupt(uc, number, data):
            self.assertEqual(number, 0x13)
            self.assertEqual(uc.reg_read(UC_X86_REG_AX) >> 8, 0x42)
            dap = bytes(uc.mem_read(uc.reg_read(UC_X86_REG_SI), 16))
            reads.append((uc.reg_read(UC_X86_REG_DX), struct.unpack_from('<Q', dap, 8)[0]))
            sector = bytearray(512); sector[0] = 0xf4; sector[510:] = b'\x55\xaa'
            uc.mem_write(0x7c00, bytes(sector))
            uc.reg_write(UC_X86_REG_EFLAGS, uc.reg_read(UC_X86_REG_EFLAGS) & ~1)
        u.hook_add(UC_HOOK_INTR, interrupt)
        u.emu_start(0x7c00, 0x90000, count=1000)
        self.assertEqual(reads, [(0x80, wanted_lba)])


if __name__ == '__main__':
    unittest.main()
