#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Bounded byte fixtures for the independent dynamic-VHD oracle adapter."""
import io
from pathlib import Path
import struct
import sys
import unittest
import uuid
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'minios'))
import install_native as native


def checksum(data, at):
    data[at:at + 4] = bytes(4)
    struct.pack_into('>I', data, at, ~sum(data) & 0xffffffff)


def fixture(allocated=True):
    footer = bytearray(512)
    footer[:8] = b'conectix'
    struct.pack_into('>IIQ', footer, 8, 2, 0x10000, 512)
    struct.pack_into('>QQ', footer, 40, 32 * 1024**2, 32 * 1024**2)
    struct.pack_into('>I', footer, 60, 3)
    footer[68:84] = bytes(range(16))
    checksum(footer, 64)
    header = bytearray(1024)
    header[:8] = b'cxsparse'
    struct.pack_into('>QQIII', header, 8, 0xffffffffffffffff, 1536, 0x10000, 16, native.BLOCK)
    checksum(header, 36)
    table = bytearray(b'\xff' * 512)
    payload = b''
    if allocated:
        struct.pack_into('>I', table, 0, 4)
        bitmap = bytearray(512)
        bitmap[0] = 0x80  # Only the first512-byte logical sector is present.
        block = bytearray(b'X' * native.BLOCK)
        block[:512] = bytes(offset % 251 for offset in range(512))
        payload = bitmap + block
    return bytes(footer + header + table + payload + footer)


def parsed(data):
    value = native.DynamicVhd.__new__(native.DynamicVhd)
    value.path = Path('unused.vhd')
    value.file, value.file_bytes = io.BytesIO(data), len(data)
    value.own_file = True
    value.position, value.bitmap_index, value.bitmap = 0, None, None
    value._parse()
    return value


class DynamicVhdTests(unittest.TestCase):
    def test_allocated_sector_bitmap_and_unallocated_block(self):
        value = parsed(fixture())
        self.assertEqual(value.read(512), bytes(offset % 251 for offset in range(512)))
        self.assertEqual(value.read(512), bytes(512))
        value.seek(native.BLOCK - 17)
        self.assertEqual(value.read(42), bytes(42))
        value.seek(32 * 1024**2 - 7)
        self.assertEqual(value.read(100), bytes(7))
        self.assertEqual(value.read(1), b'')

    def test_empty_dynamic_container_reads_zero(self):
        value = parsed(fixture(False))
        self.assertEqual(value.read(8197), bytes(8197))
        self.assertEqual(value.seek(-5, 2), value.size - 5)
        self.assertEqual(value.read(5), bytes(5))

    def test_checksums_and_footer_backup_refuse_corruption(self):
        original = fixture()
        for offset in (3, 512 + 36, 512 + 11, len(original) - 512 + 64):
            data = bytearray(original)
            data[offset] ^= 1
            with self.assertRaises(ValueError):
                parsed(data)

    def test_bat_overlap_metadata_and_outside_are_refused(self):
        for sector in (0, 1, 3, 0x100000, 0xfffffffe):
            data = bytearray(fixture())
            struct.pack_into('>I', data, 1536, sector)
            with self.assertRaises(ValueError):
                parsed(data)
        data = bytearray(fixture())
        struct.pack_into('>I', data, 1540, 4)
        with self.assertRaises(ValueError):
            parsed(data)

    def test_header_parent_and_geometry_refused_with_valid_checksums(self):
        for offset, data_value in ((32, 512), (28, 17), (24, 0x20000)):
            data = bytearray(fixture())
            struct.pack_into('>I', data, 512 + offset, data_value)
            header = data[512:1536]
            checksum(header, 36)
            data[512:1536] = header
            with self.assertRaises(ValueError):
                parsed(data)
        data = bytearray(fixture())
        data[512 + 40] = 1
        header = data[512:1536]
        checksum(header, 36)
        data[512:1536] = header
        with self.assertRaises(ValueError):
            parsed(data)

    def test_read_and_seek_are_bounded(self):
        value = parsed(fixture(False))
        for count in (-1, 32 * 1024**2 + 1, True):
            with self.assertRaises(ValueError):
                value.read(count)
        for offset, mode in ((-1, 0), (value.size + 1, 0), (0, 9)):
            with self.assertRaises(ValueError):
                value.seek(offset, mode)
        for count in (0, 1, 512, 4097):
            value.seek(0)
            self.assertEqual(value.read(count), bytes(count))


