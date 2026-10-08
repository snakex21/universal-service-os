"""Windows XP Media Center Edition 2005 (menu entry windows-xp-mce, the XP
x86 flow from UEFI), host-only, no Microsoft files:

- tools/nt5_profile.sh: usos.xp_edition=mce -> the Media Center DATA folder;
- tools/probe_xp_source.sh: media_center=yes|no, the MCE entry refuses a disc
  without CMPNENTS\\MEDIACTR (disc 1 of the two-CD set);
- tools/prepare_xp_local_source.sh: CMPNENTS copied into ~LS (source text);
- tools/nt5_media_key.sh: the disc's own I386\\WINNT.SIF key as the last
  fallback, never over an answered key.

    python tools/tests/test_xp_mce.py
"""
from pathlib import Path
import sys, tempfile, unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_nt52_staging import ROOT, SH, posix, rows, sh  # noqa: E402

KEYLIB = posix(ROOT / 'tools' / 'nt5_media_key.sh')
# A made-up key in the 5x5 shape (not a product key).
FAKE = 'AAAAA-BBBBB-CCCCC-DDDDD-EEEEE'


def xp_source(root: Path, mce: bool) -> None:
    (root / 'I386').mkdir()
    for marker in ('WIN51', 'WIN51IP', 'WIN51IP.SP3'):
        (root / marker).write_bytes(b'Windows\r\n')
    for name in ('DOSNET.INF', 'SETUPLDR.BIN', 'NTLDR', 'NTDETECT.COM', 'TXTSETUP.SIF', 'USETUP.EXE', 'SETUPDD.SY_', 'NTOSKRNL.EX_', 'NTKRNLMP.EX_', 'BOOTVID.DL_'):
        (root / 'I386' / name).write_bytes(b'x')
    if mce:
        cab = root / 'cmpnents' / 'mediactr' / 'I386'
        cab.mkdir(parents=True)
        (cab / 'MEDIACTR.CAB').write_bytes(b'MSCF')


@unittest.skipIf(SH is None, 'sh not found')
class XpMceProfile(unittest.TestCase):
    def test_profile_edition(self):
        prof = posix(ROOT / 'tools' / 'nt5_profile.sh')
        show = 'usos_nt5_profile; printf "%s|%s|%s|%s|%s" "$NT5_NAME" "$NT5_TITLE" "$NT5_SETUP_DIR" "$NT5_INSTALL_DIR" "$USOS_XP_EDITION"'
        r = sh(f"NT5_SYSTEM=windows-xp USOS_XP_EDITION=mce; . '{prof}'; {show}")
        self.assertEqual(r.stdout.decode(), 'Windows XP Media Center Edition 2005|WINDOWS XP MEDIA CENTER EDITION 2005|XP|WINDOWS|mce')
        r = sh(f"NT5_SYSTEM=windows-xp USOS_XP_EDITION=; . '{prof}'; {show}")
        self.assertEqual(r.stdout.decode(), 'Windows XP|WINDOWS XP|XP|WINDOWS|')

    def test_probe(self):
        probe = posix(ROOT / 'tools' / 'probe_nt5_source.sh')
        for mce in (True, False):
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                xp_source(root, mce)
                base = f"SOURCE_ROOT='{posix(root)}' NT5_SYSTEM=windows-xp"
                r = sh(f"{base} USOS_XP_EDITION= sh '{probe}'")
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn(f'media_center={"yes" if mce else "no"}', r.stdout.decode())
                self.assertIn('service_pack_markers=WIN51IP.SP3', r.stdout.decode())
                r = sh(f"{base} USOS_XP_EDITION=mce sh '{probe}'")
                if mce:
                    self.assertEqual(r.returncode, 0, r.stderr)
                else:
                    self.assertNotEqual(r.returncode, 0)
                    self.assertIn(b'MEDIACTR.CAB is missing', r.stdout + r.stderr)

    def test_local_source_copies_cmpnents(self):
        text = (ROOT / 'tools' / 'prepare_xp_local_source.sh').read_text(encoding='utf-8')
        copy = text.index("-iname cmpnents")
        self.assertLess(copy, text.index('prepare_xp_source_aliases.sh'))
        self.assertIn('"$cmpnents" "::/$LS_DIR/"', text)
        packaged = (ROOT / 'tools' / 'build_micro_linux.py').read_text(encoding='utf-8')
        self.assertIn('("tools/nt5_media_key.sh", "usr/lib/usos/nt5_media_key.sh")', packaged)


