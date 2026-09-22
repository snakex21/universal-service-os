#!/usr/bin/env python3
"""Set EFI_PART_ATTR_NO_BLOCK_IO_PROTOCOL (GPT attribute bit 1) on DATA/WORK.

Test-only helper. It operates on a raw disk image, validates both GPT headers and
partition arrays, patches only partitions named USOS_DATA and USOS_WORK, and
recomputes primary/backup CRCs. It never accepts a device path.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import os
import struct
import uuid
import zlib

SECTOR_SIZE = 512
GPT_SIGNATURE = b"EFI PART"
GPT_HEADER_MIN_SIZE = 92
GPT_ATTRIBUTE_NO_BLOCK_IO_PROTOCOL = 1 << 1
TARGET_NAMES = {"USOS_DATA", "USOS_WORK"}
BASIC_DATA_TYPE = uuid.UUID("EBD0A0A2-B9E5-4433-87C0-68B6B72699C7").bytes_le


@dataclass
class Header:
    lba: int
    raw_sector: bytearray
    header_size: int
    current_lba: int
    backup_lba: int
    entries_lba: int
    entry_count: int
    entry_size: int
    entries_crc: int


def crc32(data: bytes) -> int:
    return zlib.crc32(data) & 0xFFFFFFFF


def read_exact(f, offset: int, length: int) -> bytes:
    f.seek(offset)
    data = f.read(length)
    if len(data) != length:
        raise RuntimeError(f"short read offset={offset} length={length} got={len(data)}")
    return data


def write_exact(f, offset: int, data: bytes) -> None:
    f.seek(offset)
    written = f.write(data)
    if written != len(data):
        raise RuntimeError(f"short write offset={offset} length={len(data)} got={written}")


def parse_header(f, lba: int) -> Header:
    sector = bytearray(read_exact(f, lba * SECTOR_SIZE, SECTOR_SIZE))
    if sector[:8] != GPT_SIGNATURE:
        raise RuntimeError(f"GPT signature missing at LBA {lba}")
    header_size = struct.unpack_from("<I", sector, 12)[0]
    if header_size < GPT_HEADER_MIN_SIZE or header_size > SECTOR_SIZE:
        raise RuntimeError(f"invalid GPT header size {header_size} at LBA {lba}")
    stored_crc = struct.unpack_from("<I", sector, 16)[0]
    crc_bytes = bytearray(sector[:header_size])
    struct.pack_into("<I", crc_bytes, 16, 0)
    actual_crc = crc32(crc_bytes)
    if actual_crc != stored_crc:
        raise RuntimeError(
            f"GPT header CRC mismatch at LBA {lba}: stored=0x{stored_crc:08X} actual=0x{actual_crc:08X}"
        )

    current_lba, backup_lba = struct.unpack_from("<QQ", sector, 24)
    entries_lba = struct.unpack_from("<Q", sector, 72)[0]
    entry_count, entry_size, entries_crc = struct.unpack_from("<III", sector, 80)
    if current_lba != lba:
        raise RuntimeError(f"GPT current_lba={current_lba} does not match physical LBA {lba}")
    if entry_count == 0 or entry_size < 128 or entry_size % 8 != 0:
        raise RuntimeError(f"invalid GPT entry geometry count={entry_count} size={entry_size}")

    return Header(
        lba=lba,
        raw_sector=sector,
        header_size=header_size,
        current_lba=current_lba,
        backup_lba=backup_lba,
        entries_lba=entries_lba,
        entry_count=entry_count,
        entry_size=entry_size,
        entries_crc=entries_crc,
    )


def read_entries(f, header: Header) -> bytearray:
    length = header.entry_count * header.entry_size
    raw = bytearray(read_exact(f, header.entries_lba * SECTOR_SIZE, length))
    actual_crc = crc32(raw)
    if actual_crc != header.entries_crc:
        raise RuntimeError(
            f"GPT partition-array CRC mismatch at LBA {header.entries_lba}: "
            f"stored=0x{header.entries_crc:08X} actual=0x{actual_crc:08X}"
        )
    return raw


def decode_name(entry: bytes) -> str:
    name_raw = entry[56:128]
    try:
        text = name_raw.decode("utf-16-le", errors="strict")
    except UnicodeDecodeError as exc:
        raise RuntimeError(f"invalid UTF-16 GPT partition name: {exc}") from exc
    return text.split("\x00", 1)[0]


def patch_entries(entries: bytearray, header: Header) -> dict[str, tuple[int, int]]:
    found: dict[str, tuple[int, int]] = {}
    named_indices: dict[str, int] = {}
    basic_data_indices: list[tuple[int, int]] = []

    for index in range(header.entry_count):
        start = index * header.entry_size
        entry = entries[start : start + header.entry_size]
        if entry[:16] == b"\0" * 16:
            continue
        name = decode_name(entry)
        if name in TARGET_NAMES:
            named_indices[name] = index
        if entry[:16] == BASIC_DATA_TYPE:
            first_lba = struct.unpack_from("<Q", entry, 32)[0]
            basic_data_indices.append((first_lba, index))

    target_indices: dict[str, int]
    if set(named_indices) == TARGET_NAMES:
        target_indices = named_indices
    else:
        # Some Windows-created test VHDs use generic GPT names even though the
        # filesystem labels are USOS_DATA/USOS_WORK. In the canonical USOS
        # layout there must be exactly two Microsoft Basic Data partitions,
        # ordered DATA then WORK. Refuse anything else rather than guessing.
        basic_data_indices.sort()
        if len(basic_data_indices) != 2:
            raise RuntimeError(
                "target GPT names are absent and canonical layout does not contain exactly two Basic Data partitions"
            )
        target_indices = {
            "USOS_DATA": basic_data_indices[0][1],
            "USOS_WORK": basic_data_indices[1][1],
        }

    for name, index in target_indices.items():
        start = index * header.entry_size
        attrs = struct.unpack_from("<Q", entries, start + 48)[0]
        new_attrs = attrs | GPT_ATTRIBUTE_NO_BLOCK_IO_PROTOCOL
        struct.pack_into("<Q", entries, start + 48, new_attrs)
        found[name] = (attrs, new_attrs)
    return found


def commit_header_and_entries(f, header: Header, entries: bytearray) -> None:
    entries_crc = crc32(entries)
    write_exact(f, header.entries_lba * SECTOR_SIZE, entries)

    sector = bytearray(header.raw_sector)
    struct.pack_into("<I", sector, 88, entries_crc)
    struct.pack_into("<I", sector, 16, 0)
    header_crc = crc32(sector[: header.header_size])
    struct.pack_into("<I", sector, 16, header_crc)
    write_exact(f, header.lba * SECTOR_SIZE, sector)


def partition_attributes(entries: bytes, header: Header) -> dict[str, int]:
    named: dict[str, int] = {}
    basic: list[tuple[int, int]] = []
    for index in range(header.entry_count):
        start = index * header.entry_size
        entry = entries[start : start + header.entry_size]
        if entry[:16] == b"\0" * 16:
            continue
        name = decode_name(entry)
        attrs = struct.unpack_from("<Q", entry, 48)[0]
        if name in TARGET_NAMES:
            named[name] = attrs
        if entry[:16] == BASIC_DATA_TYPE:
            first_lba = struct.unpack_from("<Q", entry, 32)[0]
            basic.append((first_lba, attrs))
    if set(named) == TARGET_NAMES:
        return named
    basic.sort()
    if len(basic) != 2:
        return {}
    return {"USOS_DATA": basic[0][1], "USOS_WORK": basic[1][1]}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("image", type=Path)
    args = parser.parse_args()

    image = args.image.resolve()
    if not image.is_file():
        raise FileNotFoundError(image)
    # Hard fail on Windows raw-device syntax and Unix device nodes. This tool is
    # intentionally limited to disposable test image files.
    text = str(image)
    if text.startswith("\\\\.\\") or text.startswith("/dev/"):
        raise RuntimeError("refusing device path; use a disposable raw image file")
    size = image.stat().st_size
    if size < 2 * 1024 * 1024 or size % SECTOR_SIZE != 0:
        raise RuntimeError(f"invalid raw disk image size: {size}")

    with image.open("r+b", buffering=0) as f:
        primary = parse_header(f, 1)
        backup = parse_header(f, primary.backup_lba)
        if backup.backup_lba != 1:
            raise RuntimeError("backup GPT does not point back to primary LBA 1")

        primary_entries = read_entries(f, primary)
        backup_entries = read_entries(f, backup)
        if primary_entries != backup_entries:
            raise RuntimeError("primary and backup GPT partition arrays differ before patch")

        changes = patch_entries(primary_entries, primary)
        backup_entries[:] = primary_entries
        commit_header_and_entries(f, primary, primary_entries)
        commit_header_and_entries(f, backup, backup_entries)
        f.flush()
        os.fsync(f.fileno())

        verify_primary = parse_header(f, 1)
        verify_backup = parse_header(f, verify_primary.backup_lba)
        verify_primary_entries = read_entries(f, verify_primary)
        verify_backup_entries = read_entries(f, verify_backup)
        if verify_primary_entries != verify_backup_entries:
            raise RuntimeError("primary and backup GPT partition arrays differ after patch")
        attrs = partition_attributes(verify_primary_entries, verify_primary)
        if set(attrs) != TARGET_NAMES:
            raise RuntimeError(f"verification did not find both target partitions: {attrs}")
        for name, value in attrs.items():
            if value & GPT_ATTRIBUTE_NO_BLOCK_IO_PROTOCOL == 0:
                raise RuntimeError(f"{name} is missing NO_BLOCK_IO_PROTOCOL after patch")

    for name in sorted(changes):
        old, new = changes[name]
        print(f"[PASS] {name} GPT attributes 0x{old:016X} -> 0x{new:016X}")
    print(f"[PASS] primary+backup GPT CRCs valid after patch: {image}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
