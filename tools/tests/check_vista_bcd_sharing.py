"""Reproduce the live-hive CopyFile failure on project-local BCD copies only."""
from pathlib import Path
import ctypes as c,shutil,uuid
root=Path(__file__).resolve().parents[2]
out=root/'zig-out/vista/bcd-sharing-check'/str(uuid.uuid4());out.mkdir(parents=True)
snapshot=Path((root/'zig-out/vista/finish-snapshot-path.txt').read_text())
source=out/'BCD';shutil.copyfile(snapshot/'prepared/BCD',source)
advapi=c.WinDLL('advapi32',use_last_error=True);kernel=c.WinDLL('kernel32',use_last_error=True)
advapi.RegLoadAppKeyW.argtypes=[c.c_wchar_p,c.POINTER(c.c_void_p),c.c_uint,c.c_uint,c.c_uint]
advapi.RegCloseKey.argtypes=[c.c_void_p]
kernel.CopyFileW.argtypes=[c.c_wchar_p,c.c_wchar_p,c.c_int]
handle=c.c_void_p()
code=advapi.RegLoadAppKeyW(str(source),c.byref(handle),0x20019,1,0)
assert code==0,code
try:
    copied=kernel.CopyFileW(str(source),str(out/'raw-copy'),0)
    error=c.get_last_error()
    assert copied==0 and error==32,(copied,error)
finally:advapi.RegCloseKey(handle)
assert kernel.CopyFileW(str(source),str(out/'closed-copy'),0)
print('PASS: loaded project-local BCD reproduces CopyFile error 32; closed BCD copies successfully')