class BuilderSources(unittest.TestCase):
    def test_xp_images_include_the_media_center_folder(self):
        sys.path.insert(0, str(ROOT / 'tools'))
        import build_xp_uefi_csm_trial as builder
        with tempfile.TemporaryDirectory() as tmp:
            data = Path(tmp)
            for folder, name in (('Windows XP', 'b_xp_sp3.iso'), ('Windows XP Media Center Edition 2005', 'a_mce_sp3.iso'), ('Windows XP x64', 'c_sp2.iso')):
                images = data / 'Systems' / 'Windows' / folder / 'Images'
                images.mkdir(parents=True)
                (images / name).write_bytes(b'')
            # XP first (unchanged order of an XP-only DATA), then Media Center; never XP x64.
            self.assertEqual([p.name for p in builder.xp_images(data)], ['b_xp_sp3.iso', 'a_mce_sp3.iso'])
            self.assertTrue(all(builder.is_sp3(p) for p in builder.xp_images(data)))


@unittest.skipIf(SH is None, 'sh not found')
class MediaKey(unittest.TestCase):
    def media(self, tmp: Path, text: bytes) -> Path:
        (tmp / 'i386').mkdir()
        (tmp / 'i386' / 'winnt.sif').write_bytes(text)
        return tmp

    def test_media_key_found_and_put(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = self.media(Path(tmp), b'[Data]\r\nUnattendedInstall=Yes\r\n\r\n[UserData]\r\nProductKey=' + FAKE.lower().encode() + b'\r\n')
            r = sh(f". '{KEYLIB}'; p=$(usos_nt5_media_sif_path '{posix(root)}') && usos_nt5_media_key \"$p\"")
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(r.stdout.decode().strip(), FAKE)
        # No [UserData] yet: the section is added.
        r = sh(f". '{KEYLIB}'; usos_nt5_put_key ProductKey {FAKE}", b'[Data]\r\nx=1\r\n[Unattended]\r\nUnattendMode=ProvideDefault\r\n')
        self.assertEqual(rows(r.stdout)[-3:], ['[UserData]', f'ProductKey="{FAKE}"', ''])
        # An empty field is replaced in place, other keys and sections kept.
        r = sh(f". '{KEYLIB}'; usos_nt5_put_key ProductKey {FAKE}", b'[UserData]\r\nFullName="A"\r\nProductKey=""\r\n[GuiUnattended]\r\nTimeZone=95\r\n')
        self.assertEqual(rows(r.stdout), ['[UserData]', 'FullName="A"', f'ProductKey="{FAKE}"', '[GuiUnattended]', 'TimeZone=95', ''])
        # Windows 2000 spelling.
        r = sh(f". '{KEYLIB}'; usos_nt5_put_key ProductID {FAKE}", b'[UserData]\r\nFullName="A"\r\n[Data]\r\n')
        self.assertEqual(rows(r.stdout), ['[UserData]', 'FullName="A"', f'ProductID="{FAKE}"', '[Data]', ''])

    def test_answered_key_wins_and_bad_shapes(self):
        has = f". '{KEYLIB}'; usos_nt5_answer_has_key ProductKey"
        self.assertEqual(sh(has, b'[UserData]\r\nProductKey="' + FAKE.encode() + b'"\r\n').returncode, 0)
        self.assertNotEqual(sh(has, b'[UserData]\r\nProductKey=""\r\n').returncode, 0)
        self.assertNotEqual(sh(has, b'[Data]\r\nProductKey=x\r\n').returncode, 0)
        with tempfile.TemporaryDirectory() as tmp:
            for text in (b'[UserData]\r\nProductKey=\r\n', b'[UserData]\r\nProductKey=ABC\r\n', b'[Data]\r\nProductKey=' + FAKE.encode() + b'\r\n'):
                sif = Path(tmp) / 'w.sif'
                sif.write_bytes(text)
                self.assertNotEqual(sh(f". '{KEYLIB}'; usos_nt5_media_key '{posix(sif)}'").returncode, 0, text)
            self.assertNotEqual(sh(f". '{KEYLIB}'; usos_nt5_media_sif_path '{posix(Path(tmp))}'").returncode, 0)

    def test_partition_script_never_logs_the_key(self):
        text = (ROOT / 'tools' / 'prepare_xp_windows_partition.sh').read_text(encoding='utf-8')
        block = text[text.index('nt5_media_key.sh"'):text.index('put_verified "$work/winnt.sif" WINNT.SIF')]
        self.assertNotIn('$media_key"\n', block.replace('"$media_key" <', ''))
        self.assertNotIn('printf \'%s', block)
        self.assertIn('(not logged)', block)


if __name__ == '__main__':
    unittest.main()
