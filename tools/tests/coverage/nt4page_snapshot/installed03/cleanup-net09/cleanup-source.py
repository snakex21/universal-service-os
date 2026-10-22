"""Literal-only, closed owned NT4 qcow2 cleanup. No directory recursion/deletion.

Manifest precedes mutation. Exclusive READ+DELETE handles share DELETE only,
blocking existing/new readers/writers while allowing literal unlink operations.
Group hardlinks so the representative open path is deleted last.
"""
from pathlib import Path
import argparse,ctypes,hashlib,json,os,stat,subprocess,time
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[1]
VM=Path(r'G:\USOS-Kolekcja\_vm')
PROTECTED=Path(r'G:\USOS-Kolekcja\_vm\nt4-sp6a-desktop-net-ps2-candidate03\target-retained.qcow2')
PROTECTED_SHA='cf04c232df2dc3bcbc2775c0d31963fd1fc4abd4daf7a2967eba9be1f8af2a21'
QIMG=ROOT.parent/'bety-instalacja/tools/qemu/qemu-img.exe'
MANIFEST=HERE/'nt4-net-cleanup-final-manifest.json';RECEIPT=HERE/'nt4-net-cleanup-final-receipt.json'
LITERALS=(
 r'G:\USOS-Kolekcja\_vm\nt4-installed08-usbmsc-hid-net09\target.qcow2',
 r'G:\USOS-Kolekcja\_vm\nt4-installed08-usbmsc-hid-net09\usb-test-boot.qcow2',
 r'G:\USOS-Kolekcja\_vm\nt4-installed08-usbmsc-hid-net09\usb-test-hot.qcow2',
 r'G:\USOS-Kolekcja\_vm\nt4-installed08b-network-readonly\target.qcow2',
 r'G:\USOS-Kolekcja\_vm\nt4-installed07-canonical-irq08\target.qcow2',
 r'G:\USOS-Kolekcja\_vm\nt4-installed07-canonical-irq08\blank-stick.qcow2',
 r'G:\USOS-Kolekcja\_vm\nt4-installed03-network07\target.qcow2',
 r'G:\USOS-Kolekcja\_vm\nt4-installed03-network07\blank-stick.qcow2',
 r'G:\USOS-Kolekcja\_vm\nt4-installed03-start3-control06\target.qcow2',
 r'G:\USOS-Kolekcja\_vm\nt4-installed03-start3-control06\blank-stick.qcow2',
 r'G:\USOS-Kolekcja\_vm\nt4-installed03-loadorder05\target.qcow2',
 r'G:\USOS-Kolekcja\_vm\nt4-installed03-loadorder05\blank-stick.qcow2',
 r'G:\USOS-Kolekcja\_vm\nt4-installed03-loadorder04\target.qcow2',
 r'G:\USOS-Kolekcja\_vm\nt4-installed03-loadorder04\blank-stick.qcow2',
)
PINS={LITERALS[0]:'6c4e80a34c20544c314cb3ad88a0e0222320bd0550351d2f4fbc7f3c95e35743',LITERALS[1]:'ed90e0bfdd066c8fe6d889f8d8ac8765df826330e15a2e249d19edd3e5f6aff0',LITERALS[2]:'c7a2f2b0c8aad058ab26e90176abe51660093f6dcc539fbb6e031f5a6def744c',LITERALS[3]:'f0f976d0af544fc3b2a87dbaac84811785332d9ef487d6e3e0c6a1ed6ad820ee',LITERALS[4]:'f0f976d0af544fc3b2a87dbaac84811785332d9ef487d6e3e0c6a1ed6ad820ee',LITERALS[6]:'29036264e022d760223f2f091805e8c170888b3b8d6b1f933888c0193ce0da10'}
K=ctypes.WinDLL('kernel32',use_last_error=True)
K.CreateFileW.argtypes=[ctypes.c_wchar_p,ctypes.c_uint32,ctypes.c_uint32,ctypes.c_void_p,ctypes.c_uint32,ctypes.c_uint32,ctypes.c_void_p];K.CreateFileW.restype=ctypes.c_void_p
K.CloseHandle.argtypes=[ctypes.c_void_p];K.DeleteFileW.argtypes=[ctypes.c_wchar_p];K.DeleteFileW.restype=ctypes.c_int
# Native BY_HANDLE_FILE_INFORMATION consists of thirteen DWORDs.
class NativeInfo(ctypes.Structure):
 _fields_=[('words',ctypes.c_uint32*13)]
