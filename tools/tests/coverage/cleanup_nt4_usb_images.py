"""Delete only the13 reviewed literal stopped qcow2 files; no directory removal."""
from pathlib import Path
import argparse,ctypes,hashlib,json,os
from datetime import datetime,timezone

ROOT=Path(__file__).resolve().parents[3]
PLAN=ROOT/'artifacts/nt4-usb-cleanup-plan.json'
PLAN_SHA='d45245e87d9194b8f3d5e0a22255a7d0849b43505522b8a3f1a70fa9b4f2ad57'
OUT=ROOT/'artifacts/nt4-usb-cleanup'
DIRECTORIES=tuple(map(Path,(
 r'G:\USOS-Kolekcja\_vm\nt4-installed03-usb-combo01',
 r'G:\USOS-Kolekcja\_vm\nt4-installed03-usb-msc04',
 r'G:\USOS-Kolekcja\_vm\nt4-installed03-usb-msc03',
 r'G:\USOS-Kolekcja\_vm\nt4-installed03-usb-msc02',
 r'G:\USOS-Kolekcja\_vm\nt4-installed03-usb-msc01',
 r'G:\USOS-Kolekcja\_vm\nt4-installed03-usb-hid01',
)))
FILES=tuple(map(Path,(
 r'G:\USOS-Kolekcja\_vm\nt4-installed03-usb-combo01\target.qcow2',
 r'G:\USOS-Kolekcja\_vm\nt4-installed03-usb-combo01\usb-test-boot.qcow2',
 r'G:\USOS-Kolekcja\_vm\nt4-installed03-usb-combo01\usb-test-hot.qcow2',
 r'G:\USOS-Kolekcja\_vm\nt4-installed03-usb-msc04\target.qcow2',
 r'G:\USOS-Kolekcja\_vm\nt4-installed03-usb-msc04\usb-test-boot.qcow2',
 r'G:\USOS-Kolekcja\_vm\nt4-installed03-usb-msc04\usb-test-hot.qcow2',
 r'G:\USOS-Kolekcja\_vm\nt4-installed03-usb-msc03\target.qcow2',
 r'G:\USOS-Kolekcja\_vm\nt4-installed03-usb-msc03\usb-test-boot.qcow2',
 r'G:\USOS-Kolekcja\_vm\nt4-installed03-usb-msc03\usb-test-hot.qcow2',
 r'G:\USOS-Kolekcja\_vm\nt4-installed03-usb-msc02\target.qcow2',
 r'G:\USOS-Kolekcja\_vm\nt4-installed03-usb-msc02\usb-test-boot.qcow2',
 r'G:\USOS-Kolekcja\_vm\nt4-installed03-usb-msc02\usb-test-hot.qcow2',
 r'G:\USOS-Kolekcja\_vm\nt4-installed03-usb-hid01\target.qcow2',
)))
PROTECTED=Path(r'G:\USOS-Kolekcja\_vm\nt4-sp6a-desktop-net-ps2-candidate03\target-retained.qcow2')
PROTECTED_SHA='cf04c232df2dc3bcbc2775c0d31963fd1fc4abd4daf7a2967eba9be1f8af2a21'
DEPENDENCY=dict(confirmed_by='/root/nt4',basis='Completed preparation and known09 argv; no active09 read',
 parent09=r'G:\USOS-Kolekcja\_vm\nt4-installed07-canonical-irq08\target.qcow2',
 media09_standalone=True,no09_runtime_backing_argv_reference_to_six_owned_usb_folders=True,
 source_operator_helper_and_completed_metadata_on_C_preserved=True)
def sha(path):
 with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def read(path):return json.loads(path.read_text(encoding='utf-8'))
def exact(path):
 if not path.is_absolute() or path.resolve(strict=True)!=path:raise ValueError('Resolved absolute literal path required')
 for p in (path,*path.parents):
  if p.lstat().st_file_attributes&0x400:raise ValueError('Reparse path refused')
def save(path,data):
 with path.open('x',encoding='utf-8',newline='\n') as f:json.dump(data,f,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())
class Info(ctypes.Structure):
 _fields_=[('attributes',ctypes.c_uint32),('created',ctypes.c_uint32*2),('accessed',ctypes.c_uint32*2),('written',ctypes.c_uint32*2),('volume',ctypes.c_uint32),('high',ctypes.c_uint32),('low',ctypes.c_uint32),('links',ctypes.c_uint32),('index_high',ctypes.c_uint32),('index_low',ctypes.c_uint32)]
class Disposition(ctypes.Structure):
 _fields_=[('DeleteFile',ctypes.c_int)]
