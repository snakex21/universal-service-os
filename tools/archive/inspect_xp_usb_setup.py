"""Read only the latest XP snapshot and installed USB file versions/hashes."""
from pathlib import Path
import sys,hashlib
root=Path(__file__).resolve().parents[1];sys.path.insert(0,str(root/'tools/cache/registry-reader'))
sys.stdout.reconfigure(errors='backslashreplace')
from Registry import Registry
snap=sorted((root/'artifacts/xp-pae').glob('lsass-*'))[-1]
r=Registry.Registry(str(snap/'WINDOWS/System32/config/SYSTEM'))
cs='ControlSet%03d'%r.open('Select').value('Current').value()
print('SNAPSHOT',snap.name,'CONTROLSET',cs)
def vals(k):return {v.name():v.value() for v in k.values()}
for name in ('USBXHCI','USBHUB3','Ucx01000','Wdf01000','hidusb','mouhid','kbdhid','mouclass','kbdclass'):
 try:print('SERVICE',name,vals(r.open(cs+'\\Services\\'+name)))
 except Registry.RegistryKeyNotFoundException:print('SERVICE ABSENT',name)
for bus in ('PCI','USB','HID'):
 try:k=r.open(cs+'\\Enum\\'+bus)
 except Registry.RegistryKeyNotFoundException:continue
 for dev in k.subkeys():
  for instance in dev.subkeys():
   values=vals(instance)
   if bus!='PCI' or any(s in str(values).lower() for s in ('cc_0c03','usbxhci','usb controller')):
    print('DEVICE',bus,dev.name(),instance.name(),{n:values[n] for n in ('HardwareID','CompatibleIDs','Service','ClassGUID','Driver','Problem','ConfigFlags','DeviceDesc') if n in values})
    for sub in ('Control','LogConf'):
     try:print(sub,{n:v for n,v in vals(instance.subkey(sub)).items() if not isinstance(v,bytes)})
     except Registry.RegistryKeyNotFoundException:pass
for name in ('usbxhci.sys','usbhub3.sys','ucx01000.sys','wdf01000.sys','wdfldr.sys','ntoskrn8.sys','ksecd8.sys','usbd8.sys','wpprecor.sys','usbccgp.sys','usbport.sys','usbd.sys','hidusb.sys','hidclass.sys','hidparse.sys','mouhid.sys','kbdhid.sys','mouclass.sys','kbdclass.sys'):
 p=Path('M:/WINDOWS/system32/drivers')/name
 print('FILE',name,p.stat().st_size if p.exists() else 'MISSING',hashlib.sha256(p.read_bytes()).hexdigest() if p.exists() else '')
for name in ('setupapi.log','setuperr.log'):
 print('LOG',name,(snap/'WINDOWS'/name).read_bytes().decode('cp1250',errors='replace')[-6500:])
