# SPDX-License-Identifier: GPL-3.0-or-later
"""Isolated installer slot geometry and CRCs; no compiler, image or firmware."""
import hashlib
import importlib.util
from pathlib import Path
import struct
import sys
import unittest
import zlib

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'tools/minios'))
import build_bios_install as c


def legacy_packer():
    spec=importlib.util.spec_from_file_location('test_unchanged_legacy_packer',REPO/'tools/pack_legacy_core_slot.py')
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result


def linked_elf(payload_size,bss_start=None,bss_size=0):
    data=bytearray(52+payload_size+3*40)
    data[:6]=b'\x7fELF\x01\x01';struct.pack_into('<HH',data,16,2,3)
    struct.pack_into('<I',data,24,c.INSTALL_LOAD_ADDRESS)
    table=52+payload_size;struct.pack_into('<I',data,32,table)
    struct.pack_into('<HH',data,46,40,3)
    struct.pack_into('<10I',data,table+40,0,1,6,c.INSTALL_LOAD_ADDRESS,52,payload_size,0,0,4,0)
    struct.pack_into('<10I',data,table+80,0,8,3,bss_start or c.INSTALL_LOAD_ADDRESS+payload_size,0,bss_size,0,0,4,0)
    return data


class IsolatedBiosBuildTests(unittest.TestCase):
    def test_private_bootstrap_changes_exactly_two_geometry_constants(self):
        path=REPO/'src/platform/bios/bootstrap.S';before=path.read_bytes();source=before.decode().replace('\r\n','\n')
        result=c.patched_bootstrap(source)
        self.assertEqual(result,source.replace('.equ SLOT_BYTES, 262144\n','.equ SLOT_BYTES, 278528\n')
                         .replace('.equ SLOT_SECTORS, 512\n','.equ SLOT_SECTORS, 544\n'))
        for constant in ('.equ BOOTSTRAP_SECTORS, 32\n','.equ CORE_LOAD_ADDRESS, 0x00020000\n',
                         '    add eax, 511\n','    shr eax, 9\n'):
            self.assertIn(constant,result)
        self.assertEqual(path.read_bytes(),before)

    def test_missing_changed_or_duplicate_bootstrap_anchors_refuse(self):
        source=(REPO/'src/platform/bios/bootstrap.S').read_text()
        for altered in (source.replace('SLOT_BYTES, 262144','SLOT_BYTES, 270000'),
                        source.replace('SLOT_SECTORS, 512','SLOT_SECTORS, 513'),
                        source+'.equ SLOT_BYTES, 262144\n',source+'.equ SLOT_SECTORS, 512\n'):
            with self.subTest(anchor=altered[-60:]),self.assertRaises(ValueError):c.patched_bootstrap(altered)

    def test_full_256k_payload_has_correct_header_content_crc_and_slot_size(self):
        bootstrap=bytes(64)+b'own bootstrap';payload=b'\x5a'*c.INSTALL_PAYLOAD_BYTES
        slot,meta=c.build_install_slot(REPO,bootstrap,payload)
        self.assertEqual(len(slot),272*1024);self.assertEqual(slot[:8],b'USOSCORE')
        self.assertEqual(struct.unpack_from('<HH',slot,8),(1,64))
        self.assertEqual(struct.unpack_from('<7I',slot,12),(278528,16384,278528,16384,262144,0x20000,0))
        self.assertEqual(slot[16384:],payload);self.assertFalse(any(slot[48:64]))
        self.assertEqual(struct.unpack_from('<I',slot,40)[0],zlib.crc32(slot[64:meta['image_size']])&0xffffffff)
        self.assertEqual(struct.unpack_from('<I',slot,44)[0],zlib.crc32(slot[:44])&0xffffffff)
        changed=bytearray(slot);changed[16384]^=1
        self.assertNotEqual(zlib.crc32(changed[64:meta['image_size']])&0xffffffff,meta['content_crc32'])

    def test_previous_oversized_payload_now_fits_and_padding_remains_zero(self):
        slot,meta=c.build_install_slot(REPO,bytes(64),b'\xa6'*255140)
        self.assertEqual(meta['payload_size'],255140)
        self.assertEqual(meta['image_size'],16384+255140)
        self.assertFalse(any(slot[meta['image_size']:]))
        for size in (0,262145):
            with self.subTest(size=size),self.assertRaises(ValueError):c.build_install_slot(REPO,bytes(64),bytes(size))
        for bootstrap in (bytes(63),bytes(16385),b'x'+bytes(63)):
            with self.subTest(bootstrap=len(bootstrap)),self.assertRaises(ValueError):c.build_install_slot(REPO,bootstrap,b'a')

    def test_sector_rounded_load_and_disk_slot_do_not_cross_stack_or_config(self):
        geometry=c.payload_geometry(255140)
        self.assertEqual(geometry['payload_sectors'],499)
        self.assertEqual(geometry['rounded_load_end'],0x20000+499*512)
        self.assertEqual(geometry['slot_end_lba_exclusive'],608)
        self.assertLess(geometry['slot_end_lba_exclusive'],geometry['config_lba'])
        self.assertEqual(geometry['log_start_lba'],1025)
        self.assertEqual(c.payload_geometry(262144)['rounded_load_end'],0x60000)
        for size in (True,-1,0,262145):
            with self.subTest(size=size),self.assertRaises(ValueError):c.payload_geometry(size)

    def test_actual_linked_memory_bounds_include_bss_and_rounded_padding(self):
        result=c.linked_memory_bounds(linked_elf(255140,0x20000+255144,4096),255140)
        self.assertEqual(result['bss_end'],0x20000+255144+4096)
        self.assertLessEqual(result['bss_end'],0x60000)
        self.assertEqual(c.linked_memory_bounds(linked_elf(262144),262144)['bss_end'],0x60000)
        for blob,size in ((linked_elf(255140,0x5ff00,512),255140),
                          (linked_elf(8192,0x22000,65536),8192),
                          (linked_elf(8192,0x21000,4),8192),(linked_elf(4096),4095)):
            with self.subTest(size=size),self.assertRaises(ValueError):c.linked_memory_bounds(blob,size)

    def test_malformed_or_wrong_entry_elf_refuses(self):
        original=linked_elf(8192)
        cases=[b'',b'\x7fELF\x02\x01'+bytes(100)]
        for offset,value,fmt in ((24,0x20004,'I'),(32,len(original),'I'),(46,41,'H'),(48,0xffff,'H')):
            changed=bytearray(original);struct.pack_into('<'+fmt,changed,offset,value);cases.append(changed)
        for blob in cases:
            with self.subTest(length=len(blob)),self.assertRaises(ValueError):c.linked_memory_bounds(blob,8192)

    def test_legacy_module_limits_and_all_tracked_legacy_bytes_remain_unchanged(self):
        paths=[REPO/'src/platform/bios'/name for name in ('stage1.S','bootstrap.S','core.S','windows_disk_order.S')]
        paths.append(REPO/'tools/pack_legacy_core_slot.py')
        pins={path:hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
        legacy=legacy_packer();self.assertEqual(legacy.SLOT_BYTES,262144)
        c.build_install_slot(REPO,bytes(64),b'x'*255140)
        self.assertEqual(legacy.SLOT_BYTES,262144)
        self.assertEqual(legacy_packer().SLOT_BYTES,262144)
        with self.assertRaises(ValueError):legacy.build_slot(bytes(64),b'x'*(240*1024+1))
        slot,_=legacy.build_slot(bytes(64),b'x'*(240*1024))
        self.assertEqual(len(slot),262144)
        self.assertEqual(pins,{path:hashlib.sha256(path.read_bytes()).hexdigest() for path in paths})


if __name__=='__main__':unittest.main()
