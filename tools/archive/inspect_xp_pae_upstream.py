"""Read upstream file inventory; save provenance locally, do not execute downloads."""
from pathlib import Path
import json,urllib.request
root=Path(__file__).resolve().parents[1];out=root/'artifacts/xp-pae/research';out.mkdir(parents=True,exist_ok=True)
def fetch(url):
 with urllib.request.urlopen(urllib.request.Request(url,headers={'User-Agent':'USOS-source-review'}),timeout=30) as r:return r.read()
repo='https://api.github.com/repos/evgen-b/PatchPAE3'
commit=json.loads(fetch(repo+'/commits/master'))['sha']
tree=json.loads(fetch(repo+'/git/trees/'+commit+'?recursive=1'))
(out/'upstream-tree.json').write_text(json.dumps({'commit':commit,'tree':tree},indent=2))
print('COMMIT',commit)
for item in tree['tree']:
 if item['type']=='blob':print(item['path'],item.get('size'))
