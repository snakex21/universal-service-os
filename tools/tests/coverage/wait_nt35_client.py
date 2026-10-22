"""Block on one exact completion filename; no progress reads or timed polling."""
from pathlib import Path
import ctypes
from ctypes import wintypes
import json
import struct
import sys

ROOT=Path(__file__).resolve().parents[3]
WATCH=ROOT/'artifacts/coverage'
CASE=WATCH/'vm/nt35-client-apply03'

def main():
    global CASE
    if len(sys.argv)==3:
        if sys.argv[2] not in ('nt35-client-apply03','nt35-client-cold01'):raise ValueError('Exact owned case required')
        CASE=WATCH/'vm'/sys.argv[2]
    mode=sys.argv[1]
    if mode=='endpoint':wanted=[CASE/'endpoint.png',CASE/'completed.json']
    elif mode.startswith('policy'):
        n=int(mode[6:]);assert 1<=n<=4;wanted=[CASE/('policy-done-%02d.json'%n),CASE/'completed.json']
    else:
        n=int(mode);assert 1<=n<=128;wanted=[CASE/('operator-%02d.png'%n),CASE/'completed.json']
    WATCH.mkdir(parents=True,exist_ok=True)
    kernel=ctypes.WinDLL('kernel32',use_last_error=True)
    kernel.CreateFileW.argtypes=[wintypes.LPCWSTR,wintypes.DWORD,wintypes.DWORD,ctypes.c_void_p,wintypes.DWORD,wintypes.DWORD,wintypes.HANDLE]
    kernel.CreateFileW.restype=wintypes.HANDLE
    kernel.ReadDirectoryChangesW.argtypes=[wintypes.HANDLE,ctypes.c_void_p,wintypes.DWORD,wintypes.BOOL,wintypes.DWORD,ctypes.POINTER(wintypes.DWORD),ctypes.c_void_p,ctypes.c_void_p]
    kernel.CloseHandle.argtypes=[wintypes.HANDLE]
    handle=kernel.CreateFileW(str(WATCH),1,7,None,3,0x02000000,None)
    if handle==ctypes.c_void_p(-1).value:raise ctypes.WinError(ctypes.get_last_error())
    expected={str(p).casefold() for p in wanted}
    try:
        print('NT35_CLIENT_LISTENER_ARMED',flush=True)
        for p in wanted:
            if p.is_file():print(json.dumps({'completed':str(p)}),flush=True);return
        buf=ctypes.create_string_buffer(65536);received=wintypes.DWORD()
        while True:
            if not kernel.ReadDirectoryChangesW(handle,buf,len(buf),True,0x11,ctypes.byref(received),None,None):raise ctypes.WinError(ctypes.get_last_error())
            if not received.value:raise RuntimeError('Completion notification overflow')
            offset=0
            while offset<received.value:
                next_offset,action,size=struct.unpack_from('<III',buf.raw,offset)
                name=buf.raw[offset+12:offset+12+size].decode('utf-16-le')
                path=WATCH/name
                if action in (1,3,5) and str(path).casefold() in expected:
                    print(json.dumps({'completed':str(path),'action':action}),flush=True);return
                if not next_offset:break
                offset+=next_offset
    finally:kernel.CloseHandle(handle)

if __name__=='__main__':main()
