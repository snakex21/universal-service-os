#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Bounded Windows-CopyFile ISO + native fragmentation, independent RO proof.

Creates a fresh 512 MiB VHD only below the pinned runtime, then retains VHD,
raw, original 2 MiB ISO and all receipts. No physical devices or cleanup.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

import inspect_ntfs as inspect
import optical_fixtures as fixtures
import optical_oracle as optical
import wim_oracle as guard
import wim_pool as pool


def own_iso():
    data=bytearray(fixtures.iso9660(joliet=True))
    data.extend(bytes(2*1024*1024-len(data)))
    for block in (16,17):
        fixtures.both(data,block*2048+80,'I',1024)
    return bytes(data)


def independent(raw,number):
    image=inspect.Image(raw)
    try:
        result=image.file_extents(number)
        base=image.record(number)
        attrs=list(inspect.attributes(base))
        selected={(number,a['id']):a for a in attrs if a['kind']==0x80 and not a['name']}
        for attr in attrs:
            if attr['kind']!=0x20:continue
            for entry in image.list_entries(image.attr_value(attr['data'])):
                if entry['kind']!=0x80 or entry['name']:continue
                reference=entry['reference']&((1<<48)-1)
                record=image.record(reference)
                values=[a for a in inspect.attributes(record) if a['kind']==0x80 and not a['name'] and a['id']==entry['id'] and a['lowest']==entry['lowest']]
                if len(values)!=1:raise ValueError('Independent AL match failed')
                selected[(reference,entry['id'])]=values[0]
        mapped=[run for attr in sorted(selected.values(),key=lambda a:a['lowest']) for run in inspect.runs(attr['data'])]
        payload=image.stream(mapped,0,result['size'])
        result.update(sha256=hashlib.sha256(payload).hexdigest(),attribute_extents=len(selected),
                      mft_attribute_list=any(a['kind']==0x20 for a in inspect.attributes(image.zero)))
        return result
    finally:image.file.close()


