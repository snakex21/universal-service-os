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

    def run_helper(self, command, name='Haiku', ok=True):
        rc, out, err = sh(f'sh "{HELPER.as_posix()}" {command}', env={
            'TARGET_DEVICE': self.disk.as_posix(), 'ENTRY_NAME': name, 'SECTOR_SIZE': '512',
            'EFIVARS_DIR': self.vars.as_posix()})
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
        # Appended: the firmware's default entry stays first.
        self.assertEqual(self.var('BootOrder'), b'\x07\0\0\0' + b'\x01\x00\x00\x00\x02\x00')
        self.assertEqual(self.var('BootNext'), b'\x07\0\0\0\x02\x00')

    def test_add_again_reuses_the_entry(self):
        self.disk.write_bytes(mbr_disk())
        self.run_helper('add')
        before = sorted(p.name for p in self.vars.iterdir())
        _, out, _ = self.run_helper('add')
        self.assertIn('already present', out)
        self.assertEqual(sorted(p.name for p in self.vars.iterdir()), before)
        self.assertEqual(self.var('BootOrder'), b'\x07\0\0\0\x01\x00')
        self.assertEqual(self.var('BootNext'), b'\x07\0\0\0\x01\x00')

    def test_no_variables_is_exit_2(self):
        self.disk.write_bytes(mbr_disk())
        shutil.rmtree(self.vars)
        rc, _, _ = self.run_helper('add', ok=False)
        self.assertEqual(rc, 2)


class Wiring(unittest.TestCase):
    def test_image_disk_target_calls_the_helper(self):
        text = (ROOT / 'tools/image_disk_target.sh').read_text(encoding='utf-8')
        self.assertIn('uefi_boot_entry.sh', text)

    def test_micro_linux_ships_helper_and_efivarfs(self):
        text = (ROOT / 'tools/build_micro_linux.py').read_text(encoding='utf-8')
        self.assertIn('"tools/uefi_boot_entry.sh"', text)
        self.assertIn('kernel/fs/efivarfs/efivarfs.ko', text)


if __name__ == '__main__':
    unittest.main()
