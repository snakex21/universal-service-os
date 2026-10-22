"""One stopped NT4 HID fixture; SYSTEM/MS bytes only in RAM or whole disks on G."""
from pathlib import Path
import argparse,hashlib,importlib.util,json,os,shutil,stat,struct,subprocess

ROOT=Path(__file__).resolve().parents[3]
MATRIX=ROOT.parent/'macierz-windows'
SOURCE=MATRIX/'artifacts/coverage/vm/nt4-sp6a-desktop-net-ps2-candidate03'
BASE=Path(r'G:\USOS-Kolekcja\_vm\nt4-sp6a-desktop-net-ps2-candidate03\target-retained.qcow2')
BASE_SHA='cf04c232df2dc3bcbc2775c0d31963fd1fc4abd4daf7a2967eba9be1f8af2a21'
WORK=Path(r'G:\USOS-Kolekcja\_vm\nt4-installed03-usb-hid01')
OUT=ROOT/'artifacts/nt4-hid'
RUNTIME=ROOT/'artifacts/coverage/vm'/WORK.name
QIMG=ROOT.parent/'bety-instalacja/tools/qemu/qemu-img.exe'
USB='2d4557439d7c60f7e0d5cc53d36467cbc36ae24596eb614e078059ddc718cfe1'

def load(name,path):
 s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
def sha(path):
 with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def read(path):return json.loads(path.read_text(encoding='utf-8'))
def exact(path):
 if not path.is_absolute() or path.resolve()!=path:raise ValueError('Exact absolute path required')
 for p in (path,*path.parents):
  if p.exists() and p.lstat().st_file_attributes&0x400:raise ValueError('No reparse paths')
def remove_raw(path):
 exact(path)
 if path.parent!=WORK or path.name not in ('preparation.raw','independent-readback.raw','stopped-readback.raw') or not stat.S_ISREG(path.lstat().st_mode):raise ValueError('Owned whole-disk cleanup refused')
 path.unlink()
def run(*args):
 env=dict(os.environ,TEMP=str(WORK),TMP=str(WORK),APPDATA=str(WORK),LOCALAPPDATA=str(WORK))
 return subprocess.run([str(QIMG),*map(str,args)],env=env,check=True,capture_output=True,text=True).stdout.strip()

fat=load('nt4_hid_fat',ROOT/'tools/tests/legacy_bios/fat32_read.py')
hive=load('nt4_hid_registry',ROOT/'tools/xp_hive.py')
pe=load('nt4_hid_pe',ROOT/'tools/tests/check_nt52_driver_imports.py')
class Fat(fat.Fat):
 def chain(self,c):
  seen=set()
  while 2<=c<0xfff8:
   if c in seen or len(seen)>=2048:raise ValueError('Invalid bounded FAT16 chain')
   seen.add(c);yield c;c=struct.unpack('<H',self.read(self.fat+c*2,2))[0]
def file_data(fs,path,maximum):
 c,a,n=fs.find(path)
 if a&16 or not 0<n<=maximum:raise ValueError('Unexpected bounded file')
 offsets=[fs.data+(v-2)*fs.csize for v in fs.chain(c)]
 if not offsets or not (len(offsets)-1)*fs.csize<n<=len(offsets)*fs.csize:raise ValueError('Exact file chain required')
 return b''.join(fs.read(p,fs.csize) for p in offsets)[:n],offsets
def parse_hive(blob):
 if blob[:4]!=b'regf' or blob[4:8]!=blob[8:12] or struct.unpack_from('<I',blob,508)[0]!=hive.checksum(blob):raise ValueError('Clean hive required')
 return hive.read_hive_content(blob)
def number(values,key,name):
 item=values.get(key,{}).get(name)
 if not item or item[0]!=4 or len(item[1])!=4:raise ValueError('Existing DWORD required')
 return struct.unpack('<I',item[1])[0]
