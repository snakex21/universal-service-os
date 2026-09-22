"""Build a Vista-only recovery helper and prepare an offline SYSTEM copy."""
from pathlib import Path
import ctypes,hashlib,json,os,subprocess,sys,datetime
root=Path(__file__).resolve().parents[1];sys.path.insert(0,str(root/'tools/cache/registry-reader'))
from Registry import Registry
out=root/'artifacts/vista'/('oobe-resume-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S'));out.mkdir(parents=True)
target=Path('M:/');config=target/'Windows/System32/config'
def sha(data):return hashlib.sha256(data).hexdigest()
for name in ['SYSTEM','SOFTWARE','SAM']:(out/name).write_bytes((config/name).read_bytes())
for rel in ['Windows/Panther/unattend.xml','Windows/Panther/UnattendGC/setupact.log','Windows/Performance/WinSAT/winsat.log']:
 dest=out/rel;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes((target/rel).read_bytes())
software=Registry.Registry(str(out/'SOFTWARE'))
assert software.open(r'Microsoft\Windows NT\CurrentVersion').value('SystemRoot').value()==r'C:\Windows'
assert software.open(r'Microsoft\Windows NT\CurrentVersion').value('CurrentBuildNumber').value()=='6002'
assert 'test' in [k.name() for k in Registry.Registry(str(out/'SAM')).open(r'SAM\Domains\Account\Users\Names').subkeys()]
env=dict(os.environ,TEMP=str(root/'zig-out/vista/usb-install/tmp'),TMP=str(root/'zig-out/vista/usb-install/tmp'),ZIG_GLOBAL_CACHE_DIR=str(root/'tools/cache/zig-global'),ZIG_LOCAL_CACHE_DIR=str(root/'zig-out/vista/usb-install/zig-cache'))
common=[str(root/'tools/zig/zig.exe'),'cc','-target','x86_64-windows.vista-gnu','-Os','-nostdlib','-fno-stack-protector','-fno-builtin','-I'+str(root/'tools/zig/lib/libc/include/any-windows-any')]
subprocess.run(common+[str(root/'tools/windows_vista_oobe_resume.c'),'-Wl,--entry,entry','-lkernel32','-ladvapi32','-lnetapi32','-o',str(out/'end.exe')],env=env,check=True)
subprocess.run(common+['-shared',str(root/'tools/tests/vista_oobe_resume_harness.c'),'-Wl,--entry,DllMain','-o',str(out/'patch.dll')],env=env,check=True)
api=ctypes.CDLL(str(out/'patch.dll'));api.arm_oobe_resume.argtypes=[ctypes.c_void_p,ctypes.c_uint32];api.arm_oobe_resume.restype=ctypes.c_int
data=(out/'SYSTEM').read_bytes();buf=ctypes.create_string_buffer(data,len(data));assert api.arm_oobe_resume(buf,len(data))==1
prepared=buf.raw;(out/'SYSTEM.prepared').write_bytes(prepared)
assert api.arm_oobe_resume(buf,len(data))==0
dirty=bytearray(data);dirty[4]^=1;buf=ctypes.create_string_buffer(bytes(dirty),len(data));assert api.arm_oobe_resume(buf,len(data))==0
old=Registry.Registry(str(out/'SYSTEM'));new=Registry.Registry(str(out/'SYSTEM.prepared'))
diff=[]
def compare(a,b):
 av={v.name():(v.value_type(),v.value()) for v in a.values()};bv={v.name():(v.value_type(),v.value()) for v in b.values()}
 assert av.keys()==bv.keys()
 for name in av:
  if av[name]!=bv[name]:diff.append((a.path(),name,av[name],bv[name]))
 ak={k.name():k for k in a.subkeys()};bk={k.name():k for k in b.subkeys()};assert ak.keys()==bk.keys()
 for name in ak:compare(ak[name],bk[name])
compare(old.root(),new.root());assert len(diff)==1 and diff[0][1]=='CmdLine' and diff[0][3][1]==r'C:\USOS\end.exe'
report={'original':{name:sha((out/name).read_bytes()) for name in ['SYSTEM','SOFTWARE','SAM']},'prepared':sha(prepared),'exe':sha((out/'end.exe').read_bytes()),'logical_changes':diff}
(out/'manifest.json').write_text(json.dumps(report,indent=2))
(root/'zig-out/vista/oobe-resume-path.txt').write_text(str(out))
print('BUILD_AND_CHECK_PASS: Vista helper; only SYSTEM Setup/CmdLine changes; dirty/repeated patch rejected; '+str(out))
