#!/usr/bin/env python3
import argparse
import hashlib
import struct
from pathlib import Path

VDI_SIGNATURE = 0xBEDA107F
VDI_VERSION_1_1 = 0x00010001
OFF_SIGNATURE = 0x40
OFF_VERSION = 0x44
OFF_CYLINDERS = 0x15C
OFF_HEADS = 0x160
OFF_SECTORS = 0x164
OFF_SECTOR_SIZE = 0x168
OFF_LCHS_CYLINDERS = 0x1C8
OFF_LCHS_HEADS = 0x1CC
OFF_LCHS_SECTORS = 0x1D0
OFF_LCHS_SECTOR_SIZE = 0x1D4


def u32(buf: bytes, off: int) -> int:
    return struct.unpack_from('<I', buf, off)[0]


def main() -> int:
    ap = argparse.ArgumentParser(description='Patch only legacy C/H/S fields in a VDI 1.1 header.')
    ap.add_argument('image', type=Path)
    ap.add_argument('--cylinders', type=int, required=True)
    ap.add_argument('--heads', type=int, required=True)
    ap.add_argument('--sectors', type=int, required=True)
    args = ap.parse_args()

    if not (1 <= args.cylinders <= 0xFFFFFFFF):
        raise SystemExit('invalid cylinders')
    if not (1 <= args.heads <= 255):
        raise SystemExit('invalid heads')
    if not (1 <= args.sectors <= 63):
        raise SystemExit('invalid sectors')

    with args.image.open('r+b') as f:
        header = bytearray(f.read(512))
        if len(header) != 512:
            raise SystemExit('short VDI header')
        if u32(header, OFF_SIGNATURE) != VDI_SIGNATURE:
            raise SystemExit('not a VDI image: bad signature')
        if u32(header, OFF_VERSION) != VDI_VERSION_1_1:
            raise SystemExit('unsupported VDI version')
        if u32(header, OFF_SECTOR_SIZE) != 512:
            raise SystemExit('unsupported VDI sector size')

        before = hashlib.sha256(header).hexdigest().upper()
        original = bytes(header)
        # QEMU emits the old 384-byte VDI 1.1 header. VBox upgrades it on first
        # writable open and clears LCHS unless the extended header is declared.
        header_bytes = u32(header, 0x48)
        if header_bytes not in (384, 400):
            raise SystemExit('unsupported VDI header length')
        if u32(header, 0x154) < 0x1D8:
            raise SystemExit('VDI block map overlaps extended geometry')
        struct.pack_into('<I', header, 0x48, 400)
        struct.pack_into('<I', header, OFF_CYLINDERS, args.cylinders)
        struct.pack_into('<I', header, OFF_HEADS, args.heads)
        struct.pack_into('<I', header, OFF_SECTORS, args.sectors)
        struct.pack_into('<I', header, OFF_LCHS_CYLINDERS, args.cylinders)
        struct.pack_into('<I', header, OFF_LCHS_HEADS, args.heads)
        struct.pack_into('<I', header, OFF_LCHS_SECTORS, args.sectors)
        if u32(header, OFF_LCHS_SECTOR_SIZE) not in (0, 512):
            raise SystemExit('unsupported VDI logical sector size')
        struct.pack_into('<I', header, OFF_LCHS_SECTOR_SIZE, 512)

        changed = [i for i, (a, b) in enumerate(zip(original, header)) if a != b]
        allowed = set(range(0x48, 0x4C)) | set(range(OFF_CYLINDERS, OFF_SECTORS + 4)) | set(range(OFF_LCHS_CYLINDERS, OFF_LCHS_SECTOR_SIZE + 4))
        if any(i not in allowed for i in changed):
            raise SystemExit('internal error: bytes outside geometry fields changed')

        f.seek(0)
        f.write(header)
        f.flush()

    after = hashlib.sha256(header).hexdigest().upper()
    print(f'[PASS] VDI physical+logical geometry patched to {args.cylinders}/{args.heads}/{args.sectors}')
    print(f'[PASS] header_sha256_before={before}')
    print(f'[PASS] header_sha256_after={after}')
    print(f'[PASS] changed_header_bytes={len(changed)} confined_to=header-size and geometry fields')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
