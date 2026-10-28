#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Own optical fixtures, 7-Zip stream oracle, random reads and bounded refusal/fuzz gates.

Outputs are retained. There is no mount, extraction tree, physical-device access
or cleanup. Use logged_run.py for the outer clean-tree, two-CPU test invocation.
The optional sparse image requires a separately reserved six-GiB test budget.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import optical_fixtures as f
import optical_oracle as oracle


def profiles():
    return [
        ('iso',f.iso9660(),'SOURCES/LONG.TXT',f.PAYLOAD),
        ('joliet',f.iso9660(joliet=True),'Sources/Long Żółć.txt',f.PAYLOAD),
        ('multi',f.iso9660(multi=True),'SOURCES/LONG.TXT',f.PAYLOAD.ljust(f.BLOCK,b'\0')+f.PAYLOAD),
        ('multi-joliet',f.iso9660(joliet=True,multi=True),'Sources/Long Żółć.txt',f.PAYLOAD.ljust(f.BLOCK,b'\0')+f.PAYLOAD),
        *[('udf'+format(revision,'x'),f.udf(revision),'Sources/Long Żółć.txt',f.PAYLOAD)
          for revision in (0x102,0x201,0x250,0x260)],
        ('udf250-metadata',f.udf(0x250,metadata=True),'Sources/Long Żółć.txt',f.PAYLOAD),
        ('udf260-metadata',f.udf(0x260,metadata=True),'Sources/Long Żółć.txt',f.PAYLOAD),
        ('udf201-efe',f.udf(0x201,extended=True),'Sources/Long Żółć.txt',f.PAYLOAD),
        ('udf260-efe-embedded',f.udf(0x260,extended=True,embedded=True),'Sources/Long Żółć.txt',f.PAYLOAD),
        ('udf102-embedded',f.udf(0x102,embedded=True),'Sources/Long Żółć.txt',f.PAYLOAD),
        ('udf201-continuation',f.udf(0x201,continuation=True,payload=b'x'*f.BLOCK+f.PAYLOAD),'Sources/Long Żółć.txt',b'x'*f.BLOCK+f.PAYLOAD),
        ('udf260-metadata-efe',f.udf(0x260,metadata=True,extended=True),'Sources/Long Żółć.txt',f.PAYLOAD),
    ]


def negative_profiles():
    loop=bytearray(f.iso9660())
    at=24*f.BLOCK+68
    f.both(loop,at+2,'I',24)
    bounds=bytearray(f.iso9660());f.both(bounds,25*f.BLOCK+68+2,'I',999999)
    endian=bytearray(f.iso9660());endian[16*f.BLOCK+131]^=1
    tag=bytearray(f.udf());tag[37*f.BLOCK+4]^=1
    crc=bytearray(f.udf());crc[37*f.BLOCK+48]^=1
    return [
        ('iso-directory-loop',bytes(loop),'DirectoryLoop'),
        ('iso-out-of-bounds',bytes(bounds),'OpticalBounds'),
        ('iso-endian-mismatch',bytes(endian),'IsoEndianMismatch'),
        ('udf-bad-tag',bytes(tag),'UdfTagChecksum'),
        ('udf-bad-crc',bytes(crc),'UdfDescriptorCrc'),
        ('udf-allocation-loop',f.udf(0x201,allocation_loop=True),'UdfAllocationLoop'),
        ('udf-directory-loop',f.udf(0x201,directory_loop=True),'DirectoryLoop'),
        ('udf-invalid-partition',f.udf_patch(f.udf(),37,184,struct.pack('<H',99)),'InvalidUdfPartition'),
        ('udf-out-of-bounds',f.udf_patch(f.udf(),257,188,struct.pack('<I',999999)),'OpticalBounds'),
    ]


def invoke(command,log,label,timeout=300):
    result=subprocess.run([str(value) for value in command],capture_output=True,timeout=timeout)
    text=(result.stdout+result.stderr).decode('utf8')
    log.write_text(label+text+'\nEXIT '+str(result.returncode)+'\n',encoding='utf8')
    return result.returncode,text


def probes(exe,image,path,payload,out,label):
    offsets=sorted({0,1,len(payload)//2,max(0,len(payload)-1),len(payload),
                    *([f.BLOCK-16,f.BLOCK,f.BLOCK+1] if len(payload)>f.BLOCK else [])})
    results=[]
    for offset in offsets:
        code,text=invoke([exe,'probe',image,path.swapcase().replace('/','\\'),offset],out/('probe-'+str(offset)+'.log'),label)
        match=re.search(r'OPTICAL_PROBE size=(\d+) offset=(\d+) bytes=(\d+) sha256=([0-9a-f]{64})',text)
        expected=payload[offset:offset+32]
        passed=(code==0 and match is not None and tuple(match.groups())==
                (str(len(payload)),str(offset),str(len(expected)),hashlib.sha256(expected).hexdigest()))
        if not passed:raise ValueError('Random-read probe mismatch: '+str(image)+' at'+str(offset))
        results.append(dict(offset=offset,bytes=len(expected),sha256=hashlib.sha256(expected).hexdigest(),passed=True))
    return results