class WindowsFiles:
 def __init__(self):
  k=self.k=ctypes.WinDLL('kernel32',use_last_error=True)
  k.CreateFileW.argtypes=[ctypes.c_wchar_p,ctypes.c_uint32,ctypes.c_uint32,ctypes.c_void_p,ctypes.c_uint32,ctypes.c_uint32,ctypes.c_void_p];k.CreateFileW.restype=ctypes.c_void_p
  k.GetFileInformationByHandle.argtypes=[ctypes.c_void_p,ctypes.POINTER(Info)]
  k.GetFinalPathNameByHandleW.argtypes=[ctypes.c_void_p,ctypes.c_wchar_p,ctypes.c_uint32,ctypes.c_uint32]
  k.ReadFile.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.c_uint32,ctypes.POINTER(ctypes.c_uint32),ctypes.c_void_p]
  k.SetFileInformationByHandle.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_void_p,ctypes.c_uint32]
  k.CloseHandle.argtypes=[ctypes.c_void_p]
 def open_locked(self,path,expected):
  exact(path)
  # Read+DELETE access, sharing0. All13 handles remain exclusive until verified.
  handle=self.k.CreateFileW(str(path),0x80010000,0,None,3,0x00200000,None)
  if handle==ctypes.c_void_p(-1).value:raise ctypes.WinError(ctypes.get_last_error())
  try:
   info=Info()
   if not self.k.GetFileInformationByHandle(handle,ctypes.byref(info)):raise ctypes.WinError(ctypes.get_last_error())
   if info.attributes&(0x400|0x10|1) or info.links!=1:raise ValueError('Regular writable nonreparse single-link file required')
   size=(info.high<<32)|info.low
   buf=ctypes.create_unicode_buffer(32768);n=self.k.GetFinalPathNameByHandleW(handle,buf,len(buf),0)
   if not 0<n<len(buf):raise ctypes.WinError(ctypes.get_last_error())
   final=buf.value.removeprefix('\\\\?\\')
   if Path(final)!=path:raise ValueError('Actual handle path differs from reviewed literal')
   digest=hashlib.sha256();buffer=ctypes.create_string_buffer(1024**2);received=ctypes.c_uint32();count=0
   while True:
    if not self.k.ReadFile(handle,buffer,len(buffer),ctypes.byref(received),None):raise ctypes.WinError(ctypes.get_last_error())
    if not received.value:break
    count+=received.value;digest.update(buffer.raw[:received.value])
   if count!=size or size!=expected['opened_bytes'] or digest.hexdigest()!=expected['sha256']:raise ValueError('Reviewed file size/hash changed; no deletion allowed')
   return handle,dict(path=str(path),opened_bytes=size,sha256=digest.hexdigest(),exclusive_share0=True,links=info.links,final_handle_path=final,file_id=dict(volume=info.volume,index=(info.index_high<<32)|info.index_low))
  except BaseException:self.k.CloseHandle(handle);raise
 def unlink_locked(self,handle):
  # Native handle unlink avoids closing the exclusive handle before deletion.
  disposition=Disposition(1)
  if not self.k.SetFileInformationByHandle(handle,4,ctypes.byref(disposition),ctypes.sizeof(disposition)):raise ctypes.WinError(ctypes.get_last_error())
 def close(self,handle):
  if not self.k.CloseHandle(handle):raise ctypes.WinError(ctypes.get_last_error())
def manifest():
 exact(PLAN)
 if sha(PLAN)!=PLAN_SHA:raise ValueError('Reviewed plan changed')
 plan=read(PLAN);cases=plan['cases_in_child_before_parent_order']
 if tuple(Path(c['directory']) for c in cases)!=DIRECTORIES or plan.get('executed_deletions') is not False:raise ValueError('Reviewed scope/order changed')
 selected={};preserved={};closure=[];directories={}
 for case,directory in zip(cases,DIRECTORIES):
  exact(directory)
  files={Path(f['path']):f for f in case['files']}
  direct=list(directory.iterdir())
  if {p for p in direct if p.is_file()}!=set(files):raise ValueError('Direct file inventory changed')
  directories[str(directory)]=[]
  for p in direct:
   exact(p)
   if p.is_dir():directories[str(directory)].append(str(p))
  for p in case.get('child_directories',[]):exact(Path(p))
  for path,item in files.items():
   if path.parent!=directory:raise ValueError('Reviewed file escaped literal directory')
   if path in FILES:selected[path]=item
   else:
    exact(path)
    with path.open('rb') as f:
     if os.fstat(f.fileno()).st_size!=item['opened_bytes'] or hashlib.file_digest(f,'sha256').hexdigest()!=item['sha256']:raise ValueError('Preserved file changed')
    preserved[str(path)]=dict(opened_bytes=item['opened_bytes'],sha256=item['sha256'])
  runtime=ROOT/'artifacts/coverage/vm'/directory.name
  if directory.name in ('nt4-installed03-usb-msc01','nt4-installed03-usb-msc02'):
   if runtime.exists():raise ValueError('Never-launched preparation now has runtime')
   closure.append(dict(case=directory.name,never_launched=True))
  else:
   complete=runtime/'completed.json';result=runtime/'result.json'
   if read(complete).get('stopped') is not True or read(result).get('qemu_returncode')!=0:raise ValueError('Exact stopped writer0 proof required')
   closure.append(dict(case=directory.name,stopped=True,qemu_returncode=0,completed_sha256=sha(complete),result_sha256=sha(result)))
 if set(selected)!=set(FILES) or len(FILES)!=13 or any(p.suffix!='.qcow2' for p in FILES):raise ValueError('Only13 literal qcow2 files allowed')
 exact(PROTECTED)
 if sha(PROTECTED)!=PROTECTED_SHA:raise ValueError('Protected original parent changed')
 return selected,preserved,closure,directories
