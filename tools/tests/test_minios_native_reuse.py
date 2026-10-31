#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Small own container/receipt fixtures; never QEMU, chkdsk or native mounting."""
import contextlib
import copy
import json
import os
from pathlib import Path
import stat
import struct
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'minios'))
sys.path.insert(0,str(Path(__file__).resolve().parent))
import install_native as native
from test_minios_install_native import fixture

SIZE=32*1024**2


def qcow(backing,size=SIZE,mapped=False):
    raw=bytearray(2*65536)
    raw[:4]=b'QFI\xfb'
    struct.pack_into('>I',raw,4,3)
    name=backing.name.encode('utf-8')
    struct.pack_into('>QIIQ',raw,8,104,len(name),16,size)
    struct.pack_into('>IQ',raw,36,1,65536)
    struct.pack_into('>I',raw,100,104)
    raw[104:104+len(name)]=name
    if mapped:struct.pack_into('>Q',raw,65536,65536)
    return bytes(raw)


class ReuseTests(unittest.TestCase):
    def setUp(self):
        base=Path(__file__).resolve().parents[2]/'runtime';base.mkdir(exist_ok=True)
        self.temp=tempfile.TemporaryDirectory(prefix='native-reuse-unit-',dir=base)
        self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name)
        self.prep=self.root/'prep';self.prep.mkdir()
        self.vhd=self.prep/'target.vhd';self.vhd.write_bytes(fixture(False))
        self.wrapper=self.prep/'target.qcow2';self.wrapper.write_bytes(qcow(self.vhd))
        self.receipt=self.prep/'result.json'
        pin=native.oracle.digest(self.vhd)
        self.record=dict(schema='minios-install-firmware-v1',passed=True,qemu_only=True,dirty=0,head='a'*40,
                         mode='gpt',target=str(self.wrapper),target_bytes=SIZE,target_format='vpc',
                         target_sha256=native.oracle.digest(self.wrapper),prepared_vhd=str(self.vhd),
                         prepared_vhd_bytes=self.vhd.stat().st_size,prepared_vhd_sha256=pin,returncode=33,timed_out=False,
                         source_unchanged=True,base_unchanged=True,guest_completion_wait=True,physical_disks_opened=False,
                         prepared_vhd_normalization=dict(kind='fresh-owned-vhd-in-place-normalization',passed=True,
                            bytes=self.vhd.stat().st_size,virtual_bytes=SIZE,sha256_before=pin,sha256_after=pin,
                            exclusive_handle=True,operation='FSCTL_SET_SPARSE(FALSE)',source_qcow2_opened=False,
                            image_deleted=False,attributes_after=32))
        self.args=SimpleNamespace(source=self.wrapper,virtual_bytes=SIZE,mode='uefi',reuse_prepared_vhd=self.vhd,
                                  prep_receipt=self.receipt,prep_receipt_sha256=None,out=self.root/'native',
                                  expected_tree=self.root/'tree',expected_security=self.root/'security',
                                  qemu_img=Path(__file__).resolve(),pwsh=Path(__file__).resolve(),plan=self.root/'plan')
        self.save()
        os.chmod(self.vhd,stat.S_IREAD)

    def save(self):
        self.receipt.write_text(json.dumps(self.record),encoding='utf-8')
        self.args.prep_receipt_sha256=native.oracle.digest(self.receipt)

    def invoke(self):
        @contextlib.contextmanager
        def own_readonly(path):
            with path.open('rb') as source:yield source
        with patch.object(native.oracle,'RUNTIME',self.root),patch.object(native.oracle,'readonly',side_effect=own_readonly),contextlib.ExitStack() as locks:
            return native.prepared_reuse(self.args,locks)

    def test_completed_exact_immutable_dynamic_vhd_and_empty_wrapper_are_accepted(self):
        result=self.invoke()
        self.assertEqual(result['vhd'],self.vhd)
        self.assertEqual(result['sha256'],self.record['prepared_vhd_sha256'])
        self.assertEqual(result['wrapper_sha256'],self.record['target_sha256'])

    def test_failed_stale_forged_or_wrong_identity_receipt_refused(self):
        for key,value in [('passed',False),('dirty',1),('returncode',True),('target_format','qcow2'),('target_bytes',SIZE+512),
                          ('prepared_vhd_bytes',1),('prepared_vhd_sha256','0'*64),('target_sha256','0'*64),
                          ('mode','mbr'),('source_unchanged',False),('target',str(self.root/'another.qcow2'))]:
            original=self.record[key];self.record[key]=value;self.save()
            with self.subTest(key=key):
                with self.assertRaises(ValueError):self.invoke()
            self.record[key]=original
        self.save();self.args.prep_receipt_sha256='0'*64
        with self.assertRaises(ValueError):self.invoke()

    def test_normalization_must_be_completed_and_byte_preserving(self):
        original=copy.deepcopy(self.record['prepared_vhd_normalization'])
        for key,value in [('passed',False),('virtual_bytes',SIZE+512),('sha256_after','0'*64),('exclusive_handle',False),
                          ('source_qcow2_opened',True),('image_deleted',True),('attributes_after',0x220),('operation','other')]:
            self.record['prepared_vhd_normalization']=copy.deepcopy(original)
            self.record['prepared_vhd_normalization'][key]=value;self.save()
            with self.subTest(key=key):
                with self.assertRaises(ValueError):self.invoke()

    def test_rw_vhd_nonempty_wrapper_wrong_chain_and_virtual_size_refused(self):
        os.chmod(self.vhd,stat.S_IWRITE|stat.S_IREAD)
        with self.assertRaises(ValueError):self.invoke()
        os.chmod(self.vhd,stat.S_IREAD)
        self.wrapper.write_bytes(qcow(self.vhd,mapped=True));self.record['target_sha256']=native.oracle.digest(self.wrapper);self.save()
        with self.assertRaises(ValueError):self.invoke()
        self.wrapper.write_bytes(qcow(self.vhd,size=SIZE+512));self.record['target_sha256']=native.oracle.digest(self.wrapper);self.save()
        with self.assertRaises(ValueError):self.invoke()
        self.wrapper.write_bytes(qcow(self.vhd));self.record['target_sha256']=native.oracle.digest(self.wrapper);self.save()
        other=self.prep/'other.vhd';other.write_bytes(fixture(False))
        self.wrapper.write_bytes(qcow(other));self.record['target_sha256']=native.oracle.digest(self.wrapper);self.save()
        with self.assertRaises(ValueError):self.invoke()

    def test_chain_accepts_only_dynamic_exact_size_vhd_terminal(self):
        with patch.object(native.oracle,'RUNTIME',self.root):
            self.assertEqual(native.qcow_chain(self.wrapper,SIZE),[self.wrapper,self.vhd])
            with self.assertRaises(ValueError):native.qcow_chain(self.wrapper,SIZE+512)
            os.chmod(self.vhd,stat.S_IWRITE|stat.S_IREAD)
            data=bytearray(self.vhd.read_bytes());data[0]=0;self.vhd.write_bytes(data)
            with self.assertRaises(ValueError):native.qcow_chain(self.wrapper,SIZE)

    def test_incomplete_or_forged_reuse_refuses_before_output_convert_normalization_or_mount(self):
        for missing in ('prep_receipt','prep_receipt_sha256'):
            original=getattr(self.args,missing);setattr(self.args,missing,None)
            with patch.object(native.oracle,'RUNTIME',self.root),patch.object(native,'execute') as execute, \
                 patch.object(native,'normalize_fresh_vhd') as normalize:
                with self.assertRaises(ValueError):native.verify(self.args)
                execute.assert_not_called();normalize.assert_not_called();self.assertFalse(self.args.out.exists())
            setattr(self.args,missing,original)
        self.record['passed']=False;self.save()
        @contextlib.contextmanager
        def own_readonly(path):
            with path.open('rb') as source:yield source
        with patch.object(native.oracle,'RUNTIME',self.root),patch.object(native.oracle,'readonly',side_effect=own_readonly), \
             patch.object(native.logged_run,'tree',return_value=('a'*40,0)),patch.object(native,'execute') as execute, \
             patch.object(native,'normalize_fresh_vhd') as normalize,patch.object(native.pool,'enforce_incremental') as capacity:
            with self.assertRaises(ValueError):native.verify(self.args)
            execute.assert_not_called();normalize.assert_not_called();capacity.assert_not_called()
            self.assertFalse(self.args.out.exists())

    def test_reuse_orchestration_compares_readonly_original_without_convert_or_normalize(self):
        for path in (self.args.expected_tree,self.args.expected_security):path.write_text('own-manifest',encoding='utf-8')
        layout=dict(windows_number=3,partitions=[dict(number=1,filesystem='FAT32',start=1024**2,bytes=4*1024**2),
                                                dict(number=3,filesystem='NTFS',start=5*1024**2,bytes=27*1024**2)])
        commands=[]
        def execute(command,log,env,head):
            commands.append(command)
            log.write_text('own-no-process-fixture',encoding='utf-8')
            if command[1]!='compare':
                flag='-Out' if '-Out' in command else '-InstallOut'
                out=command[command.index(flag)+1];out.mkdir()
                (out/'result.json').write_text(json.dumps(dict(passed=True,chkdsk_exit=0)),encoding='utf-8')
        def security(vhd,sha,expected,tree,out,**kwargs):
            self.assertEqual(vhd,self.vhd)
            out.write_text('{"passed":true}',encoding='utf-8')
            return dict(passed=True)
        @contextlib.contextmanager
        def own_readonly(path):
            with path.open('rb') as source:yield source
        with patch.object(native.oracle,'RUNTIME',self.root),patch.object(native.oracle,'readonly',side_effect=own_readonly), \
             patch.object(native.logged_run,'tree',return_value=('a'*40,0)),patch.object(native,'disk_layout',return_value=layout), \
             patch.object(native.pool,'enforce_incremental',return_value=dict(passed=True)) as capacity, \
             patch.object(native,'execute',side_effect=execute),patch.object(native,'normalize_fresh_vhd') as normalize, \
             patch.object(native.os,'chmod') as chmod,patch('wim_security_readonly.verify_tree',side_effect=security):
            result=native.verify(self.args)
            normalize.assert_not_called();chmod.assert_not_called()
            capacity.assert_called_once_with(self.args.plan,self.args.out,512*1024**2,closed_scope=True)
        self.assertEqual(commands[0],[self.args.qemu_img,'compare','-f','qcow2','-F','vpc',self.wrapper,self.vhd])
        self.assertFalse(any('convert' in command for command in commands))
        self.assertEqual(len(commands),3)
        self.assertEqual(result['vhd'],str(self.vhd))
        self.assertTrue(result['reused_prepared_vhd'])
        self.assertFalse(result['vhd_export_performed'])
        self.assertFalse((self.args.out/'readonly-install.vhd').exists())


if __name__=='__main__':unittest.main()
