"""Build a one-shot Vista/Win7 BIOS bootmgr entry probe.

The probe is only for physical diagnostics.  It changes the five-byte hotpatch
prologue at the PE entry point into a relative jump to an existing zero-filled
code cave inside an executable section.  The trampoline writes one character
directly to the last VGA text cell, executes the original prologue, and jumps
back to entry+5.  No BIOS interrupt is used, so seeing the marker proves that
bootmgr itself executed at least its first instruction after wimboot handoff.
"""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import struct


VGA_LAST_CHAR = 0x000B8F9E  # 80x25 text mode, row 24 col 79 character byte
EXPECTED_ENTRY = bytes.fromhex("8b ff 55 8b ec")
MIN_CAVE = 17


def section_table(image: bytes):
    pe = struct.unpack_from("<I", image, 0x3C)[0]
    if image[pe : pe + 4] != b"PE\0\0":
        raise ValueError("Not a PE image")
    count = struct.unpack_from("<H", image, pe + 6)[0]
    optional_size = struct.unpack_from("<H", image, pe + 20)[0]
    optional = pe + 24
    magic = struct.unpack_from("<H", image, optional)[0]
    if magic != 0x10B:
        raise ValueError(f"Expected PE32 bootmgr, got optional magic {magic:#x}")
    entry_rva = struct.unpack_from("<I", image, optional + 16)[0]
    image_base = struct.unpack_from("<I", image, optional + 28)[0]
    sections = []
    start = optional + optional_size
    for index in range(count):
        off = start + index * 40
        name = image[off : off + 8].split(b"\0", 1)[0].decode("ascii", "replace")
        virtual_size, virtual_address, raw_size, raw_offset = struct.unpack_from(
            "<IIII", image, off + 8
        )
        characteristics = struct.unpack_from("<I", image, off + 36)[0]
        sections.append(
            {
                "name": name,
                "virtual_size": virtual_size,
                "virtual_address": virtual_address,
                "raw_size": raw_size,
                "raw_offset": raw_offset,
                "characteristics": characteristics,
            }
        )
    return entry_rva, image_base, sections


def rva_to_file(sections, rva: int) -> int:
    for section in sections:
        va = section["virtual_address"]
        span = min(section["raw_size"], max(section["virtual_size"], 1))
        if va <= rva < va + span:
            return section["raw_offset"] + (rva - va)
    raise ValueError(f"RVA {rva:#x} is not backed by file data")


def find_exec_cave(image: bytes, sections, needed: int):
    best = None
    for section in sections:
        if not (section["characteristics"] & 0x20000000):
            continue
        usable = min(section["raw_size"], section["virtual_size"])
        data = image[section["raw_offset"] : section["raw_offset"] + usable]
        start = None
        for pos, byte in enumerate(data + b"\x01"):
            if byte == 0 and start is None:
                start = pos
            elif byte != 0 and start is not None:
                length = pos - start
                if length >= needed:
                    candidate = (length, section, start)
                    if best is None or candidate[0] < best[0]:
                        # Prefer the smallest sufficient cave so we avoid consuming
                        # a larger area that may be useful for later diagnostics.
                        best = candidate
                start = None
    if best is None:
        raise ValueError(f"No executable zero cave of at least {needed} bytes")
    length, section, offset = best
    return section, offset, length


def rel32(source_next_rva: int, target_rva: int) -> bytes:
    delta = target_rva - source_next_rva
    if not -(1 << 31) <= delta < (1 << 31):
        raise ValueError("relative jump is out of range")
    return struct.pack("<i", delta)


def build(source: bytes, marker: int = ord("0")) -> tuple[bytes, dict]:
    entry_rva, image_base, sections = section_table(source)
    entry_file = rva_to_file(sections, entry_rva)
    original = source[entry_file : entry_file + len(EXPECTED_ENTRY)]
    if original != EXPECTED_ENTRY:
        raise ValueError(
            f"Unexpected bootmgr entry bytes {original.hex()} at RVA {entry_rva:#x}"
        )

    section, cave_offset, cave_len = find_exec_cave(source, sections, MIN_CAVE)
    cave_rva = section["virtual_address"] + cave_offset
    cave_file = section["raw_offset"] + cave_offset

    # mov byte ptr ds:[VGA_LAST_CHAR], marker
    trampoline = bytearray(b"\xC6\x05" + struct.pack("<I", VGA_LAST_CHAR) + bytes([marker]))
    trampoline += original
    trampoline += b"\xE9" + rel32(cave_rva + len(trampoline) + 5, entry_rva + 5)
    if len(trampoline) > cave_len:
        raise ValueError("Selected code cave is too small after trampoline assembly")

    patched = bytearray(source)
    patched[entry_file : entry_file + 5] = b"\xE9" + rel32(entry_rva + 5, cave_rva)
    patched[cave_file : cave_file + len(trampoline)] = trampoline

    info = {
        "source_sha256": hashlib.sha256(source).hexdigest(),
        "probe_sha256": hashlib.sha256(patched).hexdigest(),
        "entry_rva": entry_rva,
        "image_base": image_base,
        "cave_section": section["name"],
        "cave_rva": cave_rva,
        "cave_bytes": cave_len,
        "trampoline_bytes": len(trampoline),
        "marker": chr(marker),
    }
    return bytes(patched), info


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--marker", default="0")
    args = parser.parse_args()
    if len(args.marker) != 1:
        raise SystemExit("--marker must contain exactly one character")
    source = args.source.read_bytes()
    patched, info = build(source, ord(args.marker))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(patched)
    for key, value in info.items():
        if isinstance(value, int):
            print(f"{key}={value:#x}")
        else:
            print(f"{key}={value}")


if __name__ == "__main__":
    main()
