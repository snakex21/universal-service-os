"""Build a deep Vista SP2 bootmgr execution-path probe for MS-7100.

This diagnostic PE writes one marker directly to VGA memory at selected
bootmgr function entries and CALL sites. It uses no BIOS interrupt and starts
from the pinned original Vista SP2 bootmgr.exe.
"""
from __future__ import annotations
import argparse, hashlib, struct
from pathlib import Path

SOURCE_SHA256='b9bc1cf550aaa2b120be678837e47f06876bb3e922c894ca56d293d9e2cfe347'
VGA_LAST_CHAR=0x000B8F9E
SECTION_NAME=b'.usosd\0\0'
SECTION_CHARACTERISTICS=0x60000020
PROLOGUE=bytes.fromhex('8b ff 55 8b ec')
# Keep the known outer marker, then descend through the first initializer.
CALL_SITES=(
    (0x1090,'1'),       # entry -> 41df5c
    (0x1df99,'B'),      # 41df5c -> 41e798
    (0x1e7f7,'D'),      # descriptor init -> 409e2e
    (0x1e874,'E'),      # -> 42835d
    (0x1e887,'F'),      # -> 4393af
    (0x1e896,'G'),      # -> 423a66
    (0x1e89b,'H'),      # -> 439c86
    (0x1e8aa,'I'),      # -> 41e9b4
    (0x1e8f6,'J'),      # -> 42af49
    (0x1e8fb,'K'),      # -> 4058b7
    (0x1e90a,'L'),      # -> 4122c6
    (0x1e90f,'M'),      # -> 420918
    (0x1e929,'N'),      # -> 42421a
    (0x1e93e,'O'),      # error cleanup -> 4122ef
    (0x1e943,'P'),      # error cleanup -> 405a55
    (0x1e948,'Q'),      # error cleanup -> 42af18
    (0x1e94d,'R'),      # error cleanup -> 41ea7e
    (0x1e952,'S'),      # cleanup -> 439ccf
    (0x1e95a,'T'),      # cleanup -> 42841b
    (0x28385,'b'),      # 42835d -> 42858c
    (0x28395,'c'),      # -> 42990f phase 0
    (0x283a6,'d'),      # -> 42665b
    (0x283b1,'e'),      # -> 427a53
    (0x283c7,'f'),      # -> 42990f phase 1
    (0x283e0,'g'),      # -> 4270ce
    (0x283f5,'h'),      # conditional -> 4291a4
    (0x283fa,'i'),      # -> 428096
    (0x28408,'j'),      # cleanup -> 4286a0
)
FUNCTION_ENTRIES=((0x1df5c,'A'),(0x1e798,'C'),(0x2835d,'a'))

def align_up(v,a): return (v+a-1)&~(a-1)
def parse_pe(image):
    pe=struct.unpack_from('<I',image,0x3c)[0]
    if image[pe:pe+4]!=b'PE\0\0': raise ValueError('Not PE')
    count=struct.unpack_from('<H',image,pe+6)[0]; optsz=struct.unpack_from('<H',image,pe+20)[0]
    opt=pe+24
    if struct.unpack_from('<H',image,opt)[0]!=0x10b: raise ValueError('Expected PE32')
    sa=struct.unpack_from('<I',image,opt+32)[0]; fa=struct.unpack_from('<I',image,opt+36)[0]
    soi=struct.unpack_from('<I',image,opt+56)[0]; soh=struct.unpack_from('<I',image,opt+60)[0]
    st=opt+optsz; secs=[]
    for i in range(count):
        o=st+i*40; name=image[o:o+8].split(b'\0',1)[0].decode('ascii','replace')
        vs,va,rs,rp=struct.unpack_from('<IIII',image,o+8); ch=struct.unpack_from('<I',image,o+36)[0]
        secs.append(dict(name=name,virtual_size=vs,virtual_address=va,raw_size=rs,raw_offset=rp,characteristics=ch))
    return dict(pe=pe,count=count,opt=opt,section_table=st,section_alignment=sa,file_alignment=fa,size_of_image=soi,size_of_headers=soh,sections=secs)

