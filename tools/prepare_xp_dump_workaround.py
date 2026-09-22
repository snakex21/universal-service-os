"""Prepare one reversible offline diagnostic change, without loading host hives."""
from pathlib import Path
import hashlib, io, json, struct, datetime
from repair_vista_drive_mapping import inventory
from Registry import Registry

root=Path(__file__).resolve().parents[1]
source=Path('M:/WINDOWS/system32/config/SYSTEM')
original=source.read_bytes()
assert original[:4]==b'regf'
seq1,seq2=struct.unpack_from('<II',original,4)
assert seq1==seq2,'Dirty hive; stop for transaction recovery'
reg=Registry.Registry(io.BytesIO(original))
assert reg.open('Setup').value('CmdLine').value()=='setup -newsetup'
current=reg.open('Select').value('Current').value()
assert current==reg.open('Select').value('Default').value()
key='ControlSet%03d\\Control\\CrashControl'%current
assert reg.open(key).value('AutoReboot').value()==0
v=reg.open(key).value('CrashDumpEnabled')
assert v.value_type()==4 and v.value()==3
vk=v._vkrecord
assert vk.raw_data_length() in (4,0x80000004)
offset=vk.data_offset()
assert original[offset:offset+4]==struct.pack('<I',3)
data=bytearray(original)
struct.pack_into('<I',data,offset,0)
struct.pack_into('<II',data,4,seq1+1,seq1+1)
checksum=0
for word in struct.unpack_from('<127I',data): checksum^=word
if checksum==0: checksum=1
elif checksum==0xffffffff: checksum=0xfffffffe
struct.pack_into('<I',data,0x1fc,checksum)
expected=inventory(reg)
expected['\\'+key]['CrashDumpEnabled']=(4,struct.pack('<I',0))
assert inventory(Registry.Registry(io.BytesIO(data)))==expected
assert len(data)==len(original)
out=root/'artifacts/xp-pae'/('dump-workaround-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
out.mkdir()
(out/'SYSTEM.original').write_bytes(original)
(out/'SYSTEM').write_bytes(data)
(out/'repair.json').write_text(json.dumps({'original_sha256':hashlib.sha256(original).hexdigest(),'patched_sha256':hashlib.sha256(data).hexdigest(),'key':key,'value':'CrashDumpEnabled','old':3,'new':0,'all_registry_values_verified':True},indent=2))
print('PREPARED='+str(out))
print('PASS: all registry values compared; only CrashDumpEnabled 3 -> 0; AutoReboot remains 0; Intel unchanged')
