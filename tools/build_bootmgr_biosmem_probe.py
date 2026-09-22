"""Vista SP2 bootmgr probe for the first memory/BIOS initializer after marker d."""
from __future__ import annotations
import argparse, hashlib, struct
from pathlib import Path

SOURCE_SHA256='b9bc1cf550aaa2b120be678837e47f06876bb3e922c894ca56d293d9e2cfe347'
VGA=0x000B8F9E
SECTION_NAME=b'.usosm\0\0'
SECTION_CHARACTERISTICS=0x60000020
PROLOGUE=bytes.fromhex('8b ff 55 8b ec')
CALLS=(
    (0x283a6,'d'), # 4283a6 -> 42665b
    (0x26765,'u'), # 42665b -> 4296d3
    (0x29703,'v'), # 4296d3 -> 409957
    (0x09980,'w'), # 409957 -> 40a035 (INT15 callback, AX=C000)
    (0x099cb,'y'), # optional second callback, AX=C100
    (0x29784,'z'), # 4296d3 -> 4285fe
    (0x29793,'2'), # 4296d3 -> 428737
    (0x297ad,'3'), # 4296d3 -> 42980c
)
FUNCTIONS=((0x2665b,'D'),(0x296d3,'U'),(0x09957,'V'),(0x0a035,'W'))
# Replace the 5-byte MOV EAX,[5010d0] immediately before the indirect callback.
INLINE=((0x0a03d,'X',bytes.fromhex('a1 d0 10 50 00')),) 

def au(v,a): return (v+a-1)&~(a-1)
def peinfo(b):
    pe=struct.unpack_from('<I',b,0x3c)[0]; n=struct.unpack_from('<H',b,pe+6)[0]; osz=struct.unpack_from('<H',b,pe+20)[0]; opt=pe+24
    if b[pe:pe+4]!=b'PE\0\0' or struct.unpack_from('<H',b,opt)[0]!=0x10b: raise ValueError('bad PE')
    sa,fa=struct.unpack_from('<II',b,opt+32); soi,soh=struct.unpack_from('<II',b,opt+56); st=opt+osz; ss=[]
    for i in range(n):
        o=st+i*40; vs,va,rs,rp=struct.unpack_from('<IIII',b,o+8); ss.append((vs,va,rs,rp))
    return pe,n,opt,st,sa,fa,soi,soh,ss
def r2f(ss,r):
    for vs,va,rs,rp in ss:
        if va<=r<va+min(rs,max(vs,1)): return rp+r-va
    raise ValueError(f'RVA {r:#x} not backed')
def rel(srcnext,dst): return struct.pack('<i',dst-srcnext)
def mark(c): return b'\xc6\x05'+struct.pack('<I',VGA)+bytes([ord(c)])

def build(src:bytes):
    if hashlib.sha256(src).hexdigest()!=SOURCE_SHA256: raise ValueError('unexpected source')
    pe,n,opt,st,sa,fa,soi,soh,ss=peinfo(src); nh=st+n*40
    if nh+40>soh: raise ValueError('no header room')
    raw=au(len(src),fa); va=au(soi,sa); cur=0; tr=[]; fmeta=[]; cmeta=[]; imeta=[]
    for r,c in FUNCTIONS:
        f=r2f(ss,r)
        if src[f:f+5]!=PROLOGUE: raise ValueError(f'bad prologue {r:#x}')
        code=mark(c)+PROLOGUE; here=va+cur+len(code); code+=b'\xe9'+rel(here+5,r+5); tr.append((cur,code)); fmeta.append((r,cur)); cur+=len(code)
    for r,c in CALLS:
        f=r2f(ss,r)
        if src[f]!=0xe8: raise ValueError(f'not CALL {r:#x}')
        target=r+5+struct.unpack_from('<i',src,f+1)[0]
        code=mark(c); here=va+cur+len(code); code+=b'\xe9'+rel(here+5,target); tr.append((cur,code)); cmeta.append((r,cur)); cur+=len(code)
    for r,c,orig in INLINE:
        f=r2f(ss,r)
        if src[f:f+5]!=orig: raise ValueError(f'bad inline {r:#x}')
        code=mark(c)+orig; here=va+cur+len(code); code+=b'\xe9'+rel(here+5,r+5); tr.append((cur,code)); imeta.append((r,cur)); cur+=len(code)
    rs=au(cur,fa); out=bytearray(src); out+=bytes(raw-len(out)+rs)
    h=bytearray(40); h[:8]=SECTION_NAME; struct.pack_into('<IIII',h,8,cur,va,rs,raw); struct.pack_into('<I',h,36,SECTION_CHARACTERISTICS); out[nh:nh+40]=h
    struct.pack_into('<H',out,pe+6,n+1); struct.pack_into('<I',out,opt+56,au(va+cur,sa))
    for r,o in fmeta+imeta:
        f=r2f(ss,r); out[f:f+5]=b'\xe9'+rel(r+5,va+o)
    for r,o in cmeta:
        f=r2f(ss,r); out[f:f+5]=b'\xe8'+rel(r+5,va+o)
    for o,code in tr: out[raw+o:raw+o+len(code)]=code
    return bytes(out)

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('source',type=Path); ap.add_argument('output',type=Path); a=ap.parse_args(); data=build(a.source.read_bytes()); a.output.write_bytes(data); print('sha256='+hashlib.sha256(data).hexdigest()); print('markers=dDUuVvWwXy z23'.replace(' ',''))
if __name__=='__main__': main()
