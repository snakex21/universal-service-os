"""Cache upstream source solely for inspection of the photographed dump fault."""
from pathlib import Path
import urllib.request, json
root=Path(__file__).resolve().parents[1]
out=root/'artifacts/xp-pae/ntoskrn8-source-inspection'
out.mkdir(exist_ok=True)
api='https://api.github.com/repos/MovAX0xDEAD/NTOSKRNL_Emu/git/trees/master?recursive=1'
tree=json.load(urllib.request.urlopen(api,timeout=30))
(out/'tree.json').write_text(json.dumps(tree))
for item in tree['tree']:
    name=item['path']
    if not name.endswith(('.c','.cpp','.h')): continue
    data=urllib.request.urlopen('https://raw.githubusercontent.com/MovAX0xDEAD/NTOSKRNL_Emu/'+tree['sha']+'/'+name,timeout=30).read()
    p=out/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data)
    for number,line in enumerate(data.decode('utf-8',errors='replace').splitlines(),1):
        if any(term in line for term in ('DllInitialize','gDumpMode','FindPattern','PatternScan')):
            print(name,number,line)
