"""Check NT5 media identity copying without mounting a filesystem on the host."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
BASH = r'C:\Program Files\Git\bin\bash.exe' if os.name == 'nt' else shutil.which('bash')


class Markers(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / 'zig-out')
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.source = self.work / 'source'
        self.target = self.work / 'target'
        self.source.mkdir()
        (self.target / '$WIN_NT$.~LS').mkdir(parents=True)
        self.expected = {'CDROM_NT.5': b'NT5\r\n', 'CDROM_IP.5': b'W2KP\r\n', 'CDROMSP4.TST': b''}
        for name, content in self.expected.items():
            (self.source / name.lower()).write_bytes(content)

    def run_copy(self, system='windows-2000'):
        # Uppercase Pro markers are the source probe contract; SP4 accepts either case.
        for name in ('CDROM_NT.5', 'CDROM_IP.5'):
            source = self.source / name.lower()
            if source.exists() and os.name != 'nt':
                source.rename(self.source / name)
        env = os.environ | {'SOURCE_ROOT': self.source.as_posix(),
                            'XP_TARGET_ROOT': self.target.as_posix(),
                            'MTOOLS_IMAGE': 'unused', 'NT5_SYSTEM': system,
                            'TMPDIR': self.work.as_posix()}
        return subprocess.run([BASH, '--noprofile', '--norc', str(ROOT / 'tools/prepare_nt5_media_markers.sh')],
                              env=env, capture_output=True, text=True)

    def test_markers_are_identical_at_both_lookup_locations(self):
        result = self.run_copy()
        self.assertEqual(result.returncode, 0, result.stderr)
        for folder in (self.target, self.target / '$WIN_NT$.~LS'):
            for name, expected in self.expected.items():
                self.assertEqual((folder / name).read_bytes(), expected)

    def test_xp_is_unchanged(self):
        result = self.run_copy('windows-xp')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(p.is_file() for p in self.target.rglob('*')))

    def test_missing_source_and_unknown_profile_do_not_write(self):
        (self.source / 'cdromsp4.tst').unlink()
        self.assertNotEqual(self.run_copy().returncode, 0)
        self.assertNotEqual(self.run_copy('windows-nt-4').returncode, 0)
        self.assertFalse(any(p.is_file() for p in self.target.rglob('*')))


if __name__ == '__main__':
    unittest.main()
