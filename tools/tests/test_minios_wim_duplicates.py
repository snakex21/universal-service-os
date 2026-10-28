# SPDX-License-Identifier: GPL-3.0-or-later
"""Construct own duplicate lookup fixtures; never mutate a Windows WIM."""
import importlib.util
import json
from pathlib import Path
import struct
import sys
import unittest
from unittest import mock
import uuid
sys.path.insert(0,str(Path(__file__).parents[1]/'minios'))
import wim_duplicate_case as m


def own():
    raw=bytearray(300);raw[:8]=b'MSWIM\0\0\0'
    raw[48:56]=(50).to_bytes(8,'little');raw[55]=2
    struct.pack_into('<QQ',raw,56,208,50)
    struct.pack_into('<QQQHI',raw,208,4,280,4,1,1)
    raw[238:258]=bytes(range(20));raw[280:284]=b'own!'
    return bytes(raw)


class Duplicates(unittest.TestCase):
    def capture_case(self):
        # Keep these tiny receipts beside the application's other test data.
        out=m.oracle.RUNTIME/'1c1'/'duplicate-helper-tests'/uuid.uuid4().hex
        out.mkdir(parents=True)
        source=out/'source';source.mkdir()
        return source,out

    def test_capture_labels_log_before_writing_receipt_once_and_never_overwrites(self):
        source,out=self.capture_case()
        revision=('a'*40,0)
        def execute(command,**kwargs):
            kwargs['stdout'].write(b'own capture complete\n')
            return m.subprocess.CompletedProcess(command,0)
        with mock.patch.object(m.subprocess,'run',side_effect=execute) as child:
            receipt=m.capture_fixture(source,out,{},revision)
            self.assertEqual(child.call_count,1)
            log=(out/'capture.txt').read_bytes();stored=(out/'capture.json').read_bytes()
            self.assertTrue(log.startswith(b'HEAD '+b'a'*40+b'\nWORKTREE_DIRTY 0\n'))
            self.assertEqual(json.loads(stored),receipt)
            self.assertEqual(receipt['sha256'],m.oracle.digest(out/'capture.txt'))
            self.assertEqual(receipt['head'],revision[0]);self.assertEqual(receipt['dirty'],0)
            with self.assertRaises(FileExistsError):m.capture_fixture(source,out,{},revision)
            self.assertEqual(child.call_count,1)
            self.assertEqual((out/'capture.txt').read_bytes(),log)
            self.assertEqual((out/'capture.json').read_bytes(),stored)

    def test_capture_failure_keeps_consistent_log_and_failure_receipt(self):
        source,out=self.capture_case()
        def execute(command,**kwargs):
            kwargs['stdout'].write(b'own capture refused\n')
            return m.subprocess.CompletedProcess(command,2)
        with mock.patch.object(m.subprocess,'run',side_effect=execute):
            with self.assertRaisesRegex(ValueError,'capture failed'):
                m.capture_fixture(source,out,{},('b'*40,3))
        receipt=json.loads((out/'capture.json').read_text(encoding='utf-8'))
        self.assertEqual(receipt['exit'],2)
        self.assertEqual(receipt['sha256'],m.oracle.digest(out/'capture.txt'))
        self.assertTrue((out/'capture.txt').read_bytes().startswith(b'HEAD '+b'b'*40+b'\nWORKTREE_DIRTY 3\n'))

    def test_identical_table_append_keeps_source_and_first_entry(self):
        source=own();actual=m.duplicate_lookup(source)
        self.assertEqual(source,own())
        self.assertEqual(actual[300:350],actual[350:400])
        self.assertEqual(actual[300:350],source[208:258])
        self.assertEqual(struct.unpack_from('<QQ',actual,56),(300,100))
        self.assertEqual(actual[55],2)

    def test_conflict_retains_hash_but_changes_resource_offset_and_content(self):
        actual=m.duplicate_lookup(own(),conflicting=True)
        self.assertEqual(actual[300:304],b'\xff'*4)
        self.assertEqual(actual[334:354],actual[384:404])
        self.assertNotEqual(actual[312:320],actual[362:370])

    def test_relocated_identical_blob_has_own_storage_and_exact_hash_and_size(self):
        original=own();actual=m.duplicate_lookup(original,relocated=True)
        self.assertEqual(actual[300:304],b'own!')
        table_at,table_size=struct.unpack_from('<QQ',actual,56)
        self.assertEqual(table_size,100)
        first=actual[table_at:table_at+50];second=actual[table_at+50:table_at+100]
        self.assertEqual(first[30:],second[30:])
        self.assertEqual(first[16:24],second[16:24])
        self.assertNotEqual(first[8:16],second[8:16])
        self.assertEqual(original,own())

    def test_conflicting_size_retains_claimed_hash_but_changes_size(self):
        actual=m.duplicate_lookup(own(),different_size=True)
        table_at,_=struct.unpack_from('<QQ',actual,56)
        first=actual[table_at:table_at+50];second=actual[table_at+50:table_at+100]
        self.assertEqual(first[30:],second[30:])
        self.assertEqual(int.from_bytes(first[16:24],'little'),4)
        self.assertEqual(int.from_bytes(second[16:24],'little'),3)
        self.assertEqual(actual[300:303],b'\xff'*3)
        with self.assertRaises(ValueError):m.duplicate_lookup(own(),conflicting=True,relocated=True)

    def test_truncation_and_compressed_lookup_refused(self):
        for source in (own()[:100],own()[:240]):
            with self.assertRaises(ValueError):m.duplicate_lookup(source)
        data=bytearray(own());data[55]=4
        with self.assertRaises(ValueError):m.duplicate_lookup(data)


if __name__=='__main__':unittest.main()
