"""Invoked by guarded PS wrapper; write three verified files, SYSTEM last."""
from pathlib import Path
import ctypes,hashlib,json,os,sys
folder=Path(sys.argv[1]);meta=json.loads((folder/'snapshot.json').read_text(encoding='utf-8-sig'))
report=json.loads((folder/'prepared/repair.json').read_text())
assert meta['diskGuid'].strip('{}').lower()=='8e281c54-58d1-4ad0-8afd-ad76d2e48148'
assert meta['osGuid'].strip('{}').lower()=='8dca99dc-9f12-46c9-9c0d-5230748ee536'
assert meta['espGuid'].strip('{}').lower()=='266ef7fa-2486-4050-892f-20c3bc889930'
# Volume GUID paths remain bound even if drive letters change.
osroot=Path('\\\\?\\Volume{8dca99dc-9f12-46c9-9c0d-5230748ee536}\\')
esp=Path('\\\\?\\Volume{266ef7fa-2486-4050-892f-20c3bc889930}\\')
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
assert digest(osroot/'Windows/System32/config/SOFTWARE')==report['original']['SOFTWARE']
assert digest(esp/'EFI/Microsoft/Boot/bootmgfw.efi')==report['original']['bootmgfw.efi']
changes=[('BCD',esp/'EFI/Microsoft/Boot/BCD','BCD'),('bootx64.efi',esp/'EFI/Boot/bootx64.efi','bootx64.before'),('SYSTEM',osroot/'Windows/System32/config/SYSTEM','SYSTEM')]
for prepared,target,original in changes:
    assert digest(target)==report['original'][original],('Target changed',str(target))
    assert digest(folder/'prepared'/prepared)==report['prepared'][prepared]
move=ctypes.WinDLL('kernel32',use_last_error=True).MoveFileExW
move.argtypes=[ctypes.c_wchar_p,ctypes.c_wchar_p,ctypes.c_uint];move.restype=ctypes.c_int
def replace(target,data):
    temp=target.with_name(target.name+'.usos-v4.tmp')
    with temp.open('xb') as output:output.write(data);output.flush();os.fsync(output.fileno())
    if not move(str(temp),str(target),1|8):raise ctypes.WinError(ctypes.get_last_error())
done=[]
try:
    for prepared,target,original in changes:
        replace(target,(folder/'prepared'/prepared).read_bytes());done.append((target,original))
        assert digest(target)==report['prepared'][prepared]
except Exception:
    for target,original in reversed(done):replace(target,(folder/original).read_bytes())
    raise
(folder/'deployed.json').write_text(json.dumps({'files':{str(target):digest(target) for _,target,_ in changes},'verified':True},indent=2))
print('READBACK_PASS: Vista BCD, fallback EFI, SYSTEM USB hook; no reinstall; backups in',folder)
