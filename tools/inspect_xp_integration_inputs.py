from pathlib import Path
import subprocess,sys
sys.stdout.reconfigure(errors='backslashreplace')
r=Path(__file__).resolve().parents[1]
d=r/'media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x86'
iso=next(Path('L:/Systems/Windows/Windows XP/Images').glob('*NiKKA.iso'))
out=r/'zig-out/xp-uefi-csm/driver-source';out.mkdir(parents=True,exist_ok=True)
subprocess.run(['C:/Program Files/7-Zip/7z.exe','e',str(iso),'I386\\TXTSETUP.SIF','I386\\DOSNET.INF','I386\\HIVESYS.INF','I386\\SETUPREG.HIV','WIN51IP.SP3','-o'+str(out),'-y'],check=True,stdout=subprocess.DEVNULL)
s=(out/'TXTSETUP.SIF').read_text(encoding='latin1')
for l in s.splitlines():
 if any(t in l.lower() for t in ('genahci','storport','ntoskrn8','acpi.sys','wdf','149c','43d0','43b7','0c0330','010601','usbxhci','usbhub3','sata','ahci')):print(l)
