#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Owned fresh-image ISO/NTFS/WIM integration and existing read-only VHD gate."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import logged_run
import wim_oracle as oracle
import wim_pool as pool

REPO=Path(__file__).resolve().parents[2]
GiB=1024**3


def execute(command,log,env,timeout=3600):
    head,dirty=logged_run.tree(REPO)
    if dirty:raise ValueError('Integration evidence requires a clean tree')
    with log.open('x',encoding='utf-8',newline='\n') as output:
        output.write(f'HEAD {head}\nWORKTREE_DIRTY 0\nCOMMAND {json.dumps(list(map(str,command)))}\n');output.flush()
        result=subprocess.run(list(map(str,command)),cwd=REPO,env=env,stdout=output,stderr=subprocess.STDOUT,timeout=timeout)
        output.write(f'EXIT {result.returncode}\n')
    if logged_run.tree(REPO)!=(head,0):raise ValueError('Tree changed during gate')
    if result.returncode:raise ValueError(f'Command failed; retained {log}')


def blank(out,size,qemu,env):
    base=out/'blank-base.qcow2';cow=out/'test-cow.qcow2';raw=out/'target.raw'
    execute([qemu,'create','-f','qcow2',base,str(size)],out/'base-create.log',env)
    execute([qemu,'snapshot','-c','base',base],out/'base-snapshot.log',env)
    pin=oracle.digest(base)
    execute([qemu,'create','-f','qcow2','-F','qcow2','-b',base,cow],out/'cow-create.log',env)
    execute([qemu,'convert','-f','qcow2','-O','raw',cow,raw],out/'raw-create.log',env)
    if raw.stat().st_size!=size or oracle.digest(base)!=pin:raise ValueError('Blank base changed')
    return raw,base,pin


def expectations(args,source_sha):
    if not args.expected_tree or not args.expected_security or not args.iso_proof:
        raise ValueError('Independent WIM manifests and completed ISO/7-Zip proof required')
    for path in (args.expected_tree,args.expected_security,args.iso_proof):oracle.owned(path)
    manifest_path=args.expected_tree.parent/'manifest.json'
    oracle.owned(manifest_path)
    manifest=json.loads(manifest_path.read_text(encoding='utf-8'))
    proof=json.loads(args.iso_proof.read_text(encoding='utf-8'))
    if (proof.get('passed') is not True or proof.get('worktree_dirty')!=0 or proof.get('source_unchanged') is not True
        or proof.get('iso_mounted') is not False or proof.get('extracted_tree') is not False
        or proof.get('difference_count')!=0 or proof.get('sevenzip_exit')!=0):
        raise ValueError('ISO proof is not a complete clean read-only 7-Zip pass')
    actual=args.iso_proof.parent/'actual.jsonl'
    if oracle.digest(actual)!=proof.get('actual_manifest_sha256'):
        raise ValueError('ISO file manifest pin mismatch')
    matches=[]
    with actual.open(encoding='utf-8') as rows:
        for line in rows:
            row=json.loads(line)
            if row['path'].replace('\\','/').lower()=='sources/install.wim' and not row['directory']:matches.append(row)
    if len(matches)!=1 or matches[0]['sha256']!=manifest.get('wim_sha256') or manifest.get('index')!=args.index:
        raise ValueError('Expected WIM index/hash does not bind this ISO source')
    tree_sha=oracle.digest(args.expected_tree);security_sha=oracle.digest(args.expected_security)
    if tree_sha!=manifest.get('tree_sha256') or security_sha!=manifest.get('security_sha256'):
        raise ValueError('Expected WIM tree/security pins differ')
    if args.partition_bytes:
        if not args.pack_proof:raise ValueError('NTFS source requires its pack receipt')
        oracle.owned(args.pack_proof)
        pack=json.loads(args.pack_proof.read_text(encoding='utf-8'))
        if (pack.get('passed') is not True or pack.get('target_sha256')!=source_sha
            or pack.get('source_sha256')!=proof['iso_sha256'] or pack.get('target')!=str(args.source)
            or pack.get('partition_start')!=args.partition_start or pack.get('partition_bytes')!=args.partition_bytes):
            raise ValueError('NTFS pack does not bind this ISO proof/partition')
    elif source_sha!=proof['iso_sha256']:
        raise ValueError('ISO source hash differs from oracle proof')
    return dict(iso_proof_sha256=oracle.digest(args.iso_proof),expected_manifest_sha256=oracle.digest(manifest_path),
                expected_tree_sha256=tree_sha,expected_security_sha256=security_sha,
                install_wim_sha256=manifest['wim_sha256'],selected_index=args.index)


