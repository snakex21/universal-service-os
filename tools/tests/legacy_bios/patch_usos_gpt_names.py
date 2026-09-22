#!/usr/bin/env python3
import argparse
import mmap
import struct
import zlib
from pathlib import Path

SECTOR = 512
ESP_TYPE = bytes.fromhex('28732ac11ff8d211ba4b00a0c93ec93b')
BASIC_TYPE = bytes.fromhex('a2a0d0ebe5b9334487c068b6b72699c7')


def u32(buf, off):
    return struct.unpack_from('<I', buf, off)[0]


def u64(buf, off):
    return struct.unpack_from('<Q', buf, off)[0]


def patch_header_crc(buf, off):
    size = u32(buf, off + 12)
    if size < 92 or size > SECTOR:
        raise RuntimeError('invalid GPT header size')
    struct.pack_into('<I', buf, off + 16, 0)
    crc = zlib.crc32(buf[off:off + size]) & 0xffffffff
    struct.pack_into('<I', buf, off + 16, crc)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--image', required=True)
    args = parser.parse_args()
    image = Path(args.image)
    with image.open('r+b', buffering=0) as f:
        mm = mmap.mmap(f.fileno(), 0)
        try:
            primary = SECTOR
            if mm[primary:primary + 8] != b'EFI PART':
                raise RuntimeError('primary GPT header missing')
            entries_lba = u64(mm, primary + 72)
            count = u32(mm, primary + 80)
            entry_size = u32(mm, primary + 84)
            if entry_size != 128 or count == 0 or count > 128:
                raise RuntimeError('unsupported GPT layout')
            array_off = entries_lba * SECTOR
            esp = []
            basic = []
            for i in range(count):
                off = array_off + i * entry_size
                typ = bytes(mm[off:off + 16])
                if typ == ESP_TYPE:
                    esp.append(i)
                elif typ == BASIC_TYPE:
                    basic.append(i)
            if len(esp) != 1 or len(basic) != 1:
                raise RuntimeError(f'expected one ESP and one Basic Data partition, got ESP={len(esp)} DATA={len(basic)}')

            names = {esp[0]: 'USOS_ESP', basic[0]: 'USOS_DATA'}
            entries_bytes = count * entry_size
            for index, name in names.items():
                off = array_off + index * entry_size
                encoded = name.encode('utf-16le')
                mm[off + 56:off + 128] = encoded + b'\0' * (72 - len(encoded))
            entries_crc = zlib.crc32(mm[array_off:array_off + entries_bytes]) & 0xffffffff
            struct.pack_into('<I', mm, primary + 88, entries_crc)
            patch_header_crc(mm, primary)

            backup = u64(mm, primary + 32) * SECTOR
            if mm[backup:backup + 8] != b'EFI PART':
                raise RuntimeError('backup GPT header missing')
            backup_entries = u64(mm, backup + 72) * SECTOR
            for index, name in names.items():
                off = backup_entries + index * entry_size
                encoded = name.encode('utf-16le')
                mm[off + 56:off + 128] = encoded + b'\0' * (72 - len(encoded))
            backup_crc = zlib.crc32(mm[backup_entries:backup_entries + entries_bytes]) & 0xffffffff
            struct.pack_into('<I', mm, backup + 88, backup_crc)
            patch_header_crc(mm, backup)
            mm.flush()
            print(f'[PASS] GPT names patched: ESP entry={esp[0] + 1} USOS_ESP; DATA entry={basic[0] + 1} USOS_DATA')
        finally:
            mm.close()


if __name__ == '__main__':
    main()