def patch(blob):
 values=parse_hive(blob)
 if number(values,'select','current')!=1 or number(values,'select','default')!=1:raise ValueError('Exact CS1 required')
 key='controlset001\\services\\i8042prt'
 if number(values,key,'start')!=1:raise ValueError('Original i8042prt Start1 required')
 found=[]
 for path,_,nk,_ in hive._nodes(blob):
  if path.split('\\',1)[-1].lower()!=key:continue
  count,where=struct.unpack_from('<II',nk,36);entries=hive._cell(blob,where)
  for i in range(count):
   off=struct.unpack_from('<I',entries,4*i)[0];vk=hive._cell(blob,off);nlen=struct.unpack_from('<H',vk,2)[0]
   if hive._name(vk[20:20+nlen],struct.unpack_from('<H',vk,16)[0]&1).lower()!='start':continue
   size,data,kind=struct.unpack_from('<III',vk,4)
   if kind!=4 or size&0x7fffffff!=4:raise ValueError('Exact existing Start DWORD required')
   found.append(hive.HBIN+off+12 if size&0x80000000 else hive.HBIN+data+4)
 if len(found)!=1:raise ValueError('Ambiguous DWORD')
 at=found[0];changed=bytearray(blob);struct.pack_into('<I',changed,at,4)
 expected={k:dict(v) for k,v in values.items()};expected[key]['start']=(4,struct.pack('<I',4))
 if parse_hive(changed)!=expected or changed[:at]!=blob[:at] or changed[at+4:]!=blob[at+4:]:raise ValueError('Unexpected full hive change')
 return bytes(changed),at
class RamFile:
 def __init__(self,data):self.data=data
 def read_bytes(self):return self.data
def inspect(raw,expected_start):
 fs=Fat(raw)
 try:
  if fs.fat32 or fs.base!=32256 or fs.bps!=512:raise ValueError('Exact FAT16 geometry required')
  system,offsets=file_data(fs,'WINNT/SYSTEM32/CONFIG/SYSTEM',8*1024**2)
  usb,_=file_data(fs,'WINNT/SYSTEM32/DRIVERS/USOSUSB.SYS',32128)
  if len(usb)!=32128 or hashlib.sha256(usb).hexdigest()!=USB:raise ValueError('Frozen own USB mismatch')
  values=parse_hive(system);starts={n:number(values,'controlset001\\services\\'+n,'start') for n in ('i8042prt','usosusb','kbdclass','mouclass','ndisloop')}
  if starts!={'i8042prt':expected_start,'usosusb':1,'kbdclass':1,'mouclass':1,'ndisloop':3}:raise ValueError('Exact isolated service set required')
  if number(values,'select','current')!=1 or number(values,'select','default')!=1:raise ValueError('CS1 required')
  tables={};modules={}
  for name,path in (('ntoskrnl.exe','WINNT/SYSTEM32/NTOSKRNL.EXE'),('hal.dll','WINNT/SYSTEM32/HAL.DLL')):
   data,_=file_data(fs,path,8*1024**2);tables[name]=pe.pe(RamFile(data));modules[name]=dict(bytes=len(data),sha256=hashlib.sha256(data).hexdigest())
  _,imports=pe.pe(RamFile(usb));missing=[pe.resolve(tables,m,n) for m,n in imports if pe.resolve(tables,m,n)]
  if missing:raise ValueError('USB import unresolved on actual installed kernel/HAL')
  return system,offsets,fs.csize,dict(usb_sha256=USB,usb_bytes=len(usb),usb_import_count=len(imports),usb_imports_resolved=True,
    original_modules_metadata=modules,service_start=starts,current_default=1,system_sha256=hashlib.sha256(system).hexdigest())
 finally:fs.f.close()
