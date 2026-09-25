from pathlib import Path
import re,sys
sys.stdout.reconfigure(errors='backslashreplace')
r=Path(__file__).resolve().parents[1]
snaps=sorted((r/'artifacts/xp-pae').glob('lsass-*'));now=snaps[-1];prev=snaps[-2]
for n in ('ntbtlog.txt','setupapi.log','setupact.log','setuperr.log'):
 p=now/'WINDOWS'/n;q=prev/'WINDOWS'/n
 b=p.read_bytes();old=q.read_bytes() if q.exists() else b''
 print(n,'bytes',len(b),'previous',len(old),'same',b==old)
 if n=='ntbtlog.txt':
  s=b.decode('utf-16' if b.startswith(b'\xff\xfe') else 'cp1250',errors='replace')
  lines=s.splitlines();print('BOOT_HEADERS',[x for x in lines if 'Service Pack' in x]);print('LAST_BOOT_END','\n'.join(lines[-12:]))
p=next((r/'tools/vendor/xp-modern/2026-09-21').glob('integrator/*/Patch Integrator */Options Menu.cmd'))
lines=p.read_text(encoding='cp1252').splitlines()
for i,l in enumerate(lines):
 if any(t in l.lower() for t in ('ksecd8','ksecdd')): print('RECIPE',i+1,'\n'.join(lines[max(0,i-2):i+3]))
for p in [r/'media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x86/USB3/ksecd8.sys',Path('M:/WINDOWS/system32/drivers/ksecdd.sys')]:
 b=p.read_bytes();strings=re.findall(rb'(?:[\x20-\x7e]\x00){6,}',b)
 print('STRINGS',p.name,[s.decode('utf-16le') for s in strings if any(x in s.decode('utf-16le').lower() for x in ('device','ksec','lsa'))])
