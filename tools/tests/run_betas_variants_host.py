"""Host regressions for beta variants; no VM starts and no physical disk writes.

Optional --vendor-root reads two existing, hash-pinned driver dependencies
from another checkout without copying them into this checkout or changing it.
All temporary test data stays under this checkout's tools/tests/artifacts.
"""
from pathlib import Path
import argparse
import os
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT/'tools/tests'), str(ROOT/'tools')]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--vendor-root', type=Path)
a = p.parse_args()
# Existing POSReady tests use which('sh'); append a local Git shell fallback
# only for this test process. Other suites keep their own SH_ENV prefixes.
if not shutil.which('sh'):
    shell_dir = Path('C:/Program Files/Git/usr/bin')
    if (shell_dir/'sh.exe').is_file():
        os.environ['PATH'] = os.environ.get('PATH', '') + os.pathsep + str(shell_dir)
tmp = ROOT/'tools/tests/artifacts/beta-tmp'
tmp.mkdir(parents=True, exist_ok=True)
tempfile.tempdir = str(tmp)
if a.vendor_root:
    import build_xp_uefi_csm_trial as builder
    import xp64_acpi
    builder.GENAHCI_ARCHIVE = a.vendor_root/'tools/vendor/xp-modern/2026-09-21/GenAHCI_6.3.0.1.7z'
    xp64_acpi.DRIVER_DIR = a.vendor_root/'media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x64/ACPI'
    # Production readers still enforce their original pinned SHA-256 values.
suite = unittest.TestLoader().loadTestsFromNames([
    'test_betas_variants', 'test_nt4_flow', 'test_nt3_flow', 'test_posready',
    'test_posready_credentials', 'test_nt52_staging', 'test_xp_mce', 'test_xp_tablet',
    'legacy_bios.test_nt5_source',
])
result = unittest.TextTestRunner(verbosity=1).run(suite)
for test, reason in result.skipped:
    print('SKIP:', test.id(), reason)
sys.exit(not result.wasSuccessful())
