#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Own mapped bytes and synthetic NTFS records; no VM or Windows payload."""
import copy
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'minios'))
import qcow_map_readonly as mapped
import firstboot_logs as logs


def resident(kind,value,instance=0):
    result=bytearray((24+len(value)+7)//8*8)
    struct.pack_into('<II',result,0,kind,len(result))
    struct.pack_into('<H',result,14,instance)
    struct.pack_into('<IH',result,16,len(value),24)
    result[24:24+len(value)]=value
    return bytes(result)


def name(value,parent):
    data=bytearray(66+len(value)*2)
    struct.pack_into('<Q',data,0,parent|(2<<48))
    data[64]=len(value);data[65]=1;data[66:]=value.encode('utf-16le')
    return resident(0x30,data)


def record(attrs,directory=False):
    result=bytearray(1024)
    struct.pack_into('<H',result,16,2)
    struct.pack_into('<HH',result,20,56,3 if directory else 1)
    cursor=56
    for attr in attrs:
        result[cursor:cursor+len(attr)]=attr;cursor+=len(attr)
    struct.pack_into('<I',result,cursor,0xffffffff)
    struct.pack_into('<I',result,24,cursor+8)
    return bytes(result)


class MapTests(unittest.TestCase):
    def setUp(self):
        root=Path(__file__).resolve().parents[2]/'runtime';root.mkdir(exist_ok=True)
        self.temp=tempfile.TemporaryDirectory(prefix='firstboot-map-unit-',dir=root)
        self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name)

    def test_logical_reads_cross_depths_and_zero_extents(self):
        (self.root/'a').write_bytes(b'--abcd++');(self.root/'b').write_bytes(b'EFGH')
        with (self.root/'a').open('rb') as a,(self.root/'b').open('rb') as b:
            rows=[dict(start=0,length=4,data=True,zero=False,depth=0,offset=2),
                  dict(start=4,length=3,data=False,zero=True,depth=0),
                  dict(start=7,length=4,data=True,zero=False,depth=1,offset=0)]
            reader=mapped.Reader(rows,[a,b],11)
            self.assertEqual(reader.read(11),b'abcd\0\0\0EFGH')
            reader.seek(-8,2);self.assertEqual(reader.read(5),b'd\0\0\0E')
            reader.seek(0);self.assertEqual(reader.read(0),b'')
            with self.assertRaises(ValueError):reader.read(8*1024**2+1)
            with self.assertRaises(ValueError):reader.seek(12)

    def test_map_refuses_gaps_overlap_compression_bad_depth_and_physical_bounds(self):
        (self.root/'a').write_bytes(b'abcd')
        good=dict(start=0,length=4,data=True,zero=False,depth=0,offset=0)
        with (self.root/'a').open('rb') as a:
            for field,value in [('start',1),('length',0),('length',5),('offset',1),('depth',1),('depth',True),
                                ('data',False),('compressed',True),('zero',1)]:
                bad=copy.deepcopy(good);bad[field]=value
                with self.subTest(field=field,value=value):
                    with self.assertRaises(ValueError):mapped.Reader([bad],[a],4)
            with self.assertRaises(ValueError):mapped.Reader([dict(good,length=3)],[a],4)
            with self.assertRaises(ValueError):mapped.Reader([good,good],[a],8)

    def fake_image(self,oversized=False,stale=False):
        allocation=sum(1<<number for number in (0,5,8,9,10,11,12))
        data=bytearray(72);struct.pack_into('<II',data,0,0x80,len(data));data[8]=1
        struct.pack_into('<H',data,14,1);struct.pack_into('<QQH',data,16,0,1,64)
        struct.pack_into('<QQQ',data,40,8192,logs.MAX_LOG_BYTES+1 if oversized else 9,5)
        data[64:68]=b'\x11\x02\x0a\0'
        records={0:record([resident(0xb0,allocation.to_bytes(2,'little'))]),5:record([],True),
                 8:record([name('Windows',5)],True),9:record([name('Panther',8)],True),
                 10:record([name('UnattendGC',9)],True),
                 11:record([name('setuperr.log',9),resident(0x80,b'',1)]),
                 12:record([name('setupact.log',10),bytes(data)])}
        if stale:records[9]=record([name('Panther',7)],True)
        class Fake:
            zero=records[0];mft_bytes=13*1024
            def __init__(self,*args,**kwargs):pass
            def record(self,number):return records[number]
            def attr_value(self,attr):return logs.nt.resident(attr)
            def validate_runs(self,runs,allocated):
                if runs!=[(0,2,10)] or allocated!=8192:raise ValueError('Unexpected own run fixture')
            def stream(self,runs,offset,count):return b'hello'[offset:offset+count]
        return Fake

    def test_four_logs_only_exact_parent_chain_empty_and_uninitialized_tail(self):
        with patch.object(logs.nt,'Image',self.fake_image()):
            result=logs.collect(object(),dict(start=0,bytes=4096),self.root/'panther')
        self.assertEqual(result['content_bytes'],9)
        self.assertEqual((self.root/'panther/Windows/Panther/UnattendGC/setupact.log').read_bytes(),b'hello'+bytes(4))
        self.assertEqual((self.root/'panther/Windows/Panther/setuperr.log').read_bytes(),b'')
        self.assertEqual(len(result['missing']),2)
        self.assertFalse(result['windows_success_judged'])

    def test_oversized_log_refused_and_stale_parent_never_extracted(self):
        with patch.object(logs.nt,'Image',self.fake_image(oversized=True)):
            with self.assertRaises(ValueError):logs.collect(object(),dict(start=0,bytes=4096),self.root/'big')
        with patch.object(logs.nt,'Image',self.fake_image(stale=True)):
            result=logs.collect(object(),dict(start=0,bytes=4096),self.root/'stale')
        self.assertEqual(result['files'],[])
        self.assertEqual(result['missing'],list(logs.LOGS))

    def test_malformed_name_or_existing_output_refused(self):
        with self.assertRaises(ValueError):list(logs.names(record([resident(0x30,b'x')])) )
        with self.assertRaises(ValueError):logs.collect(object(),{},self.root)


if __name__=='__main__':unittest.main()
