#!/usr/bin/env python3
import argparse
import hashlib
import os
import struct

SECTOR = 512
VBR_CODE_OFFSET = 90
VBR_CODE_BUDGET = 510 - VBR_CODE_OFFSET
STAGE2_REL_LBA = 8
STAGE2_BYTES = 24 * SECTOR


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def read_exact(f, offset: int, size: int) -> bytes:
    f.seek(offset)
    data = f.read(size)
    if len(data) != size:
        raise RuntimeError(f'short read at {offset}: got {len(data)} want {size}')
    return data


def write_exact(f, offset: int, data: bytes) -> None:
    f.seek(offset)
    written = f.write(data)
    if written != len(data):
        raise RuntimeError(f'short write at {offset}: got {written} want {len(data)}')


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--target-raw', required=True)
    ap.add_argument('--vbr-code', required=True)
    ap.add_argument('--stage2', required=True)
    ap.add_argument('--int13-shim')
    ap.add_argument('--xpsetup-slot', type=int, default=1)
    args = ap.parse_args()

    vbr_code = open(args.vbr_code, 'rb').read()
    stage2 = open(args.stage2, 'rb').read()
    int13_shim = open(args.int13_shim, 'rb').read() if args.int13_shim else None
    if len(vbr_code) > VBR_CODE_BUDGET:
        raise RuntimeError(f'EDD VBR code too large: {len(vbr_code)} > {VBR_CODE_BUDGET}')
    if len(stage2) != STAGE2_BYTES:
        raise RuntimeError(f'EDD stage2 must be exactly {STAGE2_BYTES} bytes, got {len(stage2)}')
    if int13_shim is not None and len(int13_shim) != SECTOR:
        raise RuntimeError(f'INT13 shim fixture must be exactly {SECTOR} bytes, got {len(int13_shim)}')

    with open(args.target_raw, 'r+b', buffering=0) as f:
        mbr = read_exact(f, 0, SECTOR)
        if mbr[510:512] != b'\x55\xaa':
            raise RuntimeError('MBR signature missing')
        entry_off = 446 + (args.xpsetup_slot - 1) * 16
        entry = mbr[entry_off:entry_off + 16]
        if entry[0] != 0x80 or entry[4] != 0x0C:
            raise RuntimeError(f'XPSETUP entry mismatch status=0x{entry[0]:02X} type=0x{entry[4]:02X}')
        start_lba, sectors = struct.unpack_from('<II', entry, 8)
        if start_lba != 2048 or sectors != 4194304:
            raise RuntimeError(f'XPSETUP geometry mismatch start={start_lba} sectors={sectors}')

        vbr_off = start_lba * SECTOR
        vbr = bytearray(read_exact(f, vbr_off, SECTOR))
        original_bpb = bytes(vbr[:VBR_CODE_OFFSET])
        original_sig = bytes(vbr[510:512])
        if original_sig != b'\x55\xaa':
            raise RuntimeError('XPSETUP VBR signature missing')
        if struct.unpack_from('<H', vbr, 11)[0] != 512:
            raise RuntimeError('XPSETUP BPB bytes/sector mismatch')
        if struct.unpack_from('<I', vbr, 28)[0] != start_lba:
            raise RuntimeError('XPSETUP BPB HiddenSectors mismatch')

        if int13_shim is not None:
            # Absolute LBA9 is test-only pre-partition scratch space. The external
            # mismatch prelude reads this sector into 0000:1200 before installing
            # the shim, keeping it alive while the EDD stage2 occupies 8000:AFFF.
            write_exact(f, 9 * SECTOR, int13_shim)

        # Production layout: preserve the real FAT32 BPB/EBPB and signature,
        # zero the executable tail, then place the USOS EDD/LBA VBR code at 7C5A.
        vbr[VBR_CODE_OFFSET:510] = b'\x00' * VBR_CODE_BUDGET
        vbr[VBR_CODE_OFFSET:VBR_CODE_OFFSET + len(vbr_code)] = vbr_code
        write_exact(f, vbr_off, vbr)
        write_exact(f, (start_lba + 6) * SECTOR, vbr)

        # The EDD VBR loads 24 reserved sectors starting at partition-relative 8.
        write_exact(f, (start_lba + STAGE2_REL_LBA) * SECTOR, stage2)
        f.flush()
        os.fsync(f.fileno())

        rb_shim = read_exact(f, 9 * SECTOR, SECTOR) if int13_shim is not None else None
        rb_vbr = read_exact(f, vbr_off, SECTOR)
        rb_backup = read_exact(f, (start_lba + 6) * SECTOR, SECTOR)
        rb_stage2 = read_exact(f, (start_lba + STAGE2_REL_LBA) * SECTOR, STAGE2_BYTES)
        if int13_shim is not None and rb_shim != int13_shim:
            raise RuntimeError('INT13 shim LBA9 readback mismatch')
        if rb_vbr[:VBR_CODE_OFFSET] != original_bpb or rb_vbr[510:512] != original_sig:
            raise RuntimeError('EDD fixture altered BPB/EBPB or 55AA')
        if rb_backup != rb_vbr:
            raise RuntimeError('EDD fixture backup VBR mismatch')
        expected_tail = bytearray(VBR_CODE_BUDGET)
        expected_tail[:len(vbr_code)] = vbr_code
        if rb_vbr[VBR_CODE_OFFSET:510] != bytes(expected_tail):
            raise RuntimeError('EDD VBR code readback mismatch')
        if rb_stage2 != stage2:
            raise RuntimeError('EDD stage2 readback mismatch')

    if int13_shim is not None:
        print(f'[PASS] EDD fixture persistent INT13 shim installed absolute_lba=9 bytes={len(int13_shim)} sha256={sha256(int13_shim)}')
    print(f'[PASS] EDD fixture VBR installed code_bytes={len(vbr_code)} sha256={sha256(vbr_code)} BPB=preserved')
    print(f'[PASS] EDD fixture stage2 installed rel_lba={STAGE2_REL_LBA} bytes={len(stage2)} sha256={sha256(stage2)}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
