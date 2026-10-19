"""Minimal FAT32 disk image writer/reader and FAT12 floppy file replacement,
for the legacy pack VM test (tools/tests/addons/win98se_vm.py). Test helper
only; 8.3 names, no long file names written (LFN entries are skipped when
reading). Copyright (C) 2026 Maksymilian and the USOS Authors,
GPL-3.0-or-later.
"""
from __future__ import annotations

import struct
import time
from pathlib import Path

SECTOR = 512
SPC = 8                      # 4 KiB clusters
RESERVED = 32
PART_START = 63              # CHS-aligned, as Windows 98 FDISK does
EOC = 0x0FFFFFFF


def _name83(name: str) -> bytes:
    name = name.upper()
    base, _, ext = name.partition('.')
    if not (1 <= len(base) <= 8 and len(ext) <= 3):
        raise ValueError(f'not an 8.3 name: {name}')
    return base.ljust(8).encode('ascii') + ext.ljust(3).encode('ascii')


def _dos_time(t: float) -> tuple[int, int]:
    lt = time.localtime(t)
    return ((lt.tm_hour << 11) | (lt.tm_min << 5) | (lt.tm_sec // 2),
            ((max(lt.tm_year, 1980) - 1980) << 9) | (lt.tm_mon << 5) | lt.tm_mday)


def _chs(lba: int) -> bytes:
    c, rem = divmod(lba, 255 * 63)
    h, s = divmod(rem, 63)
    if c > 1023:
        c, h, s = 1023, 254, 62
    return bytes([h, ((s + 1) & 0x3f) | ((c >> 2) & 0xc0), c & 0xff])


class Fat32Writer:
    """Builds MBR + one FAT32 partition (type 0x0C, active) in a raw file."""

    def __init__(self, path: Path, size_bytes: int, label: str = 'USOS98'):
        self.path = path
        self.total = size_bytes // SECTOR
        self.psize = self.total - PART_START
        self.fatsz = (self.psize - RESERVED + (SPC * 128 + 2) - 1) // (SPC * 128 + 2) + 1
        self.data_start = PART_START + RESERVED + 2 * self.fatsz
        self.nclusters = (self.total - self.data_start) // SPC
        self.fat = [0] * (self.nclusters + 2)
        self.fat[0], self.fat[1] = 0x0FFFFFF8, 0x0FFFFFFF
        self.next = 2
        self.f = open(path, 'wb')
        self.f.truncate(self.total * SECTOR)
        self.label = label
        # directory tree: path tuple -> list of (name83, attr, cluster, size, mtime)
        self.dirs: dict[tuple, list] = {(): []}
        self.dir_cluster: dict[tuple, int] = {(): self._alloc(1)}

    def _alloc(self, n: int) -> int:
        first = self.next
        if first + n > self.nclusters + 2:
            raise ValueError('image full')
        for i in range(n):
            self.fat[first + i] = first + i + 1 if i < n - 1 else EOC
        self.next += n
        return first

    def _cl_offset(self, c: int) -> int:
        return (self.data_start + (c - 2) * SPC) * SECTOR

    def mkdir(self, parts: tuple) -> None:
        for i in range(1, len(parts) + 1):
            p = tuple(x.upper() for x in parts[:i])
            if p in self.dirs:
                continue
            self.dirs[p] = []
            self.dir_cluster[p] = None  # allocated at finish (size known then)
            self.dirs[p[:-1]].append((_name83(p[-1]), 0x10, p, 0, time.time()))

    def add_file(self, parts: tuple, data: bytes, mtime: float | None = None) -> None:
        parts = tuple(x.upper() for x in parts)
        self.mkdir(parts[:-1])
        n = (len(data) + SPC * SECTOR - 1) // (SPC * SECTOR)
        first = self._alloc(n) if n else 0
        if n:
            self.f.seek(self._cl_offset(first))
            self.f.write(data)
        self.dirs[parts[:-1]].append((_name83(parts[-1]), 0x20, first, len(data), mtime or time.time()))

    def add_tree(self, src: Path, dest: tuple) -> int:
        count = 0
        for f in sorted(src.rglob('*')):
            rel = f.relative_to(src).parts
            try:
                [_name83(x) for x in rel]
            except ValueError:
                continue
            if f.is_dir():
                self.mkdir(dest + rel)
            else:
                self.add_file(dest + rel, f.read_bytes(), f.stat().st_mtime)
                count += 1
        return count

    def _entry(self, name: bytes, attr: int, cluster: int, size: int, mtime: float) -> bytes:
        t, d = _dos_time(mtime)
        return struct.pack('<11sBBBHHHHHHHI', name, attr, 0, 0, t, d, d, cluster >> 16, t, d, cluster & 0xffff, size)

    def finish(self) -> None:
        # allocate directory clusters, deepest last is fine (any order)
        for p in self.dirs:
            if self.dir_cluster.get(p) is None:
                n = max(1, ((len(self.dirs[p]) + 2) * 32 + SPC * SECTOR - 1) // (SPC * SECTOR))
                self.dir_cluster[p] = self._alloc(n)
        root_n = max(1, ((len(self.dirs[()]) + 1) * 32 + SPC * SECTOR - 1) // (SPC * SECTOR))
        if root_n > 1:
            raise ValueError('root directory too large for this helper')
        for p, entries in self.dirs.items():
            raw = b''
            if p == ():
                raw += struct.pack('<11sB20x', self.label.ljust(11).encode('ascii')[:11], 0x08)
            else:
                parent = self.dir_cluster[p[:-1]] if p[:-1] else 0
                raw += self._entry(b'.          ', 0x10, self.dir_cluster[p], 0, time.time())
                raw += self._entry(b'..         ', 0x10, parent, 0, time.time())
            for name, attr, cl, size, mt in entries:
                if attr == 0x10:
                    cl = self.dir_cluster[cl]
                raw += self._entry(name, attr, cl, size, mt)
            self.f.seek(self._cl_offset(self.dir_cluster[p]))
            self.f.write(raw)
        # FATs
        fat = struct.pack(f'<{len(self.fat)}I', *self.fat)
        for i in range(2):
            self.f.seek((PART_START + RESERVED + i * self.fatsz) * SECTOR)
            self.f.write(fat)
        # boot sector, FSInfo, backups
        bs = bytearray(SECTOR)
        bs[0:3] = b'\xeb\x58\x90'
        bs[3:11] = b'MSWIN4.1'
        struct.pack_into('<HBHBHHBHHHII', bs, 11, SECTOR, SPC, RESERVED, 2, 0, 0, 0xF8, 0, 63, 255, PART_START, self.psize)
        struct.pack_into('<IHHIHH', bs, 36, self.fatsz, 0, 0, 2, 1, 6)
        struct.pack_into('<BBBI11s8s', bs, 64, 0x80, 0, 0x29, 0x1998_0930, self.label.ljust(11).encode()[:11], b'FAT32   ')
        bs[510:512] = b'\x55\xaa'
        fsinfo = bytearray(SECTOR)
        struct.pack_into('<I', fsinfo, 0, 0x41615252)
        struct.pack_into('<III', fsinfo, 484, 0x61417272, self.nclusters + 2 - self.next, self.next)
        struct.pack_into('<I', fsinfo, 508, 0xAA550000)
        for base in (0, 6):
            self.f.seek((PART_START + base) * SECTOR)
            self.f.write(bytes(bs) + bytes(fsinfo))
            self.f.seek((PART_START + base + 2) * SECTOR)
            self.f.write(bytes(SECTOR - 2) + b'\x55\xaa')
        # MBR: partition table only (FDISK /MBR writes the code in the VM)
        mbr = bytearray(SECTOR)
        entry = bytes([0x80]) + _chs(PART_START) + bytes([0x0C]) + _chs(self.total - 1) + struct.pack('<II', PART_START, self.psize)
        mbr[446:462] = entry
        struct.pack_into('<I', mbr, 440, 0x55534F53)
        mbr[510:512] = b'\x55\xaa'
        self.f.seek(0)
        self.f.write(mbr)
        self.f.close()


class Fat32Reader:
    def __init__(self, path: Path):
        self.f = open(path, 'rb')
        mbr = self._read(0, 1)
        lba = struct.unpack_from('<I', mbr, 454)[0]
        bs = self._read(lba, 1)
        bps, self.spc, reserved, nfats = struct.unpack_from('<HBHB', bs, 11)
        fatsz, _, _, self.root = struct.unpack_from('<IHHI', bs, 36)
        self.fat_start = lba + reserved
        self.data_start = lba + reserved + nfats * fatsz

    def _read(self, lba: int, n: int) -> bytes:
        self.f.seek(lba * SECTOR)
        return self.f.read(n * SECTOR)

    def _next(self, c: int) -> int:
        self.f.seek(self.fat_start * SECTOR + c * 4)
        return struct.unpack('<I', self.f.read(4))[0] & 0x0FFFFFFF

    def _chain(self, c: int) -> bytes:
        out = b''
        while 2 <= c < 0x0FFFFFF8:
            out += self._read(self.data_start + (c - 2) * self.spc, self.spc)
            c = self._next(c)
        return out

    def listdir(self, parts: tuple) -> dict[str, tuple[int, int, int]]:
        c = self.root
        for p in parts:
            entry = self.listdir_cluster(c).get(p.upper())
            if not entry or not entry[0] & 0x10:
                raise FileNotFoundError('/'.join(parts))
            c = entry[1]
        return self.listdir_cluster(c)

    def listdir_cluster(self, c: int) -> dict[str, tuple[int, int, int]]:
        raw, out = self._chain(c), {}
        for i in range(0, len(raw), 32):
            e = raw[i:i + 32]
            if e[0] == 0:
                break
            if e[0] == 0xE5 or e[11] == 0x0F or e[11] & 0x08:
                continue
            base, ext = e[0:8].decode('latin-1').rstrip(), e[8:11].decode('latin-1').rstrip()
            name = base + ('.' + ext if ext else '')
            cl = (struct.unpack_from('<H', e, 20)[0] << 16) | struct.unpack_from('<H', e, 26)[0]
            out[name] = (e[11], cl, struct.unpack_from('<I', e, 28)[0])
        return out

    def read(self, parts: tuple) -> bytes:
        entry = self.listdir(parts[:-1]).get(parts[-1].upper())
        if not entry:
            raise FileNotFoundError('/'.join(parts))
        return self._chain(entry[1])[:entry[2]]


def floppy_replace(img: Path, name: str, data: bytes) -> None:
    """Replace a root-directory file of a FAT12 floppy image in place (the new
    content must fit into the file's existing clusters)."""
    b = bytearray(img.read_bytes())
    bps, spc, reserved, nfats, rootents = struct.unpack_from('<HBHBH', b, 11)
    fatsz = struct.unpack_from('<H', b, 22)[0]
    root = (reserved + nfats * fatsz) * bps
    data_start = root + rootents * 32
    want = _name83(name)
    for i in range(rootents):
        e = root + i * 32
        if bytes(b[e:e + 11]) != want:
            continue
        c = struct.unpack_from('<H', b, e + 26)[0]
        chain = []
        while 2 <= c < 0xFF8:
            chain.append(c)
            off = reserved * bps + c * 3 // 2
            v = struct.unpack_from('<H', b, off)[0]
            c = (v >> 4) if c & 1 else (v & 0xFFF)
        csize = spc * bps
        if len(data) > len(chain) * csize:
            raise ValueError(f'{name}: new content does not fit ({len(data)} > {len(chain) * csize})')
        for k, cl in enumerate(chain):
            chunk = data[k * csize:(k + 1) * csize].ljust(csize, b'\0')
            o = data_start + (cl - 2) * csize
            b[o:o + csize] = chunk
        struct.pack_into('<I', b, e + 28, len(data))
        img.write_bytes(bytes(b))
        return
    raise FileNotFoundError(name)


def floppy_hide(img: Path, name: str) -> None:
    """Mark a root-directory entry of a FAT12 floppy image as deleted (its
    clusters stay allocated; enough for a test image)."""
    b = bytearray(img.read_bytes())
    bps, spc, reserved, nfats, rootents = struct.unpack_from('<HBHBH', b, 11)
    fatsz = struct.unpack_from('<H', b, 22)[0]
    root = (reserved + nfats * fatsz) * bps
    want = _name83(name)
    for i in range(rootents):
        e = root + i * 32
        if bytes(b[e:e + 11]).upper() == want:
            b[e] = 0xE5
            img.write_bytes(bytes(b))
            return
    raise FileNotFoundError(name)
