"""Inspect copied artifacts and run only /store against a project-local BCD copy."""
from pathlib import Path
import hashlib,json,subprocess,sys,uuid,shutil
root=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(root/'tools/cache/registry-reader'))
from Registry import Registry
profile=root/'zig-out/vista/intel-boot-profile'
manifest=json.loads((profile/'manifest.json').read_text(encoding='utf-8-sig'))
for name,digest in manifest['sha256'].items():
    assert hashlib.sha256((profile/name).read_bytes()).hexdigest()==digest
data=(profile/'vista-target-esp.bin').read_bytes()
assert len(data)==48 and data[:8]==b'VESP0001'
esp=uuid.UUID(manifest['espGuid'].strip('{}'))
assert data[8:24]==uuid.UUID(manifest['diskGuid'].strip('{}')).bytes_le
assert data[24:40]==esp.bytes_le
assert int.from_bytes(data[40:48],'little')==manifest['diskSize']
store=profile/'BCD.test-copy';shutil.copyfile(profile/'BCD.before',store)
reg=Registry.Registry(str(store))
device=reg.open('Objects\\{9dea862c-5cdd-4e70-acc1-f32b344d4795}\\Elements\\11000001').value('Element').value()
assert esp.bytes_le in device
exe=profile/'read-only-probe/bcdedit.exe';exe.parent.mkdir(exist_ok=True)
shutil.copyfile(profile/'vista-bcdedit.exe',exe)
mui=exe.parent/'pl-PL/bcdedit.exe.mui';mui.parent.mkdir(exist_ok=True)
shutil.copyfile(profile/'vista-bcdedit.exe.mui',mui)
result=subprocess.run([str(exe),'/store',str(store),'/enum','all','/v'],capture_output=True)
(profile/'local-bcd-probe-output.bin').write_bytes(result.stdout+result.stderr)
assert result.returncode==0, result.returncode
print('PASS: Intel GUID profile; bootmgr binds intended ESP; Vista BCDEdit reads project-local BCD copy')
