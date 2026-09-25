"""Verify downloaded x86 candidates and stage locally, without activating drivers."""
from pathlib import Path
import hashlib,json,shutil,struct
root=Path(__file__).resolve().parents[1]
source=root/'tools/vendor/xp-modern/2026-09-21'
dest=root/'media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x86'
manifest=json.loads((source/'download-manifest.json').read_text())
for entry in manifest:
 p=source/entry['file']
 assert hashlib.sha256(p.read_bytes()).hexdigest()==entry['sha256'],p
patches=next(source.glob('integrator/*/Patch Integrator */Patches'))
groups={
 'USB3':'Microsoft USB3.x xHCI driver v2.2',
 'SATA':'Microsoft SATA driver v6.3.0.1',
 'KMDF':'Kernel-Mode Driver Framework 1.11',
 'Dependencies':'Miscellaneous',
 'ACPI':'ACPI drivers',
}
files=[]
for group,folder in groups.items():
 for p in (patches/folder).rglob('*'):
  if not p.is_file():continue
  rel=Path(group)/p.relative_to(patches/folder)
  data=p.read_bytes()
  record=dict(file=rel.as_posix(),sha256=hashlib.sha256(data).hexdigest(),size=len(data),source=p.relative_to(source).as_posix())
  if p.suffix.lower()=='.sys':
   assert data[:2]==b'MZ',p
   pe=struct.unpack_from('<I',data,60)[0]
   assert data[pe:pe+4]==b'PE\0\0',p
   machine,nsections=struct.unpack_from('<HH',data,pe+4)
   assert machine==0x14c,p
   optional=pe+24
   assert struct.unpack_from('<H',data,optional)[0]==0x10b,p
   sections=optional+struct.unpack_from('<H',data,pe+20)[0]
   def offset(rva):
    for n in range(nsections):
     vs,va,rs,raw=struct.unpack_from('<IIII',data,sections+n*40+8)
     if va<=rva<va+max(vs,rs): return raw+rva-va
    raise ValueError(f'Unmapped RVA {rva:x}')
   imports=[]
   rva=struct.unpack_from('<I',data,optional+104)[0]
   if rva:
    pos=offset(rva)
    while any(data[pos:pos+20]):
     name=offset(struct.unpack_from('<I',data,pos+12)[0])
     imports.append(data[name:data.index(b'\0',name)].decode('ascii').lower());pos+=20
   record.update(machine='i386',imports=imports)
  target=dest/rel
  target.parent.mkdir(parents=True,exist_ok=True)
  if target.exists() and target.read_bytes()!=data:raise RuntimeError(f'Refusing to overwrite different candidate: {target}')
  target.write_bytes(data)
  files.append(record)
names={Path(f['file']).name.lower() for f in files}
missing={imp for f in files for imp in f.get('imports',[]) if imp not in names and imp not in ('ntoskrnl.exe','hal.dll','scsiport.sys','wmilib.sys','bootvid.dll')}
assert not missing,missing
required=['usbxhci.sys','usbhub3.sys','ucx01000.sys','wpprecor.sys','usbd8.sys','ksecd8.sys','wdf01000.sys','wdfldr.sys','ntoskrn8.sys','storport.sys','genahci.sys','acpi.sys']
assert all(n in names for n in required)
assert 'PCI\\CC_0C0330' in (dest/'USB3/usbxhci.inf').read_text(encoding='cp1252')
assert 'PCI\\CC_010601' in (dest/'SATA/genahci.inf').read_text(encoding='cp1252')
report=dict(status='downloaded-and-staged-only',target='XP x86; SP3 candidate; SP2 and PAE hardware compatibility unverified',activation='Not yet consumed by experimental XP builder',files=files)
(dest/'manifest.json').write_text(json.dumps(report,indent=2),encoding='utf8')
print('DOWNLOAD_HASHES=PASS; SYS_ARCHITECTURE_I386=PASS; NON_OS_IMPORT_FILES_PRESENT=PASS; USB_AND_AHCI_CLASS_MATCH=PASS')
print('FILES',len(files),'SYS',sum('machine' in f for f in files),'BYTES',sum(f['size'] for f in files))
for f in files:
 if 'machine' in f: print(f['file'],','.join(f['imports']))
