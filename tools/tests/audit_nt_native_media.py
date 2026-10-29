# SPDX-License-Identifier: GPL-3.0-or-later
"""Original CD audit; decompressed Microsoft files exist only in RAM.

7-Zip's bounded compressed input is briefly placed in ignored artifacts,
not outputs. No application/configuration/product-key files are read.
"""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import io
import json
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools'));sys.path.insert(0,str(ROOT/'tools/tests'))
import nt31_native_source as source
from windows_media_facts import ISO
from check_nt52_driver_imports import pe

class MemoryFile:
    def __init__(self,data):self.data=data
    def read_bytes(self):return self.data

def sha(data):return hashlib.sha256(data).hexdigest()

def main():
    p=argparse.ArgumentParser();p.add_argument('--ws',type=Path,required=True);p.add_argument('--advanced',type=Path,required=True)
    p.add_argument('--nt4',type=Path,required=True);p.add_argument('--out',type=Path,required=True)
    p.add_argument('--seven',type=Path,required=True);p.add_argument('--shell',type=Path,required=True)
    a=p.parse_args();result={};scratch=ROOT/'artifacts/native-media';scratch.mkdir(parents=True,exist_ok=True)
    def independent(blob):
        if not blob.startswith((b'SZDD',b'MSCF')):return blob
        with tempfile.TemporaryDirectory(dir=scratch) as tmp:
            packed=Path(tmp)/'input.cab';packed.write_bytes(blob)
            r=subprocess.run([str(a.seven),'x','-so',str(packed)],capture_output=True,timeout=60,check=True)
            return r.stdout
    for tag,path in (('nt31-ws',a.ws),('nt31-as',a.advanced),('nt4-ws',a.nt4)):
        if path.suffix.lower()=='.iso': raw=path.read_bytes()
        else: raw=subprocess.run([str(a.seven),'e','-so',str(path),'*.iso','-r'],capture_output=True,timeout=120,check=True).stdout
        v=ISO(io.BytesIO(raw));row={'source_name':path.name,'source_sha256':sha(path.read_bytes()),'iso_sha256':sha(raw),'files':{},'modules':{}}
        def get(leaf):
            for name in ('i386/'+leaf,'i386/'+leaf[:-1]+'_'):
                if name in v.entries:return name,v.read(name)
            return None,None
        for name in sorted(v.entries):
            if name.startswith('i386/') and not v.entries[name][2] and name.rsplit('/',1)[-1].startswith('setupldr'):
                blob=v.read(name);row['files'][name]={'sha256':sha(blob),'size':len(blob),'prefix':blob[:14].hex(),
                    'maxmem_ascii':b'MAXMEM' in blob.upper(),
                    'ah88_sequences':[i for i in range(len(blob)) if blob[i:i+4]==b'\xb4\x88\xcd\x15'],
                    'e801_sequences':[i for i in range(len(blob)) if blob[i:i+5]==b'\xb8\x01\xe8\xcd\x15']}
        for kind,leaf in (('initial','initial.inf'),('hardware','hardware.inf'),('ntlanman','ntlanman.inf'),('oemnadlb','oemnadlb.inf')):
            name,blob=get(leaf)
            if blob is None:continue
            data=independent(blob)
            info={'sha256':sha(blob),'decoded_sha256':sha(data),'prefix':blob[:14].hex(),'size':len(blob),'decoded_size':len(data)}
            if tag.startswith('nt31'):
                ours=source.unpack(blob) if blob.startswith(b'SZDD') else blob
                if ours!=data:raise ValueError('SZDD mismatch against 7-Zip: '+name)
                info['szdd_matches_7zip']=True
                if kind in ('initial','hardware') or tag=='nt31-as':
                    patched=source.patch(blob,kind,advanced=tag=='nt31-as',nvme=True,shell=a.shell)
                    unpacked=source.unpack(patched) if patched.startswith(b'SZDD') else patched
                    if independent(patched)!=unpacked:raise ValueError('Patched source mismatch against 7-Zip')
                    info.update(patched_sha256=sha(patched),patched_decoded_sha256=sha(unpacked),patched_7zip_match=True,
                        copied_microsoft_output=False)
            row['files'][name]=info
        for leaf in ('ntoskrnl.exe','hal.dll','ndis.sys','kernel32.dll','advapi32.dll','user32.dll'):
            name,blob=get(leaf)
            if blob is None:continue
            data=independent(blob);exports,_=pe(MemoryFile(data))
            row['modules'][leaf]={'sha256':sha(data),'source':name,'exports':exports}
        result[tag]=row
    a.out.write_text(json.dumps(result,indent=2,sort_keys=True)+'\n',encoding='utf-8')
    print(json.dumps({'media':len(result),'source_files':sum(len(v['files']) for v in result.values()),'copied_microsoft_outputs':0}))

if __name__=='__main__':main()
