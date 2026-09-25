"""Read the NTFS $Volume flags (dirty bit etc.) of every NTFS partition of a
disk image, read-only. Used to check that USOS leaves a prepared XP target
clean (docs/research/xp-first-boot-2026-09-25.md).

    python tools/tests/ntfs_volume_flags.py IMAGE.qcow2|IMAGE.raw [--expect-clean]

qcow2 images are converted to a temporary raw file next to the image.
"""
from __future__ import annotations

import argparse
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
QEMU_IMG = ROOT / 'tools' / 'qemu' / 'qemu-img.exe'
FLAGS = {0x0001: 'DIRTY', 0x0002: 'RESIZE_LOGFILE', 0x0004: 'UPGRADE_ON_MOUNT', 0x0008: 'MOUNTED_ON_NT4',
         0x0010: 'DELETE_USN_UNDERWAY', 0x0020: 'REPAIR_OBJECT_ID', 0x4000: 'CHKDSK_UNDERWAY', 0x8000: 'MODIFIED_BY_CHKDSK'}


def partitions(disk):
    disk.seek(0)
    mbr = disk.read(512)
    for i in range(4):
        entry = mbr[446 + 16 * i:462 + 16 * i]
        if entry[4] in (0x07,):
            start, count = struct.unpack_from('<II', entry, 8)
            yield i + 1, start


def record(disk, offset, size, sector):
    disk.seek(offset)
    data = bytearray(disk.read(size))
    if data[:4] != b'FILE':
        raise ValueError('not a FILE record')
    usa_off, usa_count = struct.unpack_from('<HH', data, 4)
    usn = data[usa_off:usa_off + 2]
    for i in range(1, usa_count):
        end = i * sector - 2
        if data[end:end + 2] != usn:
            raise ValueError('fixup mismatch')
        data[end:end + 2] = data[usa_off + 2 * i:usa_off + 2 * i + 2]
    return bytes(data)


def volume_info(disk, start_lba):
    base = start_lba * 512
    disk.seek(base)
    boot = disk.read(512)
    if boot[3:11] != b'NTFS    ':
        return None
    bps = struct.unpack_from('<H', boot, 0x0B)[0]
    spc = boot[0x0D]
    cluster = bps * spc
    mft_lcn = struct.unpack_from('<Q', boot, 0x30)[0]
    cpr = struct.unpack_from('<b', boot, 0x40)[0]
    rsize = cluster * cpr if cpr > 0 else 1 << (-cpr)
    rec = record(disk, base + mft_lcn * cluster + 3 * rsize, rsize, bps)
    at = struct.unpack_from('<H', rec, 0x14)[0]
    while at + 8 <= len(rec):
        atype, alen = struct.unpack_from('<II', rec, at)
        if atype == 0xFFFFFFFF or alen == 0:
            break
        if atype == 0x70 and rec[at + 8] == 0:
            voff = struct.unpack_from('<H', rec, at + 0x14)[0]
            value = rec[at + voff:at + voff + 12]
            major, minor, flags = value[8], value[9], struct.unpack_from('<H', value, 10)[0]
            return major, minor, flags
        at += alen
    raise ValueError('$VOLUME_INFORMATION not found')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('image', type=Path)
    parser.add_argument('--expect-clean', action='store_true')
    a = parser.parse_args()
    image = a.image.resolve()
    raw = image
    temp = None
    if image.suffix.lower() == '.qcow2':
        temp = image.with_suffix('.flags.raw')
        subprocess.run([str(QEMU_IMG), 'convert', '-f', 'qcow2', '-O', 'raw', str(image), str(temp)], check=True)
        raw = temp
    dirty = False
    try:
        with raw.open('rb') as disk:
            for index, start in partitions(disk):
                info = volume_info(disk, start)
                if info is None:
                    continue
                major, minor, flags = info
                names = [n for bit, n in FLAGS.items() if flags & bit] or ['clean']
                dirty |= bool(flags & 0x0001)
                print(f'partition {index} start={start} NTFS {major}.{minor} flags=0x{flags:04x} {"|".join(names)}')
    finally:
        if temp:
            temp.unlink(missing_ok=True)
    if a.expect_clean and dirty:
        print('[FAIL] a volume is marked dirty')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
