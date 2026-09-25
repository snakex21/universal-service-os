"""Inspect XP source markers without changing ISO or installation media."""
from pathlib import Path
import subprocess, sys
sys.stdout.reconfigure(errors='backslashreplace')
root=Path(__file__).resolve().parents[1]
sources=Path('L:/Systems/Windows/Windows XP/Images')
for p in sources.glob('*.iso'):
 print('ISO',p.name,'bytes',p.stat().st_size)
 if not any(s in p.name.lower() for s in ('sp2','service_pack_2')):continue
 out=root/'artifacts/xp-pae/sp2-source-inspection'/p.stem
 out.mkdir(parents=True,exist_ok=True)
 subprocess.run(['C:/Program Files/7-Zip/7z.exe','e',str(p),'WIN51*',r'I386\PRODSPEC.INI',r'I386\SETUPP.INI',r'I386\TXTSETUP.SIF','-o'+str(out),'-y'],check=True,stdout=subprocess.DEVNULL)
 print('MARKERS',[f.name for f in out.glob('WIN51*')])
 spec=out/'PRODSPEC.INI'
 if spec.exists():print('PRODSPEC',spec.read_bytes().decode('latin1'))
 sif=out/'TXTSETUP.SIF'
 if sif.exists():
  for line in sif.read_bytes().decode('latin1').splitlines():
   if line.lower().startswith(('productname','majorversion','minorversion','defaultproductkey','spcdname')) and not 'key' in line.lower():print('SETUP',line)
print('LOCAL_SP3_PACKAGES')
for base in (root/'tools/vendor',root/'media',root/'artifacts'):
 for p in base.rglob('*936929*'):
  if p.is_file():print(p,p.stat().st_size)
