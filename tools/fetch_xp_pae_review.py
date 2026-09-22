"""Fetch pinned upstream sources for review only; execute nothing."""
from pathlib import Path
import hashlib,json,urllib.request
root=Path(__file__).resolve().parents[1]
commit='3e1d3b65f5c3c1ec0c4759f707d3017e51113103'
out=root/'tools/vendor/patchpae3'/commit
files=['LICENSE','README.md','PatchPAE3/main.c','ScriptPAE/ScriptPAE3v26.cmd']
manifest={'repository':'https://github.com/evgen-b/PatchPAE3','commit':commit,'purpose':'source review; not executed or shipped','sha256':{}}
for name in files:
 url='https://raw.githubusercontent.com/evgen-b/PatchPAE3/'+commit+'/'+name
 with urllib.request.urlopen(url,timeout=30) as response:data=response.read()
 path=out/name;path.parent.mkdir(parents=True,exist_ok=True)
 if path.exists() and path.read_bytes()!=data:raise RuntimeError('Pinned source changed: '+name)
 path.write_bytes(data);manifest['sha256'][name]=hashlib.sha256(data).hexdigest()
(out/'manifest.json').write_text(json.dumps(manifest,indent=2))
print('SOURCE_REVIEW_ONLY',commit,manifest['sha256'])
