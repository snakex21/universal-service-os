"""Validate production XML generator against the actual Microsoft MUM identity."""
from pathlib import Path
import ctypes,xml.etree.ElementTree as ET,shutil,tempfile
root=Path(__file__).resolve().parents[2]
# Built by check_vista_esp_selection.py; this test never runs Setup or servicing.
lib=ctypes.CDLL(str(root/'zig-out/vista/usb-install/vista-esp-tests.dll'))
fn=lib.servicing_answer
fn.argtypes=[ctypes.POINTER(ctypes.c_wchar),ctypes.c_uint,ctypes.c_wchar_p]
fn.restype=ctypes.c_uint
mum=ET.parse(root/'zig-out/vista/community-usb/kb/files/update.mum')
identity=mum.getroot().find('{urn:schemas-microsoft-com:asm.v3}assemblyIdentity').attrib
ns='{urn:schemas-microsoft-com:unattend}'
for path in ['X:\\Windows\\System32\\Windows6.0-KB2864202-x64.cab','X:\\żółć & test\\a<b>".cab']:
 out=ctypes.create_unicode_buffer(2048);size=fn(out,2048,path);assert size>0
 doc=ET.fromstring(out.value.encode('utf-16le'))
 assert doc.tag==ns+'unattend'
 assert [e.tag for e in doc]==[ns+'servicing']
 packages=doc.findall(ns+'servicing/'+ns+'package');assert len(packages)==1
 package=packages[0];assert package.attrib=={'action':'install'}
 assert package.find(ns+'assemblyIdentity').attrib==identity
 assert package.find(ns+'source').attrib=={'location':path}
 assert len(package)==2
 # Exact-size buffer needs space for terminating NUL; truncation is rejected.
 exact=ctypes.create_unicode_buffer(size+1);assert fn(exact,size+1,path)==size
 assert fn(exact,size,path)==0
for path in ['', 'X:\\bad\npath', 'X:\\bad\tpath']:
 assert fn(ctypes.create_unicode_buffer(2048),2048,path)==0
print('PASS: production servicing XML matches KB2864202 6.0.1.0 MUM; escaping/bounds; no disk, product-key or account settings')
check=lib.check_framework;check.argtypes=[ctypes.c_wchar_p];check.restype=ctypes.c_int
with tempfile.TemporaryDirectory(dir=root/'zig-out/vista/usb-install',prefix='framework-check-') as folder:
 base=Path(folder);drivers=base/'Windows/System32/drivers';drivers.mkdir(parents=True)
 source=root/'zig-out/vista/community-usb/kb/files/amd64_microsoft-windows-wdf-kernellibrary_31bf3856ad364e35_6.0.6002.18880_none_d401bb27d3b09f79'
 assert check(str(base)+'\\')==0
 for name in ['wdf01000.sys','wdfldr.sys']:shutil.copyfile(source/name,drivers/name)
 assert check(str(base)+'\\')==1
 (drivers/'wdfldr.sys').write_bytes(b'invalid framework file')
 assert check(str(base)+'\\')==0
print('PASS: production pre-reboot KMDF gate accepts both Microsoft 1.11 files and rejects missing/invalid files; project-local fixtures only')
