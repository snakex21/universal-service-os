"""Closed MSC04 parent, one SYSTEM DWORD delta, identical frozen313952 package."""
from pathlib import Path
import argparse,hashlib,importlib.util,json,os,shutil,stat,struct,subprocess
HERE=Path(__file__).resolve().parent
s=importlib.util.spec_from_file_location('nt4_combo_msc',HERE/'nt4_msc_fixture.py');msc=importlib.util.module_from_spec(s);s.loader.exec_module(msc)
h=msc.h;ROOT=h.ROOT;MATRIX=h.MATRIX;QIMG=h.QIMG
BASE=msc.WORK/'target.qcow2'
BASE_SHA='a6807a432891b47ea20a4eb1650fc981ae8b7fdade6cec138d9ef03818b1de5c'
WORK=Path(r'G:\USOS-Kolekcja\_vm\nt4-installed03-usb-combo01')
OUT=ROOT/'artifacts/nt4-combo';RUNTIME=ROOT/'artifacts/coverage/vm'/WORK.name
USB=msc.MSC;HELPER_SHA=msc.HELPER_SHA
def read(path):return h.read(path)
def sha(path):return h.sha(path)
def run(*args):
 env=dict(os.environ,TEMP=str(WORK),TMP=str(WORK),APPDATA=str(WORK),LOCALAPPDATA=str(WORK))
 return subprocess.run([str(QIMG),*map(str,args)],env=env,check=True,capture_output=True,text=True).stdout.strip()
def cleanup(path):
 h.exact(path)
 if path.parent!=WORK or path.name not in ('preparation.raw','independent-readback.raw','stopped-readback.raw','usb-boot-readback.raw','usb-hot-readback.raw') or not stat.S_ISREG(path.lstat().st_mode):raise ValueError('Exact owned scratch cleanup refused')
 path.unlink()
def inspect(raw,start):
 fs=msc.Fat(raw)
 try:
  if fs.base!=32256 or fs.bps!=512:raise ValueError('Exact parent geometry required')
  system,chain=h.file_data(fs,'WINNT/SYSTEM32/CONFIG/SYSTEM',8*1024**2);values=h.parse_hive(system)
  starts={n:h.number(values,'controlset001\\services\\'+n,'start') for n in ('i8042prt','usosusb','kbdclass','mouclass','ndisloop')}
  if starts!={'i8042prt':start,'usosusb':1,'kbdclass':1,'mouclass':1,'ndisloop':3} or h.number(values,'select','current')!=1 or h.number(values,'select','default')!=1:raise ValueError('Exact combined service set required')
  usb,_=h.file_data(fs,'WINNT/SYSTEM32/DRIVERS/USOSUSB.SYS',43648);helper,_=h.file_data(fs,'USOS/NT4/MSC4TEST.EXE',5120);marker,_=h.file_data(fs,'USOS/NT4/MSC4TEST.ON',128);log,_=h.file_data(fs,'USOS/NT4/MSC4LOG.TXT',16384)
  if hashlib.sha256(usb).hexdigest()!=USB or hashlib.sha256(helper).hexdigest()!=HELPER_SHA or marker!=b'USOS NT4 MSC fixture only\r\n' or not all(c in (10,13) or 32<=c<127 for c in log):raise ValueError('Exact frozen own SYS/helper/marker/log required')
  tables={};modules={}
  for name,path in (('ntoskrnl.exe','WINNT/SYSTEM32/NTOSKRNL.EXE'),('hal.dll','WINNT/SYSTEM32/HAL.DLL'),('kernel32.dll','WINNT/SYSTEM32/KERNEL32.DLL')):
   data,_=h.file_data(fs,path,8*1024**2);tables[name]=h.pe.pe(h.RamFile(data));modules[name]=hashlib.sha256(data).hexdigest()
  imports={}
  for label,data in (('frozen_msc',usb),('observer',helper)):
   rows=h.pe.pe(h.RamFile(data))[1]
   if any(h.pe.resolve(tables,m,n) for m,n in rows):raise ValueError('Actual original NT4 import missing')
   imports[label]=dict(count=len(rows),resolved=True)
  return system,chain,fs.csize,msc.inventory(fs),log,dict(service_start=starts,current_default=1,system_sha256=hashlib.sha256(system).hexdigest(),usb_sha256=USB,usb_bytes=len(usb),helper_sha256=HELPER_SHA,helper_bytes=len(helper),actual_imports=imports,original_modules_hashes=modules)
 finally:fs.f.close()
