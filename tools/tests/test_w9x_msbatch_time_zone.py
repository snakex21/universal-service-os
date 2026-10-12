"""The USOS default MSBATCH.INF gets the menu language's 9x time zone
(request.ini timezone=, tools/w9x_csmwrap_prepare.sh w9x_msbatch_time_zone),
so Setup's Date/Time page does not wait for a click. Host only (Git sh)."""
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_w9x_phase1_qemu import sh

ROOT = Path(__file__).resolve().parents[2]
PREPARE = (ROOT / 'tools/w9x_csmwrap_prepare.sh').as_posix()
DEFAULT = ROOT / 'src/platform/bios/win9x/msbatch.inf'


class MsbatchTimeZone(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='usos-w9x-tz-'))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.inf = self.tmp / 'MSBATCH.INF'
        self.inf.write_bytes(DEFAULT.read_bytes().replace(b'\r\n', b'\n').replace(b'\n', b'\r\n'))

    def run_tz(self, zone):
        script = f'. "{PREPARE}"\nw9x_msbatch_time_zone "$TZ_VALUE" "{self.inf.as_posix()}"'
        rc, out, err = sh(script, {'TZ_VALUE': zone})
        self.assertEqual(rc, 0, err)
        return self.inf.read_bytes()

    def test_zone_goes_right_after_setup(self):
        # Git's awk on Windows drops the CRs of the input lines; busybox awk
        # in the micro-Linux keeps them. The inserted line is always CRLF.
        text = self.run_tz('Central European')
        self.assertIn(b'TimeZone="Central European"\r\n', text)
        lines = text.replace(b'\r\n', b'\n').split(b'\n')
        at = lines.index(b'[Setup]')
        self.assertEqual(lines[at + 1:at + 3], [b'TimeZone="Central European"', b'Express=1'])
        self.assertEqual(text.count(b'TimeZone='), 1)

    def test_no_or_unsafe_zone_leaves_the_file(self):
        before = self.inf.read_bytes()
        self.assertEqual(self.run_tz(''), before)
        self.assertEqual(self.run_tz('a"b'), before)
        self.assertEqual(self.run_tz('x;rm'), before)

    def release_zone(self, tag, zone):
        script = f'. "{PREPARE}"\nw9x_release_time_zone "$TAG" "$TZ_VALUE"'
        rc, out, err = sh(script, {'TAG': tag, 'TZ_VALUE': zone})
        self.assertEqual(rc, 0, err)
        return out

    def test_windows_98_has_no_pacific_sa(self):
        # The Windows 98 CD's TIMEZONE.INF lacks only "Pacific SA" (98 SE added it).
        self.assertEqual(self.release_zone('98', 'Pacific SA'), '')
        self.assertEqual(self.release_zone('98SE', 'Pacific SA'), 'Pacific SA')
        self.assertEqual(self.release_zone('98', 'Central European'), 'Central European')
        self.assertEqual(self.release_zone('98', ''), '')
        none = Path(PREPARE).read_text(encoding='utf-8')
        self.assertIn('time_zone=$(w9x_release_time_zone "$tag" "$time_zone")', none)

    def test_windows_95_names_and_the_renderer_table_agree(self):
        self.assertEqual(self.release_zone('95', 'Central European'), 'Warsaw')
        self.assertEqual(self.release_zone('95', 'Central Europe'), 'Prague Bratislava')
        self.assertEqual(self.release_zone('95', 'Eastern'), 'Eastern')
        self.assertEqual(self.release_zone('95', 'GTB'), '')
        self.assertEqual(self.release_zone('95', 'Pacific SA'), '')
        # The same table as src/flow/answer/msbatch.zig timeZoneName95, for
        # every key the menu can produce (windows98_zones).
        import re
        zig = (ROOT / 'src/flow/answer/msbatch.zig').read_text(encoding='utf-8')
        fn = zig[zig.index('pub fn timeZoneName95'):zig.index('const windows95_zones')]
        renamed = dict(re.findall(r'\.\{ "([^"]+)", "([^"]+)" \}', fn))
        same = zig[zig.index('const windows95_zones'):]
        same = re.findall(r'"([^"]+)"', same[:same.index('};')])
        menu = zig[zig.index('const windows98_zones'):]
        menu = re.findall(r'"([^"]+)"', menu[:menu.index('};')])
        self.assertEqual(len(renamed), 5)
        for name in menu:
            expected = renamed.get(name, name if name in same else '')
            self.assertEqual(self.release_zone('95', name), expected, name)

    def test_prepare_uses_it_only_for_the_default_answer(self):
        text = Path(PREPARE).read_text(encoding='utf-8')
        # The 9x answer switch; the POSReady and NT switches above it have
        # their own none) / profile) arms.
        begin = text.index('\n        none)', text.index('        nt4|posr) ;;'))
        none = text[begin:text.index('\n        profile)', begin)]
        self.assertIn('w9x_csmwrap_value timezone "$request"', none)
        self.assertIn('w9x_msbatch_time_zone "$time_zone" "$answer_inf"', none)
        # The default file itself stays without a zone (BIOS mode, other languages).
        self.assertNotIn(b'TimeZone', DEFAULT.read_bytes())


if __name__ == '__main__':
    unittest.main()
