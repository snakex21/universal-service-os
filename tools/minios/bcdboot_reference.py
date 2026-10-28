#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Read-only validation of historical BCD/native proofs. Host bcdboot is forbidden."""
import argparse
import contextlib
import json
from pathlib import Path
import re
from types import SimpleNamespace

import install_native as native
import logged_run
import wim_oracle as oracle
import wim_pool as pool

REPO = Path(__file__).resolve().parents[2]
SHA = re.compile(r'^[0-9a-f]{64}$')


def document(path, expected_sha):
    path = native.regular(oracle.owned(path))
    if not SHA.fullmatch(expected_sha) or path.stat().st_size > 1024**2 or oracle.digest(path) != expected_sha:
        raise ValueError('Bounded exact receipt/layout pin differs')
    return json.loads(path.read_text(encoding='utf-8-sig'))


def prepared_base_pins(proof, base):
    """Only the pinned successful direct-VHD path permits an external base.

    This reuses the same read-only firmware contract as the native gate. No
    comparison process, normalization, copy or disk API is performed here.
    """
    if (proof.get('reused_prepared_vhd') is not True or proof.get('vhd_export_performed') is not False
        or proof.get('normalization_performed_during_native') is not False
        or type(proof.get('prepared_logical_compare_exit')) is not int or proof['prepared_logical_compare_exit']!=0):
        raise ValueError('Completed byte-identical native prepared-VHD reuse required')
    rows=proof.get('source_backing_chain')
    if not isinstance(rows,list) or len(rows)!=2:raise ValueError('Exact prepared wrapper/VHD chain required')
    paths=[];pins={}
    for row in rows:
        if not isinstance(row,dict) or set(row)!={'path','sha256'} or not isinstance(row['path'],str):
            raise ValueError('Exact native source-chain row required')
        relative=Path(row['path'])
        if relative.is_absolute() or relative.drive or '..' in relative.parts or any(char in str(relative) for char in ':,\r\n\0'):
            raise ValueError('Unsafe prepared source chain')
        path=native.regular(oracle.owned(oracle.RUNTIME/relative))
        if path in pins or not isinstance(row['sha256'],str) or not SHA.fullmatch(row['sha256']):
            raise ValueError('Duplicate/unpinned native source chain')
        paths.append(path);pins[path]=row['sha256']
    if paths[1]!=base or pins[base]!=proof['vhd_sha256'] or pins[paths[0]]!=proof.get('source_sha256'):
        raise ValueError('Native prepared VHD identity differs from its source chain')
    receipt=oracle.owned(Path(proof.get('prep_receipt','')))
    args=SimpleNamespace(reuse_prepared_vhd=base,prep_receipt=receipt,
                         prep_receipt_sha256=proof.get('prep_receipt_sha256'),source=paths[0],
                         virtual_bytes=proof['virtual_bytes'],mode=proof['mode'])
    with contextlib.ExitStack() as locks:
        for path,pin in pins.items():
            source=locks.enter_context(oracle.readonly(path))
            if oracle.digest_stream(source)!=pin:raise ValueError('Native prepared chain changed')
        reused=native.prepared_reuse(args,locks)
        if (reused['vhd']!=base or reused['sha256']!=proof['vhd_sha256']
            or reused['normalization']!=proof.get('normalization')):
            raise ValueError('Native reuse normalization differs from original firmware proof')
    pins[receipt]=args.prep_receipt_sha256
    return pins


def accepted(proof_path, proof_sha):
    """Validate every acceptance child before any native API or output mutation."""
    proof = document(proof_path, proof_sha)
    if (proof.get('schema') != 'minios-install-native-v1' or proof.get('passed') is not True
            or proof.get('dirty') != 0 or not re.fullmatch(r'[0-9a-f]{40}', proof.get('head', ''))
            or proof.get('boot_attempted') is not False or proof.get('deleted') is not False
            or proof.get('source_backing_chain_unchanged') is not True
            or proof.get('extra_full_raw_or_fixed_vhd_copies') != 0 or proof.get('mode') not in ('uefi', 'bios')):
        raise ValueError('Complete clean 1c-2 native PASS required before bcdboot')
    base = native.regular(oracle.owned(Path(proof['vhd'])))
    reuse=proof.get('reused_prepared_vhd',False)
    if type(reuse) is not bool:raise ValueError('Explicit native reuse boolean required')
    reuse_pins=prepared_base_pins(proof,base) if reuse else {}
    if ((not reuse and base.parent != proof_path.parent) or base.suffix != '.vhd'
            or base.stat().st_size != proof['vhd_bytes']
            or not getattr(base.stat(), 'st_file_attributes', 0) & 1
            or getattr(base.stat(), 'st_file_attributes', 0) & 0x200):
        raise ValueError('Exact ordinary readonly base VHD required')
    layout_path = proof_path.parent / 'layout.json'
    layout = document(layout_path, proof['layout_sha256'])
    if (layout.get('schema') != 'minios-install-layout-v1' or layout.get('mode') != proof['mode']
            or layout.get('image_bytes') != proof['virtual_bytes'] or layout.get('sector_bytes') != 512):
        raise ValueError('Accepted virtual geometry/layout differs')
    rows = {row['number']: row for row in layout['partitions'] if row['filesystem'] is not None}
    expected = {layout['system_number'], layout['windows_number']}
    if set(rows) != expected or len(rows) != 2 or layout['system_number'] != 1:
        raise ValueError('Exact two-filesystem installation required')
    result_rows = proof.get('native_results', [])
    if len(result_rows) != 2 or {row.get('number') for row in result_rows} != expected:
        raise ValueError('All filesystem gates must precede bcdboot')
    pins = {proof_path: proof_sha, layout_path: proof['layout_sha256']}
    pins.update(reuse_pins)
    for row in result_rows:
        relative = Path(row['result'])
        if (relative.is_absolute() or relative.drive or '..' in relative.parts
                or any(char in str(relative) for char in ':,\r\n\0')):
            raise ValueError('Unsafe native child receipt path')
        path = proof_path.parent / relative
        child = document(path, row['sha256'])
        wanted = rows[row['number']]
        if (row.get('chkdsk_exit') != 0 or row.get('filesystem') != wanted['filesystem']
                or child.get('passed') is not True or child.get('chkdsk_exit') != 0):
            raise ValueError('One filesystem acceptance failed')
        # Native FAT and NTFS oracle receipts deliberately have different
        # field names; their exact hash is already pinned by the parent gate.
        pins[path] = row['sha256']
    reader = native.DynamicVhd(base)
    try:
        if reader.size != proof['virtual_bytes'] or native.disk_layout(reader, proof['mode']) != layout:
            raise ValueError('Independent base VHD layout changed')
    finally:
        reader.close()
    if oracle.digest(base) != proof['vhd_sha256']:
        raise ValueError('Accepted base VHD changed')
    pins[base] = proof['vhd_sha256']
    return proof, layout, pins


def run(args):
    # Permanent policy, independent of native acceptance or temporary DISM gates.
    # Keep document()/accepted() for offline validation of historical receipts.
    raise ValueError('HOST_BCDBOOT_FORBIDDEN: use the offline REGF writer; host execution is permanently disabled')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('native-receipt', 'out', 'plan', 'pwsh'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--native-receipt-sha256', required=True)
    print(json.dumps(run(parser.parse_args())))
