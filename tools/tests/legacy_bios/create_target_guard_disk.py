#!/usr/bin/env python3
"""Create sparse MBR disks for XP target-guard tests."""

from __future__ import annotations

import argparse
from pathlib import Path

SECTOR = 512
SIZE = 4 * 1024 * 1024 * 1024
P1_START = 2048
P1_SECTORS = 1024 * 1024  # 512 MiB
DISK_ID = 0x4F534F53


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mode", choices=("existing-mbr",), default="existing-mbr")
    args = parser.parse_args()

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("wb") as stream:
        stream.truncate(SIZE)
        mbr = bytearray(SECTOR)
        mbr[440:444] = DISK_ID.to_bytes(4, "little")
        entry = 446
        mbr[entry + 0] = 0x00
        mbr[entry + 1 : entry + 4] = bytes((0xFE, 0xFF, 0xFF))
        mbr[entry + 4] = 0x07
        mbr[entry + 5 : entry + 8] = bytes((0xFE, 0xFF, 0xFF))
        mbr[entry + 8 : entry + 12] = P1_START.to_bytes(4, "little")
        mbr[entry + 12 : entry + 16] = P1_SECTORS.to_bytes(4, "little")
        mbr[510:512] = b"\x55\xAA"
        stream.seek(0)
        stream.write(mbr)

    print(
        f"[PASS] target guard raw disk mode={args.mode} path={args.output} "
        f"bytes={SIZE} p1={P1_START}+{P1_SECTORS} disk_id=0x{DISK_ID:08x}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
