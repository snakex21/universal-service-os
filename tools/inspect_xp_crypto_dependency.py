"""Read-only PE entry/export inspection; do not run target drivers."""
from pathlib import Path
import ast, ctypes as c, struct
root=Path(__file__).resolve().parents[1]
tree=ast.parse((root/'tools/tests/check_xp_driver_imports.py').read_text())
f=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='pe')
ns={'struct':struct};exec(compile(ast.Module(body=[f],type_ignores=[]),'pe-parser','exec'),ns)
v=c.WinDLL('version')
v.GetFileVersionInfoSizeW.argtypes=[c.c_wchar_p,c.c_void_p]
v.GetFileVersionInfoW.argtypes=[c.c_wchar_p,c.c_uint,c.c_uint,c.c_void_p]
v.VerQueryValueW.argtypes=[c.c_void_p,c.c_wchar_p,c.POINTER(c.c_void_p),c.POINTER(c.c_uint)]
for name in ('ksecd8.sys','ksecdd.sys','genahci.sys','storport.sys'):
 p=Path('M:/WINDOWS/system32/drivers')/name;b=p.read_bytes()
 n=v.GetFileVersionInfoSizeW(str(p),None);ver=None
 if n:
  buf=c.create_string_buffer(n);assert v.GetFileVersionInfoW(str(p),0,n,buf)
  addr=c.c_void_p();size=c.c_uint();assert v.VerQueryValueW(buf,'\\',c.byref(addr),c.byref(size))
  q=struct.unpack('<13I',c.string_at(addr,52));ver=(q[2]>>16,q[2]&65535,q[3]>>16,q[3]&65535)
 h=struct.unpack_from('<I',b,60)[0];o=h+24;ep=struct.unpack_from('<I',b,o+16)[0]
 sec=o+struct.unpack_from('<H',b,h+20)[0];entry=None
 for i in range(struct.unpack_from('<H',b,h+6)[0]):
  vs,va,rs,raw=struct.unpack_from('<IIII',b,sec+i*40+8)
  if va<=ep<va+max(vs,rs):entry=b[raw+ep-va:raw+ep-va+24].hex()
 exports,imports=ns['pe'](p)
 print(name,'version',ver,'entry',hex(ep),entry,'DLL',bool(struct.unpack_from('<H',b,h+22)[0]&0x2000))
 print('initialization exports',sorted(x for x in exports if 'init' in x.lower() or 'entry' in x.lower()))
