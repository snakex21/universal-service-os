"""Host-only regression: Patcher9x NDIS bytes, WININIT queue and manifest rules."""
from pathlib import Path
import hashlib
import os
import shutil
import subprocess
import sys
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(ROOT/'tools/tests'), str(ROOT/'tools/addons')]
import depguard
import legacy_manifest as lm

OUT = ROOT/'artifacts/w95-addons-fixes'


class AddonsFixes(unittest.TestCase):
    def test_winsock_answer_is_package_scoped(self):
        m = lm.Manifest.load()
        self.assertEqual(lm.validate(m), [])
        self.assertEqual(m.find('ws2-95').get('answer1'), 'Winsock2 Setup|1')
        self.assertNotIn('Winsock2 Setup', '\n'.join(v for s,k,v in m.entries if s=='pack'))

    def test_byte_patch_matches_pinned_patcher9x(self):
        folder = ROOT/'tools/vendor/patcher9x/0.9.91'
        lock = __import__('json').loads((folder/'manifest.json').read_text())
        source = folder/'source.zip'
        self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), lock['files']['source.zip'])
        with zipfile.ZipFile(source) as z:
            prefix = z.namelist()[0].split('/')[0]+'/'
            for version in (1, 4):
                before = z.read(prefix+f'cpuspeed/speedndis_v{version}_orig.bin')
                after = z.read(prefix+f'cpuspeed/speedndis_v{version}.bin')
                diffs = [i for i, (a,b) in enumerate(zip(before,after)) if a!=b]
                lo, hi = min(diffs), max(diffs)+1
                self.assertEqual(hi-lo, 18)
                self.assertEqual(before[lo:hi].hex(), '100090e2fecd203f00010029d0b9e8030000')
                self.assertEqual(after[lo:hi].hex(), '4006e2fecd203f00010029d07501406a0a59')

    def test_compiled_repair_offsets_queue_idempotence_and_failures(self):
        zig = depguard.require_zig()
        OUT.mkdir(parents=True, exist_ok=True)
        env = dict(os.environ, TEMP=str(OUT), TMP=str(OUT),
                   ZIG_GLOBAL_CACHE_DIR=str(ROOT/'tools/cache/zig-global'),
                   ZIG_LOCAL_CACHE_DIR=str(OUT/'zig-cache'))
        exe = OUT/'ndis_repair_host.exe'
        subprocess.run([str(zig), 'cc', '-target', 'x86_64-windows-gnu', '-Os', '-nostdlib',
                        '-fno-builtin', '-fno-stack-protector',
                        '-isystem', str(zig.parent/'lib/libc/include/any-windows-any'),
                        str(ROOT/'tools/tests/addons/ndis_repair_host.c'), '-Wl,--entry,entry',
                        '-lkernel32', '-o', str(exe)], env=env, check=True)
        for case in range(13):
            with self.subTest(case=case):
                # Keep all run evidence; no cleanup of prior fixture outputs.
                import tempfile
                folder = Path(tempfile.mkdtemp(prefix=f'case-{case}-', dir=OUT))
                dest = folder/exe.name
                shutil.copyfile(exe, dest)
                result = subprocess.run([str(dest), str(case)], env=env, timeout=15)
                self.assertEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
