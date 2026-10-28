"""Read-only plan for exact stopped owned NT4 USB images; never deletes."""
from pathlib import Path
import hashlib,importlib.util,json,os,stat,subprocess
HERE=Path(__file__).resolve().parent
s=importlib.util.spec_from_file_location('nt4_usb_cleanup_common',HERE/'nt4_combo_fixture.py');h=importlib.util.module_from_spec(s);s.loader.exec_module(h)
COLLECTION=Path(r'G:\USOS-Kolekcja\_vm')
CASES=(
 ('nt4-installed03-usb-combo01','qualified HID+MSC313952',h.BASE),
 ('nt4-installed03-usb-msc04','qualified MSC313952; parent of combo01',h.msc.BASE),
 ('nt4-installed03-usb-msc03','completed host-token timeout, startup read only',h.msc.BASE),
 ('nt4-installed03-usb-msc02','preparation only; never launched',h.msc.BASE),
 ('nt4-installed03-usb-msc01','empty after refused preparation; never launched',None),
 ('nt4-installed03-usb-hid01','qualified separate HID2d455',h.msc.BASE),
)
def main():
 out=h.ROOT/'artifacts/nt4-usb-cleanup-plan.json'
 if out.exists():raise FileExistsError('Preserve prior plan')
 rows=[];total=0
 for name,meaning,parent in CASES:
  directory=COLLECTION/name;h.h.exact(directory)
  if directory.parent!=COLLECTION or not directory.is_dir():raise ValueError('Exact owned case directory required')
  runtime=h.ROOT/'artifacts/coverage/vm'/name
  if name not in ('nt4-installed03-usb-msc01','nt4-installed03-usb-msc02'):
   if h.read(runtime/'completed.json').get('stopped') is not True or h.read(runtime/'result.json').get('qemu_returncode')!=0:raise ValueError('Closed writer0 required before metadata read')
  elif runtime.exists():raise ValueError('Unlaunched preflight unexpectedly has runtime')
  files=[];directories=[];pending=list(sorted(directory.iterdir()));nodes=0
  while pending:
   path=pending.pop(0);nodes+=1
   h.h.exact(path)
   if nodes>128 or len(path.relative_to(directory).parts)>8:raise ValueError('Bounded exact own directory tree required')
   if path.is_dir():
    directories.append(str(path));pending.extend(sorted(path.iterdir()));continue
   if not stat.S_ISREG(path.lstat().st_mode):raise ValueError('Unexpected nonregular child; scope review required')
   with path.open('rb') as f:
    size=os.fstat(f.fileno()).st_size;pin=hashlib.file_digest(f,'sha256').hexdigest()
   item=dict(path=str(path),opened_bytes=size,sha256=pin);total+=size
   if path.suffix.casefold()=='.qcow2':
    env=dict(os.environ,TEMP=str(directory),TMP=str(directory),APPDATA=str(directory),LOCALAPPDATA=str(directory))
    result=subprocess.run([str(h.QIMG),'info','--backing-chain','--output=json',str(path)],check=True,capture_output=True,text=True,env=env)
    chain=json.loads(result.stdout)
    item['backing_chain']=[dict(path=str(Path(n['filename']).resolve()),format=n['format'],virtual_bytes=n['virtual-size'],backing=str(Path(n['full-backing-filename']).resolve()) if n.get('full-backing-filename') else None) for n in chain]
    expected=parent if path.name=='target.qcow2' else None
    actual=chain[0].get('full-backing-filename')
    if (Path(actual).resolve() if actual else None)!=expected:raise ValueError('Unexpected backing parent')
   files.append(item)
  rows.append(dict(directory=str(directory),meaning=meaning,expected_target_parent=str(parent) if parent else None,child_directories=directories,files=files))
 plan=dict(read_only_plan=True,executed_deletions=False,scope='Only exact stopped owned NT4 USB cases; no recursive discovery',
  protected_original03=dict(path=str(h.msc.BASE),sha256=h.msc.BASE_SHA),protected_exclusions=['All macOS images including refused02-04','All NT4 NET cases and shared candidate03','All other collection paths'],
  known_owned_dependency='combo01 target -> msc04 target -> protected original03; all other own targets -> protected original03; USB media have no backing',
  ordering='Archive own proof metadata first; delete owned child combo01 before its parent msc04 if later authorized; original03 excluded. External dependents require root coordination.',
  total_owned_opened_bytes=total,cases_in_child_before_parent_order=rows)
 out.write_text(json.dumps(plan,indent=2)+'\n',encoding='utf-8');print(json.dumps(dict(plan=str(out),owned_bytes=total,cases=[dict(directory=r['directory'],file_count=len(r['files']),opened_bytes=sum(f['opened_bytes'] for f in r['files'])) for r in rows]),indent=2))
if __name__=='__main__':main()
