#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Independent read-only FAT32 structural/tree oracle (no MiniOS decoder).

Public format reference: Microsoft EFI FAT specification1.03,2000-12-06.
The test reads an explicitly supplied regular image. It never mounts, repairs,
discovers disks, writes the source or loads a whole image into RAM.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import stat
import struct
import unittest
import uuid


def expected_fixture():
    directories = ['EFI', 'EFI/BOOT', 'EFI/Microsoft', 'EFI/Microsoft/Boot',
                   'EFI/Microsoft/Boot/en-US', 'EFI/Microsoft/Boot/Fonts']
    names = ['EFI/BOOT/BOOTX64.EFI', 'EFI/Microsoft/Boot/bootmgfw.efi',
             'EFI/Microsoft/Boot/BCD', 'EFI/Microsoft/Boot/en-US/bootmgfw.efi.mui',
             'EFI/Microsoft/Boot/Fonts/wgl4_boot.ttf',
             'EFI/Microsoft/Boot/Zażółć gęślą jaźń.txt', 'EFI/Microsoft/Boot/Empty.txt']
    files = {}
    for index, name in enumerate(names):
        size = 0 if index == len(names) - 1 else 8197 + index * 123
        content = bytes((offset * 7 + 9 + index) % 256 for offset in range(size))
        files[name] = dict(size=size, sha256=hashlib.sha256(content).hexdigest())
    files.update((f'EFI/Microsoft/Boot/Long collision fixture {index}.txt',
                  dict(size=4, sha256=hashlib.sha256(b'done').hexdigest())) for index in range(100))
    files['PHASE1.TXT'] = dict(size=11, sha256=hashlib.sha256(b'first phase').hexdigest())
    return dict(directories=directories, files=files)


def short_checksum(name):
    value = 0
    for byte in name:
        value = (((value & 1) << 7) + (value >> 1) + byte) & 255
    return value


def guarded_image(path):
    path = Path(path)
    if not path.is_absolute() or str(path).startswith(('\\\\', '//')):
        raise ValueError('Explicit local regular-file image required')
    for ancestor in [path, *path.parents]:
        value = ancestor.lstat()
        if stat.S_ISLNK(value.st_mode) or getattr(value, 'st_file_attributes', 0) & 0x400:
            raise ValueError('Reparse/symbolic image path refused')
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise ValueError('Regular image with exactly one link required')
    return path


