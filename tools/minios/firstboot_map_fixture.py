#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Read back a closed own32MiB BIOS fixture through real qemu-img map.

This launches no VM and creates no image/export. It is not a Windows boot gate.
"""
import argparse
import contextlib
import hashlib
import json
from pathlib import Path
import subprocess

import bcdboot_reference as reference
import install_firmware_case as commands
import install_native as native
import logged_run
import qcow_map_readonly
import wim_oracle as oracle

REPO=Path(__file__).resolve().parents[2]


def run(args):
    oracle.owned(args.out)
    if args.out.exists() or not args.out.is_relative_to(oracle.RUNTIME/'1c23/hive-bcd'):
        raise ValueError('Fresh small reserved map-evidence output required')
    oracle.local(args.qemu_img)
    head,dirty=logged_run.tree(REPO)
    if dirty:raise ValueError('F3: clean frozen HEAD required')
    with contextlib.ExitStack() as locks:
        proof_path=native.regular(oracle.owned(args.fixture_result))
        locks.enter_context(oracle.readonly(proof_path))
        proof=reference.document(proof_path,args.fixture_sha256)
        if (proof.get('schema')!='minios-own-bios-handoff-v1' or proof.get('passed') is not True
            or proof.get('microsoft_payload') is not False or proof.get('windows_boot_test') is not False
            or proof.get('image_bytes')!=32*1024**2 or proof.get('dirty')!=0):
            raise ValueError('Completed own32MiB no-Windows fixture required')
        matches=[row for row in proof.get('results',[]) if row.get('cpu')=='486' and row.get('passed') is True]
        if len(matches)!=1 or matches[0]['overlay']!='486.qcow2':raise ValueError('One exact closed fixture overlay required')
        target=proof_path.parent/'486.qcow2';base=proof_path.parent/'own-abi.raw'
        chain=native.qcow_chain(target,proof['image_bytes'])
        if chain!=[target,base]:raise ValueError('Expected exact own fixture chain')
        files=[locks.enter_context(oracle.readonly(path)) for path in chain]
        pins=[matches[0]['overlay_sha256'],proof['image_sha256']]
        if any(oracle.digest_stream(file)!=sha for file,sha in zip(files,pins)):
            raise ValueError('Own fixture bytes changed')
        args.out.mkdir(parents=True)
        env=oracle.environment(args.out)
        command=list(map(str,[args.qemu_img,'map','-f','qcow2','--output=json',target]))
        oracle.save(args.out/'map-command.json',dict(head=head,dirty=0,command=command,closed_fixture=True))
        with (args.out/'map.json').open('xb') as output,(args.out/'map.stderr').open('xb') as stderr:
            stderr.write(commands.capture_header(head));stderr.flush()
            result=subprocess.run(command,stdin=subprocess.DEVNULL,stdout=output,stderr=stderr,timeout=60,env=env,
                                  creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        if result.returncode:raise ValueError('Real fixture map failed')
        map_path=args.out/'map.json'
        if map_path.stat().st_size>1024**2:raise ValueError('Small fixture map bound exceeded')
        reader=qcow_map_readonly.Reader(json.loads(map_path.read_text()),files,proof['image_bytes'])
        digest=hashlib.sha256()
        while reader.position<reader.size:digest.update(reader.read(min(65536,reader.size-reader.position)))
        actual=digest.hexdigest()
        unchanged=all(oracle.digest_stream(file)==sha for file,sha in zip(files,pins))
        if logged_run.tree(REPO)!=(head,0):raise ValueError('F3: tree changed')
        receipt=dict(schema='minios-firstboot-map-fixture-v1',head=head,dirty=0,passed=actual==proof['image_sha256'] and unchanged,
                     logical_sha256=actual,expected_sha256=proof['image_sha256'],virtual_bytes=reader.size,
                     base_unchanged=unchanged,fixture_receipt_sha256=args.fixture_sha256,
                     map_sha256=oracle.digest(map_path),vm_started=False,microsoft_payload=False,
                     windows_boot_gate=False,new_image_or_export_created=False,deleted=[])
        oracle.save(args.out/'result.json',receipt)
        return receipt


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('fixture-result','qemu-img','out'):parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--fixture-sha256',required=True)
    result=run(parser.parse_args());print(json.dumps(result))
    raise SystemExit(0 if result['passed'] else 1)
