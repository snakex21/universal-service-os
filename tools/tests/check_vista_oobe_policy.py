"""Exercise production decisions on real and interrupted logs; no OS mutations."""
from pathlib import Path
import ctypes,os,subprocess,sys
root=Path(__file__).resolve().parents[2];out=root/'zig-out/vista/usb-install'
env=dict(os.environ,TEMP=str(out/'tmp'),TMP=str(out/'tmp'),ZIG_GLOBAL_CACHE_DIR=str(root/'tools/cache/zig-global'),ZIG_LOCAL_CACHE_DIR=str(out/'zig-cache'))
dll=out/'oobe-policy-tests.dll'
subprocess.run([str(root/'tools/zig/zig.exe'),'cc','-target','x86_64-windows-gnu','-shared','-nostdlib','-Os',str(root/'tools/tests/vista_oobe_policy_harness.c'),'-Wl,--entry,DllMain','-o',str(dll)],env=env,check=True)
api=ctypes.CDLL(str(dll));api.completed.argtypes=[ctypes.c_char_p,ctypes.c_uint,ctypes.c_char_p];api.decide.argtypes=[ctypes.c_uint]*4
log=(root/'artifacts/vista/oobe-resume-20260921-190133/Windows/Panther/UnattendGC/setupact.log').read_bytes()
def check(data,name=b'test'):return api.completed(data,len(data),name)
assert check(log)==1
assert check(log,b'other')==0
assert check(b'')==0
assert check(log+b'\0'*256)==0
assert check(log+b'\n[oobeldr.exe] Launching [C:\\Windows\\system32\\oobe\\msoobe.exe]...')==0
assert check(log+b'\n[msoobe.exe] Running mandatory tasks\n[msoobe.exe] Exiting mandatory tasks... [0x1]')==0
for marker in [b'Finalize: create user [test]',b'Exiting mandatory tasks... [0x0]']:
 assert check(log[:log.index(marker)+len(marker)-1])==0
other=log.replace(b'create user [test]',b'create user [Anna]')
assert check(other,b'Anna')==1 and check(other)==0
assert api.decide(1,1,0,0)==0
assert api.decide(1,1,1,1)==1
assert api.decide(1,1,1,0)==-1
assert api.decide(1,1,2,1)==-1
assert api.decide(0,1,1,1)==-1
assert api.decide(1,0,1,1)==-1
sys.path.insert(0,str(root/'tools/cache/registry-reader'))
from Registry import Registry
fresh=root/'artifacts/vista/winsat-stall-20260921-184000/USOS/Vista/SYSTEM.before-usb'
h=Registry.Registry(str(fresh));setup=h.open('Setup')
assert setup.value('SystemSetupInProgress').value()==1
assert setup.value('SetupPhase').value()==4
assert setup.value('OOBEInProgress').value() in [0,1]
assert h.open(r'Setup\Status\ChildCompletion').value('setup.exe').value()==0
print('PASS: fresh wizard, existing account recovery, ambiguous/incomplete state blocked; real OOBE log, different names, interrupted/restarted/corrupt logs')
