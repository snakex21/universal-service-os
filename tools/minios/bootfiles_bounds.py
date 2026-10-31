# SPDX-License-Identifier: GPL-3.0-or-later
"""Bounded bootfiles QEMU, images and event-driven completion waits."""
import asyncio
import ctypes
import json
import os
from pathlib import Path
import subprocess

import firstboot_bounds
import firstboot_output

MIB=1024**2
UTILITY=65*MIB
TARGET=128*MIB
BOOT=8*MIB
MISC=7*MIB
SCOPE=208*MIB
assert UTILITY+TARGET+BOOT+MISC==SCOPE

def new_sparse_container(path, maximum):
    if os.name!='nt' or maximum not in (BOOT,TARGET): raise ValueError('Exact Windows container bound required')
    path=Path(path)
    if path.suffix.lower()!='.qcow2': raise ValueError('Fresh QCOW2 container required')
    # Exclusive create of the exact caller-owned path; no pre-existing file
    # can be truncated or replaced. QMP receives only this file afterward.
    with path.open('xb') as f:
        import msvcrt
        returned=ctypes.c_ulong()
        kernel=ctypes.WinDLL('kernel32',use_last_error=True)
        kernel.DeviceIoControl.argtypes=[ctypes.c_void_p,ctypes.c_uint32,ctypes.c_void_p,ctypes.c_uint32,ctypes.c_void_p,ctypes.c_uint32,ctypes.POINTER(ctypes.c_ulong),ctypes.c_void_p]
        if not kernel.DeviceIoControl(msvcrt.get_osfhandle(f.fileno()),0x900c4,None,0,None,0,ctypes.byref(returned),None):raise ctypes.WinError(ctypes.get_last_error())
        f.truncate(maximum);f.flush();os.fsync(f.fileno())

