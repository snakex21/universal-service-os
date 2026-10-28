"""Execute the NT 3.x MBR's resident INT 15h E820 filter (sector 1 hook).

CSMWrap reports A0000-FFFFF as one reserved E820 entry (plain SeaBIOS only
F0000-FFFFF).  The NT 3.51 SETUPLDR / NTLDR turn every entry into a loader
memory descriptor; the A0000 one overlapped the VGA window, vga.sys could not
claim A0000-BFFFF and text-mode Setup stopped "while initializing your
computer's video" (0, C0000034) on the X470 (B261028-173747) and in QEMU
OVMF + CSMWrap.  The hook must hand out only non-RAM entries that end at or
below A0000h unchanged; every other non-RAM entry becomes F0000-FFFFF.
"""
from pathlib import Path
import os
import struct
import subprocess
import sys
import unittest
from unicorn import Uc, UC_ARCH_X86, UC_MODE_16, UC_HOOK_CODE
from unicorn.x86_const import *

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/tests'))
import depguard
OUT = ROOT / 'zig-out/nt3-e820-hook-test'
SRC = ROOT / 'src/platform/bios/nt3'

HOOK_SEG = 0x9F00          # INT 12h top after the MBR reserved 1 KiB (636 KiB)
BIOS = 0xF0000             # old INT 15h vector F000:0000 (an IRET)
BUF = 0x7000               # ES:DI = 0000:7000
STACK = 0x8000
RET_CS, RET_IP = 0x0000, 0x0600


def build_hook():
    depguard.require_zig()
    OUT.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env['ZIG_GLOBAL_CACHE_DIR'] = str(ROOT / 'tools/cache/zig-global')
    zig = str(ROOT / 'tools/zig/zig.exe')
    elf = OUT / 'nt3-e820-mbr.elf'
    hook = OUT / 'nt3-e820-hook.bin'
    subprocess.run([zig, 'cc', '-target', 'x86-freestanding-none', '-mcpu=i386', '-nostdlib',
                    '-nodefaultlibs', '-Wl,-T,' + str(SRC / 'nt3_e820_mbr.ld'),
                    '-Wl,--entry=nt3_e820_mbr_start', str(SRC / 'nt3_e820_mbr.S'), '-o', str(elf)],
                   env=env, check=True)
    subprocess.run([zig, 'objcopy', '-O', 'binary', '-j', '.hook', str(elf), str(hook)], env=env, check=True)
    return hook.read_bytes()


class Nt3E820Hook(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.hook = build_hook()
        assert len(cls.hook) <= 502, len(cls.hook)

    def e820(self, base, length, kind):
        """One INT 15h E820 call through the hook; the firmware returns
        (base, length, kind).  Returns the entry the caller sees and CF."""
        u = Uc(UC_ARCH_X86, UC_MODE_16)
        u.mem_map(0, 0x100000)
        code = bytearray(self.hook)
        # The old INT 15h vector sits right behind the resident code (OLD15).
        code += struct.pack('<HH', BIOS & 0xFFFF, BIOS >> 4) + struct.pack('<HH', 0, 0)
        u.mem_write(HOOK_SEG << 4, bytes(code))
        u.mem_write(BIOS, b'\xcf')                         # iret
        u.mem_write(RET_IP, b'\xf4')                       # hlt after the hook's iret
        # Caller frame of INT 15h: IP, CS, FLAGS (CF set to see it cleared).
        sp = STACK - 6
        u.mem_write(sp, struct.pack('<HHH', RET_IP, RET_CS, 0x0203))
        u.reg_write(UC_X86_REG_SS, 0)
        u.reg_write(UC_X86_REG_SP, sp)
        u.reg_write(UC_X86_REG_CS, HOOK_SEG)
        u.reg_write(UC_X86_REG_ES, 0)
        u.reg_write(UC_X86_REG_DI, BUF)
        u.reg_write(UC_X86_REG_EAX, 0xE820)
        u.reg_write(UC_X86_REG_ECX, 20)
        u.reg_write(UC_X86_REG_EDX, 0x534D4150)
        u.reg_write(UC_X86_REG_EBX, 0)

        def firmware(uc, address, size, data):
            if address != BIOS:
                return
            uc.mem_write(BUF, struct.pack('<QQI', base, length, kind))
            uc.reg_write(UC_X86_REG_EAX, 0x534D4150)
            sp = uc.reg_read(UC_X86_REG_SP)
            flags = struct.unpack('<H', uc.mem_read(sp + 4, 2))[0]
            uc.mem_write(sp + 4, struct.pack('<H', flags & ~1))
        u.hook_add(UC_HOOK_CODE, firmware)
        u.emu_start(HOOK_SEG << 4, RET_IP, count=2000)
        self.assertEqual(u.reg_read(UC_X86_REG_SP), STACK, 'hook did not return through IRET')
        flags = struct.unpack('<H', u.mem_read(STACK - 2, 2))[0]
        return struct.unpack('<QQI', u.mem_read(BUF, 20)), flags & 1

    def test_csmwrap_legacy_window_becomes_rom_copy(self):
        # CSMWrap: A0000h, 60000h, reserved -> F0000h, 10000h, reserved.
        self.assertEqual(self.e820(0xA0000, 0x60000, 2), ((0xF0000, 0x10000, 2), 0))

    def test_ebda_and_seabios_rom_entries(self):
        self.assertEqual(self.e820(0x9FC00, 0x400, 2), ((0x9FC00, 0x400, 2), 0))
        self.assertEqual(self.e820(0xF0000, 0x10000, 2), ((0xF0000, 0x10000, 2), 0))
        # A reserved entry that starts in the EBDA but runs into the VGA window.
        self.assertEqual(self.e820(0x9F000, 0x61000, 2), ((0xF0000, 0x10000, 2), 0))

    def test_high_non_ram_and_ram_unchanged_rules(self):
        self.assertEqual(self.e820(0xFEC00000, 0x1000, 2), ((0xF0000, 0x10000, 2), 0))
        self.assertEqual(self.e820(0x1_0000_0000, 0x8000_0000, 1), ((0xF0000, 0x10000, 2), 0))
        self.assertEqual(self.e820(0x100000, 0x3FF00000, 1), ((0x100000, 0x3FF00000, 1), 0))
        # The RAM entry at 0 ends below the hook (HOOK_SEG:0000).
        self.assertEqual(self.e820(0, 0x9FC00, 1), ((0, HOOK_SEG << 4, 1), 0))
        # RAM clipped at 4 GiB.
        self.assertEqual(self.e820(0xC0000000, 0x80000000, 1), ((0xC0000000, 0x40000000, 1), 0))


if __name__ == '__main__':
    unittest.main()
