#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""No native disk APIs: acceptance-proof and refusal-path unit tests."""
import copy
import contextlib
from pathlib import Path
from types import SimpleNamespace
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'minios'))
import bcdboot_reference as reference


class ReferenceTests(unittest.TestCase):
    def setUp(self):
        self.folder = reference.oracle.RUNTIME / '1c23' / 'qemu-x64' / 'native'
        self.proof_path = self.folder / 'result.json'
        self.base = self.folder / 'readonly-install.vhd'
        self.layout = dict(schema='minios-install-layout-v1', mode='uefi', image_bytes=32*1024**3,
                           sector_bytes=512, windows_number=3, system_number=1,
                           partitions=[dict(number=1, filesystem='FAT32'), dict(number=2, filesystem=None),
                                       dict(number=3, filesystem='NTFS')])
        self.proof = dict(schema='minios-install-native-v1', passed=True, dirty=0, head='a'*40,
                          boot_attempted=False, deleted=False, source_backing_chain_unchanged=True,
                          extra_full_raw_or_fixed_vhd_copies=0, mode='uefi', vhd=str(self.base),
                          vhd_bytes=123456, vhd_sha256='b'*64, virtual_bytes=32*1024**3,
                          layout_sha256='c'*64,
                          native_results=[dict(number=1, filesystem='FAT32', result='native-1/result.json', sha256='d'*64,chkdsk_exit=0),
                                          dict(number=3, filesystem='NTFS', result='native-3/result.json', sha256='e'*64,chkdsk_exit=0)])
        self.docs = {self.proof_path:self.proof, self.folder/'layout.json':self.layout,
                     self.folder/'native-1/result.json':dict(passed=True,chkdsk_exit=0),
                     self.folder/'native-3/result.json':dict(passed=True,chkdsk_exit=0)}
        self.attrs=1
        self.closed=False
        self.reuse_result=None
        self.reuse_pins={}

    def accept(self):
        reader=SimpleNamespace(size=32*1024**3,close=lambda:setattr(self,'closed',True))
        with patch.object(reference,'document',side_effect=lambda path,sha:self.docs[path]), \
             patch.object(reference.native,'regular',side_effect=lambda path:path), \
             patch.object(reference.oracle,'owned',side_effect=lambda path:path), \
             patch.object(Path,'stat',return_value=SimpleNamespace(st_size=123456,st_file_attributes=self.attrs)), \
             patch.object(reference.native,'DynamicVhd',return_value=reader), \
             patch.object(reference.native,'disk_layout',return_value=copy.deepcopy(self.layout)), \
             patch.object(reference.oracle,'digest',return_value='b'*64), \
             patch.object(reference.oracle,'readonly',side_effect=lambda path:contextlib.nullcontext(path)), \
             patch.object(reference.oracle,'digest_stream',side_effect=lambda path:self.reuse_pins[path]), \
             patch.object(reference.native,'prepared_reuse',side_effect=lambda args,locks:self.reuse_result):
            return reference.accepted(self.proof_path,'f'*64)

    def test_complete_acceptance_binds_every_child_and_closes_reader(self):
        proof,layout,pins=self.accept()
        self.assertEqual(proof,self.proof)
        self.assertEqual(layout,self.layout)
        self.assertEqual(len(pins),5)
        self.assertIn(self.base,pins)
        self.assertTrue(self.closed)

    def test_not_passed_dirty_booted_deleted_and_missing_gate_refused(self):
        for key,value in [('passed',False),('dirty',1),('boot_attempted',True),('deleted',True),
                          ('source_backing_chain_unchanged',False),('head','')]:
            with self.subTest(key=key):
                old=self.proof[key];self.proof[key]=value
                with self.assertRaises(ValueError):self.accept()
                self.proof[key]=old
        self.proof['native_results'].pop()
        with self.assertRaises(ValueError):self.accept()

    def test_failed_chkdsk_child_refused(self):
        self.docs[self.folder/'native-3/result.json']['chkdsk_exit']=3
        with self.assertRaises(ValueError):self.accept()

    def test_result_path_escape_and_alias_duplicate_refused(self):
        for bad in ['../escape.json','Z:/host.json','native-1/result.json:stream','native-1/\nresult.json']:
            with self.subTest(path=bad):
                self.proof['native_results'][0]['result']=bad
                with self.assertRaises(ValueError):self.accept()
        self.proof['native_results'][0]['result']='native-1/result.json'
        self.proof['native_results'][1]['number']=1
        with self.assertRaises(ValueError):self.accept()

    def test_writable_sparse_or_relocated_base_refused(self):
        for attrs in [0,0x201]:
            self.attrs=attrs
            with self.assertRaises(ValueError):self.accept()
        self.attrs=1
        self.proof['vhd']=str(self.folder.parent/'different.vhd')
        with self.assertRaises(ValueError):self.accept()

    def test_wrong_virtual_geometry_refused(self):
        self.layout['image_bytes']-=512
        with self.assertRaises(ValueError):self.accept()

    def reused(self):
        self.base=self.folder.parent/'prep/target.vhd'
        source=self.base.with_name('target.qcow2');prep=self.base.with_name('result.json')
        normalization=dict(kind='own-normalization-fixture',passed=True)
        self.proof.update(vhd=str(self.base),reused_prepared_vhd=True,vhd_export_performed=False,
                          normalization_performed_during_native=False,prepared_logical_compare_exit=0,
                          source_sha256='1'*64,normalization=normalization,prep_receipt=str(prep),prep_receipt_sha256='2'*64,
                          source_backing_chain=[dict(path=str(source.relative_to(reference.oracle.RUNTIME)),sha256='1'*64),
                                                dict(path=str(self.base.relative_to(reference.oracle.RUNTIME)),sha256='b'*64)])
        self.reuse_result=dict(vhd=self.base,sha256='b'*64,normalization=normalization)
        self.reuse_pins={source:'1'*64,self.base:'b'*64}
        return source,prep

    def test_external_prepared_base_requires_revalidated_reuse_and_pins_its_receipt_and_wrapper(self):
        source,prep=self.reused()
        proof,layout,pins=self.accept()
        self.assertEqual(pins[source],'1'*64)
        self.assertEqual(pins[prep],'2'*64)
        self.assertEqual(pins[self.base],'b'*64)
        self.assertTrue(self.closed)
        self.proof['reused_prepared_vhd']=False
        with self.assertRaises(ValueError):self.accept()

    def test_reused_base_export_normalization_compare_and_chain_cannot_be_forged(self):
        self.reused()
        for key,value in [('vhd_export_performed',True),('normalization_performed_during_native',True),
                          ('prepared_logical_compare_exit',False),('prepared_logical_compare_exit',1),
                          ('source_sha256','3'*64),('source_backing_chain',[]),('reused_prepared_vhd',1)]:
            old=self.proof[key];self.proof[key]=value
            with self.subTest(key=key,value=value),self.assertRaises(ValueError):self.accept()
            self.proof[key]=old
        self.proof['source_backing_chain'][0]['path']='../escape.qcow2'
        with self.assertRaises(ValueError):self.accept()

    def test_reused_normalization_must_match_the_original_firmware_contract(self):
        self.reused()
        self.reuse_result['normalization']={'different':'proof'}
        with self.assertRaises(ValueError):self.accept()


if __name__=='__main__':unittest.main()
