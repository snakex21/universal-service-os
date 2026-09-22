from pathlib import Path
import sys
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'tools/cache/registry-reader'))
from Registry import Registry
for name,keys in [('SYSTEM',['Setup','Select','ControlSet001\\Services\\TrustedInstaller','ControlSet001\\Control\\Session Manager']),('SOFTWARE',['Microsoft\\Windows\\CurrentVersion\\Component Based Servicing','Microsoft\\Windows\\CurrentVersion\\Component Based Servicing\\Packages\\Package_for_KB2864202~31bf3856ad364e35~amd64~~6.0.1.11']),('COMPONENTS',[''])]:
 reg=Registry.Registry('M:/Windows/System32/config/'+name)
 for key in keys:
  print(name,key)
  try:
   k=reg.open(key) if key else reg.root()
   for v in k.values():
    if key.endswith('Session Manager') and v.name() not in ['BootExecute','SetupExecute','PendingFileRenameOperations']:continue
    print(v.name(),repr(v.value())[:700])
   if 'Component Based Servicing' in key:
    print('Subkeys',[x.name() for x in k.subkeys()][:30])
  except Exception as e: print(type(e).__name__)
packages=Registry.Registry('M:/Windows/System32/config/SOFTWARE').open('Microsoft\\Windows\\CurrentVersion\\Component Based Servicing\\Packages')
print('KMDF packages',[k.name() for k in packages.subkeys() if '2864202' in k.name()])
for p in [Path('M:/Windows/winsxs/pending.xml'),Path('M:/USOS/Vista/kmdf-before-setup.log'),Path('M:/USOS/usb-bootstrap.log')]:
 b=p.read_bytes();print(p,'bytes',len(b),'zeros',b.count(b'\0'))
 if p.suffix=='.xml':print(b[:300]);print('KB2864202 occurrence',b.find(b'2864202'))
 else:print(repr(b))
