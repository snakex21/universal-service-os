#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Read-only semantic gate against a real bcdboot store on the same layout.

Only original files are read (python-registry with a deny-write handle). Loader
GUIDs and optional resume/debug/recovery objects may differ; all their raw
values remain in manifests. The required default boot route must match exactly.
"""
import argparse
import json
from pathlib import Path
import subprocess

import bcd_oracle as oracle


def value(tree, obj, code, default=None):
    return tree.get(f'objects\\{obj}\\elements\\{code}'.lower(), {}).get('element', default)


def string(value):
    kind, data = value
    if kind != 1 or len(data) & 1 or not data.endswith(b'\0\0'):
        raise ValueError('Invalid BCD string')
    return data.decode('utf-16le').rstrip('\0').lower()


def device(value):
    kind, data = value
    if kind != 3 or len(data) != 88 or any(data[:16]) or int.from_bytes(data[16:20], 'little') != 6 or int.from_bytes(data[24:28], 'little') != 72:
        raise ValueError('Qualified partition descriptor required')
    style = int.from_bytes(data[52:56], 'little')
    if style == 0:
        return dict(style='GPT', disk_guid_le=data[56:72].hex(), partition_guid_le=data[32:48].hex())
    if style == 1:
        return dict(style='MBR', signature=int.from_bytes(data[56:60], 'little'), byte_offset=int.from_bytes(data[32:40], 'little'))
    raise ValueError('Invalid partition style')


def route(tree):
    manager = oracle.GUID_BOOTMGR
    loader = string(value(tree, manager, '23000003'))
    obj = tree[f'objects\\{loader}\\description']['type']
    mgr = tree[f'objects\\{manager}\\description']['type']
    if obj != (4, bytes.fromhex('03002010')) or mgr != (4, bytes.fromhex('02001010')):
        raise ValueError('Wrong BCD application classes')
    order_kind, order_data = value(tree, manager, '24000001')
    if order_kind != 7 or loader not in order_data.decode('utf-16le').lower().split('\0'):
        raise ValueError('Default Windows loader absent from displayorder')
    winpe_kind, winpe_data = value(tree, loader, '26000022', (3, b'\0'))
    if winpe_kind != 3 or int.from_bytes(winpe_data, 'little') != 0:
        raise ValueError('An installed Windows must not be marked WinPE')
    loader_path = string(value(tree, loader, '12000002'))
    manager_path = value(tree, manager, '12000002')
    if manager_path is None:
        if not loader_path.endswith('winload.exe'):
            raise ValueError('UEFI manager path required')
        manager_path = (1, '\\bootmgr\0'.encode('utf-16le'))
    return dict(system=device(value(tree, manager, '11000001')),
                manager_path=string(manager_path),
                manager_locale=string(value(tree, manager, '12000005')),
                windows=device(value(tree, loader, '11000001')),
                osdevice=device(value(tree, loader, '21000001')),
                loader_path=loader_path,
                loader_locale=string(value(tree, loader, '12000005')),
                systemroot=string(value(tree, loader, '22000002')),
                winpe=False)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--ours', type=Path, required=True)
    p.add_argument('--reference', type=Path, required=True)
    p.add_argument('--bcdboot-receipt', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--require-clean', action='store_true')
    args = p.parse_args()
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=oracle.REPO, text=True).strip()
    dirty = len(subprocess.check_output(['git', 'status', '--porcelain=v1', '-uall'], cwd=oracle.REPO, text=True).splitlines())
    print(f'HEAD {head}\nWORKTREE_DIRTY {dirty}', flush=True)
    if args.require_clean and dirty:
        raise ValueError('Final evidence requires clean tree')
    receipt = json.loads(args.bcdboot_receipt.read_text(encoding='utf-8'))
    # The parent gate owns virtual-disk identity/mount and bcdboot /s execution.
    # Bind this comparison to its exact completed reference, never any host BCD.
    if receipt.get('bcdboot_exit') != 0 or receipt.get('reference_sha256') != oracle.sha(args.reference) or receipt.get('physical_disk_touched') is not False:
        raise ValueError('Completed guarded bcdboot receipt required')
    ours = oracle.independent_read(args.ours)
    ref = oracle.independent_read(args.reference)
    a, b = route(ours), route(ref)
    differences = {key: {'ours': a[key], 'reference': b[key]} for key in a if a[key] != b[key]}
    after_head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=oracle.REPO, text=True).strip()
    after_dirty = len(subprocess.check_output(['git', 'status', '--porcelain=v1', '-uall'], cwd=oracle.REPO, text=True).splitlines())
    if args.require_clean and (after_head != head or after_dirty):
        raise ValueError('Tree changed during evidence gate')
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    (out / 'ours.json').write_text(json.dumps(oracle.manifest(ours), indent=2), encoding='utf-8')
    (out / 'reference.json').write_text(json.dumps(oracle.manifest(ref), indent=2), encoding='utf-8')
    result = dict(head=head, dirty=dirty, after_head=after_head, after_dirty=after_dirty,
                  source_sha256=oracle.sha(args.ours), reference_sha256=oracle.sha(args.reference),
                  bcdboot_receipt_sha256=oracle.sha(args.bcdboot_receipt), ours_route=a, reference_route=b,
                  core_differences=differences, status='FAIL' if differences else 'PASS',
                  scope='Default boot route; optional recovery/resume/debug objects retained in full raw manifests')
    (out / 'result.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    if differences:
        raise ValueError('Required BCD boot route differs from real bcdboot')
    print('BCD_REAL_BCDBOOT_ROUTE PASS')


if __name__ == '__main__':
    main()
