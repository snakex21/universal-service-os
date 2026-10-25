"""Every staged dos-native file reaches the stick.

The staged lists (build_win9x_support.STAGED, build_dos_network.NET_FILES,
build_win16_winsock.PAYLOAD_FILES, the Legacy Core's win9x_helpers in
src/platform/bios/dos_native_iso.zig and the hard requirements of the 9x
prep scripts tools/w9x_*.sh) must all be in the installer payload list
(installer/cmd/usos-payload-pack/main.go) and, for win9x, in the release
check (tools/verify_release_consistency.ps1). Regression: Windows 95 RTM
(4.00.950) prep stopped at w9x_csmwrap_target.sh because VESBIND.EXE was
built and staged but never packed (2026-10-25).

When a build output exists (zig-out/dos-native), every file there must be
packed or listed in INTENTIONALLY_UNPACKED with the reason. Host only.
Run: python tools/tests/test_dos_native_payload_lists.py
"""
from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import build_dos_network  # noqa: E402
import build_win16_winsock  # noqa: E402
import build_win9x_support  # noqa: E402

GO = (ROOT / 'installer/cmd/usos-payload-pack/main.go').read_text(encoding='utf-8')
PS1 = (ROOT / 'tools/verify_release_consistency.ps1').read_text(encoding='utf-8-sig')
ZIG_OUT = ROOT / 'zig-out/dos-native'

# Built into zig-out/dos-native but deliberately not on the stick.
INTENTIONALLY_UNPACKED = {
    # "Also built, not staged (copied by hand)" (build_win9x_support.py
    # docstring): hardware experiments, no script or menu on the target uses
    # the win9x copies. The Windows 3.x flow uses its own msdos copies of
    # USOSV10 / USOSVGAR / USOSWHER (packed under dos-native/msdos).
    'win9x/USOSHPET.COM': 'HPET LegacyReplacement experiment, copied by hand',
    'win9x/USOSV10.COM': 'INT 10h TSR experiment, copied by hand (msdos copy is packed)',
    'win9x/USOSVGAR.COM': 'VGA redraw TSR experiment, copied by hand (msdos copy is packed)',
    'win9x/USOSWHERE.COM': 'CS:IP TSR experiment, copied by hand (msdos USOSWHER.COM is packed)',
    # Build inputs: build_win9x_support copies them (BRIDGE) into win9x,
    # which is the packed copy; no MS-DOS / Windows 3.x script loads them.
    'msdos/USOSMOUS.DRV': 'build input of win9x/USOSMOUS.DRV (packed there)',
    'msdos/USOSVMD.VXD': 'build input of win9x/USOSVMD.VXD (packed there)',
}


def packed():
    pairs = re.findall(r'\{`zig-out/dos-native/([^`]+)`, `EFI/USOS/dos-native/([^`]+)`\}', GO)
    for source, target in pairs:
        assert source == target, (source, target)
    return {source for source, _ in pairs}


PACKED = packed()


class DosNativePayloadListTest(unittest.TestCase):
    def assert_packed(self, folder, names):
        missing = sorted(n for n in names if f'{folder}/{n}' not in PACKED)
        self.assertEqual(missing, [], f'dos-native/{folder} files missing from usos-payload-pack')

    def test_win9x_staged_is_packed_and_release_checked(self):
        self.assert_packed('win9x', build_win9x_support.STAGED)
        unchecked = sorted(n for n in build_win9x_support.STAGED
                           if f"'EFI/USOS/dos-native/win9x/{n}'" not in PS1)
        self.assertEqual(unchecked, [], 'win9x files missing from verify_release_consistency.ps1')

    def test_vesbind_regression(self):
        self.assertIn('VESBIND.EXE', build_win9x_support.STAGED)
        self.assertTrue('win9x/VESBIND.EXE' in PACKED, 'VESBIND.EXE not packed')
        self.assertIn("'EFI/USOS/dos-native/win9x/VESBIND.EXE'", PS1)

    def test_grpconv_watchdog_is_built_packed_and_release_checked(self):
        self.assertIn('USOSGRPW.EXE',build_win9x_support.STAGED)
        self.assertIn('win9x/USOSGRPW.EXE',PACKED)
        self.assertIn("'EFI/USOS/dos-native/win9x/USOSGRPW.EXE'",PS1)
        build=(ROOT/'tools/build_win9x_support.py').read_text(encoding='utf-8')
        self.assertIn('build_grpwatch(out)',build)

    def test_legacy_core_win9x_helpers_are_packed(self):
        zig = (ROOT / 'src/platform/bios/dos_native_iso.zig').read_text(encoding='utf-8')
        block = re.search(r'const win9x_helpers = \[_\]\[\]const u8\{([^}]*)\}', zig).group(1)
        names = re.findall(r'"([^"]+)"', block)
        self.assertIn('USOSLAN.EXE', names)
        self.assertEqual(sorted(set(names) - set(build_win9x_support.STAGED)), [])
        self.assert_packed('win9x', names)

    def test_msdos_network_is_packed(self):
        self.assert_packed('msdos', build_dos_network.NET_FILES)

    def test_winsock16_is_packed(self):
        self.assert_packed('winsock16', build_win16_winsock.PAYLOAD_FILES)

    def test_w9x_script_hard_requirements_are_packed(self):
        # "$HELPERS/X" (the ESP copy) and [ -f "$dir/X" ] || return 1 / fail
        # on C:\USOS9X before the scripts generate anything there.
        found = set()
        for script in sorted((ROOT / 'tools').glob('w9x_*.sh')):
            text = script.read_text(encoding='utf-8')
            found.update(re.findall(r'"\$HELPERS/([A-Z0-9_]+\.[A-Z0-9]+)"', text))
            found.update(re.findall(
                r'\[ -[fr] "\$dir/([A-Z0-9_]+\.[A-Z0-9]+)" \] \|\| (?:return 1|fail)', text))
        self.assertTrue({'U9FIX.COM', 'USOSKEY.DRV', 'VESBIND.EXE'} <= found, found)
        self.assert_packed('win9x', found)

    def test_unpacked_whitelist_is_really_unpacked_and_unstaged(self):
        for path in INTENTIONALLY_UNPACKED:
            self.assertNotIn(path, PACKED)
            folder, name = path.split('/')
            if folder == 'win9x':
                self.assertNotIn(name, build_win9x_support.STAGED)
        doc = build_win9x_support.__doc__
        notstaged = doc[doc.index('Also built, not staged'):]
        for name in ('USOSHPET.COM', 'USOSWHERE.COM', 'USOSV10.COM'):
            self.assertIn(name, notstaged)

    @unittest.skipUnless(ZIG_OUT.is_dir(), 'no zig-out/dos-native build output')
    def test_every_built_file_is_packed_or_whitelisted(self):
        stray = []
        for folder in ('win9x', 'msdos', 'freedos', 'winsock16', 'ram-patch', 'i18n'):
            directory = ZIG_OUT / folder
            if not directory.is_dir():
                continue
            for entry in sorted(directory.iterdir()):
                path = f'{folder}/{entry.name}'
                if entry.is_file() and path not in PACKED and path not in INTENTIONALLY_UNPACKED:
                    stray.append(path)
        self.assertEqual(stray, [], 'built but neither packed nor in INTENTIONALLY_UNPACKED')


if __name__ == '__main__':
    unittest.main()
