"""Execute the NT 3.x MBR's resident INT 15h E820 filter (sector 1 hook).

CSMWrap reports A0000-FFFFF as one reserved E820 entry (plain SeaBIOS only
F0000-FFFFF).  The NT 3.51 SETUPLDR / NTLDR turn every entry into a loader
memory descriptor; the A0000 one overlapped the VGA window, vga.sys could not
claim A0000-BFFFF and text-mode Setup stopped "while initializing your
computer's video" (0, C0000034) on the X470 (B261028-173747) and in QEMU
OVMF + CSMWrap.  The hook must hand out only non-RAM entries that end at or
below A0000h unchanged; every other non-RAM entry becomes F0000-FFFFF.

RAM cap (hook sector byte 508, 16 MiB units): native NT 3.5 loses the boot
disk above 128 MiB (docs/nt35-2026-10-09.md) and its SETUPLDR ignores
/MAXMEM, so E820 RAM and the AH=88h / AX=E801h sizes end at the cap.
Native NT 3.51 gets a 1024 MiB cap (STOP 0x0A on 3 GB in GUI Setup).
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
RAM_CAP_OFF = 508          # nt3_e820_mbr.S HOOK_RAM_CAP
MIB = 1 << 20
# A CSMWrap-like map of a 32 GiB PC (X470 shape).
BIG_MAP = [(0, 0x9FC00, 1), (0x9FC00, 0x400, 2), (0xA0000, 0x60000, 2),
           (0x100000, 0x700000, 1), (0x800000, 0x8000, 4), (0x808000, 0xBE7F8000, 1),
           (0xBF000000, 0x1000000, 2), (0xFEC00000, 0x1000, 2),
           (0x1_0000_0000, 0x7_4000_0000, 1)]


# The firmware map the MBR recorded on the X470 (disk sector 2, CSMWrap,
# 32 GiB, cold boot B261029-185936; identical below 1 GiB in every dump of
# 2026-10-29; the small MMIO entries at FD2xxxxx-FEBxxxxx are left out and the
# entry above 4 GiB is assumed: the record holds 25 entries).  Reserved / ACPI
# NVS ranges sit at 155-176 MiB.
X470_MAP = [(0, 0x9FC00, 1), (0x9FC00, 0x60400, 2), (0x100000, 0x9AFF000, 1),
            (0x9BFF000, 0x401000, 2), (0xA000000, 0x200000, 1), (0xA200000, 0xE000, 4),
            (0xA20E000, 0xDF2000, 1), (0xB000000, 0x20000, 2), (0xB020000, 0xAB451000, 1),
            (0xB6471000, 0x200000, 2), (0xB6671000, 0x1D1000, 1), (0xB6842000, 0x2F000, 2),
            (0xB6871000, 0x4978000, 1), (0xBB1E9000, 0x176B000, 2), (0xBC954000, 0x4D000, 3),
            (0xBC9A1000, 0x6E0000, 4), (0xBD081000, 0xB7E000, 2), (0xBDBFF000, 0x1401000, 1),
            (0xBF000000, 0x1000000, 2), (0xF0000000, 0x8000000, 2), (0xFEC10000, 0x1000, 2),
            (0x1_0000_0000, 0x7_4000_0000, 1)]


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
        # Code + the two old vectors stay below the RAM cap byte (508).
        assert len(cls.hook) + 8 <= RAM_CAP_OFF, len(cls.hook)

    def load(self, cap):
        u = Uc(UC_ARCH_X86, UC_MODE_16)
        u.mem_map(0, 0x100000)
        code = bytearray(512)
        code[:len(self.hook)] = self.hook
        # The old INT 15h vector sits right behind the resident code (OLD15).
        code[len(self.hook):len(self.hook) + 8] = struct.pack('<HHHH', BIOS & 0xFFFF, BIOS >> 4, 0, 0)
        code[RAM_CAP_OFF] = cap
        code[510:] = b'U3'
        u.mem_write(HOOK_SEG << 4, bytes(code))
        return u

    def e820(self, base, length, kind, cap=0):
        """One INT 15h E820 call through the hook; the firmware returns
        (base, length, kind).  Returns the entry the caller sees and CF."""
        u = self.load(cap)
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

    def old_sizes(self, function, memory_map, cap=0):
        """INT 15h AH=88h (function 0x8800) or AX=E801h through the hook; the
        firmware answers E801h (AX=CX=KiB 1-16 MiB, BX=DX=a dummy the hook
        must replace) and E820h from memory_map.  Returns (AX, BX, CX, DX, CF)."""
        u = self.load(cap)
        u.mem_write(BIOS, b'\xcf')
        u.mem_write(RET_IP, b'\xf4')
        sp = STACK - 6
        u.mem_write(sp, struct.pack('<HHH', RET_IP, RET_CS, 0x0203))
        u.reg_write(UC_X86_REG_SS, 0)
        u.reg_write(UC_X86_REG_SP, sp)
        u.reg_write(UC_X86_REG_CS, HOOK_SEG)
        u.reg_write(UC_X86_REG_EAX, function)
        for reg in (UC_X86_REG_EBX, UC_X86_REG_ECX, UC_X86_REG_EDX):
            u.reg_write(reg, 0)

        def firmware(uc, address, size, data):
            if address != BIOS:
                return
            eax = uc.reg_read(UC_X86_REG_EAX)
            sp = uc.reg_read(UC_X86_REG_SP)
            flags = struct.unpack('<H', uc.mem_read(sp + 4, 2))[0] & ~1
            if eax & 0xFFFF == 0xE801:
                uc.reg_write(UC_X86_REG_EAX, 0x3C00)
                uc.reg_write(UC_X86_REG_ECX, 0x3C00)
                uc.reg_write(UC_X86_REG_EBX, 0x1234)
                uc.reg_write(UC_X86_REG_EDX, 0x1234)
            elif eax == 0xE820:
                index = uc.reg_read(UC_X86_REG_EBX)
                es = uc.reg_read(UC_X86_REG_ES)
                di = uc.reg_read(UC_X86_REG_DI)
                uc.mem_write((es << 4) + di, struct.pack('<QQI', *memory_map[index]))
                uc.reg_write(UC_X86_REG_EAX, 0x534D4150)
                uc.reg_write(UC_X86_REG_EBX, 0 if index + 1 == len(memory_map) else index + 1)
            else:
                uc.reg_write(UC_X86_REG_EAX, 0x3FC0)     # AH=88h: 63 MiB
            uc.mem_write(sp + 4, struct.pack('<H', flags))
        u.hook_add(UC_HOOK_CODE, firmware)
        u.emu_start(HOOK_SEG << 4, RET_IP, count=20000)
        self.assertEqual(u.reg_read(UC_X86_REG_SP), STACK, 'hook did not return through IRET')
        flags = struct.unpack('<H', u.mem_read(STACK - 2, 2))[0]
        regs = [u.reg_read(r) & 0xFFFF for r in (UC_X86_REG_EAX, UC_X86_REG_EBX, UC_X86_REG_ECX, UC_X86_REG_EDX)]
        return (*regs, flags & 1)

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

    def test_ram_cap_e820(self):
        cap = 8                                  # 128 MiB (native NT 3.5)
        top = 128 * MIB
        # The X470-shaped map with the cap: no RAM byte above 128 MiB.
        seen = [self.e820(*entry, cap=cap)[0] for entry in BIG_MAP]
        self.assertEqual(seen[3], (0x100000, 0x700000, 1))
        self.assertEqual(seen[5], (0x808000, top - 0x808000, 1))
        self.assertEqual(seen[8], (0xF0000, 0x10000, 2))
        self.assertEqual(max(b + n for b, n, k in seen if k == 1), top)
        # An entry starting at the cap or above becomes the ROM copy.
        self.assertEqual(self.e820(top, 0x1000000, 1, cap=cap), ((0xF0000, 0x10000, 2), 0))
        self.assertEqual(self.e820(0xC0000000, 0x80000000, 1, cap=cap), ((0xF0000, 0x10000, 2), 0))
        # An entry ending at or below the cap is unchanged.
        self.assertEqual(self.e820(0x100000, top - 0x100000, 1, cap=cap), ((0x100000, top - 0x100000, 1), 0))
        self.assertEqual(self.e820(0x100000, 0x3F00000, 1, cap=cap), ((0x100000, 0x3F00000, 1), 0))
        # The low entry still ends below the hook; non-RAM rules unchanged.
        self.assertEqual(self.e820(0, 0x9FC00, 1, cap=cap), ((0, HOOK_SEG << 4, 1), 0))
        self.assertEqual(self.e820(0xA0000, 0x60000, 2, cap=cap), ((0xF0000, 0x10000, 2), 0))
        self.assertEqual(self.e820(0x9FC00, 0x400, 2, cap=cap), ((0x9FC00, 0x400, 2), 0))

    def test_ram_cap_1024_nt351(self):
        cap = 64                                 # 1024 MiB (native NT 3.51)
        top = 1024 * MIB
        seen = [self.e820(*entry, cap=cap)[0] for entry in BIG_MAP]
        self.assertEqual(seen[3], (0x100000, 0x700000, 1))
        self.assertEqual(seen[5], (0x808000, top - 0x808000, 1))
        self.assertEqual(max(b + n for b, n, k in seen if k == 1), top)
        self.assertEqual(self.e820(0xC0000000, 0x80000000, 1, cap=cap), ((0xF0000, 0x10000, 2), 0))
        # (1024 - 16) MiB / 64 KiB = 0x3F00 blocks above 16 MiB.
        ax, bx, cx, dx, cf = self.old_sizes(0xE801, BIG_MAP, cap=cap)
        self.assertEqual((ax, bx, cx, dx, cf), (0x3C00, 0x3F00, 0x3C00, 0x3F00, 0))
        ax, bx, cx, dx, cf = self.old_sizes(0x8800, BIG_MAP, cap=cap)
        self.assertEqual((ax, cf), (0x3C00, 0))

    def test_no_cap_keeps_nt4_behaviour(self):
        # Byte 508 = 0 (NT 4.0, VM path): RAM up to 4 GiB as before.
        seen = [self.e820(*entry)[0] for entry in BIG_MAP]
        self.assertEqual(seen[5], (0x808000, 0xBE7F8000, 1))
        self.assertEqual(seen[3], (0x100000, 0x700000, 1))

    def test_old_sizes_without_cap(self):
        # E801h: BX/DX = the E820 RAM entry over 16 MiB up to its end.
        ax, bx, cx, dx, cf = self.old_sizes(0xE801, BIG_MAP)
        self.assertEqual((ax, cx, cf), (0x3C00, 0x3C00, 0))
        self.assertEqual(bx, (0xBF000000 - 16 * MIB) >> 16)
        self.assertEqual(dx, bx)
        ax, bx, cx, dx, cf = self.old_sizes(0x8800, BIG_MAP)
        self.assertEqual((ax, cf), (0x3C00, 0))

    def test_old_sizes_with_cap(self):
        # 128 MiB cap: (128 - 16) MiB / 64 KiB = 0x700 blocks above 16 MiB.
        ax, bx, cx, dx, cf = self.old_sizes(0xE801, BIG_MAP, cap=8)
        self.assertEqual((ax, bx, cx, dx, cf), (0x3C00, 0x700, 0x3C00, 0x700, 0))
        ax, bx, cx, dx, cf = self.old_sizes(0x8800, BIG_MAP, cap=8)
        self.assertEqual((ax, cf), (0x3C00, 0))
        # Less RAM than the cap: unchanged (64 MiB machine -> 48 MiB above 16).
        small = [(0, 0x9FC00, 1), (0x100000, 0x3F00000, 1)]
        ax, bx, cx, dx, cf = self.old_sizes(0xE801, small, cap=8)
        self.assertEqual((bx, dx), (0x300, 0x300))
        # A 16 MiB cap: nothing above 16 MiB.
        ax, bx, cx, dx, cf = self.old_sizes(0xE801, BIG_MAP, cap=1)
        self.assertEqual((bx, dx), (0, 0))


    def test_x470_map_nt351_no_reserved_range(self):
        # The NT 3.51 SU module (same as the 3.5 one) makes its free memory
        # list from E820 type 1 entries only; AH=88h / AX=E801h are its
        # fallback.  With the 1 GiB cap no RAM it sees may touch a firmware
        # reserved / NVS range of the real X470 map.
        cap = 64
        firmware_ram = [(b, b + n) for b, n, k in X470_MAP if k == 1]
        seen = [self.e820(*entry, cap=cap)[0] for entry in X470_MAP]
        ram = [(b, b + n) for b, n, k in seen if k == 1]
        self.assertEqual(ram, [(0, HOOK_SEG << 4), (0x100000, 0x9BFF000), (0xA000000, 0xA200000),
                               (0xA20E000, 0xB000000), (0xB020000, 1024 * MIB)])
        for b, e in ram:
            self.assertTrue(any(fb <= b and e <= fe for fb, fe in firmware_ram), hex(b))
        for b, n, k in seen:
            if k != 1:
                self.assertIn((b, n), [(0xF0000, 0x10000), (0x9FC00, 0x60400)])
        # The fallback ends at the first hole (9BFF000h), below the cap.
        ax, bx, cx, dx, cf = self.old_sizes(0xE801, X470_MAP, cap=cap)
        self.assertEqual((bx, dx, cf), (0x8BF, 0x8BF, 0))
        self.assertLessEqual(16 * MIB + (bx << 16), 0x9BFF000)

if __name__ == '__main__':
    unittest.main()
