#!/usr/bin/env python3
"""Dependency-free ISO9660 reader and FAT16 builder/reader for the Win16 harness.

Only the pieces the Win16 test needs are implemented:

* ``Iso`` - read an ISO9660 image (the MS-DOS 6.22 and Windows 3.1 media),
* ``Fat16Builder`` - create a 64/128 MiB hard-disk image with an MBR, one
  active FAT16 partition and a caller-supplied list of files,
* ``Fat16Reader`` - read files back from such an image,
* ``Fat16Volume`` - read and write files in the FAT16 partition of an
  existing image (staging into an installed Windows without reinstalling it).

The MS-DOS boot sector code is not written from scratch: it is taken from the
MS-DOS 6.22 ``SYS.COM`` (the utility embeds the boot sector template) and only
its BIOS parameter block is replaced with the geometry of the new image - the
same split the production installer uses for the user's own boot sector
(``src/platform/bios/dos_fat16_seed.zig``: bytes 11..62 from USOS, the rest of
the boot sector from the original MS-DOS media).
"""
from __future__ import annotations

import struct
from pathlib import Path

SECTOR = 512


class IsoError(RuntimeError):
    pass


class Iso:
    """Read-only view of an ISO9660 image (8.3 names, nested directories)."""

    def __init__(self, path: Path) -> None:
        self.path = Path(path)
        self._fh = self.path.open('rb')
        pvd = self._sector(16)
        if pvd[1:6] != b'CD001':
            raise IsoError('%s: no ISO9660 primary volume descriptor' % self.path)
        self.entries: dict[str, tuple[int, int]] = {}
        self._walk(struct.unpack_from('<I', pvd, 158)[0],
                   struct.unpack_from('<I', pvd, 166)[0], '')

    def close(self) -> None:
        self._fh.close()

    def __enter__(self) -> 'Iso':
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    def _sector(self, lba: int) -> bytes:
        self._fh.seek(lba * 2048)
        return self._fh.read(2048)

    def _walk(self, lba: int, size: int, prefix: str) -> None:
        pos, end = lba * 2048, lba * 2048 + size
        while pos < end:
            self._fh.seek(pos)
            length = self._fh.read(1)[0]
            if length == 0:
                pos = (pos // 2048 + 1) * 2048
                continue
            self._fh.seek(pos)
            record = self._fh.read(length)
            extent = struct.unpack_from('<I', record, 2)[0]
            size_le = struct.unpack_from('<I', record, 10)[0]
            flags = record[25]
            name = record[33:33 + record[32]].decode('latin1')
            if name not in ('\x00', '\x01'):
                base = name.split(';', 1)[0].upper().rstrip('.')
                path = prefix + base
                self.entries[path] = (extent, size_le)
                if flags & 2:
                    self._walk(extent, size_le, path + '/')
            pos += length

    def read(self, name: str) -> bytes:
        key = name.upper().strip('/')
        if key not in self.entries:
            raise IsoError('%s: no %s' % (self.path.name, name))
        lba, size = self.entries[key]
        self._fh.seek(lba * 2048)
        data = self._fh.read(size)
        if len(data) != size:
            raise IsoError('%s: short read of %s' % (self.path.name, name))
        return data

    def has(self, name: str) -> bool:
        return name.upper().strip('/') in self.entries


# Classic 32-byte MBR loader: read the first sector of partition entry 0 with
# INT 13h AH=42h and jump to it with DL = boot drive.
MBR_CODE = bytes.fromhex(
    'FA'                 # cli
    '31C0'               # xor ax,ax
    '8ED0'               # mov ss,ax
    'BC007C'             # mov sp,7c00
    '8EC0'               # mov es,ax
    '8ED8'               # mov ds,ax
    'FB'                 # sti
    '8816B007'           # mov [07b0],dl
    'C70600061000'       # mov word [0600],0x0010   DAP size, 1 sector
    'C70602060100'       # mov word [0602],0x0001   count
    'C7060406007C'       # mov word [0604],0x7c00   offset
    'C70606060000'       # mov word [0606],0x0000   segment
    'A1C67D'             # mov ax,[7dc6]            partition LBA low
    'A30806'             # mov [0608],ax
    'A1C87D'             # mov ax,[7dc8]            partition LBA high
    'A30A06'             # mov [060a],ax
    'B442'               # mov ah,42
    'BE0006'             # mov si,0600
    'CD13'               # int 13
    '7302'               # jnc +2
    'CD18'               # int 18 (no bootable partition)
    '8A16B007'           # mov dl,[07b0]
    'EA007C0000'         # jmp 0000:7c00
)


def mbr_partition(boot_code: bytes, start_lba: int, sectors: int,
                  heads: int = 16, tracks: int = 63) -> bytes:
    """MBR: boot code, one active FAT16B entry, 0x55AA."""
    if len(boot_code) > 446:
        raise ValueError('MBR boot code longer than 446 bytes')
    mbr = bytearray(SECTOR)
    mbr[:len(boot_code)] = boot_code

    def chs(lba: int) -> bytes:
        # BIOS geometry of the QEMU IDE disk: 16 heads, 63 sectors/track.
        cylinder, rest = divmod(lba, heads * tracks)
        head, sector = divmod(rest, tracks)
        if cylinder > 1023:
            raise ValueError('partition beyond CHS limit (cylinder %d)' % cylinder)
        return bytes((head, (sector + 1) | ((cylinder >> 2) & 0xC0), cylinder & 0xFF))

    entry = bytearray(16)
    entry[0] = 0x80
    entry[1:4] = chs(start_lba)
    entry[4] = 0x06
    entry[5:8] = chs(start_lba + sectors - 1)
    struct.pack_into('<I', entry, 8, start_lba)
    struct.pack_into('<I', entry, 12, sectors)
    mbr[446:462] = entry
    mbr[510:512] = b'\x55\xaa'
    return bytes(mbr)


def boot_sector_template(sys_com: bytes) -> bytes:
    """Find the MS-DOS 6.22 boot sector embedded in SYS.COM.

    SYS.COM writes this 512-byte record to the target: byte 0 is the jump, 3..11
    the OEM name ("MSDOS6.2"), 11..62 the BPB that SYS fills in, and 62..510 the
    loader code that reads IO.SYS.  Only a record with a self-consistent BPB is
    accepted, so a random occurrence of the OEM string cannot be picked.
    """
    found: list[bytes] = []
    pos = sys_com.find(b'MSDOS6.2')
    while pos != -1:
        start = pos - 3
        if start >= 0 and start + SECTOR <= len(sys_com):
            candidate = sys_com[start:start + SECTOR]
            bps = struct.unpack_from('<H', candidate, 11)[0]
            reserved = struct.unpack_from('<H', candidate, 14)[0]
            nfats = candidate[16]
            table = struct.unpack_from('<H', candidate, 22)[0]
            spt = struct.unpack_from('<H', candidate, 24)[0]
            heads = struct.unpack_from('<H', candidate, 26)[0]
            if (candidate[0] in (0xE9, 0xEB) and candidate[510:512] == b'\x55\xaa'
                    and bps in (512, 1024, 2048, 4096)
                    and 1 <= candidate[13] <= 64 and reserved >= 1
                    and 1 <= nfats <= 2 and table >= 1
                    and 1 <= spt <= 63 and 1 <= heads <= 255):
                found.append(candidate)
        pos = sys_com.find(b'MSDOS6.2', pos + 1)
    if not found:
        raise IsoError('SYS.COM carries no MS-DOS boot sector template')
    for candidate in found:
        if candidate[54:62].strip(b' \x00') == b'FAT16':
            return candidate
    return found[0]


def volume_geometry(total_sectors: int, hidden: int, spc: int = 4,
                    root_entries: int = 512, spt: int = 63,
                    heads: int = 16, label: bytes = b'USOSWIN16') -> dict[str, int | bytes]:
    """BPB fields for a FAT16 volume (2 KiB clusters at 64-128 MiB)."""
    reserved, nfats = 1, 2
    root_sectors = (root_entries * 32 + SECTOR - 1) // SECTOR
    while True:
        clusters = total_sectors // spc
        spf = ((clusters + 2) * 2 + SECTOR - 1) // SECTOR
        data_sectors = total_sectors - reserved - nfats * spf - root_sectors
        if data_sectors // spc + 2 <= 0xFFF5:
            return {'total': total_sectors, 'hidden': hidden, 'spc': spc,
                    'reserved': reserved, 'nfats': nfats,
                    'root_entries': root_entries, 'root_sectors': root_sectors,
                    'spf': spf, 'spt': spt, 'heads': heads, 'media': 0xF8,
                    'label': label}
        spc += 1
        if spc > 64:
            raise ValueError('no FAT16 geometry for %d sectors' % total_sectors)


def vbr(template: bytes, geometry: dict[str, int | bytes]) -> bytes:
    """MS-DOS loader code + our BPB (bytes 11..62), exactly like the installer."""
    g = geometry
    sector = bytearray(template[:SECTOR])
    struct.pack_into('<H', sector, 11, SECTOR)
    sector[13] = g['spc']            # type: ignore[assignment]
    struct.pack_into('<H', sector, 14, g['reserved'])      # type: ignore[arg-type]
    sector[16] = g['nfats']          # type: ignore[assignment]
    struct.pack_into('<H', sector, 17, g['root_entries'])  # type: ignore[arg-type]
    struct.pack_into('<H', sector, 19, 0)                  # FAT16B: total 16 = 0
    sector[21] = g['media']          # type: ignore[assignment]
    struct.pack_into('<H', sector, 22, g['spf'])           # type: ignore[arg-type]
    struct.pack_into('<H', sector, 24, g['spt'])           # type: ignore[arg-type]
    struct.pack_into('<H', sector, 26, g['heads'])         # type: ignore[arg-type]
    struct.pack_into('<I', sector, 28, g['hidden'])        # type: ignore[arg-type]
    struct.pack_into('<I', sector, 32, g['total'])         # type: ignore[arg-type]
    struct.pack_into('<H', sector, 36, 0x80)               # fixed disk
    sector[38] = 0x29                                      # extended boot record
    struct.pack_into('<I', sector, 39, 0x55534F53)         # volume serial 'USOS'
    sector[43:54] = g['label'].ljust(11)[:11]              # type: ignore[assignment]
    sector[54:62] = b'FAT16   '
    return bytes(sector)


def short_name(name: str) -> bytes:
    """DOS 8.3 name -> 11 bytes (the caller supplies valid 8.3 names)."""
    base, _, ext = name.upper().partition('.')
    if not base or len(base) > 8 or len(ext) > 3:
        raise ValueError('not an 8.3 name: %s' % name)
    return base.ljust(8).encode('ascii') + ext.ljust(3).encode('ascii')


def _entry(name: bytes, attr: int, cluster: int, size: int = 0) -> bytes:
    record = bytearray(32)
    record[0:11] = name
    record[11] = attr
    struct.pack_into('<H', record, 26, cluster)
    struct.pack_into('<I', record, 28, size)
    return bytes(record)


class Fat16Builder:
    """Collect files, then write one FAT16 hard-disk image."""

    def __init__(self, total_bytes: int, template: bytes) -> None:
        if total_bytes % SECTOR:
            raise ValueError('image size must be a multiple of 512')
        self.total_sectors = total_bytes // SECTOR
        self.start_lba = 63
        self.geometry = volume_geometry(self.total_sectors - self.start_lba,
                                        self.start_lba)
        self.vbr = vbr(template, self.geometry)
        self.files: list[tuple[str, str, bytes, int]] = []  # dir, name, data, attr

    def add(self, path: str, data: bytes, attr: int = 0x20) -> None:
        directory, _, name = path.strip('\\/').replace('/', '\\').rpartition('\\')
        self.files.append((directory.upper(), name.upper(), data, attr))

    def build(self) -> bytes:
        g = self.geometry
        cluster_bytes = SECTOR * g['spc']          # type: ignore[operator]
        directories: list[str] = ['']
        for directory, _, _, _ in self.files:
            parts = directory.split('\\') if directory else []
            for depth in range(1, len(parts) + 1):
                path = '\\'.join(parts[:depth])
                if path not in directories:
                    directories.append(path)

        image = bytearray(self.total_sectors * SECTOR)
        part = memoryview(image)[self.start_lba * SECTOR:]
        part[0:SECTOR] = self.vbr

        fat_offset = SECTOR * g['reserved']        # type: ignore[operator]
        root_offset = fat_offset + g['nfats'] * SECTOR * g['spf']  # type: ignore[operator]
        data_offset = root_offset + SECTOR * g['root_sectors']     # type: ignore[operator]
        fat = bytearray(SECTOR * g['spf'])                          # type: ignore[operator]
        struct.pack_into('<H', fat, 0, 0xFFF8)
        struct.pack_into('<H', fat, 2, 0xFFFF)
        next_cluster = 2
        first_cluster: dict[str, int] = {}

        def allocate(key: str, size: int) -> int:
            nonlocal next_cluster
            count = max(1, (size + cluster_bytes - 1) // cluster_bytes)
            if next_cluster + count > 0xFFF0:
                raise ValueError('FAT16 image too small')
            first = next_cluster
            for cluster in range(first, first + count):
                struct.pack_into('<H', fat, cluster * 2,
                                 cluster + 1 if cluster + 1 < first + count else 0xFFFF)
            first_cluster[key] = first
            next_cluster += count
            return first

        # Files first, in add order: IO.SYS gets cluster 2 and MSDOS.SYS follows
        # it directly, which is what the MS-DOS 6.22 loader expects.
        for directory, name, data, _ in self.files:
            key = (directory + '\\' + name) if directory else name
            allocate(key, len(data))

        def dir_bytes(directory: str) -> int:
            """Directory space needed: '.' + '..' + files + subdirectories."""
            count = 2
            count += sum(1 for file_dir, _, _, _ in self.files if file_dir == directory)
            count += sum(1 for path in directories[1:]
                         if path.rpartition('\\')[0] == directory)
            return count * 32

        for directory in directories[1:]:
            allocate('DIR:' + directory, dir_bytes(directory))

        for directory, name, data, _ in self.files:
            key = (directory + '\\' + name) if directory else name
            offset = data_offset + (first_cluster[key] - 2) * cluster_bytes
            part[offset:offset + len(data)] = data

        def children(directory: str) -> tuple[list[tuple[str, int, int]],
                                              list[tuple[str, int, int]]]:
            """(files, subdirectories) of one directory as (name, cluster, size)."""
            files, subdirs = [], []
            for file_dir, name, data, _ in self.files:
                if file_dir == directory:
                    key = (directory + '\\' + name) if directory else name
                    files.append((name, first_cluster[key], len(data)))
            for path in directories[1:]:
                parent, _, leaf = path.rpartition('\\')
                if parent == directory:
                    subdirs.append((leaf, first_cluster['DIR:' + path], 0))
            return files, subdirs

        root_entries = g['root_entries']
        root = bytearray(SECTOR * g['root_sectors'])  # type: ignore[operator]
        files, subdirs = children('')
        index = 0
        for name, cluster, size in files:
            if index >= root_entries:
                raise ValueError('root directory full')
            root[index * 32:(index + 1) * 32] = _entry(short_name(name), 0x20,
                                                       cluster, size)
            index += 1
        for name, cluster, _ in subdirs:
            if index >= root_entries:
                raise ValueError('root directory full')
            root[index * 32:(index + 1) * 32] = _entry(short_name(name), 0x10, cluster)
            index += 1

        for directory in directories[1:]:
            parent, _, _ = directory.rpartition('\\')
            clusters = (dir_bytes(directory) + cluster_bytes - 1) // cluster_bytes
            block = bytearray(clusters * cluster_bytes)
            records = [_entry(b'.          ', 0x10, first_cluster['DIR:' + directory]),
                       _entry(b'..         ', 0x10,
                              first_cluster['DIR:' + parent] if parent else 0)]
            files, subdirs = children(directory)
            records += [_entry(short_name(name), 0x20, cluster, size)
                        for name, cluster, size in files]
            records += [_entry(short_name(name), 0x10, cluster)
                        for name, cluster, _ in subdirs]
            for depth, record in enumerate(records):
                block[depth * 32:(depth + 1) * 32] = record
            offset = data_offset + (first_cluster['DIR:' + directory] - 2) * cluster_bytes
            part[offset:offset + len(block)] = bytes(block)

        part[fat_offset:fat_offset + len(fat)] = fat
        part[fat_offset + SECTOR * g['spf']:fat_offset + 2 * SECTOR * g['spf']] = fat
        part[root_offset:root_offset + len(root)] = root
        image[0:SECTOR] = mbr_partition(MBR_CODE, self.start_lba,
                                        self.total_sectors - self.start_lba)
        del part
        return bytes(image)


class Fat16Reader:
    """Read files from a FAT16 hard-disk image written by ``Fat16Builder``."""

    def __init__(self, path: Path) -> None:
        self.data = Path(path).read_bytes()
        mbr = self.data[:SECTOR]
        if mbr[510:512] != b'\x55\xaa':
            raise ValueError('%s: no MBR signature' % path)
        self.start = struct.unpack_from('<I', mbr, 446 + 8)[0]
        self.part = memoryview(self.data)[self.start * SECTOR:]
        if struct.unpack_from('<H', self.part, 11)[0] != SECTOR:
            raise ValueError('%s: unsupported sector size' % path)
        self.spc = self.part[13]
        self.reserved = struct.unpack_from('<H', self.part, 14)[0]
        self.nfats = self.part[16]
        self.root_entries = struct.unpack_from('<H', self.part, 17)[0]
        self.spf = struct.unpack_from('<H', self.part, 22)[0]
        self.fat_offset = SECTOR * self.reserved
        self.root_offset = self.fat_offset + self.nfats * SECTOR * self.spf
        self.data_offset = self.root_offset + self.root_entries * 32
        self.index: dict[str, tuple[int, int, int]] = {}
        self._walk(self._entries_bytes(0, 0), '')

    def _chain(self, first: int, size: int | None) -> bytes:
        out = bytearray()
        cluster = first
        while cluster not in (0, 0xFFFF) and (size is None or len(out) < size):
            offset = self.data_offset + (cluster - 2) * SECTOR * self.spc
            out += self.part[offset:offset + SECTOR * self.spc]
            value = struct.unpack_from('<H', self.part, self.fat_offset + cluster * 2)[0]
            cluster = value if value < 0xFFF8 else 0xFFFF
        if size is not None and size and len(out) < size:
            raise ValueError('cluster chain shorter than the file')
        return bytes(out if size is None else out[:size])

    def _entries_bytes(self, first: int, size: int | None) -> bytes:
        if first == 0:  # root directory: fixed area, not a cluster chain
            return bytes(self.part[self.root_offset:
                                   self.root_offset + self.root_entries * 32])
        return self._chain(first, size)

    def _walk(self, raw: bytes, prefix: str) -> None:
        for pos in range(0, len(raw), 32):
            record = raw[pos:pos + 32]
            if record[0] == 0:
                break
            if record[0] == 0xE5 or record[11] == 0x0F:
                continue
            name = record[0:11].decode('ascii', 'replace')
            base, ext = name[:8].rstrip(), name[8:].rstrip()
            short = (base + '.' + ext if ext else base).upper()
            if short in ('.', '..'):
                continue
            cluster = struct.unpack_from('<H', record, 26)[0]
            size = struct.unpack_from('<I', record, 28)[0]
            attr = record[11]
            self.index[prefix + short] = (cluster, size, attr)
            if attr & 0x10:
                self._walk(self._entries_bytes(cluster, None), prefix + short + '\\')

    def read(self, path: str) -> bytes:
        key = path.upper().replace('/', '\\').strip('\\')
        if key not in self.index:
            raise FileNotFoundError(path)
        cluster, size, attr = self.index[key]
        if attr & 0x10:
            raise IsADirectoryError(path)
        return self._chain(cluster, size)

    def exists(self, path: str) -> bool:
        try:
            self.read(path)
        except (FileNotFoundError, IsADirectoryError):
            return False
        return True


class Fat16Volume:
    """Read and write files in the FAT16 partition of an existing image.

    ``Fat16Builder`` writes a whole image; this class edits one in place, the
    way the QEMU harness stages ``WINSOCK.DLL``/``TESTLOAD.EXE`` into an
    already installed Windows, rewrites ``AUTOEXEC.BAT`` for one run and
    removes the DLL again for the negative run.  Both FAT copies are kept in
    sync and a replaced file returns its clusters to the table.

    Only 8.3 names are created; existing long-file-name entries are left as
    they are (Windows itself writes them), so replacing a file never touches
    the preceding 0x0F records.
    """

    def __init__(self, path: Path) -> None:
        self.path = Path(path)
        self._fh = self.path.open('r+b')
        head = self._read(0, SECTOR)
        start = 0
        if head[510:512] == b'\x55\xaa' and head[446 + 4] in (0x04, 0x06, 0x0E):
            start = struct.unpack_from('<I', head, 446 + 8)[0]
        self.start = start
        vbr = self._read(start * SECTOR, SECTOR)
        if struct.unpack_from('<H', vbr, 11)[0] != SECTOR:
            raise ValueError('%s: unsupported sector size' % self.path)
        self.spc = vbr[13]
        self.reserved = struct.unpack_from('<H', vbr, 14)[0]
        self.nfats = vbr[16]
        self.root_entries = struct.unpack_from('<H', vbr, 17)[0]
        self.spf = struct.unpack_from('<H', vbr, 22)[0]
        total = struct.unpack_from('<H', vbr, 19)[0] or struct.unpack_from('<I', vbr, 32)[0]
        base = start * SECTOR
        self.fat = base + self.reserved * SECTOR
        self.root = self.fat + self.nfats * self.spf * SECTOR
        self.data = self.root + self.root_entries * 32
        self.cluster_bytes = SECTOR * self.spc
        data_sectors = total - self.reserved - self.nfats * self.spf \
            - (self.root_entries * 32) // SECTOR
        self.max_cluster = data_sectors // self.spc + 2

    # -- raw access -------------------------------------------------------
    def _read(self, offset: int, size: int) -> bytes:
        self._fh.seek(offset)
        data = self._fh.read(size)
        if len(data) < size:
            raise ValueError('%s: short read at %d' % (self.path, offset))
        return data

    def _write(self, offset: int, data: bytes) -> None:
        self._fh.seek(offset)
        self._fh.write(data)

    def close(self) -> None:
        self._fh.close()

    def __enter__(self) -> 'Fat16Volume':
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    # -- FAT --------------------------------------------------------------
    def _fat_get(self, cluster: int) -> int:
        return struct.unpack_from('<H', self._read(self.fat + cluster * 2, 2))[0]

    def _fat_set(self, cluster: int, value: int) -> None:
        record = struct.pack('<H', value)
        for copy in range(self.nfats):
            self._write(self.fat + copy * self.spf * SECTOR + cluster * 2, record)

    def _cluster_offset(self, cluster: int) -> int:
        return self.data + (cluster - 2) * self.cluster_bytes

    def _read_chain(self, first: int, size: int | None = None) -> bytes:
        out = bytearray()
        cluster = first
        while 2 <= cluster < self.max_cluster and (size is None or len(out) < size):
            out += self._read(self._cluster_offset(cluster), self.cluster_bytes)
            value = self._fat_get(cluster)
            cluster = 0xFFFF if value >= 0xFFF8 else value
        if size is not None:
            if len(out) < size:
                raise ValueError('%s: cluster chain shorter than %d bytes'
                                 % (self.path, size))
            return bytes(out[:size])
        return bytes(out)

    def _free_chain(self, first: int) -> None:
        cluster = first
        while 2 <= cluster < self.max_cluster:
            value = self._fat_get(cluster)
            self._fat_set(cluster, 0)
            if value >= 0xFFF8 or value < 2:
                break
            cluster = value

    def _alloc(self, size: int) -> int:
        """First free cluster of a chain for ``size`` bytes (zeroed)."""
        count = max(1, (size + self.cluster_bytes - 1) // self.cluster_bytes)
        free: list[int] = []
        cluster = 2
        while cluster < self.max_cluster and len(free) < count:
            if self._fat_get(cluster) == 0:
                free.append(cluster)
            cluster += 1
        if len(free) < count:
            raise ValueError('%s: FAT16 partition full (%d clusters needed)'
                             % (self.path, count))
        for index, cluster in enumerate(free):
            self._fat_set(cluster, free[index + 1] if index + 1 < count else 0xFFFF)
            self._write(self._cluster_offset(cluster), bytes(self.cluster_bytes))
        return free[0]

    def _write_chain(self, first: int, data: bytes) -> None:
        cluster, pos = first, 0
        while pos < len(data):
            chunk = data[pos:pos + self.cluster_bytes]
            self._write(self._cluster_offset(cluster), chunk)
            pos += len(chunk)
            if pos < len(data):
                cluster = self._fat_get(cluster)
                if not 2 <= cluster < self.max_cluster:
                    raise ValueError('%s: broken chain while writing' % self.path)

    # -- directories ------------------------------------------------------
    def _dir_bytes(self, first: int) -> bytes:
        if first == 0:  # root: fixed area, no chain
            return self._read(self.root, self.root_entries * 32)
        return self._read_chain(first)

    def _write_dir(self, first: int, raw: bytes) -> None:
        if first == 0:
            if len(raw) > self.root_entries * 32:
                raise ValueError('%s: root directory full' % self.path)
            self._write(self.root, raw)
            return
        cluster, pos = first, 0
        while pos < len(raw):
            self._write(self._cluster_offset(cluster), raw[pos:pos + self.cluster_bytes])
            pos += self.cluster_bytes
            if pos < len(raw):
                cluster = self._fat_get(cluster)
                if not 2 <= cluster < self.max_cluster:
                    raise ValueError('%s: directory chain too short' % self.path)

    @staticmethod
    def _short_name(record: bytes) -> str:
        name = record[0:11].decode('ascii', 'replace')
        base, ext = name[:8].rstrip(), name[8:].rstrip()
        return (base + '.' + ext if ext else base).upper()

    def _find_entry(self, raw: bytes, name: str) -> int | None:
        for offset in range(0, len(raw), 32):
            record = raw[offset:offset + 32]
            if record[0] == 0:
                return None
            if record[0] == 0xE5 or record[11] == 0x0F:
                continue
            if self._short_name(record) == name.upper():
                return offset
        return None

    def _slot(self, raw: bytes, first: int) -> int:
        """Free 32-byte slot offset, growing the directory by one cluster."""
        for offset in range(0, len(raw), 32):
            if raw[offset] in (0x00, 0xE5):
                return offset
        if first == 0:
            raise ValueError('%s: root directory full' % self.path)
        last = first
        while True:
            value = self._fat_get(last)
            if value >= 0xFFF8:
                break
            last = value
        self._fat_set(last, self._alloc(self.cluster_bytes))
        return len(raw)

    def _walk_to(self, parts: list[str], create: bool) -> tuple[int, bytes]:
        """(first cluster, raw directory) of ``parts``; creates directories."""
        first, raw = 0, self._dir_bytes(0)
        for depth, part in enumerate(parts):
            offset = self._find_entry(raw, part)
            if offset is not None:
                if not raw[offset + 11] & 0x10:
                    raise ValueError('%s: %s is not a directory'
                                     % (self.path, '\\'.join(parts[:depth + 1])))
                first = struct.unpack_from('<H', raw, offset + 26)[0]
                raw = self._dir_bytes(first)
                continue
            if not create:
                raise FileNotFoundError('\\'.join(parts[:depth + 1]))
            new = self._alloc(self.cluster_bytes)
            offset = self._slot(raw, first)
            block = bytearray(raw + bytes(self.cluster_bytes) if offset == len(raw) else raw)
            block[offset:offset + 32] = _entry(short_name(part), 0x10, new)
            self._write_dir(first, bytes(block))
            parent = first
            first, raw = new, bytes(self.cluster_bytes)
            block = bytearray(raw)
            block[0:32] = _entry(b'.          ', 0x10, new)
            block[32:64] = _entry(b'..         ', 0x10, parent)
            self._write(self._cluster_offset(new), bytes(block))
        return first, raw

    # -- public API -------------------------------------------------------
    @staticmethod
    def _parts(path: str) -> list[str]:
        return [part for part in path.strip('\\/').replace('/', '\\').split('\\') if part]

    def put(self, path: str, data: bytes, attr: int = 0x20) -> None:
        """Create or replace one file (missing parent directories are made)."""
        parts = self._parts(path)
        if not parts:
            raise ValueError('empty path')
        first, raw = (self._walk_to(parts[:-1], create=True) if len(parts) > 1
                      else (0, self._dir_bytes(0)))
        offset = self._find_entry(raw, parts[-1])
        block = bytearray(raw)
        if offset is not None:
            if raw[offset + 11] & 0x10:
                raise ValueError('%s: is a directory' % path)
            old = struct.unpack_from('<H', raw, offset + 26)[0]
            if old >= 2:
                self._free_chain(old)
        else:
            offset = self._slot(raw, first)
            if offset == len(raw):
                block += bytes(self.cluster_bytes)
        cluster = self._alloc(len(data)) if data else 0
        if data:
            self._write_chain(cluster, data)
        block[offset:offset + 32] = _entry(short_name(parts[-1]), attr, cluster, len(data))
        self._write_dir(first, bytes(block))

    def remove(self, path: str) -> bool:
        """Delete a file; returns False when it did not exist."""
        parts = self._parts(path)
        try:
            first, raw = (self._walk_to(parts[:-1], create=False) if len(parts) > 1
                          else (0, self._dir_bytes(0)))
        except FileNotFoundError:
            return False
        offset = self._find_entry(raw, parts[-1])
        if offset is None or raw[offset + 11] & 0x10:
            return False
        old = struct.unpack_from('<H', raw, offset + 26)[0]
        if old >= 2:
            self._free_chain(old)
        block = bytearray(raw)
        block[offset] = 0xE5
        self._write_dir(first, bytes(block))
        return True

    def read(self, path: str) -> bytes:
        parts = self._parts(path)
        first, raw = (self._walk_to(parts[:-1], create=False) if len(parts) > 1
                      else (0, self._dir_bytes(0)))
        offset = self._find_entry(raw, parts[-1])
        if offset is None or raw[offset + 11] & 0x10:
            raise FileNotFoundError(path)
        cluster = struct.unpack_from('<H', raw, offset + 26)[0]
        size = struct.unpack_from('<I', raw, offset + 28)[0]
        return self._read_chain(cluster, size) if size else b''

    def exists(self, path: str) -> bool:
        try:
            self.read(path)
        except FileNotFoundError:
            return False
        return True
