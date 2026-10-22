"""Read-only file inventory; no Windows binaries or product keys are emitted.

Only the OS library and the explicitly allowed G: collection are traversed.
The second inventory pass reuses a digest only for unchanged size/mtime.
"""
from pathlib import Path
import argparse
import concurrent.futures
import hashlib
import json
import os
import subprocess
import time

LIBRARY=Path(r'C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows')
COLLECTION=Path(r'G:\USOS-Kolekcja')
SUFFIXES={'.iso','.img','.7z','.zip'}


def files():
    for root in (LIBRARY,COLLECTION):
        if not root.exists():continue
        for directory,dirs,names in os.walk(root):
            if root==COLLECTION:
                dirs[:]=[name for name in dirs if not name.startswith('_') and name not in ('MacOS','macOS','Apple')]
            for name in names:
                p=Path(directory)/name
                if p.suffix.lower() in SUFFIXES:yield root,p


def main(a):
    previous={}
    if a.previous:
        previous={r['path']:r for r in json.loads(a.previous.read_text(encoding='utf-8'))['files']}
    def inspect(pair):
        root,p=pair;s=p.stat();old=previous.get(str(p))
        if old and old['bytes']==s.st_size and old['mtime_ns']==s.st_mtime_ns:
            return old
        with p.open('rb') as stream:digest=hashlib.file_digest(stream,'sha256').hexdigest()
        row=dict(root=str(root),path=str(p),relative=str(p.relative_to(root)),bytes=s.st_size,
                 mtime_ns=s.st_mtime_ns,sha256=digest,beta='Betas' in p.parts)
        if a.probe and p.suffix.lower()=='.iso' and not row['beta']:
            r=subprocess.run([str(a.probe),str(p)],capture_output=True,text=True,errors='replace',timeout=120)
            row['usos_optical_probe']={'exit':r.returncode,'output':r.stdout+r.stderr}
        return row
    start=time.monotonic()
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        rows=list(pool.map(inspect,sorted(files(),key=lambda x:str(x[1]))))
    result=dict(timestamp=time.strftime('%Y-%m-%dT%H:%M:%S%z'),files=rows,
                seconds=round(time.monotonic()-start,2),scope='read-only, beta content not probed')
    a.out.parent.mkdir(parents=True,exist_ok=True)
    a.out.write_text(json.dumps(result,indent=2,ensure_ascii=False),encoding='utf-8')
    print(json.dumps({'files':len(rows),'bytes':sum(r['bytes'] for r in rows),'seconds':result['seconds']}))


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--out',type=Path,required=True)
    p.add_argument('--previous',type=Path)
    p.add_argument('--probe',type=Path)
    main(p.parse_args())
