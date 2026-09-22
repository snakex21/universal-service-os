"""Create a local-test catalog copy; preserve all original INF/SYS bytes.

No host certificate stores are modified. The private key stays in the project.
"""
from pathlib import Path
import hashlib,json,os,shutil,subprocess,datetime
from cryptography import x509
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.primitives.serialization import Encoding
root=Path(__file__).resolve().parents[1]
source=root/'zig-out/vista/community-usb/driver'
out=root/'zig-out/vista/local-catalog';out.mkdir(parents=True,exist_ok=True)
driver=out/'driver';driver.mkdir(exist_ok=True)
keys=out/'keys-v10';keys.mkdir(exist_ok=True)
sdk=Path('C:/Program Files (x86)/Windows Kits/10/bin/10.0.26100.0/x64')
openssl=Path('C:/Program Files/Git/usr/bin/openssl.exe')
env=dict(os.environ,TEMP=str(out),TMP=str(out))
def run(args):
 result=subprocess.run([str(a) for a in args],env=env,cwd=out,capture_output=True)
 with (out/'prepare.log').open('ab') as log:log.write(result.stdout+result.stderr)
 if result.returncode:raise RuntimeError((result.stdout+result.stderr).decode(errors='replace'))
(keys/'publisher.ext').write_text('basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=codeSigning\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n')
if not (keys/'root.pem').exists():
 run([openssl,'req','-x509','-newkey','rsa:2048','-nodes','-sha1','-days','3650','-subj','/CN=USOS Vista Local Test CA v10','-addext','basicConstraints=critical,CA:TRUE,pathlen:0','-addext','keyUsage=critical,keyCertSign,cRLSign','-keyout',keys/'root.key','-out',keys/'root.pem'])
if not (keys/'publisher.pem').exists():
 run([openssl,'req','-new','-newkey','rsa:2048','-nodes','-subj','/CN=USOS Vista USB Test Publisher v10','-keyout',keys/'publisher.key','-out',keys/'publisher.csr'])
 run([openssl,'x509','-req','-in',keys/'publisher.csr','-CA',keys/'root.pem','-CAkey',keys/'root.key','-set_serial','0x'+os.urandom(16).hex(),'-days','1825','-sha1','-extfile',keys/'publisher.ext','-out',keys/'publisher.pem'])
anchor=x509.load_pem_x509_certificate((keys/'root.pem').read_bytes())
cert=x509.load_pem_x509_certificate((keys/'publisher.pem').read_bytes())
assert anchor.subject==anchor.issuer and cert.issuer==anchor.subject and cert.subject!=anchor.subject
assert anchor.extensions.get_extension_for_class(x509.BasicConstraints).value.ca
assert anchor.extensions.get_extension_for_class(x509.KeyUsage).value.key_cert_sign
bc=cert.extensions.get_extension_for_class(x509.BasicConstraints).value
ku=cert.extensions.get_extension_for_class(x509.KeyUsage).value
assert not bc.ca and bc.path_length is None and ku.digital_signature and not ku.key_cert_sign
assert cert.not_valid_before_utc<datetime.datetime.now(datetime.timezone.utc)<cert.not_valid_after_utc
anchor.public_key().verify(anchor.signature,anchor.tbs_certificate_bytes,padding.PKCS1v15(),anchor.signature_hash_algorithm)
anchor.public_key().verify(cert.signature,cert.tbs_certificate_bytes,padding.PKCS1v15(),cert.signature_hash_algorithm)
assert x509.oid.ExtendedKeyUsageOID.CODE_SIGNING in cert.extensions.get_extension_for_class(x509.ExtendedKeyUsage).value
run([openssl,'pkcs12','-export','-inkey',keys/'publisher.key','-in',keys/'publisher.pem','-certfile',keys/'root.pem','-out',keys/'publisher.pfx','-passout','pass:','-keypbe','PBE-SHA1-3DES','-certpbe','PBE-SHA1-3DES','-macalg','sha1'])
files=['USBXHCI.inf','USBXHCI.cat','usbxhci.sys','usbhub3.sys','ucx01000.sys','usbd8.sys']
for name in files:shutil.copyfile(source/name,driver/name)
run([sdk/'signtool.exe','sign','/f',keys/'publisher.pfx','/fd','sha1',driver/'USBXHCI.cat'])
# Verify the new signature with only our pinned certificate, not host trust.
run([openssl,'smime','-verify','-binary','-inform','DER','-in',driver/'USBXHCI.cat','-CAfile',keys/'root.pem','-purpose','any','-out',out/'local-content.der'])
# Original catalog was separately verified with SignTool; extract its content
# to assert that all member hashes and catalog attributes survived re-signing.
run([openssl,'smime','-verify','-binary','-inform','DER','-in',source/'USBXHCI.cat','-noverify','-out',out/'original-content.der'])
assert (out/'local-content.der').read_bytes()==(out/'original-content.der').read_bytes(),'Catalog contents changed'
for name in files:
 if name.endswith(('.inf','.sys')):assert (source/name).read_bytes()==(driver/name).read_bytes(),name
der=cert.public_bytes(Encoding.DER);(out/'publisher.cer').write_bytes(der)
root_der=anchor.public_bytes(Encoding.DER);(out/'root.cer').write_bytes(root_der)
header='static const BYTE local_cert[]={'+','.join(str(b) for b in der)+'};\n'
header+='static const BYTE local_root[]={'+','.join(str(b) for b in root_der)+'};\n'
header+='static const struct {const BYTE *data; DWORD length; const WCHAR *store;} community_certs[]={\n{local_root,sizeof(local_root),L"ROOT"},{local_cert,sizeof(local_cert),L"TrustedPublisher"}};\n'
(root/'zig-out/vista/community-usb/vista_local_certs.h').write_text(header)
manifest={'purpose':'Local Intel Vista trial; not vendor/WHQL signing','version':10,'publisher_ca':False,'root_certificate_sha256':anchor.fingerprint(hashes.SHA256()).hex(),'certificate_sha256':cert.fingerprint(hashes.SHA256()).hex(),'catalog_content_sha256':hashlib.sha256((out/'local-content.der').read_bytes()).hexdigest(),'files':{name:hashlib.sha256((driver/name).read_bytes()).hexdigest() for name in files}}
(out/'manifest.json').write_text(json.dumps(manifest,indent=2))
print('V10_ROOT_CA_AND_DISTINCT_PUBLISHER_CA_FALSE; LOCAL_CATALOG_SIGNATURE_VALID; CATALOG_CONTENT_UNCHANGED; ALL_INF_SYS_BYTES_UNCHANGED; HOST_TRUST_UNCHANGED')
