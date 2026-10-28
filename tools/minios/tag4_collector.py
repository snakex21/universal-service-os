#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Prototype read-only NTFS metadata collector: bounded, fail-closed helpers.

Uses the independent MiniOS host inspector, not the Zig writer. The caller
must supply a closed, deny-write-locked chain and a trusted logical reader.
See tag4-diff-notes.md. It does not mount NTFS or execute guest code.
"""
import argparse, contextlib, hashlib, json, os, struct, subprocess, sys, uuid, zlib
from pathlib import Path

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'tools'/'minios'))
import inspect_ntfs as nt
import wim_security_readonly as security
import install_native as native
import qcow_map_readonly as qcow
import wim_oracle as oracle

import tag4_diff as diff

MAX_META=32*1024*1024
MAX_ADS=8*1024*1024*1024
MAX_EVIDENCE=512*1024*1024

# Strict VHDX preflight: the local ReactOS-derived VHDX layout in
# doors/LiberNT-main-nt10/modules/rosv/include/rosv/vhdx.h describes the two
# headers, region and metadata entries, and the HasParent flag. The parser
# intentionally accepts only a small, closed, clean, non-differencing subset.
_VHDX_META=uuid.UUID('8b7ca206-4790-4b9a-b8fe-575f050f886e').bytes_le
_VHDX_BAT=uuid.UUID('2dc27766-f623-4200-9d64-115e9bfd4a08').bytes_le
_VHDX_PARAMS=uuid.UUID('caa16737-fa36-4d43-b3b6-33f0aa44e76b').bytes_le
_VHDX_SIZE=uuid.UUID('2fa54224-cd1b-4876-b211-5dbed83bf4b8').bytes_le
_VHDX_PARENT=uuid.UUID('a8d35f2d-b30b-454d-abf7-d3d84834ab0c').bytes_le
_VHDX_ITEMS={_VHDX_PARAMS,_VHDX_SIZE,*[uuid.UUID(x).bytes_le for x in (
    '8141bf1d-a96f-4709-ba47-f233a8faab5f',
    'cda348c7-445d-4471-9cc9-e9885251c556',
    'beca12ab-b2e6-4523-93ef-c309e000c746')]}

def _crc32c(data):
    crc=0xffffffff
    for byte in data:
        crc^=byte
        for _ in range(8):crc=(crc>>1)^(0x82f63b78 if crc&1 else 0)
    return crc^0xffffffff

def _vhdx_checksum(data):
    stored=struct.unpack_from('<I',data,4)[0]
    block=bytearray(data);block[4:8]=bytes(4)
    if _crc32c(block)!=stored:raise ValueError('VHDX checksum mismatch')

def validate_vhdx(file,virtual):
    """Before QEMU opens it, reject parents, dirty logs and ambiguous metadata.

    The file must already have a deny-write lock; this never opens a path.
    Both copies must be valid and region copies identical: unsupported but
    otherwise valid layouts fail closed. No claim about future file growth.
    """
    file.seek(0,2);size=file.tell()
    def at(off,n):
        if off<0 or n<0 or off>size or n>size-off:raise ValueError('VHDX structure outside file')
        file.seek(off);data=file.read(n)
        if len(data)!=n:raise ValueError('Short VHDX structure')
        return data
    if size<1024**2 or at(0,8)!=b'vhdxfile':raise ValueError('VHDX signature missing')
    logs=[]
    for offset in (65536,131072):
        h=at(offset,4096)
        if h[:4]!=b'head':raise ValueError('VHDX header signature')
        _vhdx_checksum(h)
        if h[48:64]!=bytes(16) or struct.unpack_from('<HH',h,64)!=(0,1):raise ValueError('VHDX dirty log or unsupported version')
        loglen,logoff=struct.unpack_from('<IQ',h,68)
        if loglen<1048576 or loglen%1048576 or logoff<1048576 or logoff%1048576 or logoff>size or loglen>size-logoff:raise ValueError('VHDX log bounds')
        logs.append((logoff,loglen))
    tables=[at(x,65536) for x in (196608,262144)]
    if tables[0]!=tables[1]:raise ValueError('VHDX region copies disagree')
    table=tables[0]
    if table[:4]!=b'regi':raise ValueError('VHDX region signature')
    _vhdx_checksum(table)
    count,reserved=struct.unpack_from('<II',table,8)
    if not 1<=count<=2047 or reserved:raise ValueError('VHDX region count')
    regions={};bounds=[]
    for i in range(count):
        guid=table[16+i*32:32+i*32];off,length,flags=struct.unpack_from('<QII',table,32+i*32)
        if guid not in (_VHDX_META,_VHDX_BAT) or guid in regions or flags not in (0,1) or off<1048576 or off%1048576 or not length or length%1048576 or off>size or length>size-off:raise ValueError('Unsupported VHDX region')
        if any(off<b+bl and b<off+length for b,bl in bounds+logs):raise ValueError('Overlapping VHDX regions or log')
        bounds.append((off,length));regions[guid]=(off,length)
    if set(regions)!={_VHDX_META,_VHDX_BAT}:raise ValueError('Required VHDX region missing')
    off,length=regions[_VHDX_META]
    if length<65536:raise ValueError('Short VHDX metadata')
    head=at(off,65536)
    if head[:8]!=b'metadata' or any(head[8:10]) or any(head[12:32]):raise ValueError('VHDX metadata signature')
    count=struct.unpack_from('<H',head,10)[0]
    if not 1<=count<=2047:raise ValueError('VHDX metadata count')
    entries={};used=[]
    for i in range(count):
        start=32+i*32;guid=head[start:start+16];pos,n,flags,reserved=struct.unpack_from('<IIII',head,start+16)
        if guid==_VHDX_PARENT or guid not in _VHDX_ITEMS or guid in entries or reserved or flags&~7 or pos<65536 or not 0<n<=16 or pos>length or n>length-pos:raise ValueError('Unsupported VHDX metadata or parent')
        if any(pos<b+bl and b<pos+n for b,bl in used):raise ValueError('Overlapping VHDX metadata')
        used.append((pos,n));entries[guid]=at(off+pos,n)
    if set(entries)!=_VHDX_ITEMS or len(entries[_VHDX_PARAMS])!=8 or len(entries[_VHDX_SIZE])!=8:raise ValueError('Required VHDX metadata missing')
    block,flags=struct.unpack('<II',entries[_VHDX_PARAMS]);vsize=struct.unpack('<Q',entries[_VHDX_SIZE])[0]
    if flags&~1 or not 1048576<=block<=268435456 or block&(block-1) or vsize!=virtual or vsize%512:raise ValueError('VHDX parent, block size or virtual size invalid')
    diskid=uuid.UUID('beca12ab-b2e6-4523-93ef-c309e000c746').bytes_le
    if len(entries[diskid])!=16:raise ValueError('VHDX disk ID length invalid')
    for guid in _VHDX_ITEMS-{_VHDX_PARAMS,_VHDX_SIZE,diskid}:
        if len(entries[guid])!=4 or struct.unpack('<I',entries[guid])[0] not in (512,4096):raise ValueError('VHDX sector size invalid')
    return {'size':vsize,'fixed_flag':bool(flags&1),'block_size':block}

def known(value): return {'known':True,'value':value}
def unknown(exc): return {'known':False,'reason':str(exc)[:500]}
def try_field(function):
    try: return known(function())
    except (ValueError, UnicodeError, OSError, OverflowError, IndexError) as exc: return unknown(exc)

def read_at(reader,at,size):
    if at<0 or size<0 or at>reader.size or size>reader.size-at: raise ValueError('Disk read outside virtual device')
    reader.seek(at); result=reader.read(size)
    if len(result)!=size: raise ValueError('Short virtual device read')
    return result

def gpt_partition(reader,selected_guid,*,allow_windows_mbr_sentinel=False):
    """Validate GPT CRCs, reciprocal headers, all bounds and chosen GUID."""
    sector=512
    if reader.size<100*sector or reader.size%sector: raise ValueError('Invalid 512-byte disk size')
    mbr=read_at(reader,0,sector)
    if mbr[510:]!=b'\x55\xaa' or mbr[446]!=0 or mbr[450]!=0xee or struct.unpack_from('<I',mbr,454)[0]!=1 or any(mbr[462:510]): raise ValueError('Protective MBR invalid')
    total=reader.size//sector
    protective_length=struct.unpack_from('<I',mbr,458)[0]
    if protective_length!=min(total-1,0xffffffff) and not (allow_windows_mbr_sentinel and protective_length==0xffffffff):
        raise ValueError('Protective MBR length differs')
    def header(lba):
        raw=bytearray(read_at(reader,lba*sector,sector))
        if raw[:8]!=b'EFI PART' or struct.unpack_from('<I',raw,8)[0]!=0x10000: raise ValueError('Invalid GPT signature/revision')
        hsize,crc,reserved=struct.unpack_from('<III',raw,12)
        if not 92<=hsize<=sector or reserved: raise ValueError('Invalid GPT header geometry')
        struct.pack_into('<I',raw,16,0)
        if zlib.crc32(raw[:hsize])!=crc: raise ValueError('GPT header CRC')
        own,peer,first,last=struct.unpack_from('<QQQQ',raw,24)
        table_lba,count,width,table_crc=struct.unpack_from('<QIII',raw,72)
        if own!=lba or not 2<=first<=last<total-1 or not 1<=count<=4096 or not 128<=width<=1024 or width%8: raise ValueError('Invalid GPT bounds')
        length=count*width
        if table_lba<2 or table_lba*sector>reader.size or length>reader.size-table_lba*sector: raise ValueError('GPT array outside disk')
        table=read_at(reader,table_lba*sector,length)
        if zlib.crc32(table)!=table_crc: raise ValueError('GPT array CRC')
        return dict(own=own,peer=peer,first=first,last=last,disk=bytes(raw[56:72]),table_lba=table_lba,count=count,width=width,table=table)
    a,b=header(1),header(total-1)
    if a['peer']!=total-1 or b['peer']!=1 or any(a[k]!=b[k] for k in ('first','last','disk','count','width','table')) or a['disk']==bytes(16): raise ValueError('GPT copies disagree')
    array_sectors=(a['count']*a['width']+sector-1)//sector
    if a['table_lba']+array_sectors>a['first'] or b['table_lba']<=a['last'] or b['table_lba']+array_sectors>total-1: raise ValueError('GPT array overlaps usable range or header')
    expected=uuid.UUID(selected_guid); found=[]; seen=set(); intervals=[]
    for i in range(a['count']):
        entry=a['table'][i*a['width']:(i+1)*a['width']]
        if entry[:16]==bytes(16):
            if any(entry): raise ValueError('Unused GPT entry has data')
            continue
        kind,unique=uuid.UUID(bytes_le=entry[:16]),uuid.UUID(bytes_le=entry[16:32]); start,end=struct.unpack_from('<QQ',entry,32)
        if unique.int==0 or unique in seen or start<a['first'] or end<start or end>a['last']: raise ValueError('Invalid or duplicate GPT partition')
        if any(start<=p_end and p_start<=end for p_start,p_end in intervals): raise ValueError('Overlapping GPT partitions')
        seen.add(unique);intervals.append((start,end))
        if unique==expected:
            if str(kind)!='ebd0a0a2-b9e5-4433-87c0-68b6b72699c7': raise ValueError('Selected partition not basic data')
            found.append({'number':i+1,'start':start*sector,'bytes':(end-start+1)*sector,'guid':str(unique),'disk_guid':str(uuid.UUID(bytes_le=a['disk']))})
    if len(found)!=1: raise ValueError('Expected unique explicit GPT partition missing')
    if read_at(reader,found[0]['start']+3,8)!=b'NTFS    ': raise ValueError('Selected partition is not NTFS')
    return found[0]

def complete_attributes(image,number):
    base=list(nt.attributes(image.record(number)))
    lists=[a for a in base if a['kind']==0x20]
    if len(lists)>1: raise ValueError('Multiple ATTRIBUTE_LIST roots unsupported')
    attrs=security.all_attributes(image,number)
    if lists:
        # all_attributes validates extension identity; verify base entries too
        # so an omitted / mismatched attribute cannot become a false absence.
        entries=image.list_entries(image.attr_value(lists[0]['data']))
        for item in entries:
            if item['kind'] not in (0x10,0x50,0x80,0xc0,0xd0,0xe0): continue
            if item['reference'] & ((1<<48)-1)==number:
                if item['reference']>>48 != nt.number(image.record(number),16,2): raise ValueError('Stale base list reference')
                match=[a for a in base if a['kind']==item['kind'] and a['name']==item['name'] and a['lowest']==item['lowest'] and a['id']==item['id']]
                if len(match)!=1: raise ValueError('Unresolved base list attribute')
        for attr in base:
            if attr['kind'] not in (0x10,0x50,0x80,0xc0,0xd0,0xe0): continue
            if not any(e['kind']==attr['kind'] and e['name']==attr['name'] and e['lowest']==attr['lowest'] and e['id']==attr['id'] and e['reference']&((1<<48)-1)==number for e in entries): raise ValueError('Base attribute omitted from attribute list')
    return attrs

def selected(attrs,kind,name=''):
    result=sorted((a for a in attrs if a['kind']==kind and a['name']==name),key=lambda a:a['lowest'])
    if not result: raise ValueError('Requested attribute absent')
    return result

def stream_info(image,attrs,kind,name=''):
    group=selected(attrs,kind,name); first=group[0]['data']
    if any(nt.number(a['data'],12,2) for a in group): raise ValueError('Compressed, sparse or encrypted stream unsupported')
    if not first[8]:
        if len(group)!=1: raise ValueError('Resident attribute continuation')
        raw=nt.resident(first)
        return len(raw),len(raw),None,raw
    if any(a['data'][8]!=1 for a in group): raise ValueError('Mixed resident/nonresident attribute')
    mapped=[r for a in group for r in nt.runs(a['data'])]
    size,initialized=nt.number(first,48,8),nt.number(first,56,8)
    if initialized>size or any(lcn is None for _,_,lcn in mapped): raise ValueError('Sparse/invalid initialized stream')
    image.validate_runs(mapped,nt.number(first,40,8))
    return size,initialized,mapped,None

def stream_chunks(image,info):
    size,initialized,mapped,resident=info; offset=0
    while offset<size:
        n=min(65536,size-offset); valid=min(n,max(0,initialized-offset))
        data=(resident[offset:offset+valid] if resident is not None else image.stream(mapped,offset,valid)) if valid else b''
        if len(data)!=valid: raise ValueError('Short stream read')
        yield data+bytes(n-valid); offset+=n

def metadata_stream(image,attrs,kind):
    info=stream_info(image,attrs,kind)
    if info[0]>MAX_META or info[0]!=info[1]: raise ValueError('Metadata stream too large or not initialized')
    return b''.join(stream_chunks(image,info))

def read_reparse(image,attrs,si):
    rows=[a for a in attrs if a['kind']==0xc0]
    if not rows:
        if si&0x400: raise ValueError('Reparse flag without attribute')
        return None
    if not si&0x400 or any(a['name'] for a in rows): raise ValueError('Inconsistent reparse state')
    raw=metadata_stream(image,attrs,0xc0)
    if len(raw)<8: raise ValueError('Short reparse buffer')
    tag,n,reserved=struct.unpack_from('<IHH',raw)
    if len(raw)!=n+8 or reserved: raise ValueError('Invalid reparse header')
    return {'tag':tag,'data_hex':raw[8:].hex()}

def read_ea(image,attrs):
    info=[a for a in attrs if a['kind']==0xd0];data=[a for a in attrs if a['kind']==0xe0]
    if not info and not data:return []
    if not info or not data or any(a['name'] for a in info+data): raise ValueError('Incomplete EA pair')
    head=metadata_stream(image,attrs,0xd0);raw=metadata_stream(image,attrs,0xe0)
    if len(head)!=8 or not raw or len(raw)>65536: raise ValueError('Invalid EA information')
    packed,need,unpacked=struct.unpack('<HHI',head)
    if unpacked!=len(raw):raise ValueError('EA length differs')
    result=[];at=0;size_sum=0;need_sum=0
    while at<len(raw):
        if len(raw)-at<9:raise ValueError('Truncated EA')
        step,flags,n,v=struct.unpack_from('<IBBH',raw,at);size=9+n+v
        if not n or flags&~0x80 or step%4 or step<size or step-size>3 or at+step>len(raw):raise ValueError('Invalid EA bounds')
        name=raw[at+8:at+8+n]
        if b'\0' in name or raw[at+8+n]!=0 or any(raw[at+size:at+step]):raise ValueError('Invalid EA name/padding')
        result.append({'name':name.hex(),'flags':flags,'value_hex':raw[at+9+n:at+size].hex()})
        size_sum+=size-4;need_sum+=bool(flags&0x80);at+=step
    if packed!=size_sum or need!=need_sum or len({x['name'] for x in result})!=len(result):raise ValueError('EA information mismatch')
    return result

def read_ads(image,attrs):
    names=sorted({a['name'] for a in attrs if a['kind']==0x80 and a['name']})
    result=[]
    for name in names:
        info=stream_info(image,attrs,0x80,name)
        if info[0]>MAX_ADS:raise ValueError('Named stream exceeds read bound')
        h=hashlib.sha256()
        for block in stream_chunks(image,info):h.update(block)
        result.append({'name':name,'size':info[0],'sha256':h.hexdigest()})
    return result

def read_security(node,descriptors):
    raw=node['inline'] if node['security_id']==0 else descriptors.get(node['security_id'])
    if raw is None: raise ValueError('Security descriptor missing')
    parts=security.components(raw)
    return {k:parts[k] if k in ('revision','sbz','control') or parts[k] is None else parts[k]['hex'] for k in ('revision','sbz','control','owner','group','sacl','dacl')}

def capture_record(image,node,descriptors):
    out={'attrs':known(node['si_attributes']), 'security':try_field(lambda:read_security(node,descriptors))}
    try: attrs=complete_attributes(image,node['record'])
    except (ValueError,UnicodeError,OSError,OverflowError,IndexError) as exc:
        out.update({k:unknown(exc) for k in ('reparse','ea','ads')});return out
    out.update(reparse=try_field(lambda:read_reparse(image,attrs,node['si_attributes'])),ea=try_field(lambda:read_ea(image,attrs)),ads=try_field(lambda:read_ads(image,attrs)))
    return out

def capture_reader(reader,partition,paths,out):
    image=nt.Image(None,file=reader,partition_start=partition['start'],partition_bytes=partition['bytes'])
    if image.mft_bytes//1024>1_000_000:raise ValueError('MFT record bound exceeded')
    nodes=security.visible_security_references(image)
    descriptors=security.sds_descriptors(security.stream_bytes(image,9,0x80,'$SDS'))
    cache={}; counts={'found':0,'missing':0,'unknown_fields':0};written=0
    for path in paths:
        node=nodes.get(path)
        if node is None:
            value={'path':path};counts['missing']+=1
        else:
            number=node['record']
            if number not in cache:cache[number]=capture_record(image,node,descriptors)
            value={'path':path,**cache[number]};counts['found']+=1
            counts['unknown_fields']+=sum(not value[k]['known'] for k in ('attrs','reparse','ea','ads','security'))
        line=json.dumps(value,ensure_ascii=True,separators=(',',':'))+'\n'
        written+=len(line.encode('utf-8'))
        if written>MAX_EVIDENCE:raise ValueError('Evidence size bound exceeded')
        out.write(line)
    return counts

def capture_plan(plan_path,plan_sha,qemu_img,qemu_sha,out_dir,volume_guid,*,allow_windows_mbr_sentinel=False):
    """All inputs pinned; generated output new; no guest or host mounts."""
    root=oracle.RUNTIME
    oracle.storage_guard(1024**3)  # Reserve space for bounded evidence and map.
    if not diff.SHA.fullmatch(plan_sha) or not diff.SHA.fullmatch(qemu_sha):raise ValueError('Pinned plan and qemu-img SHA required')
    if not out_dir.is_absolute() or not out_dir.is_relative_to(root) or out_dir.exists():raise ValueError('Fresh output directory under runtime required')
    for node in (out_dir.parent,*out_dir.parent.parents):
        if node.is_symlink() or (node.exists() and getattr(node.lstat(),'st_file_attributes',0)&0x400):raise ValueError('Output reparse ancestry')
    if volume_guid.lower()!=oracle.VOLUME.lower():raise ValueError('Runtime volume pin differs')
    executable=oracle.local(qemu_img)
    if not executable.is_file() or executable.name.lower()!='qemu-img.exe':raise ValueError('Exact qemu-img executable required')
    with contextlib.ExitStack() as stack:
        def pin(path,sha):
            path=diff.checked_path(root,path)
            if not diff.SHA.fullmatch(sha):raise ValueError('Invalid SHA pin')
            f=stack.enter_context(diff.locked(path))
            if diff.digest(f)!=sha:raise ValueError('Pinned file differs')
            return f
        pf=pin(plan_path,plan_sha);plan=json.load(pf)
        if plan.get('schema')!='minios-tag4-capture-plan-v1':raise ValueError('Invalid capture plan')
        w=plan['wim_receipt'];wf=pin(w['path'],w['sha256']);wim=json.load(wf)
        t=plan['tree'];tf=pin(t['path'],t['sha256'])
        if wim.get('schema')!='usos-wim-oracle-manifest-v1' or wim.get('tree_sha256')!=t['sha256'] or not diff.SHA.fullmatch(wim.get('wim_sha256','')) or type(wim.get('index')) is not int:raise ValueError('WIM manifest binding failed')
        paths=[];items=0;seen=set()
        for row in diff.jsonl(tf):
            path=diff.path_key(row['path']);tags=[x for x in row.get('tagged_metadata',[]) if x.get('type')==4]
            if tags:
                if path in seen or len(seen)>=1_000_000:raise ValueError('Duplicate/unbounded tag paths')
                seen.add(path);paths.append(path);items+=len(tags)
        if not paths or wim.get('tagged_metadata_histogram',{}).get('0x00000004')!=items:raise ValueError('WIM tagged count differs')
        virtual=plan['virtual_bytes'];chain=plan['chain']
        if type(virtual) is not int or not 0<virtual<=128*1024**3 or not isinstance(chain,list) or not 1<=len(chain)<=16:raise ValueError('Invalid bounded image chain')
        targets=[Path(x['path']) for x in chain]
        if any(set(x)!={'path','sha256'} for x in chain) or len(set(targets))!=len(targets):raise ValueError('Invalid image chain identity')
        files=[pin(x['path'],x['sha256']) for x in chain]
        is_vhdx=targets[0].suffix.lower()=='.vhdx'
        if is_vhdx:
            if len(targets)!=1:raise ValueError('VHDX must be a single pinned file')
            import host_dism_vhdx_verify as fixed
            # The QEMU VHDX driver can omit physical offsets from `map`.
            # Derive them from our separately validated fixed-image BAT instead.
            layout=fixed.check_layout(files[0],virtual,fixed.real_allocation(targets[0]),129*1024**3,include_map=True)
        elif native.qcow_chain(targets[0],virtual)!=targets:raise ValueError('Actual QCOW backing chain differs')
        exe=stack.enter_context(diff.locked(executable))
        if diff.digest(exe)!=qemu_sha:raise ValueError('qemu-img pin differs')
        if targets[0].suffix.lower()=='.raw':
            if len(files)!=1 or os.fstat(files[0].fileno()).st_size!=virtual:raise ValueError('Raw target size differs')
            class Raw:
                size=virtual
                def seek(self,n):return files[0].seek(n)
                def read(self,n):return files[0].read(n)
            reader=Raw();map_data=None
        elif targets[0].suffix.lower() in ('.qcow2','.vhdx'):
            image_format='vhdx' if is_vhdx else 'qcow2'
            proc=subprocess.run([str(executable),'map','-f',image_format,'--output=json',str(targets[0])],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=180,check=False)
            if proc.returncode or len(proc.stdout)>32*1024**2 or len(proc.stderr)>1024**2:raise ValueError('qemu-img map failed/bound')
            map_data=proc.stdout;maps=json.loads(map_data)
            for item in maps:
                if item.get('data') and not item.get('zero') and 'filename' in item:
                    depth=item.get('depth')
                    if type(depth) is not int or not 0<=depth<len(targets) or Path(item['filename'])!=targets[depth]:raise ValueError('Map filename/depth differs')
            if is_vhdx:
                fixed.check_qemu_map(maps,virtual,layout['map'])
                reader=qcow.Reader(layout['map'],files,virtual)
            else:reader=qcow.Reader(maps,files,virtual)
        else:raise ValueError('Target must be raw, QCOW2 or standalone clean VHDX')
        partition=gpt_partition(reader,plan['partition_guid'],allow_windows_mbr_sentinel=allow_windows_mbr_sentinel)
        if (partition['start'],partition['bytes'])!=(plan['partition_offset'],plan['partition_bytes']):raise ValueError('GPT partition geometry differs from pinned plan')
        out_dir.mkdir()
        if map_data is not None:
            with (out_dir/'map.json').open('xb') as f:f.write(map_data)
        evidence=out_dir/'metadata.jsonl'
        with evidence.open('x',encoding='utf-8',newline='\n') as out:counts=capture_reader(reader,partition,paths,out)
        for f,entry in zip(files,chain):
            if diff.digest(f)!=entry['sha256']:raise ValueError('Image bytes changed during capture')
        if is_vhdx:validate_vhdx(files[0],virtual)
        elif native.qcow_chain(targets[0],virtual)!=targets:raise ValueError('Image chain changed during capture')
        receipt=dict(schema='minios-tag4-capture-v1',locked_readonly_during_capture=True,manifest_sha256=t['sha256'],
                     source_wim_sha256=wim['wim_sha256'],wim_index=wim['index'],virtual_bytes=virtual,
                     partition_offset=partition['start'],partition_bytes=partition['bytes'],partition_guid=partition['guid'],
                     chain=chain,evidence={'path':str(evidence),'sha256':oracle.digest(evidence)},
                     capture_plan_sha256=plan_sha,wim_receipt_sha256=w['sha256'],qemu_img_sha256=qemu_sha,
                     map_sha256=hashlib.sha256(map_data).hexdigest() if map_data is not None else None,
                     tagged_items=items,tagged_paths=len(paths),counts=counts,host_mount_used=False,
                     windows_mbr_sentinel_allowed=allow_windows_mbr_sentinel,
                     note='Raw independent host NTFS inspector; unknown fields are not matches.')
        with (out_dir/'receipt.json').open('x',encoding='utf8',newline='\n') as out:json.dump(receipt,out,indent=2);out.write('\n')
        return receipt

def main():
    p=argparse.ArgumentParser(description=__doc__)
    for x in ('plan','plan-sha256','qemu-img','qemu-sha256','out','volume-guid'):p.add_argument('--'+x,required=True)
    a=p.parse_args()
    print(json.dumps(capture_plan(Path(a.plan),a.plan_sha256,Path(a.qemu_img),a.qemu_sha256,Path(a.out),a.volume_guid),indent=2))
if __name__=='__main__':main()
