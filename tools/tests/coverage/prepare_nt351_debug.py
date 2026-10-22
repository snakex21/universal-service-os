"""Patch one existing driver DebugPort DWORD in a new stopped-target overlay.

SYSTEM and driver data stay in RAM. Only owned VM disk images remain on G:.
No physical disks, RegLoadKey or registry APIs are used on the host.
"""
from pathlib import Path
import hashlib,importlib.util,json,shutil,struct,subprocess
ROOT=Path(__file__).resolve().parents[3]
COLLECTION=Path(r'G:\USOS-Kolekcja').resolve()
BASE=COLLECTION/'_vm/r18c-nt351-cold-i8042-on/target.qcow2'
WORK=COLLECTION/'_vm/r18d-nt351-debug-e9'
OUT=ROOT/'artifacts/nt351-network/r18d-debug-preparation.json'
QIMG=Path(r'C:\Users\ASRock\usos-work\bety-instalacja\tools\qemu\qemu-img.exe')
DRIVER='dc8827954e6fe75ee8264c7382e87899cc9761890998198c126c7ea8aa5c55b6'

def load(name,path):
 s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
hive=load('owned_hive',ROOT/'tools/xp_hive.py')
fat=load('owned_fat',ROOT/'tools/tests/legacy_bios/fat32_read.py')

class BoundedFat(fat.Fat):
 def chain(self,c):
  seen=set();limit=0x0ffffff8 if self.fat32 else 0xfff8
  while 2<=c<limit:
   if c in seen or len(seen)>=2048:raise ValueError('Invalid or oversized FAT chain')
   seen.add(c);yield c
   c=(struct.unpack('<I',self.read(self.fat+c*4,4))[0]&0x0fffffff) if self.fat32 else struct.unpack('<H',self.read(self.fat+c*2,2))[0]

def file_data(fs,path,maximum):
 c,attr,size=fs.find(path)
 if attr&0x10 or not 0<size<=maximum:raise ValueError('Invalid bounded file')
 chain=list(fs.chain(c))
 if len(chain)*fs.csize<size or (len(chain)-1)*fs.csize>=size:raise ValueError('Unexpected file cluster count')
 offsets=[fs.data+(x-2)*fs.csize for x in chain]
 return b''.join(fs.read(at,fs.csize) for at in offsets)[:size],offsets

def patch_hive(original):
 if original[:4]!=b'regf' or struct.unpack_from('<I',original,0x1fc)[0]!=hive.checksum(original):raise ValueError('Invalid hive checksum')
 if struct.unpack_from('<I',original,4)[0]!=struct.unpack_from('<I',original,8)[0]:raise ValueError('Unclean hive sequences')
 before=hive.read_hive_content(original)
 current=before['select']['current'];default=before['select']['default']
 if current[0]!=4 or default!=current or len(current[1])!=4:raise ValueError('Ambiguous selected control set')
 number=struct.unpack('<I',current[1])[0]
 if not 1<=number<=999:raise ValueError('Invalid current controlset')
 key=f'controlset{number:03d}\\services\\ndisloop1\\parameters'
 if before[key].get('debugport')!=(4,b'\x00'*4):raise ValueError('DebugPort must already be exactly DWORD0')
 found=[]
 for path,at,nk,values in hive._nodes(original):
  rel=path.split('\\',1)[1].lower() if '\\' in path else ''
  if rel!=key:continue
  count,vlist=struct.unpack_from('<II',nk,0x24);entries=hive._cell(original,vlist)
  for i in range(count):
   off=struct.unpack_from('<I',entries,4*i)[0];vk=hive._cell(original,off)
   nlen=struct.unpack_from('<H',vk,2)[0];flags=struct.unpack_from('<H',vk,16)[0]
   if hive._name(vk[20:20+nlen],flags&1).lower()!='debugport':continue
   size,data,kind=struct.unpack_from('<III',vk,4)
   if kind!=4 or size&0x7fffffff!=4:raise ValueError('Not an existing bounded DWORD')
   found.append(hive.HBIN+off+4+8 if size&0x80000000 else hive.HBIN+data+4)
 if len(found)!=1:raise ValueError('Ambiguous DebugPort value cell')
 changed=bytearray(original);struct.pack_into('<I',changed,found[0],233)
 after=hive.read_hive_content(changed)
 expected={k:dict(v) for k,v in before.items()};expected[key]['debugport']=(4,struct.pack('<I',233))
 if after!=expected or any(a!=b for i,(a,b) in enumerate(zip(original,changed)) if not found[0]<=i<found[0]+4):raise ValueError('Unexpected hive modification')
 dependencies={}
 for service in ('i8042prt','kbdclass','mouclass','usosusb','ndisloop','ndisloop1'):
  path=f'controlset{number:03d}\\services\\{service}'
  dependencies[service]={}
  for name in ('start','type','group','dependonservice','dependongroup','imagepath'):
   value=before.get(path,{}).get(name)
   if value is not None:
    typ,raw=value;dependencies[service][name]={'type':typ,'value':struct.unpack('<I',raw)[0] if typ==4 and len(raw)==4 else raw.decode('utf-16le').rstrip('\0') if typ in (1,2,7) else raw.hex()}
 return bytes(changed),dict(key=key,value='DebugPort',before=0,after=233,hive_version=hive.check_header(original),hive_value_offset=found[0],hive_only_one_dword_changed=True,services=dependencies)