class SparseLogicalDisk:
    size = 512 * 1024**2
    def __init__(self):
        self.position, self.segments = 0, {}
    def seek(self, offset):
        self.position = offset
    def read(self, count):
        output = bytearray(count)
        for start, data in self.segments.items():
            begin, end = max(start, self.position), min(start + len(data), self.position + count)
            if begin < end:
                output[begin - self.position:end - self.position] = data[begin - start:end - start]
        self.position += count
        return bytes(output)


def partition_fixture(mode):
    disk = SparseLogicalDisk()
    mib = 1024**2
    mbr = bytearray(512)
    mbr[510:] = b'\x55\xaa'
    if mode == 'bios':
        struct.pack_into('<I', mbr, 440, 0x17916847)
        for index, (start, size) in enumerate([(mib, 100 * mib), (101 * mib, disk.size - 101 * mib)]):
            mbr[446 + 16 * index] = 0x80 if index == 0 else 0
            mbr[450 + 16 * index] = 7
            struct.pack_into('<II', mbr, 454 + 16 * index, start // 512, size // 512)
        disk.segments[0] = mbr
        return disk
    mbr[450] = 0xee
    struct.pack_into('<II', mbr, 454, 1, disk.size // 512 - 1)
    disk.segments[0] = mbr
    table = bytearray(16384)
    kinds = ['c12a7328-f81f-11d2-ba4b-00a0c93ec93b', 'e3c9e316-0b5c-4db8-817d-f92df00215ae', 'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7']
    ranges = [(mib, 300 * mib), (301 * mib, 16 * mib), (317 * mib, 194 * mib)]
    for index, ((start, size), kind) in enumerate(zip(ranges, kinds)):
        at = index * 128
        table[at:at + 16] = uuid.UUID(kind).bytes_le
        table[at + 16:at + 32] = bytes([index + 10]) * 16
        struct.pack_into('<QQQ', table, at + 32, start // 512, (start + size) // 512 - 1, 0)
    disk.segments[1024] = table
    disk.segments[disk.size - 33 * 512] = table.copy()
    for own, peer, entry_at in [(1, disk.size // 512 - 1, 2), (disk.size // 512 - 1, 1, disk.size // 512 - 33)]:
        header = bytearray(512)
        header[:8] = b'EFI PART'
        struct.pack_into('<II', header, 8, 0x10000, 92)
        struct.pack_into('<QQQQ', header, 24, own, peer, 34, disk.size // 512 - 34)
        header[56:72] = b'\x01' * 16
        struct.pack_into('<QIII', header, 72, entry_at, 128, 128, zlib.crc32(table))
        struct.pack_into('<I', header, 16, zlib.crc32(header[:92]))
        disk.segments[own * 512] = header
    return disk


class InstallPartitionTests(unittest.TestCase):
    def test_exact_gpt_and_mbr_layouts(self):
        for mode, count, windows in [('uefi', 3, 3), ('bios', 2, 2)]:
            result = native.disk_layout(partition_fixture(mode), mode)
            self.assertEqual((len(result['partitions']), result['windows_number']), (count, windows))
            self.assertEqual(result['partitions'][0]['start'], 1024**2)
            self.assertEqual(result['image_bytes'], 512 * 1024**2)

    def test_gpt_crc_backup_and_extra_partition_refused(self):
        for at in (512, 1024, 512 * 1024**2 - 512):
            disk = partition_fixture('uefi')
            disk.segments[at][5] ^= 1
            with self.assertRaises(ValueError):
                native.disk_layout(disk, 'uefi')
        disk = partition_fixture('bios')
        disk.segments[0][478] = 0x80
        with self.assertRaises(ValueError):
            native.disk_layout(disk, 'bios')

    def test_mbr_offset_size_active_and_source_style_refused(self):
        for offset in (446, 450, 454, 458, 470, 474):
            disk = partition_fixture('bios')
            disk.segments[0][offset] ^= 1
            with self.assertRaises(ValueError):
                native.disk_layout(disk, 'bios')
        for source, target in [('uefi', 'bios'), ('bios', 'uefi')]:
            with self.assertRaises(ValueError):
                native.disk_layout(partition_fixture(source), target)


if __name__ == '__main__':
    unittest.main()