def continuation_gate(exe,sevenzip,source,directory,path,payload,label):
    """7-Zip lists an AED chain but does not implement its data extraction.

    Public upstream UdfIn.cpp ReadItem copies FE allocation descriptors into
    extents without traversing descriptor258. Keep this unsupported-method
    result explicit; the independent byte oracle is our original fixture input.
    """
    code,tool=invoke([sevenzip,'t','-sccUTF-8',source],directory/'sevenzip-unsupported.log',label)
    if code==0 or 'Unsupported Method' not in tool:raise ValueError('Unexpected continuation oracle behavior')
    code,text=invoke([exe,'manifest',source],directory/'own.log',label)
    rows=[json.loads(line[6:]) for line in text.splitlines() if line.startswith('ENTRY ')]
    expected=[dict(path='Sources',directory=True,size=0,sha256=None),
              dict(path=path,directory=False,size=len(payload),sha256=hashlib.sha256(payload).hexdigest()),
              dict(path='Sources/empty.dat',directory=False,size=0,sha256=hashlib.sha256(b'').hexdigest())]
    if code or rows!=expected:raise ValueError('Continuation generated-byte oracle mismatch')
    code,listing=invoke([sevenzip,'l','-slt','-sccUTF-8',source],directory/'sevenzip-listing.log',label)
    if code or oracle.listing(listing)!=[{key:value for key,value in row.items() if key!='sha256'} for row in expected]:
        raise ValueError('Continuation 7-Zip listing mismatch')
    return dict(passed=True,kind='udf',entries=3,own_heap_peak=int(re.search(r'heap_peak=(\d+)',text)[1]),
                oracle='original generated payload SHA-256; 7-Zip listing only; extraction unsupported'),rows


def write_sparse(plan,path):
    """Regular, new output only; mark sparse before the truncate on Windows."""
    size=plan['logical_bytes']
    if isinstance(size,bool) or not isinstance(size,int) or not 0<size<=6*1024**3:
        raise ValueError('Sparse fixture exceeds reserved six-GiB image budget')
    if not path.is_absolute() or path.suffix.lower()!='.iso' or any(p.is_symlink() for p in [path,*path.parents]):
        raise ValueError('New local regular ISO path required')
    if os.name=='nt' and (len(path.drive)!=2 or path.drive[1]!=':'):
        raise ValueError('No device or network path')
    for offset,data in plan['chunks']:
        if isinstance(offset,bool) or not isinstance(offset,int) or not isinstance(data,bytes) or offset<0 or offset>size or len(data)>size-offset:
            raise ValueError('Sparse chunk outside declared image')
    if sum(len(data) for _,data in plan['chunks'])>2*1024**2:
        raise ValueError('Sparse fixture header/chunk budget')
    with path.open('xb') as image:
        if os.name=='nt':
            import msvcrt
            kernel=ctypes.WinDLL('kernel32',use_last_error=True)
            kernel.DeviceIoControl.argtypes=[ctypes.c_void_p,ctypes.c_ulong,ctypes.c_void_p,ctypes.c_ulong,
                                             ctypes.c_void_p,ctypes.c_ulong,ctypes.POINTER(ctypes.c_ulong),ctypes.c_void_p]
            returned=ctypes.c_ulong()
            if not kernel.DeviceIoControl(msvcrt.get_osfhandle(image.fileno()),0x900c4,None,0,None,0,ctypes.byref(returned),None):
                raise ctypes.WinError(ctypes.get_last_error())
        image.truncate(size)
        for offset,data in plan['chunks']:
            image.seek(offset);image.write(data)


