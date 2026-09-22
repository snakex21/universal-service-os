"""Prepare a narrowly bounded offline MOOBE change; never write a target disk."""
from pathlib import Path
import ctypes,hashlib,json,os,subprocess,sys,struct,xml.etree.ElementTree as ET
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'tools/cache/registry-reader'))
from Registry import Registry
snapshot=Path((root/'zig-out/vista/winsat-snapshot-path.txt').read_text())
out=snapshot/'prepared';out.mkdir(exist_ok=True)
source=Path('M:/Windows/System32/config/SOFTWARE');data=source.read_bytes()
hive=Registry.Registry(str(source))
assert hive.open(r'Microsoft\Windows NT\CurrentVersion').value('CurrentVersion').value()=='6.0'
assert hive.open(r'Microsoft\Windows NT\CurrentVersion').value('CurrentBuildNumber').value()=='6002'
sam=Path('M:/Windows/System32/config/SAM')
names=Registry.Registry(str(sam)).open(r'SAM\Domains\Account\Users\Names')
assert 'test' in [k.name() for k in names.subkeys()]
system=Path('M:/Windows/System32/config/SYSTEM')
setup=Registry.Registry(str(system)).open('Setup')
assert setup.value('OOBEInProgress').value()==1
assert setup.value('SystemSetupInProgress').value()==0
assert setup.value('CmdLine').value()==r'oobe\windeploy.exe'
assert hive.open(r'Microsoft\Windows NT\CurrentVersion\WinSAT').value('MOOBE').value()==1
log=Path('M:/Windows/Panther/UnattendGC/setupact.log').read_bytes()
log=log.decode('utf-16') if log.startswith(b'\xff\xfe') else log.decode('utf-8',errors='replace')
assert 'Finalize: create user [test]' in log and 'Exiting mandatory tasks... [0x0]' in log
# Recovery of this already-created account only. Never included in fresh media:
# native OOBE must still create an account on a new installation.
answer=Path('M:/Windows/Panther/unattend.xml');original_answer=answer.read_bytes()
ns='urn:schemas-microsoft-com:unattend';ET.register_namespace('',ns)
xml=ET.fromstring(original_answer)
assert not xml.findall('{%s}settings'%ns)
settings=ET.SubElement(xml,'{%s}settings'%ns,{'pass':'oobeSystem'})
component=ET.SubElement(settings,'{%s}component'%ns,{'name':'Microsoft-Windows-Shell-Setup','processorArchitecture':'amd64','publicKeyToken':'31bf3856ad364e35','language':'neutral','versionScope':'nonSxS'})
oobe=ET.SubElement(component,'{%s}OOBE'%ns)
for name in ['SkipMachineOOBE','SkipUserOOBE']:ET.SubElement(oobe,'{%s}%s'%(ns,name)).text='true'
prepared_answer=ET.tostring(xml,encoding='utf-8',xml_declaration=True)
(out/'unattend.xml.original').write_bytes(original_answer)
(out/'unattend.xml').write_bytes(prepared_answer)
env=dict(os.environ,TEMP=str(root/'zig-out/vista/usb-install/tmp'),TMP=str(root/'zig-out/vista/usb-install/tmp'),ZIG_GLOBAL_CACHE_DIR=str(root/'tools/cache/zig-global'),ZIG_LOCAL_CACHE_DIR=str(root/'zig-out/vista/usb-install/zig-cache'))
dll=out/'winsat-patch.dll'
subprocess.run([str(root/'tools/zig/zig.exe'),'cc','-target','x86_64-windows-gnu','-shared','-nostdlib','-Os',str(root/'tools/tests/vista_winsat_harness.c'),'-Wl,--entry,DllMain','-o',str(dll)],env=env,check=True)
api=ctypes.CDLL(str(dll));api.skip_moobe.argtypes=[ctypes.c_void_p,ctypes.c_uint32];api.skip_moobe.restype=ctypes.c_int
buf=ctypes.create_string_buffer(data,len(data));assert api.skip_moobe(buf,len(data))==1
changed=buf.raw
# Only two sequence counters, checksum, and the MOOBE DWORD may change.
diff=[i for i,(a,b) in enumerate(zip(data,changed)) if a!=b]
payload=[i for i in diff if i>=4096];assert len(payload)==1 and data[payload[0]]==1 and changed[payload[0]]==2
assert all(i in range(4,12) or i in range(0x1fc,0x200) or i==payload[0] for i in diff)
assert api.skip_moobe(buf,len(data))==0
dirty=bytearray(data);dirty[4]^=1;bad=ctypes.create_string_buffer(bytes(dirty),len(data));assert api.skip_moobe(bad,len(data))==0
(out/'SOFTWARE').write_bytes(changed)
assert Registry.Registry(str(out/'SOFTWARE')).open(r'Microsoft\Windows NT\CurrentVersion\WinSAT').value('MOOBE').value()==2
def sha(b): return hashlib.sha256(b).hexdigest()
(out/'SOFTWARE.original').write_bytes(data)
report={'original':sha(data),'prepared':sha(changed),'SYSTEM':sha(system.read_bytes()),'SAM':sha(sam.read_bytes()),'changed_offsets':diff,'change':'MOOBE=1 -> 2: deliberately skip automatic assessment; not a measured score','accounts_unchanged':True,'answer_original':sha(original_answer),'answer_prepared':sha(prepared_answer),'recovery_only':'Skip completed OOBE pages for verified existing test account; native windeploy finishes Setup'}
(out/'repair.json').write_text(json.dumps(report,indent=2))
print('PREPARED_MOOBE_ONLY; dirty hive rejected; native readback=2; SAM/SYSTEM unchanged; backup='+str(out))
