#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""F-i: delete exactly four accepted, reproducible VHD copies, never target.raw."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat


def digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def checked(root, relative):
    if not relative or Path(relative).is_absolute() or Path(relative).drive or '..' in Path(relative).parts:
        raise ValueError('Relative inventory path required')
    path = root / relative
    if not path.is_relative_to(root / '1c1'):
        raise ValueError('Only accepted 1c1 artifacts')
    for node in (path, *path.parents):
        if node.is_symlink() or node.exists() and getattr(node.lstat(), 'st_file_attributes', 0) & 0x400:
            raise ValueError('Reparse point refused')
    return path


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('runtime', 'inventory', 'receipt'):
        p.add_argument('--' + name, type=Path, required=True)
    p.add_argument('--inventory-sha256', required=True)
    p.add_argument('--approved-vhd-copy-cleanup-20261025', action='store_true', required=True)
    a = p.parse_args()
    root = a.runtime.resolve(strict=True)
    if not root.is_absolute() or str(root).startswith('\\\\'):
        raise ValueError('Local runtime required')
    if a.receipt.exists() or not a.receipt.absolute().is_relative_to(root / '1c23'):
        raise ValueError('New receipt under1c23 required')
    if digest(a.inventory) != a.inventory_sha256:
        raise ValueError('Inventory pin mismatch')
    rows = json.loads(a.inventory.read_text(encoding='utf-8'))['files']
    index = {(r['scope'], r['path']):r for r in rows}
    names = [f'1c1/e2e-{os_name}-01/native/{name}.vhd'
             for os_name in ('win11', 'win7') for name in ('converted-fixed', 'readonly-copy')]
    selected = [index[('runtime', name)] for name in names]
    if sum(r['bytes'] for r in selected) != 44 * 1024**3 + 4 * 512:
        raise ValueError('Expected exactly44GiB plus four VHD footers')
    raw_pins = [index[('runtime',f'1c1/e2e-{os_name}-01/target.raw')] for os_name in ('win11','win7')]
    # Verify surviving raw sources and ALL copies before the first unlink.
    for row in raw_pins + selected:
        path = checked(root,row['path'])
        if not path.is_file() or path.stat().st_size != row['bytes'] or digest(path) != row['sha256']:
            raise ValueError('Closed artifact pin mismatch: ' + row['path'])
    a.receipt.parent.mkdir(parents=True,exist_ok=True)
    record = dict(schema='accepted-1c1-vhd-cleanup-v1',authorization='user-2026-10-25-F-i',
                  inventory_sha256=a.inventory_sha256,state='verified-before-deletion',
                  raw_sources_preserved=raw_pins,deleted=[],small_evidence_deleted=False)
    def save():
        a.receipt.write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8')
    save()
    for row in selected:
        path = checked(root,row['path'])
        if path.stat().st_size != row['bytes']:
            raise ValueError('Copy changed after verification')
        os.chmod(path,path.stat().st_mode | stat.S_IWRITE)
        path.unlink()
        record['deleted'].append(row)
        save()
    record['state']='complete'
    save()
    print(json.dumps(dict(deleted=4,bytes=sum(r['bytes'] for r in selected),raw_sources_preserved=True)))


if __name__ == '__main__':
    main()
