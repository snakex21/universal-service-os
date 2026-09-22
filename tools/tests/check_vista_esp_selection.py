"""Fast in-memory tests of the production selector; never executes the installer."""
from pathlib import Path
import ctypes, os, subprocess
root=Path(__file__).resolve().parents[2]
out=root/'zig-out/vista/usb-install'
env=dict(os.environ,TEMP=str(out/'tmp'),TMP=str(out/'tmp'),ZIG_GLOBAL_CACHE_DIR=str(root/'tools/cache/zig-global'),ZIG_LOCAL_CACHE_DIR=str(out/'zig-cache'))
dll=out/'vista-esp-tests.dll'
subprocess.run([str(root/'tools/zig/zig.exe'),'cc','-target','x86_64-windows.win10-gnu','-Os','-shared','-nostdlib','-fno-stack-protector','-fno-builtin','-I'+str(root/'tools/zig/lib/libc/include/any-windows-any'),'-I'+str(out),str(root/'tools/tests/vista_esp_harness.c'),'-Wl,--entry,dll_entry','-lkernel32','-ladvapi32','-lversion','-luser32','-o',str(dll)],env=env,check=True)
library=ctypes.CDLL(str(dll));fn=library.select_scenario
fn.argtypes=[ctypes.c_uint,ctypes.POINTER(ctypes.c_uint),ctypes.c_uint,ctypes.POINTER(ctypes.c_uint)]
cases=[
 ('empty disk before Setup',[],[],-1),
 ('first ESP created',[],[1],0),
 ('existing unique ESP',[1],[1],0),
 ('deleted and recreated ESP',[1],[2],0),
 ('new ESP beside stale EFI',[1],[1,2],1),
 ('three stale ESPs, no guess',[1,2,3],[1,2,3],-1),
 ('fresh ESP after clearing stale layout',[1,2,3],[4],0),
 ('ambiguous new ESPs',[1],[1,2,3],-1),
 ('same GUID on another disk is distinct',[1],[65537],0),
 ('old ESP order does not select a target',[1,2],[2,1],-1),
]
for name,old,current,expected in cases:
    a=(ctypes.c_uint*len(old))(*old);b=(ctypes.c_uint*len(current))(*current)
    actual=fn(len(old),a,len(current),b)
    assert actual==expected,(name,actual,expected)
profile=library.select_profile_scenario;profile.argtypes=[ctypes.c_uint]
for mode,expected in enumerate([1,-1,-1,-1,-1,1]):
    assert profile(mode)==expected,('profile',mode,expected)
recreated=library.select_recreated_scenario;recreated.argtypes=[ctypes.c_uint]
for mode,expected in enumerate([-1,0,0,-1,-1,0,0,-1,-1,0,0,-1,1]):
    actual=recreated(mode)
    assert actual==expected,('recreated EFI',mode,actual,expected)
print('PASS: 29 production ESP-selection scenarios including full partition deletion/recreation; disk GUID/size binding; no disk or registry operations')