def main(stopped=False):
 for p in (BASE,WORK,OUT,msc.BASE):h.exact(p)
 if sha(BASE)!=BASE_SHA or sha(msc.BASE)!=msc.BASE_SHA or sha(msc.HELPER)!=HELPER_SHA:raise ValueError('Both immutable parents and helper pins required')
 if shutil.disk_usage(BASE.parent).free<100*1024**3:raise ValueError('100GiB disk reserve required')
 if stopped:
  if read(RUNTIME/'completed.json').get('stopped') is not True or read(RUNTIME/'result.json').get('qemu_returncode')!=0:raise ValueError('Closed writer0 required')
  if (OUT/'stopped-readback.json').exists():raise FileExistsError('Preserve completed readback')
  target=WORK/'target.qcow2';pin=sha(target);raw=WORK/'stopped-readback.raw'
  try:
   run('convert','-f','qcow2','-O','raw',target,raw);_,_,_,_,log,result=inspect(raw,4)
   before=(msc.OUT/'MSC4LOG.TXT').read_bytes()
   if not log.startswith(before):raise ValueError('Existing own log prefix changed')
   tail=log[len(before):]
   if tail.count(b'MSC4_PASS')!=3 or tail.count(b'ROUNDTRIP_WRITE_FLUSH_CLOSE_PASS')!=1 or tail.count(b'ROUNDTRIP_READBACK_PASS')!=2:raise ValueError('Three new successful explicit MSC stages required')
   (OUT/'MSC4LOG.TXT').write_bytes(log);(OUT/'combo-own-log-tail.txt').write_bytes(tail)
  finally:
   if raw.exists():cleanup(raw)
  result.update(actual_target_sha256=pin,own_log_sha256=hashlib.sha256(log).hexdigest(),prior_own_log_prefix_unchanged=True,own_usb={})
  for kind in ('boot','hot'):
   disk=WORK/('usb-test-'+kind+'.qcow2');raw=WORK/('usb-'+kind+'-readback.raw')
   try:run('convert','-f','qcow2','-O','raw',disk,raw);result['own_usb'][kind]=dict(sha256=sha(disk),**msc.inspect_media(raw,kind,kind=='hot'))
   finally:
    if raw.exists():cleanup(raw)
  if sha(target)!=pin or sha(BASE)!=BASE_SHA or sha(msc.BASE)!=msc.BASE_SHA:raise ValueError('Readonly boundary changed')
  result.update(msc04_parent_unchanged=True,original03_parent_unchanged=True,raw_scratch_removed=True,ms_bytes_exported=False)
  (OUT/'stopped-readback.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8');print(json.dumps(result,indent=2),flush=True);return
 if WORK.exists() or OUT.exists():raise FileExistsError('Fresh combined case required')
 proof=read(msc.OUT/'evaluation.json');closed=read(msc.RUNTIME/'result.json');prior=read(msc.OUT/'stopped-readback.json')
 if not proof.get('pass') or not proof.get('native_shutdown_pass') or closed.get('error') or closed.get('qemu_returncode')!=0 or prior.get('actual_target_sha256')!=BASE_SHA:raise ValueError('Completed qualified MSC04 parent required')
 WORK.mkdir();OUT.mkdir();raw=WORK/'preparation.raw';independent=WORK/'independent-readback.raw';target=WORK/'target.qcow2'
 try:
  run('convert','-f','qcow2','-O','raw',BASE,raw);system,chain,csize,before,log,original=inspect(raw,1);changed,at=h.patch(system)
  position=chain[at//csize]+at%csize
  if at%csize>csize-4:raise ValueError('DWORD crosses cluster boundary')
  def write(value):
   with raw.open('r+b') as f:f.seek(position);f.write(value);f.flush();os.fsync(f.fileno())
  write(changed[at:at+4]);run('convert','-f','raw','-O','qcow2','-B',BASE,'-F','qcow2',raw,target);modified=run('compare','-f','raw','-F','qcow2',raw,target)
  write(system[at:at+4]);restored=run('compare','-f','raw','-F','qcow2',raw,BASE)
  run('convert','-f','qcow2','-O','raw',target,independent);actual,_,_,after,actual_log,result=inspect(independent,4)
  key='winnt/system32/config/system'
  if actual!=changed or actual_log!=log or set(before)!=set(after) or any(before[k]!=after[k] for k in before if k!=key):raise ValueError('Only SYSTEM DWORD delta required')
  aux=h.load('nt4_combo_aux',MATRIX/'tools/tests/coverage/usability_aux.py');media={};parent_prep=read(msc.OUT/'preparation.json')
  for kind in ('boot','hot'):
   prefix=WORK/('usb-'+kind+'.prefix');disk=WORK/('usb-test-'+kind+'.qcow2');media_raw=WORK/('usb-'+kind+'-readback.raw')
   try:
    prefix.write_bytes(msc.own_media(aux,kind));run('convert','-f','raw','-O','qcow2',prefix,disk);run('resize','-q','-f','qcow2',disk,str(aux.VIRTUAL_BYTES));run('convert','-f','qcow2','-O','raw',disk,media_raw)
    media[kind]=dict(path=str(disk),sha256=sha(disk),independent_readback=msc.inspect_media(media_raw,kind))
    if media[kind]['sha256']!=parent_prep['test_media'][kind]['sha256']:raise ValueError('Media differs from qualified initial MSC04 fixture')
   finally:
    prefix.unlink(missing_ok=True)
    if media_raw.exists():cleanup(media_raw)
  if sha(BASE)!=BASE_SHA or sha(msc.BASE)!=msc.BASE_SHA:raise ValueError('Immutable source changed')
  result.update(base=str(BASE),base_sha256=BASE_SHA,original03_parent_sha256=msc.BASE_SHA,target=str(target),target_sha256=sha(target),
   only_system_dword_changed=True,hive_binary_compare=True,hive_dword_offset=at,raw_dword_offset=position,original_system_sha256=original['system_sha256'],
   modified_raw_cow_compare=modified,restored_raw_parent_compare=restored,independent_full_inventory_readback=True,original_file_count=len(before),
   unchanged_other_files=len(before)-1,new_target_files=[],sys_helper_marker_log_unchanged=True,source_command_sha256=sha(msc.RUNTIME/'command.json'),
   msc04_parent_unchanged=True,original03_parent_unchanged=True,test_media=media,media_initial_pins_identical_to_msc04=True,
   shared_aux_sha256=sha(MATRIX/'tools/tests/coverage/usability_aux.py'),topology=dict(boot=1,hot=2,keyboard=3,mouse=4),hid_pass=False,msc_pass=False)
 finally:
  for p in (raw,independent):
   if p.exists():cleanup(p)
 result.update(raw_scratch_removed=True,ms_bytes_exported=False)
 (OUT/'preparation.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8');print(json.dumps(result,indent=2),flush=True)
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--stopped',action='store_true');main(p.parse_args().stopped)