K.GetFileInformationByHandle.argtypes=[ctypes.c_void_p,ctypes.POINTER(NativeInfo)];K.GetFileInformationByHandle.restype=ctypes.c_int
K.SetFilePointerEx.argtypes=[ctypes.c_void_p,ctypes.c_longlong,ctypes.c_void_p,ctypes.c_uint32];K.SetFilePointerEx.restype=ctypes.c_int
K.ReadFile.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.c_uint32,ctypes.POINTER(ctypes.c_uint32),ctypes.c_void_p];K.ReadFile.restype=ctypes.c_int
def opened(path,exclusive=False):
 h=K.CreateFileW(str(path),0x80010000 if exclusive else 0,4 if exclusive else 7,None,3,0x00200080,None)
 if h==ctypes.c_void_p(-1).value:raise ctypes.WinError(ctypes.get_last_error())
 return h
def info(handle):
 data=NativeInfo()
 if not K.GetFileInformationByHandle(handle,ctypes.byref(data)):raise ctypes.WinError(ctypes.get_last_error())
 w=data.words
 if w[0]&0x410:raise ValueError('No directory/reparse file handle')
 return {'file_id':str(w[7])+':'+format((w[11]<<32)|w[12],'016x'),'bytes':(w[8]<<32)|w[9],'links':w[10],'attributes':w[0]}
def digest_handle(handle,expected_size):
 if not K.SetFilePointerEx(handle,0,None,0):raise ctypes.WinError(ctypes.get_last_error())
 result=hashlib.sha256();buffer=ctypes.create_string_buffer(1024**2);total=0
 while True:
  n=ctypes.c_uint32()
  if not K.ReadFile(handle,buffer,len(buffer),ctypes.byref(n),None):raise ctypes.WinError(ctypes.get_last_error())
  if not n.value:break
  total+=n.value
  if total>expected_size or total>8*1024**3:raise ValueError('Exact bounded owned qcow2 length')
  result.update(buffer.raw[:n.value])
 if total!=expected_size:raise ValueError('Truncated owned qcow2')
 return result.hexdigest()
def exact(path,eligible=True):
 if not path.is_absolute() or path.resolve()!=path:raise ValueError('Exact resolved absolute path required')
 if eligible and (str(path) not in LITERALS or path.suffix.lower()!='.qcow2' or path.parent.parent!=VM or path==PROTECTED):raise ValueError('Literal owned allowlist only')
 for p in (path,*path.parents):
  if p.exists() and p.lstat().st_file_attributes&0x400:raise ValueError('No reparse ancestry')
 if not stat.S_ISREG(path.lstat().st_mode):raise ValueError('Regular existing owned file only')
def metadata(path):
 h=opened(path)
 try:return info(h)
 finally:K.CloseHandle(h)
def sha(path):
 with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def save(path,value):
 if path.exists():raise FileExistsError('Preserve immutable manifest/receipt')
 path.write_text(json.dumps(value,indent=2)+'\n',encoding='utf-8',newline='\n')
