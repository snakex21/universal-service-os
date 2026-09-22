"""Adapt the Intel's previously working system BCD to Vista, on a local copy.

Preserves System/TreatAsSystem flags. Uses only object classes also present in
the original Vista template; removes the Win7 recovery and experimental entries.
"""
from pathlib import Path
import subprocess,sys,shutil,json
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'tools/cache/registry-reader'))
from Registry import Registry
sys.stdout.reconfigure(errors='backslashreplace')
out=ROOT/'zig-out/vista/bcd-complete-v5';out.mkdir(exist_ok=False)
store=out/'BCD';shutil.copyfile(ROOT/'zig-out/vista/deploy-20260920-200612/intel-before-vista/EFI/Microsoft/Boot/BCD',store)
loader='{53bc7825-b510-11f1-9dfe-b47cf444e757}';resume='{53bc7824-b510-11f1-9dfe-b47cf444e757}'
keep={loader,resume,'{9dea862c-5cdd-4e70-acc1-f32b344d4795}','{b2721d73-1db4-4c62-bf78-c548a880142d}','{0ce4991b-e6b3-4b16-b23c-5e0d9250e5d9}','{4636856e-540f-4170-a130-a84776f4c654}','{5189b25c-5558-4bf2-bca4-289b11bd29e2}','{7ea2e1ac-2e61-4728-aaa3-896d9d0a9f0e}','{6efb52bf-1766-41db-a6b3-0ee5eff72bd7}','{1afa9c49-16ab-4a5c-901b-212802da9460}'}
def bcd(*args):
 r=subprocess.run(['bcdedit.exe','/store',str(store),*args],capture_output=True)
 with (out/'operations.log').open('ab') as f:f.write((' '.join(args)+'\n').encode());f.write(r.stdout+r.stderr)
 if r.returncode:raise RuntimeError((args,r.returncode,r.stdout.decode(errors='replace')))
 return r.stdout
reg=Registry.Registry(str(store))
for obj in reg.open('Objects').subkeys():
 if obj.name() not in keep:
  current={o.name() for o in Registry.Registry(str(store)).open('Objects').subkeys()}
  if obj.name() in current:bcd('/delete',obj.name(),'/cleanup','/f')
 else:
  for element in obj.subkey('Elements').subkeys():
   if element.name().startswith('4'):bcd('/deletevalue',obj.name(),'custom:'+element.name())
for k,v in {'device':'partition=M:','osdevice':'partition=M:','path':'\\Windows\\system32\\winload.efi','systemroot':'\\Windows','description':'Windows Vista Ultimate SP2','locale':'pl-PL','bootlog':'Yes','sos':'No','nocrashautoreboot':'Yes'}.items():bcd('/set',loader,k,v)
for k,v in {'device':'partition=M:','path':'\\Windows\\system32\\winresume.efi','locale':'pl-PL'}.items():bcd('/set',resume,k,v)
for k,v in {'default':loader,'displayorder':loader,'timeout':'0','locale':'pl-PL','toolsdisplayorder':'{memdiag}'}.items():bcd('/set','{bootmgr}',k,v)
bcd('/set','{memdiag}','path','\\EFI\\Microsoft\\Boot\\memtest.efi')
(out/'enum-before-esp.txt').write_bytes(bcd('/enum','all','/v'))
check=Registry.Registry(str(store))
assert check.open('Description').value('System').value()==1
# BCDEdit clears TreatAsSystem when editing an offline copy. System=1 is kept;
# TreatAsSystem is set by the system-store load on the target OS.
assert {o.name() for o in check.open('Objects').subkeys()}==keep
print('FULL_VISTA_BCD_PREPARED',len(keep),'objects; ESP device pending guarded deployment')
