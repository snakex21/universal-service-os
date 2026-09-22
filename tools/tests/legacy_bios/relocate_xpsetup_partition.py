#!/usr/bin/env python3
import argparse
import hashlib
import os
import struct

SECTOR = 512
ENTRY0 = 446


def read_exact(f, off: int, size: int) -> bytes:
    f.seek(off)
    data = f.read(size)
    if len(data) != size:
        raise RuntimeError(f'short read off={off} got={len(data)} want={size}')
    return data


def write_exact(f, off: int, data: bytes) -> None:
    f.seek(off)
    n = f.write(data)
    if n != len(data):
        raise RuntimeError(f'short write off={off} got={n} want={len(data)}')


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--target-raw', required=True)
    ap.add_argument('--new-start-lba', type=int, required=True)
    ap.add_argument('--chunk-mib', type=int, default=16)
    args = ap.parse_args()

    if args.new_start_lba <= 0:
        raise RuntimeError('new start LBA must be positive')
    chunk = args.chunk_mib * 1024 * 1024
    if chunk <= 0:
        raise RuntimeError('chunk size must be positive')

    with open(args.target_raw, 'r+b', buffering=0) as f:
        mbr = bytearray(read_exact(f, 0, SECTOR))
        if mbr[510:512] != b'\x55\xAA':
            raise RuntimeError('invalid MBR signature')
        if mbr[ENTRY0] != 0x80 or mbr[ENTRY0 + 4] != 0x0C:
            raise RuntimeError('partition 1 is not active FAT32 LBA XPSETUP')
        old_start, sectors = struct.unpack_from('<II', mbr, ENTRY0 + 8)
        if old_start != 2048 or sectors != 4194304:
            raise RuntimeError(f'unexpected XPSETUP layout start={old_start} sectors={sectors}')
        if args.new_start_lba == old_start:
            raise RuntimeError('new start equals old start')

        old_vbr = bytearray(read_exact(f, old_start * SECTOR, SECTOR))
        if old_vbr[510:512] != b'\x55\xAA':
            raise RuntimeError('invalid XPSETUP VBR signature')
        if struct.unpack_from('<H', old_vbr, 24)[0] != 63:
            raise RuntimeError('unexpected XPSETUP sectors/track')
        if struct.unpack_from('<H', old_vbr, 26)[0] != 255:
            raise RuntimeError('strategy A requires unchanged BPB heads=255')
        if struct.unpack_from('<I', old_vbr, 28)[0] != old_start:
            raise RuntimeError('unexpected XPSETUP HiddenSectors before relocation')
        backup_boot = struct.unpack_from('<H', old_vbr, 50)[0]

        src_off = old_start * SECTOR
        dst_off = args.new_start_lba * SECTOR
        total = sectors * SECTOR
        if not (dst_off >= src_off + total or src_off >= dst_off + total):
            raise RuntimeError('source and destination partition ranges overlap')
        if dst_off + total > os.fstat(f.fileno()).st_size:
            raise RuntimeError('relocated partition would exceed image size')

        copied = 0
        while copied < total:
            take = min(chunk, total - copied)
            data = read_exact(f, src_off + copied, take)
            write_exact(f, dst_off + copied, data)
            copied += take

        # Relocation metadata only: partition-table start LBA/CHS and FAT32 HiddenSectors.
        mbr[ENTRY0 + 1:ENTRY0 + 4] = b'\xFE\xFF\xFF'
        mbr[ENTRY0 + 5:ENTRY0 + 8] = b'\xFE\xFF\xFF'
        struct.pack_into('<I', mbr, ENTRY0 + 8, args.new_start_lba)
        write_exact(f, 0, mbr)

        vbr = bytearray(read_exact(f, dst_off, SECTOR))
        struct.pack_into('<I', vbr, 28, args.new_start_lba)
        write_exact(f, dst_off, vbr)

        if backup_boot not in (0, 0xFFFF):
            backup_off = dst_off + backup_boot * SECTOR
            backup = bytearray(read_exact(f, backup_off, SECTOR))
            if backup[510:512] == b'\x55\xAA':
                struct.pack_into('<I', backup, 28, args.new_start_lba)
                write_exact(f, backup_off, backup)

        f.flush()
        os.fsync(f.fileno())

        verify_mbr = read_exact(f, 0, SECTOR)
        verify_vbr = read_exact(f, dst_off, SECTOR)
        if struct.unpack_from('<I', verify_mbr, ENTRY0 + 8)[0] != args.new_start_lba:
            raise RuntimeError('partition-table start LBA readback mismatch')
        if struct.unpack_from('<I', verify_vbr, 28)[0] != args.new_start_lba:
            raise RuntimeError('VBR HiddenSectors readback mismatch')
        if struct.unpack_from('<H', verify_vbr, 26)[0] != 255:
            raise RuntimeError('strategy A accidentally changed BPB heads')
        if struct.unpack_from('<H', verify_vbr, 24)[0] != 63:
            raise RuntimeError('strategy A accidentally changed BPB sectors/track')

    print(f'[PASS] XPSETUP relocated old_lba={old_start} new_lba={args.new_start_lba} sectors={sectors}')
    print('[PASS] BPB heads remains 255; sectors/track remains 63')
    print(f'[PASS] primary HiddenSectors={args.new_start_lba}; backup_boot_sector={backup_boot}')
    print(f'[PASS] relocated VBR sha256={sha256(verify_vbr)}')
    print('[NOTE] destination overlaps the disposable clone NTFS region; fixture is for NT52 boot-path proof only')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
