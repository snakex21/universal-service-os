"""Run only via the disk-identity-guarded PowerShell wrapper."""
from pathlib import Path
import ctypes,hashlib,json,os,sys
folder=Path(sys.argv[1])/'prepared';info=json.loads((folder/'repair.json').read_text())
target=Path('\\\\?\\Volume{8dca99dc-9f12-46c9-9c0d-5230748ee536}\\')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
for name in ['SYSTEM','SAM']:assert sha(target/'Windows/System32/config'/name)==info[name]
changes=[('unattend.xml',target/'Windows/Panther/unattend.xml','answer_original','answer_prepared'),('SOFTWARE',target/'Windows/System32/config/SOFTWARE','original','prepared')]
for name,path,old,new in changes:
 assert sha(path)==info[old] and sha(folder/name)==info[new] and sha(folder/(name+'.original'))==info[old]
move=ctypes.WinDLL('kernel32',use_last_error=True).MoveFileExW
move.argtypes=[ctypes.c_wchar_p,ctypes.c_wchar_p,ctypes.c_uint];move.restype=ctypes.c_int
def replace(path,data):
 temp=path.with_name(path.name+'.usos-winsat.tmp')
 with temp.open('xb') as f:f.write(data);f.flush();os.fsync(f.fileno())
 if not move(str(temp),str(path),1|8):raise ctypes.WinError(ctypes.get_last_error())
done=[]
try:
 for name,path,old,new in changes:
  replace(path,(folder/name).read_bytes());done.append((name,path))
  assert sha(path)==info[new]
 for name in ['SYSTEM','SAM']:assert sha(target/'Windows/System32/config'/name)==info[name]
except Exception:
 for name,path in reversed(done):replace(path,(folder/(name+'.original')).read_bytes())
 raise
(folder/'deployed.json').write_text(json.dumps({'verified':True,'changes':{str(p):sha(p) for _,p,_,_ in changes},'SYSTEM_SAM_unchanged':True},indent=2))
print('READBACK_PASS: MOOBE guard and recovery-only OOBE answer; existing SYSTEM/SAM byte-identical')
