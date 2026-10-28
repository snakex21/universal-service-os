#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Pre-write limits for every retained firstboot output; no progress polling."""
import asyncio
import contextlib
import ctypes as C
import json
import os
from pathlib import Path
import subprocess
import threading
import uuid

MiB = 1024**2
# Disjoint upper bounds. Panther has one aggregate 32MiB bound in collect().
LIMITS = {'windows.qcow2':1792*MiB, 'vars.fd':4*MiB,
          'overlay-create.log':MiB, 'base-snapshot.log':MiB,
          'envelope.json':MiB, 'qemu.stdout':16*MiB, 'qemu.stderr':16*MiB,
          'endpoint.ppm':32*MiB, 'qcow-map-command.json':MiB,
          'qcow-map.json':32*MiB, 'qcow-map.stderr':MiB,
          'panther-result.json':MiB, 'result.json':4*MiB, 'failure.json':MiB}
PANTHER_LIMIT = 32*MiB
SCOPE_LIMIT = 2*1024**3
assert sum(LIMITS.values())+PANTHER_LIMIT <= SCOPE_LIMIT


class Scope:
    def __init__(self, root):
        self.root = Path(root)

    def open(self, name, prefix=b''):
        if name not in LIMITS or name=='windows.qcow2':
            raise ValueError('Undeclared firstboot output')
        result = Sink(self.root/name, LIMITS[name])
        result.write(prefix)
        return result

    def save(self, name, value):
        data=(json.dumps(value,ensure_ascii=True,indent=2)+'\n').encode()
        with self.open(name) as stream: stream.write(data)

    def audit(self):
        total=panther=0
        for path in self.root.rglob('*'):
            info=path.lstat()
            if path.is_symlink() or getattr(info,'st_file_attributes',0)&0x400:
                raise ValueError('Link in firstboot output')
            if path.is_dir(): continue
            if info.st_nlink!=1: raise ValueError('Shared firstboot output')
            name=path.relative_to(self.root).as_posix()
            if name.startswith('panther/'):
                import firstboot_logs
                if name[8:] not in firstboot_logs.LOGS: raise ValueError('Unexpected Panther output')
                panther+=info.st_size
            elif name not in LIMITS or info.st_size>LIMITS[name]:
                raise ValueError('Unexpected/oversized firstboot output')
            total+=info.st_size
        if panther>PANTHER_LIMIT or total>SCOPE_LIMIT: raise ValueError('Firstboot budget exceeded')
        return total


class Sink:
    def __init__(self, path, maximum):
        self.file=Path(path).open('xb'); self.maximum=maximum; self.written=0
    def write(self, data):
        if len(data)>self.maximum-self.written: raise ValueError('Pre-write output limit: '+str(self.file.name))
        self.file.write(data); self.written+=len(data)
    def close(self): self.file.close()
    def __enter__(self): return self
    def __exit__(self,*_): self.close()


async def drain(reader, sink, failed):
    """Overflow wakes the owner, but keep draining/discarding until child EOF."""
    discard=False
    try:
        while data:=await reader.read(65536):
            if not discard:
                try: sink.write(data)
                except Exception as error:
                    discard=True
                    if not failed.done(): failed.set_result(str(error))
    except Exception as error:
        if not failed.done(): failed.set_result(str(error))


