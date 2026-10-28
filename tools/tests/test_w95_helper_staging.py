"""VESBIND.EXE and USOSFB.EXE reach C:\\USOS9X for every native 95 install.

X470 95 OSR2.1 run (2026-10-27): no VESBIND.EXE / USOSFB.EXE in C:\\USOS9X.
tools/w9x_csmwrap_target.sh copies every EFI/USOS/dos-native/win9x helper
unconditionally (950 and OSR2 1068/1111/1212/1214/1216 alike); these checks
keep it that way: both files are built, packed and copied by the top-level
helper loop, and no target script removes them again. Host-only.
"""
from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import build_win9x_support  # noqa: E402

TARGET = (ROOT / 'tools/w9x_csmwrap_target.sh').read_text(encoding='utf-8')
PACK = (ROOT / 'installer/cmd/usos-payload-pack/main.go').read_text(encoding='utf-8')
NAMES = ('VESBIND.EXE', 'USOSFB.EXE')
LOOP = 'for file in "$HELPERS"/*; do'


class W95HelperStaging(unittest.TestCase):
    def test_built_and_packed(self):
        for name in NAMES:
            self.assertIn(name, build_win9x_support.STAGED)
            self.assertIn(f'{{`zig-out/dos-native/win9x/{name}`, `EFI/USOS/dos-native/win9x/{name}`}}', PACK)

    def test_helper_loop_is_unconditional(self):
        self.assertIn('HELPERS="$ESP_DIR/dos-native/win9x"', TARGET)
        self.assertEqual(TARGET.count(LOOP), 1)
        line = next(l for l in TARGET.splitlines() if LOOP in l)
        self.assertTrue(line.startswith(LOOP), 'helper copy loop must be at top level')
        # Between the C: mount and the loop only the setup folder copy runs
        # (its own for/done); no if/case could gate the helpers by version.
        head = TARGET[TARGET.index('mount -t vfat -o shortname=winnt'):TARGET.index(LOOP)]
        self.assertIsNone(re.search(r'^\s*(?:if|case|elif|else)\b', head, re.M), head)
        self.assertEqual(head.count('; do\n'), head.count('\ndone'))
        body = TARGET[TARGET.index(LOOP):TARGET.index('done', TARGET.index(LOOP))]
        self.assertNotIn('950', body)
        self.assertNotIn('SYSTEM_TAG', body)
        self.assertIn('"$work/c/USOS9X/', body)

    def test_nothing_removes_them(self):
        for script in [*sorted((ROOT / 'tools').glob('w9x_*.sh')),
                       ROOT / 'src/platform/bios/dos_startup.cmd']:
            for line in script.read_text(encoding='utf-8').splitlines():
                code = line.split('#', 1)[0] if script.suffix == '.sh' else line
                if re.search(r'\brm\b|^\s*(?:@?IF .*\s)?DEL\s', code, re.I):
                    for name in NAMES:
                        self.assertNotIn(name, code.upper(), f'{script.name}: {line.strip()}')


if __name__ == '__main__':
    unittest.main()
