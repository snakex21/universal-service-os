"""Exercise mounted-source operations used by the NTFS staging path."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]


class SourceIO(unittest.TestCase):
    def test_copy_alias_readback_and_reject_traversal(self):
        bash = shutil.which('bash') if os.name != 'nt' else r'C:\Program Files\Git\bin\bash.exe'
        (ROOT / 'zig-out').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / 'zig-out') as tmp:
            work = Path(tmp)
            (work / 'volume').mkdir()
            (work / 'source tree').mkdir()
            (work / 'source tree' / 'file.bin').write_bytes(bytes(range(256)))
            script = '''set -eu
export PATH=/usr/bin:/bin:$PATH
export XP_TARGET_ROOT="$PWD/volume"
. "$1/tools/xp_source_io.sh"
mmd -i ignored ::/I386
mcopy -i ignored -s "source tree" ::/I386/
mcopy -i ignored "source tree/file.bin" ::/I386/alias.bi_
mcopy -i ignored ::/I386/alias.bi_ readback.bin
mdir -i ignored ::/I386/alias.bi_
if mdir -i ignored ::/missing; then exit 20; fi
if mcopy -i ignored "source tree/file.bin" ::/../escape; then exit 21; fi
'''
            subprocess.run([bash, '-c', script, 'test', ROOT.as_posix()], cwd=work, check=True)
            expected = bytes(range(256))
            self.assertEqual((work / 'readback.bin').read_bytes(), expected)
            self.assertEqual((work / 'volume/I386/source tree/file.bin').read_bytes(), expected)
            self.assertFalse((work / 'escape').exists())


if __name__ == '__main__':
    unittest.main()
