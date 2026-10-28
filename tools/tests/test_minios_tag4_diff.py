#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Small synthetic tests, no VM or physical disk access."""
import ctypes, hashlib, importlib.util, json, tempfile, unittest
from pathlib import Path

HERE=Path(__file__).resolve().parent.parent/'minios'
spec=importlib.util.spec_from_file_location('tag4_diff', HERE/'tag4_diff.py')
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

def known(value): return {'known':True,'value':value}
def row(path='Windows/a'):
    return {'path':path, 'attrs':known(32), 'reparse':known(None), 'ea':known([]), 'ads':known([]),
            'security':known({'revision':1,'sbz':0,'control':32772,'owner':'0102','group':'0304','sacl':None,'dacl':'0506'})}
def manifest(path='Windows/a'):
    return {'path':path,'tagged_metadata':[{'type':4,'bytes':4,'hex':'02000000'}]}
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def volume(root):
    result=ctypes.create_unicode_buffer(64); kernel=ctypes.WinDLL('kernel32',use_last_error=True)
    kernel.GetVolumeNameForVolumeMountPointW.argtypes=[ctypes.c_wchar_p,ctypes.c_wchar_p,ctypes.c_uint32]
    if not kernel.GetVolumeNameForVolumeMountPointW(root.anchor,result,len(result)): raise ctypes.WinError(ctypes.get_last_error())
    return result.value

class DiffTests(unittest.TestCase):
    def test_equal_and_sort(self):
        a=row(); b=row(); a['ads']=known([{'name':'b','size':0,'sha256':'0'*64},{'name':'a','size':0,'sha256':'1'*64}]); b['ads']=known(list(reversed(a['ads']['value'])))
        rows,stats=m.compare_rows([manifest()],[a],[b]); self.assertEqual(rows[0]['overall'],'MATCH');self.assertEqual(stats['tag4_items'],1)
    def test_missing_and_unknown_never_pass(self):
        a=row(); b=row(); del b['ads']; b['security']={'known':False,'reason':'SACL inaccessible'}
        rows,_=m.compare_rows([manifest()],[a],[b]);self.assertEqual(rows[0]['overall'],'UNKNOWN');self.assertEqual(rows[0]['fields']['ads']['status'],'UNKNOWN');self.assertEqual(rows[0]['fields']['security']['status'],'UNKNOWN')
    def test_any_actual_difference_visible_even_when_other_fields_unknown(self):
        a=row();b=row();b['attrs']=known(16);del b['ads'];rows,_=m.compare_rows([manifest()],[a],[b]);self.assertEqual(rows[0]['overall'],'DIFF');self.assertEqual(rows[0]['fields']['ads']['status'],'UNKNOWN')
    def test_missing_entry_unknown(self):
        rows,_=m.compare_rows([manifest()],[row()],[]);self.assertEqual(rows[0]['overall'],'UNKNOWN')
    def test_duplicate_paths_and_malformed_values_rejected(self):
        with self.assertRaises(ValueError):m.compare_rows([manifest()],[row(),row()],[row()])
        bad=row();bad['ads']=known([{'name':'a','size':1,'sha256':'bad'}])
        with self.assertRaises(ValueError):m.compare_rows([manifest()],[row()],[bad])
        bad=row();bad['security']={'known':False,'value':None}
        with self.assertRaises(ValueError):m.compare_rows([manifest()],[row()],[bad])
    def test_path_is_not_casefolded(self):
        rows,_=m.compare_rows([manifest()],[row()],[row('windows/a')]);self.assertEqual(rows[0]['overall'],'UNKNOWN')
    def test_security_revision_sbz_acl_and_absent_revision(self):
        for field,value in (('revision',2),('sbz',1),('sacl','0200080000000000'),('dacl','0200080000000000'),('control',32788)):
            a=row();b=row();b['security']['value'][field]=value
            rows,_=m.compare_rows([manifest()],[a],[b]);self.assertEqual(rows[0]['fields']['security']['status'],'DIFF',field)
        b=row();del b['security']['value']['revision']
        rows,_=m.compare_rows([manifest()],[row()],[b]);self.assertEqual(rows[0]['fields']['security']['status'],'UNKNOWN')
        b=row();b['security']['value']['sbz']=None
        rows,_=m.compare_rows([manifest()],[row()],[b]);self.assertEqual(rows[0]['overall'],'UNKNOWN')
    def test_distinct_item_and_path_count(self):
        e=manifest();e['tagged_metadata'].append(e['tagged_metadata'][0]);_,s=m.compare_rows([e],[row()],[row()]);self.assertEqual((s['tag4_items'],s['tag4_paths']),(2,1))
    def test_fixture_end_to_end_and_sha_mismatch(self):
        with tempfile.TemporaryDirectory(dir=HERE) as d:
            root=Path(d); (root/'left.img').write_bytes(b'left');(root/'right.img').write_bytes(b'right')
            (root/'wim.jsonl').write_text(json.dumps(manifest())+'\n', encoding='utf8')
            (root/'wim.json').write_text(json.dumps({'schema':'usos-wim-oracle-manifest-v1','wim_sha256':'a'*64,'index':2,'tree_sha256':sha(root/'wim.jsonl'),'tagged_metadata_histogram':{'0x00000004':1}}),encoding='utf8')
            for side in ('left','right'):
                evidence=root/(side+'.jsonl');evidence.write_text(json.dumps(row())+'\n', encoding='utf8')
                receipt={'schema':'minios-tag4-capture-v1','locked_readonly_during_capture':True,'manifest_sha256':sha(root/'wim.jsonl'),'source_wim_sha256':'a'*64,'wim_index':2,'virtual_bytes':4096,'partition_offset':512,'partition_bytes':1024,'chain':[{'path':str(root/(side+'.img')),'sha256':sha(root/(side+'.img'))}],'evidence':{'path':str(evidence),'sha256':sha(evidence)}}
                (root/(side+'.json')).write_text(json.dumps(receipt),encoding='utf8')
            args=[root,volume(root),root/'wim.jsonl',sha(root/'wim.jsonl'),root/'wim.json',sha(root/'wim.json'),root/'left.json',sha(root/'left.json'),root/'right.json',sha(root/'right.json'),root/'diff.jsonl']
            result=m.run(*args);self.assertEqual(result['outcome'],{'MATCH':1});self.assertTrue(result['images_rehashed_and_locked'])
            args[-1]=root/'diff2.jsonl';args[7]='b'*64
            with self.assertRaises(ValueError):m.run(*args)
            args[7]=sha(root/'left.json');args[1]='\\\\?\\Volume{00000000-0000-0000-0000-000000000000}\\'
            with self.assertRaises(ValueError):m.run(*args)
            args[1]=volume(root); right=json.loads((root/'right.json').read_text(encoding='utf8'));right['wim_index']=3
            (root/'right.json').write_text(json.dumps(right),encoding='utf8');args[9]=sha(root/'right.json')
            with self.assertRaises(ValueError):m.run(*args)
            right['wim_index']=2;right['chain']=json.loads((root/'left.json').read_text(encoding='utf8'))['chain']
            (root/'right.json').write_text(json.dumps(right),encoding='utf8');args[9]=sha(root/'right.json')
            with self.assertRaises(ValueError):m.run(*args)

if __name__=='__main__': unittest.main()