def run(exe,sevenzip,out,development=False,sparse=False,fuzz=True,only=(),fuzz_exe=None):
    repo=Path(__file__).resolve().parents[2]
    head,dirty,label=oracle.header(repo,not development)
    if not out.is_absolute() or out.exists():raise ValueError('Fresh absolute test directory required')
    if any(parent.is_symlink() for parent in [out,*out.parents]):raise ValueError('No linked test directories')
    out.mkdir(parents=True)
    summary=dict(schema='minios-optical-small-v1',head=head,dirty=dirty,final_evidence=not development,
                 positives=[],negatives=[],fuzz=[],sparse=None)
    for name,image,path,payload in profiles():
        if only and name not in only:continue
        directory=out/name;directory.mkdir()
        source=directory/'own.iso';source.write_bytes(image)
        if name=='udf201-continuation':
            comparison,file_rows=continuation_gate(exe,sevenzip,source,directory,path,payload,label)
        else:
            comparison=oracle.compare(source,exe,sevenzip,directory/'oracle',require_clean=not development)
            file_rows=[json.loads(line) for line in (directory/'oracle/actual.jsonl').read_text(encoding='utf8').splitlines()]
        if not comparison['passed']:raise ValueError('7-Zip tree/hash mismatch '+name)
        block_code,block_text=invoke([exe,'block-manifest',source],directory/'block.log',label)
        if block_code or 'OPTICAL_MANIFEST_COMPLETE ' not in block_text:raise ValueError('Block path refused '+name)
        block_rows=[json.loads(line[6:]) for line in block_text.splitlines() if line.startswith('ENTRY ')]
        if block_rows!=file_rows:raise ValueError('Block/file manifests differ '+name)
        reads=probes(exe,source,path,payload,directory,label)
        summary['positives'].append(dict(name=name,entries=comparison['entries'],kind=comparison['kind'],
                                         own_heap_peak=comparison['own_heap_peak'],probes=reads,
                                         oracle=comparison.get('oracle','7-Zip complete tree and streamed SHA-256'),passed=True))
    for name,image,expected in negative_profiles():
        directory=out/name;directory.mkdir()
        source=directory/'own.iso';source.write_bytes(image)
        before=oracle.digest(source)
        code,text=invoke([exe,'manifest',source],directory/'refusal.log',label,30)
        passed=code!=0 and expected in text and oracle.digest(source)==before
        if not passed:raise ValueError('Malformed fixture not safely refused '+name+': '+text)
        summary['negatives'].append(dict(name=name,expected=expected,sha256=before,passed=True))
    if fuzz:
        fuzz_exe=exe if fuzz_exe is None else fuzz_exe
        fuzz_hash=oracle.digest(fuzz_exe)
        for name in ('joliet','udf260-metadata','udf201-continuation'):
            directory=out/name
            if not directory.exists():continue
            source=directory/'own.iso';before=oracle.digest(source)
            code,text=invoke([fuzz_exe,'fuzz',source],directory/'fuzz.log',label,1200)
            match=re.search(r'OPTICAL_FUZZ_COMPLETE seed=([0-9a-f]+) cases=(\d+) refused=(\d+) unchanged_or_accepted=(\d+)',text)
            if code or match is None or int(match[2])!=1024 or oracle.digest(source)!=before or oracle.digest(fuzz_exe)!=fuzz_hash:
                raise ValueError('Fuzz gate failed '+name)
            summary['fuzz'].append(dict(name=name,seed=match[1],cases=int(match[2]),refused=int(match[3]),program_sha256=fuzz_hash,passed=True))
    if sparse:
        directory=out/'sparse-multi';directory.mkdir()
        plan=f.iso9660_sparse_plan();source=directory/'own.iso';write_sparse(plan,source)
        comparison=oracle.compare(source,exe,sevenzip,directory/'oracle',require_clean=not development)
        if not comparison['passed']:raise ValueError('Sparse multi-extent tree/hash mismatch')
        reads=[]
        for offset in (0,plan['split']-16,plan['split']-1,plan['split'],2**32,plan['file_bytes']-16):
            code,text=invoke([exe,'probe',source,plan['path'].lower(),offset],directory/('probe-'+str(offset)+'.log'),label)
            sample=f.sparse_sample(plan,offset,min(32,plan['file_bytes']-offset))
            if code or ('sha256='+hashlib.sha256(sample).hexdigest()) not in text:
                raise ValueError('Sparse random offset mismatch '+str(offset))
            reads.append(dict(offset=offset,bytes=len(sample),sha256=hashlib.sha256(sample).hexdigest()))
        summary['sparse']=dict(image_bytes=plan['logical_bytes'],file_bytes=plan['file_bytes'],sha256=oracle.digest(source),probes=reads,passed=True)
    if not development and oracle.logged_run.tree(repo)!=(head,0):raise ValueError('Tree changed during final evidence')
    summary['passed']=True
    (out/'result.json').write_text(json.dumps(summary,indent=2)+'\n',encoding='utf8')
    return summary


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('exe','sevenzip','out'):parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--development',action='store_true')
    parser.add_argument('--sparse',action='store_true')
    parser.add_argument('--no-fuzz',action='store_true')
    parser.add_argument('--fuzz-exe',type=Path,help='Optional separate ReleaseSafe fuzz harness')
    parser.add_argument('--only',action='append',default=[])
    args=parser.parse_args()
    result=run(args.exe.resolve(strict=True),args.sevenzip.resolve(strict=True),args.out,args.development,args.sparse,
               not args.no_fuzz,args.only,args.fuzz_exe.resolve(strict=True) if args.fuzz_exe else None)
    print(json.dumps(result));raise SystemExit(0 if result['passed'] else 1)
