#!/usr/bin/env python3
import argparse
import hashlib
import os
import struct
from pathlib import Path


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def main() -> int:
    parser = argparse.ArgumentParser(description="Patch guest LBA0 bytes 0..439 inside a dynamic VDI while preserving bytes 440..511.")
    parser.add_argument("--vdi", required=True, type=Path)
    parser.add_argument("--mbr-code", required=True, type=Path)
    parser.add_argument("--map-offset", required=True, type=int)
    parser.add_argument("--data-offset", required=True, type=int)
    parser.add_argument("--block-size", required=True, type=int)
    parser.add_argument("--expected-before-sha256")
    args = parser.parse_args()

    code = args.mbr_code.read_bytes()
    if len(code) != 440:
        raise SystemExit(f"MBR code must be exactly 440 bytes, got {len(code)}")

    with args.vdi.open("r+b", buffering=0) as f:
        f.seek(args.map_offset)
        raw_index = f.read(4)
        if len(raw_index) != 4:
            raise SystemExit("short VDI block-map read")
        block_index = struct.unpack("<I", raw_index)[0]
        if block_index in (0xFFFFFFFF, 0xFFFFFFFE):
            raise SystemExit(f"guest block 0 is not allocated: 0x{block_index:08X}")

        host_offset = args.data_offset + block_index * args.block_size
        f.seek(host_offset)
        before = f.read(512)
        if len(before) != 512:
            raise SystemExit("short guest LBA0 read")
        if before[510:512] != b"\x55\xAA":
            raise SystemExit("guest LBA0 lacks 55AA before patch")

        before_hash = sha256(before[:440])
        if args.expected_before_sha256 and before_hash != args.expected_before_sha256.upper():
            raise SystemExit(
                f"unexpected pre-patch MBR code hash: {before_hash} != {args.expected_before_sha256.upper()}"
            )

        preserved_tail = before[440:512]
        f.seek(host_offset)
        f.write(code)
        f.flush()
        os.fsync(f.fileno())
        f.seek(host_offset)
        after = f.read(512)

    if after[:440] != code:
        raise SystemExit("guest MBR code readback mismatch")
    if after[440:512] != preserved_tail:
        raise SystemExit("guest MBR bytes 440..511 changed")

    print(f"[PASS] vdi_block0_index={block_index}")
    print(f"[PASS] guest_lba0_host_offset={host_offset}")
    print(f"[PASS] mbr_code_sha256_before={before_hash}")
    print(f"[PASS] mbr_code_sha256_after={sha256(after[:440])}")
    print(f"[PASS] mbr_tail_sha256={sha256(after[440:512])}")
    print("[PASS] guest LBA0 bytes 440..511 preserved bit-for-bit; signature=55AA")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
