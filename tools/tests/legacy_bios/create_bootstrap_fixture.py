#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path
import shutil
import struct
import subprocess
import uuid
import zlib

SECTOR = 512
DISK_BYTES = 64 * 1024 * 1024
TOTAL_LBAS = DISK_BYTES // SECTOR
GPT_ENTRY_COUNT = 128
GPT_ENTRY_SIZE = 128
GPT_ENTRIES_BYTES = GPT_ENTRY_COUNT * GPT_ENTRY_SIZE
GPT_ENTRIES_SECTORS = GPT_ENTRIES_BYTES // SECTOR
CORE_LBA = 64
CORE_SLOT_SECTORS = 512
CORE_SLOT_BYTES = CORE_SLOT_SECTORS * SECTOR
ESP_START = 2048
ESP_END = 4095
DATA_START = 4096
DATA_END = 8191
WORK_START = 8192
WORK_END = 12287

EFI_SYSTEM = uuid.UUID("c12a7328-f81f-11d2-ba4b-00a0c93ec93b")
BASIC_DATA = uuid.UUID("ebd0a0a2-b9e5-4433-87c0-68b6b72699c7")
DISK_GUID = uuid.UUID("f8a11f13-0877-4895-b8b2-72d4334a4201")
ESP_GUID = uuid.UUID("155e0dcc-956d-44df-b330-c3363951f201")
DATA_GUID = uuid.UUID("6a1803ad-f644-4a30-a17b-a94e26ea9201")
WORK_GUID = uuid.UUID("d1cf9bde-c6ea-4fa4-a518-3b206dccb201")


def run(args: list[str]) -> None:
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode != 0:
        raise RuntimeError(f"command failed ({result.returncode}): {' '.join(args)}\n{result.stdout}")


def partition_entry(type_guid: uuid.UUID, part_guid: uuid.UUID, start: int, end: int, name: str) -> bytes:
    entry = bytearray(GPT_ENTRY_SIZE)
    entry[0:16] = type_guid.bytes_le
    entry[16:32] = part_guid.bytes_le
    struct.pack_into("<QQQ", entry, 32, start, end, 0)
    encoded_name = name.encode("utf-16le")
    if len(encoded_name) > 72:
        raise ValueError(f"GPT name too long: {name}")
    entry[56:56 + len(encoded_name)] = encoded_name
    return bytes(entry)


def gpt_header(current_lba: int, backup_lba: int, entries_lba: int, entries_crc: int) -> bytes:
    header = bytearray(SECTOR)
    header[0:8] = b"EFI PART"
    struct.pack_into("<I", header, 8, 0x00010000)
    struct.pack_into("<I", header, 12, 92)
    struct.pack_into("<Q", header, 24, current_lba)
    struct.pack_into("<Q", header, 32, backup_lba)
    struct.pack_into("<Q", header, 40, 34)
    struct.pack_into("<Q", header, 48, TOTAL_LBAS - 34)
    header[56:72] = DISK_GUID.bytes_le
    struct.pack_into("<Q", header, 72, entries_lba)
    struct.pack_into("<I", header, 80, GPT_ENTRY_COUNT)
    struct.pack_into("<I", header, 84, GPT_ENTRY_SIZE)
    struct.pack_into("<I", header, 88, entries_crc)
    struct.pack_into("<I", header, 16, zlib.crc32(header[:92]) & 0xFFFFFFFF)
    return bytes(header)


def protective_mbr(stage1: bytes) -> bytes:
    if len(stage1) != 440:
        raise ValueError(f"Stage 1 must be exactly 440 bytes, got {len(stage1)}")
    sector = bytearray(SECTOR)
    sector[:440] = stage1
    entry = 446
    sector[entry + 4] = 0xEE
    struct.pack_into("<I", sector, entry + 8, 1)
    struct.pack_into("<I", sector, entry + 12, min(TOTAL_LBAS - 1, 0xFFFFFFFF))
    sector[510:512] = b"\x55\xAA"
    return bytes(sector)


