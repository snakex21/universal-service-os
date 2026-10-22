"""Separate frozen MSC package on completed03; whole-disk G/RAM only."""
from pathlib import Path
import argparse,hashlib,json,os,shutil,stat,struct,subprocess
from pyfatfs.PyFatFS import PyFatFS
import importlib.util
HERE=Path(__file__).resolve().parent
s=importlib.util.spec_from_file_location('nt4_msc_common',HERE/'nt4_hid_fixture.py');h=importlib.util.module_from_spec(s);s.loader.exec_module(h)
ROOT=h.ROOT;BASE=h.BASE;BASE_SHA=h.BASE_SHA
WORK=Path(r'G:\USOS-Kolekcja\_vm\nt4-installed03-usb-msc04')
OUT=ROOT/'artifacts/nt4-msc';RUNTIME=ROOT/'artifacts/coverage/vm'/WORK.name
DRIVER=ROOT.parent/'nt4-net/artifacts/nt4-address-cache-review/frozen-msc-USOSUSB.SYS'
MSC='3139522926f054946b280c14c962593062817a0ca71170a5aeeb8551a6fab2a1'
HELPER=OUT/'build04/MSC4TEST.EXE'
HELPER_SHA='75cef5e2e8be39b1cdc3d52a0f414464a86cd85fb0513de1139133fc3ac6429e'
OLD='winnt/system32/drivers/usosusb.sys'
NEW=('usos/nt4/msc4test.exe','usos/nt4/msc4test.on')
def run(*args):
 env=dict(os.environ,TEMP=str(WORK),TMP=str(WORK),APPDATA=str(WORK),LOCALAPPDATA=str(WORK))
 return subprocess.run([str(h.QIMG),*map(str,args)],env=env,check=True,capture_output=True,text=True).stdout.strip()
def cleanup(path):
 h.exact(path)
 if path.parent!=WORK or path.name not in ('preparation.raw','independent-readback.raw','stopped-readback.raw','usb-boot-readback.raw','usb-hot-readback.raw') or not stat.S_ISREG(path.lstat().st_mode):raise ValueError('Exact owned scratch cleanup refused')
 path.unlink()
