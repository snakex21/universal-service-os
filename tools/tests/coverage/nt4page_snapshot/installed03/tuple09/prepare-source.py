"""Owned09 COW: frozen MSC, isolated HID and unchanged qualified NET89b.

No USB source/hub modification. Whole disk scratch stays in the exact G case.
Only existing USB file/size, one existing SYSTEM DWORD and two own FAT files.
"""
from pathlib import Path
import hashlib,importlib.util,json,os,shutil,struct,subprocess
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[1]
OTHER=ROOT.parent/'nt4-usb-hid';MATRIX=ROOT.parent/'macierz-windows'
BASE=Path(r'G:\USOS-Kolekcja\_vm\nt4-installed07-canonical-irq08\target.qcow2')
BASE_SHA='f0f976d0af544fc3b2a87dbaac84811785332d9ef487d6e3e0c6a1ed6ad820ee'
WORK=BASE.parent.with_name('nt4-installed08-usbmsc-hid-net09');OUT=HERE/'candidate09-tuple-preparation.json'
def load(name,path):
 s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
msc=load('nt4_tuple_frozen_msc',OTHER/'tools/tests/coverage/nt4_msc_fixture.py');h=msc.h
p=load('nt4_tuple_same_chain',HERE/'prepare_candidate07_network.py')
previous=load('nt4_tuple_full_compare',HERE/'prepare_candidate08_irq.py')
USB='3139522926f054946b280c14c962593062817a0ca71170a5aeeb8551a6fab2a1'
HELPER_SHA='75cef5e2e8be39b1cdc3d52a0f414464a86cd85fb0513de1139133fc3ac6429e'
MARKER=b'USOS NT4 MSC fixture only\r\n'
NEW=('usos/nt4/msc4test.exe','usos/nt4/msc4test.on')
def sha(path):
 with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def run(*args):
 return subprocess.run([str(h.QIMG),*map(str,args)],check=True,capture_output=True,text=True).stdout.strip()
def remove(path):
 h.exact(path)
 if path.parent!=WORK or path.suffix not in ('.raw','.prefix'):raise ValueError('Only declared exact own scratch')
 path.unlink()
