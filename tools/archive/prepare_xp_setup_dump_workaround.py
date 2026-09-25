"""Keep the dump diagnostic setting consistent with XP Setup's saved hive."""
from pathlib import Path
import datetime,hashlib,io,json,struct
from repair_vista_drive_mapping import inventory
from Registry import Registry

root=Path(__file__).resolve().parents[1]
out=root/'artifacts/xp-pae'/('setup-dump-workaround-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
out.mkdir()
changes=[]
for name in ('SYSTEM','SYSTEM.SAV'):
 target=Path('M:/WINDOWS/system32/config')/name
 original=target.read_bytes();data=bytearray(original)
 assert original[:4]==b'regf'
 seq1,seq2=struct.unpack_from('<II',original,4)
 assert seq1==seq2,'Dirty hive'
 reg=Registry.Registry(io.BytesIO(original));expected=inventory(reg)
 assert reg.open('Setup').value('CmdLine').value()=='setup -newsetup'
 key='ControlSet001\\Control\\CrashControl'
 assert reg.open('Select').value('Default').value()==1
 assert reg.open(key).value('AutoReboot').value()==0
 v=reg.open(key).value('CrashDumpEnabled');assert v.value_type()==4 and v.value() in (0,3)
 vk=v._vkrecord;assert vk.raw_data_length() in (4,0x80000004)
 offset=vk.data_offset();assert original[offset:offset+4]==struct.pack('<I',v.value())
 struct.pack_into('<I',data,offset,0)
 expected['\\'+key]['CrashDumpEnabled']=(4,struct.pack('<I',0))
 struct.pack_into('<II',data,4,seq1+1,seq1+1)
 checksum=0
 for word in struct.unpack_from('<127I',data):checksum^=word
 if checksum==0:checksum=1
 elif checksum==0xffffffff:checksum=0xfffffffe
 struct.pack_into('<I',data,0x1fc,checksum)
 assert inventory(Registry.Registry(io.BytesIO(data)))==expected,'Unexpected registry edits'
 assert len(data)==len(original)
 (out/(name+'.original')).write_bytes(original);(out/name).write_bytes(data)
 changes.append({'target':str(target),'file':name,'before':hashlib.sha256(original).hexdigest(),'after':hashlib.sha256(data).hexdigest()})
target=Path('M:/$WIN_NT$.~LS/I386/hivesys.inf')
original=target.read_bytes()
encoding='utf-16le' if original[:2]==b'\xff\xfe' else 'ascii'
line='HKLM,"SYSTEM\\CurrentControlSet\\Control\\CrashControl","CrashDumpEnabled",0x00010003,3'
old=line.encode(encoding)
assert original.count(old)==1,'Unexpected INF declaration'
data=original.replace(old,(line[:-1]+'0').encode(encoding))
assert len(data)==len(original) and sum(a!=b for a,b in zip(original,data))==1
(out/'hivesys.inf.original').write_bytes(original);(out/'hivesys.inf').write_bytes(data)
changes.append({'target':str(target),'file':'hivesys.inf','before':hashlib.sha256(original).hexdigest(),'after':hashlib.sha256(data).hexdigest()})
(out/'changes.json').write_text(json.dumps(changes,indent=2))
print('PREPARED='+str(out))
print('PASS: SYSTEM and SYSTEM.SAV all values compared; only CrashDumpEnabled=0; INF single-byte edit; target untouched')
