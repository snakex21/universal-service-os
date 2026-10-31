#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Serial read-only host measurements of firmware LZX and SHA-1, not VM speed."""
import argparse
import contextlib
import json
from pathlib import Path
import re
import subprocess

import install_native as native
import logged_run
import wim_oracle as oracle

REPO=Path(__file__).resolve().parents[2]


def build_proof(text,head,arch):
    if (not text.startswith(f'HEAD {head}\nWORKTREE_DIRTY 0\n') or f'HEAD_AFTER {head}\nWORKTREE_DIRTY_AFTER 0' not in text
        or not re.search(r'^EXIT 0$',text,re.M)):
        raise ValueError('Completed clean same-HEAD benchmark build log required')
    commands=re.findall(r'^COMMAND (.+)$',text,re.M)
    if len(commands)!=1:raise ValueError('One exact compiler command required')
    command=json.loads(commands[0])
    target='x86_64-windows' if arch=='x86_64' else 'x86-windows'
    if ('src/prep/wim_bench.zig' not in command or '-target' not in command
        or command[command.index('-target')+1]!=target or '-O' not in command
        or command[command.index('-O')+1]!='ReleaseSmall'
        or (arch=='x86' and ('-mcpu' not in command or command[command.index('-mcpu')+1]!='i486'))):
        raise ValueError('Actual firmware optimization and explicit architecture required')
    return command


def measurement(text,arch):
    rows=re.findall(r'^BENCH_RESULT (.+)$',text,re.M)
    if len(rows)!=1:raise ValueError('One complete benchmark result required')
    row=json.loads(rows[0])
    if (row.get('arch')!=arch or row.get('optimize')!='ReleaseSmall' or row.get('sha1_verified') is not True
        or row.get('timed_io') is not False or (arch=='x86' and row.get('cpu')!='i486')
        or not re.fullmatch('[0-9a-f]{40}',row.get('sha1',''))):
        raise ValueError('Actual codec/sample identity or isolated measurement differs')
    for field in ('size','stored','lzx_chunks','decoder_bytes','decoder_ns','sha_bytes','sha_ns','allocator_peak'):
        if type(row.get(field)) is not int or row[field]<=0:raise ValueError('Positive exact measurement counters required')
    if not 1024**2<=row['size']<=4*1024**2 or row['stored']>4*1024**2 or row['allocator_peak']>12*1024**2:
        raise ValueError('Bounded sample/allocation required')
    for stage in ('decoder','sha'):
        row[stage+'_mib_per_second']=row[stage+'_bytes']*1e9/row[stage+'_ns']/1024**2
    return row


def run(args):
    oracle.owned(args.out)
    if args.out.exists() or not args.out.is_relative_to(oracle.RUNTIME/'1c23/final-logs') or not args.out.name.startswith('lzx-sha-bench'):
        raise ValueError('Fresh small final-logs/lzx-sha-bench* evidence required')
    if len(args.wim)!=len(set(args.wim)) or not 1<=len(args.wim)<=3:raise ValueError('One to three distinct real WIMs required')
    head,dirty=logged_run.tree(REPO)
    if dirty:raise ValueError('F3: clean benchmark snapshot required')
    with contextlib.ExitStack() as locks:
        inputs={};programs={}
        for arch in ('x86_64','x86'):
            program=native.regular(oracle.local(getattr(args,arch)))
            log=native.regular(oracle.local(getattr(args,arch+'_build_log')))
            source=locks.enter_context(oracle.readonly(log));program_source=locks.enter_context(oracle.readonly(program))
            if log.stat().st_size>1024**2:raise ValueError('Bounded build proof required')
            build_proof(log.read_text(encoding='utf-8-sig'),head,arch)
            inputs[program]=(program_source,oracle.digest_stream(program_source))
            inputs[log]=(source,oracle.digest_stream(source));programs[arch]=program
        for path in args.wim:
            path=native.regular(oracle.owned(path))
            if not path.is_relative_to(oracle.RUNTIME/'inputs') or path.suffix.lower()!='.wim':raise ValueError('Retained real input WIM required')
            source=locks.enter_context(oracle.readonly(path))
            inputs[path]=(source,oracle.digest_stream(source))
        oracle.storage_guard(8*1024**2)
        args.out.mkdir(parents=True)
        env=oracle.environment(args.out)
        rows=[]
        for number,path in enumerate(args.wim):
            paired=[]
            for arch in ('x86_64','x86'):
                command=[str(programs[arch]),str(path),'16','256']
                log=args.out/f'{number}-{arch}.log'
                with log.open('x',encoding='utf-8',newline='\n') as output:
                    output.write(f'HEAD {head}\nWORKTREE_DIRTY 0\nCOMMAND '+json.dumps(command)+'\n');output.flush()
                    result=subprocess.run(command,stdin=subprocess.DEVNULL,stdout=output,stderr=subprocess.STDOUT,
                                          env=env,timeout=180,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
                    output.write(f'EXIT {result.returncode}\nHEAD_AFTER {head}\nWORKTREE_DIRTY_AFTER 0\n')
                if result.returncode:raise ValueError('Benchmark failed; evidence retained')
                row=measurement(log.read_text(),arch)
                row.update(wim=str(path.relative_to(oracle.RUNTIME)),wim_sha256=inputs[path][1],program_sha256=inputs[programs[arch]][1],log=log.name)
                paired.append(row);rows.append(row)
            if any(paired[0][field]!=paired[1][field] for field in ('resource','offset','size','stored','sha1')):
                raise ValueError('Architectures measured different real resources')
        unchanged=all(oracle.digest_stream(source)==sha for source,sha in inputs.values())
        if logged_run.tree(REPO)!=(head,0):raise ValueError('F3: source tree changed during benchmark')
        receipt=dict(schema='minios-firmware-lzx-sha-host-benchmark-v1',head=head,dirty=0,passed=unchanged,
                     rows=rows,immutable_inputs_unchanged=unchanged,sequential=True,timed_io=False,
                     interpretation='Native-host ISA-specific CPU throughput; not QEMU, physical i486 speed, or full WIM apply throughput',
                     vm_started=False,images_created=0,deleted=[])
        oracle.save(args.out/'result.json',receipt)
        return receipt


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('x86_64','x86','x86_64-build-log','x86-build-log','out'):parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--wim',type=Path,action='append',required=True)
    result=run(parser.parse_args());print(json.dumps(result))
    raise SystemExit(0 if result['passed'] else 1)
