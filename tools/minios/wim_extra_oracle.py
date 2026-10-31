#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""HOST-only WIM extras oracle, decompressed by pinned public wimlib.

No writer import/link, host mount, extraction or modification. Complements the
public directory-iteration ABI with raw entry flags and typed tagged metadata.
The host oracle may retain bounded metadata; usosprep remains streaming Zig.
Format references: wimlib v1.14.5 header.h/dentry.c/tagged_items.h/reparse.c
(Eric Biggers and contributors, LGPL-2.1-or-later).
"""
from __future__ import annotations
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct

MAX_METADATA = 64 * 1024**2
DLL_SHA256 = 'ba853ee1e3fc5f5798581f02e8e066ba07a0a2375f0bf444fe981431fd508495'


def num(data, offset, width):
    if offset < 0 or offset + width > len(data):
        raise ValueError('Field outside independently decoded metadata')
    return int.from_bytes(data[offset:offset + width], 'little')


def align(value):
    return (value + 7) & ~7


def corrected_reparse(data: bytes, tag: int, flags: int, header_flags: int, drive: str):
    if len(drive) != 1 or not 'A' <= drive <= 'Z':
        raise ValueError('Explicit uppercase logical destination drive required')
    base = 12 if tag == 0xa000000c else 8 if tag == 0xa0000003 else None
    if base is None:
        return data  # Inventory an unsupported type without pretending to fix it.
    if len(data) < base:
        raise ValueError('Invalid reparse data')
    ranges = [(num(data, i * 4, 2), num(data, i * 4 + 2, 2)) for i in range(2)]
    names = []
    for offset, size in ranges:
        if (offset | size) & 1 or base + offset + size > len(data):
            raise ValueError('Reparse name outside blob')
        names.append(data[base + offset:base + offset + size].decode('utf-16-le'))
    if tag == 0xa000000c and num(data, 8, 4) & 1:
        return data
    if not header_flags & 0x80 or flags & 1:
        return data
    sub, printable = names
    if not (len(sub) >= 7 and sub.startswith('\\??\\') and sub[4].isascii()
            and sub[4].isalpha() and sub[5:7] == ':\\'):
        return data
    out = bytearray(data)
    offset, size = ranges[0]
    out[base + offset:base + offset + size] = (sub[:4] + drive + sub[5:]).encode('utf-16-le')
    if len(printable) >= 3 and printable[0].isascii() and printable[0].isalpha() and printable[1:3] == ':\\':
        offset, size = ranges[1]
        out[base + offset:base + offset + size] = (drive + printable[1:]).encode('utf-16-le')
    return bytes(out)


class Archive:
    def __init__(self, source, dll: Path):
        self.source = source
        self.header = self.read(0, 208)
        if self.header[:8] != b'MSWIM\0\0\0':
            raise ValueError('WIM magic differs')
        self.flags = num(self.header, 16, 4)
        self.chunk = num(self.header, 20, 4)
        self.kind = {0: 0, 0x20000: 1, 0x40000: 2, 0x80000: 3}[self.flags & 0xe0000]
        if self.kind and (self.chunk < 4096 or self.chunk > 131072):
            raise ValueError('Unsupported host-oracle chunk size')
        with dll.open('rb') as binary:
            if hashlib.file_digest(binary, 'sha256').hexdigest() != DLL_SHA256:
                raise ValueError('Pinned public wimlib DLL differs')
        self.library = C.CDLL(str(dll))
        self.library.wimlib_create_decompressor.argtypes = [C.c_int, C.c_size_t, C.POINTER(C.c_void_p)]
        self.library.wimlib_create_decompressor.restype = C.c_int
        self.library.wimlib_decompress.argtypes = [C.c_void_p, C.c_size_t, C.c_void_p, C.c_size_t, C.c_void_p]
        self.library.wimlib_decompress.restype = C.c_int
        self.library.wimlib_free_decompressor.argtypes = [C.c_void_p]
        lookup = self.resource(self.descriptor(self.header[48:72]))
        if len(lookup) % 50:
            raise ValueError('Malformed raw lookup table')
        self.metadata, self.blobs, self.duplicates = [], {}, []
        for at in range(0, len(lookup), 50):
            row = lookup[at:at + 50]
            desc = self.descriptor(row[:24])
            digest = row[30:50].hex()
            if desc[3] & 2:
                self.metadata.append((desc, digest))
            elif not desc[3] & 1:
                if digest in self.blobs:
                    self.duplicates.append(dict(sha1=digest, first=list(self.blobs[digest]), later=list(desc)))
                else:
                    self.blobs[digest] = desc

    def read(self, at, size):
        if at < 0 or size < 0:
            raise ValueError('Negative resource range')
        self.source.seek(at)
        data = self.source.read(size)
        if len(data) != size:
            raise ValueError('Truncated WIM resource')
        return data

    @staticmethod
    def descriptor(raw):
        return num(raw, 0, 7), num(raw, 8, 8), num(raw, 16, 8), raw[7]

    def resource(self, desc, expected_sha1=None):
        stored, start, size, flags = desc
        if flags & ~7 or size > MAX_METADATA:
            raise ValueError('Only bounded nonsolid metadata/reparse blobs are accepted')
        if not flags & 4:
            if stored != size:
                raise ValueError('Uncompressed length differs')
            result = self.read(start, size)
        else:
            chunks = (size + self.chunk - 1) // self.chunk
            width = 8 if size > 0xffffffff else 4
            table_size = (chunks - 1) * width
            if not chunks or table_size > stored:
                raise ValueError('Malformed independent chunk table')
            table = self.read(start, table_size)
            positions = [0] + [num(table, i * width, width) for i in range(chunks - 1)] + [stored - table_size]
            decoder = C.c_void_p()
            if self.library.wimlib_create_decompressor(self.kind, self.chunk, C.byref(decoder)):
                raise ValueError('wimlib decompressor creation failed')
            result = bytearray()
            try:
                for i, (begin, end) in enumerate(zip(positions, positions[1:])):
                    want = min(self.chunk, size - i * self.chunk)
                    if not 0 <= begin < end <= stored - table_size or end - begin > want:
                        raise ValueError('Malformed independent chunk range')
                    block = self.read(start + table_size + begin, end - begin)
                    if len(block) == want:
                        result.extend(block)
                    else:
                        packed, unpacked = C.create_string_buffer(block), C.create_string_buffer(want)
                        if self.library.wimlib_decompress(packed, len(block), unpacked, want, decoder):
                            raise ValueError('Pinned public wimlib rejected chunk')
                        result.extend(unpacked.raw)
            finally:
                self.library.wimlib_free_decompressor(decoder)
            result = bytes(result)
        if len(result) != size or (expected_sha1 and hashlib.sha1(result).hexdigest() != expected_sha1):
            raise ValueError('Independent resource SHA1/size mismatch')
        return result

    def extras(self, index, drive='C'):
        if not 1 <= index <= len(self.metadata):
            raise ValueError('Selected raw metadata resource missing')
        desc, digest = self.metadata[index - 1]
        data = self.resource(desc, digest)
        root = max(8, align(num(data, 0, 4)))
        pending, visited = [(root, '', True, ())], set()
        while pending:
            at, parent, is_root, ancestors = pending.pop()
            while at:
                if at in visited or len(visited) >= 1_000_000:
                    raise ValueError('Cyclic/unbounded raw metadata')
                length = num(data, at, 8)
                if length == 0:
                    break
                if at & 7 or not 102 <= length <= 65536 or at + align(length) > len(data):
                    raise ValueError('Malformed raw dentry')
                visited.add(at)
                raw = data[at:at + align(length)]
                short_size, name_size = num(raw, 98, 2), num(raw, 100, 2)
                name_start, short_start = 102, 102 + name_size + (2 if name_size else 0)
                names_end = short_start + short_size + (2 if short_size else 0)
                if (short_size | name_size) & 1 or short_size > 24 or names_end > len(raw):
                    raise ValueError('Malformed independent names')
                name = raw[name_start:name_start + name_size].decode('utf-16-le')
                short = raw[short_start:short_start + short_size].decode('utf-16-le') or None
                if any(c in name for c in '\\/:\0') or name in ('.', '..') or is_root != (name == ''):
                    raise ValueError('Unsafe independent dentry path')
                path = (parent + '/' + name).lstrip('/')
                tags = []
                cursor = align(names_end)
                while cursor < len(raw):
                    tag, size = num(raw, cursor, 4), num(raw, cursor + 4, 4)
                    if cursor + 8 + align(size) > len(raw):
                        raise ValueError('Tagged metadata length exceeds dentry')
                    value = raw[cursor + 8:cursor + 8 + size]
                    if tag or size:
                        tags.append(dict(type=tag, bytes=size, sha256=hashlib.sha256(value).hexdigest(), hex=value.hex()))
                    cursor += 8 + align(size)
                attrs, flags, rptag = num(raw, 8, 4), num(raw, 94, 2), num(raw, 88, 4)
                hashes = [raw[64:84].hex()]
                next_at = at + align(length)
                for _ in range(num(raw, 96, 2)):
                    slen, nlen = align(num(data, next_at, 8)), num(data, next_at + 36, 2)
                    if slen < 38 + nlen or next_at + slen > len(data):
                        raise ValueError('Malformed independent extra stream')
                    if not nlen:
                        hashes.append(data[next_at + 16:next_at + 36].hex())
                    next_at += slen
                source_order = ancestors + (at,)
                record = dict(path=path, short_name=short, tagged=tags, reparse_flags=flags if attrs & 0x400 else None,
                              source_order=source_order, source_hardlink_group_id=num(raw,88,8) if not attrs & 0x410 else 0,
                              source_data_sha1=next((h for h in hashes if h != '0'*40), '0'*40))
                if attrs & 0x400:
                    resource_hash = next((h for h in hashes if h != '0' * 40), None)
                    if resource_hash is None:
                        raise ValueError('Reparse resource missing')
                    original = self.resource(self.blobs[resource_hash], resource_hash)
                    applied = corrected_reparse(original, rptag, flags, self.flags, drive)
                    record.update(reparse_source_sha1=resource_hash, reparse_applied_sha1=hashlib.sha1(applied).hexdigest(),
                                  reparse_data_hex=applied.hex(), reparse_fixed=applied != original)
                yield record
                child = num(raw, 16, 8)
                if child:
                    if child <= at or child >= len(data):
                        raise ValueError('Invalid independent subtree offset')
                    pending.append((child, path, False, source_order))
                if is_root:
                    break
                at = next_at


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--wim', type=Path, required=True)
    p.add_argument('--dll', type=Path, required=True)
    p.add_argument('--sha256', required=True)
    p.add_argument('--index', type=int, required=True)
    p.add_argument('--drive', default='C')
    p.add_argument('--out', type=Path, required=True)
    a = p.parse_args()
    with a.wim.open('rb') as source:
        sha = hashlib.file_digest(source, 'sha256').hexdigest()
        if sha != a.sha256:
            raise ValueError('Pinned WIM differs')
        archive = Archive(source, a.dll)
        with a.out.open('x', encoding='utf-8') as out:
            for row in archive.extras(a.index, a.drive):
                out.write(json.dumps(row, ensure_ascii=True) + '\n')
    print(json.dumps(dict(source_sha256=sha, header_flags=archive.flags,
                          duplicate_lookup_hashes=archive.duplicates)))


if __name__ == '__main__':
    main()
