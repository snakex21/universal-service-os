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

    def test_esp_installs_the_logger_only_on_request(self):
        # xp_csmwrap_esp.sh: USOS_NT_BOOTLOG=on puts the pinned logger at
        # \EFI\BOOT\BOOTX64.EFI, CSMWrap at \EFI\BOOT\CSMWRAPX.EFI (what the
        # logger chainloads) and an empty \USOS\BOOTLOG.TXT; otherwise
        # CSMWrap stays BOOTX64.EFI.
        import hashlib
        esp = (ROOT / 'tools/xp_csmwrap_esp.sh').read_text(encoding='utf-8')
        pin = re.search(r'^PINNED_BOOTLOG=([0-9a-f]{64})$', esp, re.M).group(1)
        binary = (ROOT / 'tools/nt_bootlog/bin/ntbootlg.efi').read_bytes()
        self.assertEqual(hashlib.sha256(binary).hexdigest(), pin)
        self.assertEqual(binary[:2], b'MZ')
        self.assertIn('BOOTLOG_EFI=${USOS_NT_BOOTLOG_EFI:-${USOS_LIB_DIR:-/usr/lib/usos}/nt3/NTBOOTLG.EFI}', esp)
        self.assertIn('CSMWRAP_NAME=BOOTX64.EFI\nif [ "${USOS_NT_BOOTLOG:-off}" = on ]; then', esp)
        self.assertEqual(esp.count('CSMWRAP_NAME=CSMWRAPX.EFI'), 1)
        self.assertIn('mcopy -i "$image" "$EFI_INPUT" "::/EFI/BOOT/$CSMWRAP_NAME"', esp)
        self.assertIn('mcopy -i "$image" "$BOOTLOG_EFI" ::/EFI/BOOT/BOOTX64.EFI', esp)
        self.assertIn('mcopy -i "$image" /tmp/csmwrap-bootlog.txt ::/USOS/BOOTLOG.TXT', esp)
        self.assertIn(': > /tmp/csmwrap-bootlog.txt', esp)
        self.assertIn('mcopy -i "$image" "$ini" ::/EFI/BOOT/csmwrap.ini', esp)   # next to CSMWRAPX.EFI
        # Read-back: CSMWrap under its name, the logger and the log file.
        self.assertIn('mcopy -i "$image" "::/EFI/BOOT/$CSMWRAP_NAME" "$readback"', esp)
        self.assertIn('= "$PINNED_BOOTLOG" ] || fail \'read-back: the logger BOOTX64.EFI differs\'', esp)
        self.assertIn("mdir -i \"$image\" ::/USOS/BOOTLOG.TXT >/dev/null 2>&1 || fail 'read-back: USOS/BOOTLOG.TXT missing'", esp)

    def test_only_native_nt3_requests_the_logger(self):
        prepare = (ROOT / 'tools/w9x_csmwrap_prepare.sh').read_text(encoding='utf-8')
        self.assertEqual(prepare.count('USOS_NT_BOOTLOG='), 1)
        native = prepare[prepare.index('if [ -n "$nt4" ] && [ "$nt_native" = yes ]; then\n        # Native (docs/nt-native-plan.md)'):]
        native = native[:native.index('elif [ -n "$nt4" ]; then')]
        self.assertIn('nt_bootlog=off\n        [ "$nt_major" != 3 ] || nt_bootlog=on\n', native)
        self.assertIn('USOS_NT_BOOTLOG=$nt_bootlog sh /usr/lib/usos/xp_csmwrap_esp.sh', native)
        # nt3-native.flag covers 3.51 / 3.5 only; NT 3.1 has no native path.
        self.assertIn('NT351|NT351S|NT35|NT35S) nt_native_flag=nt3-native.flag ;;', prepare)
        for path in (ROOT / 'tools').glob('*.sh'):
            if path.name not in ('w9x_csmwrap_prepare.sh', 'xp_csmwrap_esp.sh'):
                self.assertNotIn('USOS_NT_BOOTLOG', path.read_text(encoding='utf-8', errors='replace'), path.name)
        micro = (ROOT / 'tools/build_micro_linux.py').read_text(encoding='utf-8')
        self.assertIn('("tools/nt_bootlog/bin/ntbootlg.efi", "usr/lib/usos/nt3/NTBOOTLG.EFI"),', micro)


if __name__ == '__main__':
    unittest.main()
