"""Called by the Intel identity guard only; publish helper before arming it."""
from pathlib import Path
import ctypes,hashlib,json,os,sys
folder=Path(sys.argv[1]);info=json.loads((folder/'manifest.json').read_text())
root=Path('\\\\?\\Volume{8dca99dc-9f12-46c9-9c0d-5230748ee536}\\');config=root/'Windows/System32/config'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
for name,expected in info['original'].items():assert sha(config/name)==expected
assert sha(folder/'SYSTEM.prepared')==info['prepared'] and sha(folder/'end.exe')==info['exe']
destination=root/'USOS/end.exe';assert not destination.exists()
move=ctypes.WinDLL('kernel32',use_last_error=True).MoveFileExW
move.argtypes=[ctypes.c_wchar_p,ctypes.c_wchar_p,ctypes.c_uint];move.restype=ctypes.c_int
def write_new(p,data):
 with p.open('xb') as f:f.write(data);f.flush();os.fsync(f.fileno())
def replace(p,data):
 temp=p.with_name(p.name+'.usos-resume.tmp');write_new(temp,data)
 if not move(str(temp),str(p),1|8):raise ctypes.WinError(ctypes.get_last_error())
write_new(destination,(folder/'end.exe').read_bytes());assert sha(destination)==info['exe']
try:
 replace(config/'SYSTEM',(folder/'SYSTEM.prepared').read_bytes())
 assert sha(config/'SYSTEM')==info['prepared']
 for name in ['SOFTWARE','SAM']:assert sha(config/name)==info['original'][name]
except Exception:
 replace(config/'SYSTEM',(folder/'SYSTEM').read_bytes())
 raise
(folder/'deployed.json').write_text(json.dumps({'verified':True,'SYSTEM':sha(config/'SYSTEM'),'end.exe':sha(destination),'SAM_and_SOFTWARE_unchanged':True},indent=2))
print('READBACK_PASS: helper + native OOBE recovery hook; SAM/SOFTWARE byte-identical')
