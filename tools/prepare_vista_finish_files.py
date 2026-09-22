"""Prepare and validate local-only repairs for the successful Vista Setup run."""
from pathlib import Path
import ctypes as c,hashlib,io,json,os,shutil,struct,subprocess,sys,uuid
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'tools'))
from repair_vista_drive_mapping import inventory
from Registry import Registry
folder=Path((root/'zig-out/vista/finish-snapshot-path.txt').read_text())
meta=json.loads((folder/'snapshot.json').read_text(encoding='utf-8-sig'))
assert meta['osGuid'].strip('{}').lower()=='8dca99dc-9f12-46c9-9c0d-5230748ee536'
assert 'Vista Setup returned=0x00000000' in (folder/'usb-logs/vista-install.log').read_text()
out=folder/'prepared';out.mkdir(exist_ok=False)
system=(folder/'SYSTEM').read_bytes();software=(folder/'SOFTWARE').read_bytes()
reg=Registry.Registry(io.BytesIO(system));soft=Registry.Registry(io.BytesIO(software))
letter=soft.open('Microsoft\\Windows NT\\CurrentVersion').value('SystemRoot').value()[0]
assert soft.open('Microsoft\\Windows NT\\CurrentVersion').value('CurrentBuildNumber').value()=='6002'
assert soft.open('Microsoft\\Windows NT\\CurrentVersion').value('SystemRoot').value()==letter+':\\Windows'
assert soft.open('Microsoft\\Windows\\CurrentVersion').value('ProgramFilesDir').value()==letter+':\\Program Files'
assert reg.open('MountedDevices').value('\\DosDevices\\'+letter+':').value()==b'DMIO:ID:'+uuid.UUID(meta['osGuid'].strip('{}')).bytes_le
assert reg.open('Setup').value('CmdLine').value()=='oobe\\windeploy.exe'
assert reg.open('Setup').value('SetupType').value() in [0,2]
frozen=root/'artifacts/vista/hardware-success-v11-20260920-235629'
manifest=json.loads((frozen/'manifest.json').read_text())
for name,digest in manifest['sha256'].items():
    if name.startswith('payload/'):
        target=Path(meta['osRoot'])/name[len('payload/'):]
        assert hashlib.sha256(target.read_bytes()).hexdigest()==digest, target
temp=out/'tmp';temp.mkdir()
env=dict(os.environ,TEMP=str(temp),TMP=str(temp),ZIG_GLOBAL_CACHE_DIR=str(root/'tools/cache/zig-global'),ZIG_LOCAL_CACHE_DIR=str(out/'zig-cache'))
dll=out/'hive-check.dll'
subprocess.run([str(root/'tools/zig/zig.exe'),'cc','-target','x86_64-windows-gnu','-shared','-Os','-nostdlib','-fno-builtin',str(root/'tools/tests/vista_hive_harness.c'),'-Wl,--entry,DllMain','-o',str(dll)],env=env,check=True)
lib=c.CDLL(str(dll));lib.patch_setup.argtypes=[c.c_void_p,c.c_uint32,c.c_wchar_p];lib.patch_setup.restype=c.c_int
buf=c.create_string_buffer(system,len(system));launch=letter+':\\USOS\\usb.exe'
assert lib.patch_setup(buf,len(system),launch)==1
expected=inventory(reg);expected['\\Setup']['CmdLine']=(1,(launch+'\0').encode('utf-16le'));expected['\\Setup']['SetupType']=(4,struct.pack('<I',2))
assert inventory(Registry.Registry(io.BytesIO(buf.raw)))==expected
(out/'SYSTEM').write_bytes(buf.raw)
store=out/'BCD';shutil.copyfile(folder/'BCD',store)
for suffix in ['.LOG','.LOG1','.LOG2']:
    if (folder/('BCD'+suffix)).exists():shutil.copyfile(folder/('BCD'+suffix),out/('BCD'+suffix))
loader='{'+str(uuid.uuid4())+'}'
def bcd(*args):
    result=subprocess.run(['bcdedit.exe','/store',str(store),*args],capture_output=True)
    with (out/'bcd-operations.log').open('ab') as f:f.write((' '.join(args)+'\n').encode());f.write(result.stdout+result.stderr)
    assert result.returncode==0,(args,result.returncode)
bcd('/enum','all','/v')
recovered=Registry.Registry(str(store));candidates=[]
for obj in recovered.open('Objects').subkeys():
    try:
        elem=obj.subkey('Elements')
        if elem.subkey('12000002').value('Element').value().lower()=='\\windows\\system32\\winload.efi' and uuid.UUID(meta['osGuid'].strip('{}')).bytes_le in elem.subkey('21000001').value('Element').value():candidates.append(obj.name())
    except Registry.RegistryKeyNotFoundException:pass
assert len(candidates)<=1,candidates
if candidates:loader=candidates[0]
else:bcd('/create',loader,'/d','Windows Vista Ultimate SP2','/application','osloader')
for key,value in {'device':'partition='+meta['osRoot'][:2],'osdevice':'partition='+meta['osRoot'][:2],'path':'\\Windows\\system32\\winload.efi','systemroot':'\\Windows','inherit':'{bootloadersettings}','locale':'pl-PL','nx':'OptIn','testsigning':'on','nocrashautoreboot':'on'}.items():bcd('/set',loader,key,value)
bcd('/default',loader);bcd('/displayorder',loader);bcd('/timeout','0')
check=Registry.Registry(str(store));boot=check.open('Objects\\{9dea862c-5cdd-4e70-acc1-f32b344d4795}\\Elements')
assert boot.subkey('23000003').value('Element').value()==loader
assert uuid.UUID(meta['espGuid'].strip('{}')).bytes_le in boot.subkey('11000001').value('Element').value()
for name in ['11000001','21000001']:
    assert uuid.UUID(meta['osGuid'].strip('{}')).bytes_le in check.open('Objects\\'+loader+'\\Elements\\'+name).value('Element').value()
assert check.open('Objects\\'+loader+'\\Elements\\16000049').value('Element').value()==b'\x01'
shutil.copyfile(folder/'bootmgfw.efi',out/'bootx64.efi')
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
report={'loader':loader,'runtime':launch,'system_all_values_verified':True,'target_payload_v11_verified':True,'original':{n:digest(folder/n) for n in ['SYSTEM','SOFTWARE','BCD','bootmgfw.efi','bootx64.before'] if (folder/n).exists()},'prepared':{n:digest(out/n) for n in ['SYSTEM','BCD','bootx64.efi']}}
(out/'repair.json').write_text(json.dumps(report,indent=2))
print('PREPARED: complete Vista boot entry + USB hook; all SYSTEM values compared; v11 payload exact; Intel not modified')
