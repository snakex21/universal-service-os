#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Read only four bounded Panther logs, not a Windows tree or mounted volume."""
import hashlib
from pathlib import Path
import inspect_ntfs as nt

MAX_LOG_BYTES=32*1024**2
LOGS=('Windows/Panther/setupact.log','Windows/Panther/setuperr.log',
      'Windows/Panther/UnattendGC/setupact.log','Windows/Panther/UnattendGC/setuperr.log')


def names(record):
    for attr in nt.attributes(record):
        if attr['kind']!=0x30:continue
        value=nt.resident(attr['data'])
        if len(value)<66 or 66+2*value[64]>len(value):raise ValueError('Malformed log FILE_NAME')
        if value[65]==2:continue
        yield value[66:66+2*value[64]].decode('utf-16le'),nt.number(value,0,8)


def stream_parts(image,number):
    record=image.record(number)
    attrs=list(nt.attributes(record))
    selected=[a for a in attrs if a['kind']==0x80 and not a['name']]
    lists=[a for a in attrs if a['kind']==0x20]
    visited={number}
    if len(lists)>1:raise ValueError('Ambiguous log ATTRIBUTE_LIST')
    if lists:
        for entry in image.list_entries(image.attr_value(lists[0]['data'])):
            target=entry['reference']&0xffffffffffff
            if entry['kind']!=0x80 or entry['name'] or target==number:continue
            if target in visited or len(visited)>=256:raise ValueError('Repeated/oversized log continuation')
            visited.add(target);extension=image.record(target)
            if nt.number(extension,32,8)&0xffffffffffff!=number or nt.number(extension,16,2)!=entry['reference']>>48:
                raise ValueError('Stale log continuation identity')
            match=[a for a in nt.attributes(extension) if a['kind']==0x80 and not a['name'] and a['lowest']==entry['lowest'] and a['id']==entry['id']]
            if len(match)!=1:raise ValueError('Missing exact log continuation')
            selected.extend(match)
    selected.sort(key=lambda a:a['lowest'])
    if not selected or any(nt.number(a['data'],12,2)!=0 for a in selected):raise ValueError('Missing or unsupported compressed/sparse log DATA')
    first=selected[0]['data']
    if not first[8]:
        if len(selected)!=1:raise ValueError('Ambiguous resident log')
        data=nt.resident(first)
        return len(data),len(data),None,data
    mapped=[run for attr in selected for run in nt.runs(attr['data'])]
    image.validate_runs(mapped,nt.number(first,40,8))
    size,initialized=nt.number(first,48,8),nt.number(first,56,8)
    if initialized>size or any(lcn is None for _,_,lcn in mapped):raise ValueError('Invalid log initialization/allocation')
    return size,initialized,mapped,None


def collect(reader,partition,out):
    if out.exists():raise ValueError('Fresh log-only output required')
    image=nt.Image(None,file=reader,partition_start=partition['start'],partition_bytes=partition['bytes'])
    attrs=[a for a in nt.attributes(image.zero) if a['kind']==0xb0 and not a['name']]
    if len(attrs)!=1 or image.mft_bytes//1024>1_000_000:raise ValueError('Bounded complete MFT bitmap required')
    bitmap=image.attr_value(attrs[0]['data'])
    dirs={5:('',None,nt.number(image.record(5),16,2))};files=[]
    for number in range(image.mft_bytes//1024):
        if number//8>=len(bitmap):raise ValueError('Truncated MFT allocation bitmap')
        if not bitmap[number//8]&(1<<(number%8)):continue
        record=image.record(number)
        if nt.number(record,32,8) or not nt.number(record,22,2)&1:continue
        isdir=bool(nt.number(record,22,2)&2)
        for name,parent in names(record):
            folded=name.casefold()
            if isdir and folded in ('windows','panther','unattendgc'):
                if len(dirs)>256:raise ValueError('Excessive Panther directory candidates')
                dirs[number]=(name,parent,nt.number(record,16,2))
            elif not isdir and folded in ('setupact.log','setuperr.log'):
                if len(files)>=1024:raise ValueError('Excessive named log candidates')
                files.append((number,name,parent))
    def path_of(number,seen):
        if number==5:return ''
        if number in seen or len(seen)>=4 or number not in dirs:return None
        name,parent,_=dirs[number];parent_number=parent&0xffffffffffff
        if parent_number not in dirs or dirs[parent_number][2]!=parent>>48:return None
        prefix=path_of(parent_number,seen|{number})
        return None if prefix is None else (prefix+'/'+name).lstrip('/')
    wanted={p.casefold():p for p in LOGS};selected={}
    for number,name,parent in files:
        parent_number=parent&0xffffffffffff
        if parent_number not in dirs or dirs[parent_number][2]!=parent>>48:continue
        path=path_of(parent_number,set())
        folded=(path+'/'+name).casefold() if path is not None else ''
        if folded in wanted:
            if folded in selected:raise ValueError('Ambiguous duplicate Panther log path')
            selected[folded]=number
    out.mkdir(parents=True)
    result=[];total=0
    for folded,number in sorted(selected.items()):
        size,initialized,mapped,resident=stream_parts(image,number)
        if size>MAX_LOG_BYTES-total:raise ValueError('Total Panther log content exceeds32MiB')
        path=out/Path(wanted[folded]);path.parent.mkdir(parents=True,exist_ok=True)
        sha=hashlib.sha256();cursor=0
        with path.open('xb') as output:
            while cursor<size:
                take=min(65536,size-cursor)
                valid=min(take,max(0,initialized-cursor))
                data=(resident[cursor:cursor+valid] if resident is not None else image.stream(mapped,cursor,valid)) if valid else b''
                data+=bytes(take-valid);output.write(data);sha.update(data);cursor+=take
        total+=size;result.append(dict(path=wanted[folded],record=number,bytes=size,sha256=sha.hexdigest()))
    return dict(schema='minios-firstboot-panther-logs-v1',files=result,missing=[p for p in LOGS if p.casefold() not in selected],
                content_bytes=total,byte_limit=MAX_LOG_BYTES,full_tree_extracted=False,windows_success_judged=False)
