"""CSMWrap 3.1.2-usos11-int13x (patch 0014, csmwrap.ini int13_boot_disk_only): host checks.

The manifest hashes match the committed patches and binary; the variant is
usos11's series plus 0014 only; 0014 keeps patch 0005's no-match / several-
matches fallback and drops only IPL_TYPE_HARDDISK entries; the binary carries
the version and the ini key. QEMU behaviour: tools/tests/legacy_bios/
run_csmwrap_boot_disk_qemu.py --only (docs/nvme-9x-2026-10-14.md).
"""
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
V = ROOT / 'tools/vendor/csmwrap/3.1.2-usos11-int13x'
BASE = ROOT / 'tools/vendor/csmwrap/3.1.2-usos11'


def sha(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def main() -> int:
    m = json.loads((V / 'manifest.json').read_text(encoding='utf-8'))
    assert m['version'] == '3.1.2-usos11-int13x'
    patches = sorted(p.name for p in (V / 'patches').glob('*.patch'))
    assert set(m['patches']) == set(patches), patches
    for name, h in m['patches'].items():
        assert sha(V / 'patches' / name) == h, name
    assert sha(V / 'csmwrapx64.efi') == m['files']['csmwrapx64.efi']
    base = sorted(p.name for p in (BASE / 'patches').glob('*.patch'))
    assert patches == sorted(base + ['0014-int13-boot-disk-only.patch']), patches
    for name in base:
        assert sha(V / 'patches' / name) == sha(BASE / 'patches' / name), name
    p14 = (V / 'patches/0014-int13-boot-disk-only.patch').read_text(encoding='utf-8')
    for needle in ('int13_boot_disk_only', 'USOS_BOOTDISK_ONLY_TAG', 'CSM_USOS_BOOTDISK_ONLY_TAG',
                   '+    if (matches != 1) {', 'pos->type != IPL_TYPE_HARDDISK || pos == match',
                   '+    if (!only)\n+        return;'):
        assert needle in p14, needle
    efi = (V / 'csmwrapx64.efi').read_bytes()
    assert efi[:2] == b'MZ'
    assert b'3.1.2-usos11-int13x' in efi and b'int13_boot_disk_only' in efi
    print('CSMWRAP-INT13X-TEST PASS')
    return 0


if __name__ == '__main__':
    sys.exit(main())
