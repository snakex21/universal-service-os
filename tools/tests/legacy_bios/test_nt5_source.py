"""Reject mismatched NT5 media before any target preparation can run."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
BASH = r'C:\Program Files\Git\bin\bash.exe' if os.name == 'nt' else shutil.which('bash')
REQUIRED = ('DOSNET.INF', 'SETUPLDR.BIN', 'NTLDR', 'NTDETECT.COM', 'TXTSETUP.SIF',
            'USETUP.EXE', 'SETUPDD.SY_', 'NTOSKRNL.EX_', 'NTKRNLMP.EX_', 'BOOTVID.DL_', 'SP4.CAB')


class NT5Source(unittest.TestCase):
    def setUp(self):
        (ROOT / 'zig-out').mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / 'zig-out')
        self.addCleanup(self.temp.cleanup)
        self.source = Path(self.temp.name)
        (self.source / 'I386').mkdir()
        for name in REQUIRED:
            (self.source / 'I386' / name).write_bytes(b'test fixture')
        for name in ('CDROM_NT.5', 'CDROM_IP.5', 'cdromsp4.tst'):
            (self.source / name).write_bytes(b'')
        self.sif = self.source / 'I386/TXTSETUP.SIF'
        self.sif.write_text('[SetupData]\nMajorVersion = 5\nMinorVersion = 0\nProductType = 0\n')

    def probe(self, system='windows-2000'):
        environment = os.environ | {'SOURCE_ROOT': self.source.as_posix(), 'NT5_SYSTEM': system}
        return subprocess.run([BASH, '--noprofile', '--norc', str(ROOT / 'tools/probe_nt5_source.sh')],
                              env=environment, capture_output=True, text=True)

    def test_sp4_source_and_lowercase_service_pack_marker(self):
        result = self.probe()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('service_pack_markers=CDROMSP4.TST', result.stdout)

    def test_wrong_family_is_refused_in_both_directions(self):
        self.assertNotEqual(self.probe('windows-xp').returncode, 0)
        (self.source / 'WIN51').write_bytes(b'')
        result = self.probe()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('XP source selected', result.stderr)

    def test_missing_service_pack_and_incomplete_loader_are_refused(self):
        (self.source / 'cdromsp4.tst').unlink()
        self.assertNotEqual(self.probe().returncode, 0)
        (self.source / 'CDROMSP4.TST').write_bytes(b'')
        (self.source / 'I386/SETUPLDR.BIN').unlink()
        self.assertNotEqual(self.probe().returncode, 0)

    def test_version_edition_and_duplicate_fields_are_refused(self):
        for text in (
            '[SetupData]\nMajorVersion=5\nMinorVersion=1\nProductType=0\n',
            '[SetupData]\nMajorVersion=5\nMinorVersion=0\nProductType=1\n',
            '[SetupData]\nMajorVersion=5\nMinorVersion=0\nMinorVersion=1\nProductType=0\n',
            '[Other]\nMajorVersion=5\nMinorVersion=0\nProductType=0\n',
        ):
            with self.subTest(text=text):
                self.sif.write_text(text)
                self.assertNotEqual(self.probe().returncode, 0)

    def test_unknown_profile_is_refused(self):
        self.assertNotEqual(self.probe('windows-nt-4').returncode, 0)


if __name__ == '__main__':
    unittest.main()
