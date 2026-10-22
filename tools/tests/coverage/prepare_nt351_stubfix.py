"""Replace only the own fixed-size SYS on a new stopped R18d overlay."""
from pathlib import Path
import hashlib,importlib.util,json,shutil,struct,subprocess
ROOT=Path(__file__).resolve().parents[3]
def load(name,path):
 s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
h=load('owned_debug_prepare',Path(__file__).with_name('prepare_nt351_debug.py'))
COLLECTION=h.COLLECTION
BASE=COLLECTION/'_vm/r18d-nt351-debug-e9/target.qcow2'
WORK=COLLECTION/'_vm/r18e-nt351-stubfix-e9'
OLD=h.DRIVER
NEW='f39d58fd923632dacbc577562045015123a9bdfc98c56237090bfcd53c70612a'
BINARY=ROOT/'artifacts/nt351-network/build-04-stubfix/usosnet351.sys'
def main():
 assert str(WORK)==r'G:\USOS-Kolekcja\_vm\r18e-nt351-stubfix-e9' and not WORK.exists()
 done=ROOT/'artifacts/coverage/vm/r18d-nt351-debug-e9/completed.json'
 if json.loads(done.read_text(encoding='utf-8')).get('stopped') is not True:raise ValueError('R18d writer completion absent')
 candidate=BINARY.read_bytes()
 if len(candidate)!=17024 or hashlib.sha256(candidate).hexdigest()!=NEW:raise ValueError('Unexpected exact own candidate')
 if shutil.disk_usage(COLLECTION).free<100*1024**3:raise ValueError('Less than100GiB free')
 WORK.mkdir();raw=WORK/'scratch-stopped.raw';overlay=WORK/'target.qcow2'
 subprocess.run([str(h.QIMG),'convert','-f','qcow2','-O','raw',str(BASE),str(raw)],check=True)
 fs=h.BoundedFat(raw)
 try:
  if fs.fat32 or fs.base!=32256 or fs.bps!=512:raise ValueError('Expected exact NT351 FAT16 layout')
  old,offsets=h.file_data(fs,'WINNT/SYSTEM32/DRIVERS/usosnet351.sys',17024)
  system,_=h.file_data(fs,'WINNT/SYSTEM32/CONFIG/SYSTEM',4*1024**2);cluster_size=fs.csize
  if len(old)!=len(candidate) or hashlib.sha256(old).hexdigest()!=OLD:raise ValueError('Parent own SYS differs')
 finally:fs.f.close()
 values=h.hive.read_hive_content(system);current=struct.unpack('<I',values['select']['current'][1])[0]
 key=f'controlset{current:03d}\\services\\ndisloop1\\parameters'
 if values[key].get('debugport')!=(4,struct.pack('<I',233)):raise ValueError('DebugPort233 must remain intact')
 with raw.open('r+b') as stream:
  for index,at in enumerate(offsets):
   data=candidate[index*cluster_size:(index+1)*cluster_size];stream.seek(at);stream.write(data)
  stream.flush()
 fs=h.BoundedFat(raw)
 try:
  got,_=h.file_data(fs,'WINNT/SYSTEM32/DRIVERS/usosnet351.sys',17024)
  sys_after,_=h.file_data(fs,'WINNT/SYSTEM32/CONFIG/SYSTEM',4*1024**2)
  if got!=candidate or sys_after!=system:raise ValueError('Exact own SYS readback or unchanged SYSTEM failed')
 finally:fs.f.close()
 subprocess.run([str(h.QIMG),'convert','-f','raw','-O','qcow2','-B',str(BASE),'-F','qcow2',str(raw),str(overlay)],check=True)
 subprocess.run([str(h.QIMG),'compare','-f','raw','-F','qcow2',str(raw),str(overlay)],check=True)
 meta=json.loads((BASE.parent/'fixture.json').read_text(encoding='utf-8'));meta.update(stopped_parent=str(BASE),manual_driver_override_sha256=NEW)
 (WORK/'fixture.json').write_text(json.dumps(meta,indent=2)+'\n',encoding='utf-8')
 usb_key=f'controlset{current:03d}\\services\\usosusb\\parameters'
 usb_diag=values.get(usb_key,{}).get('diag')
 def safe_value(v):
  typ,raw=v
  return {'type':typ,'value':struct.unpack('<I',raw)[0] if typ==4 and len(raw)==4 else raw.decode('utf-16le').rstrip('\0') if typ in (1,2,7) else raw.hex()}
 classes={}
 for name in ('kbdclass','mouclass'):
  params=values.get(f'controlset{current:03d}\\services\\{name}\\parameters',{})
  classes[name]={n:safe_value(v) for n,v in params.items() if n.lower()=='connectmultipleports'}
 groups=values.get(f'controlset{current:03d}\\control\\servicegrouporder',{}).get('list')
 record=dict(base=str(BASE),overlay=str(overlay),driver_before_sha256=OLD,driver_after_sha256=NEW,
  only_own_sys_replaced=True,system_hive_unchanged=True,system_sha256=hashlib.sha256(system).hexdigest(),debug_port=233,
  driver_readback_matches=True,raw_overlay_qemu_compare_pass=True,ms_hive_or_driver_exported=False,
  usb_diagnostic_key=usb_key,usb_diagnostic=safe_value(usb_diag) if usb_diag else None,classes=classes,
  service_group_order=safe_value(groups) if groups else None)
 assert raw.resolve().parent==WORK.resolve();raw.unlink();record['scratch_raw_removed']=True
 out=ROOT/'artifacts/nt351-network/r18e-stubfix-preparation.json';assert not out.exists();out.write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8')
 print(json.dumps(record,indent=2),flush=True)
if __name__=='__main__':main()
