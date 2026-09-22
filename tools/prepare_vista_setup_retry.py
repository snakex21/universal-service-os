"""Reset only the interrupted Vista setup child to its original pre-run state.
Unlike the commonly suggested value 3, value 0 does not claim setup completed.
Creates output copies; never writes directly to the target volume.
"""
from pathlib import Path
import hashlib, io, json, struct, sys, uuid
from repair_vista_drive_mapping import inventory, ROOT
from Registry import Registry

source=Path(sys.argv[1]); output=Path(sys.argv[2])
output.mkdir(parents=True,exist_ok=False)
original=source.read_bytes()
seq=struct.unpack_from('<II',original,4)
assert seq[0]==seq[1]
h=Registry.Registry(io.BytesIO(original))
assert h.open('MountedDevices').value('\\DosDevices\\D:').value()==b'DMIO:ID:'+uuid.UUID('73dbde99-8026-4759-a19a-fd943e891d09').bytes_le
assert h.open('Setup').value('WorkingDirectory').value()=='D:\\Windows\\Panther'
assert h.open('Setup').value('SetupPhase').value()==4
assert h.open('Setup').value('CmdLine').value()=='oobe\\windeploy.exe'
assert h.open('Setup\\Status\\UnattendPasses').value('specialize').value()==0
key='Setup\\Status\\ChildCompletion';name='setup.exe'
value=h.open(key).value(name)
stock=Registry.Registry(str(ROOT/'zig-out/vista/image/Windows/System32/config/SYSTEM'))
assert stock.open(key).value(name).value()==0
assert value.value_type()==4 and value.value()==1
record=value._vkrecord
assert record.raw_data_length()==0x80000004
offset=record.absolute_offset(8)
data=bytearray(original)
assert data[offset:offset+4]==struct.pack('<I',1)
struct.pack_into('<I',data,offset,0)
struct.pack_into('<II',data,4,seq[0]+1,seq[0]+1)
checksum=0
for x in struct.unpack_from('<127I',data):checksum^=x
if checksum==0:checksum=1
elif checksum==0xffffffff:checksum=0xfffffffe
struct.pack_into('<I',data,0x1fc,checksum)
expected=inventory(h)
expected['\\'+key][name]=(4,struct.pack('<I',0))
assert inventory(Registry.Registry(io.BytesIO(data)))==expected
(output/'SYSTEM.original').write_bytes(original)
(output/'SYSTEM').write_bytes(data)
(output/'repair.json').write_text(json.dumps({'SYSTEM':{'original_sha256':hashlib.sha256(original).hexdigest(),'patched_sha256':hashlib.sha256(data).hexdigest(),'edit':{'key':key,'value':name,'old':1,'new':0},'all_registry_values_verified':True}},indent=2),encoding='utf-8')
print('SETUP_RETRY_PREPARED; CHILD_COMPLETION=0; ALL_OTHER_VALUES_UNCHANGED')