def mutate_slot(slot: bytes, mode: str) -> bytes:
    data = bytearray(slot)
    if mode == "none":
        return bytes(data)
    if mode == "version":
        # Keep the header CRC internally consistent: this tests explicit format
        # rejection, not accidental CRC rejection.
        struct.pack_into("<H", data, 8, 2)
        struct.pack_into("<I", data, 44, zlib.crc32(data[:44]) & 0xFFFFFFFF)
        return bytes(data)
    if mode == "content-crc":
        image_size = struct.unpack_from("<I", data, 20)[0]
        if image_size <= 64:
            raise ValueError("invalid image_size for content corruption")
        data[image_size - 1] ^= 0x5A
        return bytes(data)
    raise ValueError(f"unknown mutation mode: {mode}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--qemu-img", type=Path, required=True)
    parser.add_argument("--stage1", type=Path, required=True)
    parser.add_argument("--core-slot", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mutate", choices=("none", "version", "content-crc"), default="none")
    args = parser.parse_args()

    stage1 = args.stage1.read_bytes()
    core_slot = mutate_slot(args.core_slot.read_bytes(), args.mutate)
    if len(core_slot) != CORE_SLOT_BYTES:
        raise ValueError(f"Core slot must be {CORE_SLOT_BYTES} bytes, got {len(core_slot)}")
    if CORE_LBA < 34 or CORE_LBA + CORE_SLOT_SECTORS > ESP_START:
        raise ValueError("Core slot overlaps GPT metadata or ESP")

    entries = bytearray(GPT_ENTRIES_BYTES)
    parts = (
        partition_entry(EFI_SYSTEM, ESP_GUID, ESP_START, ESP_END, "USOS_ESP"),
        partition_entry(BASIC_DATA, DATA_GUID, DATA_START, DATA_END, "USOS_DATA"),
        partition_entry(BASIC_DATA, WORK_GUID, WORK_START, WORK_END, "USOS_WORK"),
    )
    for index, part in enumerate(parts):
        start = index * GPT_ENTRY_SIZE
        entries[start:start + GPT_ENTRY_SIZE] = part
    entries_crc = zlib.crc32(entries) & 0xFFFFFFFF

    backup_header_lba = TOTAL_LBAS - 1
    backup_entries_lba = backup_header_lba - GPT_ENTRIES_SECTORS
    primary_header = gpt_header(1, backup_header_lba, 2, entries_crc)
    backup_header = gpt_header(backup_header_lba, 1, backup_entries_lba, entries_crc)
    mbr = protective_mbr(stage1)

    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        output.unlink()
    staging = output.parent / f"bootstrap-fixture-{args.mutate}"
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    raw_layout = staging / "legacy-layout.tmp"

    try:
        with raw_layout.open("w+b") as handle:
            handle.truncate(DISK_BYTES)
            handle.seek(0)
            handle.write(mbr)
            handle.seek(SECTOR)
            handle.write(primary_header)
            handle.seek(2 * SECTOR)
            handle.write(entries)
            handle.seek(CORE_LBA * SECTOR)
            handle.write(core_slot)
            handle.seek(backup_entries_lba * SECTOR)
            handle.write(entries)
            handle.seek(backup_header_lba * SECTOR)
            handle.write(backup_header)
            handle.flush()
        run([str(args.qemu_img.resolve()), "convert", "-f", "raw", "-O", "qcow2", str(raw_layout), str(output)])
        run([str(args.qemu_img.resolve()), "check", str(output)])
    finally:
        shutil.rmtree(staging, ignore_errors=True)

    print(f"[PASS] bootstrap fixture={output}")
    print(f"[PASS] Core slot LBA={CORE_LBA}..{CORE_LBA + CORE_SLOT_SECTORS - 1} bytes={CORE_SLOT_BYTES}")
    print(f"[PASS] ESP starts at LBA={ESP_START}; all GPT partition attributes are zero")
    print(f"[PASS] mutation={args.mutate}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
