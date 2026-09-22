"""Compile XP supervisor; patch only CmdLine in a private hive, preserving ACLs."""
from pathlib import Path
import ctypes as c,subprocess,os,struct,json,hashlib,sys,io
root=Path(__file__).resolve().parents[1];sys.path.insert(0,str(root/'tools'))
from repair_vista_drive_mapping import inventory
from Registry import Registry
out=root/'artifacts/xp-pae/setup-trace-v3';out.mkdir(exist_ok=True)
env=dict(os.environ,TEMP=str(out),TMP=str(out),ZIG_GLOBAL_CACHE_DIR=str(root/'tools/cache/zig-global'))
zig=str(root/'tools/zig/zig.exe');exe=out/'setup-trace.exe'
subprocess.run([zig,'cc','-target','x86-windows-gnu','-Os','-nostdlib','-fno-stack-protector','-fno-builtin','-I'+str(root/'tools/zig/lib/libc/include/any-windows-any'),str(root/'tools/windows_xp_setup_trace.c'),'-Wl,--entry,entry','-lkernel32','-luser32','-ladvapi32','-o',str(exe)],env=env,check=True)
b=bytearray(exe.read_bytes());p=struct.unpack_from('<I',b,60)[0]+24
struct.pack_into('<HH',b,p+40,5,1);struct.pack_into('<HH',b,p+48,5,1);struct.pack_into('<I',b,p+64,0);exe.write_bytes(b)
dll=out/'hive-patch.dll'
subprocess.run([zig,'cc','-target','x86_64-windows-gnu','-shared','-Os','-nostdlib','-fno-builtin',str(root/'tools/tests/xp_setup_trace_hive.c'),'-Wl,--entry,DllMain','-o',str(dll)],env=env,check=True)
lib=c.CDLL(str(dll));lib.patch.argtypes=[c.c_void_p,c.c_uint32];lib.patch.restype=c.c_int
original=Path('M:/WINDOWS/system32/config/SYSTEM').read_bytes()
buf=c.create_string_buffer(original,len(original));assert lib.patch(buf,len(original))==1
updated=buf.raw
before=inventory(Registry.Registry(io.BytesIO(original)));expected={k:dict(v) for k,v in before.items()}
assert expected['\\Setup']['CmdLine']==(1,'setup -newsetup\0'.encode('utf-16le'))
expected['\\Setup']['CmdLine']=(1,'C:\\USOS\\x.exe\0'.encode('utf-16le'))
assert inventory(Registry.Registry(io.BytesIO(updated)))==expected,'Unexpected registry change'
assert len(updated)==len(original) and updated[20:28]==original[20:28]
again=c.create_string_buffer(updated,len(updated));assert lib.patch(again,len(updated))==0,'Repeat must be refused'
(out/'SYSTEM').write_bytes(updated)
(out/'changes.json').write_text(json.dumps([{'file':'SYSTEM','original_sha256':hashlib.sha256(original).hexdigest(),'change':'Setup/CmdLine only; registry ACLs and XP hive format retained'}],indent=2))
print('PASS: Zig x86 compilation; all hive values compared, only CmdLine changed; repeated patch refused; target untouched')
