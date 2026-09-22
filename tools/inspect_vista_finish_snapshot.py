from pathlib import Path
import sys,json,uuid
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'tools/cache/registry-reader'))
from Registry import Registry
folder=Path((root/'zig-out/vista/finish-snapshot-path.txt').read_text())
meta=json.loads((folder/'snapshot.json').read_text(encoding='utf-8-sig'))
for hive,keys in [('SYSTEM',['Setup','Setup\\Status\\ChildCompletion','MountedDevices']),('SOFTWARE',['Microsoft\\Windows NT\\CurrentVersion','Microsoft\\Windows\\CurrentVersion'])]:
    reg=Registry.Registry(str(folder/hive))
    for key in keys:
        for value in reg.open(key).values():
            if key=='MountedDevices' and not value.name().startswith('\\DosDevices'):continue
            if hive=='SOFTWARE' and value.name() not in ['SystemRoot','ProgramFilesDir','CurrentVersion','CurrentBuildNumber']:continue
            print(hive,key,value.name(),repr(value.value()))
reg=Registry.Registry(str(folder/'BCD'))
boot=reg.open('Objects\\{9dea862c-5cdd-4e70-acc1-f32b344d4795}\\Elements')
default=boot.subkey('23000003').value('Element').value()
print('BCD default',default)
for name in ['11000001','21000001','12000002','12000004']:
    try: print('BCD loader',name,repr(reg.open('Objects\\'+default+'\\Elements\\'+name).value('Element').value()))
    except Exception as e: print(type(e).__name__,name)
print('SNAPSHOT',folder)
for obj in reg.open('Objects').subkeys():
    print('OBJECT',obj.name())
    try:
        for el in obj.subkey('Elements').subkeys():
            if el.name() in ['11000001','21000001','12000002','12000004','23000003','24000001']:
                print(el.name(),repr(el.value('Element').value()))
    except Exception as error:print(type(error).__name__)
