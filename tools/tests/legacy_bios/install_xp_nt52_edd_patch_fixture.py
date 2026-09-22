#!/usr/bin/env python3
import argparse
import hashlib
import struct

SECTOR = 512
TAIL_OFFSET_IN_VBR = 90
CHS_BRANCH_OFFSET_IN_TAIL = 0x8C
EXPECTED = bytes.fromhex('0F824A00')
PATCHED = bytes.fromhex('90909090')


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
    n = f.write(data)
    if n != len(data):
        raise RuntimeError(f'short write at {offset}: got {n} want {len(data)}')


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--target-raw', required=True)
    ap.add_argument('--xpsetup-slot', type=int, default=1)
    args = ap.parse_args()
    if args.xpsetup_slot not in (1, 2, 3, 4):
        raise RuntimeError('xpsetup slot must be 1..4')

    with open(args.target_raw, 'r+b', buffering=0) as f:
        mbr = read_exact(f, 0, SECTOR)
        if mbr[510:512] != b'\x55\xAA':
            raise RuntimeError('MBR signature is not 55AA')
        off = 446 + (args.xpsetup_slot - 1) * 16
        entry = mbr[off:off + 16]
        if entry[0] != 0x80 or entry[4] != 0x0C:
            raise RuntimeError(f'XPSETUP entry mismatch status=0x{entry[0]:02X} type=0x{entry[4]:02X}')
        start_lba, sectors = struct.unpack_from('<II', entry, 8)
        if start_lba != 2048 or sectors != 4194304:
            raise RuntimeError(f'XPSETUP geometry mismatch start={start_lba} sectors={sectors}')

        vbr_off = start_lba * SECTOR
        vbr = bytearray(read_exact(f, vbr_off, SECTOR))
        if vbr[510:512] != b'\x55\xAA':
            raise RuntimeError('VBR signature is not 55AA')
        bpb_before = bytes(vbr[:90])
        sig_before = bytes(vbr[510:512])
        patch_off = TAIL_OFFSET_IN_VBR + CHS_BRANCH_OFFSET_IN_TAIL
        actual = bytes(vbr[patch_off:patch_off + 4])
        if actual != EXPECTED:
            raise RuntimeError(
                f'NT52 CHS branch mismatch at VBR+0x{patch_off:03X}: '
                f'got={actual.hex().upper()} want={EXPECTED.hex().upper()}'
            )
        before = bytes(vbr)
        vbr[patch_off:patch_off + 4] = PATCHED
        diffs = [i for i, (a, b) in enumerate(zip(before, vbr)) if a != b]
        expected_diffs = list(range(patch_off, patch_off + 4))
        if diffs != expected_diffs:
            raise RuntimeError(f'unexpected VBR diff offsets: {diffs}')
        write_exact(f, vbr_off, vbr)
        f.flush()

        rb = read_exact(f, vbr_off, SECTOR)
        if rb != bytes(vbr):
            raise RuntimeError('patched VBR readback mismatch')
        if rb[:90] != bpb_before or rb[510:512] != sig_before:
            raise RuntimeError('patched VBR altered BPB or 55AA')

    print(
        f'[PASS] NT52 EDD-only fixture patch VBR+0x{patch_off:03X} '
        f'bytes=4 sha256={sha256(bytes(vbr))} BPB=preserved MBR=untouched'
    )
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