class FatOracle:
    def __init__(self, stream, image_size, start, size, sector):
        self.stream, self.image_size, self.start, self.size, self.sector = stream, image_size, start, size, sector
        if sector not in (512, 4096) or start % sector or size % sector or start < 0 or size < 1 or start + size > image_size:
            raise ValueError('Partition geometry outside regular image')
        self.boot = self.read(0, sector)
        boot = self.boot
        if boot[510:512] != b'\x55\xaa' or boot[82:90] != b'FAT32   ':
            raise ValueError('FAT32 boot signature required')
        u16 = lambda off: struct.unpack_from('<H', boot, off)[0]
        u32 = lambda off: struct.unpack_from('<I', boot, off)[0]
        self.spc, self.reserved, self.copies = boot[13], u16(14), boot[16]
        self.total, self.fat_sectors, self.root = u32(32), u32(36), u32(44)
        if (u16(11) != sector or self.spc == 0 or self.spc & (self.spc - 1)
                or self.spc * sector > 32768 or self.reserved < 8 or self.copies != 2
                or u16(17) or u16(19) or u16(22) or u16(40) or u16(42)
                or self.total * sector != size or u32(28) * sector != start):
            raise ValueError('FAT32 BPB/hidden sector geometry differs')
        self.data = self.reserved + self.copies * self.fat_sectors
        self.clusters = (self.total - self.data) // self.spc
        self.cluster_size = self.spc * sector
        if not 65525 <= self.clusters <= 0x0fffffef or self.root != 2 or self.fat_sectors * sector < (self.clusters + 2) * 4:
            raise ValueError('FAT32 cluster count/capacity invalid')
        if u16(48) != 1 or u16(50) != 6 or self.read(6 * sector, sector) != boot:
            raise ValueError('Backup BPB differs')
        third = self.read(2 * sector, sector)
        if third[510:512] != b'\x55\xaa' or third != self.read(8 * sector, sector):
            raise ValueError('Third reserved boot sector signature/backup differs')
        self.info = self.read(sector, sector)
        if self.info != self.read(7 * sector, sector):
            raise ValueError('Backup FSInfo differs')
        if (struct.unpack_from('<I', self.info, 0)[0] != 0x41615252
                or struct.unpack_from('<I', self.info, 484)[0] != 0x61417272
                or self.info[508:512] != b'\0\0\x55\xaa'):
            raise ValueError('FSInfo signatures invalid')
        self.table = self.read(self.reserved * sector, self.fat_sectors * sector)
        if self.table != self.read((self.reserved + self.fat_sectors) * sector, len(self.table)):
            raise ValueError('Mirrored FATs differ')
        if self.fat(0) != 0x0ffffff8 or self.fat(1) != 0x0fffffff:
            raise ValueError('Reserved/clean FAT entries invalid')
        free = sum(self.fat(cluster) == 0 for cluster in range(2, self.clusters + 2))
        self.free = struct.unpack_from('<I', self.info, 488)[0]
        next_free = struct.unpack_from('<I', self.info, 492)[0]
        if self.free != free or (free and (not 2 <= next_free <= self.clusters + 1 or self.fat(next_free) != 0)):
            raise ValueError('FSInfo allocation counters invalid')
        self.used = set()

    def read(self, offset, size):
        if offset < 0 or size < 0 or offset > self.size or size > self.size - offset:
            raise ValueError('Read outside partition')
        self.stream.seek(self.start + offset)
        data = self.stream.read(size)
        if len(data) != size:
            raise ValueError('Truncated regular image')
        return data

    def fat(self, cluster):
        if not 0 <= cluster <= self.clusters + 1:
            raise ValueError('FAT index outside volume')
        return struct.unpack_from('<I', self.table, cluster * 4)[0] & 0x0fffffff

    def chain(self, cluster):
        visited = set()
        while True:
            if not 2 <= cluster <= self.clusters + 1 or cluster in visited or cluster in self.used:
                raise ValueError('Bad/cross-linked/looping allocation chain')
            visited.add(cluster)
            self.used.add(cluster)
            yield self.read((self.data + (cluster - 2) * self.spc) * self.sector, self.cluster_size)
            cluster = self.fat(cluster)
            if cluster >= 0x0ffffff8:
                return
            if len(visited) > self.clusters:
                raise ValueError('Unbounded chain')

    def directory(self, cluster, parent):
        long_name, remaining, checksum, output, ended, names, aliases = None, 0, 0, [], False, set(), set()
        for block in self.chain(cluster):
            for offset in range(0, len(block), 32):
                cell = block[offset:offset + 32]
                if ended:
                    if any(cell):
                        raise ValueError('Nonzero cells after end marker')
                    continue
                if cell[0] == 0:
                    ended = True
                    continue
                if cell[0] == 0xe5:
                    raise ValueError('Unexpected deleted entry in fresh fixture')
                if cell[11] == 15:
                    ordinal = cell[0] & 31
                    if cell[0] & 64:
                        remaining, checksum = ordinal, cell[13]
                        long_name = [0xffff] * (13 * ordinal)
                    if not long_name or not 1 <= ordinal <= 20 or remaining != ordinal or cell[13] != checksum or cell[12] or cell[26:28] != b'\0\0':
                        raise ValueError('Invalid long-name order/checksum fields')
                    units = [struct.unpack_from('<H', cell, at)[0] for at in (1,3,5,7,9,14,16,18,20,22,24,28,30)]
                    long_name[(ordinal - 1) * 13:ordinal * 13] = units
                    remaining -= 1
                    continue
                alias = cell[:11]
                if alias in aliases:
                    raise ValueError('Duplicate8.3 alias')
                aliases.add(alias)
                short = alias[:8].rstrip(b' ').decode('ascii')
                if alias[8:].strip():
                    short += '.' + alias[8:].rstrip(b' ').decode('ascii')
                name = short
                if long_name is not None:
                    if remaining or short_checksum(alias) != checksum:
                        raise ValueError('Unterminated/mismatched LFN group')
                    if 0 in long_name:
                        terminator = long_name.index(0)
                        if any(unit != 0xffff for unit in long_name[terminator + 1:]):
                            raise ValueError('Invalid LFN padding')
                        long_name = long_name[:terminator]
                    if not 1 <= len(long_name) <= 255 or 0xffff in long_name:
                        raise ValueError('Invalid LFN length')
                    name = struct.pack('<' + 'H' * len(long_name), *long_name).decode('utf-16-le')
                long_name = None
                first = struct.unpack_from('<H', cell, 20)[0] << 16 | struct.unpack_from('<H', cell, 26)[0]
                length = struct.unpack_from('<I', cell, 28)[0]
                if cell[11] & 8:
                    if cluster != self.root or cell[11] != 8 or first or length or alias != self.boot[71:82]:
                        raise ValueError('Invalid root label entry')
                    continue
                if name in ('.', '..'):
                    if cell[11] != 16 or length or first != (cluster if name == '.' else parent):
                        raise ValueError('Dot directory linkage invalid')
                    continue
                if name.casefold() in names or any(char in name for char in '/\\\0'):
                    raise ValueError('Invalid/duplicate filename')
                names.add(name.casefold())
                output.append((name, cell[11], first, length))
        if long_name is not None or not ended:
            raise ValueError('Directory lacks terminator')
        return output

    def tree(self):
        files, directories, pending = {}, [], [(self.root, 0, '', 0)]
        while pending:
            cluster, parent, prefix, depth = pending.pop()
            if depth > 64 or len(files) + len(directories) > 20000:
                raise ValueError('Fixture tree bound exceeded')
            for name, attributes, first, length in self.directory(cluster, parent):
                path = prefix + name
                if attributes & 16:
                    if length:
                        raise ValueError('Directory has file size')
                    directories.append(path)
                    pending.append((first, 0 if cluster == self.root else cluster, path + '/', depth + 1))
                else:
                    digest = hashlib.sha256()
                    left = length
                    if not length:
                        if first:
                            raise ValueError('Empty file allocated unexpectedly')
                    else:
                        for block in self.chain(first):
                            if left == 0:
                                raise ValueError('Overallocated file chain')
                            take = min(left, len(block))
                            digest.update(block[:take])
                            if any(block[take:]):
                                raise ValueError('Nonzero file slack')
                            left -= take
                    if left:
                        raise ValueError('Truncated file chain')
                    files[path] = dict(size=length, sha256=digest.hexdigest())
        if len(self.used) != self.clusters - self.free:
            raise ValueError('Lost/unreferenced allocation')
        return dict(files=files, directories=directories)