def rva_to_file(secs,rva):
    for s in secs:
        start=s['virtual_address']; span=min(s['raw_size'],max(s['virtual_size'],1))
        if start<=rva<start+span: return s['raw_offset']+(rva-start)
    raise ValueError(f'RVA {rva:#x} not file backed')

def rel32(src_next,target):
    d=target-src_next
    if not -(1<<31)<=d<(1<<31): raise ValueError('rel32 range')
    return struct.pack('<i',d)

def mark(c): return b'\xc6\x05'+struct.pack('<I',VGA_LAST_CHAR)+bytes([ord(c)])

def build(source):
    digest=hashlib.sha256(source).hexdigest()
    if digest!=SOURCE_SHA256: raise ValueError(f'Unexpected source SHA256 {digest}')
    pe=parse_pe(source); nh=pe['section_table']+pe['count']*40
    if nh+40>pe['size_of_headers']: raise ValueError('No PE header room')
    raw=align_up(len(source),pe['file_alignment']); va=align_up(pe['size_of_image'],pe['section_alignment'])
    tramp=[]; cursor=0; call_meta=[]; fn_meta=[]
    for rva,c in FUNCTION_ENTRIES:
        f=rva_to_file(pe['sections'],rva)
        if source[f:f+5]!=PROLOGUE: raise ValueError(f'Unexpected prologue {rva:#x}: {source[f:f+5].hex()}')
        code=mark(c)+PROLOGUE
        here=va+cursor+len(code); code+=b'\xe9'+rel32(here+5,rva+5)
        tramp.append((cursor,code)); fn_meta.append((rva,c,cursor)); cursor+=len(code)
    for rva,c in CALL_SITES:
        f=rva_to_file(pe['sections'],rva)
        if source[f]!=0xe8: raise ValueError(f'Expected CALL at {rva:#x}, got {source[f]:#x}')
        delta=struct.unpack_from('<i',source,f+1)[0]; target=rva+5+delta
        code=mark(c); here=va+cursor+len(code); code+=b'\xe9'+rel32(here+5,target)
        tramp.append((cursor,code)); call_meta.append((rva,c,target,cursor)); cursor+=len(code)
    vs=cursor; rs=align_up(vs,pe['file_alignment']); new_soi=align_up(va+vs,pe['section_alignment'])
    out=bytearray(source)
    if len(out)<raw: out+=bytes(raw-len(out))
    out+=bytes(rs)
    hdr=bytearray(40); hdr[:8]=SECTION_NAME; struct.pack_into('<IIII',hdr,8,vs,va,rs,raw); struct.pack_into('<I',hdr,36,SECTION_CHARACTERISTICS)
    out[nh:nh+40]=hdr; struct.pack_into('<H',out,pe['pe']+6,pe['count']+1); struct.pack_into('<I',out,pe['opt']+56,new_soi)
    for rva,c,off in fn_meta:
        f=rva_to_file(pe['sections'],rva); out[f:f+5]=b'\xe9'+rel32(rva+5,va+off)
    for rva,c,target,off in call_meta:
        f=rva_to_file(pe['sections'],rva); out[f:f+5]=b'\xe8'+rel32(rva+5,va+off)
    for off,code in tramp: out[raw+off:raw+off+len(code)]=code
    return bytes(out),dict(source_sha256=digest,probe_sha256=hashlib.sha256(out).hexdigest(),probe_section_rva=va,probe_bytes=vs,markers='1ABCDEFGHIJKLMNOPQRSTabcdefghij')

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('source',type=Path); ap.add_argument('output',type=Path); a=ap.parse_args()
    data,info=build(a.source.read_bytes()); a.output.parent.mkdir(parents=True,exist_ok=True); a.output.write_bytes(data)
    for k,v in info.items(): print(f'{k}={v:#x}' if isinstance(v,int) else f'{k}={v}')
if __name__=='__main__': main()
