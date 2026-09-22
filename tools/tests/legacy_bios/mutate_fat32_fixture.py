#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path
import shutil
import struct
import zlib

SECTOR = 512
ESP_TYPE = bytes.fromhex("28732ac11ff8d211ba4b00a0c93ec93b")
GPT_NAME = "USOS_ESP".encode("utf-16le")
MENU_PREFIX = b"[USOS]\r\nmarker=USOS FAT32 FIXTURE"


def u16(data: bytearray, off: int) -> int:
    return struct.unpack_from("<H", data, off)[0]


def u32(data: bytearray, off: int) -> int:
    return struct.unpack_from("<I", data, off)[0]


def u64(data: bytearray, off: int) -> int:
    return struct.unpack_from("<Q", data, off)[0]


def patch_header_crc(data: bytearray, header_off: int) -> None:
    size = u32(data, header_off + 12)
    if size < 92 or size > SECTOR:
        raise ValueError("invalid GPT header size")
    struct.pack_into("<I", data, header_off + 16, 0)
    crc = zlib.crc32(data[header_off:header_off + size]) & 0xFFFFFFFF
    struct.pack_into("<I", data, header_off + 16, crc)


def patch_gpt_name(data: bytearray) -> tuple[int, int]:
    if data[SECTOR:SECTOR + 8] != b"EFI PART":
        raise ValueError("primary GPT header missing")
    primary = SECTOR
    entries_lba = u64(data, primary + 72)
    count = u32(data, primary + 80)
    entry_size = u32(data, primary + 84)
    if entry_size != 128 or count == 0 or count > 128:
        raise ValueError("unsupported GPT entry layout")
    array_off = entries_lba * SECTOR
    match = None
    for index in range(count):
        off = array_off + index * entry_size
        if data[off:off + 16] == ESP_TYPE:
            if match is not None:
                raise ValueError("more than one ESP in fixture")
            match = index
    if match is None:
        raise ValueError("ESP not found in GPT")

    name = GPT_NAME + b"\0" * (72 - len(GPT_NAME))
    primary_entry = array_off + match * entry_size
    data[primary_entry + 56:primary_entry + 128] = name
    entries_bytes = count * entry_size
    entries_crc = zlib.crc32(data[array_off:array_off + entries_bytes]) & 0xFFFFFFFF
    struct.pack_into("<I", data, primary + 88, entries_crc)
    patch_header_crc(data, primary)

    backup_lba = u64(data, primary + 32)
    backup = backup_lba * SECTOR
    if data[backup:backup + 8] != b"EFI PART":
        raise ValueError("backup GPT header missing")
    backup_entries_lba = u64(data, backup + 72)
    backup_array = backup_entries_lba * SECTOR
    backup_entry = backup_array + match * entry_size
    data[backup_entry + 56:backup_entry + 128] = name
    backup_crc = zlib.crc32(data[backup_array:backup_array + entries_bytes]) & 0xFFFFFFFF
    struct.pack_into("<I", data, backup + 88, backup_crc)
    patch_header_crc(data, backup)

    start = u64(data, primary_entry + 32)
    end = u64(data, primary_entry + 40)
    return start, end


def locate_menu(data: bytearray, part_start_lba: int, part_end_lba: int) -> tuple[int, int, int, int, int, int]:
    part_start = part_start_lba * SECTOR
    part_bytes = (part_end_lba - part_start_lba + 1) * SECTOR
    boot = part_start
    bps = u16(data, boot + 11)
    spc = data[boot + 13]
    reserved = u16(data, boot + 14)
    fats = data[boot + 16]
    fatsz = u32(data, boot + 36)
    total = u32(data, boot + 32)
    first_data_sector = reserved + fats * fatsz
    cluster_count = (total - first_data_sector) // spc
    cluster_bytes = spc * bps
    data_start = part_start + first_data_sector * bps
    part_end = part_start + part_bytes
    marker = data.find(MENU_PREFIX, data_start, part_end)
    if marker < 0:
        raise ValueError("menu marker not found in FAT32 data area")
    relative = marker - data_start
    cluster = relative // cluster_bytes + 2
    cluster_start = data_start + (cluster - 2) * cluster_bytes
    if marker - cluster_start > 128:
        raise ValueError("menu prefix unexpectedly far from first cluster start")

    dir_entry = None
    for off in range(data_start, part_end - 32, 32):
        attr = data[off + 11]
        if data[off] in (0x00, 0xE5) or attr == 0x0F:
            continue
        entry_cluster = (u16(data, off + 20) << 16) | u16(data, off + 26)
        size = u32(data, off + 28)
        if entry_cluster == cluster and size > cluster_bytes:
            dir_entry = off
            menu_size = size
            break
    if dir_entry is None:
        raise ValueError(f"directory entry for menu first cluster {cluster} not found")
    return part_start, cluster, dir_entry, menu_size, cluster_count, cluster_bytes


def mutate(data: bytearray, mode: str, part_start_lba: int, part_end_lba: int) -> None:
    if mode == "valid":
        return
    part_start, cluster, entry_off, menu_size, cluster_count, cluster_bytes = locate_menu(data, part_start_lba, part_end_lba)
    if menu_size <= cluster_bytes:
        raise ValueError("menu fixture must span more than one cluster for chain tests")
    boot = part_start
    reserved = u16(data, boot + 14)
    fats = data[boot + 16]
    fatsz = u32(data, boot + 36)
    if mode == "bad-bpb":
        struct.pack_into("<H", data, boot + 11, 1024)
        return
    if mode in ("broken-chain", "loop"):
        value = 0 if mode == "broken-chain" else cluster
        for fat_index in range(fats):
            fat_off = part_start + (reserved + fat_index * fatsz) * SECTOR + cluster * 4
            old = u32(data, fat_off)
            struct.pack_into("<I", data, fat_off, (old & 0xF0000000) | value)
        return
    if mode == "outside-file":
        invalid = cluster_count + 100
        struct.pack_into("<H", data, entry_off + 20, (invalid >> 16) & 0xFFFF)
        struct.pack_into("<H", data, entry_off + 26, invalid & 0xFFFF)
        return
    raise ValueError(f"unknown mutation mode: {mode}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mode", choices=("valid", "bad-bpb", "broken-chain", "outside-file", "loop"), required=True)
    args = parser.parse_args()

    data = bytearray(args.source.read_bytes())
    if len(data) % SECTOR:
        raise ValueError("raw image size is not sector aligned")
    start, end = patch_gpt_name(data)
    mutate(data, args.mode, start, end)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(data)
    print(f"[PASS] FAT32 fixture mode={args.mode} output={args.output}")
    print(f"[PASS] GPT USOS_ESP start_lba={start} end_lba={end}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
