#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Real local QEMU/qemu-io runner gate; own empty fixtures, never Windows."""
import argparse
import asyncio
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

import firstboot_bounds as b
import firstboot_output as o
import firstboot_qmp as q
import logged_run
import windows_firstboot_case as c
import wim_oracle as oracle
import wim_pool as pool


def run(args):
    head,dirty=logged_run.tree(c.REPO)
    if dirty:raise ValueError('Clean fixture tree required')
    out=oracle.owned(args.out)
    if out.exists():raise ValueError('Fresh fixture output required')
    capacity=pool.enforce_incremental(args.plan,out,2*1024**3,closed_scope=True)
    out.mkdir(parents=True)
    img=args.qemu_dir/'qemu-img.exe';io=args.qemu_dir/'qemu-io.exe'
    def command(values,expect=0):
        result=subprocess.run(list(map(str,values)),capture_output=True,timeout=30,
            creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        if len(result.stdout)+len(result.stderr)>1024**2:raise ValueError('Fixture output excess')
        text=(result.stdout+result.stderr).decode(errors='replace')
        print(text,flush=True)
        if expect==0 and result.returncode!=0:raise ValueError('Fixture command failed')
        if expect!=0 and result.returncode==0:raise ValueError('Expected envelope refusal')
        return dict(command=list(map(str,values)),exit=result.returncode,output=text)
    base=out/'empty-base.qcow2'
    command([img,'create','-f','qcow2',base,'64M'])
    original=oracle.digest(base)
    target=out/'limited.qcow2'
    command([img,'create','-f','qcow2','-F','qcow2','-b',base,target])
    command([img,'snapshot','-c','firstboot-base',target])
    envelope=b.pad(target,64*1024**2,8*1024**2)
    graph=json.dumps(dict(driver='qcow2',file=dict(driver='raw',offset=0,size=8*1024**2,
        file=dict(driver='file',filename=str(target)))))
    good=command([io,'-c','write -P 0x51 0 1M','json:'+graph])
    full=command([io,'-c','write -P 0x52 1M 31M','json:'+graph],expect=1)
    if target.stat().st_size!=8*1024**2 or oracle.digest(base)!=original:
        raise ValueError('Envelope/backing changed size/identity')
    case=out/'qemu';case.mkdir()
    overlay=case/'windows.qcow2'
    command([img,'create','-f','qcow2','-F','qcow2','-b',base,overlay])
    command([img,'snapshot','-c','firstboot-base',overlay])
    b.pad(overlay,64*1024**2)
    shutil.copyfile(args.qemu_dir/'share/edk2-i386-vars.fd',case/'vars.fd')
    args.arch='x86_64'
    cmd=c.command_for(args,case)+['-S'] # no guest instruction executes
    started=time.monotonic()
    evidence=asyncio.run(q.endpoint(cmd,case,os.environ.copy(),2,header=f'HEAD {head}\nWORKTREE_DIRTY 0\n'.encode()))
    if (evidence.get('returncode')!=0 or not evidence.get('screenshot_created') or
        evidence.get('transport_error') or not (case/'endpoint.ppm').read_bytes().startswith(b'P6')):
        raise ValueError('Real QEMU fixed pflash/stdio/bounded PPM gate failed: '+json.dumps(evidence))
    if overlay.stat().st_size!=b.CONTAINER_BYTES or oracle.digest(base)!=original:
        raise ValueError('Actual QEMU escaped fixed container or changed base')
    retained=o.Scope(case).audit()
    # A child runner's native job deadline must terminate a sleeping descendant.
    child_code=('import sys,time,subprocess;sys.path.insert(0,sys.argv[1]);'
        'from firstboot_lifetime import Lifetime;from pathlib import Path;'
        'x=Lifetime(60,Path(sys.argv[2]));'
        'subprocess.Popen([sys.executable,"-c","import time;time.sleep(60)"]);'
        'x.timer.cancel();import threading;threading.Timer(0.2,x.expire).start();time.sleep(60)')
    deadline=subprocess.run([sys.executable,'-c',child_code,str(Path(__file__).parent),str(out/'not-created')],
        capture_output=True,timeout=5,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
    if deadline.returncode!=124:raise ValueError('Whole-operation native job deadline failed: '+str(deadline))
    result=dict(schema='minios-firstboot-native-fixture-v1',head=head,dirty=0,passed=True,
        windows_booted=False,physical_disks_opened=False,envelope=envelope,valid_write=good,
        full_refusal=full,base_unchanged=True,qemu=evidence,qemu_elapsed=time.monotonic()-started,
        scope_retained_bytes=retained,whole_operation_job_deadline_exit=deadline.returncode,
        capacity_preflight=capacity,deleted=[])
    oracle.save(out/'result.json',result)
    return result


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('plan','qemu-dir','out'):parser.add_argument('--'+name,type=Path,required=True)
    print(json.dumps(run(parser.parse_args())))
