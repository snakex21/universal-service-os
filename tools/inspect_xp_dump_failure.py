"""Read-only analysis of the photographed ntoskrn8 fault at RVA 0x2143."""
from pathlib import Path
import struct, subprocess, sys, hashlib
root=Path(__file__).resolve().parents[1];sys.path.insert(0,str(root/'tools/cache/registry-reader'))
from Registry import Registry
sys.stdout.reconfigure(errors='backslashreplace')
snap=sorted((root/'artifacts/xp-pae').glob('lsass-*'))[-1]
r=Registry.Registry(str(snap/'WINDOWS/System32/config/SYSTEM'))
cs='ControlSet%03d'%r.open('Select').value('Current').value()
for key in (cs+r'\Control\CrashControl',cs+r'\Control\Session Manager\Memory Management',r'Setup'):
 print('REGISTRY',key,{v.name():v.value() for v in r.open(key).values()})
for pattern in ('MEMORY.DMP','Minidump/*.dmp'):
 print('DUMPFILES',[(str(p),p.stat().st_size) for p in Path('M:/WINDOWS').glob(pattern)])
with Path('M:/PAGEFILE.SYS').open('rb') as f:print('PAGEFILE_HEADER',f.read(64).hex())
for name in ('setupapi.log','setupact.log','setuperr.log'):
 p=snap/'WINDOWS'/name
 old=root/'artifacts/xp-pae/lsass-20260922-171225/WINDOWS'/name
 print('LOG_CHANGED',name,p.read_bytes()!=old.read_bytes())
p=Path('M:/WINDOWS/system32/drivers/ntoskrn8.sys');b=p.read_bytes()
h=struct.unpack_from('<I',b,60)[0];base=struct.unpack_from('<I',b,h+24+28)[0]
print('BINARY',hashlib.sha256(b).hexdigest(),'TIMESTAMP',hex(struct.unpack_from('<I',b,h+8)[0]),'IMAGEBASE',hex(base))
result=subprocess.run(['C:/msys64/mingw64/bin/objdump.exe','-d','--start-address='+hex(base+0x2100),'--stop-address='+hex(base+0x2190),str(p)],check=True,capture_output=True,text=True)
print(result.stdout)
(snap/'dump-fault-disassembly.txt').write_text(result.stdout)
