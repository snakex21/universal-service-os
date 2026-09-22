from pathlib import Path
import hashlib
root=Path(__file__).resolve().parents[1]
folder=root/'artifacts/vista/offline-kmdf-20260921-174803'
for name in ['SYSTEM','SOFTWARE','COMPONENTS']:
 a=hashlib.sha256((folder/name).read_bytes()).hexdigest()
 b=hashlib.sha256(Path('M:/Windows/System32/config',name).read_bytes()).hexdigest()
 print(name,'UNCHANGED' if a==b else 'CHANGED',b)
print('WDF bytes',Path('M:/Windows/System32/drivers/Wdf01000.sys').stat().st_size)
