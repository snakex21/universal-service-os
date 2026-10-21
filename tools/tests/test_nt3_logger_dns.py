"""Execute the actual portable NT3 DNS parser on host, including malformed replies."""
from pathlib import Path
import ctypes
import hashlib
import json
import os
import random
import struct
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
HEADER=ROOT/'tools/nt3/usoslog/src/usoslog_dns_packet.h'
ZIG=Path(os.environ.get('USOS_ZIG',str(ROOT.parent/'dokumentacja-9x/tools/zig/zig.exe')))


def name(value):return b''.join(bytes((len(v),))+v.encode() for v in value.split('.'))+b'\0'
QUESTION=name('frogfind.com')+struct.pack('!HH',1,1)


def rr(owner,data,kind=1,cls=1):return owner+struct.pack('!HHIH',kind,cls,60,len(data))+data
def reply(records=None,question=QUESTION,flags=0x8180,xid=123):
    if records is None:records=[rr(b'\xc0\x0c',b'\x01\x02\x03\x04')]
    return struct.pack('!HHHHHH',xid,flags,1,len(records),0,0)+question+b''.join(records)


class DNSParser(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        parent=ROOT/'artifacts/nt3-logger-dns-host';parent.mkdir(parents=True,exist_ok=True)
        cls.temp=tempfile.TemporaryDirectory(dir=parent);cls.directory=Path(cls.temp.name)
        cls.addClassCleanup(cls.temp.cleanup)
        wrapper=cls.directory/'wrapper.c';dll=cls.directory/'dns.dll'
        wrapper.write_text('#include "'+HEADER.as_posix()+'"\n'+
            '__declspec(dllexport) int match(const unsigned char *p,int n,unsigned id,const char *q,int peer,unsigned char *a) '+
            '{return usos_dns_a_reply(p,n,id,q,peer,a);}\n',encoding='utf-8')
        result=subprocess.run([str(ZIG),'cc','-shared','-O2','-Wall','-Wextra','-Werror',
            str(wrapper),'-o',str(dll)],capture_output=True,
            env=dict(os.environ,ZIG_GLOBAL_CACHE_DIR=str(cls.directory/'cache-global'),ZIG_LOCAL_CACHE_DIR=str(cls.directory/'cache-local')))
        if result.returncode:raise RuntimeError(result.stderr.decode(errors='replace'))
        cls.library=ctypes.CDLL(str(dll));cls.function=cls.library.match
        cls.function.argtypes=[ctypes.POINTER(ctypes.c_ubyte),ctypes.c_int,ctypes.c_uint,ctypes.c_char_p,ctypes.c_int,ctypes.POINTER(ctypes.c_ubyte)]
        cls.function.restype=ctypes.c_int
        # Windows retains DLLs until explicitly unloaded, including own temp.
        def unload():
            fn=ctypes.windll.kernel32.FreeLibrary;fn.argtypes=[ctypes.c_void_p];fn.restype=ctypes.c_int
            fn(cls.library._handle)
        cls.addClassCleanup(unload)

    def check(self,data,id=123,question=b'frogfind.com',peer=1,n=None):
        source=(ctypes.c_ubyte*max(1,len(data))).from_buffer_copy(data or b'\0')
        out=(ctypes.c_ubyte*6)(0xa5,99,99,99,99,0x5a)
        pointer=ctypes.cast(ctypes.byref(out,1),ctypes.POINTER(ctypes.c_ubyte))
        result=self.function(source,len(data) if n is None else n,id,question,peer,pointer)
        self.assertEqual((out[0],out[5]),(0xa5,0x5a))
        if not result:self.assertEqual(bytes(out)[1:5],b'\0'*4)
        return result,bytes(out)[1:5]

    def test_matching_a_question_peer_id_and_case(self):
        self.assertEqual(self.check(reply()),(1,b'\x01\x02\x03\x04'))
        self.assertEqual(self.check(reply(),question=b'FROGFIND.COM')[0],1)
        for args in (dict(id=321),dict(peer=0),dict(question=b'elsewhere.com')):
            self.assertEqual(self.check(reply(),**args)[0],0)
    def test_flags_question_type_class_and_section_counts(self):
        for flags in (0x0180,0x8980,0x8380,0x8183,0x81c0):
            self.assertEqual(self.check(reply(flags=flags))[0],0)
        for q in (name('frogfind.com')+struct.pack('!HH',28,1),name('frogfind.com')+struct.pack('!HH',1,3)):
            self.assertEqual(self.check(reply(question=q))[0],0)
        for at,value in ((4,0),(4,2),(6,65),(8,129)):
            data=bytearray(reply());struct.pack_into('!H',data,at,value)
            self.assertEqual(self.check(data)[0],0)
    def test_cname_chain_and_unrelated_a_cannot_seed_address(self):
        alias=name('target.example')
        records=[rr(name('unrelated.example'),b'\x09'*4),rr(b'\xc0\x0c',alias,5),rr(alias,b'\x01\x02\x03\x04')]
        self.assertEqual(self.check(reply(records)),(1,b'\x01\x02\x03\x04'))
        self.assertEqual(self.check(reply([records[0]]))[0],0)
        self.assertEqual(self.check(reply([rr(b'\xc0\x0c',b'\0'*4)]))[0],0)
        self.assertEqual(self.check(reply([rr(b'\xc0\x0c',b'\x01'*4,1,3)]))[0],0)
    def test_pointer_loops_oob_truncated_labels_and_records(self):
        # The answer owner points to itself; the question is still valid.
        at=12+len(QUESTION);pointer=struct.pack('!H',0xc000|at)
        cases=[reply([rr(pointer,b'\x01'*4)]),reply([rr(b'\xff\xff',b'\x01'*4)]),
            reply([rr(b'\xc0\x0c',b'\xc0\x0c',5)]),reply([rr(b'\xc0\x0c',b'\x03bad',5)]),
            reply([rr(b'\xc0\x0c',b'123',1)]),reply()+b'trailing',
            reply(question=b'\x40'+b'a'*64+b'\0\0\x01\0\x01')]
        for data in cases:self.assertEqual(self.check(data)[0],0)
        valid=reply()
        for n in range(len(valid)):self.assertEqual(self.check(valid[:n])[0],0)
    def test_additional_record_bounds_validated_before_accepting_answer(self):
        valid=reply();bad=bytearray(valid);struct.pack_into('!H',bad,10,1)
        self.assertEqual(self.check(bad)[0],0)
        self.assertEqual(self.check(bad+rr(b'\0',b'1234',41))[0],1)
    def test_deterministic_mutations_remain_bounded(self):
        rng=random.Random(351);original=reply()
        for _ in range(1500):
            data=bytearray(original)
            for __ in range(rng.randrange(1,5)):data[rng.randrange(len(data))]=rng.randrange(256)
            self.check(data)
    def test_actual_logger_uses_match_before_resolved(self):
        source=(HEADER.parent/'usoslog.c').read_text()
        self.assertIn('from.sin_addr.s_addr==server && from.sin_port==htons(53)',source)
        self.assertIn('fl==sizeof(from) && from.sin_family==AF_INET',source)
        self.assertIn('DNS PASS dns_match=1',source)
        self.assertIn('DNS FAIL dns_match=0',source)
        self.assertIn('usos_dns_a_reply(r,n,id,TEST_HOST,peer_matches,address)',source)


if __name__=='__main__':unittest.main()
