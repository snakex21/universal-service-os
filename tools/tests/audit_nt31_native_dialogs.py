# SPDX-License-Identifier: GPL-3.0-or-later
"""Read-only original NT31 dialog-ID evidence, no extracted binaries."""
from pathlib import Path
import argparse,hashlib,io,json,struct,subprocess,sys
import pefile
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools'))
from windows_media_facts import ISO
from nt31_native_source import unpack

def field(data,offset):
    if offset+2>len(data):raise ValueError('Truncated dialog')
    value=int.from_bytes(data[offset:offset+2],'little');offset+=2
    if not value:return '',offset
    if value==65535:return '#'+str(int.from_bytes(data[offset:offset+2],'little')),offset+2
    start=offset-2
    while offset+2<=len(data) and int.from_bytes(data[offset:offset+2],'little'):offset+=2
    if offset+2>len(data):raise ValueError('Truncated dialog string')
    return data[start:offset].decode('utf-16le'),offset+2

def main():
    p=argparse.ArgumentParser();p.add_argument('--source',type=Path,action='append',required=True)
    p.add_argument('--seven',required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args();result={}
    for path in a.source:
        raw=subprocess.run([a.seven,'e','-so',str(path),'*.iso','-r'],capture_output=True,timeout=120,check=True).stdout
        iso=ISO(io.BytesIO(raw));row={}
        for leaf,title in (('main.cp_','Date/Time'),('ncpa.cp_','Domain Settings')):
            blob=unpack(iso.read('i386/'+leaf));image=pefile.PE(data=blob);matches=[]
            for kind in image.DIRECTORY_ENTRY_RESOURCE.entries:
                if kind.id!=5:continue
                for name in kind.directory.entries:
                    for lang in name.directory.entries:
                        data=image.get_data(lang.data.struct.OffsetToData,lang.data.struct.Size)
                        style,_,count,_,_,_,_=struct.unpack_from('<IIHhhhh',data);offset=18
                        _,offset=field(data,offset);_,offset=field(data,offset);caption,offset=field(data,offset)
                        if style&64:_,offset=field(data,offset+2)
                        controls={}
                        for _ in range(count):
                            offset=(offset+3)&~3
                            _,_,_,_,_,_,cid=struct.unpack_from('<IIhhhhH',data,offset);offset+=18
                            cls,offset=field(data,offset);_,offset=field(data,offset)
                            extra=int.from_bytes(data[offset:offset+2],'little');offset+=2+extra
                            controls[cid]=cls
                        if caption==title:matches.append({'id':name.id,'title':caption,'controls':controls})
            if len(matches)!=1:raise ValueError('Ambiguous original dialog')
            row[leaf]={'sha256':hashlib.sha256(blob).hexdigest(),'dialog':matches[0]}
        result[path.name]={'iso_sha256':hashlib.sha256(raw).hexdigest(),'modules':row}
    a.out.write_text(json.dumps(result,indent=2)+'\n');print('Original dialog tables: '+str(len(result)))
if __name__=='__main__':main()