def run(command,log,label,timeout=600):
    with log.open('xb') as output:
        output.write(label.encode());output.flush()
        result=subprocess.run([str(v) for v in command],stdin=subprocess.DEVNULL,stdout=output,stderr=subprocess.STDOUT,timeout=timeout)
        output.write(('\nEXIT '+str(result.returncode)+'\n').encode())
    if result.returncode:raise ValueError('Fixture command failed: '+str(log))
    return log.read_text(encoding='utf8')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('plan','out','exe','qemu-img','pwsh','sevenzip'):parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--fixture',type=Path,help='Reuse one closed fixture read-only, no new image')
    parser.add_argument('--blank-vhd',type=Path,help='Reuse an owned all-zero blank fixed VHD as read-only template')
    parser.add_argument('--development',action='store_true')
    args=parser.parse_args()
    guard.owned(args.out);guard.owned(args.plan)
    capacity=pool.enforce(args.plan,args.out)
    head,dirty,label=optical.header(guard.REPO,not args.development)
    if args.out.exists():raise ValueError('New output directory required')
    args.out.mkdir(parents=True)
    if args.fixture:
        fixture=guard.owned(args.fixture)
        iso=fixture/'own.iso';native=fixture/'native';raw=fixture/'source.raw'
        native_receipt=optical.digest(native/'receipt.json')
        run([args.pwsh,'-NoProfile','-File',guard.REPO/'tools/tests/minios_ntfs_fragmented.ps1',
             '-Workspace',guard.RUNTIME,'-Iso',iso,'-QemuImg',args.qemu_img,'-Out',args.out/'native-ro',
             '-VerifyFixture',native,'-VerifyReceiptSha256',native_receipt],args.out/'native-ro.log',label)
        proof_receipt=args.out/'native-ro/receipt.json'
    else:
        fixture=args.out
        iso=fixture/'own.iso';native=fixture/'native';raw=fixture/'source.raw'
        iso.write_bytes(own_iso())
        command=[args.pwsh,'-NoProfile','-File',guard.REPO/'tools/tests/minios_ntfs_fragmented.ps1',
                 '-Workspace',guard.RUNTIME,'-Iso',iso,'-QemuImg',args.qemu_img,'-Out',native]
        if args.blank_vhd:command+=['-BlankVhd',guard.owned(args.blank_vhd)]
        run(command,args.out/'create.log',label)
        run([args.qemu_img,'convert','-f','vpc','-O','raw',native/'windows-fragmented.vhd',raw],args.out/'convert.log',label)
        proof_receipt=native/'receipt.json'
    receipt=json.loads(proof_receipt.read_text(encoding='utf-8-sig'))
    if receipt.get('passed') is not True or receipt.get('chkdsk_exit')!=0 or not receipt.get('dismounted'):
        raise ValueError('Windows copied/fragmented fixture lacks a completed readonly native gate')
    if raw.stat().st_size!=512*1024*1024:raise ValueError('Raw virtual image size differs')
    expected_iso=hashlib.sha256(own_iso()).hexdigest()
    if optical.digest(iso)!=expected_iso or receipt['source_iso_sha256']!=expected_iso:
        raise ValueError('Own ISO or native copy source differs')
    oracle=optical.compare(iso,args.exe,args.sevenzip,args.out/'iso-oracle',require_clean=not args.development)
    with guard.readonly(raw):
        raw_sha=optical.digest(raw)
        # Bind the native VHD chkdsk bytes to the exact raw bytes read by Zig.
        with guard.readonly(native/'windows-fragmented.vhd') as source:
            source.seek(0);digest=hashlib.sha256();remaining=raw.stat().st_size
            while remaining:
                block=source.read(min(1024*1024,remaining))
                if not block:raise ValueError('Truncated native VHD payload')
                digest.update(block);remaining-=len(block)
        if digest.hexdigest()!=raw_sha:raise ValueError('Native VHD payload differs from tested raw source')
        found=independent(raw,receipt['file_record'])
        if not found['attribute_list'] or found['run_count']<=128 or found['extension_records']==0 or found['sha256']!=expected_iso:
            raise ValueError('Independent bytes did not prove AL, >128 runs and identical complete ISO')
        text=run([args.exe,'ntfs-manifest',raw,receipt['partition_start'],receipt['partition_bytes'],'INSTALL.ISO'],args.out/'ntfs-read.log',label)
        rows=[json.loads(line[6:]) for line in text.splitlines() if line.startswith('ENTRY ')]
        expected=[json.loads(line) for line in (args.out/'iso-oracle/expected.jsonl').read_text(encoding='utf8').splitlines()]
        key=lambda row:row['path']
        if sorted(rows,key=key)!=sorted(expected,key=key):raise ValueError('NTFS→ISO independent tree/SHA differs')
        parsed=re.search(r'NTFS_ISO_SOURCE size=(\d+) runs=(\d+) attribute_extents=(\d+)',text)
        if not parsed or tuple(map(int,parsed.groups()))!=(found['size'],found['run_count'],found['attribute_extents']):
            raise ValueError('Own AL/run count differs from independent parser')
        if optical.digest(raw)!=raw_sha:raise ValueError('Read-only NTFS source changed')
    result=dict(schema='minios-ntfs-windows-fragmented-v1',head=head,worktree_dirty=dirty,passed=True,
                source_sha256=raw_sha,source_bytes=raw.stat().st_size,iso_sha256=expected_iso,
                native_receipt_sha256=optical.digest(proof_receipt),independent=found,
                own_rows=len(rows),tree_sha256=optical.digest(args.out/'iso-oracle/expected.jsonl'),
                native_chkdsk_exit=0,native_copy='Windows CopyFileW followed by FSCTL_MOVE_FILE',
                retained_images=[str(raw.relative_to(guard.RUNTIME)),str((native/'windows-fragmented.vhd').relative_to(guard.RUNTIME))],
                capacity_projected_bytes=capacity['projected_total_bytes'],target_writes=0)
    if not args.development and optical.header(guard.REPO)[:2]!=(head,0):raise ValueError('Tree changed during final evidence')
    guard.save(args.out/'result.json',result)
    print(json.dumps(result))


if __name__=='__main__':main()
