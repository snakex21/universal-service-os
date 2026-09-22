from pathlib import Path
import ctypes as c, winreg, subprocess, hashlib, json
root=Path(__file__).resolve().parents[1]
snap=sorted((root/'artifacts/xp-pae').glob('lsass-*'))[-1]
adv=c.WinDLL('advapi32');adv.RegLoadAppKeyW.argtypes=[c.c_wchar_p,c.POINTER(c.c_void_p),c.c_uint,c.c_uint,c.c_uint]
for hive,paths in [('SYSTEM',[r'ControlSet001\Control\Session Manager\Memory Management',r'ControlSet001\Control\Lsa',r'ControlSet001\Control\Session Manager\SubSystems']),('SOFTWARE',[r'Microsoft\Windows NT\CurrentVersion\Winlogon',r'Microsoft\Windows\CurrentVersion\Setup'])]:
 h=c.c_void_p();rc=adv.RegLoadAppKeyW(str(snap/'WINDOWS/System32/config'/hive),c.byref(h),winreg.KEY_READ,1,0);assert rc==0,rc
 try:
  for path in paths:
   print('\nREG',path)
   with winreg.OpenKey(h.value,path) as k:
    for i in range(winreg.QueryInfoKey(k)[1]):
     n,v,t=winreg.EnumValue(k,i)
     if any(x in n.lower() for x in ('password','productkey','digitalproduct')):continue
     if isinstance(v,bytes):v=f'<{len(v)} bytes>'
     print(n,repr(v))
 finally:winreg.CloseKey(h.value)
names=['LSASS.EXE','LSASRV.DLL','SAMSRV.DLL','MSV1_0.DLL','SECUR32.DLL','ADVAPI32.DLL','NTDLL.DLL','KERNEL32.DLL','WINLOGON.EXE','SYSSETUP.DLL','SETUPAPI.DLL','INITPKI.DLL','RSAENH.DLL','DSSENH.DLL','CRYPT32.DLL','NTKRNLMP.EXE','NTKRPAMP.EXE','HALMACPI.DLL']
iso=next(Path('L:/Systems/Windows/Windows XP/Images').glob('*NiKKA.iso'))
packed=snap/'iso-gui-packed';packed.mkdir(exist_ok=True)
expanded=snap/'iso-gui-expanded';expanded.mkdir(exist_ok=True)
subprocess.run(['C:/Program Files/7-Zip/7z.exe','e',str(iso),*['I386/'+n[:-1]+'_' for n in names],*['I386/'+n for n in names],'-o'+str(packed),'-y'],check=True,stdout=subprocess.DEVNULL)
for p in packed.iterdir():
 if p.suffix.endswith('_'):subprocess.run(['C:/Windows/System32/expand.exe',str(p),str(expanded/(p.name[:-1]+next(n[-1] for n in names if n[:-1]==p.name[:-1])))],check=True,stdout=subprocess.DEVNULL)
 else:(expanded/p.name).write_bytes(p.read_bytes())
results=[]
for n in names:
 p=expanded/n
 dest='ntoskrnl.exe' if n=='NTKRNLMP.EXE' else 'ntkrnlpa.exe' if n=='NTKRPAMP.EXE' else 'hal.dll' if n=='HALMACPI.DLL' else n
 q=Path('M:/WINDOWS/system32')/dest
 same=p.exists() and q.exists() and p.read_bytes()==q.read_bytes()
 results.append({'source':n,'installed':dest,'match':same,'source_size':p.stat().st_size if p.exists() else None,'target_size':q.stat().st_size if q.exists() else None})
print(json.dumps(results,indent=2))
(snap/'gui-files-comparison.json').write_text(json.dumps(results,indent=2))
