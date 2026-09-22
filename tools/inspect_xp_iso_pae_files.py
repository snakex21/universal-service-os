from pathlib import Path
import subprocess
for iso in sorted(Path('L:/Systems/Windows/Windows XP/Images').glob('*.iso')):
    listing=subprocess.run(['C:/Program Files/7-Zip/7z.exe','l',str(iso)],capture_output=True,text=True,check=True).stdout
    print(iso.name)
    for line in listing.splitlines():
        if any(s in line.upper() for s in ['NTKR','NTOS','HALMAC','ACPI.SY','USBOHCI','USBXHCI','STORAHCI']):print(line)
