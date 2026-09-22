"""Pin downloaded Microsoft CAB and original third-party signing certificates."""
from pathlib import Path
import hashlib,json
from cryptography import x509
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.primitives.serialization import pkcs7,Encoding
root=Path(__file__).resolve().parents[1];out=root/'zig-out/vista/community-usb'
cab=out/'kb/Windows6.0-KB2864202-x64.cab'
digest=hashlib.sha256(cab.read_bytes()).digest()
(out/'vista_kmdf_cab_hash.h').write_text('static const BYTE expected[32]={'+','.join(str(b) for b in digest)+'};\n')
certs=pkcs7.load_der_pkcs7_certificates((out/'driver/USBXHCI.cat').read_bytes())
root_data=(out/'DigiCertAssuredIDRootCA.crt').read_bytes()
root_sha256='3e9099b5015e8f486c00bcea9d111ee721faba355a89bcf1df69561e3dc6325c'
assert hashlib.sha256(root_data).hexdigest()==root_sha256,'Official DigiCert root hash mismatch'
anchor=x509.load_der_x509_certificate(root_data)
assert anchor.subject==anchor.issuer and anchor.extensions.get_extension_for_class(x509.BasicConstraints).value.ca
anchor.public_key().verify(anchor.signature,anchor.tbs_certificate_bytes,padding.PKCS1v15(),anchor.signature_hash_algorithm)
selected=[(anchor,'ROOT')]
for name,store in [('Riolin Limited','TrustedPublisher'),('DigiCert SHA2 Assured ID Code Signing CA','CA'),('DigiCert Assured ID Root CA','CA'),('DigiCert Assured ID CA-1','CA')]:
 cert=next(c for c in certs if c.subject.rfc4514_string().split(',')[0]=='CN='+name)
 selected.append((cert,store))
# Verify issuer signatures for both catalog signing and timestamp chains.
# This checks the bytes/chain, not Vista's runtime Authenticode policy.
for cert in certs:
 if cert.subject==anchor.subject: continue # Microsoft cross-certificate is not a trust anchor.
 issuer=next(c for c in [anchor]+certs if c.subject==cert.issuer)
 issuer.public_key().verify(cert.signature,cert.tbs_certificate_bytes,padding.PKCS1v15(),cert.signature_hash_algorithm)
text=''
for i,(cert,store) in enumerate(selected):
 text+='static const unsigned char community_cert_'+str(i)+'[]={'+','.join(str(b) for b in cert.public_bytes(Encoding.DER))+'};\n'
text+='static const struct {const BYTE *data; DWORD length; const WCHAR *store;} community_certs[]={\n'
text+=',\n'.join('{community_cert_'+str(i)+',sizeof(community_cert_'+str(i)+'),L"'+store+'"}' for i,(c,store) in enumerate(selected))+'};\n'
(out/'vista_community_certs.h').write_text(text)
manifest=json.loads((out/'sources.json').read_text());manifest['github_revision']=json.loads((out/'github-tree.json').read_text())['sha']
manifest['driver_repository']='https://github.com/marie-systems/win7-sp2/tree/main/patches/drivers/USB3/XHCI/x64'
manifest['cab_sha256']=digest.hex();manifest['driver_files']=json.loads((out/'files-sha256.json').read_text())
manifest['root_certificate']={'url':'https://cacerts.digicert.com/DigiCertAssuredIDRootCA.crt','sha256':root_sha256,'store':'ROOT'}
manifest['certificates']=[{'subject':c.subject.rfc4514_string(),'store':s,'sha256':hashlib.sha256(c.public_bytes(Encoding.DER)).hexdigest()} for c,s in selected]
(out/'deployment-manifest.json').write_text(json.dumps(manifest,indent=2))
print('COMMUNITY_PACKAGE_HEADERS_READY; original driver files retained unchanged')