class Fat(h.Fat):
 def __init__(self,path):
  super().__init__(path)
  b=self.read(self.base,512)
  sectors=struct.unpack_from('<H',b,19)[0] or struct.unpack_from('<I',b,32)[0]
  self.max_clusters=(sectors-(self.data-self.base)//self.bps)//self.spc
  if self.fat32 or not 1<=self.max_clusters<=65524:raise ValueError('Bounded FAT16 geometry required')
 def chain(self,c):
  seen=set()
  while 2<=c<0xfff8:
   if c>=self.max_clusters+2 or c in seen or len(seen)>=self.max_clusters:raise ValueError('Bounded FAT16 chain required')
   seen.add(c);yield c;c=struct.unpack('<H',self.read(self.fat+c*2,2))[0]
def inventory(fs):
 found={};pending=[('',0)];directories=set()
 while pending:
  path,c=pending.pop()
  if c in directories or len(directories)>1024:raise ValueError('Directory cycle/count')
  directories.add(c)
  for name,short,attr,cluster,size in fs.entries(c):
   if name in ('.','..') or attr&8:continue
   key=(path+'/'+name).lstrip('/').lower()
   if attr&16:pending.append((key,cluster));continue
   # The pinned parent contains a measured548405248-byte PAGEFILE. Hash it
   # cluster by cluster; bounded module/hive readers below remain unchanged.
   if key in found or len(found)>8192 or size>min(1024**3,fs.max_clusters*fs.csize):raise ValueError('Bounded original inventory required')
   dig=hashlib.sha256();left=size
   if size:
    for v in fs.chain(cluster):
     count=min(left,fs.csize);data=fs.read(fs.data+(v-2)*fs.csize,count)
     if len(data)!=count:raise ValueError('Truncated original cluster')
     dig.update(data);left-=count
     if not left:break
   if left:raise ValueError('Truncated original file')
   found[key]=(size,dig.hexdigest())
 return found
def inspect(raw):
 fs=Fat(raw)
 try:
  if fs.fat32 or fs.base!=32256 or fs.bps!=512:raise ValueError('Exact parent FAT16 layout required')
  system,_=h.file_data(fs,'WINNT/SYSTEM32/CONFIG/SYSTEM',8*1024**2);values=h.parse_hive(system)
  starts={n:h.number(values,'controlset001\\services\\'+n,'start') for n in ('i8042prt','usosusb','kbdclass','mouclass','ndisloop')}
  if starts!={'i8042prt':1,'usosusb':1,'kbdclass':1,'mouclass':1,'ndisloop':3} or h.number(values,'select','current')!=1 or h.number(values,'select','default')!=1:raise ValueError('Original PS2/network/SYSTEM policy changed')
  usb,chain=h.file_data(fs,OLD,43648);tables={};module_hashes={}
  for name,path in (('ntoskrnl.exe','WINNT/SYSTEM32/NTOSKRNL.EXE'),('hal.dll','WINNT/SYSTEM32/HAL.DLL'),('kernel32.dll','WINNT/SYSTEM32/KERNEL32.DLL')):
   blob,_=h.file_data(fs,path,8*1024**2);tables[name]=h.pe.pe(h.RamFile(blob));module_hashes[name]=hashlib.sha256(blob).hexdigest()
  imports={}
  for label,blob in (('frozen_msc',DRIVER.read_bytes()),('observer',HELPER.read_bytes())):
   rows=h.pe.pe(h.RamFile(blob))[1]
   if any(h.pe.resolve(tables,m,n) for m,n in rows):raise ValueError('Actual original NT4 import missing')
   imports[label]=dict(count=len(rows),resolved=True)
  return system,usb,chain,fs.csize,inventory(fs),dict(service_start=starts,current_default=1,system_sha256=hashlib.sha256(system).hexdigest(),usb_sha256=hashlib.sha256(usb).hexdigest(),actual_imports=imports,original_modules_hashes=module_hashes)
 finally:fs.f.close()
def own_media(aux,kind):
 data=bytearray(aux.fat16_prefix(kind));start=aux.PARTITION_LBA*512;root_sector=1+2*aux.FAT_SECTORS;root=start+root_sector*512;data_sector=root_sector+aux.ROOT_ENTRIES*32//512
 marker=('USOS NT4 MSC volume '+kind+'\r\n').encode('ascii')
 for sector in (1,1+aux.FAT_SECTORS):struct.pack_into('<H',data,start+sector*512+6,0xffff)
 entry=root+32;data[entry:entry+11]=b'MSC4VOL ON ';data[entry+11]=0x20;struct.pack_into('<HHHI',data,entry+22,0,0x21,3,len(marker))
 # Both the BPB and the standard root volume-label entry declare the label.
 entry=root+64;data[entry:entry+11]=b'USOS_BOOT  ' if kind=='boot' else b'USOS_HOT   ';data[entry+11]=8
 at=start+(data_sector+4)*512
 if len(data)<at+len(marker):data.extend(b'\0'*(at+len(marker)-len(data)))
 data[at:at+len(marker)]=marker
 return bytes(data)
def inspect_media(raw,kind,roundtrip=False):
 fs=Fat(raw)
 try:
  name='START.TXT' if kind=='boot' else 'HOTPLUG.TXT';content,_=h.file_data(fs,name,256);marker,_=h.file_data(fs,'MSC4VOL.ON',128)
  expected=('USOS disposable USB '+kind+' read test\r\n').encode('ascii')
  label=b'USOS_BOOT  ' if kind=='boot' else b'USOS_HOT   ';entry=fs.read(fs.root16+64,32)
  if content!=expected or marker!=('USOS NT4 MSC volume '+kind+'\r\n').encode() or entry[11]!=8 or entry[:11]!=label or fs.read(fs.base+43,11)!=label or fs.read(450,1)!=b'\x06':raise ValueError('Own USB FAT16/MBR/label/payload proof differs')
  facts=dict(file=name,payload_matches=True,marker_matches=True,root_bpb_label_matches=True,fat16=True,mbr_partition_type=6)
  if roundtrip:
   data,_=h.file_data(fs,'ROUNDTRIP.TXT',256)
   if data!=b'USOS NT4 MSC ROUNDTRIP persisted\r\n':raise ValueError('Actual persisted roundtrip differs')
   facts.update(roundtrip_matches=True,roundtrip_sha256=hashlib.sha256(data).hexdigest())
  return facts
 finally:fs.f.close()
def main(stopped=False):
 for path in (BASE,WORK,OUT,DRIVER,HELPER):h.exact(path)
 if h.sha(BASE)!=BASE_SHA or h.sha(DRIVER)!=MSC or DRIVER.stat().st_size!=43648 or h.sha(HELPER)!=HELPER_SHA:raise ValueError('Exact frozen inputs required')
 if shutil.disk_usage(BASE.parent).free<100*1024**3:raise ValueError('100GiB disk reserve required')
 if stopped:
  if h.read(RUNTIME/'completed.json').get('stopped') is not True or h.read(RUNTIME/'result.json').get('qemu_returncode')!=0:raise ValueError('Closed writer0 required')
  if (OUT/'stopped-readback.json').exists():raise FileExistsError('Preserve completed readback')
  raw=WORK/'stopped-readback.raw';target=WORK/'target.qcow2';pin=h.sha(target)
  try:
   run('convert','-f','qcow2','-O','raw',target,raw);_,usb,_,_,_,record=inspect(raw)
   if hashlib.sha256(usb).hexdigest()!=MSC:raise ValueError('Actual installed MSC differs')
   fs=Fat(raw)
   try:
    log,_=h.file_data(fs,'USOS/NT4/MSC4LOG.TXT',16384);binary,_=h.file_data(fs,NEW[0],5120)
    if hashlib.sha256(binary).hexdigest()!=HELPER_SHA or b'\0' in log:raise ValueError('Own observer/log differs')
   finally:fs.f.close()
   (OUT/'MSC4LOG.TXT').write_bytes(log)
  finally:
   if raw.exists():cleanup(raw)
  record.update(actual_target_sha256=pin,helper_sha256=HELPER_SHA,own_log_sha256=hashlib.sha256(log).hexdigest(),own_usb={})
  for kind in ('boot','hot'):
   media=WORK/('usb-test-'+kind+'.qcow2');raw=WORK/('usb-'+kind+'-readback.raw')
   try:
    run('convert','-f','qcow2','-O','raw',media,raw);record['own_usb'][kind]=dict(sha256=h.sha(media),**inspect_media(raw,kind,kind=='hot'))
   finally:
    if raw.exists():cleanup(raw)
  if h.sha(BASE)!=BASE_SHA or h.sha(target)!=pin:raise ValueError('Readonly boundary changed')
  record.update(base_unchanged=True,raw_scratch_removed=True,ms_bytes_exported=False)
  (OUT/'stopped-readback.json').write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8');print(json.dumps(record,indent=2));return
 if WORK.exists() or (OUT/'preparation.json').exists():raise FileExistsError('Fresh MSC case required')
 source=h.read(h.SOURCE/'result.json');closed=h.read(ROOT.parent/'nt4-net/artifacts/nt4-success-review/candidate03-stopped-network-metadata.json')
 if source.get('qemu_returncode')!=0 or not closed.get('native_desktop_observed') or not closed.get('native_safe_off_observed') or not (h.SOURCE/'cleanup.json').is_file():raise ValueError('Closed original03 required')
 WORK.mkdir();raw=WORK/'preparation.raw';independent=WORK/'independent-readback.raw';target=WORK/'target.qcow2'
 try:
  run('convert','-f','qcow2','-O','raw',BASE,raw);system,old,chain,csize,before,original=inspect(raw)
  if hashlib.sha256(old).hexdigest()!=h.USB or any(p in before for p in NEW):raise ValueError('Exact original driver/new own names required')
  fits=len(DRIVER.read_bytes())<=len(chain)*csize
  if fits:
   blob=DRIVER.read_bytes();fs=Fat(raw)
   try:
    c,_,_=fs.find('WINNT/SYSTEM32/DRIVERS');entry=None
    for cluster in fs.chain(c):
     at=fs.data+(cluster-2)*csize
     for i in range(0,csize,32):
      if fs.read(at+i,11)==b'USOSUSB SYS':entry=at+i
    if entry is None:raise ValueError('Exact existing own directory entry absent')
   finally:fs.f.close()
   with raw.open('r+b') as f:
    for i,at in enumerate(chain):f.seek(at);f.write(blob[i*csize:(i+1)*csize])
    f.seek(entry+28);f.write(struct.pack('<I',len(blob)));f.flush();os.fsync(f.fileno())
  with PyFatFS(str(raw),offset=32256,preserve_case=True) as fs:
   if not fits:fs.writebytes('WINNT/SYSTEM32/DRIVERS/USOSUSB.SYS',DRIVER.read_bytes())
   fs.writebytes('USOS/NT4/MSC4TEST.EXE',HELPER.read_bytes());fs.writebytes('USOS/NT4/MSC4TEST.ON',b'USOS NT4 MSC fixture only\r\n')
  after_system,usb,after_chain,_,after,record=inspect(raw)
  if after_system!=system or hashlib.sha256(usb).hexdigest()!=MSC or set(after)!=set(before)|set(NEW) or any(before[p]!=after[p] for p in before if p!=OLD):raise ValueError('Original SYSTEM/other file contents changed')
  run('convert','-f','raw','-O','qcow2','-B',BASE,'-F','qcow2',raw,target);compare=run('compare','-f','raw','-F','qcow2',raw,target)
  run('convert','-f','qcow2','-O','raw',target,independent);check_system,check_usb,_,_,check,checked=inspect(independent)
  if check_system!=system or check_usb!=DRIVER.read_bytes() or check!=after or h.sha(BASE)!=BASE_SHA:raise ValueError('Independent full inventory proof differs')
  aux=h.load('nt4_msc_shared_aux',h.MATRIX/'tools/tests/coverage/usability_aux.py')
  media={}
  for kind in ('boot','hot'):
   prefix=WORK/('usb-'+kind+'.prefix');disk=WORK/('usb-test-'+kind+'.qcow2')
   try:prefix.write_bytes(own_media(aux,kind));run('convert','-f','raw','-O','qcow2',prefix,disk);run('resize','-q','-f','qcow2',disk,str(aux.VIRTUAL_BYTES))
   finally:prefix.unlink(missing_ok=True)
   media_raw=WORK/('usb-'+kind+'-readback.raw')
   try:run('convert','-f','qcow2','-O','raw',disk,media_raw);proof=inspect_media(media_raw,kind)
   finally:
    if media_raw.exists():cleanup(media_raw)
   media[kind]=dict(path=str(disk),sha256=h.sha(disk),label='USOS_BOOT' if kind=='boot' else 'USOS_HOT',fat16_mbr=True,independent_readback=proof)
  record.update(base=str(BASE),base_sha256=BASE_SHA,base_unchanged=True,target=str(target),target_sha256=h.sha(target),
   old_usb_sha256=h.USB,usb_sha256=MSC,usb_bytes=43648,helper_sha256=HELPER_SHA,helper_bytes=5120,
   only_original_file_changed=OLD,new_own_files=list(NEW),original_file_count=len(before),unchanged_original_files=len(before)-1,
   all_other_original_contents_unchanged=True,system_binary_unchanged=True,source_command_sha256=h.sha(h.SOURCE/'command.json'),
   original_chain_capacity=len(chain)*csize,original_chain_clusters=len(chain),new_chain_clusters=len(after_chain),new_fits_original_chain=fits,
   own_file_allocation='bounded existing chain/directory size' if fits else 'PyFatFS allocation only for own USB SYS and two declared own additions',
   full_raw_cow_compare=compare,independent_full_inventory_readback=True,test_media=media,
   named_backend_source_commit='d62eb0c6',shared_aux_sha256=h.sha(h.MATRIX/'tools/tests/coverage/usability_aux.py'))
 finally:
  for path in (raw,independent):
   if path.exists():cleanup(path)
 record.update(raw_scratch_removed=True,ms_bytes_exported=False)
 (OUT/'preparation.json').write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8');print(json.dumps(record,indent=2),flush=True)
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--stopped',action='store_true');main(p.parse_args().stopped)
