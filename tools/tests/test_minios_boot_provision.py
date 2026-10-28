#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Own JSON/BPB fixtures only; no images, native mounts or QEMU process."""
import contextlib
import copy
import json
from pathlib import Path
import struct
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'minios'))
import boot_provision_case as c


class BootProvisionTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(__file__).resolve().parents[2] / 'runtime'
        self.root.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='boot-gate-unit-', dir=self.root)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.head = 'a' * 40
        self.pin = dict(native='a' * 64, reference='b' * 64, ours_bcd='c' * 64, reference_bcd='d' * 64)
        self.layout = dict(style='GPT', disk_guid='00112233-4455-4677-8899-aabbccddeeff',
                           partitions=[dict(number=1, guid='10213243-5465-4677-8899-aabbccddeeff', start=1024**2, bytes=300*1024**2),
                                       dict(number=2, guid='20314253-6475-4677-8899-aabbccddeeff', start=301*1024**2, bytes=16*1024**2),
                                       dict(number=3, guid='30415263-7485-4677-8899-aabbccddeeff', start=317*1024**2, bytes=30*1024**3)])
        self.route = dict(system=dict(style='GPT', disk_guid_le=uuid.UUID(self.layout['disk_guid']).bytes_le.hex(),
                                      partition_guid_le=uuid.UUID(self.layout['partitions'][0]['guid']).bytes_le.hex()),
                          windows=dict(style='GPT', disk_guid_le=uuid.UUID(self.layout['disk_guid']).bytes_le.hex(),
                                       partition_guid_le=uuid.UUID(self.layout['partitions'][2]['guid']).bytes_le.hex()),
                          manager_path='\\efi\\microsoft\\boot\\bootmgfw.efi', loader_path='\\windows\\system32\\winload.efi',
                          systemroot='\\windows', winpe=False, manager_locale='pl-pl', loader_locale='pl-pl')
        self.route['osdevice'] = copy.deepcopy(self.route['windows'])
        self.prep = dict(schema='minios-install-firmware-v1', passed=True, qemu_only=True, head=self.head, dirty=0,
                         mode='gpt', source_unchanged=True, base_unchanged=True, returncode=33, timed_out=False,
                         physical_disks_opened=False, guest_completion_wait=True, target_bytes=32*1024**3, target_sha256='e'*64)
        self.native = dict(mode='uefi', virtual_bytes=32*1024**3, source_sha256='e'*64, vhd_sha256='f'*64)
        self.reference = dict(schema='minios-bcdboot-reference-v1', passed=True, worktree_dirty=0, worktree_dirty_after=0,
                              head=self.head, head_after=self.head, native_receipt_sha256=self.pin['native'],
                              bcdboot_exit=0, bcdedit_exit=0, physical_disk_touched=False, host_firmware_entry_requested=False,
                              base_sha256_before='f'*64, base_sha256_after='f'*64, mode='uefi', virtual_bytes=32*1024**3,
                              reference_sha256=self.pin['reference_bcd'])
        self.compare = dict(status='PASS', core_differences={}, dirty=0, after_dirty=0, head=self.head, after_head=self.head,
                            source_sha256=self.pin['ours_bcd'], reference_sha256=self.pin['reference_bcd'],
                            bcdboot_receipt_sha256=self.pin['reference'], ours_route=self.route, reference_route=copy.deepcopy(self.route))

    def fields(self):
        return c.receipt_fields(self.prep, self.native, self.layout, self.reference, self.compare, self.pin)

    def test_complete_semantic_chain_and_actual_layout_route(self):
        self.fields()
        c.route_for_layout(self.route, self.layout)

    def test_failed_forged_stale_or_incomplete_receipt_fields_refused(self):
        for document, key, value in ((self.prep, 'passed', False), (self.prep, 'dirty', 1), (self.prep, 'returncode', True),
                                     (self.native, 'source_sha256', '0'*64), (self.native, 'mode', 'bios'),
                                     (self.reference, 'native_receipt_sha256', '0'*64), (self.reference, 'physical_disk_touched', True),
                                     (self.reference, 'host_firmware_entry_requested', True), (self.reference, 'base_sha256_after', '0'*64),
                                     (self.reference, 'bcdboot_exit', 1), (self.compare, 'core_differences', {'device': 1}),
                                     (self.compare, 'after_head', '0'*40), (self.compare, 'bcdboot_receipt_sha256', '0'*64)):
            with self.subTest(key=key, value=value):
                old = document[key]
                document[key] = value
                with self.assertRaises(ValueError): self.fields()
                document[key] = old
        self.reference.pop('bcdedit_exit')
        with self.assertRaises(ValueError): self.fields()

    def test_route_for_another_partition_or_loader_is_refused(self):
        for key, value in [('system', self.route['windows']), ('loader_path', '\\windows\\system32\\winload.exe'),
                           ('winpe', True), ('loader_locale', '../../unsafe')]:
            changed = copy.deepcopy(self.route); changed[key] = value
            with self.assertRaises(ValueError): c.route_for_layout(changed, self.layout)

    def test_output_guard_rejects_outside_existing_and_wrong_arch_before_image_io(self):
        with patch.object(c.oracle, 'RUNTIME', self.root):
            good = self.root/'1c23/qemu-x64/boot-case'
            self.assertEqual(c.output_guard(good, 'x86_64'), good)
            for bad in (self.root/'outside/boot-case', self.root/'1c23/qemu-ia32/boot-case', self.root/'1c23/qemu-x64'):
                with self.assertRaises(ValueError): c.output_guard(bad, 'x86_64')
            good.mkdir(parents=True)
            with self.assertRaises(ValueError): c.output_guard(good, 'x86_64')

    def arguments(self):
        args = SimpleNamespace(out=self.root/'1c23/qemu-x64/boot-case', arch='x86_64',
                               program=Path(__file__).resolve(), qemu_dir=Path(__file__).resolve().parent,
                               program_sha256='0'*64, memory=128, timeout=300)
        for name in ('prep', 'native', 'reference', 'compare'):
            setattr(args, name+'_receipt', self.root/(name+'.json'))
            setattr(args, name+'_sha256', '0'*64)
        return args

    def negative_run(self, args):
        @contextlib.contextmanager
        def own_file_only_lock(path):
            with path.open('rb') as stream: yield stream
        with patch.object(c.oracle, 'RUNTIME', self.root), patch.object(c.oracle, 'readonly', side_effect=own_file_only_lock), \
             patch.object(c.logged_run, 'tree', return_value=(self.head, 0)), \
             patch.object(c.firmware, 'SmallEsp') as writer, patch.object(c.subprocess, 'Popen') as process, \
             patch.object(c.pool, 'enforce_incremental') as capacity:
            with self.assertRaises((ValueError, FileNotFoundError)): c.run(args)
            writer.assert_not_called(); process.assert_not_called(); capacity.assert_not_called()
        self.assertFalse(args.out.exists())

    def test_missing_real_receipt_refuses_before_any_image_or_output(self):
        self.negative_run(self.arguments())

    def test_real_json_with_forged_approved_hash_refuses_before_any_image(self):
        args = self.arguments()
        args.prep_receipt.write_text(json.dumps(self.prep), encoding='utf-8')
        self.negative_run(args)

    def test_deleted_semantic_receipt_is_not_replaced_with_a_pass_flag(self):
        args = self.arguments()
        for name, doc in (('prep', self.prep), ('native', self.native), ('reference', self.reference)):
            path = getattr(args, name+'_receipt')
            path.write_text(json.dumps(doc), encoding='utf-8')
            setattr(args, name+'_sha256', c.oracle.digest(path))
        self.negative_run(args)

    def test_identity_comes_from_readonly_gpt_bpb_and_exact_completed_log(self):
        bpb = bytearray(512); bpb[3:11] = b'NTFS    '; struct.pack_into('<H', bpb, 11, 512); struct.pack_into('<Q', bpb, 72, 0x123456789abcdef0)
        reader = SimpleNamespace(seek=lambda offset: None, read=lambda count: bytes(bpb))
        rows = self.layout['partitions']
        disk = uuid.UUID(self.layout['disk_guid']).bytes_le.hex()
        windows = uuid.UUID(rows[2]['guid']).bytes_le.hex(); esp = uuid.UUID(rows[0]['guid']).bytes_le.hex()
        debug = f'INSTALL layout_mode=uefi disk_guid={disk} windows_guid={windows} esp_guid={esp} mbr_signature=abcdef windows_start={rows[2]["start"]} windows_size={rows[2]["bytes"]} system_start={rows[0]["start"]} system_size={rows[0]["bytes"]}\n'
        with patch.object(c.native, 'disk_layout', return_value=self.layout):
            ids = c.actual_ids(reader, self.layout, debug)
            self.assertEqual(ids['ntfs_serial'], '123456789abcdef0')
            self.assertEqual(ids['msr_guid'], uuid.UUID(rows[1]['guid']).bytes_le.hex())
            with self.assertRaises(ValueError): c.actual_ids(reader, self.layout, debug.replace(esp, '0'*32))
            with self.assertRaises(ValueError): c.actual_ids(reader, self.layout, debug+debug)
        loader = uuid.UUID('40516273-8495-4677-8899-aabbccddeeff')
        config = c.configuration(ids, loader, 32*1024**3, 'x86_64', 'pl-pl', '1'*64, '2'*64)
        self.assertIn(b'layout_gate=pass\nbcd_gate=pass\n', config)
        self.assertIn(b'loader_guid='+loader.bytes_le.hex().encode()+b'\n', config)
        self.assertLessEqual(len(config),4096)

    def test_guest_completion_requires_real_pass_and_no_failure(self):
        text = 'BOOT_UEFI PASS\nUSOSBOOT FINAL\nSTACK canary_ok=true\nUSOSPREP PLATFORM\n'
        self.assertTrue(c.guest_acceptance(33,False,text))
        for code in (0,35,None,True): self.assertFalse(c.guest_acceptance(code,False,text))
        self.assertFalse(c.guest_acceptance(33,True,text))
        self.assertFalse(c.guest_acceptance(33,False,text+'TERMINAL FAIL'))
        self.assertFalse(c.guest_acceptance(33,False,text.replace('BOOT_UEFI PASS','')))

    def test_only_normal_capacity_policy_is_reachable(self):
        args = self.arguments()
        args.plan = self.root/'plan.json'
        with patch.object(c.pool, 'enforce_incremental', return_value={'ordinary': True}) as normal:
            self.assertEqual(c.capacity_preflight(args), {'ordinary': True})
            normal.assert_called_once_with(args.plan,args.out,c.MAX_NEW_BYTES,closed_scope=True)
            for field in ('approval', 'firstboot_receipt'):
                setattr(args, field, self.root/'historical.json')
                with self.assertRaisesRegex(ValueError, 'no longer supported'):
                    c.capacity_preflight(args)
                delattr(args, field)


if __name__ == '__main__': unittest.main()
