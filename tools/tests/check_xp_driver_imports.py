"""Resolve driver import names against the actual SP3 source and payload."""
from pathlib import Path
import struct,sys,subprocess,json,argparse
r=Path(__file__).resolve().parents[2];sys.path.insert(0,str(r/'tools'))
from xp_driver_overlay import SELECTED,BUILTIN_USB,DRIVERS
def pe(path):
 b=path.read_bytes();u=lambda o:struct.unpack_from('<I',b,o)[0]
 p=u(60);opt=p+24;sections=opt+struct.unpack_from('<H',b,p+20)[0]
 def off(v):
  for i in range(struct.unpack_from('<H',b,p+6)[0]):
   vs,va,rs,raw=struct.unpack_from('<IIII',b,sections+i*40+8)
   if va<=v<va+max(vs,rs):return raw+v-va
  raise ValueError((path,v))
 def string(v):
  n=off(v);return b[n:b.index(b'\0',n)].decode('ascii')
 exports=set();imports=[]
 if u(opt+96):
  e=off(u(opt+96));names=off(u(e+32))
  exports={string(u(names+i*4)) for i in range(u(e+24))}
 if u(opt+104):
  i=off(u(opt+104))
  while u(i) or u(i+12):
   mod=string(u(i+12)).lower();t=off(u(i) or u(i+16))
   while u(t):
    assert not u(t)&0x80000000,'ordinal imports require review'
    imports.append((mod,string(u(t)+2)));t+=4
   i+=20
 return exports,imports
base=r/'zig-out/xp-uefi-csm'
parser=argparse.ArgumentParser();parser.add_argument('--source-iso',type=Path);args=parser.parse_args()
iso=args.source_iso or next(Path('L:/Systems/Windows/Windows XP/Images').glob('*NiKKA.iso'))
source=base/'drivers'/json.loads((base/'manifest.json').read_text())['added_source']['sha256'] if args.source_iso else None
out=(source/'import-checks') if source else (base/'driver-checks');out.mkdir(exist_ok=True)
subprocess.run(['C:/Program Files/7-Zip/7z.exe','e',str(iso),r'I386\WMILIB.SY_','-o'+str(out),'-y'],check=True,stdout=subprocess.DEVNULL)
subprocess.run(['C:/Program Files/7-Zip/7z.exe','e',str(out/'WMILIB.SY_'),'-o'+str(out),'-y'],check=True,stdout=subprocess.DEVNULL)
paths={Path(n).name.lower():DRIVERS/n for n in SELECTED if n.endswith('.sys')}
if source:
 paths.update({n:source/'native-usb'/n for n in BUILTIN_USB if (source/'native-usb'/n).is_file()})
paths.update({'ntoskrnl.exe':(source/'sp3-files/ntkrpamp.exe') if source else base/'checks/0/ntkrpamp.exe','hal.dll':(source/'sp3-files/halmacpi.dll') if source else base/'checks/0/halmacpi.dll','wmilib.sys':out/'wmilib.sys'})
tables={name:pe(p) for name,p in paths.items()}
missing=[]
for name in [Path(n).name.lower() for n in SELECTED if n.endswith('.sys')]+[n for n in BUILTIN_USB if n in paths]:
 for mod,fn in tables[name][1]:
  if mod not in tables or fn not in tables[mod][0]:missing.append((name,mod,fn))
(out/'imports.json').write_text(json.dumps({'unresolved':missing,'modules':list(paths)},indent=2))
assert not missing,missing
print('PASS: every named driver import resolves against bundled modules and real XP SP3 kernel/HAL/WMILIB exports')
