"""Read crash settings in live offline XP hives and prior prepared backups."""
from pathlib import Path
import sys,struct,hashlib
sys.path.insert(0,str(Path(__file__).resolve().parent/'cache/registry-reader'))
from Registry import Registry
sys.stdout.reconfigure(errors='backslashreplace')
paths=list(Path('M:/WINDOWS/system32/config').glob('SYSTEM*'))
paths+=list(Path('artifacts/xp-pae').glob('dump-workaround-*/SYSTEM*'))
for p in paths:
 b=p.read_bytes()
 print('\nFILE',p,'size',len(b),'sha256',hashlib.sha256(b).hexdigest(),'magic',b[:4],'sequences',struct.unpack_from('<II',b,4) if len(b)>12 else '')
 if b[:4]!=b'regf':continue
 try:
  r=Registry.Registry(str(p))
  print('Select',{v.name():v.value() for v in r.open('Select').values()})
  if p.parent==Path('M:/WINDOWS/system32/config'):print('Setup',{v.name():v.value() for v in r.open('Setup').values()})
  for key in r.root().subkeys():
   if not key.name().startswith('ControlSet'):continue
   k=key.name()+r'\Control\CrashControl'
   print(k,{v.name():v.value() for v in r.open(k).values()})
 except Exception as e:print(type(e).__name__,str(e))
for name in ('hivesys.inf','hivesft.inf'):
 for base in ('M:/WINDOWS/inf','M:/$WIN_NT$.~LS/I386'):
  p=Path(base)/name
  if p.exists():
   b=p.read_bytes();s=b.decode('utf-16') if b[:2] in (b'\xff\xfe',b'\xfe\xff') else b.decode('cp1250',errors='replace')
   for i,line in enumerate(s.splitlines(),1):
    if 'CrashDumpEnabled' in line:print(p,i,line)
for p in (Path('M:/boot.ini'),Path('M:/WINDOWS/setupact.log'),Path('M:/WINDOWS/setupapi.log')):
 if p.exists():
  b=p.read_bytes();s=b.decode('utf-16') if b[:2] in (b'\xff\xfe',b'\xfe\xff') else b.decode('cp1250',errors='replace')
  print('\nTEXT',p,s[-6500:])
