# SPDX-License-Identifier: GPL-3.0-or-later
"""Tiny receipt-binding refusals; no images, mounts, VHDs or external commands."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'tools/minios'))
spec=importlib.util.spec_from_file_location('optical_e2e',REPO/'tools/minios/optical_e2e.py')
m=importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
TMP=REPO/'runtime/optical-unit-tmp'
TMP.mkdir(parents=True,exist_ok=True)


class OpticalE2eReceiptTests(unittest.TestCase):
    def test_three_gib_is_pack_only_and_apply_refuses_before_any_capacity_or_image_access(self):
        m.validate_size('pack',3)
        for action in ('pack','apply'):
            for size in (6,12,16):m.validate_size(action,size)
        self.args.size_gib=3
        with (patch.object(m.pool,'enforce') as capacity,patch.object(m.oracle,'readonly') as source,
              patch.object(m,'blank') as blank):
            with self.assertRaisesRegex(ValueError,'source-pack only'):m.run(self.args)
            capacity.assert_not_called();source.assert_not_called();blank.assert_not_called()
        for size in (0,2,4,32):
            with self.subTest(size=size),self.assertRaises(ValueError):m.validate_size('pack',size)

    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory(dir=TMP)
        self.addCleanup(self.temporary.cleanup)
        self.root=Path(self.temporary.name)
        self.tree=self.root/'tree.jsonl'
        self.security=self.root/'security.jsonl'
        self.actual=self.root/'actual.jsonl'
        self.manifest_path=self.root/'manifest.json'
        self.proof_path=self.root/'iso-proof.json'
        self.pack_path=self.root/'pack-proof.json'
        self.tree.write_text('{"path":"own"}\n',encoding='utf8')
        self.security.write_text('{"own_security":"fixture"}\n',encoding='utf8')
        self.actual.write_text(json.dumps(dict(path='sources/install.wim',directory=False,size=1024,sha256='2'*64))+'\n',encoding='utf8')
        self.manifest=dict(index=1,wim_sha256='2'*64,tree_sha256=m.oracle.digest(self.tree),
                           security_sha256=m.oracle.digest(self.security))
        self.proof=dict(passed=True,worktree_dirty=0,source_unchanged=True,iso_mounted=False,
                        extracted_tree=False,difference_count=0,sevenzip_exit=0,iso_sha256='1'*64,
                        actual_manifest_sha256=m.oracle.digest(self.actual))
        self.args=SimpleNamespace(action='apply',source=self.root/'nonexistent-source.iso',
                                  exe=self.root/'nonexistent-program.exe',out=self.root/'never-created',
                                  index=1,partition_start=1024*1024,partition_bytes=0,pack_proof=None,
                                  expected_tree=self.tree,expected_security=self.security,iso_proof=self.proof_path,
                                  plan=self.root/'nonexistent-plan.json',size_gib=6,qemu_img=self.root/'nonexistent-qemu.exe')
        self.pack=dict(passed=True,target_sha256='3'*64,source_sha256='1'*64,target=str(self.args.source),
                       partition_start=self.args.partition_start,partition_bytes=4096)
        self.save_receipts()
        owned=patch.object(m.oracle,'owned',side_effect=lambda path:path)
        owned.start();self.addCleanup(owned.stop)

    def save_receipts(self):
        for path,value in ((self.manifest_path,self.manifest),(self.proof_path,self.proof),(self.pack_path,self.pack)):
            path.write_text(json.dumps(value)+'\n',encoding='utf8')

    def test_correct_iso_proof_binds_wim_index_and_both_manifest_hashes(self):
        result=m.expectations(self.args,'1'*64)
        self.assertEqual(result['selected_index'],1)
        self.assertEqual(result['install_wim_sha256'],'2'*64)
        self.assertEqual(result['expected_tree_sha256'],m.oracle.digest(self.tree))
        self.assertEqual(result['expected_security_sha256'],m.oracle.digest(self.security))
        self.assertEqual(result['iso_proof_sha256'],m.oracle.digest(self.proof_path))

    def test_wrong_index_wim_hash_and_source_hash_are_refused(self):
        self.args.index=2
        with self.assertRaisesRegex(ValueError,'index/hash'):m.expectations(self.args,'1'*64)
        self.args.index=1;self.manifest['wim_sha256']='4'*64;self.save_receipts()
        with self.assertRaisesRegex(ValueError,'index/hash'):m.expectations(self.args,'1'*64)
        self.manifest['wim_sha256']='2'*64;self.save_receipts()
        with self.assertRaisesRegex(ValueError,'source hash'):m.expectations(self.args,'4'*64)

    def test_dirty_failed_mounted_extracted_or_different_iso_proof_is_refused(self):
        changes=dict(worktree_dirty=1,passed=False,source_unchanged=False,iso_mounted=True,
                     extracted_tree=True,difference_count=1,sevenzip_exit=2)
        for key,value in changes.items():
            old=self.proof[key];self.proof[key]=value;self.save_receipts()
            with self.subTest(field=key),self.assertRaisesRegex(ValueError,'complete clean read-only'):
                m.expectations(self.args,'1'*64)
            self.proof[key]=old

    def test_changed_actual_tree_or_security_manifest_is_refused(self):
        for path,message in ((self.actual,'ISO file manifest pin'),(self.tree,'tree/security pins'),
                             (self.security,'tree/security pins')):
            original=path.read_bytes();path.write_bytes(original+b'changed\n')
            with self.subTest(path=path.name),self.assertRaisesRegex(ValueError,message):
                m.expectations(self.args,'1'*64)
            path.write_bytes(original)

    def test_missing_or_duplicate_install_wim_in_pinned_iso_manifest_is_refused(self):
        original=self.actual.read_text(encoding='utf8')
        for text in ('',original+original,json.dumps(dict(path='sources/install.wim',directory=True))+'\n'):
            self.actual.write_text(text,encoding='utf8')
            self.proof['actual_manifest_sha256']=m.oracle.digest(self.actual);self.save_receipts()
            with self.subTest(text=text),self.assertRaisesRegex(ValueError,'index/hash'):
                m.expectations(self.args,'1'*64)

    def test_missing_independent_inputs_are_refused(self):
        for key in ('expected_tree','expected_security','iso_proof'):
            old=getattr(self.args,key);setattr(self.args,key,None)
            with self.subTest(key=key),self.assertRaisesRegex(ValueError,'Independent WIM manifests'):
                m.expectations(self.args,'1'*64)
            setattr(self.args,key,old)

    def test_correct_pack_receipt_binds_iso_source_partition_and_ntfs_image(self):
        self.args.partition_bytes=4096;self.args.pack_proof=self.pack_path
        result=m.expectations(self.args,'3'*64)
        self.assertEqual(result['install_wim_sha256'],'2'*64)
        self.assertFalse(self.args.source.exists())

    def test_missing_and_mismatched_pack_receipts_are_refused(self):
        self.args.partition_bytes=4096
        with self.assertRaisesRegex(ValueError,'requires its pack receipt'):m.expectations(self.args,'3'*64)
        self.args.pack_proof=self.pack_path
        changes=dict(passed=False,target_sha256='4'*64,source_sha256='4'*64,
                     target=str(self.root/'other.raw'),partition_start=512,partition_bytes=8192)
        for key,value in changes.items():
            old=self.pack[key];self.pack[key]=value;self.save_receipts()
            with self.subTest(key=key),self.assertRaisesRegex(ValueError,'does not bind'):
                m.expectations(self.args,'3'*64)
            self.pack[key]=old

    def test_expectation_failure_precedes_blank_image_creation(self):
        self.args.index=2
        original_digest=m.oracle.digest
        def small_digest(path):
            if path==self.args.source:return '1'*64
            if path==self.args.exe:return '5'*64
            return original_digest(path)
        with (patch.object(m.oracle,'digest',side_effect=small_digest),patch.object(m,'blank') as blank,
              patch.object(m,'execute') as execute):
            with self.assertRaisesRegex(ValueError,'index/hash'):m.run_locked(self.args,'own-head',{})
            blank.assert_not_called();execute.assert_not_called()
        self.assertFalse(self.args.out.exists())

    def test_dirty_run_stops_before_source_open_or_image_creation(self):
        with (patch.object(m.pool,'enforce',return_value={}),patch.object(m.logged_run,'tree',return_value=('own-head',1)),
              patch.object(m.oracle,'readonly') as readonly,patch.object(m,'blank') as blank):
            with self.assertRaisesRegex(ValueError,'Clean tree'):m.run(self.args)
            readonly.assert_not_called();blank.assert_not_called()
        self.assertFalse(self.args.out.exists())


if __name__=='__main__':unittest.main()
