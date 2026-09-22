from pathlib import Path
import shutil
from datetime import datetime
import sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

repo = Path(__file__).resolve().parents[1]
out = repo / 'artifacts/vista' / ('failed-usb-setup-' + datetime.now().strftime('%Y%m%d-%H%M%S'))
out.mkdir(parents=True)
run = Path('J:/EFI/USOS/Logs/WinSetup-2026-9-20-23-35-48-1748')
shutil.copytree(run, out / 'usb-logs')
print('Saved evidence:', out)
print('Target root:', [p.name for p in Path('M:/').iterdir()])
for folder in [Path('M:/$WINDOWS.~BT/Sources/Panther'), Path('M:/Windows/Panther')]:
    if not folder.exists():
        continue
    shutil.copytree(folder, out / folder.parent.name / folder.name)
    for p in folder.glob('*.log'):
        print('\nLOG', p, p.stat().st_size)
        raw = p.read_bytes()
        text = raw.decode('utf-16' if raw.startswith(b'\xff\xfe') else 'utf-8-sig', errors='replace')
        print(text[-24000:])
p = run / 'pe-panther-setupact.log'
print('\nPE final section:\n', p.read_text(errors='replace')[-13000:])
