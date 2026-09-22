from pathlib import Path
import ctypes as c,winreg,hashlib,json
root=Path(__file__).resolve().parents[1]
snap=sorted((root/'artifacts/xp-pae').glob('lsass-*'))[-1]
def read(p):
 b=p.read_bytes();return b.decode('utf-16' if b.startswith(b'\xff\xfe') else 'cp1250',errors='replace')
for rel in ['boot.ini','WINDOWS/setupact.log','WINDOWS/setuperr.log','WINDOWS/setupapi.log']:
 p=snap/rel
 if p.exists():print('\nFILE',rel,'\n',read(p)[-18000:])
adv=c.WinDLL('advapi32');adv.RegLoadAppKeyW.argtypes=[c.c_wchar_p,c.POINTER(c.c_void_p),c.c_uint,c.c_uint,c.c_uint]
h=c.c_void_p();rc=adv.RegLoadAppKeyW(str(snap/'WINDOWS/System32/config/SYSTEM'),c.byref(h),winreg.KEY_READ,1,0)
assert rc==0,rc
def values(path):
 try:
  with winreg.OpenKey(h.value,path) as k:
   i=0
   while True:
    try:n,v,t=winreg.EnumValue(k,i);i+=1
    except OSError:break
    if isinstance(v,bytes):v=v.hex()
    print(path,n,repr(v))
 except FileNotFoundError:print('MISSING',path)
try:
 for p in ['Select','Setup','MountedDevices']:values(p)
 for cs in ['ControlSet001','ControlSet002']:
  for path in ['Control/Session Manager','Control/CrashControl','Services/genahci','Services/storahci','Services/iaStor','Services/disk','Services/MountMgr','Services/Ftdisk','Services/PartMgr','Services/Ntfs']:
   values(cs+'\\'+path.replace('/','\\'))
finally:winreg.CloseKey(h.value)
for name in ['genahci.sys','storport.sys','acpi.sys','ntoskrn8.sys','ntfs.sys','disk.sys','classpnp.sys','mountmgr.sys','ftdisk.sys','partmgr.sys']:
 p=Path('M:/WINDOWS/system32/drivers')/name
 print('DRIVER',name,p.stat().st_size if p.exists() else 'MISSING',hashlib.sha256(p.read_bytes()).hexdigest() if p.exists() else '')
print('CONFIG FILES',[(p.name,p.stat().st_size) for p in Path('M:/WINDOWS/system32/config').iterdir()])
