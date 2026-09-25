from pathlib import Path
import sys,io,hashlib,json
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'tools/cache/registry-reader'))
from Registry import Registry
snap=sorted((root/'artifacts/xp-pae').glob('lsass-*'))[-1]
def text(p):
 b=p.read_bytes();return b.decode('utf-16' if b.startswith(b'\xff\xfe') else 'cp1250',errors='replace')
print('SNAPSHOT',snap)
for p in [Path('M:/boot.ini'),*sorted(Path('M:/USOS').glob('*.log'))]:
 print('FILE',p,'\n',text(p)[-14000:])
for hive,paths in [('SYSTEM',['Setup','Select',r'ControlSet001\Control\Session Manager\Memory Management']),('SOFTWARE',[r'Microsoft\Windows\CurrentVersion\Setup'])]:
 p=snap/'WINDOWS/System32/config'/hive;reg=Registry.Registry(io.BytesIO(p.read_bytes()))
 for key in paths:
  print('KEY',hive,key)
  for v in reg.open(key).values():
   if v.name().lower() in ('cmdline','systemsetupinprogress','setuptype','restartsetup','current','default','lastknowngood','failed','pagingfiles','physicaladdressextension','loglevel'): print(v.name(),repr(v.value()))
for name in ['setupact.log','setupapi.log','setuperr.log']:
 p=snap/'WINDOWS'/name;previous=root/'artifacts/xp-pae/lsass-20260922-010952/WINDOWS'/name
 print('LOG',name,'size',p.stat().st_size,'same_as_previous',p.read_bytes()==previous.read_bytes());print(text(p)[-6000:])
for p in [Path('M:/USOS/x.exe'),Path('M:/USOS/XP/pae-install.log'),Path('M:/WINDOWS/system32/usospae.exe'),Path('M:/WINDOWS/system32/usoshal.dll')]:
 print('FILE_CHECK',str(p),p.exists(),hashlib.sha256(p.read_bytes()).hexdigest() if p.exists() else '')
deployed=root/'artifacts/xp-pae/setup-trace-v3/SYSTEM'
print('SYSTEM_identical_to_deployment',deployed.read_bytes()==(snap/'WINDOWS/System32/config/SYSTEM').read_bytes())
