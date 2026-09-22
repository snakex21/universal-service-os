"""Create an explicitly local test-signed copy; never change vendor originals."""
from pathlib import Path
import subprocess,os,shutil,hashlib,json,struct
ROOT=Path(__file__).resolve().parents[1]
out=ROOT/'zig-out/vista/usb-test-package'
out.mkdir(parents=True,exist_ok=True)
sdk=Path('C:/Program Files (x86)/Windows Kits/10/bin/10.0.26100.0/x64')
openssl=Path('C:/Program Files/Git/usr/bin/openssl.exe')
env=dict(os.environ,TEMP=str(out),TMP=str(out))
def run(args,cwd=out):
 r=subprocess.run([str(a) for a in args],cwd=cwd,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 with (out/'build.log').open('ab') as f:f.write(r.stdout)
 if r.returncode:raise RuntimeError(r.stdout.decode(errors='replace'))
if not (out/'local-test.key').exists():
 run([openssl,'req','-x509','-newkey','rsa:2048','-nodes','-sha1','-days','3650','-subj','/CN=USOS Vista USB Local Test Only','-addext','extendedKeyUsage=codeSigning','-addext','keyUsage=digitalSignature,keyCertSign','-keyout','local-test.key','-out','local-test.pem'])
run([openssl,'x509','-in','local-test.pem','-outform','DER','-out','usos-vista-usb-test.cer'])
run([openssl,'pkcs12','-export','-inkey','local-test.key','-in','local-test.pem','-out','local-test.pfx','-passout','pass:','-keypbe','PBE-SHA1-3DES','-certpbe','PBE-SHA1-3DES','-macalg','sha1'])
source=ROOT/'media/Systems/Windows/Windows Vista/Drivers/x64/AMD_USB31_PT'
target=out/'AMD_USB31_PT';shutil.copytree(source,target,dirs_exist_ok=True)
def payload(path):
 d=bytearray(path.read_bytes());pe=struct.unpack_from('<I',d,0x3c)[0];opt=pe+24
 certpos=opt+112+8*4;offset,size=struct.unpack_from('<II',d,certpos)
 d[opt+64:opt+68]=b'\0'*4;d[certpos:certpos+8]=b'\0'*8
 if offset:del d[offset:offset+size]
 return bytes(d)
manifest={'purpose':'Local Vista experiment, not vendor-certified Vista support','files':{}}
for name,folder in [('amdhub31','Hub'),('amdxhc31','Host')]:
 p=target/folder;driver=p/'x64'/f'{name}.sys';before=payload(driver)
 run([sdk/'signtool.exe','sign','/f',out/'local-test.pfx','/fd','sha1',driver])
 assert payload(driver)==before,'Executable payload changed beyond signature/checksum'
 cdf=p/'local-test.cdf'
 cdf.write_text('[CatalogHeader]\nName='+name+'.cat\nResultDir=.\\\nPublicVersion=0x00000001\nEncodingType=0x00010001\n[CatalogFiles]\n<HASH>'+name+'.inf='+name+'.inf\n<HASH>'+name+'.sys=x64\\'+name+'.sys\n',encoding='ascii')
 # Replaces only the copied catalog, not the vendor source package.
 (p/f'{name}.cat').unlink()
 run([sdk/'makecat.exe','/v',cdf.name],p)
 run([sdk/'signtool.exe','sign','/f',out/'local-test.pfx','/fd','sha1',p/f'{name}.cat'])
 run([openssl,'smime','-verify','-binary','-inform','DER','-in',p/f'{name}.cat','-CAfile',out/'local-test.pem','-purpose','any','-out',out/(name+'-verified-content.der')])
 for file in [p/f'{name}.inf',driver,p/f'{name}.cat']:
  manifest['files'][str(file.relative_to(out))]=hashlib.sha256(file.read_bytes()).hexdigest()
 # Verify membership plus cryptographic signature using the pinned leaf root;
 # the test root is deliberately not added to the host certificate store.
 for file in [p/f'{name}.inf',driver]:
  r=subprocess.run([str(sdk/'signtool.exe'),'verify','/pa','/v','/c',str(p/f'{name}.cat'),str(file)],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
  (out/(name+'-'+file.suffix[1:]+'-verify.txt')).write_bytes(r.stdout)
  assert b'certificate which is not trusted by the trust provider' in r.stdout or r.returncode==0,'Unexpected signature validation failure'
print('TEST_PACKAGE_PREPARED; DRIVER_EXECUTABLE_PAYLOADS_UNCHANGED; HOST_TRUST_STORE_UNCHANGED')
(out/'manifest.json').write_text(json.dumps(manifest,indent=2))
der=(out/'usos-vista-usb-test.cer').read_bytes()
(out/'usb_test_cert.h').write_text('static const unsigned char usb_test_cert[]={'+','.join(str(x) for x in der)+'};\n',encoding='ascii')