def inspect(raw,start,added):
 fs=msc.Fat(raw)
 try:
  if fs.base!=32256 or fs.bps!=512 or fs.csize!=32768 or fs.nfats!=2:raise ValueError('Pinned measured FAT16 layout required')
  system,chain=h.file_data(fs,'WINNT/SYSTEM32/CONFIG/SYSTEM',8*1024**2);v=h.parse_hive(system)
  starts={n:h.number(v,'controlset001\\services\\'+n,'start') for n in ('i8042prt','usosusb','kbdclass','mouclass','ndisloop','tcpip','dhcp','lanmanworkstation','lanmanserver','browser')}
  if starts!={'i8042prt':start,'usosusb':1,'kbdclass':1,'mouclass':1,'ndisloop':2,'tcpip':2,'dhcp':2,'lanmanworkstation':2,'lanmanserver':4,'browser':4}:raise ValueError('Exact shared tuple service set required')
  if h.number(v,'select','current')!=1 or h.number(v,'select','default')!=1:raise ValueError('Pinned CS1 required')
  expected={'WINNT/SYSTEM32/DRIVERS/USOSNET4.SYS':'89b7337c294ca0c56415cdc4e7023615a628ae8158a5a7ab80dcf6f35ca02233','WINNT/SYSTEM32/DRIVERS/USOSUSB.SYS':USB if added else h.USB,'USOS/COVERAGE/NT4OBS.EXE':'82279b889053a68f42f18fdaeb0a1c0b5a76a00ce21e2685bedb9cb18dc38284','USOS/COVERAGE/USOSLOG.EXE':'fe4ffa555e1cc837185156e7b76639d86b14580150663fd310c35ce3807c94c2','USOS/COVERAGE/FIRSTLO.CMD':'c0f82213bb319445a9ea6d1407608af2b2cec53cbc633a9931ef4802e3bdbedc'}
  if added:expected['USOS/NT4/MSC4TEST.EXE']=HELPER_SHA
  pins={};payloads={}
  for name,pin in expected.items():
   data,_=h.file_data(fs,name,2*1024**2)
   if hashlib.sha256(data).hexdigest()!=pin:raise ValueError('Actual own tuple pin differs')
   pins[name]=dict(sha256=pin,bytes=len(data));payloads[name]=data
  inventory=msc.inventory(fs)
  if not added and any(name in inventory for name in (*NEW,'usos/nt4/msc4log.txt')):raise ValueError('New MSC file paths must be fresh')
  if added:
   marker,_=h.file_data(fs,'USOS/NT4/MSC4TEST.ON',128)
   if marker!=MARKER:raise ValueError('Exact MSC marker required')
  tables={};originals={}
  for name,path in (('ntoskrnl.exe','WINNT/SYSTEM32/NTOSKRNL.EXE'),('hal.dll','WINNT/SYSTEM32/HAL.DLL'),('kernel32.dll','WINNT/SYSTEM32/KERNEL32.DLL')):
   data,_=h.file_data(fs,path,8*1024**2);tables[name]=h.pe.pe(h.RamFile(data));originals[name]=hashlib.sha256(data).hexdigest()
  imports={}
  for label,blob in (('frozen_msc',msc.DRIVER.read_bytes()),('quiet_msc_helper',msc.HELPER.read_bytes())):
   rows=h.pe.pe(h.RamFile(blob))[1]
   if any(h.pe.resolve(tables,m,n) for m,n in rows):raise ValueError('Original NT4 import missing')
   imports[label]=dict(count=len(rows),resolved=True)
  return system,chain,inventory,dict(service_start=starts,system_sha256=hashlib.sha256(system).hexdigest(),actual_own_pins=pins,actual_imports=imports,original_modules_sha256=originals)
 finally:fs.f.close()
def free_clusters(fs):
 b=fs.read(fs.base,512);spf=struct.unpack_from('<H',b,22)[0]
 if not spf or fs.nfats!=2 or fs.csize!=32768:raise ValueError('Exact measured FAT16 two-copy layout required')
 fat1=fs.read(fs.fat,spf*512);fat2=fs.read(fs.fat+spf*512,spf*512)
 if fat1!=fat2:raise ValueError('Both FAT copies must match')
 free=[c for c in range(2,fs.max_clusters+2) if struct.unpack_from('<H',fat1,c*2)[0]==0][:3]
 if len(free)!=3:raise ValueError('Three declared free own clusters required')
 return spf,free
def replace_usb(fs,stream,spf,extra):
 original,_=h.file_data(fs,'WINNT/SYSTEM32/DRIVERS/USOSUSB.SYS',65536);blob=msc.DRIVER.read_bytes()
 c,attr,size=fs.find('WINNT/SYSTEM32/DRIVERS/USOSUSB.SYS');chain=list(fs.chain(c))
 if hashlib.sha256(original).hexdigest()!=h.USB or len(chain)!=1 or len(original)!=32128 or len(blob)!=43648:raise ValueError('Measured single-cluster HID -> two-cluster MSC transition required')
 at,entry=p.directory_entry(fs,'WINNT/SYSTEM32/DRIVERS/USOSUSB.SYS');ranges=[]
 for copy in range(2):
  for cluster,value in ((chain[-1],extra),(extra,0xffff)):
   position=fs.fat+copy*spf*512+cluster*2;stream.seek(position);stream.write(struct.pack('<H',value));ranges.append((position,position+2))
 for i,cluster in enumerate((*chain,extra)):
  position=fs.data+(cluster-2)*fs.csize;part=blob[i*fs.csize:(i+1)*fs.csize]
  stream.seek(position);stream.write(part+b'\0'*(fs.csize-len(part)));ranges.append((position,position+fs.csize))
 stream.seek(at+28);stream.write(struct.pack('<I',len(blob)));ranges.append((at+28,at+32));stream.flush()
 return ranges,dict(path='WINNT/SYSTEM32/DRIVERS/USOSUSB.SYS',before_sha256=h.USB,after_sha256=USB,before_bytes=len(original),after_bytes=len(blob),before_clusters=1,after_clusters=2,first_cluster_unchanged=True,extra_owned_cluster=extra)
