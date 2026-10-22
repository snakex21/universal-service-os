"""USOSKEY.DRV scan code translation (src/platform/win3/usoskey_xlat.h),
compiled for the host with zig cc and fed the byte sequences SeaBIOS
(CSMWrap 3.1.2, src/hw/usb-hid.c) produces for a USB keyboard."""
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[3]
import sys
sys.path.insert(0, str(ROOT / 'tools/tests'))
import depguard
HEADER = ROOT / 'src/platform/win3/usoskey_xlat.h'

HARNESS = r'''
#include <stdio.h>
#include <stdlib.h>
typedef unsigned char BYTE;
typedef unsigned short WORD;
static int quiet;
static void xlat_event(WORD ax, WORD bx) { if (!quiet) printf("%c%02X:%02X%s\n", ax & 0x8000 ? 'u' : 'd', ax & 0xFF, bx & 0xFF, bx & 0x100 ? "x" : ""); }
static void xlat_cad(void) { if (!quiet) printf("CAD\n"); }
#include "usoskey_xlat.h"
/* argv[1]: "0"/"1" events (NumLock off/on); "f" BIOS flags after every byte
 * (start 00/00/00); "F" the same with the kept bits set (80/8C/F3) and the
 * lock toggles taken from 0040:0017 = 70h. */
int main(int argc, char **argv)
{
    int i;
    char mode = argc > 1 ? argv[1][0] : '0';
    BYTE f17 = 0, f18 = 0, f96 = 0;
    translate_init(mode == '1');
    if (mode == 'F') { f17 = 0xF0; f18 = 0x8C; f96 = 0xF3; translate_set_locks(f17); }
    quiet = mode == 'f' || mode == 'F';
    for (i = 2; i < argc; i++) {
        translate((BYTE)strtoul(argv[i], 0, 16));
        if (quiet) { bios_shift_flags(&f17, &f18, &f96); printf("%02X.%02X.%02X\n", f17, f18, f96); }
    }
    return 0;
}
'''

VK_LWIN, VK_RWIN, VK_APPS = 0x5B, 0x5C, 0x5D


def ev(vk, up=False, scan=None, ext=False):
    return '%s%02X:%02X%s' % ('u' if up else 'd', vk, scan, 'x' if ext else '')