def validate_size(action,size_gib):
    if size_gib not in (6,12,16) and not (action=='pack' and size_gib==3):
        raise ValueError('Three GiB is source-pack only; apply requires6,12or16GiB')


def run(args):
    validate_size(args.action,args.size_gib)
    oracle.owned(args.out);oracle.local(args.exe);oracle.local(args.source)
    if args.out.exists():raise ValueError('New owned output required')
    capacity=pool.enforce(args.plan,args.out)
    head,dirty=logged_run.tree(REPO)
    if dirty:raise ValueError('Clean tree required')
    args.out.mkdir(parents=True)
    env=oracle.environment(args.out)
    with oracle.readonly(args.source):
        result=run_locked(args,head,env)
    if logged_run.tree(REPO)!=(head,0):raise ValueError('Tree changed across integration steps')
    oracle.save(args.out/'result.json',result)
    return result


def run_locked(args,head,env):
    source_sha=oracle.digest(args.source);program_sha=oracle.digest(args.exe)
    if args.action=='pack':
        if not args.iso_proof:raise ValueError('Pack requires the completed ISO proof before writing')
        oracle.owned(args.iso_proof)
        proof=json.loads(args.iso_proof.read_text(encoding='utf-8'))
        expected_rows=args.iso_proof.parent/'expected.jsonl'
        if (proof.get('passed') is not True or proof.get('worktree_dirty')!=0 or proof.get('iso_sha256')!=source_sha
            or proof.get('iso_mounted') is not False or proof.get('extracted_tree') is not False
            or proof.get('difference_count')!=0 or proof.get('sevenzip_exit')!=0
            or oracle.digest(expected_rows)!=proof.get('expected_manifest_sha256')):
            raise ValueError('Pack source/proof mismatch before target creation')
        expected=dict(iso_proof_sha256=oracle.digest(args.iso_proof),expected_iso_tree_sha256=oracle.digest(expected_rows))
    else:expected=expectations(args,source_sha)
    raw,base,base_sha=blank(args.out,args.size_gib*GiB,args.qemu_img,env)
    if args.action=='pack':
        command=[args.exe,'pack-ntfs',args.source,raw,'--image-only',oracle.RUNTIME]
    else:
        mode='ntfs-apply' if args.partition_bytes else 'apply'
        command=[args.exe,mode,args.source]
        if args.partition_bytes:command += [str(args.partition_start),str(args.partition_bytes),'INSTALL.ISO']
        command += [raw,str(args.index),'--image-only',oracle.RUNTIME]
    execute(command,args.out/'program.log',env)
    return finish_locked(args,head,env,source_sha,program_sha,raw,base,base_sha,expected)


