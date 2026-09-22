"""Fetch a pinned upstream x64 package and create a local test-signed copy."""
from pathlib import Path
import hashlib, json, os, shutil, struct, subprocess, urllib.request

root = Path(__file__).resolve().parents[1]
out = root / 'zig-out/vista/xhci98'
out.mkdir(parents=True, exist_ok=True)
api = 'https://api.github.com/repos/yeokm1/xhci98/commits/main'
request = urllib.request.Request(api, headers={'User-Agent': 'USOS-Vista-driver-preparation'})
revision = json.load(urllib.request.urlopen(request, timeout=30))['sha']
source = out / 'upstream'
source.mkdir(exist_ok=True)
for name in ('xhci98.inf', 'xhci98.sys'):
    url = f'https://raw.githubusercontent.com/yeokm1/xhci98/{revision}/releases/1.1.0.0/release-x64/{name}'
    (source/name).write_bytes(urllib.request.urlopen(url, timeout=30).read())
for name in ('LICENSE','README.md'):
    url=f'https://raw.githubusercontent.com/yeokm1/xhci98/{revision}/{name}'
    (source/name).write_bytes(urllib.request.urlopen(url, timeout=30).read())
driver = (source/'xhci98.sys').read_bytes()
pe = struct.unpack_from('<I', driver, 0x3c)[0]
assert driver[:2] == b'MZ' and driver[pe:pe+4] == b'PE\0\0'
assert struct.unpack_from('<H', driver, pe+4)[0] == 0x8664
inf = (source/'xhci98.inf').read_text()
assert '[XhciModels.NTamd64.6.0]' in inf and 'PCI\\CC_0C0330' in inf
package = out/'package'
package.mkdir(exist_ok=True)
shutil.copy2(source/'xhci98.sys', package/'xhci98.sys')
assert 'CatalogFile=' not in inf
(package/'xhci98.inf').write_text(inf.replace('[Version]', '[Version]\nCatalogFile=xhci98.cat'), encoding='ascii')
sdk = Path('C:/Program Files (x86)/Windows Kits/10/bin/10.0.26100.0/x64')
cert = root/'zig-out/vista/usb-test-package'
env = dict(os.environ, TEMP=str(out), TMP=str(out))
def run(args):
    r = subprocess.run([str(a) for a in args], cwd=package, env=env, capture_output=True)
    with (out/'signing.log').open('ab') as f: f.write(r.stdout+r.stderr)
    if r.returncode: raise RuntimeError((r.stdout+r.stderr).decode(errors='replace'))
run([sdk/'signtool.exe','sign','/f',cert/'local-test.pfx','/fd','sha1',package/'xhci98.sys'])
(package/'xhci98.cdf').write_text('[CatalogHeader]\nName=xhci98.cat\nResultDir=.\\\nPublicVersion=0x00000001\nEncodingType=0x00010001\n[CatalogFiles]\n<HASH>xhci98.inf=xhci98.inf\n<HASH>xhci98.sys=xhci98.sys\n')
run([sdk/'makecat.exe','/v','xhci98.cdf'])
run([sdk/'signtool.exe','sign','/f',cert/'local-test.pfx','/fd','sha1',package/'xhci98.cat'])
run([Path('C:/Program Files/Git/usr/bin/openssl.exe'),'smime','-verify','-binary','-inform','DER','-in',package/'xhci98.cat','-CAfile',cert/'local-test.pem','-purpose','any','-out',out/'catalog-content.der'])
manifest = {'upstream': 'https://github.com/yeokm1/xhci98', 'revision': revision, 'version':'1.1.0.0', 'modified':'CatalogFile and local test signature; target hardware untested', 'sha256':{}}
for p in (*source.iterdir(), *package.glob('*.sys'), *package.glob('*.inf'), *package.glob('*.cat')):
    manifest['sha256'][str(p.relative_to(out))] = hashlib.sha256(p.read_bytes()).hexdigest()
(out/'manifest.json').write_text(json.dumps(manifest, indent=2))
print('XHCI98_X64_PREPARED revision='+revision+'; signed with existing project test key; host trust unchanged')