def selftest():
 folder=HERE/'cleanup-exclusive-selftest';folder.mkdir(exist_ok=False);left=folder/'alias.qcow2';right=folder/'last.qcow2'
 left.write_bytes(b'OWN CLEANUP TEST ONLY\n'*128);os.link(left,right);expected=sha(left);before=metadata(right)
 h=opened(right,True)
 try:
  try:other=K.CreateFileW(str(left),0x80000000,7,None,3,0x80,None)
  except Exception:raise
  if other!=ctypes.c_void_p(-1).value:K.CloseHandle(other);raise AssertionError('Exclusive reader lock failed')
  if ctypes.get_last_error()!=32:raise AssertionError('Expected sharing violation')
  if metadata(left)['file_id']!=before['file_id'] or digest_handle(h,before['bytes'])!=expected:raise AssertionError('Actual handle ID/hash proof failed')
  if not K.DeleteFileW(str(left)):raise ctypes.WinError(ctypes.get_last_error())
  if not K.DeleteFileW(str(right)):raise ctypes.WinError(ctypes.get_last_error())
 finally:K.CloseHandle(h)
 if os.path.lexists(left) or os.path.lexists(right):raise AssertionError('Hardlink namespace cleanup failed')
 save(HERE/'cleanup-exclusive-selftest.json',{'pass':True,'share_read_write_refused':True,'attribute_handle_allowed':True,'hardlink_alias_first_last_representative':True,'file_id_hash_verified':True,'only_synthetic_C_files_deleted':True,'G_images_opened':False})
 print('EXCLUSIVE_HANDLE_AND_TWO_HARDLINK_DELETE_SELFTEST_PASS',flush=True)
def closure():
 roots=['nt4-installed08-usbmsc-hid-net09','nt4-installed07-canonical-irq08','nt4-installed03-network07','nt4-installed03-start3-control06','nt4-installed03-loadorder05','nt4-installed03-loadorder04']
 proof=[]
 for name in roots:
  path=ROOT/'artifacts/coverage/vm'/name;v=json.loads((path/'result.json').read_text(encoding='utf-8'));end=json.loads((path/'completed.json').read_text(encoding='utf-8'))
  if v['qemu_returncode']!=0 or end.get('stopped') is not True:raise ValueError('Closed owned writer0 proof required')
  proof.append({'result':str(path/'result.json'),'sha256':sha(path/'result.json'),'qemu_returncode':0,'runtime_error_retained':v.get('error')})
 for tag in ('nt4-installed08b-network-excerpt','nt4-installed09-network-excerpt'):
  path=ROOT.parent/'macierz-windows/artifacts/coverage'/tag/'collection.json';v=json.loads(path.read_text(encoding='utf-8'))
  if v['collector_result']['exit_code']!=0 or v['collector_result']['result']!='PASS':raise ValueError('Read-only reader completion required')
  proof.append({'result':str(path),'sha256':sha(path),'collector_stopped':True})
 return proof
def evidence_pins():
 folders=[ROOT/'artifacts/coverage/vm'/x for x in ('nt4-installed03-loadorder04','nt4-installed03-loadorder05','nt4-installed03-start3-control06','nt4-installed03-network07','nt4-installed07-canonical-irq08','nt4-installed08-usbmsc-hid-net09')]
 folders+=[ROOT/'tools/tests/coverage/nt4page_snapshot/installed03/tuple09']
 folders+=[ROOT.parent/'macierz-windows/artifacts/coverage'/x for x in ('nt4-installed05-network-excerpt','nt4-installed07-network-excerpt','nt4-installed08-network-excerpt','nt4-installed08b-network-excerpt','nt4-installed09-network-excerpt')]
 files=[]
 for folder in folders:
  if not folder.is_dir():continue
  for p in sorted(folder.iterdir()):
   if p.is_file() and p.suffix.lower() in ('.json','.log','.png','.pcap','.txt','.py'):
    if p.resolve()!=p or p.lstat().st_file_attributes&0x400 or p.stat().st_size>32*1024**2:raise ValueError('Bounded own completed C evidence only')
    files.append({'path':str(p),'bytes':p.stat().st_size,'sha256':sha(p)})
 if len(files)>1024 or sum(x['bytes'] for x in files)>128*1024**2:raise ValueError('C evidence bounds')
 return files