def finish_locked(args,head,env,source_sha,program_sha,raw,base,base_sha,expected):
    text=(args.out/'program.log').read_text(encoding='utf-8')
    result=dict(schema='minios-optical-e2e-v1',action=args.action,head=head,dirty=0,
                source_sha256=source_sha,source_unchanged=oracle.digest(args.source)==source_sha,
                program_sha256=program_sha,program_unchanged=oracle.digest(args.exe)==program_sha,
                target=str(raw),target_bytes=raw.stat().st_size,target_sha256=oracle.digest(raw),
                base_sha256=base_sha,base_unchanged=oracle.digest(base)==base_sha,
                fresh_format=True,intermediate_wim_copy=False,physical_disks_opened=False,
                source_write_delete_denied=True,**expected)
    if args.action=='pack':
        match=re.search(r'ISO_ON_NTFS_COMPLETE start=(\d+) bytes=(\d+) file=INSTALL.ISO size=(\d+)',text)
        if not match:raise ValueError('Pack completion missing')
        result.update(partition_start=int(match[1]),partition_bytes=int(match[2]),iso_bytes=int(match[3]),passed=True)
        if not args.iso_proof:raise ValueError('NTFS source gate requires independent ISO proof')
        oracle.owned(args.iso_proof)
        proof=json.loads(args.iso_proof.read_text(encoding='utf-8'))
        expected_rows=args.iso_proof.parent/'expected.jsonl'
        if (proof.get('passed') is not True or proof.get('worktree_dirty')!=0 or proof.get('iso_sha256')!=source_sha
            or oracle.digest(expected_rows)!=proof.get('expected_manifest_sha256')
            or oracle.digest(args.iso_proof)!=expected['iso_proof_sha256']
            or oracle.digest(expected_rows)!=expected['expected_iso_tree_sha256']):
            raise ValueError('Pack source ISO does not bind the 7-Zip proof')
        os.chmod(raw,raw.stat().st_mode & ~stat.S_IWRITE)
        with oracle.readonly(raw):
            execute([args.exe,'ntfs-manifest',raw,str(result['partition_start']),str(result['partition_bytes']),'INSTALL.ISO'],args.out/'ntfs-manifest.log',env)
            actual=[json.loads(line[6:]) for line in (args.out/'ntfs-manifest.log').read_text(encoding='utf-8').splitlines() if line.startswith('ENTRY ')]
            with expected_rows.open(encoding='utf-8') as expected_file:expected_items=[json.loads(line) for line in expected_file]
            if sorted(actual,key=lambda row:row['path'])!=sorted(expected_items,key=lambda row:row['path']):
                raise ValueError('ISO-on-NTFS tree/hash differs from independent 7-Zip')
            if oracle.digest(raw)!=result['target_sha256']:raise ValueError('NTFS source changed during read')
        result.update(ntfs_manifest_verified=True,ntfs_iso_entries=len(actual),iso_proof_sha256=oracle.digest(args.iso_proof))
    else:
        if 'ISO_WIM_COMPLETE intermediate_copy=false' not in text or 'USOSPREP WIM PASS' not in text:
            raise ValueError('Apply completion missing')
        result['heap_peak']=int(re.search(r'OPTICAL_COMPLETE heap_peak=(\d+)',text)[1])
        os.chmod(raw,raw.stat().st_mode & ~stat.S_IWRITE)
        native=args.out/'native'
        execute([args.pwsh,'-NoProfile','-File',REPO/'tools/tests/minios_chkdsk_readonly.ps1',
                 '-Workspace',oracle.RUNTIME,'-RawCopy',raw,'-ExpectedImageBytes',str(result['target_bytes']),
                 '-ExpectedSha256',result['target_sha256'],'-QemuImg',args.qemu_img,'-Out',native,
                 '-ExpectedWimTreeJsonl',args.expected_tree,'-ExpectedWimSecurityJsonl',args.expected_security,
                 '-CheckTimeoutSeconds','3600'],args.out/'native-gate.log',env,7200)
        receipt=json.loads((native/'result.json').read_text(encoding='utf-8-sig'))
        result.update(native_result=str(native/'result.json'),native_result_sha256=oracle.digest(native/'result.json'),
                      chkdsk_exit=receipt['chkdsk_exit'],passed=receipt['passed'])
        # Raw stdout captures are also labelled before final evidence sealing;
        # the native receipt pins sources/manifests/VHD, not these captures.
        stamp=f'HEAD {head}\nWORKTREE_DIRTY 0\n'.encode('utf-8')
        for path in native.iterdir():
            if path.is_file() and path.suffix in ('.log','.txt'):
                data=path.read_bytes()
                if not data.startswith(b'HEAD '):path.write_bytes(stamp+data)
    result['passed']=result['passed'] and result['source_unchanged'] and result['program_unchanged'] and result['base_unchanged']
    result['capacity_plan_sha256']=oracle.digest(args.plan)
    result['log_sha256']=oracle.digest(args.out/'program.log')
    if args.action!='pack' and (oracle.digest(args.expected_tree)!=expected['expected_tree_sha256'] or oracle.digest(args.expected_security)!=expected['expected_security_sha256']):
        raise ValueError('Expected manifests changed during native gate')
    result['source_unchanged']=oracle.digest(args.source)==source_sha
    result['passed']=result['passed'] and result['source_unchanged']
    return result


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('action',choices=['pack','apply'])
    for name in ['source','exe','out','qemu-img','plan']:p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--pwsh',type=Path)
    p.add_argument('--size-gib',type=int,choices=[3,6,12,16],required=True)
    p.add_argument('--index',type=int,default=1)
    p.add_argument('--partition-start',type=int,default=1024*1024)
    p.add_argument('--partition-bytes',type=int,default=0)
    p.add_argument('--expected-tree',type=Path);p.add_argument('--expected-security',type=Path)
    p.add_argument('--iso-proof',type=Path);p.add_argument('--pack-proof',type=Path)
    a=p.parse_args();r=run(a);print(json.dumps(r));raise SystemExit(0 if r['passed'] else 1)