def verify(path, sector, start=1024*1024, size=300*1024*1024):
    path = guarded_image(path)
    with path.open('rb') as stream:
        fs = FatOracle(stream, path.stat().st_size, start, size, sector)
        actual = fs.tree()
    expected = expected_fixture()
    if actual['files'] != expected['files'] or set(actual['directories']) != set(expected['directories']):
        raise ValueError('Independent FAT tree/file sizes/SHA256 differ')
    with path.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    return dict(kind='independent-python-fat32', passed=True, source_sha256=digest,
                image_bytes=path.stat().st_size, sector_bytes=sector, partition_start=start,
                partition_bytes=size, cluster_count=fs.clusters, file_count=len(actual['files']),
                directory_count=len(actual['directories']), volume_writes=False,
                comparison='BPB, backup/FSInfo, FAT mirror/allocation, exact paths, streamed SHA256')


class FatOracleTests(unittest.TestCase):
    def test_fixture_has_exact_counts_and_empty_file(self):
        fixture = expected_fixture()
        self.assertEqual((len(fixture['files']), len(fixture['directories'])), (108, 6))
        self.assertEqual(fixture['files']['EFI/Microsoft/Boot/Empty.txt']['size'], 0)

    def test_short_checksum_known(self):
        self.assertEqual(short_checksum(b'FOO     TXT'), 0x65)

    def test_invalid_geometry_refused_before_read(self):
        for sector, start, size in [(1024, 0, 4096), (512, 1, 4096), (512, 0, 4097), (512, 4096, 4096)]:
            with self.assertRaises(ValueError):
                FatOracle(io.BytesIO(b''), 4096, start, size, sector)

    def test_corrupt_boot_and_truncation_refused(self):
        for stream in [io.BytesIO(b''), io.BytesIO(bytes(512))]:
            with self.assertRaises(ValueError):
                FatOracle(stream, 4096, 0, 4096, 512)

    def test_relative_and_device_paths_refused(self):
        for name in ['image.raw', r'\\.\PhysicalDrive0', r'\\server\share\image.raw']:
            with self.assertRaises(ValueError):
                guarded_image(name)

    def test_qemu_sparse_source_gets_equal_ordinary_clone_and_stays_unchanged(self):
        # Regression for Windows Virtual Disk's rejection of QEMU SparseFile
        # outputs. Small own binary fixtures stay inside application runtime.
        from test_minios_fat32_case import normal_copy
        folder = Path(__file__).resolve().parents[2] / 'runtime' / 'fat32-copy-tests' / uuid.uuid4().hex
        folder.mkdir(parents=True)
        source, clone = folder / 'sparse-source.bin', folder / 'ordinary-clone.bin'
        with source.open('w+b') as stream:
            if os.name == 'nt':
                import ctypes
                import msvcrt
                kernel = ctypes.WinDLL('kernel32', use_last_error=True)
                kernel.DeviceIoControl.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p,
                    ctypes.c_uint32, ctypes.c_void_p, ctypes.c_uint32,
                    ctypes.POINTER(ctypes.c_uint32), ctypes.c_void_p]
                kernel.DeviceIoControl.restype = ctypes.c_int
                done = ctypes.c_uint32()
                if not kernel.DeviceIoControl(msvcrt.get_osfhandle(stream.fileno()), 0x900c4,
                                              None, 0, None, 0, ctypes.byref(done), None):
                    raise ctypes.WinError(ctypes.get_last_error())
            stream.write(b'FAT32')
            stream.seek(2 * 1024 * 1024 - 3)
            stream.write(b'end')
        before = source.stat()
        if os.name == 'nt':
            self.assertTrue(before.st_file_attributes & 0x200)
        proof = normal_copy(source, clone)
        self.assertTrue(proof['source_unchanged'])
        self.assertEqual(proof['bytes'], 2 * 1024 * 1024)
        self.assertEqual(getattr(source.stat(), 'st_file_attributes', 0), getattr(before, 'st_file_attributes', 0))
        self.assertFalse(getattr(clone.stat(), 'st_file_attributes', 0) & 0x4a00)
        with self.assertRaises(ValueError):
            normal_copy(source, clone)
        os.link(source, folder / 'linked-source.bin')
        with self.assertRaises(ValueError):
            normal_copy(source, folder / 'refused.bin')
        self.assertFalse((folder / 'refused.bin').exists())


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--image', type=Path)
    parser.add_argument('--sector-bytes', type=int, choices=[512, 4096], default=512)
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    if args.image:
        result = verify(args.image, args.sector_bytes)
        if args.out:
            with args.out.open('x', encoding='utf-8', newline='\n') as target:
                json.dump(result, target, indent=2)
                target.write('\n')
        print(json.dumps(result))
    else:
        unittest.main(argv=[__file__])
