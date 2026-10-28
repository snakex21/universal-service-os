#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Synthetic fixtures only: no VM, mounting, disks, or downloaded media."""
import hashlib, importlib.util, io, json, struct, tempfile, unittest, uuid, zlib
from pathlib import Path
from unittest.mock import patch
HERE=Path(__file__).resolve().parent.parent/'minios'
spec=importlib.util.spec_from_file_location('tag4_collector',HERE/'tag4_collector.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
import host_dism_vhdx_verify as fixed

class Reader:
    def __init__(self,data):self.data=bytes(data);self.size=len(data);self.pos=0
    def seek(self,n):self.pos=n
    def read(self,n):out=self.data[self.pos:self.pos+n];self.pos+=len(out);return out
def fixture():
    sec=512;total=16384;raw=bytearray(sec*total);disk=uuid.UUID('00000001-0000-0000-0000-000000000000');part=uuid.UUID('00000002-0000-0000-0000-000000000000')
    raw[510:512]=b'\x55\xaa';raw[450]=0xee;struct.pack_into('<II',raw,454,1,total-1)
    table=bytearray(128*128);table[:16]=uuid.UUID('ebd0a0a2-b9e5-4433-87c0-68b6b72699c7').bytes_le;table[16:32]=part.bytes_le;struct.pack_into('<QQ',table,32,2048,12000)
    crc=zlib.crc32(table);raw[2*sec:34*sec]=table;raw[(total-33)*sec:(total-1)*sec]=table
    def hdr(own,peer,table_sector):
        b=bytearray(sec);b[:8]=b'EFI PART';struct.pack_into('<IIII',b,8,0x10000,92,0,0);struct.pack_into('<QQQQ',b,24,own,peer,34,total-34);b[56:72]=disk.bytes_le;struct.pack_into('<QIII',b,72,table_sector,128,128,crc);struct.pack_into('<I',b,16,zlib.crc32(b[:92]));return b
    raw[sec:2*sec]=hdr(1,total-1,2);raw[(total-1)*sec:]=hdr(total-1,1,total-33);raw[2048*sec+3:2048*sec+11]=b'NTFS    '
    return raw,str(part)
def attr(kind,value,name=''):
    data=bytearray(24+len(value));data[8]=0;struct.pack_into('<IH',data,16,len(value),24);data[24:]=value
    return {'kind':kind,'name':name,'id':1,'lowest':0,'data':bytes(data)}

def vhdx_fixture():
    # In-memory only: independent minimal clean VHDX structures, not an image.
    out=bytearray(4*1024*1024);out[:8]=b'vhdxfile'
    def crc_at(start,length):
        out[start+4:start+8]=bytes(4)
        struct.pack_into('<I',out,start+4,m._crc32c(out[start:start+length]))
    for h in (65536,131072):
        out[h:h+4]=b'head';struct.pack_into('<Q',out,h+8,1)
        struct.pack_into('<HHIQ',out,h+64,0,1,1048576,1048576);crc_at(h,4096)
    for t in (196608,262144):
        out[t:t+4]=b'regi';struct.pack_into('<II',out,t+8,2,0)
        for i,(guid,off) in enumerate(((m._VHDX_META,2097152),(m._VHDX_BAT,3145728))):
            pos=t+16+i*32;out[pos:pos+16]=guid;struct.pack_into('<QII',out,pos+16,off,1048576,1)
        crc_at(t,65536)
    at=2097152;out[at:at+8]=b'metadata';struct.pack_into('<H',out,at+10,5)
    items=[(m._VHDX_PARAMS,struct.pack('<II',1048576,1)),(m._VHDX_SIZE,struct.pack('<Q',32*1024*1024))]
    items += [(uuid.UUID('8141bf1d-a96f-4709-ba47-f233a8faab5f').bytes_le,struct.pack('<I',512)),
              (uuid.UUID('cda348c7-445d-4471-9cc9-e9885251c556').bytes_le,struct.pack('<I',4096)),
              (uuid.UUID('beca12ab-b2e6-4523-93ef-c309e000c746').bytes_le,bytes(range(16)))]
    for i,(guid,data) in enumerate(items):
        pos=at+32+i*32;dataoff=65536+i*32
        out[pos:pos+16]=guid;struct.pack_into('<IIII',out,pos+16,dataoff,len(data),4,0)
        out[at+dataoff:at+dataoff+len(data)]=data
    return out

class Tests(unittest.TestCase):
    def test_vhdx_clean_preflight_and_crc32c(self):
        self.assertEqual(m._crc32c(b'123456789'),0xe3069283)
        disk=vhdx_fixture()
        self.assertEqual(m.validate_vhdx(io.BytesIO(disk),32*1024*1024),{'size':32*1024*1024,'fixed_flag':True,'block_size':1048576})
        # QEMU emits the two known region entries with Required=0.
        for table in (196608,262144):
            for i in range(2):struct.pack_into('<I',disk,table+16+i*32+28,0)
            struct.pack_into('<I',disk,table+4,0)
            struct.pack_into('<I',disk,table+4,m._crc32c(disk[table:table+65536]))
        self.assertTrue(m.validate_vhdx(io.BytesIO(disk),32*1024*1024)['fixed_flag'])
    def test_vhdx_refuses_parent_and_unknown_metadata(self):
        disk=vhdx_fixture();struct.pack_into('<I',disk,2097152+65536+4,3)
        with self.assertRaisesRegex(ValueError,'parent'):m.validate_vhdx(io.BytesIO(disk),32*1024*1024)
        disk=vhdx_fixture();disk[2097152+32:2097152+48]=m._VHDX_PARENT
        with self.assertRaisesRegex(ValueError,'parent'):m.validate_vhdx(io.BytesIO(disk),32*1024*1024)
        disk=vhdx_fixture();disk[2097152+32:2097152+48]=bytes(16)
        with self.assertRaisesRegex(ValueError,'metadata'):m.validate_vhdx(io.BytesIO(disk),32*1024*1024)
    def test_vhdx_refuses_dirty_corrupt_and_geometry(self):
        disk=vhdx_fixture();disk[65536+48]=1
        with self.assertRaisesRegex(ValueError,'checksum'):m.validate_vhdx(io.BytesIO(disk),32*1024*1024)
        struct.pack_into('<I',disk,65536+4,0);struct.pack_into('<I',disk,65536+4,m._crc32c(disk[65536:65536+4096]))
        with self.assertRaisesRegex(ValueError,'dirty'):m.validate_vhdx(io.BytesIO(disk),32*1024*1024)
        disk=vhdx_fixture();disk[262144+80]^=1
        with self.assertRaisesRegex(ValueError,'copies'):m.validate_vhdx(io.BytesIO(disk),32*1024*1024)
        disk=vhdx_fixture()
        with self.assertRaisesRegex(ValueError,'virtual size'):m.validate_vhdx(io.BytesIO(disk),64*1024*1024)
    def test_vhdx_preflight_refusal_happens_before_qemu(self):
        def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
        with tempfile.TemporaryDirectory(dir=HERE) as temp:
            root=Path(temp);image=root/'fixture.vhdx';image.write_bytes(b'not a real image')
            exe=root/'qemu-img.exe';exe.write_bytes(b'dummy')
            tree=root/'tree.jsonl';tree.write_text(json.dumps({'path':'Windows/example','tagged_metadata':[{'type':4}]})+'\n',encoding='utf8')
            wr=root/'wim.json';wr.write_text(json.dumps({'schema':'usos-wim-oracle-manifest-v1','tree_sha256':sha(tree),'wim_sha256':'a'*64,'index':2,'tagged_metadata_histogram':{'0x00000004':1}}),encoding='utf8')
            plan=root/'plan.json';plan.write_text(json.dumps({'schema':'minios-tag4-capture-plan-v1','virtual_bytes':512,'chain':[{'path':str(image),'sha256':sha(image)}], 'tree':{'path':str(tree),'sha256':sha(tree)},'wim_receipt':{'path':str(wr),'sha256':sha(wr)}}),encoding='utf8')
            with patch.multiple(m.oracle,RUNTIME=root,VOLUME='fixture-volume'),patch.object(m.oracle,'storage_guard'),patch.object(m.subprocess,'run') as run:
                with self.assertRaisesRegex(ValueError,'signature'):m.capture_plan(plan,sha(plan),exe,sha(exe),root/'capture','fixture-volume')
                run.assert_not_called();self.assertFalse((root/'capture').exists())
    def test_vhdx_map_reader_rejects_unpinned_or_out_of_bounds_extents(self):
        # A tiny byte stream, not a virtual disk: exercise the map consumer.
        with tempfile.TemporaryFile(dir=HERE) as file:
            file.write(b'xxABCDyy');file.flush()
            rows=[{'start':0,'length':4,'zero':False,'data':True,'depth':0,'offset':2},
                  {'start':4,'length':4,'zero':True,'data':False,'depth':0}]
            reader=m.qcow.Reader(rows,[file],8)
            self.assertEqual(reader.read(8),b'ABCD'+bytes(4))
            for bad in (dict(rows[0],depth=1),dict(rows[0],offset=7),dict(rows[0],compressed=True)):
                with self.assertRaises(ValueError):m.qcow.Reader([bad,rows[1]],[file],8)
    def test_fully_allocated_fixed_vhdx_initial_layout(self):
        data=vhdx_fixture()+bytearray(1024*1024)
        struct.pack_into('<Q',data,2097152+65536+32,1024*1024)
        struct.pack_into('<Q',data,3145728,4194304|6)
        result=fixed.check_layout(io.BytesIO(data),1024*1024,len(data),len(data),include_map=True)
        self.assertEqual(result['payload_blocks'],1)
        self.assertFalse(result['future_vhdmp_growth_guaranteed'])
        qemu=[{'start':0,'length':1024*1024,'depth':0,'present':True,'zero':False,'data':True}]
        fixed.check_qemu_map(qemu,1024*1024,result['map'])
        fixed.check_qemu_map([dict(qemu[0],offset=4194304)],1024*1024,result['map'])
        for row in (dict(qemu[0],depth=1),dict(qemu[0],data=False),dict(qemu[0],offset=1),dict(qemu[0],length=512)):
            with self.assertRaises(ValueError):fixed.check_qemu_map([row],1024*1024,result['map'])
        with self.assertRaisesRegex(ValueError,'budget'):
            fixed.check_layout(io.BytesIO(data),1024*1024,len(data)-1,len(data))
        with self.assertRaisesRegex(ValueError,'budget'):
            fixed.check_layout(io.BytesIO(data),1024*1024,len(data),len(data)-1)
        bad=bytearray(data);struct.pack_into('<Q',bad,3145728,4194304|2)
        with self.assertRaisesRegex(ValueError,'not fully present'):
            fixed.check_layout(io.BytesIO(bad),1024*1024,len(bad),len(bad))
        bad=bytearray(data);struct.pack_into('<Q',bad,3145728,2097152|6)
        with self.assertRaisesRegex(ValueError,'overlaps'):
            fixed.check_layout(io.BytesIO(bad),1024*1024,len(bad),len(bad))
    def test_gpt_select_exact_partition(self):
        data,guid=fixture();p=m.gpt_partition(Reader(data),guid);self.assertEqual((p['start'],p['bytes']),(2048*512,(12000-2048+1)*512))
    def test_gpt_corrupt_and_missing_fail(self):
        data,guid=fixture();data[2*512+8]^=1
        with self.assertRaises(ValueError):m.gpt_partition(Reader(data),guid)
        data,guid=fixture()
        with self.assertRaises(ValueError):m.gpt_partition(Reader(data),'00000003-0000-0000-0000-000000000000')
    def test_gpt_backup_crc_and_ntfs_signature_fail(self):
        data,guid=fixture();data[-512+20]^=1
        with self.assertRaises(ValueError):m.gpt_partition(Reader(data),guid)
        data,guid=fixture();data[2048*512+3]=0
        with self.assertRaises(ValueError):m.gpt_partition(Reader(data),guid)
    def test_scoped_windows_protective_sentinel_still_checks_gpt(self):
        data,guid=fixture();struct.pack_into('<I',data,458,0xffffffff)
        with self.assertRaisesRegex(ValueError,'MBR length'):m.gpt_partition(Reader(data),guid)
        self.assertEqual(m.gpt_partition(Reader(data),guid,allow_windows_mbr_sentinel=True)['guid'],guid)
        for offset in (446,462,510,512+20,len(data)-512+20):
            bad=bytearray(data);bad[offset]^=1
            with self.assertRaises(ValueError):m.gpt_partition(Reader(bad),guid,allow_windows_mbr_sentinel=True)
    def test_attrs_no_guess_and_reparse(self):
        r=attr(0xc0,struct.pack('<IHH',0xa0000003,3,0)+b'abc')
        self.assertIsNone(m.read_reparse(None,[],0));self.assertEqual(m.read_reparse(None,[r],0x400),{'tag':0xa0000003,'data_hex':'616263'})
        with self.assertRaises(ValueError):m.read_reparse(None,[],0x400)
        broken=attr(0xc0,struct.pack('<IHH',1,9,0)+b'abc')
        self.assertFalse(m.try_field(lambda:m.read_reparse(None,[broken],0x400))['known'])
    def test_ea_info_and_value(self):
        v=struct.pack('<IBBH',12,0x80,1,1)+b'A\0Z\0';info=struct.pack('<HHI',7,1,12)
        self.assertEqual(m.read_ea(None,[attr(0xd0,info),attr(0xe0,v)]),[{'name':'41','flags':128,'value_hex':'5a'}]);self.assertEqual(m.read_ea(None,[]),[])
        self.assertFalse(m.try_field(lambda:m.read_ea(None,[attr(0xe0,v)]))['known'])
        with self.assertRaises(ValueError):m.read_ea(None,[attr(0xd0,struct.pack('<HHI',8,1,12)),attr(0xe0,v)])
    def test_resident_ads_and_unsupported_flags(self):
        a=attr(0x80,b'hello','Zone.Identifier');self.assertEqual(m.read_ads(None,[a]),[{'name':'Zone.Identifier','size':5,'sha256':hashlib.sha256(b'hello').hexdigest()}]);self.assertEqual(m.read_ads(None,[]),[])
        value=bytearray(a['data']);struct.pack_into('<H',value,12,1);a['data']=bytes(value)
        self.assertFalse(m.try_field(lambda:m.read_ads(None,[a]))['known'])
    def test_security_component_extraction_and_unknown(self):
        raw=struct.pack('<BBHIIII',1,0,0x8000,0,0,0,0)
        v=m.read_security({'security_id':0,'inline':raw},{});self.assertEqual(v,{'revision':1,'sbz':0,'control':0x8000,'owner':None,'group':None,'sacl':None,'dacl':None})
        self.assertFalse(m.try_field(lambda:m.read_security({'security_id':256,'inline':None},{}))['known'])
        bad=bytes([2])+raw[1:]
        self.assertFalse(m.try_field(lambda:m.read_security({'security_id':0,'inline':bad},{}))['known'])
        variant=raw[:1]+bytes([0x7f])+raw[2:]
        self.assertEqual(m.read_security({'security_id':0,'inline':variant},{})['sbz'],0x7f)
    def test_full_sacl_and_control_are_preserved(self):
        acl=bytes.fromhex('02030c000100020000000400')
        raw=struct.pack('<BBHIIII',1,7,0x8010,0,0,20,0)+acl
        v=m.read_security({'security_id':0,'inline':raw},{})
        self.assertEqual((v['revision'],v['sbz'],v['control'],v['sacl']),(1,7,0x8010,acl.hex()))
        truncated=raw[:-1]
        self.assertFalse(m.try_field(lambda:m.read_security({'security_id':0,'inline':truncated},{}))['known'])
    def test_missing_list_or_attributes_is_unknown(self):
        node={'record':27,'si_attributes':32,'security_id':256,'inline':None}
        with patch.object(m,'complete_attributes',side_effect=ValueError('incomplete attribute list')):
            out=m.capture_record(None,node,{})
        self.assertEqual(out['attrs'],{'known':True,'value':32})
        self.assertTrue(all(not out[k]['known'] for k in ('reparse','ea','ads','security')))
    def test_incomplete_base_attribute_list_refused(self):
        base=bytearray(64);struct.pack_into('<H',base,16,1)
        class Image:
            def record(self,n):return bytes(base)
            def attr_value(self,data):return b'list'
            def list_entries(self,value):return []
        a=attr(0x80,b'value');listing=attr(0x20,b'list')
        with patch.object(m.nt,'attributes',return_value=iter([a,listing])),patch.object(m.security,'all_attributes',return_value=[a,listing]):
            with self.assertRaises(ValueError):m.complete_attributes(Image(),27)
    def test_protocol_receipt_on_tiny_synthetic_raw(self):
        def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
        with tempfile.TemporaryDirectory(dir=HERE) as temp:
            root=Path(temp);raw=root/'fixture.raw';raw.write_bytes(b'abcd');exe=root/'qemu-img.exe';exe.write_bytes(b'test executable')
            tree=root/'tree.jsonl';tree.write_text(json.dumps({'path':'Windows/example','tagged_metadata':[{'type':4,'hex':'02000000'}]})+'\n',encoding='utf8')
            wr=root/'wim.json';wr.write_text(json.dumps({'schema':'usos-wim-oracle-manifest-v1','tree_sha256':sha(tree),'wim_sha256':'a'*64,'index':2,'tagged_metadata_histogram':{'0x00000004':1}}),encoding='utf8')
            plan=root/'plan.json';plan.write_text(json.dumps({'schema':'minios-tag4-capture-plan-v1','virtual_bytes':4,'chain':[{'path':str(raw),'sha256':sha(raw)}], 'tree':{'path':str(tree),'sha256':sha(tree)},'wim_receipt':{'path':str(wr),'sha256':sha(wr)},'partition_guid':'fake','partition_offset':1,'partition_bytes':2}),encoding='utf8')
            def fake_capture(reader,partition,paths,out):
                self.assertEqual(paths,['Windows/example']);self.assertEqual(reader.read(4),b'abcd')
                out.write('{"path":"Windows/example"}\n');return {'found':1,'missing':0,'unknown_fields':5}
            p=patch.multiple(m.oracle,RUNTIME=root,VOLUME='fixture-volume');p.start();self.addCleanup(p.stop)
            with patch.object(m.oracle,'storage_guard'),patch.object(m.native,'qcow_chain',return_value=[raw]),patch.object(m,'gpt_partition',return_value={'start':1,'bytes':2,'guid':'fake'}),patch.object(m,'capture_reader',side_effect=fake_capture):
                result=m.capture_plan(plan,sha(plan),exe,sha(exe),root/'capture','fixture-volume')
            self.assertEqual(result['evidence']['sha256'],sha(root/'capture'/'metadata.jsonl'));self.assertTrue(result['locked_readonly_during_capture'])
            with patch.object(m.oracle,'storage_guard'):
                with self.assertRaises(ValueError):m.capture_plan(plan,'b'*64,exe,sha(exe),root/'capture2','fixture-volume')

if __name__=='__main__':unittest.main()
