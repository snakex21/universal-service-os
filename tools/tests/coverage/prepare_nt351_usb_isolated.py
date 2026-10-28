"""Disable only PS/2 port service on a new overlay of stopped R18e.
Original Microsoft hive/driver contents stay in RAM; output is metadata only.
"""
from pathlib import Path
import hashlib,importlib.util,json,shutil,struct,subprocess
spec=importlib.util.spec_from_file_location("owned_debug_helper",Path(__file__).with_name("prepare_nt351_debug.py"));h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
ROOT=h.ROOT;COLLECTION=h.COLLECTION;hive=h.hive
BASE=COLLECTION/'_vm/r18e-nt351-stubfix-e9/target.qcow2'
WORK=COLLECTION/'_vm/r18f-nt351-usb-port-isolation'
OUT=ROOT/'artifacts/nt351-network/r18f-usb-isolation-preparation.json'
DRIVER='f39d58fd923632dacbc577562045015123a9bdfc98c56237090bfcd53c70612a'
USB='2d4557439d7c60f7e0d5cc53d36467cbc36ae24596eb614e078059ddc718cfe1'

def patch_hive(original):
 if original[:4]!=b'regf' or struct.unpack_from('<I',original,0x1fc)[0]!=hive.checksum(original):raise ValueError('Invalid hive checksum')
 if struct.unpack_from('<I',original,4)[0]!=struct.unpack_from('<I',original,8)[0]:raise ValueError('Unclean hive sequences')
 before=hive.read_hive_content(original)
 current=before['select']['current'];default=before['select']['default']
 if current[0]!=4 or default!=current or len(current[1])!=4:raise ValueError('Ambiguous selected control set')
 number=struct.unpack('<I',current[1])[0]
 if not 1<=number<=999:raise ValueError('Invalid current controlset')
 key=f'controlset{number:03d}\\services\\i8042prt'
 if before[key].get('start')!=(4,struct.pack('<I',1)):raise ValueError('i8042prt Start must already be exactly DWORD1')
 found=[]
 for path,at,nk,values in hive._nodes(original):
  rel=path.split('\\',1)[1].lower() if '\\' in path else ''
  if rel!=key:continue
  count,vlist=struct.unpack_from('<II',nk,0x24);entries=hive._cell(original,vlist)
  for i in range(count):
   off=struct.unpack_from('<I',entries,4*i)[0];vk=hive._cell(original,off)
   nlen=struct.unpack_from('<H',vk,2)[0];flags=struct.unpack_from('<H',vk,16)[0]
   if hive._name(vk[20:20+nlen],flags&1).lower()!='start':continue
   size,data,kind=struct.unpack_from('<III',vk,4)
   if kind!=4 or size&0x7fffffff!=4:raise ValueError('Not an existing bounded DWORD')
   found.append(hive.HBIN+off+4+8 if size&0x80000000 else hive.HBIN+data+4)
 if len(found)!=1:raise ValueError('Ambiguous Start value cell')
 changed=bytearray(original);struct.pack_into('<I',changed,found[0],4)
 after=hive.read_hive_content(changed)
 expected={k:dict(v) for k,v in before.items()};expected[key]['start']=(4,struct.pack('<I',4))
 if after!=expected or any(a!=b for i,(a,b) in enumerate(zip(original,changed)) if not found[0]<=i<found[0]+4):raise ValueError('Unexpected hive modification')
 dependencies={}
 for service in ('i8042prt','kbdclass','mouclass','usosusb','ndisloop','ndisloop1'):
  path=f'controlset{number:03d}\\services\\{service}'
  dependencies[service]={}
  for name in ('start','type','group','dependonservice','dependongroup','imagepath'):
   value=before.get(path,{}).get(name)
   if value is not None:
    typ,raw=value;dependencies[service][name]={'type':typ,'value':struct.unpack('<I',raw)[0] if typ==4 and len(raw)==4 else raw.decode('utf-16le').rstrip('\0') if typ in (1,2,7) else raw.hex()}

 for service in ('kbdclass','mouclass','usosusb'):
  if before[f'controlset{number:03d}\\services\\{service}'].get('start')!=(4,struct.pack('<I',1)):raise ValueError('Own USB/classes must remain Start1')
 for service in ('kbdclass','mouclass'):
  node=before[f'controlset{number:03d}\\services\\{service}']
  if any(n in node for n in ('dependonservice','dependongroup')):raise ValueError('Class has a dependency requiring separate review')
  params=before[f'controlset{number:03d}\\services\\{service}\\parameters']
  if params.get('connectmultipleports')!=(4,struct.pack('<I',1)):raise ValueError('Expected ConnectMultiplePorts1')
  maximum=params.get('maximumportsserviced')
  dependencies[service]['maximumportsserviced']={'type':maximum[0],'value':struct.unpack('<I',maximum[1])[0]} if maximum and maximum[0]==4 and len(maximum[1])==4 else {'present':False,'original_default':1}
 debug=before[f'controlset{number:03d}\\services\\ndisloop1\\parameters'].get('debugport')
 if debug!=(4,struct.pack('<I',233)):raise ValueError('DebugPort233 must be unchanged')
 return bytes(changed),dict(key=key,value='Start',before=1,after=4,hive_version=hive.check_header(original),hive_value_offset=found[0],hive_only_one_dword_changed=True,services=dependencies)

