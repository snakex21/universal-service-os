#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""One explicit accepted-image inventory; retain every non-image evidence file."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat


def sha(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def checked(root, relative):
    path = root / relative
    if not relative or Path(relative).is_absolute() or Path(relative).drive or '..' in Path(relative).parts:
        raise ValueError('Invalid inventory path')
    if not path.is_relative_to(root) or not relative.replace('\\', '/').startswith('1c0/'):
        raise ValueError('Only accepted 1c0 paths are permitted')
    for node in (path, *path.parents):
        if node.is_symlink() or node.exists() and getattr(node.lstat(), 'st_file_attributes', 0) & 0x400:
            raise ValueError('Reparse point refused')
    return path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--inventory', type=Path, required=True)
    parser.add_argument('--inventory-sha256', required=True)
    parser.add_argument('--receipt', type=Path, required=True)
    parser.add_argument('--approved-1c0-20261025', action='store_true', required=True)
    args = parser.parse_args()
    root = args.runtime.resolve(strict=True)
    receipt = args.receipt.absolute()
    if not receipt.is_relative_to(root / '1c1') or receipt.exists():
        raise ValueError('New receipt under 1c1 required')
    if sha(args.inventory) != args.inventory_sha256:
        raise ValueError('Inventory pin mismatch')
    inventory = json.loads(args.inventory.read_text(encoding='utf-8'))
    rows = inventory['images']
    if len(rows) != 77 or sum(row['bytes'] for row in rows) != 101927891982:
        raise ValueError('Exact accepted inventory required')
    if len({row['path'] for row in rows}) != len(rows):
        raise ValueError('Repeated path')
    # Entire inventory is verified before the first deletion. No scanning,
    # recursive delete, wildcard, physical device or cleanup of other files.
    for row in rows:
        path = checked(root, row['path'])
        if not path.is_file() or path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
            raise ValueError('Closed image pin mismatch: ' + row['path'])
    receipt.parent.mkdir(parents=True, exist_ok=True)
    record = dict(schema='accepted-1c0-cleanup-v1', inventory_sha256=args.inventory_sha256,
                  authorization='user-2026-10-25-accepted-1c0-77-listed-artifacts',
                  state='verified-before-deletion', deleted=[], evidence_deleted=False)
    def save():
        receipt.write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8')
    save()
    for row in rows:
        path = checked(root, row['path'])
        if path.stat().st_size != row['bytes']:
            raise ValueError('Image changed after verification')
        if not path.stat().st_mode & stat.S_IWRITE:
            os.chmod(path, path.stat().st_mode | stat.S_IWRITE)
        path.unlink()
        record['deleted'].append(row)
        save()
    record['state'] = 'complete'
    save()
    print(json.dumps(dict(deleted=len(rows), bytes=sum(row['bytes'] for row in rows), receipt=str(receipt))))


if __name__ == '__main__':
    main()
