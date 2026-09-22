"""Short in-memory regression check; no host registry APIs or target writes."""
from pathlib import Path
import ctypes as c
import io
import os
import struct
import subprocess
import sys

root=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(root/'tools'))
from repair_vista_drive_mapping import inventory
from Registry import Registry
out=root/'zig-out/vista/hive-parser-check';out.mkdir(parents=True,exist_ok=True)
env=dict(os.environ,TEMP=str(out),TMP=str(out),ZIG_GLOBAL_CACHE_DIR=str(root/'tools/cache/zig-global'),ZIG_LOCAL_CACHE_DIR=str(out/'zig-cache'))
dll=out/'hive-check.dll'
subprocess.run([str(root/'tools/zig/zig.exe'),'cc','-target','x86_64-windows-gnu','-shared','-Os','-nostdlib','-fno-builtin',str(root/'tools/tests/vista_hive_harness.c'),'-Wl,--entry,DllMain','-o',str(dll)],env=env,check=True)
lib=c.CDLL(str(dll));lib.patch_setup.argtypes=[c.c_void_p,c.c_uint32,c.c_wchar_p];lib.patch_setup.restype=c.c_int
lib.inspect_string.argtypes=[c.c_void_p,c.c_uint32,c.c_char_p,c.c_char_p,c.c_void_p,c.c_uint];lib.inspect_string.restype=c.c_int
original=(root/'zig-out/vista/image/Windows/System32/config/SYSTEM').read_bytes()
buf=c.create_string_buffer(original,len(original))
assert lib.patch_setup(buf,len(original),'D:\\USOS\\usb.exe')==1
updated=buf.raw
before=inventory(Registry.Registry(io.BytesIO(original)))
expected={k:dict(v) for k,v in before.items()}
expected['\\Setup']['CmdLine']=(1,'D:\\USOS\\usb.exe\0'.encode('utf-16le'))
expected['\\Setup']['SetupType']=(4,struct.pack('<I',2))
assert inventory(Registry.Registry(io.BytesIO(updated)))==expected
assert len(updated)==len(original)
assert struct.unpack_from('<II',updated,4)==(struct.unpack_from('<I',original,4)[0]+1,)*2
for label,data,line in [
 ('truncated',original[:4096],'D:\\USOS\\usb.exe'),
 ('bad header',b'BAD!'+original[4:],'D:\\USOS\\usb.exe'),
 ('dirty hive',original[:8]+b'\xff\xff\xff\xff'+original[12:],'D:\\USOS\\usb.exe'),
 ('oversized replacement',original,'D:\\'+('x'*200)),
]:
 b=c.create_string_buffer(data,len(data));assert lib.patch_setup(b,len(data),line)==0,label
 assert b.raw==data,label
soft=(root/'zig-out/vista/image/Windows/System32/config/SOFTWARE').read_bytes()
b=c.create_string_buffer(soft,len(soft));value=c.create_unicode_buffer(260)
assert lib.inspect_string(b,len(soft),b'Microsoft\\Windows NT\\CurrentVersion',b'SystemRoot',value,260)==1
assert value.value==Registry.Registry(io.BytesIO(soft)).open(r'Microsoft\Windows NT\CurrentVersion').value('SystemRoot').value()
print('VISTA_HIVE_PATCH_OK; all registry values compared; only CmdLine/SetupType changed; malformed/dirty/oversized rejected; SOFTWARE read OK')
