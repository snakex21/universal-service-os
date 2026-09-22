"""Read-only comparison of the returned Intel with the last deployed repair."""
from pathlib import Path
import hashlib,json,sys,struct
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'tools/cache/registry-reader'))
from Registry import Registry
saved=Path((root/'zig-out/vista/winsat-snapshot-path.txt').read_text())
repair=json.loads((saved/'prepared/repair.json').read_text())
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
for name,expected in [('SYSTEM',repair['SYSTEM']),('SAM',repair['SAM']),('SOFTWARE',repair['prepared'])]:
 p=Path('M:/Windows/System32/config')/name;b=p.read_bytes()
 print(name,'identical_to_last_deployment='+str(sha(p)==expected),'sequence='+str(struct.unpack_from('<II',b,4)))
for relative in ['Windows/Panther/UnattendGC/setupact.log','Windows/Performance/WinSAT/winsat.log','USOS/usb-bootstrap.log','Windows/Panther/setupact.log']:
 p=Path('M:/')/relative;old=saved/relative
 print(relative,'unchanged='+str(p.exists() and old.exists() and sha(p)==sha(old)))
for name,key in [('SYSTEM','Setup'),('SYSTEM',r'Setup\Status\ChildCompletion'),('SOFTWARE',r'Microsoft\Windows\CurrentVersion\Setup\State')]:
 h=Registry.Registry('M:/Windows/System32/config/'+name)
 try:print(name,key,[(v.name(),v.value()) for v in h.open(key).values()])
 except Registry.RegistryKeyNotFoundException:print('absent',key)
sam=Registry.Registry('M:/Windows/System32/config/SAM')
print('Accounts:',[k.name() for k in sam.open(r'SAM\Domains\Account\Users\Names').subkeys()])
p=Path('M:/Windows/Panther/unattend.xml')
print('answer_identical_to_last_deployment='+str(sha(p)==repair['answer_prepared']))
