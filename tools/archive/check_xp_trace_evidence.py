from pathlib import Path
import hashlib,sys,io,ast,struct
root=Path(__file__).resolve().parents[1];sys.path.insert(0,str(root/'tools/cache/registry-reader'))
from Registry import Registry
sys.path.insert(0,str(root/'tools'))
from repair_vista_drive_mapping import inventory
snap=sorted((root/'artifacts/xp-pae').glob('lsass-*'))[-1]
current=(snap/'WINDOWS/System32/config/SYSTEM').read_bytes()
before=(root/'artifacts/xp-pae/setup-trace-v3/backup-20260922-013221/SYSTEM').read_bytes()
a=inventory(Registry.Registry(io.BytesIO(before)));b=inventory(Registry.Registry(io.BytesIO(current)))
diff=[]
for key in sorted(a.keys()|b.keys()):
 for name in sorted(a.get(key,{}).keys()|b.get(key,{}).keys()):
  if a.get(key,{}).get(name)!=b.get(key,{}).get(name):diff.append((key,name))
print('REGISTRY_DIFF_VS_BEFORE_TRACE',len(diff),diff[:50])
print('USOS_ROOT',[(p.name,p.stat().st_size) for p in Path('M:/USOS').iterdir()])
tree=ast.parse((root/'tools/tests/check_xp_driver_imports.py').read_text());f=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='pe')
ns={'struct':struct};exec(compile(ast.Module(body=[f],type_ignores=[]),'pe-parser','exec'),ns);pe=ns['pe']
exe=root/'artifacts/xp-pae/setup-trace-v3/setup-trace.exe';missing=[]
for module,function in pe(exe)[1]:
 exports=pe(Path('M:/WINDOWS/system32')/module)[0]
 if function not in exports:missing.append((module,function))
print('TRACE_IMPORTS_MISSING_FROM_XP',missing)
print('TRACE_BINARY_MATCHES',exe.read_bytes()==Path('M:/USOS/x.exe').read_bytes())
print('PAE_KERNEL_MATCHES_ORIGINAL',Path('M:/WINDOWS/system32/ntkrnlpa.exe').read_bytes()==(root/'zig-out/xp-uefi-csm/checks/0/ntkrpamp.exe').read_bytes())
