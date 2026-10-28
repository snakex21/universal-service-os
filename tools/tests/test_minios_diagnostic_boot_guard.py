#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Memory-only disk sectors; no images or disks are created/opened."""
import struct,sys,unittest,uuid,zlib
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'minios'))
import diagnostic_boot_guard as g

class Sparse:
    size=32*1024**3
    def __init__(self):self.parts={};self.pos=0
    def seek(self,n):self.pos=n
    def read(self,n):
        out=bytearray(n)
        for start,data in self.parts.items():
            a=max(self.pos,start);b=min(self.pos+n,start+len(data))
            if a<b:out[a-self.pos:b-self.pos]=data[a-start:b-start]
        self.pos+=n;return bytes(out)

def fixture():
    r=Sparse();total=r.size//512
    mbr=bytearray(512);mbr[510:]=b'\x55\xaa';mbr[450]=0xee;struct.pack_into('<II',mbr,454,1,0xffffffff);r.parts[0]=mbr
    table=bytearray(16384)
    for i,(kind,part,first,last,flags) in enumerate(g.ENTRIES):
        p=i*128;table[p:p+16]=uuid.UUID(kind).bytes_le;table[p+16:p+32]=uuid.UUID(part).bytes_le;struct.pack_into('<QQQ',table,p+32,first,last,flags)
    crc=zlib.crc32(table)
    def header(own,peer,table_lba):
        b=bytearray(512);b[:8]=b'EFI PART';struct.pack_into('<IIII',b,8,0x10000,92,0,0)
        struct.pack_into('<QQQQ',b,24,own,peer,34,total-34);b[56:72]=uuid.UUID(g.DISK).bytes_le
        struct.pack_into('<QIII',b,72,table_lba,128,128,crc);struct.pack_into('<I',b,16,zlib.crc32(b[:92]));return b
    r.parts[512]=header(1,total-1,2);r.parts[1024]=table
    r.parts[(total-33)*512]=table.copy();r.parts[(total-1)*512]=header(total-1,1,total-33)
    boot=bytearray(512);boot[3:11]=b'NTFS    ';struct.pack_into('<H',boot,11,512);struct.pack_into('<Q',boot,72,0xe46231e86231c05a);r.parts[289406976]=boot
    return r

class Tests(unittest.TestCase):
    def test_exact_layout_and_budget(self):
        got=g.validate(fixture(),g.IMAGE_SHA)
        self.assertEqual(got['esp_bytes'],260*g.MIB)
        self.assertEqual(got['boot_bound']+got['firstboot_bound']+got['aux_bound'],2*1024**3)
        with self.assertRaises(ValueError):g.check_budget(g.BOOT_BOUND,g.FIRSTBOOT_BOUND+g.MIB,g.AUX_BOUND)
        with self.assertRaises(ValueError):g.validate(fixture(),'0'*64)
    def test_corruption_refuses(self):
        for start,offset in ((0,446),(1024,16),(Sparse.size-512,20),(289406976,72)):
            r=fixture();r.parts[start][offset]^=1
            with self.assertRaises(ValueError):g.validate(r,g.IMAGE_SHA)

if __name__=='__main__':unittest.main()
