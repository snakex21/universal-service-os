#!/usr/bin/env python3
from __future__ import annotations

import argparse
import math
import struct
from pathlib import Path

SECTOR = 512
TOTAL_SECTORS = 2880
SECTORS_PER_FAT = 9
ROOT_ENTRIES = 224
ROOT_SECTORS = (ROOT_ENTRIES * 32 + SECTOR - 1) // SECTOR
RESERVED = 1
FATS = 2
DATA_START = RESERVED + FATS * SECTORS_PER_FAT + ROOT_SECTORS


def set_fat12(fat: bytearray, cluster: int, value: int) -> None:
    off = cluster + cluster // 2
    value &= 0xFFF
    if cluster & 1:
        fat[off] = (fat[off] & 0x0F) | ((value << 4) & 0xF0)
        fat[off + 1] = (value >> 4) & 0xFF
    else:
        fat[off] = value & 0xFF
        fat[off + 1] = (fat[off + 1] & 0xF0) | ((value >> 8) & 0x0F)


def main() -> int:
    ap = argparse.ArgumentParser(description="Create a 1.44MB FAT12 floppy containing one 8.3 file.")
    ap.add_argument("--source", required=True, type=Path)
    ap.add_argument("--output", required=True, type=Path)
    ap.add_argument("--name", default="WINNT.SIF")
    args = ap.parse_args()

    data = args.source.read_bytes()
    stem, dot, ext = args.name.upper().partition(".")
    if not dot or len(stem) > 8 or len(ext) > 3:
        raise SystemExit("--name must be 8.3")
    name83 = stem.ljust(8) + ext.ljust(3)

    clusters = max(1, math.ceil(len(data) / SECTOR))
    max_clusters = TOTAL_SECTORS - DATA_START
    if clusters > max_clusters:
        raise SystemExit("file too large for floppy")

    img = bytearray(TOTAL_SECTORS * SECTOR)
    bs = memoryview(img)[:SECTOR]
    bs[0:3] = b"\xEB\x3C\x90"
    bs[3:11] = b"MSDOS5.0"
    struct.pack_into("<H", bs, 11, SECTOR)
    bs[13] = 1
    struct.pack_into("<H", bs, 14, RESERVED)
    bs[16] = FATS
    struct.pack_into("<H", bs, 17, ROOT_ENTRIES)
    struct.pack_into("<H", bs, 19, TOTAL_SECTORS)
    bs[21] = 0xF0
    struct.pack_into("<H", bs, 22, SECTORS_PER_FAT)
    struct.pack_into("<H", bs, 24, 18)
    struct.pack_into("<H", bs, 26, 2)
    struct.pack_into("<I", bs, 28, 0)
    struct.pack_into("<I", bs, 32, 0)
    bs[36] = 0
    bs[37] = 0
    bs[38] = 0x29
    struct.pack_into("<I", bs, 39, 0x58505355)
    bs[43:54] = b"XPCTRL     "
    bs[54:62] = b"FAT12   "
    bs[510:512] = b"\x55\xAA"

    fat = bytearray(SECTORS_PER_FAT * SECTOR)
    fat[0:3] = b"\xF0\xFF\xFF"
    for i in range(clusters):
        c = 2 + i
        nxt = 0xFFF if i == clusters - 1 else c + 1
        set_fat12(fat, c, nxt)
    fat1 = RESERVED * SECTOR
    fat2 = fat1 + SECTORS_PER_FAT * SECTOR
    img[fat1:fat1 + len(fat)] = fat
    img[fat2:fat2 + len(fat)] = fat

    root_off = (RESERVED + FATS * SECTORS_PER_FAT) * SECTOR
    entry = memoryview(img)[root_off:root_off + 32]
    entry[0:11] = name83.encode("ascii")
    entry[11] = 0x20
    struct.pack_into("<H", entry, 26, 2)
    struct.pack_into("<I", entry, 28, len(data))

    data_off = DATA_START * SECTOR
    img[data_off:data_off + len(data)] = data

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(img)
    print(f"[PASS] FAT12 floppy: {args.output} file={args.name.upper()} size={len(data)} clusters={clusters}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
