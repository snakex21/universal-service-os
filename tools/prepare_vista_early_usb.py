"""Prepare an early USB startup hook and retry the failed specialize phase."""
from pathlib import Path
import hashlib,io,json,struct,sys,uuid
from repair_vista_drive_mapping import inventory,ROOT
from Registry import Registry
source=Path(sys.argv[1]);out=Path(sys.argv[2]);out.mkdir(exist_ok=False)
original=source.read_bytes();data=bytearray(original);seq=struct.unpack_from('<II',data,4);assert seq[0]==seq[1]
h=Registry.Registry(io.BytesIO(original));expected=inventory(h);edits=[]
assert h.open('MountedDevices').value('\\DosDevices\\D:').value()==b'DMIO:ID:'+uuid.UUID('73dbde99-8026-4759-a19a-fd943e891d09').bytes_le
assert h.open('Setup').value('SetupPhase').value()==4
assert h.open('Setup').value('SystemSetupInProgress').value()==1
def dword(key,name,old,new):
 v=h.open(key).value(name);vk=v._vkrecord;assert v.value_type()==4 and v.value()==old and vk.raw_data_length()==0x80000004
 struct.pack_into('<I',data,vk.absolute_offset(8),new);expected['\\'+key][name]=(4,struct.pack('<I',new));edits.append([key,name,old,new])
for key,name in [('Setup\\Status\\ChildCompletion','setup.exe'),('Setup','SetupShutdownRequired')]:
 old=h.open(key).value(name).value();assert old in (0,1)
 if old:dword(key,name,old,0)
# CmdLine alone is insufficient: Winlogon also uses SetupType to select setup.
old_type=h.open('Setup').value('SetupType').value();assert old_type in (0,2)
if old_type!=2:dword('Setup','SetupType',old_type,2)
v=h.open('Setup').value('CmdLine');assert v.value() in ('oobe\\windeploy.exe','D:\\USOS\\usb.exe') and v.value_type()==1
raw=v.raw_data();replacement='D:\\USOS\\usb.exe\0'.encode('utf-16le');assert len(replacement)<=len(raw)
vk=v._vkrecord;offset=vk.data_offset()+4;assert data[offset:offset+len(raw)]==raw
data[offset:offset+len(raw)]=replacement.ljust(len(raw),b'\0');struct.pack_into('<I',data,vk.absolute_offset(4),len(replacement))
expected['\\Setup']['CmdLine']=(1,replacement);edits.append(['Setup','CmdLine',v.value(),'D:\\USOS\\usb.exe'])
struct.pack_into('<II',data,4,seq[0]+1,seq[0]+1)
checksum=0
for word in struct.unpack_from('<127I',data):checksum^=word
if checksum==0:checksum=1
elif checksum==0xffffffff:checksum=0xfffffffe
struct.pack_into('<I',data,0x1fc,checksum)
assert inventory(Registry.Registry(io.BytesIO(data)))==expected
(out/'SYSTEM.original').write_bytes(original);(out/'SYSTEM').write_bytes(data)
(out/'repair.json').write_text(json.dumps({'SYSTEM':{'original_sha256':hashlib.sha256(original).hexdigest(),'patched_sha256':hashlib.sha256(data).hexdigest(),'edits':edits,'full_inventory_checked':True}},indent=2),encoding='utf-8')
print('EARLY_USB_HOOK_PREPARED; SETUPTYPE=2; CHANGED_VALUES='+str(len(edits))+'; ALL_VALUES_VERIFIED')
