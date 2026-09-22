from pathlib import Path
import ctypes as c,struct,hashlib
v=c.WinDLL('version');v.GetFileVersionInfoSizeW.argtypes=[c.c_wchar_p,c.c_void_p];v.GetFileVersionInfoW.argtypes=[c.c_wchar_p,c.c_uint,c.c_uint,c.c_void_p];v.VerQueryValueW.argtypes=[c.c_void_p,c.c_wchar_p,c.POINTER(c.c_void_p),c.POINTER(c.c_uint)]
paths=list(Path('zig-out/xp-uefi-csm/checks/0').glob('*'))
paths += [Path('M:/WINDOWS/system32')/n for n in ('ntoskrnl.exe','ntkrnlpa.exe','hal.dll','initpki.dll','syssetup.dll')]
for p in paths:
 if not p.is_file():continue
 n=v.GetFileVersionInfoSizeW(str(p),None)
 if not n:continue
 b=c.create_string_buffer(n);assert v.GetFileVersionInfoW(str(p),0,n,b)
 addr=c.c_void_p();size=c.c_uint();assert v.VerQueryValueW(b,'\\',c.byref(addr),c.byref(size))
 q=struct.unpack('<13I',c.string_at(addr,52));ver=(q[2]>>16,q[2]&65535,q[3]>>16,q[3]&65535)
 print(str(p),ver,p.stat().st_size,hashlib.sha256(p.read_bytes()).hexdigest())
