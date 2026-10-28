"""Firmware boot entry for the prepared disk (tools/uefi_boot_entry.sh):
the EFI_LOAD_OPTION / HD() + File() device path encoding against a Python
reference (UEFI 2.10 3.1.3, 10.3.5.1, 10.3.5.4), the ESP lookup on GPT and
MBR disks, and the BootOrder / BootNext updates in an efivarfs-like folder.
Host only: Git sh on temp files standing in for the disk and efivarfs; no VM,
no disk, no firmware variable is touched.
"""
from pathlib import Path
import shutil
import struct
import tempfile
import unittest
import uuid

from test_w9x_phase1_qemu import sh

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / 'tools/uefi_boot_entry.sh'
GLOBAL = '8be4df61-93ca-11d2-aa0d-00e098032b8c'
ESP_TYPE = uuid.UUID('C12A7328-F81F-11D2-BA4B-00A0C93EC93B')
LOADER = '\\EFI\\BOOT\\BOOTX64.EFI'


def ucs2(text):
    return (text + '\0').encode('utf-16-le')


def load_option(name, number, start, size, signature, mbr_type, sig_type, loader=LOADER):
    hd = struct.pack('<BBHIQQ16sBB', 4, 1, 42, number, start, size, signature, mbr_type, sig_type)
    path = ucs2(loader)
    file_node = struct.pack('<BBH', 4, 4, 4 + len(path)) + path
    dp = hd + file_node + b'\x7f\xff\x04\x00'
    return struct.pack('<IH', 1, len(dp)) + ucs2(name) + dp


def mbr_disk(signature=b'\x78\x56\x34\x12', esp_slot=1, start=2879488, size=5760):
    mbr = bytearray(512)
    mbr[440:444] = signature
    struct.pack_into('<B3sB3sII', mbr, 446, 0x80, b'\0' * 3, 0xEB, b'\0' * 3, 12288, 2867200)
    struct.pack_into('<B3sB3sII', mbr, 446 + 16 * esp_slot, 0, b'\0' * 3, 0xEF, b'\0' * 3, start, size)
    mbr[510:512] = b'\x55\xaa'
    return bytes(mbr) + b'\0' * (512 * 40)


def gpt_disk(part_guid, index=2, first=2048, last=133119):
    disk = bytearray(512 * 64)
    disk[510:512] = b'\x55\xaa'
    disk[446 + 4] = 0xEE
    header = bytearray(92)
    header[0:8] = b'EFI PART'
    struct.pack_into('<QII', header, 72, 2, 128, 128)
    disk[512:512 + 92] = header
    other = uuid.UUID('0FC63DAF-8483-4772-8E79-3D69D8477DE4')
    for i in range(index + 1):
        off = 1024 + 128 * i
        kind = ESP_TYPE if i == index else other
        guid = part_guid if i == index else uuid.uuid4()
        struct.pack_into('<16s16sQQ', disk, off, kind.bytes_le, guid.bytes_le, first + i, last + i)
    return bytes(disk)


