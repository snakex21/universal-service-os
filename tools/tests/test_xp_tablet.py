"""Windows XP Tablet PC Edition 2005 (menu entry windows-xp-tablet, the XP
x86 flow from UEFI), host-only, no Microsoft files:

- tools/nt5_profile.sh: usos.xp_edition=tablet -> the Tablet PC DATA folder;
- tools/probe_xp_source.sh: tablet_pc=yes|no, the Tablet entry refuses a disc
  without CMPNENTS\\TABLETPC (disc 1 of the two-CD set);
- tools/micro_linux_ui.sh: the Tablet PC heading;
- tools/build_xp_uefi_csm_trial.py: driver bundles for the Tablet DATA folder.

The CMPNENTS copy into ~LS and the disc-key fallback are shared with the
Media Center entry (test_xp_mce.py).

    python tools/tests/test_xp_tablet.py
"""
from pathlib import Path
import sys, tempfile, unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_nt52_staging import ROOT, SH, posix, sh  # noqa: E402

PROFILE = posix(ROOT / 'tools' / 'nt5_profile.sh')
SHOW = 'usos_nt5_profile; printf "%s|%s|%s|%s|%s" "$NT5_NAME" "$NT5_TITLE" "$NT5_SETUP_DIR" "$NT5_INSTALL_DIR" "$USOS_XP_EDITION"'


def xp_source(root: Path, tablet: bool, media_center: bool = False) -> None:
    (root / 'I386').mkdir()
    for marker in ('WIN51', 'WIN51IP', 'WIN51IP.SP3'):
        (root / marker).write_bytes(b'Windows\r\n')
    for name in ('DOSNET.INF', 'SETUPLDR.BIN', 'NTLDR', 'NTDETECT.COM', 'TXTSETUP.SIF', 'USETUP.EXE', 'SETUPDD.SY_', 'NTOSKRNL.EX_', 'NTKRNLMP.EX_', 'BOOTVID.DL_'):
        (root / 'I386' / name).write_bytes(b'x')
    if tablet:
        cab = root / 'CMPNENTS' / 'TABLETPC' / 'I386'
        cab.mkdir(parents=True)
        (cab / 'TABLETPC.CAB').write_bytes(b'MSCF')
    if media_center:
        cab = root / 'CMPNENTS' / 'MEDIACTR' / 'I386'
        cab.mkdir(parents=True)
        (cab / 'MEDIACTR.CAB').write_bytes(b'MSCF')


@unittest.skipIf(SH is None, 'sh not found')
class XpTabletProfile(unittest.TestCase):
    def test_profile_edition(self):
        r = sh(f"NT5_SYSTEM=windows-xp USOS_XP_EDITION=tablet; . '{PROFILE}'; {SHOW}")
        self.assertEqual(r.stdout.decode(), 'Windows XP Tablet PC Edition 2005|WINDOWS XP TABLET PC EDITION 2005|XP|WINDOWS|tablet')
        # Media Center and plain XP are unchanged.
        r = sh(f"NT5_SYSTEM=windows-xp USOS_XP_EDITION=mce; . '{PROFILE}'; {SHOW}")
        self.assertEqual(r.stdout.decode(), 'Windows XP Media Center Edition 2005|WINDOWS XP MEDIA CENTER EDITION 2005|XP|WINDOWS|mce')
        r = sh(f"NT5_SYSTEM=windows-xp USOS_XP_EDITION=; . '{PROFILE}'; {SHOW}")
        self.assertEqual(r.stdout.decode(), 'Windows XP|WINDOWS XP|XP|WINDOWS|')
        # An unknown edition value falls back to plain XP.
        r = sh(f"NT5_SYSTEM=windows-xp USOS_XP_EDITION=bogus; . '{PROFILE}'; {SHOW}")
        self.assertEqual(r.stdout.decode(), 'Windows XP|WINDOWS XP|XP|WINDOWS|')

    def test_probe(self):
        probe = posix(ROOT / 'tools' / 'probe_nt5_source.sh')
        for tablet in (True, False):
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                xp_source(root, tablet, media_center=True)
                base = f"SOURCE_ROOT='{posix(root)}' NT5_SYSTEM=windows-xp"
                r = sh(f"{base} USOS_XP_EDITION= sh '{probe}'")
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn(f'tablet_pc={"yes" if tablet else "no"}', r.stdout.decode())
                self.assertIn('media_center=yes', r.stdout.decode())
                r = sh(f"{base} USOS_XP_EDITION=tablet sh '{probe}'")
                if tablet:
                    self.assertEqual(r.returncode, 0, r.stderr)
                else:
                    self.assertNotEqual(r.returncode, 0)
                    self.assertIn(b'TABLETPC.CAB is missing', r.stdout + r.stderr)
                # The Media Center entry does not need the Tablet components.
                r = sh(f"{base} USOS_XP_EDITION=mce sh '{probe}'")
                self.assertEqual(r.returncode, 0, r.stderr)

    def test_ui_heading(self):
        text = (ROOT / 'tools' / 'micro_linux_ui.sh').read_text(encoding='utf-8')
        tablet = text.index("usos.xp_edition=tablet '*) USOS_UI_NT5=yes; USOS_UI_HEADING='Windows XP Tablet PC Edition 2005'")
        # Before the plain XP row, which would match first otherwise.
        self.assertLess(tablet, text.index("*' usos.legacy_action=xp-staging '*) USOS_UI_NT5=yes; USOS_UI_HEADING='Windows XP' ;;"))


class BuilderSources(unittest.TestCase):
    def test_xp_images_include_the_tablet_folder(self):
        sys.path.insert(0, str(ROOT / 'tools'))
        import build_xp_uefi_csm_trial as builder
        with tempfile.TemporaryDirectory() as tmp:
            data = Path(tmp)
            for folder, name in (('Windows XP', 'b_xp_sp3.iso'), ('Windows XP Media Center Edition 2005', 'a_mce_sp3.iso'),
                                 ('Windows XP Tablet PC Edition 2005', 'Windows XP Tablet PC Edition 2005 SP3 EN.iso'), ('Windows XP x64', 'c_sp2.iso')):
                images = data / 'Systems' / 'Windows' / folder / 'Images'
                images.mkdir(parents=True)
                (images / name).write_bytes(b'')
            names = [p.name for p in builder.xp_images(data)]
            self.assertEqual(names, ['b_xp_sp3.iso', 'a_mce_sp3.iso', 'Windows XP Tablet PC Edition 2005 SP3 EN.iso'])
            self.assertTrue(all(builder.is_sp3(p) for p in builder.xp_images(data)))


class CatalogFolder(unittest.TestCase):
    def test_folder_names_agree(self):
        folder = 'Windows XP Tablet PC Edition 2005'
        catalog = (ROOT / 'src' / 'catalog' / 'windows_legacy.zig').read_text(encoding='utf-8')
        self.assertIn(f'uefiLegacy("windows-xp-tablet", "{folder}", "{folder}")', catalog)
        layout = (ROOT / 'installer' / 'internal' / 'winhost' / 'data_layout.go').read_text(encoding='utf-8')
        self.assertIn(f'{{"windows-xp-tablet", "{folder}", true, true}}', layout)
        self.assertIn(f"NT5_NAME='{folder}'", (ROOT / 'tools' / 'nt5_profile.sh').read_text(encoding='utf-8'))


if __name__ == '__main__':
    unittest.main()
