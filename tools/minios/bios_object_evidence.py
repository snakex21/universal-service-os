#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Read-only ELF32 object section evidence, before or after a failed link."""
import argparse
import hashlib
import json
from pathlib import Path
import struct


def analyze(blob):
    if len(blob)<52 or blob[:6]!=b'\x7fELF\x01\x01':raise ValueError('ELF32 little-endian required')
    offset=struct.unpack_from('<I',blob,32)[0]
    size,count,names_index=struct.unpack_from('<HHH',blob,46)
    if size!=40 or not count or names_index>=count or offset>len(blob) or count*size>len(blob)-offset:raise ValueError('Invalid ELF section table')
    headers=[struct.unpack_from('<10I',blob,offset+i*size) for i in range(count)]
    names_header=headers[names_index]
    if names_header[4]>len(blob) or names_header[5]>len(blob)-names_header[4]:raise ValueError('Invalid ELF strings')
    names=blob[names_header[4]:names_header[4]+names_header[5]]
    rows=[]
    for header in headers:
        if not header[2]&2:continue
        if header[0]>=len(names):raise ValueError('ELF name offset')
        end=names.find(b'\0',header[0])
        if end<0:raise ValueError('ELF name terminator')
        name=names[header[0]:end].decode('utf8')
        row=dict(name=name,size=header[5],flags=header[2],alignment=header[8])
        if name=='.rodata':
            data=blob[header[4]:header[4]+header[5]]
            row['zero_bytes']=data.count(0)
        rows.append(row)
    return dict(object_sha256=hashlib.sha256(blob).hexdigest(),total_allocated_object_bytes=sum(r['size'] for r in rows),
                sections_before_link_gc=struct.unpack_from('<H',blob,16)[0]==1,largest=sorted(rows,key=lambda r:r['size'],reverse=True)[:30],
                by_kind={prefix:sum(r['size'] for r in rows if r['name'].startswith(prefix)) for prefix in ('.text','.rodata','.data','.bss')})


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--object',type=Path,required=True);parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args()
    if not args.object.is_file() or args.object.stat().st_size>256*1024*1024:raise ValueError('Bounded regular object required')
    result=analyze(args.object.read_bytes())
    with args.out.open('x',encoding='utf8') as output:json.dump(result,output,indent=2);output.write('\n')
    print(json.dumps(result))


if __name__=='__main__':main()
