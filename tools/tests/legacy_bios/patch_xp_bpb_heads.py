#!/usr/bin/env python3
import argparse
import hashlib
import os
import struct

SECTOR = 512
XPSETUP_LBA = 2048
BPB_HEADS_OFFSET = 26


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--target-raw', required=True)
    ap.add_argument('--from-heads', type=int, required=True)
    ap.add_argument('--to-heads', type=int, required=True)
    args = ap.parse_args()

    if not (1 <= args.from_heads <= 0xFFFF and 1 <= args.to_heads <= 0xFFFF):
        raise RuntimeError('heads must fit uint16 and be non-zero')
    if args.from_heads == args.to_heads:
        raise RuntimeError('from-heads and to-heads must differ')

    path = os.path.abspath(args.target_raw)
    with open(path, 'r+b', buffering=0) as f:
        mbr_before = f.read(SECTOR)
        if len(mbr_before) != SECTOR or mbr_before[510:512] != b'\x55\xAA':
            raise RuntimeError('invalid MBR')
        p1 = mbr_before[446:462]
        if p1[0] != 0x80 or p1[4] != 0x0C:
            raise RuntimeError(f'XPSETUP P1 mismatch boot=0x{p1[0]:02X} type=0x{p1[4]:02X}')
        start_lba, sectors = struct.unpack_from('<II', p1, 8)
        if start_lba != XPSETUP_LBA:
            raise RuntimeError(f'XPSETUP start mismatch: {start_lba}')

        vbr_offset = start_lba * SECTOR
        f.seek(vbr_offset)
        vbr_before = bytearray(f.read(SECTOR))
        if len(vbr_before) != SECTOR or vbr_before[510:512] != b'\x55\xAA':
            raise RuntimeError('invalid XPSETUP VBR')
        current = struct.unpack_from('<H', vbr_before, BPB_HEADS_OFFSET)[0]
        if current != args.from_heads:
            raise RuntimeError(f'XPSETUP BPB heads mismatch: got={current} want={args.from_heads}')
        spt = struct.unpack_from('<H', vbr_before, 24)[0]
        hidden = struct.unpack_from('<I', vbr_before, 28)[0]
        if spt != 63 or hidden != start_lba:
            raise RuntimeError(f'XPSETUP BPB invariant mismatch: spt={spt} hidden={hidden}')

        patch_offset = vbr_offset + BPB_HEADS_OFFSET
        f.seek(patch_offset)
        f.write(struct.pack('<H', args.to_heads))
        f.flush()
        os.fsync(f.fileno())

        f.seek(0)
        mbr_after = f.read(SECTOR)
        f.seek(vbr_offset)
        vbr_after = bytearray(f.read(SECTOR))

    if mbr_after != mbr_before:
        raise RuntimeError('MBR changed while patching BPB heads')
    diffs = [i for i, (a, b) in enumerate(zip(vbr_before, vbr_after)) if a != b]
    allowed_bytes = {BPB_HEADS_OFFSET, BPB_HEADS_OFFSET + 1}
    if not diffs or any(i not in allowed_bytes for i in diffs):
        raise RuntimeError(f'XPSETUP VBR changed outside BPB heads: diffs={diffs}')
    after_heads = struct.unpack_from('<H', vbr_after, BPB_HEADS_OFFSET)[0]
    if after_heads != args.to_heads:
        raise RuntimeError(f'BPB heads readback mismatch: {after_heads}')

    before_zeroed = bytearray(vbr_before)
    after_zeroed = bytearray(vbr_after)
    before_zeroed[BPB_HEADS_OFFSET:BPB_HEADS_OFFSET + 2] = b'\x00\x00'
    after_zeroed[BPB_HEADS_OFFSET:BPB_HEADS_OFFSET + 2] = b'\x00\x00'
    if before_zeroed != after_zeroed:
        raise RuntimeError('VBR differs outside BPB heads after normalized comparison')

    print(f'[PASS] XPSETUP BPB heads-only patch target={path}')
    print(f'[PASS] MBR unchanged sha256={sha256(mbr_after)}')
    print(f'[PASS] VBR exact diff offsets={diffs} old={args.from_heads} new={args.to_heads}')
    print(f'[PASS] VBR normalized sha256={sha256(bytes(after_zeroed))}')
    print(f'[PASS] XPSETUP start={start_lba} sectors={sectors} spt={spt} hidden={hidden}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
