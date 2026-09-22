"""Cross-check shipped CPIO payloads against the hardware-success snapshot."""
from pathlib import Path
import hashlib
import json
import re

root=Path(__file__).resolve().parents[2]


def cpio(path):
    data=path.read_bytes();at=0;files={}
    while at<len(data):
        assert data[at:at+6]==b'070701'
        size=int(data[at+54:at+62],16);length=int(data[at+94:at+102],16)
        assert length>1 and data[at+110+length-1]==0
        name=data[at+110:at+110+length-1].decode('ascii')
        assert name not in files and name!='TRAILER!!!'
        start=(at+110+length+3)&~3
        assert start+size<=len(data)
        files[name]=data[start:start+size];at=(start+size+3)&~3
    assert at==len(data)
    return files


support=cpio(root/'zig-out/windows-native/support.cpio')
vista=cpio(root/'zig-out/windows-native/vista-support.cpio')
assert not (support.keys() & vista.keys())
assert len(support)+len(vista)+8<=64
assert b'usos-modern-vista.flag' in support['usos-start.cmd']
assert b'usos-vista-install.exe' in vista['usos-modern-vista.cmd']
assert b'/noreboot' in vista['usos-vista-install.exe'] or '/noreboot'.encode('utf-16le') in vista['usos-vista-install.exe']
header=(root/'zig-out/vista/usb-install/vista_deploy_files.h').read_text()
names=re.findall(r'\{L"(vista-payload-\d+\.bin)"',header)
assert len(names)==14 and len(set(names))==14
snapshot=root/'artifacts/vista/hardware-success-v11-20260920-235629'
manifest=json.loads((snapshot/'manifest.json').read_text())
expected={hashlib.sha256((snapshot/p).read_bytes()).hexdigest() for p in manifest['sha256'] if p.startswith('payload/')}
actual={hashlib.sha256(vista[name]).hexdigest() for name in names[:13]}
assert expected==actual
assert vista[names[13]]==(root/'zig-out/vista/usb-install/usos-vista-oobe.exe').read_bytes()
assert 'USOS\\\\oobe.exe' in header
assert b'V11 direct pre-Setup USB device installation' in b''.join(vista[n] for n in names)
assert not any(n.lower().endswith(('.pfx','.key','.pem')) for n in vista)
if 'vista-target-esp.bin' in vista:
    profile=root/'zig-out/vista/intel-boot-profile'
    metadata=json.loads((profile/'manifest.json').read_text(encoding='utf-8-sig'))
    for original,packed in [('vista-target-esp.bin','vista-target-esp.bin'),('vista-bcdedit.exe','vista-bcdedit.bin'),('vista-bcdedit.exe.mui','vista-bcdedit-mui.bin')]:
        assert hashlib.sha256(vista[packed]).hexdigest()==metadata['sha256'][original]
        assert bytes.fromhex(metadata['sha256'][original]) in vista['usos-vista-install.exe']
    assert len(vista['vista-target-esp.bin'])==48
    assert b'Vista USB installer v8' in vista['usos-vista-install.exe']
    print('VISTA_INTEL_PROFILE_OK; GUID profile and original Vista BCD tools match manifest')
print('VISTA_USB_SUPPORT_OK; exact v11 payload; CPIO names unique; dispatcher connected; no private keys')