def main():
 assert str(WORK)==r'G:\USOS-Kolekcja\_vm\r18d-nt351-debug-e9'
 assert BASE.resolve().is_relative_to(COLLECTION/'_vm') and not WORK.exists() and not OUT.exists()
 previous=ROOT/'artifacts/coverage/vm/r18c-nt351-cold-i8042-on/completed.json'
 if json.loads(previous.read_text(encoding='utf-8')).get('stopped') is not True:raise ValueError('No completed writer confirmation')
 if shutil.disk_usage(COLLECTION).free<100*1024**3:raise ValueError('Less than100GiB free')
 WORK.mkdir();raw=WORK/'scratch-stopped.raw';overlay=WORK/'target.qcow2'
 subprocess.run([str(QIMG),'convert','-f','qcow2','-O','raw',str(BASE),str(raw)],check=True)
 fs=BoundedFat(raw)
 try:
  if fs.fat32 or fs.base!=32256 or fs.bps!=512:raise ValueError('Expected exact NT351 FAT16 layout')
  original,offsets=file_data(fs,'WINNT/SYSTEM32/CONFIG/SYSTEM',4*1024**2)
  driver,_=file_data(fs,'WINNT/SYSTEM32/DRIVERS/usosnet351.sys',17024)
  if len(driver)!=17024 or hashlib.sha256(driver).hexdigest()!=DRIVER:raise ValueError('Installed own SYS changed')
  changed,record=patch_hive(original);cluster_size=fs.csize
 finally:fs.f.close()
 with raw.open('r+b') as stream:
  for index,at in enumerate(offsets):
   data=changed[index*cluster_size:(index+1)*cluster_size]
   stream.seek(at);stream.write(data)
  stream.flush()
 fs=BoundedFat(raw)
 try:
  verified,_=file_data(fs,'WINNT/SYSTEM32/CONFIG/SYSTEM',4*1024**2)
  if verified!=changed:raise ValueError('SYSTEM readback differs')
 finally:fs.f.close()
 subprocess.run([str(QIMG),'convert','-f','raw','-O','qcow2','-B',str(BASE),'-F','qcow2',str(raw),str(overlay)],check=True)
 subprocess.run([str(QIMG),'compare','-f','raw','-F','qcow2',str(raw),str(overlay)],check=True)
 meta=json.loads((BASE.parent/'fixture.json').read_text(encoding='utf-8'))
 meta.update(debug_port=233,debug_key=record['key'],stopped_parent=str(BASE),diagnostic_only=True)
 (WORK/'fixture.json').write_text(json.dumps(meta,indent=2)+'\n',encoding='utf-8')
 record.update(base=str(BASE),overlay=str(overlay),driver_sha256=DRIVER,system_before_sha256=hashlib.sha256(original).hexdigest(),system_after_sha256=hashlib.sha256(changed).hexdigest(),raw_overlay_qemu_compare_pass=True,ms_hive_or_driver_exported=False)
 assert raw.resolve().parent==WORK.resolve();raw.unlink();record['scratch_raw_removed']=True
 OUT.write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8')
 print(json.dumps(record,indent=2),flush=True)
if __name__=='__main__':main()
