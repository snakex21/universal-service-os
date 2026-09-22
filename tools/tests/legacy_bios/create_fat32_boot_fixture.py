#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path
import shutil
import struct
import subprocess

SECTOR = 512
CORE_LBA = 64
CORE_BYTES = 512 * SECTOR
ESP_TYPE = bytes.fromhex("28732ac11ff8d211ba4b00a0c93ec93b")


def run(args: list[str]) -> None:
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode != 0:
        raise RuntimeError(f"command failed ({result.returncode}): {' '.join(args)}\n{result.stdout}")


def find_esp_start(raw: Path) -> int:
    with raw.open("rb") as handle:
        handle.seek(SECTOR)
        header = handle.read(SECTOR)
        if header[:8] != b"EFI PART":
            raise ValueError("primary GPT header missing")
        entries_lba = struct.unpack_from("<Q", header, 72)[0]
        count = struct.unpack_from("<I", header, 80)[0]
        entry_size = struct.unpack_from("<I", header, 84)[0]
        if entry_size != 128 or count == 0 or count > 128:
            raise ValueError("unsupported GPT entry layout")
        handle.seek(entries_lba * SECTOR)
        entries = handle.read(count * entry_size)
        matches: list[int] = []
        for index in range(count):
            entry = entries[index * entry_size:(index + 1) * entry_size]
            if entry[:16] == ESP_TYPE:
                name = entry[56:128].decode("utf-16le", errors="strict").split("\0", 1)[0]
                if name == "USOS_ESP":
                    matches.append(struct.unpack_from("<Q", entry, 32)[0])
        if len(matches) != 1:
            raise ValueError(f"expected one GPT USOS_ESP, got {len(matches)}")
        return matches[0]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--qemu-img", type=Path, required=True)
    parser.add_argument("--source-raw", type=Path, required=True)
    parser.add_argument("--stage1", type=Path, required=True)
    parser.add_argument("--core-slot", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    stage1 = args.stage1.read_bytes()
    core = args.core_slot.read_bytes()
    if len(stage1) != 440:
        raise ValueError(f"Stage 1 must be 440 bytes, got {len(stage1)}")
    if len(core) != CORE_BYTES:
        raise ValueError(f"Core slot must be {CORE_BYTES} bytes, got {len(core)}")
    esp_start = find_esp_start(args.source_raw)
    core_end = CORE_LBA + CORE_BYTES // SECTOR
    if CORE_LBA < 34 or core_end > esp_start:
        raise ValueError(f"Core LBA {CORE_LBA}..{core_end - 1} overlaps GPT/ESP start {esp_start}")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    staging = args.output.parent / f".{args.output.stem}.staging.raw"
    if staging.exists():
        staging.unlink()
    if args.output.exists():
        args.output.unlink()
    shutil.copyfile(args.source_raw, staging)
    try:
        with staging.open("r+b") as handle:
            lba0 = bytearray(handle.read(SECTOR))
            if len(lba0) != SECTOR or lba0[510:512] != b"\x55\xAA" or lba0[446 + 4] != 0xEE:
                raise ValueError("source raw lacks valid protective MBR")
            preserved = bytes(lba0[440:512])
            lba0[:440] = stage1
            if bytes(lba0[440:512]) != preserved:
                raise AssertionError("Stage1 patch changed LBA0 bytes 440..511")
            handle.seek(0)
            handle.write(lba0)
            handle.seek(CORE_LBA * SECTOR)
            handle.write(core)
            handle.flush()

        run([str(args.qemu_img.resolve()), "convert", "-f", "raw", "-O", "qcow2", str(staging), str(args.output.resolve())])
        run([str(args.qemu_img.resolve()), "check", str(args.output.resolve())])
    finally:
        staging.unlink(missing_ok=True)

    print(f"[PASS] FAT32 boot fixture={args.output}")
    print(f"[PASS] Stage1 patched only LBA0 bytes 0..439; bytes 440..511 preserved")
    print(f"[PASS] Core slot LBA={CORE_LBA}..{core_end - 1}; GPT USOS_ESP starts LBA={esp_start}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