def main():
 assert str(WORK)==r'G:\USOS-Kolekcja\_vm\r18f-nt351-usb-port-isolation'
 assert BASE.resolve().is_relative_to(COLLECTION/'_vm') and not WORK.exists() and not OUT.exists()
 done=ROOT/'artifacts/coverage/vm/r18e-nt351-stubfix-e9/completed.json'
 if json.loads(done.read_text(encoding='utf-8')).get('stopped') is not True:raise ValueError('R18e writer completion absent')
 if shutil.disk_usage(COLLECTION).free<100*1024**3:raise ValueError('Less than100GiB free')
 WORK.mkdir();raw=WORK/'scratch-stopped.raw';overlay=WORK/'target.qcow2'
 subprocess.run([str(h.QIMG),'convert','-f','qcow2','-O','raw',str(BASE),str(raw)],check=True)
 fs=h.BoundedFat(raw)
 try:
  if fs.fat32 or fs.base!=32256 or fs.bps!=512:raise ValueError('Expected exact NT351 FAT16 layout')
  system,offsets=h.file_data(fs,'WINNT/SYSTEM32/CONFIG/SYSTEM',4*1024**2)
  driver,_=h.file_data(fs,'WINNT/SYSTEM32/DRIVERS/usosnet351.sys',17024)
  usb,_=h.file_data(fs,'WINNT/SYSTEM32/DRIVERS/usosusb.sys',32128)
  if len(driver)!=17024 or hashlib.sha256(driver).hexdigest()!=DRIVER:raise ValueError('Installed own SYS changed')
  if len(usb)!=32128 or hashlib.sha256(usb).hexdigest()!=USB:raise ValueError('Frozen USB changed')
  changed,record=patch_hive(system);cluster_size=fs.csize
 finally:fs.f.close()
 with raw.open('r+b') as stream:
  for index,at in enumerate(offsets):
   data=changed[index*cluster_size:(index+1)*cluster_size];stream.seek(at);stream.write(data)
  stream.flush()
 fs=h.BoundedFat(raw)
 try:
  got,_=h.file_data(fs,'WINNT/SYSTEM32/CONFIG/SYSTEM',4*1024**2)
  d2,_=h.file_data(fs,'WINNT/SYSTEM32/DRIVERS/usosnet351.sys',17024)
  u2,_=h.file_data(fs,'WINNT/SYSTEM32/DRIVERS/usosusb.sys',32128)
  if got!=changed or d2!=driver or u2!=usb:raise ValueError('Strict hive and unchanged own SYS readback failed')
 finally:fs.f.close()
 subprocess.run([str(h.QIMG),'convert','-f','raw','-O','qcow2','-B',str(BASE),'-F','qcow2',str(raw),str(overlay)],check=True)
 subprocess.run([str(h.QIMG),'compare','-f','raw','-F','qcow2',str(raw),str(overlay)],check=True)
 meta=json.loads((BASE.parent/'fixture.json').read_text(encoding='utf-8'))
 meta.update(stopped_parent=str(BASE),i8042prt_start=4,usb_input_isolation=True)
 (WORK/'fixture.json').write_text(json.dumps(meta,indent=2)+'\n',encoding='utf-8')
 record.update(base=str(BASE),overlay=str(overlay),driver_sha256=DRIVER,usb_sha256=USB,
  own_sys_unchanged=True,system_before_sha256=hashlib.sha256(system).hexdigest(),system_after_sha256=hashlib.sha256(changed).hexdigest(),
  raw_overlay_qemu_compare_pass=True,ms_hive_or_driver_exported=False)
 assert raw.resolve().parent==WORK.resolve();raw.unlink();record['scratch_raw_removed']=True
 OUT.write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8');print(json.dumps(record,indent=2),flush=True)
if __name__=='__main__':main()