class UsosKeyXlat(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        depguard.require_zig()
        work = ROOT / 'zig-out/usoskey-xlat-test'
        work.mkdir(parents=True, exist_ok=True)
        (work / 'harness.c').write_text(HARNESS)
        cls.exe = work / 'xlat.exe'
        subprocess.run([str(ROOT / 'tools/zig/zig.exe'), 'cc', '-O1', '-Wall', '-Werror', '-Wno-unused-function',
                        '-I', str(HEADER.parent), str(work / 'harness.c'), '-o', str(cls.exe)],
                       check=True, env={**__import__('os').environ,
                                        'ZIG_GLOBAL_CACHE_DIR': str(ROOT / 'tools/cache/zig-global')})

    def run_bytes(self, data, numlock=False):
        out = subprocess.run([str(self.exe), '1' if numlock else '0'] + ['%02X' % b for b in data],
                             check=True, capture_output=True, text=True).stdout
        return out.split()

    def key(self, data, numlock=False):
        return self.run_bytes(data, numlock)

    def flags(self, data, seeded=False):
        out = subprocess.run([str(self.exe), 'F' if seeded else 'f'] + ['%02X' % b for b in data],
                             check=True, capture_output=True, text=True).stdout
        return out.split()

    def test_extended_keys(self):
        table = {0x1C: 0x0D, 0x1D: 0x11, 0x35: 0x6F, 0x47: 0x24, 0x48: 0x26, 0x49: 0x21, 0x4B: 0x25,
                 0x4D: 0x27, 0x4F: 0x23, 0x50: 0x28, 0x51: 0x22, 0x52: 0x2D, 0x53: 0x2E,
                 0x5B: VK_LWIN, 0x5C: VK_RWIN, 0x5D: VK_APPS, 0x46: 0x03}
        for numlock in (False, True):
            for code, vk in table.items():
                self.assertEqual(self.key([0xE0, code, 0xE0, code | 0x80], numlock),
                                 [ev(vk, False, code, True), ev(vk, True, code, True)], hex(code))

    def test_windows_key_start_menu_and_combos(self):
        # Win alone: make + break (USER opens Start on the break).
        self.assertEqual(self.key([0xE0, 0x5B, 0xE0, 0xDB]), [ev(VK_LWIN, False, 0x5B, True), ev(VK_LWIN, True, 0x5B, True)])
        # Win+R, Win+E, Win+D.
        for letter, scan in (('R', 0x13), ('E', 0x12), ('D', 0x20)):
            self.assertEqual(self.key([0xE0, 0x5B, scan, scan | 0x80, 0xE0, 0xDB]),
                             [ev(VK_LWIN, False, 0x5B, True), ev(ord(letter), False, scan), ev(ord(letter), True, scan),
                              ev(VK_LWIN, True, 0x5B, True)])
        # Ctrl+Esc.
        self.assertEqual(self.key([0x1D, 0x01, 0x81, 0x9D]),
                         [ev(0x11, False, 0x1D), ev(0x1B, False, 0x01), ev(0x1B, True, 0x01), ev(0x11, True, 0x1D)])

    def test_fake_shifts_ignored(self):
        self.assertEqual(self.key([0xE0, 0x2A, 0xE0, 0x48, 0xE0, 0xC8, 0xE0, 0xAA]),
                         [ev(0x26, False, 0x48, True), ev(0x26, True, 0x48, True)])
        self.assertEqual(self.key([0xE0, 0x36, 0xE0, 0xB6]), [])

    def test_altgr_is_ctrl_alt(self):
        # AltGr+A (Polish programmer: a with ogonek).
        self.assertEqual(self.key([0xE0, 0x38, 0x1E, 0x9E, 0xE0, 0xB8]),
                         [ev(0x11, False, 0x1D), ev(0x12, False, 0x38, True), ev(ord('A'), False, 0x1E),
                          ev(ord('A'), True, 0x1E), ev(0x12, True, 0x38, True), ev(0x11, True, 0x1D)])
        # Left Ctrl already down: no emulated Ctrl, the real one stays down.
        self.assertEqual(self.key([0x1D, 0xE0, 0x38, 0xE0, 0xB8, 0x9D]),
                         [ev(0x11, False, 0x1D), ev(0x12, False, 0x38, True), ev(0x12, True, 0x38, True),
                          ev(0x11, True, 0x1D)])
        # Left Alt is a plain Alt.
        self.assertEqual(self.key([0x38, 0xB8]), [ev(0x12, False, 0x38), ev(0x12, True, 0x38)])

    def test_right_ctrl(self):
        self.assertEqual(self.key([0xE0, 0x1D, 0xE0, 0x9D]), [ev(0x11, False, 0x1D, True), ev(0x11, True, 0x1D, True)])

    def test_print_screen_and_sysreq(self):
        self.assertEqual(self.key([0xE0, 0x37, 0xE0, 0xB7]), [ev(0x2C, False, 0, True), ev(0x2C, True, 0, True)])
        # Alt+Print Screen: SeaBIOS sends 54h (SysReq) -> active window.
        self.assertEqual(self.key([0x38, 0x54, 0xD4, 0xB8]),
                         [ev(0x12, False, 0x38), ev(0x2C, False, 1), ev(0x2C, True, 1), ev(0x12, True, 0x38)])

    def test_pause_break_numlock(self):
        self.assertEqual(self.key([0xE1, 0x1D, 0x45, 0xE1, 0x9D, 0xC5]), [ev(0x13, False, 0x45), ev(0x13, True, 0x45)])
        # Real PS/2 order (all on press) gives the same pair.
        self.assertEqual(self.key([0xE1, 0x1D, 0x45, 0xE1, 0x9D, 0xC5, 0x45, 0xC5]),
                         [ev(0x13, False, 0x45), ev(0x13, True, 0x45), ev(0x90, False, 0x45), ev(0x90, True, 0x45)])
        # Ctrl+Pause = Ctrl+Break (E0 46).
        self.assertEqual(self.key([0x1D, 0xE0, 0x46, 0xE0, 0xC6, 0x9D]),
                         [ev(0x11, False, 0x1D), ev(0x03, False, 0x46, True), ev(0x03, True, 0x46, True), ev(0x11, True, 0x1D)])

    def test_lock_keys_one_toggle_per_press(self):
        # Held Caps Lock: SeaBIOS repeats the make; USER must see one press.
        self.assertEqual(self.key([0x3A, 0x3A, 0x3A, 0xBA]), [ev(0x14, False, 0x3A), ev(0x14, True, 0x3A)])
        self.assertEqual(self.key([0x46, 0x46, 0xC6]), [ev(0x91, False, 0x46), ev(0x91, True, 0x46)])
        # NumLock held with repeats toggles once: keypad 7 becomes Home again.
        self.assertEqual(self.key([0x45, 0x45, 0xC5, 0x47, 0xC7], numlock=True),
                         [ev(0x90, False, 0x45), ev(0x90, True, 0x45), ev(0x24, False, 0x47), ev(0x24, True, 0x47)])

    def test_keypad(self):
        self.assertEqual(self.key([0x47, 0xC7, 0x53, 0xD3], numlock=True),
                         [ev(0x67, False, 0x47), ev(0x67, True, 0x47), ev(0x6E, False, 0x53), ev(0x6E, True, 0x53)])
        self.assertEqual(self.key([0x47, 0xC7], numlock=False), [ev(0x24, False, 0x47), ev(0x24, True, 0x47)])
        self.assertEqual(self.key([0x37, 0xB7, 0x4A, 0xCA, 0x4E, 0xCE]),
                         [ev(0x6A, False, 0x37), ev(0x6A, True, 0x37), ev(0x6D, False, 0x4A), ev(0x6D, True, 0x4A),
                          ev(0x6B, False, 0x4E), ev(0x6B, True, 0x4E)])

    def test_ctrl_alt_del(self):
        out = self.key([0x1D, 0x38, 0xE0, 0x53, 0xE0, 0x53, 0xE0, 0xD3, 0xB8, 0x9D])
        self.assertEqual(out, [ev(0x11, False, 0x1D), ev(0x12, False, 0x38), 'CAD', ev(0x12, True, 0x38), ev(0x11, True, 0x1D)])
        # Right Ctrl + right Alt + keypad Del as well.
        out = self.key([0xE0, 0x1D, 0xE0, 0x38, 0x53, 0xD3, 0xE0, 0xB8, 0xE0, 0x9D])
        self.assertIn('CAD', out)
        self.assertNotIn(ev(0x2E, False, 0x53), out)
        # Plain Delete and Ctrl+Delete stay keys.
        self.assertEqual(self.key([0x1D, 0xE0, 0x53, 0xE0, 0xD3, 0x9D]),
                         [ev(0x11, False, 0x1D), ev(0x2E, False, 0x53, True), ev(0x2E, True, 0x53, True), ev(0x11, True, 0x1D)])

    def test_typematic_repeats_keydown(self):
        self.assertEqual(self.key([0x1E, 0x1E, 0x1E, 0x9E]),
                         [ev(ord('A'), False, 0x1E)] * 3 + [ev(ord('A'), True, 0x1E)])

    def test_function_keys(self):
        for i, code in enumerate(list(range(0x3B, 0x45)) + [0x57, 0x58]):
            self.assertEqual(self.key([code, code | 0x80]), [ev(0x70 + i, False, code), ev(0x70 + i, True, code)])

    # --- 2026-10-06 X470 report: Ctrl+letter, F-keys twice, editing keys ---
    CTRLS = (([0x1D], [0x9D], 0x1D, False), ([0xE0, 0x1D], [0xE0, 0x9D], 0x1D, True))

    def test_ctrl_letter_both_ctrls(self):
        for down, up, scan, ext in self.CTRLS:
            for letter, code in (('C', 0x2E), ('V', 0x2F), ('Z', 0x2C), ('X', 0x2D), ('S', 0x1F), ('O', 0x18)):
                self.assertEqual(self.key(down + [code, code | 0x80] + up),
                                 [ev(0x11, False, scan, ext), ev(ord(letter), False, code), ev(ord(letter), True, code),
                                  ev(0x11, True, scan, ext)], (letter, ext))

    def test_ctrl_held_tapping_c(self):
        for down, up, scan, ext in self.CTRLS:
            self.assertEqual(self.key(down + [0x2E, 0xAE] * 3 + up),
                             [ev(0x11, False, scan, ext)] + [ev(ord('C'), False, 0x2E), ev(ord('C'), True, 0x2E)] * 3
                             + [ev(0x11, True, scan, ext)])
        # The next plain key carries no modifier (nothing stuck).
        self.assertEqual(self.key([0x1D, 0x2E, 0xAE, 0x9D, 0x2E, 0xAE])[-2:],
                         [ev(ord('C'), False, 0x2E), ev(ord('C'), True, 0x2E)])

    def test_ctrl_shift_letter(self):
        self.assertEqual(self.key([0x1D, 0x2A, 0x2C, 0xAC, 0xAA, 0x9D]),
                         [ev(0x11, False, 0x1D), ev(0x10, False, 0x2A), ev(ord('Z'), False, 0x2C), ev(ord('Z'), True, 0x2C),
                          ev(0x10, True, 0x2A), ev(0x11, True, 0x1D)])

    def test_function_keys_twice(self):
        for i, code in enumerate(list(range(0x3B, 0x45)) + [0x57, 0x58]):
            pair = [ev(0x70 + i, False, code), ev(0x70 + i, True, code)]
            self.assertEqual(self.key([code, code | 0x80, code, code | 0x80]), pair * 2, hex(code))
        # F5 after a typed letter and after a Ctrl combo still arrives.
        self.assertEqual(self.key([0x3F, 0xBF, 0x1E, 0x9E, 0x1D, 0x2E, 0xAE, 0x9D, 0x3F, 0xBF])[-2:],
                         [ev(0x74, False, 0x3F), ev(0x74, True, 0x3F)])

    def test_alt_tab(self):
        self.assertEqual(self.key([0x38, 0x0F, 0x8F, 0x0F, 0x8F, 0xB8]),
                         [ev(0x12, False, 0x38)] + [ev(0x09, False, 0x0F), ev(0x09, True, 0x0F)] * 2 + [ev(0x12, True, 0x38)])

    def test_shift_and_ctrl_navigation(self):
        nav = {0x48: 0x26, 0x50: 0x28, 0x4B: 0x25, 0x4D: 0x27, 0x47: 0x24, 0x4F: 0x23}
        for numlock in (False, True):
            for code, vk in nav.items():
                for mdown, mup, mvk, mscan in (([0x2A], [0xAA], 0x10, 0x2A), ([0x1D], [0x9D], 0x11, 0x1D)):
                    self.assertEqual(self.key(mdown + [0xE0, code, 0xE0, code | 0x80] + mup, numlock),
                                     [ev(mvk, False, mscan), ev(vk, False, code, True), ev(vk, True, code, True),
                                      ev(mvk, True, mscan)], (hex(code), numlock))

    def test_esc_tab_backspace_enter(self):
        for code, vk in ((0x01, 0x1B), (0x0F, 0x09), (0x0E, 0x08), (0x1C, 0x0D)):
            self.assertEqual(self.key([code, code | 0x80, code, code | 0x80]),
                             [ev(vk, False, code), ev(vk, True, code)] * 2)

    def test_altgr_after_left_ctrl_tap(self):
        out = self.key([0x1D, 0x9D, 0xE0, 0x38, 0x1E, 0x9E, 0xE0, 0xB8])
        self.assertEqual(out, [ev(0x11, False, 0x1D), ev(0x11, True, 0x1D),
                               ev(0x11, False, 0x1D), ev(0x12, False, 0x38, True), ev(ord('A'), False, 0x1E),
                               ev(ord('A'), True, 0x1E), ev(0x12, True, 0x38, True), ev(0x11, True, 0x1D)])
        # Ctrl+C after AltGr: Ctrl down and up exactly once each.
        out = self.key([0xE0, 0x38, 0xE0, 0xB8, 0x1D, 0x2E, 0xAE, 0x9D])
        self.assertEqual(out[4:], [ev(0x11, False, 0x1D), ev(ord('C'), False, 0x2E), ev(ord('C'), True, 0x2E),
                                   ev(0x11, True, 0x1D)])

    def test_ctrl_down_up_balanced_in_mixed_sequences(self):
        seqs = [
            [0xE0, 0x38, 0x1D, 0x9D, 0xE0, 0xB8],          # AltGr, left Ctrl tap inside
            [0x1D, 0xE0, 0x38, 0x9D, 0xE0, 0xB8],          # left Ctrl released before AltGr
            [0xE0, 0x1D, 0xE0, 0x38, 0xE0, 0xB8, 0xE0, 0x9D],
            [0x1D, 0x38, 0xE0, 0x53, 0xE0, 0xD3, 0xB8, 0x9D],
        ]
        for seq in seqs:
            state = 0
            for e in self.key(seq):
                if e.startswith(('d11', 'u11')):
                    state = 1 if e[0] == 'd' else 0
            self.assertEqual(state, 0, seq)

    # --- BIOS shift flags 0040:0017 / 0040:0018 / 0040:0096 ---
    def test_bios_flags_shift_ctrl_alt(self):
        self.assertEqual(self.flags([0x2A, 0xAA]), ['02.00.00', '00.00.00'])
        self.assertEqual(self.flags([0x36, 0xB6]), ['01.00.00', '00.00.00'])
        self.assertEqual(self.flags([0x1D, 0x2E, 0xAE, 0x9D]), ['04.01.00'] * 3 + ['00.00.00'])
        self.assertEqual(self.flags([0xE0, 0x1D, 0xE0, 0x9D]), ['00.00.00', '04.00.04', '04.00.04', '00.00.00'])
        self.assertEqual(self.flags([0x38, 0xB8]), ['08.02.00', '00.00.00'])
        self.assertEqual(self.flags([0xE0, 0x38, 0xE0, 0xB8])[1::2], ['0C.01.08', '00.00.00'])

    def test_bios_flags_both_ctrls(self):
        # Left down, right down, left up: Ctrl still active (right).
        out = self.flags([0x1D, 0xE0, 0x1D, 0x9D, 0xE0, 0x9D])
        self.assertEqual([out[0], out[2], out[3], out[5]], ['04.01.00', '04.01.04', '04.00.04', '00.00.00'])

    def test_bios_flags_locks(self):
        # Caps: toggled on press, "down" bit while held, repeats ignored.
        self.assertEqual(self.flags([0x3A, 0x3A, 0xBA, 0x3A, 0xBA]),
                         ['40.40.00', '40.40.00', '40.00.00', '00.40.00', '00.00.00'])
        self.assertEqual(self.flags([0x45, 0xC5]), ['20.20.00', '20.00.00'])
        self.assertEqual(self.flags([0x46, 0xC6]), ['10.10.00', '10.00.00'])
        # Pause (E1 1D 45) is not NumLock, Ctrl+Break (E0 46) not ScrollLock.
        self.assertEqual(self.flags([0xE1, 0x1D, 0x45, 0xE1, 0x9D, 0xC5])[-1], '00.00.00')
        self.assertEqual(self.flags([0xE0, 0x46, 0xE0, 0xC6])[-1], '00.00.00')

    def test_bios_flags_keep_foreign_bits_and_start_locks(self):
        # Start: Insert on, Scroll/Num/Caps on (70h), SysReq/Pause/Insert-down,
        # E0/E1/101-key bits: all kept; Caps press turns Caps off.
        self.assertEqual(self.flags([0x1E], seeded=True), ['F0.8C.F3'])
        self.assertEqual(self.flags([0x3A, 0xBA, 0x2A], seeded=True), ['B0.CC.F3', 'B0.8C.F3', 'B2.8C.F3'])
        self.assertEqual(self.flags([0xE0, 0x1D], seeded=True)[-1], 'F4.8C.F7')

    def test_bios_flags_numlock_drives_keypad(self):
        # NumLock pressed: the keypad turns into digits like the flag says.
        self.assertEqual(self.key([0x45, 0xC5, 0x47, 0xC7])[2:], [ev(0x67, False, 0x47), ev(0x67, True, 0x47)])


if __name__ == '__main__':
    unittest.main()
