from pathlib import Path
import json, struct, subprocess, zipfile
root=Path(__file__).resolve().parents[1]
base=root/'tools/vendor/xp-modern/2026-09-21'
patches=next(base.glob('integrator/*/Patch Integrator */Patches'))
print('PATCH DIRECTORIES')
for p in patches.iterdir():
 if p.is_dir():print(p.name)
print('USB AND DEPENDENCY DOCUMENTATION')
for p in patches.rglob('*'):
 if p.is_file() and (p.name.lower().startswith('readme') or p.suffix.lower()=='.inf') and any(t in str(p.relative_to(patches)).lower() for t in ('microsoft usb','miscellaneous','acpi drivers')):
  b=p.read_bytes();s=b.decode('utf-16') if b.startswith((b'\xff\xfe',b'\xfe\xff')) else b.decode('cp1252',errors='replace')
  print('\nFILE',p.relative_to(patches))
  if p.suffix.lower()=='.inf':
   print('\n'.join(l for l in s.splitlines() if any(t in l.lower() for t in ('pci\\','driverver','copyfiles','sourcedisksfiles','.sys','ntx86','nt.5'))))
  else:print(s[:5000])
print('INTEGRATOR DEPENDENCY REFERENCES')
menu=patches.parent/'Options Menu.cmd'
lines=menu.read_text(encoding='cp1252').splitlines()
for i,l in enumerate(lines):
 if any(t in l.lower() for t in ('ntoskrn8','wdf01000','wdfldr','genahci','usbxhci','usbhub3','pae')): print(i+1,l[:240])
