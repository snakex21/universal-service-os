"""Prepare a bounded Setup CmdLine diagnostic in private XP hive copies."""
from pathlib import Path
import datetime,hashlib,io,json,struct
from repair_vista_drive_mapping import inventory
from Registry import Registry

root=Path(__file__).resolve().parents[1]
out=root/'artifacts/xp-pae'/('setup-cmd-diag-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
out.mkdir()
prior=root/'artifacts/xp-pae/setup-diag-20260922-193538'
changes=[]
for name in ('system','system.sav','SYSTEM.LOG'):
 original=(Path('M:/WINDOWS/system32/config')/name).read_bytes()
 assert (prior/name).read_bytes()==original,'Worker backup differs from current '+name
 (out/(name+'.original')).write_bytes(original)
 print('WORKER_BACKUP_OK',name,hashlib.sha256(original).hexdigest())
 if name=='SYSTEM.LOG':continue
 data=bytearray(original)
 assert original[:4]==b'regf'
 seq1,seq2=struct.unpack_from('<II',original,4);assert seq1==seq2,'Dirty hive'
 reg=Registry.Registry(io.BytesIO(original));expected=inventory(reg)
 v=reg.open('Setup').value('CmdLine')
 assert v.value_type()==1 and v.value()=='setup -newsetup'
 old=('setup -newsetup\0').encode('utf-16le')
 new=('cmd /c C:\\d.cmd\0').encode('utf-16le')
 assert len(old)==len(new)==32 and v.raw_data()==old
 vk=v._vkrecord;assert vk.raw_data_length()==len(old)
 offset=vk.data_offset()+4
 assert original[offset:offset+len(old)]==old
 data[offset:offset+len(old)]=new
 expected['\\Setup']['CmdLine']=(1,new)
 struct.pack_into('<II',data,4,seq1+1,seq1+1)
 checksum=0
 for word in struct.unpack_from('<127I',data):checksum^=word
 if checksum==0:checksum=1
 elif checksum==0xffffffff:checksum=0xfffffffe
 struct.pack_into('<I',data,0x1fc,checksum)
 assert len(data)==len(original)
 assert inventory(Registry.Registry(io.BytesIO(data)))==expected,'Unexpected registry change'
 (out/name).write_bytes(data)
 changes.append({'target':str(Path('M:/WINDOWS/system32/config')/name),'file':name,'before':hashlib.sha256(original).hexdigest(),'after':hashlib.sha256(data).hexdigest()})
script=r'''@echo off
setlocal
set "L=C:\usos-diag.txt"
echo === USOS setup diagnostic v1 start %DATE% %TIME% >> "%L%"
set >> "%L%"
dir C:\WINDOWS\system32\setup.exe C:\WINDOWS\system32\syssetup.dll >> "%L%" 2>&1
echo --- running setup -newsetup at %TIME% >> "%L%"
start "" /wait C:\WINDOWS\system32\setup.exe -newsetup
set "SETUP_RC=%ERRORLEVEL%"
echo --- setup exit code=%SETUP_RC% at %TIME% >> "%L%"
dir C:\WINDOWS\setup\*.log C:\WINDOWS\setupact.log C:\WINDOWS\setuperr.log C:\WINDOWS\setuplog.txt >> "%L%" 2>&1
echo === end %TIME% >> "%L%"
exit /b %SETUP_RC%
'''.replace('\n','\r\n').encode('ascii')
p=Path('M:/d.cmd');before=None
if p.exists():
 b=p.read_bytes();(out/'d.cmd.original').write_bytes(b);before=hashlib.sha256(b).hexdigest()
(out/'d.cmd').write_bytes(script)
changes.append({'target':str(p),'file':'d.cmd','before':before,'after':hashlib.sha256(script).hexdigest()})
(out/'changes.json').write_text(json.dumps(changes,indent=2))
print('PASS: both complete hive inventories compared; CmdLine only changed (plus header sequence/checksum); script prepared; Intel untouched')
print('PREPARED='+str(out))