async def create_bounded(qemu,path,maximum,virtual,backing,backing_format,env):
    if maximum not in (BOOT,TARGET) or backing_format not in ('qcow2','raw') or virtual<=0:
        raise ValueError('Exact bounded container geometry required')
    new_sparse_container(path,maximum)
    command=[str(qemu),'-machine','none','-nodefaults','-display','none','-qmp','stdio']
    p=await asyncio.create_subprocess_exec(*command,stdin=asyncio.subprocess.PIPE,stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,env=env,limit=MIB,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
    events=[]
    try:
        async def read():
            data=await asyncio.wait_for(p.stdout.readline(),30)
            if not data:raise ValueError('QMP closed during bounded image creation')
            return json.loads(data)
        async def call(command,args=None):
            obj={'execute':command}
            if args is not None:obj['arguments']=args
            p.stdin.write(json.dumps(obj).encode()+b'\n');await p.stdin.drain()
            while True:
                event=await read()
                if 'event' in event:
                    events.append(event)
                    if len(events)>128:raise ValueError('Excess QMP image-creation events')
                    continue
                if 'error' in event:raise ValueError('QMP: '+str(event['error']))
                if 'return' in event:return event['return']
        greeting=await read()
        if 'QMP' not in greeting:raise ValueError('Missing QMP greeting')
        await call('qmp_capabilities')
        await call('blockdev-add',{'driver':'file','node-name':'f','filename':str(path)})
        await call('blockdev-add',{'driver':'raw','node-name':'bound','file':'f','size':maximum})
        await call('blockdev-create',{'job-id':'make','options':{'driver':'qcow2','file':'bound',
            'size':virtual,'backing-file':str(backing),'backing-fmt':backing_format}})
        while not any(e.get('event')=='JOB_STATUS_CHANGE' and e.get('data',{}).get('id')=='make' and e.get('data',{}).get('status')=='concluded' for e in events):
            event=await read();events.append(event)
            if len(events)>128:raise ValueError('Excess QMP image-creation events')
        jobs=await call('query-jobs')
        selected=[j for j in jobs if j.get('id')=='make']
        if len(selected)!=1 or selected[0].get('error'):raise ValueError('Bounded QCOW2 creation failed: '+str(selected))
        await call('job-dismiss',{'id':'make'});await call('quit');await asyncio.wait_for(p.wait(),15)
    finally:
        if p.returncode is None:p.kill();await p.wait()
    if Path(path).stat().st_size!=maximum:raise ValueError('Container exceeded fixed bound')

async def snapshot_bounded(qemu,path,maximum,env):
    if maximum!=TARGET or Path(path).stat().st_size!=maximum:raise ValueError('Exact target container required')
    p=await asyncio.create_subprocess_exec(str(qemu),'-machine','none','-nodefaults','-display','none','-qmp','stdio',
        stdin=asyncio.subprocess.PIPE,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.DEVNULL,
        env=env,limit=MIB,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
    try:
        async def read():
            data=await asyncio.wait_for(p.stdout.readline(),30)
            if not data:raise ValueError('QMP closed during bounded snapshot')
            return json.loads(data)
        async def call(command,args=None):
            obj={'execute':command}
            if args is not None:obj['arguments']=args
            p.stdin.write(json.dumps(obj).encode()+b'\n');await p.stdin.drain()
            for _ in range(128):
                value=await read()
                if 'event' in value:continue
                if 'error' in value:raise ValueError('QMP: '+str(value['error']))
                if 'return' in value:return value['return']
            raise ValueError('Excess snapshot QMP events')
        if 'QMP' not in await read():raise ValueError('Missing QMP greeting')
        await call('qmp_capabilities')
        await call('blockdev-add',{'driver':'file','node-name':'f','filename':str(path)})
        await call('blockdev-add',{'driver':'raw','node-name':'bound','file':'f','size':maximum})
        await call('blockdev-add',{'driver':'qcow2','node-name':'target','file':'bound'})
        await call('blockdev-snapshot-internal-sync',{'device':'target','name':'bootfiles'})
        await call('blockdev-del',{'node-name':'target'});await call('blockdev-del',{'node-name':'bound'});await call('blockdev-del',{'node-name':'f'})
        await call('quit');await asyncio.wait_for(p.wait(),15)
    finally:
        if p.returncode is None:p.kill();await p.wait()
    if Path(path).stat().st_size!=maximum:raise ValueError('Snapshot escaped fixed bound')

def nodes(path, name, maximum):
    if name not in ('boot','target') or maximum not in (BOOT,TARGET):
        raise ValueError('Exact bounded bootfiles devices required')
    generated=firstboot_bounds.blockdev_arguments(path,maximum=maximum)
    replacements={'firstboot-file':name+'-file','firstboot-limit':name+'-limit','windows':name}
    result=[]
    for i in range(0,len(generated),2):
        if generated[i]!='-blockdev': raise ValueError('Unexpected blockdev form')
        obj=json.loads(generated[i+1])
        for key in ('node-name','file'):
            if isinstance(obj.get(key),str) and obj[key] in replacements:obj[key]=replacements[obj[key]]
        result.extend(['-blockdev',json.dumps(obj,separators=(',',':'))])
    return result

async def run_qemu(command,debug_path,stderr_path,env,timeout,header=b'',*,debug_limit=2*MIB,stderr_limit=MIB):
    if not 1 <= timeout <= 900: raise ValueError('Bounded timeout required')
    loop=asyncio.get_running_loop(); failed=loop.create_future()
    with firstboot_output.Sink(debug_path,debug_limit) as debug, firstboot_output.Sink(stderr_path,stderr_limit) as stderr:
        debug.write(header);stderr.write(header)
        child=await asyncio.create_subprocess_exec(*map(str,command),stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE,env=env,
            creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        pumps=[asyncio.create_task(firstboot_output.drain(child.stdout,debug,failed)),
               asyncio.create_task(firstboot_output.drain(child.stderr,stderr,failed))]
        done=asyncio.create_task(child.wait())
        try:
            result,_=await asyncio.wait({done,failed},timeout=timeout,return_when=asyncio.FIRST_COMPLETED)
            if failed.done(): raise ValueError('Bounded QEMU output: '+str(failed.result()))
            if done not in result: raise TimeoutError('Bounded bootfiles QEMU timed out')
            await asyncio.gather(*pumps)
            if failed.done(): raise ValueError('Bounded QEMU output: '+str(failed.result()))
            return done.result()
        finally:
            if not done.done():child.kill()
            await asyncio.wait_for(asyncio.shield(done),15)
            await asyncio.wait_for(asyncio.gather(*pumps),15)
