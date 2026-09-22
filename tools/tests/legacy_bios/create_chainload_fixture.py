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
CORE_BYTES = 32 * SECTOR
ESP_START = 2048
ESP_END = 4095
TEST_START = 4096
TEST_END = 8191
WORK_START = 8192
WORK_END = 12287
LEGACY_BOOTABLE = 0x4

EFI_SYSTEM = uuid.UUID("c12a7328-f81f-11d2-ba4b-00a0c93ec93b")
BASIC_DATA = uuid.UUID("ebd0a0a2-b9e5-4433-87c0-68b6b72699c7")
DISK_GUID = uuid.UUID("3f7ba87b-7f9b-455b-aad5-ec0ee5d8cb01")
ESP_GUID = uuid.UUID("38fa91d0-e89e-4761-9f21-1c6977763301")
TEST_GUID = uuid.UUID("455a06aa-38cb-41a8-855f-b5cc2b327101")
WORK_GUID = uuid.UUID("072b9176-8f4c-458f-8411-eb9aed9a4b01")


def run(args: list[str]) -> None:
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode != 0:
        raise RuntimeError(f"command failed ({result.returncode}): {' '.join(args)}\n{result.stdout}")


def partition_entry(type_guid: uuid.UUID, part_guid: uuid.UUID, start: int, end: int, attrs: int, name: str) -> bytes:
    if start > end:
        raise ValueError("invalid partition range")
    encoded_name = name.encode("utf-16le")
    if len(encoded_name) > 72:
        raise ValueError(f"GPT name too long: {name}")
    entry = bytearray(GPT_ENTRY_SIZE)
    entry[0:16] = type_guid.bytes_le
    entry[16:32] = part_guid.bytes_le
    struct.pack_into("<QQQ", entry, 32, start, end, attrs)
    entry[56:56 + len(encoded_name)] = encoded_name
    return bytes(entry)


def gpt_header(current_lba: int, backup_lba: int, entries_lba: int, entries_crc: int) -> bytes:
    header = bytearray(SECTOR)
    header[0:8] = b"EFI PART"
    struct.pack_into("<I", header, 8, 0x00010000)
    struct.pack_into("<I", header, 12, 92)
    struct.pack_into("<I", header, 16, 0)
    struct.pack_into("<I", header, 20, 0)
    struct.pack_into("<Q", header, 24, current_lba)
    struct.pack_into("<Q", header, 32, backup_lba)
    struct.pack_into("<Q", header, 40, 34)
    struct.pack_into("<Q", header, 48, TOTAL_LBAS - 34)
    header[56:72] = DISK_GUID.bytes_le
    struct.pack_into("<Q", header, 72, entries_lba)
    struct.pack_into("<I", header, 80, GPT_ENTRY_COUNT)
    struct.pack_into("<I", header, 84, GPT_ENTRY_SIZE)
    struct.pack_into("<I", header, 88, entries_crc)
    crc = zlib.crc32(header[:92]) & 0xFFFFFFFF
    struct.pack_into("<I", header, 16, crc)
    return bytes(header)


def protective_mbr(stage1: bytes) -> bytes:
    if len(stage1) != 440:
        raise ValueError(f"Stage 1 must be exactly 440 bytes, got {len(stage1)}")
    sector = bytearray(SECTOR)
    sector[0:440] = stage1
    entry = 446
    sector[entry + 0] = 0x00
    sector[entry + 1:entry + 4] = bytes((0x00, 0x02, 0x00))
    sector[entry + 4] = 0xEE
    sector[entry + 5:entry + 8] = bytes((0xFF, 0xFF, 0xFF))
    struct.pack_into("<I", sector, entry + 8, 1)
    struct.pack_into("<I", sector, entry + 12, min(TOTAL_LBAS - 1, 0xFFFFFFFF))
    sector[510:512] = b"\x55\xAA"
    return bytes(sector)


def write_at(handle, offset: int, data: bytes) -> None:
    handle.seek(offset)
    handle.write(data)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--qemu-img", type=Path, required=True)
    parser.add_argument("--stage1", type=Path, required=True)
    parser.add_argument("--core", type=Path, required=True)
    parser.add_argument("--vbr", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    qemu_img = args.qemu_img.resolve()
    stage1 = args.stage1.read_bytes()
    core = args.core.read_bytes()
    vbr = args.vbr.read_bytes()
    output = args.output.resolve()

    if len(core) != CORE_BYTES:
        raise ValueError(f"padded Core must be {CORE_BYTES} bytes, got {len(core)}")
    if len(vbr) != SECTOR or vbr[510:512] != b"\x55\xAA":
        raise ValueError("test VBR must be one signed 512-byte sector")

    entries = bytearray(GPT_ENTRIES_BYTES)
    parts = (
        partition_entry(EFI_SYSTEM, ESP_GUID, ESP_START, ESP_END, 0, "USOS_ESP"),
        partition_entry(BASIC_DATA, TEST_GUID, TEST_START, TEST_END, LEGACY_BOOTABLE, "USOS_TEST_CHAIN"),
        partition_entry(BASIC_DATA, WORK_GUID, WORK_START, WORK_END, 0, "USOS_WORK"),
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

    if CORE_LBA < 34 or CORE_LBA + (CORE_BYTES // SECTOR) >= ESP_START:
        raise ValueError("Legacy Core overlaps GPT metadata or ESP")

    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        output.unlink()
    staging = output.parent / "fixture-staging"
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    raw_layout = staging / "legacy-layout.tmp"

    try:
        with raw_layout.open("w+b") as handle:
            handle.truncate(DISK_BYTES)
            write_at(handle, 0, mbr)
            write_at(handle, SECTOR, primary_header)
            write_at(handle, 2 * SECTOR, bytes(entries))
            write_at(handle, CORE_LBA * SECTOR, core)
            write_at(handle, TEST_START * SECTOR, vbr)
            write_at(handle, backup_entries_lba * SECTOR, bytes(entries))
            write_at(handle, backup_header_lba * SECTOR, backup_header)
            handle.flush()

        run([str(qemu_img), "convert", "-f", "raw", "-O", "qcow2", str(raw_layout), str(output)])
        run([str(qemu_img), "check", str(output)])
    finally:
        shutil.rmtree(staging, ignore_errors=True)

    if mbr[446 + 4] != 0xEE or mbr[510:512] != b"\x55\xAA":
        raise AssertionError("protective MBR invariant failed")
    print(f"[PASS] qcow2 fixture={output}")
    print("[PASS] QEMU test medium is qcow2; temporary raw layout removed before boot")
    print("[PASS] protective MBR type=0xEE signature=55AA stage1_bytes=440")
    print(f"[PASS] Core LBA={CORE_LBA} sectors={CORE_BYTES // SECTOR} before ESP LBA={ESP_START}")
    print(f"[PASS] test GPT partition=2 start_lba={TEST_START} attrs=0x{LEGACY_BOOTABLE:X}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
