"""Test-only: derive an XP UEFI-CSM package from a micro-Linux build.

Until M4 (docs/design/refactor-os-pipeline.md) the real package is built from
the stick's base by tools/build_xp_uefi_csm_trial.py. For QEMU tests of a
branch build this derives the same package with the SAME overlay code from
another micro-Linux directory, reusing pae.exe and the driver bundles of the
existing package (zig-out/xp-uefi-csm), so only the base changes:

    python tools/tests/legacy_bios/derive_xp_uefi_csm_package.py --micro-linux DIR --output OUT

OUT receives initramfs-xp, vmlinuz.efi and manifest.json. Nothing else is
written; never deploy OUT.
"""
from pathlib import Path
import argparse
import gzip
import hashlib
import json
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))
import build_xp_uefi_csm_trial as xp_csm  # noqa: E402
from build_micro_linux import newc, parse_newc, put  # noqa: E402

PACKAGE = ROOT / 'zig-out' / 'xp-uefi-csm'


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--micro-linux', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    micro = args.micro_linux.resolve()
    out = args.output.resolve()
    if out == PACKAGE.resolve():
        raise SystemExit('refusing to overwrite the real package')
    out.mkdir(parents=True, exist_ok=True)
    derived = parse_newc(gzip.decompress(xp_csm.overlay(micro / 'initramfs-usos', PACKAGE / 'pae.exe', [])))
    existing = parse_newc(gzip.decompress((PACKAGE / 'initramfs-xp').read_bytes()))
    bundles = 0
    for name, entry in existing.items():
        if name == 'usr/lib/usos/xp-drivers' or name.startswith('usr/lib/usos/xp-drivers/'):
            put(derived, entry)
            bundles += 1
    data = gzip.compress(newc(derived), compresslevel=6, mtime=0)
    (out / 'initramfs-xp').write_bytes(data)
    (out / 'vmlinuz.efi').write_bytes((micro / 'vmlinuz-virt').read_bytes())
    manifest = {'derived_for_tests': True, 'base': str(micro), 'driver_entries_copied': bundles,
                'sha256': {'initramfs-xp': hashlib.sha256(data).hexdigest()}}
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print('[PASS] derived XP UEFI-CSM package', out, 'driver entries', bundles)
    return 0


if __name__ == '__main__':
    sys.exit(main())