class Encoding(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='usos-bootentry-'))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.disk = self.tmp / 'disk.raw'
        self.vars = self.tmp / 'efivars'
        self.vars.mkdir()

    def run_helper(self, command, name='Haiku', ok=True, order=None):
        env = {'TARGET_DEVICE': self.disk.as_posix(), 'ENTRY_NAME': name, 'SECTOR_SIZE': '512',
               'EFIVARS_DIR': self.vars.as_posix()}
        if order:
            env['ENTRY_ORDER'] = order
        rc, out, err = sh(f'sh "{HELPER.as_posix()}" {command}', env=env)
        if ok:
            self.assertEqual(rc, 0, out + err)
        return rc, out, err

    def var(self, name):
        return (self.vars / f'{name}-{GLOBAL}').read_bytes()

    def put_var(self, name, data):
        (self.vars / f'{name}-{GLOBAL}').write_bytes(b'\x07\0\0\0' + data)

    def test_mbr_option_matches_reference(self):
        self.disk.write_bytes(mbr_disk())
        _, out, _ = self.run_helper('option')
        expected = load_option('Haiku', 2, 2879488, 5760, b'\x78\x56\x34\x12' + b'\0' * 12, 1, 1)
        self.assertEqual(bytes.fromhex(out.strip()), expected)

    def test_gpt_option_uses_partuuid(self):
        part = uuid.UUID('5f0e8b5c-1d2e-4a3b-9c8d-7e6f5a4b3c2d')
        self.disk.write_bytes(gpt_disk(part, index=2))
        _, out, _ = self.run_helper('option', name='FreeBSD')
        expected = load_option('FreeBSD', 3, 2050, 133119 - 2048 + 1, part.bytes_le, 2, 2)
        self.assertEqual(bytes.fromhex(out.strip()), expected)

    def test_no_esp_fails(self):
        self.disk.write_bytes(b'\0' * 512 * 40)
        rc, _, err = self.run_helper('option', ok=False)
        self.assertNotEqual(rc, 0)
        self.assertIn('no EFI system partition', err)

    def test_non_ascii_name_is_replaced(self):
        self.disk.write_bytes(mbr_disk())
        _, out, _ = self.run_helper('option', name='Zażółć')
        # UTF-8 bytes of the non-ASCII letters become '_' (UCS-2 is ASCII only here).
        self.assertIn(ucs2('Za________'), bytes.fromhex(out.strip()))

    def test_add_writes_entry_bootorder_bootnext(self):
        self.disk.write_bytes(mbr_disk())
        self.put_var('Boot0000', b'other')
        self.put_var('Boot0001', b'other')
        self.put_var('BootOrder', b'\x01\x00\x00\x00')
        _, out, _ = self.run_helper('add')
        self.assertIn('boot_entry=Boot0002', out)
        option = load_option('Haiku', 2, 2879488, 5760, b'\x78\x56\x34\x12' + b'\0' * 12, 1, 1)
        self.assertEqual(self.var('Boot0002'), b'\x07\0\0\0' + option)
        # First: the written system stays the default after BootNext is
        # used up; the other entries (USOS stick, other systems) keep their order.
        self.assertEqual(self.var('BootOrder'), b'\x07\0\0\0' + b'\x02\x00\x01\x00\x00\x00')
        self.assertEqual(self.var('BootNext'), b'\x07\0\0\0\x02\x00')

    def test_add_moves_an_existing_entry_to_the_front(self):
        self.disk.write_bytes(mbr_disk())
        self.put_var('Boot0000', b'other')
        self.put_var('BootOrder', b'\x00\x00')
        self.run_helper('add')
        self.put_var('BootOrder', b'\x00\x00\x01\x00\x05\x00')
        _, out, _ = self.run_helper('add')
        self.assertIn('already present', out)
        self.assertEqual(self.var('BootOrder'), b'\x07\0\0\0' + b'\x01\x00\x00\x00\x05\x00')

    def test_entry_order_last_appends(self):
        self.disk.write_bytes(mbr_disk())
        self.put_var('Boot0000', b'other')
        self.put_var('BootOrder', b'\x00\x00')
        self.run_helper('add', order='last')
        self.assertEqual(self.var('BootOrder'), b'\x07\0\0\0' + b'\x00\x00\x01\x00')
        rc, _, err = self.run_helper('add', ok=False, order='middle')
        self.assertNotEqual(rc, 0)
        self.assertIn('ENTRY_ORDER', err)

    def test_add_again_reuses_the_entry(self):
        self.disk.write_bytes(mbr_disk())
        self.run_helper('add')
        before = sorted(p.name for p in self.vars.iterdir())
        _, out, _ = self.run_helper('add')
        self.assertIn('already present', out)
        self.assertEqual(sorted(p.name for p in self.vars.iterdir()), before)
        self.assertEqual(self.var('BootOrder'), b'\x07\0\0\0\x01\x00')
        self.assertEqual(self.var('BootNext'), b'\x07\0\0\0\x01\x00')

    def run_with_stale(self, ids_text):
        ids = self.tmp / 'stale.txt'
        ids.write_text(ids_text)
        env = {'TARGET_DEVICE': self.disk.as_posix(), 'ENTRY_NAME': 'FreeBSD', 'SECTOR_SIZE': '512',
               'EFIVARS_DIR': self.vars.as_posix(), 'STALE_IDS_FILE': ids.as_posix()}
        rc, out, err = sh(f'sh "{HELPER.as_posix()}" add', env=env)
        self.assertEqual(rc, 0, out + err)
        return out

    def hd_ids(self, option):
        rc, out, err = sh(f'sh "{HELPER.as_posix()}" hdids', env={'TARGET_DEVICE': '/dev/null', 'OPTION_HEX': option.hex()})
        self.assertEqual(rc, 0, err)
        return out.split()

    def test_ids_lists_gpt_partuuids_and_mbr_partitions(self):
        part = uuid.UUID('5f0e8b5c-1d2e-4a3b-9c8d-7e6f5a4b3c2d')
        self.disk.write_bytes(gpt_disk(part, index=1))
        _, out, _ = self.run_helper('ids')
        lines = out.split()
        self.assertEqual(len([x for x in lines if x.startswith('g:')]), 2)
        self.assertIn('g:' + part.bytes_le.hex(), lines)
        self.assertFalse([x for x in lines if x.startswith('m:')])   # protective EE slot only
        self.disk.write_bytes(mbr_disk())
        _, out, _ = self.run_helper('ids')
        self.assertEqual(out.split(), ['m:78563412:12288:2867200', 'm:78563412:2879488:5760'])

    def test_hd_ids_of_a_load_option(self):
        part = uuid.UUID('5f0e8b5c-1d2e-4a3b-9c8d-7e6f5a4b3c2d')
        self.assertEqual(self.hd_ids(load_option('x', 1, 2048, 4096, part.bytes_le, 2, 2)), ['g:' + part.bytes_le.hex()])
        self.assertEqual(self.hd_ids(load_option('Haiku', 2, 2879488, 5760, bytes(16), 1, 1)), ['m:00000000:2879488:5760'])
        # A firmware-style full path: PciRoot(0x0)/Pci(0x1,0x0) in front of the HD() node.
        pci = bytes([2, 1, 12, 0]) + struct.pack('<II', 0x0A0341D0, 0) + bytes([1, 1, 6, 0, 0, 1])
        hd = struct.pack('<BBHIQQ16sBB', 4, 1, 42, 1, 2048, 4096, part.bytes_le, 2, 2)
        dp = pci + hd + b'\x7f\xff\x04\x00'
        option = struct.pack('<IH', 1, len(dp)) + ucs2('Windows Boot Manager') + dp
        self.assertEqual(self.hd_ids(option), ['g:' + part.bytes_le.hex()])
        usb = struct.pack('<IH', 1, 4) + ucs2('USB') + b'\x7f\xff\x04\x00'
        self.assertEqual(self.hd_ids(usb), [])

    def test_stale_entries_of_the_old_layout_are_removed(self):
        # The disk held Haiku (MBR, signature 0) and before that a GPT system;
        # FreeBSD (GPT) is written over it.
        old_gpt = uuid.uuid4()
        self.put_var('Boot0000', struct.pack('<IH', 1, 4) + ucs2('USB') + b'\x7f\xff\x04\x00')
        self.put_var('Boot0003', load_option('Haiku', 2, 2879488, 5760, bytes(16), 1, 1))
        self.put_var('Boot0004', load_option('Old', 1, 40, 1024, old_gpt.bytes_le, 2, 2))
        # Signature 0 with another layout and a disk with its own signature: kept.
        self.put_var('Boot0005', load_option('Other', 2, 99999, 5760, bytes(16), 1, 1))
        self.put_var('Boot0006', load_option('Windows', 1, 2048, 4096, b'\x11\x22\x33\x44' + bytes(12), 1, 1))
        self.put_var('BootCurrent', b'\x00\x00')
        self.put_var('BootOrder', b'\x03\x00\x00\x00\x04\x00\x05\x00\x06\x00')
        self.disk.write_bytes(gpt_disk(uuid.uuid4(), index=0))
        out = self.run_with_stale(f'm:00000000:12288:2867200\nm:00000000:2879488:5760\ng:{old_gpt.bytes_le.hex()}\n')
        self.assertIn('Boot0003 removed', out)
        self.assertIn('Boot0004 removed', out)
        names = {p.name.split('-')[0] for p in self.vars.iterdir()}
        self.assertFalse({'Boot0003', 'Boot0004'} & names)
        self.assertTrue({'Boot0000', 'Boot0001', 'Boot0005', 'Boot0006'} <= names)
        self.assertEqual(self.var('BootOrder'), b'\x07\0\0\0' + b'\x01\x00\x00\x00\x05\x00\x06\x00')

    def test_stale_nonzero_mbr_signature_matches_any_partition(self):
        self.put_var('Boot0002', load_option('ReactOS', 1, 2048, 4096, b'\x6c\x60\x0d\xc1' + bytes(12), 1, 1))
        self.put_var('BootCurrent', b'\x00\x00')
        self.put_var('BootOrder', b'\x02\x00')
        self.disk.write_bytes(mbr_disk())
        out = self.run_with_stale('m:6c600dc1:63:100000\n')
        self.assertIn('Boot0002 removed', out)
        self.assertEqual(self.var('BootOrder'), b'\x07\0\0\0\x01\x00')

    def test_boot_current_is_never_removed(self):
        part = uuid.uuid4()
        self.put_var('Boot0002', load_option('Stick', 1, 2048, 4096, part.bytes_le, 2, 2))
        self.put_var('BootCurrent', b'\x02\x00')
        self.disk.write_bytes(mbr_disk())
        self.run_with_stale(f'g:{part.bytes_le.hex()}\n')
        self.assertTrue((self.vars / f'Boot0002-{GLOBAL}').exists())

    def test_no_variables_is_exit_2(self):
        self.disk.write_bytes(mbr_disk())
        shutil.rmtree(self.vars)
        rc, _, _ = self.run_helper('add', ok=False)
        self.assertEqual(rc, 2)


class Wiring(unittest.TestCase):
    def test_image_disk_target_calls_the_helper(self):
        text = (ROOT / 'tools/image_disk_target.sh').read_text(encoding='utf-8')
        self.assertIn('uefi_boot_entry.sh', text)
        # The old layout is read before the disk is cleared and handed to `add`.
        self.assertLess(text.index('uefi_boot_entry.sh" ids'), text.index('dd if=/dev/zero of="$TARGET_DEVICE"'))
        self.assertIn('STALE_IDS_FILE="$stale_ids"', text)

    def test_micro_linux_ships_helper_and_efivarfs(self):
        text = (ROOT / 'tools/build_micro_linux.py').read_text(encoding='utf-8')
        self.assertIn('"tools/uefi_boot_entry.sh"', text)
        self.assertIn('kernel/fs/efivarfs/efivarfs.ko', text)


if __name__ == '__main__':
    unittest.main()