def manifest():
 if MANIFEST.exists() or RECEIPT.exists():raise FileExistsError('One manifest and one cleanup')
 if not json.loads((HERE/'cleanup-exclusive-selftest.json').read_text())['pass']:raise ValueError('Actual exclusive/unlink host proof required')
 proof=closure();exact(PROTECTED,False)
 if sha(PROTECTED)!=PROTECTED_SHA:raise ValueError('Protected03 changed before cleanup')
 rows=[];known={Path(x) for x in LITERALS}|{PROTECTED}
 for literal in LITERALS:
  path=Path(literal);exact(path);m=metadata(path);pin=sha(path)
  if literal in PINS and pin!=PINS[literal]:raise ValueError('Known completed image pin changed')
  chain=json.loads(subprocess.run([str(QIMG),'info','--backing-chain','--output=json',literal],capture_output=True,check=True).stdout)
  recorded=[]
  for item in chain:
   named=Path(item['filename']).resolve();back=item.get('full-backing-filename')
   if item['format']!='qcow2' or named not in known or (back and Path(back).resolve() not in known):raise ValueError('Unknown format/dependency outside reviewed graph')
   recorded.append({'filename':str(named),'backing':str(Path(back).resolve()) if back else None,'format':item['format'],'virtual_bytes':item['virtual-size']})
  if recorded[0]['filename']!=literal:raise ValueError('Unexpected source identity in graph')
  rows.append({'path':literal,'sha256':pin,'known_historical_pin':PINS.get(literal),**m,'backing_chain':recorded})
 groups={}
 for row in rows:groups.setdefault(row['file_id'],[]).append(row)
 for group in groups.values():
  if any(x['links']!=len(group) or x['sha256']!=group[0]['sha256'] or x['bytes']!=group[0]['bytes'] for x in group):raise ValueError('Unknown hardlink or hash mismatch')
 order={x:i for i,x in enumerate(LITERALS)}
 for row in rows:
  for parent in row['backing_chain'][1:]:
   if parent['filename']!=str(PROTECTED) and order[row['path']]>=order[parent['filename']]:
    #08b and08 are one file group; the alias itself is unlinked before08.
    if metadata(Path(parent['filename']))['file_id']!=row['file_id']:raise ValueError('Dependency deletion order violated')
 archive=HERE/'completed-network-transports';archive.mkdir(exist_ok=False)
 copied=[]
 for name in ('nt4-installed03-loadorder05','nt4-installed03-network07','nt4-installed07-canonical-irq08','nt4-installed08b-network-readonly','nt4-installed08-usbmsc-hid-net09'):
  source=VM/name/'read-nt4-network/1024-qemu64-nt4-network'
  if not source.is_dir():continue
  dest=archive/name;dest.mkdir()
  for leaf in ('serial.log','stderr.log','result.json','command.json'):
   p=source/leaf
   if p.is_file():
    if p.resolve()!=p or p.stat().st_size>4*1024**2:raise ValueError('Bounded completed own transport only')
    data=p.read_bytes();(dest/leaf).write_bytes(data);copied.append({'path':str(dest/leaf),'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data)})
 value={'scope':'Authorized only14 literal qcow2 names from owned completed NET04–09/read-only08b. No recursion/directories/logs/source/_assets/NT3/macOS/USB-agent/physical objects deleted.','sourceproof_commit':'511b44a221e171f82414618b8004d0404b021b2c','S20_commit':'40e98cd1256384602311db13e07ae934d7830189','cleanup_script_sha256':sha(Path(__file__)),'closure':proof,'protected_parent':str(PROTECTED),'protected_sha256':PROTECTED_SHA,'rows':rows,'alias09_paths':[],'known_external_dependents':'None in this reviewed ownership graph. Other-agent children of03 are protected by retaining03. No global process or other-task image scan.','C_evidence_pins':evidence_pins(),'C_transport_copies':copied,'literal_count':len(rows),'unique_file_ids':len(groups),'unique_qcow2_file_length_bytes':sum(x[0]['bytes'] for x in groups.values()),'delete_executed':False}
 save(MANIFEST,value);print(json.dumps({'manifest':str(MANIFEST),'literal_names':len(rows),'unique_file_ids':len(groups),'unique_file_length_bytes':value['unique_qcow2_file_length_bytes'],'delete_executed':False}),flush=True)
def execute():
 if RECEIPT.exists():raise FileExistsError('No cleanup retry')
 m=json.loads(MANIFEST.read_text(encoding='utf-8'))
 if [x['path'] for x in m['rows']]!=list(LITERALS) or m['cleanup_script_sha256']!=sha(Path(__file__)):raise ValueError('Exact pinned manifest/script required')
 if closure()!=m['closure']:raise ValueError('Completed writer/reader evidence changed')
 for row in (*m['C_evidence_pins'],*m['C_transport_copies']):
  if sha(Path(row['path']))!=row['sha256']:raise ValueError('Retained C evidence changed')
 exact(PROTECTED,False)
 if sha(PROTECTED)!=PROTECTED_SHA:raise ValueError('Protected03 prehash changed')
 groups={}
 for row in m['rows']:groups.setdefault(row['file_id'],[]).append(row)
 handles={};receipt={'manifest_sha256':sha(MANIFEST),'deleted':[],'refused':[],'sourceproof_commit':m['sourceproof_commit'],'S20_commit':m['S20_commit'],'protected_before_sha256':PROTECTED_SHA,'started_utc_epoch':time.time(),'unique_file_length_bytes_deleted':0,'no_global_process_poll':True,'no_recursive_or_directory_delete':True}
 try:
  #Acquire all groups before any deletion. A lock/change aborts, without retry.
  for ident,group in groups.items():
   representative=Path(group[-1]['path']);exact(representative);h=opened(representative,True);handles[ident]=h;actual=info(h)
   if actual['file_id']!=ident or actual['bytes']!=group[0]['bytes'] or actual['links']!=len(group) or digest_handle(h,actual['bytes'])!=group[0]['sha256']:raise ValueError('Exclusive handle fileID/length/link/hash changed')
   for row in group:
    if metadata(Path(row['path']))['file_id']!=ident:raise ValueError('Alias identity changed')
  for row in m['rows']:
   literal=row['path'];ident=row['file_id'];h=handles[ident]
   if metadata(Path(literal))['file_id']!=ident:raise ValueError('Final literal alias identity changed')
   if not K.DeleteFileW(literal):raise ctypes.WinError(ctypes.get_last_error())
   receipt['deleted'].append({'path':literal,'file_id':ident,'sha256':row['sha256'],'qcow2_file_length_bytes':row['bytes'],'literal_unlink_requested':True,'exclusive_read_write_lease_held':True})
   if literal==groups[ident][-1]['path']:
    K.CloseHandle(h);del handles[ident];receipt['unique_file_length_bytes_deleted']+=row['bytes']
    if any(os.path.lexists(x['path']) for x in groups[ident]):raise ValueError('Unlink completion not observed')
   print('LITERAL_QCOW2_UNLINK_COMPLETE '+literal,flush=True)
 except Exception as error:
  receipt['refused'].append({'error':type(error).__name__+': '+str(error),'retry_attempted':False});raise
 finally:
  for h in handles.values():K.CloseHandle(h)
  receipt.update(completed_utc_epoch=time.time(),protected_after_sha256=sha(PROTECTED),protected_unchanged=sha(PROTECTED)==PROTECTED_SHA,all_declared_names_absent=all(not os.path.lexists(x) for x in LITERALS),C_proofs_preserved=True)
  receipt['pass']=not receipt['refused'] and len(receipt['deleted'])==len(LITERALS) and receipt['protected_unchanged'] and receipt['all_declared_names_absent'];save(RECEIPT,receipt)
 print(json.dumps({'cleanup_pass':receipt['pass'],'deleted_names':len(receipt['deleted']),'unique_file_length_bytes_deleted':receipt['unique_file_length_bytes_deleted'],'protected03_unchanged':receipt['protected_unchanged']}),flush=True)
if __name__=='__main__':
 parser=argparse.ArgumentParser();parser.add_argument('mode',choices=('selftest','manifest','execute'));args=parser.parse_args();{'selftest':selftest,'manifest':manifest,'execute':execute}[args.mode]()
