#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Own JSON/BPB/entropy fixtures; no native mounts or guest executions."""
import contextlib
import copy
import hashlib
import json
from pathlib import Path
import struct
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import uuid
import zlib

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'minios'))
import bios_boot_provision_case as c


class BiosBootProvisionTests(unittest.TestCase):
    def setUp(self):
        root=Path(__file__).resolve().parents[2]/'runtime'; root.mkdir(exist_ok=True)
        self.temp=tempfile.TemporaryDirectory(prefix='bios-boot-gate-unit-',dir=root); self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name); self.head='a'*40; self.seed=bytes(range(1,65)); self.ids=c.ids_from_seed(self.seed)
        self.layout=dict(style='MBR',image_bytes=16*1024**3,mbr_signature=self.ids['mbr_signature'],
                         partitions=[dict(number=1,start=c.MiB,bytes=100*c.MiB),dict(number=2,start=101*c.MiB,bytes=16*1024**3-101*c.MiB)])
        self.route=dict(system=dict(style='MBR',signature=self.ids['mbr_signature'],byte_offset=c.MiB),
                        windows=dict(style='MBR',signature=self.ids['mbr_signature'],byte_offset=101*c.MiB),
                        manager_path='\\bootmgr',loader_path='\\windows\\system32\\winload.exe',systemroot='\\windows',winpe=False,
                        manager_locale='pl-pl',loader_locale='pl-pl')
        self.route['osdevice']=copy.deepcopy(self.route['windows'])
        self.pin=dict(native='a'*64,reference='b'*64,ours_bcd='c'*64,reference_bcd='d'*64)
        self.prep=dict(schema='minios-install-firmware-v1',passed=True,qemu_only=True,head=self.head,dirty=0,mode='mbr',arch='bios',cpu='486',
                       source_unchanged=True,base_unchanged=True,source_writes=0,returncode=33,timed_out=False,physical_disks_opened=False,
                       guest_completion_wait=True,windows_boot_attempted=False,entropy_unchanged=True,entropy_sha256=hashlib.sha256(self.seed).hexdigest(),
                       target_bytes=16*1024**3,target_sha256='e'*64)
        self.native=dict(mode='bios',virtual_bytes=16*1024**3,source_sha256='e'*64,vhd_sha256='f'*64)
        self.reference=dict(schema='minios-bcdboot-reference-v1',passed=True,worktree_dirty=0,worktree_dirty_after=0,head=self.head,head_after=self.head,
                            native_receipt_sha256=self.pin['native'],bcdboot_exit=0,bcdedit_exit=0,physical_disk_touched=False,
                            host_firmware_entry_requested=False,base_sha256_before='f'*64,base_sha256_after='f'*64,mode='bios',
                            virtual_bytes=16*1024**3,reference_sha256=self.pin['reference_bcd'])
        self.compare=dict(status='PASS',core_differences={},dirty=0,after_dirty=0,head=self.head,after_head=self.head,source_sha256=self.pin['ours_bcd'],
                          reference_sha256=self.pin['reference_bcd'],bcdboot_receipt_sha256=self.pin['reference'],ours_route=self.route,reference_route=copy.deepcopy(self.route))
        self.log=('BOOT_BIOS PASS files=7\nSTACK BIOS reserved=253952 high_water=40000 guard=4096 guard_intact=true\n'
                  'HEAP physical_current=0 physical_peak=8000000 extent_peak=9000000 reserved=12582912\n'
                  'USOSBOOT FINAL alloc_current=0 alloc_peak=7000000 target_reads=123 target_writes=55 denied_windows_writes=0; separate gate\n')

    def fields(self):
        c.receipt_fields(self.prep,self.native,self.layout,self.reference,self.compare,self.pin)

    def debug(self):
        return ('ENTROPY source=fw_cfg_host_csprng bytes=64 expansion=SHA256-domain-v2 qemu_detected=true\n'
                'WIM_SHA1 ALL_BLOBS PASS count=123 before_target_write=true alloc_peak=2000000\n'
                f"INSTALL_SYSTEM NTFS start={c.MiB} bytes={100*c.MiB} serial={self.ids['system_serial']:016x} fresh=true empty=true\n"
                f"INSTALL_LAYOUT mode=bios windows_start={101*c.MiB} windows_bytes={self.layout['partitions'][1]['bytes']} source_verified_before_target_write=true\n")

    def reader(self):
        blobs={}
        for row,key in zip(self.layout['partitions'],('system_serial','ntfs_serial')):
            bpb=bytearray(512); bpb[3:11]=b'NTFS    '; struct.pack_into('<H',bpb,11,512); bpb[13]=8
            struct.pack_into('<I',bpb,28,row['start']//512); struct.pack_into('<Q',bpb,40,row['bytes']//512-1)
            struct.pack_into('<Q',bpb,72,self.ids[key]); bpb[510:]=b'\x55\xaa'
            blobs[row['start']]=bytes(bpb); blobs[row['start']+row['bytes']-512]=bytes(bpb)
        class Reader:
            def seek(self,at): self.at=at
            def read(self,n): return blobs[self.at][:n]
        return Reader(),blobs

    def test_complete_receipt_chain_and_bios_route(self):
        self.fields(); c.route_for_layout(self.route,self.layout)

    def test_failed_forged_stale_or_missing_gate_is_refused(self):
        changes=((self.prep,'passed',False),(self.prep,'returncode',True),(self.prep,'source_writes',True),
                 (self.prep,'source_writes',1),(self.prep,'entropy_unchanged',False),(self.prep,'entropy_sha256','unknown'),
                 (self.prep,'cpu','qemu32'),(self.prep,'windows_boot_attempted',True),(self.prep,'dirty',1),
                 (self.native,'mode','uefi'),(self.native,'source_sha256','0'*64),
                 (self.reference,'mode','uefi'),(self.reference,'native_receipt_sha256','0'*64),
                 (self.reference,'base_sha256_after','0'*64),(self.reference,'physical_disk_touched',True),
                 (self.reference,'host_firmware_entry_requested',True),(self.reference,'bcdboot_exit',1),
                 (self.reference,'head_after','0'*40),(self.compare,'bcdboot_receipt_sha256','0'*64),
                 (self.compare,'core_differences',{'partition':1}),(self.compare,'after_dirty',1))
        for doc,key,value in changes:
            with self.subTest(key=key,value=value):
                old=doc[key]; doc[key]=value
                with self.assertRaises(ValueError):self.fields()
                doc[key]=old
        self.reference.pop('bcdedit_exit')
        with self.assertRaises(ValueError):self.fields()

    def test_bcd_another_signature_offset_loader_or_locale_is_refused(self):
        for key,value in (('windows',{**self.route['windows'],'byte_offset':102*c.MiB}),('system',{**self.route['system'],'signature':5}),
                          ('manager_path','\\efi\\microsoft\\boot\\bootmgfw.efi'),('loader_path','\\windows\\system32\\winload.efi'),
                          ('winpe',True),('loader_locale','../unsafe')):
            changed={**self.route,key:value}
            with self.subTest(key=key),self.assertRaises(ValueError):c.route_for_layout(changed,self.layout)

    def test_original_entropy_expansion_matches_documented_firmware_vector(self):
        self.assertEqual(self.ids['mbr_signature'],0x24232221); self.assertEqual(self.ids['ntfs_serial'],0x2c2b2a2928272625)
        self.assertEqual(self.ids['disk_guid'],'0102030405060748890a0b0c0d0e0f10')
        expected=bytearray(hashlib.sha256(self.seed+b'USOSPREP Windows layout identity v2\0').digest()[:16])
        expected[7]=(expected[7]&15)|64; expected[8]=(expected[8]&63)|128
        self.assertEqual(self.ids['esp_guid'],expected.hex()); self.assertEqual(len(set(self.ids[key] for key in ('disk_guid','windows_guid','esp_guid','msr_guid'))),4)
        self.assertNotEqual(self.ids['ntfs_serial'],self.ids['system_serial'])
        for seed in (b'',bytes(64),b'\xff'*64,b'ABCD'*16,self.seed[:60]+self.seed[:4]):
            with self.assertRaises(ValueError):c.ids_from_seed(seed)

    def test_actual_mbr_and_two_ntfs_backup_geometry_are_bound_to_original_entropy(self):
        reader,_=self.reader()
        with patch.object(c.native,'disk_layout',return_value=self.layout):
            self.assertEqual(c.actual_ids(reader,self.layout,self.debug(),self.seed),self.ids)
            for debug in (self.debug().replace('SHA256-domain-v2','SHA512-v1'),self.debug()+self.debug(),self.debug().replace('fresh=true','fresh=false')):
                with self.assertRaises(ValueError):c.actual_ids(reader,self.layout,debug,self.seed)
            changed=bytearray(self.seed); changed[32]^=1
            with self.assertRaises(ValueError):c.actual_ids(reader,self.layout,self.debug(),bytes(changed))

    def test_actual_ntfs_backup_corruption_or_wrong_serial_refuses(self):
        for field in (11,13,28,40,72,510):
            reader,blobs=self.reader(); backup=self.layout['partitions'][0]['start']+self.layout['partitions'][0]['bytes']-512
            bad=bytearray(blobs[backup]);bad[field]^=1;blobs[backup]=bytes(bad)
            with self.subTest(field=field),patch.object(c.native,'disk_layout',return_value=self.layout),self.assertRaises(ValueError):
                c.actual_ids(reader,self.layout,self.debug(),self.seed)

    def test_selected_layout_requires_final_stream_pass_and_legacy_requires_prior_all_blobs(self):
        reader,_=self.reader()
        old=self.debug()
        all_blobs='WIM_SHA1 ALL_BLOBS PASS count=123 before_target_write=true alloc_peak=2000000\n'
        selected='WIM_SHA1 SELECTED_STREAMS PASS selected=1 metadata=verified all_applied_streams=verified\n'
        new=old.replace(all_blobs,'').replace('source_verified_before_target_write','selected_metadata_verified_before_target_write')
        with patch.object(c.native,'disk_layout',return_value=self.layout):
            self.assertEqual(c.actual_ids(reader,self.layout,new+selected,self.seed),self.ids)
            for bad in (new,selected+new,new+selected+selected,old.replace(all_blobs,''),old.replace(all_blobs,'')+all_blobs,
                        new+selected.replace('all_applied_streams=verified','all_applied_streams=unknown')):
                with self.subTest(debug=bad),self.assertRaises(ValueError):c.actual_ids(reader,self.layout,bad,self.seed)

    def config(self,**updates):
        args=dict(ids=self.ids,loader=uuid.UUID('f94a0582-52e2-4f77-96ca-f3042fc8e90a'),layout=self.layout,locale='pl-pl',
                  native_sha='a'*64,compare_sha='b'*64,native_bytes=4321,compare_bytes=7654,timestamp=133000000000000000)
        args.update(updates);return c.configuration(**args)

    def test_b1_wire_format_exact_layout_hashes_receipts_roles_and_crc(self):
        data=self.config(); self.assertEqual(len(data),512);self.assertEqual(data[:16],b'USOSPREP BIOS B1')
        self.assertEqual(struct.unpack_from('<IIQII',data,16),(1,512,16*1024**3,self.ids['mbr_signature'],512))
        self.assertEqual(struct.unpack_from('<6Q',data,40),(c.MiB,100*c.MiB,101*c.MiB,16*1024**3-101*c.MiB,self.ids['ntfs_serial'],self.ids['system_serial']))
        self.assertEqual(data[104:136],bytes.fromhex('a'*64));self.assertEqual(data[136:168],bytes.fromhex('b'*64))
        self.assertEqual(struct.unpack_from('<4I',data,168),(4321,7654,1,1));self.assertEqual(data[184:188],b'\x80\x81\0\0')
        self.assertFalse(any(data[304:508]));self.assertEqual(struct.unpack_from('<I',data,508)[0],zlib.crc32(data[:508])&0xffffffff)
        for offset,key in ((240,'disk_guid'),(256,'windows_guid'),(272,'esp_guid'),(288,'msr_guid')):self.assertEqual(data[offset:offset+16].hex(),self.ids[key])

    def test_b1_refuses_wrong_extent_receipt_size_guids_or_missing_semantics(self):
        for change in (dict(native_bytes=0),dict(compare_bytes=c.MiB+1),dict(native_sha='f'*64),dict(compare_sha='a'*64),
                       dict(timestamp=0),dict(locale='../unsafe'),dict(loader=uuid.UUID(bytes_le=bytes.fromhex(self.ids['disk_guid'])))):
            with self.subTest(change=change),self.assertRaises(ValueError):self.config(**change)
        bad=copy.deepcopy(self.layout);bad['partitions'][0]['bytes']+=c.MiB
        with self.assertRaises(ValueError):self.config(layout=bad)

    def test_utility_does_not_write_when_receipt_content_does_not_match_configuration(self):
        program=self.root/'program.bin';program.write_bytes(b'own code')
        utility=self.root/'must-not-exist.raw'
        with self.assertRaises(ValueError):c.write_utility(program,utility,self.config(),b'not-native',b'not-compare')
        self.assertFalse(utility.exists())
        with patch.object(Path,'stat',return_value=SimpleNamespace(st_size=c.UTILITY_BYTES)):
            with self.assertRaises(ValueError):c.write_utility(program,utility,self.config(),b'n'*4321,b'c'*7654)
        self.assertFalse(utility.exists())

    def test_output_is_fresh_in_reserved_bios_scope(self):
        with patch.object(c.oracle,'RUNTIME',self.root):
            good=self.root/'1c23/qemu-bios/boot-test';self.assertEqual(c.output_guard(good),good)
            for bad in (self.root/'other/boot-test',self.root/'1c23/qemu-bios',self.root/'1c23/qemu-ia32/boot-test',good.parent/'prep-test'):
                with self.assertRaises(ValueError):c.output_guard(bad)
            good.mkdir(parents=True)
            with self.assertRaises(ValueError):c.output_guard(good)

    def test_missing_or_forged_real_receipt_stops_before_images_capacity_or_guest(self):
        args=SimpleNamespace()
        for name in ('prep','native','reference','compare'):
            setattr(args,name+'_receipt',self.root/(name+'.json'));setattr(args,name+'_sha256','0'*64)
        @contextlib.contextmanager
        def own_file_lock(path):
            with path.open('rb') as stream:yield stream
        for forged in (False,True):
            if forged:args.prep_receipt.write_text(json.dumps(self.prep),encoding='utf-8')
            with patch.object(c.oracle,'RUNTIME',self.root),patch.object(c.oracle,'readonly',side_effect=own_file_lock), \
                 patch.object(c,'write_utility') as writer,patch.object(c.pool,'enforce_incremental') as capacity,patch.object(c.subprocess,'Popen') as guest,contextlib.ExitStack() as locks:
                with self.assertRaises((ValueError,FileNotFoundError)):c.accepted(args,locks)
                writer.assert_not_called();capacity.assert_not_called();guest.assert_not_called()

    def test_full_entrypoint_missing_receipt_precedes_output_and_guest_process(self):
        program=self.root/'own-program.bin'
        with program.open('wb') as stream:stream.truncate(c.UTILITY_BYTES)
        qemu=self.root/'tools';qemu.mkdir()
        for name in ('qemu-system-i386.exe','qemu-img.exe'):(qemu/name).write_bytes(b'own non-executable test fixture')
        args=SimpleNamespace(out=self.root/'1c23/qemu-bios/boot-never-created',program=program,qemu_dir=qemu,
                             arch='bios',cpu='486',memory=32,timeout=300,prep_receipt=self.root/'absent.json',prep_sha256='a'*64)
        with patch.object(c.oracle,'RUNTIME',self.root),patch.object(c.logged_run,'tree',return_value=(self.head,0)), \
             patch.object(c,'write_utility') as writer,patch.object(c.pool,'enforce_incremental') as capacity,patch.object(c.subprocess,'Popen') as guest:
            with self.assertRaises((ValueError,FileNotFoundError)):c.run(args)
            writer.assert_not_called();capacity.assert_not_called();guest.assert_not_called()
        self.assertFalse(args.out.exists())

    def test_completion_memory_and_window_write_guard_are_required(self):
        self.assertTrue(c.guest_acceptance(33,False,self.log));self.assertEqual(c.memory_evidence(self.log)['allocator_peak_including_stack'],8040000)
        for code in (0,35,None,True):self.assertFalse(c.guest_acceptance(code,False,self.log))
        for log in (self.log.replace('BOOT_BIOS PASS','BOOT_UEFI PASS'),self.log.replace('target_writes=55','target_writes=0'),
                    self.log.replace('alloc_current=0','alloc_current=1'),self.log.replace('denied_windows_writes=0','denied_windows_writes=1'),
                    self.log.replace('guard_intact=true','guard_intact=false'),self.log+'TERMINAL FAIL',self.log+self.log):
            self.assertFalse(c.guest_acceptance(33,False,log))
        self.assertFalse(c.guest_acceptance(33,True,self.log))
        for log in (self.log.replace('high_water=40000','high_water=253952'),self.log.replace('physical_current=0','physical_current=1'),self.log.replace('extent_peak=9000000','extent_peak=13000000')):
            with self.assertRaises(ValueError):c.memory_evidence(log)

    def test_no_isofile_network_or_third_drive_in_two_drive_guest(self):
        args=list(map(str,c.guest_command(Path('qemu'),Path('owned output'),'486',32)))
        devices=[args[i+1] for i,part in enumerate(args) if part=='-device']
        self.assertIn('ide-hd,drive=boot,bus=ide.0,unit=0,bootindex=1',devices)
        self.assertIn('ide-hd,drive=target,bus=ide.0,unit=1,bootindex=2',devices)
        self.assertEqual(len([part for part in args if part=='-drive']),2)
        self.assertEqual(args[args.index('-cpu')+1],'486');self.assertEqual(args[args.index('-m')+1],'32');self.assertEqual(args[args.index('-nic')+1],'none')
        self.assertFalse(any('source' in arg or '.iso' in arg or 'pflash' in arg for arg in args))


if __name__=='__main__':unittest.main()
