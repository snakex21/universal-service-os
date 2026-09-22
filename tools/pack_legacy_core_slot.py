#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path
import struct
import zlib

MAGIC = b"USOSCORE"
FORMAT_VERSION = 1
HEADER_BYTES = 64
SLOT_BYTES = 256 * 1024
BOOTSTRAP_BYTES = 16 * 1024
PAYLOAD_OFFSET = BOOTSTRAP_BYTES
LOAD_ADDRESS = 0x00020000
ENTRY_OFFSET = 0
HEADER_CRC_OFFSET = 44
RESERVED_OFFSET = 48


def build_slot(bootstrap: bytes, payload: bytes) -> tuple[bytes, dict[str, int]]:
    if len(bootstrap) < HEADER_BYTES:
        raise ValueError(f"bootstrap is shorter than fixed header: {len(bootstrap)}")
    if len(bootstrap) > BOOTSTRAP_BYTES:
        raise ValueError(f"bootstrap is {len(bootstrap)} bytes; maximum is {BOOTSTRAP_BYTES}")
    if any(bootstrap[:HEADER_BYTES]):
        raise ValueError("bootstrap header placeholder must be 64 zero bytes before packing")
    if not payload:
        raise ValueError("Core payload is empty")
    if len(payload) > SLOT_BYTES - PAYLOAD_OFFSET:
        raise ValueError(
            f"Core payload is {len(payload)} bytes; maximum is {SLOT_BYTES - PAYLOAD_OFFSET}"
        )

    image_size = PAYLOAD_OFFSET + len(payload)
    slot = bytearray(SLOT_BYTES)
    slot[: len(bootstrap)] = bootstrap
    slot[PAYLOAD_OFFSET:image_size] = payload

    # Content integrity intentionally covers the complete executable area after
    # the fixed header: bootstrap code + bootstrap zero padding + 32-bit Core.
    content_crc = zlib.crc32(slot[HEADER_BYTES:image_size]) & 0xFFFFFFFF

    header = bytearray(HEADER_BYTES)
    header[0:8] = MAGIC
    struct.pack_into("<HH", header, 8, FORMAT_VERSION, HEADER_BYTES)
    struct.pack_into("<IIIIIII", header, 12,
                     SLOT_BYTES,
                     BOOTSTRAP_BYTES,
                     image_size,
                     PAYLOAD_OFFSET,
                     len(payload),
                     LOAD_ADDRESS,
                     ENTRY_OFFSET)
    struct.pack_into("<I", header, 40, content_crc)
    header_crc = zlib.crc32(header[:HEADER_CRC_OFFSET]) & 0xFFFFFFFF
    struct.pack_into("<I", header, HEADER_CRC_OFFSET, header_crc)
    if any(header[RESERVED_OFFSET:]):
        raise AssertionError("reserved header bytes must be zero")

    slot[:HEADER_BYTES] = header
    return bytes(slot), {
        "format_version": FORMAT_VERSION,
        "slot_bytes": SLOT_BYTES,
        "bootstrap_bytes": BOOTSTRAP_BYTES,
        "image_size": image_size,
        "payload_offset": PAYLOAD_OFFSET,
        "payload_size": len(payload),
        "load_address": LOAD_ADDRESS,
        "entry_offset": ENTRY_OFFSET,
        "content_crc32": content_crc,
        "header_crc32": header_crc,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bootstrap", type=Path, required=True)
    parser.add_argument("--core", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    bootstrap = args.bootstrap.read_bytes()
    payload = args.core.read_bytes()
    slot, meta = build_slot(bootstrap, payload)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(slot)

    print(
        "[PASS] Legacy Core slot "
        f"format=v{meta['format_version']} slot={meta['slot_bytes']} "
        f"bootstrap={meta['bootstrap_bytes']} payload={meta['payload_size']} "
        f"image={meta['image_size']}"
    )
    print(f"[PASS] Core header CRC32={meta['header_crc32']:08X}")
    print(f"[PASS] Core content CRC32={meta['content_crc32']:08X}")
    print(f"[PASS] Core slot output={args.output.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
