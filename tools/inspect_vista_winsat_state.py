from pathlib import Path
import sys
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'tools/cache/registry-reader'))
from Registry import Registry
for file in [Path('M:/Windows/System32/config/SOFTWARE'), root/'zig-out/vista/image/Windows/System32/config/SOFTWARE',root/'zig-out/vista/finalizer-hive-read-check/original-SOFTWARE']:
 if not file.exists(): continue
 print(file)
 hive=Registry.Registry(str(file))
 for key in [r'Microsoft\Windows NT\CurrentVersion\WinSAT',r'Microsoft\Windows\CurrentVersion\OOBE']:
  try: print(key,[(v.name(),v.value()) for v in hive.open(key).values()])
  except Registry.RegistryKeyNotFoundException: print('MISSING KEY')