async def execute(command, scope, stdout_name, stderr_name, env, header=b'', timeout=60):
    failed=asyncio.get_running_loop().create_future()
    with scope.open(stdout_name,header) as out, scope.open(stderr_name,header) as err:
        child=await asyncio.create_subprocess_exec(*map(str,command),stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE,env=env,
            creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        pumps=[asyncio.create_task(drain(child.stdout,out,failed)),asyncio.create_task(drain(child.stderr,err,failed))]
        wait=asyncio.create_task(child.wait())
        try:
            done,_=await asyncio.wait({wait,failed},timeout=timeout,return_when=asyncio.FIRST_COMPLETED)
            if failed.done(): raise ValueError(failed.result())
            if wait not in done: raise ValueError('Bounded command timed out')
            await asyncio.gather(*pumps)
            if failed.done(): raise ValueError(failed.result())
            if wait.result()!=0: raise ValueError('Bounded command failed: '+str(wait.result()))
        finally:
            if not wait.done(): child.kill()
            await asyncio.wait_for(asyncio.shield(wait),15)
            await asyncio.wait_for(asyncio.gather(*pumps),15)


class ScreenshotPipe:
    """QEMU writes PPM into a private Windows named pipe, never directly to disk.

    Overlapped native waits are blocking completion waits. CancelIoEx wakes
    them on failure; no status/file-size sampling and no unbounded screendump.
    """
    def __init__(self, scope):
        if os.name!='nt': raise ValueError('Windows bounded screenshot sink required')
        self.loop=asyncio.get_running_loop(); self.done=self.loop.create_future()
        self.name='\\\\.\\pipe\\minios-firstboot-'+uuid.uuid4().hex
        self.k=C.WinDLL('kernel32',use_last_error=True)
        k=self.k
        class Overlapped(C.Structure):
            _fields_=[('internal',C.c_size_t),('high',C.c_size_t),('offset',C.c_uint32),('offset_high',C.c_uint32),('event',C.c_void_p)]
        self.Overlapped=Overlapped
        k.CreateNamedPipeW.argtypes=[C.c_wchar_p,C.c_uint32,C.c_uint32,C.c_uint32,C.c_uint32,C.c_uint32,C.c_uint32,C.c_void_p]
        k.CreateNamedPipeW.restype=C.c_void_p
        k.CreateEventW.argtypes=[C.c_void_p,C.c_int,C.c_int,C.c_wchar_p];k.CreateEventW.restype=C.c_void_p
        k.ConnectNamedPipe.argtypes=[C.c_void_p,C.POINTER(Overlapped)]
        k.ReadFile.argtypes=[C.c_void_p,C.c_void_p,C.c_uint32,C.POINTER(C.c_uint32),C.POINTER(Overlapped)]
        k.GetOverlappedResult.argtypes=[C.c_void_p,C.POINTER(Overlapped),C.POINTER(C.c_uint32),C.c_int]
        k.WaitForSingleObject.argtypes=[C.c_void_p,C.c_uint32]
        k.ResetEvent.argtypes=[C.c_void_p]
        k.CancelIoEx.argtypes=[C.c_void_p,C.c_void_p];k.CloseHandle.argtypes=[C.c_void_p]
        self.handle=k.CreateNamedPipeW(self.name,1|0x40000000,0,1,65536,65536,0,None)
        if self.handle==C.c_void_p(-1).value: raise C.WinError(C.get_last_error())
        self.sink=scope.open('endpoint.ppm');self.cancelled=threading.Event()
        self.thread=threading.Thread(target=self.receive,daemon=True)
        self.thread.start()

    def receive(self):
        k=self.k; event=k.CreateEventW(None,1,0,None)
        result=None;error=None
        try:
            def operation(connect=False):
                k.ResetEvent(event)
                ov=self.Overlapped();ov.event=event
                n=C.c_uint32();buf=C.create_string_buffer(65536)
                if self.cancelled.is_set(): raise ValueError('Screenshot cancelled')
                ok=k.ConnectNamedPipe(self.handle,C.byref(ov)) if connect else k.ReadFile(self.handle,buf,len(buf),C.byref(n),C.byref(ov))
                code=C.get_last_error() if not ok else 0
                if code==997:
                    if self.cancelled.is_set(): k.CancelIoEx(self.handle,None)
                    if k.WaitForSingleObject(event,0xffffffff)!=0: raise ValueError('Screenshot native wait failed')
                    ok=k.GetOverlappedResult(self.handle,C.byref(ov),C.byref(n),0)
                    code=C.get_last_error() if not ok else 0
                # A small producer can open/write/close before Connect finishes.
                # PIPE_CONNECTED and NO_DATA still require draining queued data.
                if connect and code in (535,232): return b''
                if not connect and code in (109,232): return None
                if code: raise C.WinError(code)
                return buf.raw[:n.value]
            operation(connect=True)
            while (data:=operation()) is not None:
                self.sink.write(data)
            result=dict(bytes=self.sink.written,transport='bounded-private-named-pipe')
        except Exception as caught: error=str(caught)
        finally:
            self.sink.close();k.CloseHandle(event);k.CloseHandle(self.handle)
            def complete():
                if not self.done.done(): self.done.set_result(dict(error=error) if error else result)
            self.loop.call_soon_threadsafe(complete)

    async def close(self):
        if self.done.done(): return
        self.cancelled.set(); self.k.CancelIoEx(self.handle,None)
        await asyncio.wait_for(asyncio.shield(self.done),15)