def add_pair(fs,stream,spf,free):
 """Two exact short entries, two single free FAT16 clusters; no allocator drift."""
 if len(free)!=2:raise ValueError('Two unique planned free own clusters required')
 cluster,attr,_=fs.find('USOS/NT4');slots=None
 if not attr&16:raise ValueError('Pinned own directory required')
 for c in fs.chain(cluster):
  at=fs.data+(c-2)*fs.csize;data=fs.read(at,fs.csize)
  for offset in range(0,fs.csize-95,32):
   if data[offset]==0 and data[offset+32]==0 and data[offset+64]==0:slots=(at+offset,at+offset+32);break
  if slots:break
 if not slots:raise ValueError('Two declared short directory slots + terminator required')
 ranges=[];record=[]
 for slot,c,name,data in zip(slots,free,(b'MSC4TESTEXE',b'MSC4TESTON '),(msc.HELPER.read_bytes(),MARKER)):
  for copy in range(2):
   at=fs.fat+copy*spf*512+c*2;stream.seek(at);stream.write(b'\xff\xff');ranges.append((at,at+2))
  entry=bytearray(32);entry[:11]=name;entry[11]=0x20;struct.pack_into('<H',entry,24,0x21);struct.pack_into('<H',entry,26,c);struct.pack_into('<I',entry,28,len(data))
  stream.seek(slot);stream.write(entry);ranges.append((slot,slot+32))
  at=fs.data+(c-2)*fs.csize;stream.seek(at);stream.write(data+b'\0'*(fs.csize-len(data)));ranges.append((at,at+fs.csize))
  record.append(dict(short_name=name.decode('ascii'),bytes=len(data),sha256=hashlib.sha256(data).hexdigest(),cluster=c))
 stream.flush();os.fsync(stream.fileno());return ranges,record