def main(stopped=False):
 for p in (BASE,WORK,OUT):exact(p)
 if sha(BASE)!=BASE_SHA:raise ValueError('Original completed03 changed')
 if shutil.disk_usage(BASE.parent).free<100*1024**3:raise ValueError('100GiB disk reserve required')
 if stopped:
  if read(RUNTIME/'completed.json').get('stopped') is not True or read(RUNTIME/'result.json').get('qemu_returncode')!=0:raise ValueError('Writer completion0 required')
  dest=OUT/'stopped-readback.json'
  if dest.exists():raise FileExistsError(dest)
  target=WORK/'target.qcow2';before=sha(target);raw=WORK/'stopped-readback.raw'
  if raw.exists():raise FileExistsError(raw)
  try:run('convert','-f','qcow2','-O','raw',target,raw);_,_,_,result=inspect(raw,4)
  finally:
   if raw.exists():remove_raw(raw)
  if sha(BASE)!=BASE_SHA or sha(target)!=before:raise ValueError('Source changed during readonly readback')
  result.update(target_sha256=before,base_unchanged=True,scratch_removed=True,ms_bytes_exported=False)
  dest.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8');print(json.dumps(result),flush=True);return
 if WORK.exists() or (OUT/'preparation.json').exists():raise FileExistsError('Fresh case required')
 closed=read(SOURCE/'result.json')
 proof=read(ROOT.parent/'nt4-net/artifacts/nt4-success-review/candidate03-stopped-network-metadata.json')
 if closed.get('qemu_returncode')!=0 or closed.get('shutdown_method')!='QMP quit' or not (SOURCE/'cleanup.json').is_file() or not proof.get('native_safe_off_observed') or not proof.get('native_desktop_observed'):raise ValueError('Exact closed desktop/safeoff boundary required')
 WORK.mkdir();OUT.mkdir(parents=True,exist_ok=True);raw=WORK/'preparation.raw';independent=WORK/'independent-readback.raw';target=WORK/'target.qcow2'
 try:
  run('convert','-f','qcow2','-O','raw',BASE,raw);original,offsets,csize,original_meta=inspect(raw,1);changed,at=patch(original)
  position=offsets[at//csize]+at%csize
  if at%csize>csize-4:raise ValueError('DWORD crosses cluster boundary')
  def write(value):
   with raw.open('r+b') as f:f.seek(position);f.write(value);f.flush();os.fsync(f.fileno())
  write(changed[at:at+4]);run('convert','-f','raw','-O','qcow2','-B',BASE,'-F','qcow2',raw,target)
  compare=run('compare','-f','raw','-F','qcow2',raw,target)
  write(original[at:at+4]);restored=run('compare','-f','raw','-F','qcow2',raw,BASE)
  run('convert','-f','qcow2','-O','raw',target,independent);actual,_,_,result=inspect(independent,4)
  if actual!=changed:raise ValueError('Independent full SYSTEM readback mismatch')
  if sha(BASE)!=BASE_SHA:raise ValueError('Immutable parent changed')
  result.update(base=str(BASE),base_sha256=BASE_SHA,base_unchanged=True,target=str(target),target_sha256=sha(target),
    only_i8042prt_start_changed=True,hive_binary_compare=True,hive_dword_offset=at,raw_dword_offset=position,
    modified_raw_overlay_compare=compare,restored_raw_parent_compare=restored,independent_readback=True,
    original_system_sha256=original_meta['system_sha256'],source_command_sha256=sha(SOURCE/'command.json'),source_result_sha256=sha(SOURCE/'result.json'),
    frozen_usb_unchanged=True,network_driver_changed=False,network_or_msc_pass=False,private_setup_completed=True)
  (WORK/'fixture.json').write_text(json.dumps(dict(folder='Windows NT 4.0',private_profile=True,completed_source=str(SOURCE),source_parent_sha256=BASE_SHA,usb_isolation=True),indent=2)+'\n',encoding='utf-8')
 finally:
  for p in (raw,independent):
   if p.exists():remove_raw(p)
 result.update(scratch_removed=True,ms_bytes_exported=False)
 (OUT/'preparation.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8');print(json.dumps(result,indent=2),flush=True)
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--stopped',action='store_true');main(p.parse_args().stopped)
