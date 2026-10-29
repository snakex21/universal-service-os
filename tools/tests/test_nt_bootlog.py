"""NT pre-boot logger (tools/nt_bootlog) and the usosrst 1.8-nt351 RAM marker:
host unit tests of the decoder and the layout both sides share. No VM."""
import os
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DECODE = ROOT / 'tools/nt_bootlog/decode.zig'
USOSRST = ROOT / 'tools/w2k/usosrst/src/usosrst.c'


class NtBootlog(unittest.TestCase):
    def test_decoder_unit_tests(self):
        env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(ROOT / 'tools/cache/zig-global'))
        run = subprocess.run([str(ROOT / 'tools/zig/zig.exe'), 'test', str(DECODE)], env=env,
                             capture_output=True, text=True, timeout=110)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_marker_layout_matches_usosrst(self):
        zig = DECODE.read_text(encoding='utf-8')
        c = USOSRST.read_text(encoding='latin-1')
        self.assertIn('pub const marker_address: u64 = 0x5000_0000;', zig)
        self.assertIn('#define RM_ADDRESS      0x50000000UL', c)
        offsets = {k: int(v) for k, v in re.findall(r'pub const (off_\w+) = (\d+);', zig)}
        self.assertEqual(offsets['off_nt'], 0x40)
        self.assertEqual(offsets['off_nt_boot'], 0x48)
        self.assertEqual(offsets['off_nt_count'], 0x4C)
        self.assertEqual(offsets['off_nt_stages'], 0x50)
        self.assertEqual(offsets['off_nt_bugchecks'], 0x90)
        self.assertEqual(offsets['off_nt_bugcheck_data'], 0x94)
        self.assertEqual(offsets['off_nt_seconds'], 0xA8)
        for needle in ('g_Rm[0x50 + i]', '(g_Rm + 0x4C)', '(g_Rm + 0xA8)', '(g_Rm + 0x90)',
                       '(g_Rm + 0x94 + 4 * i)', '(page + 0x48) = boot'):
            self.assertIn(needle, c)
        # "USOSPRE1" / "USOSNT35" as the little-endian words usosrst compares.
        self.assertIn('0x%08XUL' % int.from_bytes(b'USOS', 'little'), c)
        self.assertIn('0x%08XUL' % int.from_bytes(b'PRE1', 'little'), c)
        self.assertIn('0x%08XUL' % int.from_bytes(b'NT35', 'little'), c)
        self.assertIn('pre_signature = "USOSPRE1"', zig)
        self.assertIn('nt_signature = "USOSNT35"', zig)

    def test_marker_is_above_nt351_maxmem(self):
        # The page must stay outside what NT 3.51 uses: BOOT.INI /MAXMEM=1024.
        self.assertGreaterEqual(0x50000000, 1024 << 20)
        target = (ROOT / 'tools/nt4_csmwrap_target.sh').read_text(encoding='utf-8')
        self.assertIn('/MAXMEM=1024', target)

    def test_logger_chainloads_csmwrap_next_to_its_ini(self):
        main = (ROOT / 'tools/nt_bootlog/main.zig').read_text(encoding='utf-8')
        self.assertIn('wide("\\\\EFI\\\\BOOT\\\\CSMWRAPX.EFI")', main)
        self.assertIn('wide("\\\\USOS\\\\BOOTLOG.TXT")', main)
        self.assertNotIn('con_out', main)          # silent
        self.assertNotIn('readKeyStroke', main)    # no key presses


if __name__ == '__main__':
    unittest.main()
