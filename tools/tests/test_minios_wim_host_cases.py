# SPDX-License-Identifier: GPL-3.0-or-later
"""Owned synthetic WIM plans, resource-hash mutation and fail-closed receipts."""
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('wim_host_cases', REPO/'tools/minios/wim_host_cases.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
TMP = REPO/'runtime/wim-host-tests'; TMP.mkdir(parents=True,exist_ok=True)

def manifest():
    root=m.oracle.RUNTIME/'synthetic'/'unit-fixture'
    cases=[]
    for name,codec,count,solid in [('xpress','XPRESS',1,False),('lzx','LZX',1,False),('lzms','LZMS',1,False),('multi','XPRESS',2,False),('solid','LZMS',1,True)]:
        row=dict(wim=str(root/name/'install.wim'),sha256='a'*64,own_generated_data=True,read_only_attribute=True,solid=solid,header=dict(compression=codec,image_count=count))
        if not solid:row['images']=[dict(index=i,tree=str(root/name/f'image{i}'/'tree.jsonl'),security=str(root/name/f'image{i}'/'security.jsonl'),manifest=str(root/name/f'image{i}'/'manifest.json'),own_bytes_vs_wimlib='PASS') for i in range(1,count+1)]
        cases.append(row)
    return dict(schema=m.SCHEMA,own_generated_data=True,cases=cases,split_negative=dict(parts=[dict(path=str(root/'split'/f'part{i}.swm'),sha256='b'*64,part=i,total=2) for i in (1,2)]))

def wim_bytes(integrity=True):
    data=bytearray(208+64+50+16+(32 if integrity else 0))
    data[:8]=b'MSWIM\0\0\0';struct.pack_into('<I',data,8,208)
    payload=bytes(range(64));data[208:272]=payload
    struct.pack_into('<QQQ',data,48,50|(2<<56),272,50)
    struct.pack_into('<QQQ',data,272,64|(2<<56),208,64)
    struct.pack_into('<HI',data,272+24,1,1);data[302:322]=hashlib.sha1(payload).digest()
    if integrity:
        struct.pack_into('<QQQ',data,124,32,338,32)
        struct.pack_into('<III',data,338,32,1,1024)
        data[350:370]=hashlib.sha1(data[208:322]).digest()
    return bytes(data)

def receipt(positive=False):
    result=dict(kind='own-wim-host-case-v1',fresh_cow=True,physical_or_mounts_used=False,stack_reserve_bytes=1048576,
                source_unchanged=True,program_unchanged=True,source_pin_matches=True,program_pin_matches=True,target_bytes=m.SIZE,
                base_unchanged=True,cow_unchanged=True,timed_out=False,returncode=1,target_unchanged=True,pass_marker=False,
                host_complete=False,expected_error='WimHashMismatch',error_marker=True,alloc_peak=500000)
    if positive:result.update(returncode=0,target_unchanged=False,pass_marker=True,host_complete=True,expected_error=None,error_marker=False)
    return result

class HostCaseTests(unittest.TestCase):
    def test_plan_has_all_four_positives_and_five_header_negatives(self):
        plan=m.plan(manifest())
        self.assertEqual([x['name'] for x in plan[:4]],['xpress','lzx','lzms-nonsolid','multi-index2'])
        self.assertEqual([x['index'] for x in plan[:4]],[1,1,1,2])
        self.assertEqual(len(plan),9);self.assertEqual(sum(not x['positive'] for x in plan),5)
        self.assertEqual({x['index'] for x in plan if x['name'].startswith('refuse-index')},{0,3})
    def test_plan_rejects_foreign_mutable_or_incomplete_fixture(self):
        for mutate in (lambda d:d.update(own_generated_data=False),lambda d:d['cases'][0].update(read_only_attribute=False),lambda d:d['cases'].pop(2),lambda d:d['cases'][0]['images'][0].update(own_bytes_vs_wimlib='FAIL'),lambda d:d['split_negative']['parts'][0].update(total=3)):
            with self.subTest(mutate=mutate):
                data=manifest();mutate(data)
                with self.assertRaises(ValueError):m.plan(data)
    def test_large_profile_requires_all_three_codecs_and_explicit_thresholds(self):
        data = manifest()
        data.update(profile='large', source_file_count=1208, source_largest_file_bytes=128 * 1024**2 + 123)
        data['cases'] = data['cases'][:3]
        rows = m.plan(data)
        self.assertEqual([x['name'] for x in rows], ['xpress','lzx','lzms-nonsolid'])
        self.assertTrue(all(x['positive'] for x in rows))
        for field, value in (('source_file_count',999), ('source_largest_file_bytes',100 * 1024**2)):
            bad = copy.deepcopy(data); bad[field] = value
            with self.assertRaises(ValueError): m.plan(bad)
    def test_independent_large_tree_requires_count_and_individual_size(self):
        with tempfile.TemporaryDirectory(dir=TMP) as temporary:
            path = Path(temporary)/'tree.jsonl'
            rows = [dict(path='root',directory=True)]
            rows.extend(dict(path=str(i),directory=False,streams=[dict(name=None,size=1)]) for i in range(1000))
            rows[1]['streams'][0]['size'] = 128 * 1024**2 + 123
            def write(): path.write_text(''.join(json.dumps(row)+'\n' for row in rows), encoding='utf8')
            write(); self.assertEqual(m.verify_large_tree(path)['files'], 1000)
            rows[1]['streams'][0]['size'] = 100 * 1024**2
            write()
            with self.assertRaises(ValueError): m.verify_large_tree(path)
            rows[1]['streams'][0]['size'] = 128 * 1024**2 + 123
            rows.pop(); write()
            with self.assertRaises(ValueError): m.verify_large_tree(path)
    def test_ads_profile_is_one_xpress_case_and_requires_two_actual_streams(self):
        data = manifest(); data.update(profile='ads', source_named_stream_count=2)
        data['cases'] = data['cases'][:1]
        rows = m.plan(data)
        self.assertEqual([x['name'] for x in rows], ['xpress'])
        data['source_named_stream_count'] = 0
        with self.assertRaises(ValueError): m.plan(data)
        with tempfile.TemporaryDirectory(dir=TMP) as temporary:
            path = Path(temporary)/'tree.jsonl'
            row = dict(path='own',directory=False,streams=[dict(name=None,size=1),dict(name='Zone.Identifier',size=37),dict(name='large-世界',size=196609)])
            def write(): path.write_text(json.dumps(row)+'\n',encoding='utf8')
            write(); self.assertEqual(m.verify_ads_tree(path)['named_streams'],2)
            row['streams'][2]['size'] = 128; write()
            with self.assertRaises(ValueError): m.verify_ads_tree(path)
            row['streams'].pop(); write()
            with self.assertRaises(ValueError): m.verify_ads_tree(path)
    def test_plan_refuses_device_or_nonowned_source(self):
        for path in (r'\\.\PhysicalDrive0',r'C:\Windows\install.wim',str(m.oracle.RUNTIME/'..'/'outside.wim')):
            data=manifest();data['cases'][0]['wim']=path
            with self.assertRaises(ValueError):m.plan(data)
    def test_sha256_pin_requires_exact_lower_hex(self):
        self.assertEqual(m.pin('a'*64),'a'*64)
        for value in (None,1,'a'*63,'A'*64,'g'*64,'a'*64+'\n'):
            with self.assertRaises(ValueError):m.pin(value)
    def test_metadata_hash_mutation_preserves_blob_and_repairs_only_container_integrity(self):
        before=wim_bytes();f=io.BytesIO(before);proof=m.corrupt_metadata_hash(f);after=f.getvalue()
        self.assertEqual(before[:302],after[:302]);self.assertEqual(before[303:350],after[303:350])
        self.assertEqual(before[302]^1,after[302]);self.assertEqual(after[350:370],hashlib.sha1(after[208:322]).digest())
        self.assertEqual(proof['container_integrity_blocks_recomputed'],1)
        self.assertNotEqual(proof['old_sha1'],proof['new_sha1'])
        self.assertNotEqual(after[302:322],hashlib.sha1(after[208:272]).digest())
    def test_metadata_hash_mutation_without_integrity(self):
        before=wim_bytes(False);f=io.BytesIO(before);proof=m.corrupt_metadata_hash(f)
        self.assertEqual(proof['container_integrity_blocks_recomputed'],0)
        self.assertEqual(sum(a!=b for a,b in zip(before,f.getvalue())),1)
    def test_compressed_or_truncated_lookup_is_refused_before_mutation(self):
        for mode in ('compressed','truncated','no-metadata','zero-hash'):
            data=bytearray(wim_bytes())
            if mode=='compressed':data[55]|=4
            if mode=='truncated':struct.pack_into('<Q',data,56,len(data)+1)
            if mode=='no-metadata':data[279]=0
            if mode=='zero-hash':data[302:322]=b'\0'*20
            f=io.BytesIO(data)
            with self.assertRaises(ValueError):m.corrupt_metadata_hash(f)
            self.assertEqual(f.getvalue(),data)
    def test_malformed_container_integrity_is_refused(self):
        for at,value in ((338,1),(342,2),(346,0)):
            data=bytearray(wim_bytes());struct.pack_into('<I',data,at,value)
            with self.assertRaises(ValueError):m.corrupt_metadata_hash(io.BytesIO(data))
    def test_negative_acceptance_requires_actual_specific_refusal_and_unchanged_entire_target(self):
        base=receipt();self.assertTrue(m.accepts(base,False,'WimHashMismatch'))
        for field,value in (('returncode',0),('returncode',None),('target_unchanged',False),('pass_marker',True),('error_marker',False),('expected_error','MissingWimResource'),('timed_out',True),('target_bytes',m.SIZE-512),('kind','made-up'),('physical_or_mounts_used',True),('fresh_cow',False)):
            changed=copy.deepcopy(base);changed[field]=value
            with self.subTest(field=field,value=value):self.assertFalse(m.accepts(changed,False,'WimHashMismatch'))
    def test_source_program_cow_or_base_mutation_never_passes(self):
        for positive in (False,True):
            for field in ('source_unchanged','program_unchanged','source_pin_matches','program_pin_matches','base_unchanged','cow_unchanged'):
                changed=receipt(positive);changed[field]=False
                self.assertFalse(m.accepts(changed,positive,None if positive else 'WimHashMismatch'))
    def test_positive_requires_bounded_measured_ram_and_final_complete(self):
        base=receipt(True);self.assertTrue(m.accepts(base,True))
        for field,value in (('alloc_peak',0),('alloc_peak',16*1024**2),('alloc_peak',True),('host_complete',False),('pass_marker',False),('target_unchanged',True),('stack_reserve_bytes',65536)):
            changed=base.copy();changed[field]=value;self.assertFalse(m.accepts(changed,True))
    def test_pe_stack_audit_reads_actual_pe32plus_reserve(self):
        with tempfile.TemporaryDirectory(dir=TMP) as temporary:
            path=Path(temporary)/'own.exe';data=bytearray(512);data[:2]=b'MZ';struct.pack_into('<I',data,60,128)
            data[128:132]=b'PE\0\0';struct.pack_into('<H',data,152,0x20b);struct.pack_into('<Q',data,224,1048576);path.write_bytes(data)
            self.assertEqual(m.pe_stack(path),1048576)
            struct.pack_into('<Q',data,224,65536);path.write_bytes(data)
            with self.assertRaises(ValueError):m.pe_stack(path)
    def test_existing_batch_refused_before_spawning_or_writing(self):
        with patch.object(m.oracle,'owned'),patch.object(m.oracle,'local'),patch.object(Path,'exists',return_value=True),patch.object(m.subprocess,'run') as spawn:
            with self.assertRaises(ValueError):m.run(Path('fixtures'), 'a'*64,Path('existing'),Path('own.exe'),'b'*64,Path('qemu-img'))
            spawn.assert_not_called()

if __name__=='__main__':unittest.main()