def main():
 for path in (BASE,WORK,msc.DRIVER,msc.HELPER):h.exact(path)
 if OUT.exists() or (WORK.exists() and any(WORK.iterdir())):raise FileExistsError('Single fresh tuple09 case required')
 if sha(BASE)!=BASE_SHA or sha(msc.DRIVER)!=USB or sha(msc.HELPER)!=HELPER_SHA:raise ValueError('Exact completed08 and frozen own inputs required')
 if shutil.disk_usage(BASE.parent).free<100*1024**3:raise ValueError('Whole-disk scratch100GiB reserve required')
 complete=json.loads((ROOT/'artifacts/coverage/vm/nt4-installed07-canonical-irq08/completed.json').read_text(encoding='utf-8'))
 if complete.get('stopped') is not True:raise ValueError('Closed parent required')
 WORK.mkdir(exist_ok=True);before=WORK/'before.raw';after=WORK/'after.raw';independent=WORK/'independent.raw';target=WORK/'target.qcow2';record={}
 try:
  run('convert','-f','qcow2','-O','raw',BASE,before);shutil.copyfile(before,after)
  original,chain,inventory,prior=inspect(before,1,False);changed,at=h.patch(original);position=chain[at//32768]+at%32768
  fs=msc.Fat(after)
  try:
   with after.open('r+b') as stream:
    stream.seek(position);stream.write(changed[at:at+4]);ranges=[(position,position+4)]
    spf,free=free_clusters(fs);spans,usb=replace_usb(fs,stream,spf,free[0]);ranges+=spans
    spans,added=add_pair(fs,stream,spf,free[1:]);ranges+=spans
  finally:fs.f.close()
  previous.compare_outside(before,after,ranges)
  actual,_,contents,record=inspect(after,4,True)
  if actual!=changed or set(contents)!=set(inventory)|set(NEW) or any(contents[k]!=inventory[k] for k in inventory if k not in ('winnt/system32/config/system','winnt/system32/drivers/usosusb.sys')):raise ValueError('Exact SYSTEM/USB/two-new-files delta only')
  run('convert','-f','raw','-O','qcow2','-B',BASE,'-F','qcow2',after,target);compare=run('compare','-f','raw','-F','qcow2',after,target)
  run('convert','-f','qcow2','-O','raw',target,independent);check,_,checkfiles,_=inspect(independent,4,True)
  if check!=changed or checkfiles!=contents:raise ValueError('Independent complete inventory and hive proof required')
  aux=load('tuple09_named_aux',MATRIX/'tools/tests/coverage/usability_aux.py');media={};frozen=json.loads((OTHER/'artifacts/nt4-combo/preparation.json').read_text(encoding='utf-8'))
  for kind in ('boot','hot'):
   prefix=WORK/('usb-'+kind+'.prefix');disk=WORK/('usb-test-'+kind+'.qcow2');raw=WORK/('usb-'+kind+'.raw')
   try:
    prefix.write_bytes(msc.own_media(aux,kind));run('convert','-f','raw','-O','qcow2',prefix,disk);run('resize','-q','-f','qcow2',disk,str(aux.VIRTUAL_BYTES));run('convert','-f','qcow2','-O','raw',disk,raw)
    media[kind]=dict(path=str(disk),sha256=sha(disk),proof=msc.inspect_media(raw,kind))
    if media[kind]['sha256']!=frozen['test_media'][kind]['sha256']:raise ValueError('Reuse exact frozen initial media')
   finally:
    for scratch in (prefix,raw):
     if scratch.exists():remove(scratch)
  if sha(BASE)!=BASE_SHA:raise ValueError('Immutable parent changed')
  fixture=json.loads((BASE.parent/'fixture.json').read_text(encoding='utf-8'));fixture['tuple09_test']={'usb_sha256':USB,'msc_helper_sha256':HELPER_SHA,'i8042prt_start':4,'network_start':2,'only_existing_hive_dword':'ControlSet001/Services/i8042prt/Start1->4'}
  (WORK/'prepared-fixture.json').write_text(json.dumps(fixture,indent=2)+'\n',encoding='utf-8',newline='\n')
  record.update(scope='One installed frozen USB313952 HID+MSC +NET89b coexistence, no fresh AUTO/X470 or full IRQroute claim',base=str(BASE),base_sha256=BASE_SHA,target=str(target),target_sha256=sha(target),own_usb_change=usb,new_own_files=added,only_system_dword='i8042prtStart1->4',hive_dword_offset=at,hive_binary_compare=True,all_unrelated_virtual_disk_bytes_identical=True,modified_raw_cow_compare=compare,independent_full_inventory_readback=True,unchanged_original_file_count=len(inventory)-2,original_file_count=len(inventory),test_media=media,topology=dict(boot=1,hot=2,keyboard=3,mouse=4),shared_aux_sha256=sha(MATRIX/'tools/tests/coverage/usability_aux.py'),source_reuse_commit='nt4-usb-hid/6457ab4b',base_unchanged=True,prepared=True,measured_cluster_bytes=32768,offline_first_layout_guard_rejection_not_windows_failure=True)
 finally:
  for scratch in (before,after,independent):
   if scratch.exists():remove(scratch)
  record.update(raw_scratch_removed=True,ms_bytes_exported=False)
  OUT.write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8',newline='\n')
 print(json.dumps(record,indent=2),flush=True)
if __name__=='__main__':main()
