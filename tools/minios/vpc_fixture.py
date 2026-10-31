#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Retained own32MiB VHD proof; no guest, mount, Windows payload or cleanup."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path

import install_firmware_case as firmware
import install_native as native
import logged_run
import wim_oracle as oracle
import wim_pool as pool

REPO=Path(__file__).resolve().parents[2]
SIZE=32*1024**2
LIMIT=16*1024**2
PATTERN_BYTES=1024


def expected_digest(marker):
    if len(marker)!=512:raise ValueError('Exactly one own marker sector required')
    value=hashlib.sha256(marker);remaining=SIZE-len(marker)-PATTERN_BYTES
    zero=bytes(65536)
    while remaining:
        count=min(remaining,len(zero));value.update(zero[:count]);remaining-=count
    value.update(b'\x5a'*PATTERN_BYTES)
    return value.hexdigest()


def full_logical_digest(reader):
    if reader.size!=SIZE:raise ValueError('Own fixture exact virtual size differs')
    value=hashlib.sha256();reader.seek(0)
    while reader.position<reader.size:
        block=reader.read(min(65536,reader.size-reader.position))
        if not block:raise ValueError('Truncated fixture logical reader')
        value.update(block)
    return value.hexdigest()


def closed_command_json(path):
    lines=path.read_text(encoding='utf-8').splitlines()
    if (len(lines)<5 or not lines[0].startswith('HEAD ') or lines[1]!='WORKTREE_DIRTY 0' or
            not lines[2].startswith('COMMAND ') or lines[-1]!='EXIT 0'):
        raise ValueError('Completed clean command JSON log required')
    return json.loads('\n'.join(lines[3:-1]))


def run(args):
    oracle.owned(args.out);oracle.local(args.qemu_dir)
    if args.out.exists() or not args.out.is_relative_to(oracle.RUNTIME/'1c23/fixtures'):
        raise ValueError('Fresh reserved own fixture directory required')
    head,dirty=logged_run.tree(REPO)
    if dirty:raise ValueError('F3: frozen clean proof HEAD required')
    capacity=pool.enforce(args.plan,args.out)
    args.out.mkdir(parents=True);env=oracle.environment(args.out)
    token='5a'*32;prefix=b'USOSPREP TARGET v1\n'+token.encode()+b'\n'
    marker=prefix.ljust(512,b'\0');(args.out/'marker.bin').write_bytes(marker)
    target,blank=firmware.create_preparation_target(args.qemu_dir,args.out,SIZE,env,'vpc')
    blank_sha=oracle.digest(blank)
    # Exactly two allocated data blocks are sufficient to exercise separated
    # VHD BAT entries and sector bitmaps, without a32MiB RAW comparison copy.
    firmware.execute([args.qemu_dir/'qemu-io.exe','-f','vpc','-c',
                      f'write -P 0x5a {SIZE-PATTERN_BYTES} {PATTERN_BYTES}',target],
                     args.out/'known-write.log',env)
    prepared=firmware.seal_prepared_target(args.qemu_dir,args.out,SIZE,env,'vpc')
    wrapper=args.out/'target.qcow2';vhd_sha=prepared['prepared_vhd_sha256'];wrapper_sha=oracle.digest(wrapper)
    with oracle.readonly(target),oracle.readonly(wrapper),oracle.readonly(blank):
        reader=native.DynamicVhd(target)
        try:logical_sha=full_logical_digest(reader)
        finally:reader.close()
        expected_sha=expected_digest(marker)
        if logical_sha!=expected_sha:raise ValueError('Independent VHD logical SHA differs from own data')
        firmware.execute([args.qemu_dir/'qemu-img.exe','compare','-f','qcow2','-F','vpc',wrapper,target],
                         args.out/'wrapper-compare.log',env)
        firmware.execute([args.qemu_dir/'qemu-img.exe','info','-f','qcow2','--output=json',wrapper],
                         args.out/'wrapper-info.log',env)
        info=closed_command_json(args.out/'wrapper-info.log')
        if (info.get('virtual-size')!=SIZE or info.get('format')!='qcow2' or
                info.get('backing-filename')!=str(target) or info.get('backing-filename-format')!='vpc' or
                [row.get('name') for row in info.get('snapshots',[])]!=['prepared']):
            raise ValueError('Exact prepared wrapper geometry/backing/checkpoint differs')
        if oracle.digest(blank)!=blank_sha or oracle.digest(target)!=vhd_sha or oracle.digest(wrapper)!=wrapper_sha:
            raise ValueError('Frozen fixture image changed during read-only proof')
    retained=[dict(path=str(path.relative_to(args.out)),bytes=path.stat().st_size,sha256=oracle.digest(path))
              for path in sorted(args.out.rglob('*')) if path.is_file()]
    retained_bytes=sum(row['bytes'] for row in retained)
    if retained_bytes>LIMIT:raise ValueError('Own fixture exceeds16MiB retained budget')
    if logged_run.tree(REPO)!=(head,0):raise ValueError('F3: proof tree changed')
    result=dict(schema='minios-direct-vpc-fixture-v1',passed=True,head=head,dirty=0,
                virtual_bytes=SIZE,logical_sha256=logical_sha,expected_sha256=expected_sha,
                blank_checkpoint_sha256=blank_sha,blank_checkpoint_unchanged=True,
                wrapper_sha256=wrapper_sha,qemu_compare_exit=0,capacity_preflight=capacity,
                retained_bytes=retained_bytes,budget_bytes=LIMIT,retained=retained,
                guest_launched=False,mounted=False,physical_disks_opened=False,deleted=[],**prepared)
    oracle.save(args.out/'result.json',result)
    return result


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('out','plan','qemu-dir'):parser.add_argument('--'+name,type=Path,required=True)
    print(json.dumps(run(parser.parse_args())))