def main(execute):
 OUT.mkdir(parents=True,exist_ok=True)
 dest=OUT/('receipt.json' if execute else 'preflight.json')
 if dest.exists():raise FileExistsError('No retry/overwrite of cleanup attempt')
 prior=OUT/'preflight.json';source_sha=sha(Path(__file__))
 if execute:
  proof=read(prior)
  if not proof.get('preflight_pass') or proof.get('plan_sha256')!=PLAN_SHA or proof.get('source_sha256')!=source_sha or proof.get('dependency_confirmation')!=DEPENDENCY:raise ValueError('Exact successful preflight/source/dependency required')
 api=WindowsFiles();handles={};verified=[];deleted=[];failure=None;preserved={};directories={};closure=[]
 result=dict(mode='execute' if execute else 'preflight',plan=str(PLAN),plan_sha256=PLAN_SHA,source_sha256=source_sha,dependency_confirmation=DEPENDENCY,started_utc=datetime.now(timezone.utc).isoformat(),global_process_query=False,recursive_removal=False,deleted=deleted)
 if execute:result['preflight_sha256']=sha(prior)
 try:
  selected,preserved,closure,directories=manifest()
  for path in FILES:
   handle,item=api.open_locked(path,selected[path]);handles[path]=handle;verified.append(item)
  result.update(preflight_pass=True,verified=verified,closure=closure,preserved_files=preserved,preserved_directories=directories,backing_chains_bound_by_identical_full_file_sha256=True)
  if execute:
   with (OUT/'unlink-journal.jsonl').open('x',encoding='utf-8',newline='\n') as journal:
    for path,item in zip(FILES,verified):
     api.unlink_locked(handles[path]);api.close(handles.pop(path))
     if os.path.lexists(path):raise ValueError('Native unlink not complete; stop without retry')
     deletion=dict(**item,deleted=True,deleted_utc=datetime.now(timezone.utc).isoformat());deleted.append(deletion)
     journal.write(json.dumps(deletion)+'\n');journal.flush();os.fsync(journal.fileno())
   for path,item in preserved.items():
    p=Path(path);exact(p)
    if p.stat().st_size!=item['opened_bytes'] or sha(p)!=item['sha256']:raise ValueError('Preserved non-qcow2 file differs')
   for root,children in directories.items():
    exact(Path(root))
    for p in children:exact(Path(p))
   exact(PROTECTED)
   if sha(PROTECTED)!=PROTECTED_SHA:raise ValueError('Protected original parent differs')
   result.update(all13_unlinks_complete=True,total_deleted_opened_bytes=sum(i['opened_bytes'] for i in deleted),preserved_non_qcow2_files_unchanged=True,all_six_directories_preserved=True,protected_original03=dict(path=str(PROTECTED),sha256=PROTECTED_SHA,unchanged=True),net08_and_all_net_and_macos_not_opened_or_deleted=True,source_logs_vars_cache_fixture_not_deleted=True)
 except BaseException as e:
  failure=type(e).__name__+': '+str(e);result.update(error=failure,refused_or_stopped_without_retry=True,all13_unlinks_complete=False)
 finally:
  for handle in handles.values():api.close(handle)
 result.update(verified_count=len(verified),deleted_count=len(deleted),completed_utc=datetime.now(timezone.utc).isoformat())
 save(dest,result);print(json.dumps(dict(receipt=str(dest),mode=result['mode'],verified_count=len(verified),deleted_count=len(deleted),error=failure,total_deleted_opened_bytes=result.get('total_deleted_opened_bytes',0)),indent=2),flush=True)
 if failure:raise SystemExit(2)
if __name__=='__main__':
 p=argparse.ArgumentParser();g=p.add_mutually_exclusive_group(required=True);g.add_argument('--preflight',action='store_true');g.add_argument('--execute',action='store_true');main(p.parse_args().execute)
