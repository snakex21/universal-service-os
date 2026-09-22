"""Build a Vista SP2 BIOS bootmgr path probe.

The physical MS-7100 reaches bootmgr's PE entry point after the wimboot handoff,
but then stops before any observed BIOS callback.  This diagnostic image adds a
small executable PE section and routes selected existing CALL instructions
through marker trampolines.  Each trampoline writes a digit directly to the
last VGA text cell and then jumps to the original call target, preserving the
original CALL/RET stack semantics.  The visible digit is therefore the furthest
main-path call reached inside bootmgr's entry routine.
"""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import struct

SOURCE_SHA256 = "b9bc1cf550aaa2b120be678837e47f06876bb3e922c894ca56d293d9e2cfe347"
VGA_LAST_CHAR = 0x000B8F9E
ENTRY_PROLOGUE = bytes.fromhex("8b ff 55 8b ec")
# Main-path CALLs visible in the Vista SP2 bootmgr entry routine.  Error-only
# calls are intentionally skipped so marker order stays monotonic on success.
CALL_SITES = (
    (0x1090, "1"),
    (0x10E2, "2"),
    (0x10F9, "3"),
    (0x110A, "4"),
    (0x113E, "5"),
    (0x1152, "6"),
    (0x1157, "7"),
)
SECTION_NAME = b".usosp\0\0"
SECTION_CHARACTERISTICS = 0x60000020  # code | execute | read


def align_up(value: int, alignment: int) -> int:
    return (value + alignment - 1) & ~(alignment - 1)


def parse_pe(image: bytes):
    pe = struct.unpack_from("<I", image, 0x3C)[0]
    if image[pe : pe + 4] != b"PE\0\0":
        raise ValueError("Not a PE image")
    count = struct.unpack_from("<H", image, pe + 6)[0]
    optional_size = struct.unpack_from("<H", image, pe + 20)[0]
    optional = pe + 24
    if struct.unpack_from("<H", image, optional)[0] != 0x10B:
        raise ValueError("Expected PE32 bootmgr")
    entry_rva = struct.unpack_from("<I", image, optional + 16)[0]
    image_base = struct.unpack_from("<I", image, optional + 28)[0]
    section_alignment = struct.unpack_from("<I", image, optional + 32)[0]
    file_alignment = struct.unpack_from("<I", image, optional + 36)[0]
    size_of_image = struct.unpack_from("<I", image, optional + 56)[0]
    size_of_headers = struct.unpack_from("<I", image, optional + 60)[0]
    section_table = optional + optional_size
    sections = []
    for index in range(count):
        off = section_table + index * 40
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
    return {
        "pe": pe,
        "count": count,
        "optional": optional,
        "section_table": section_table,
        "entry_rva": entry_rva,
        "image_base": image_base,
        "section_alignment": section_alignment,
        "file_alignment": file_alignment,
        "size_of_image": size_of_image,
        "size_of_headers": size_of_headers,
        "sections": sections,
    }


def rva_to_file(sections, rva: int) -> int:
    for section in sections:
        start = section["virtual_address"]
        span = min(section["raw_size"], max(section["virtual_size"], 1))
        if start <= rva < start + span:
            return section["raw_offset"] + (rva - start)
    raise ValueError(f"RVA {rva:#x} is not backed by file data")


def rel32(source_next_rva: int, target_rva: int) -> bytes:
    delta = target_rva - source_next_rva
    if not -(1 << 31) <= delta < (1 << 31):
        raise ValueError("relative branch is out of range")
    return struct.pack("<i", delta)


def marker_write(character: str) -> bytes:
    # mov byte ptr ds:[VGA_LAST_CHAR], imm8
    return b"\xC6\x05" + struct.pack("<I", VGA_LAST_CHAR) + bytes([ord(character)])


def build(source: bytes) -> tuple[bytes, dict]:
    digest = hashlib.sha256(source).hexdigest()
    if digest != SOURCE_SHA256:
        raise ValueError(f"Unexpected Vista bootmgr SHA-256 {digest}")
    pe = parse_pe(source)
    if pe["entry_rva"] != 0x1000:
        raise ValueError(f"Unexpected bootmgr entry RVA {pe['entry_rva']:#x}")

    entry_file = rva_to_file(pe["sections"], pe["entry_rva"])
    if source[entry_file : entry_file + 5] != ENTRY_PROLOGUE:
        raise ValueError("Unexpected bootmgr entry prologue")

    new_header = pe["section_table"] + pe["count"] * 40
    if new_header + 40 > pe["size_of_headers"]:
        raise ValueError("PE headers have no room for diagnostic section")

    raw_offset = align_up(len(source), pe["file_alignment"])
    virtual_address = align_up(pe["size_of_image"], pe["section_alignment"])

    # Allocate all trampolines first so every branch target is stable.
    trampolines: list[tuple[str, int, bytes]] = []
    cursor = 0

    entry_code = marker_write("0") + ENTRY_PROLOGUE
    entry_jump_rva = virtual_address + cursor + len(entry_code)
    entry_code += b"\xE9" + rel32(entry_jump_rva + 5, pe["entry_rva"] + 5)
    trampolines.append(("entry", cursor, entry_code))
    cursor += len(entry_code)

    call_metadata = []
    for call_rva, marker in CALL_SITES:
        call_file = rva_to_file(pe["sections"], call_rva)
        if source[call_file] != 0xE8:
            raise ValueError(f"Expected CALL rel32 at RVA {call_rva:#x}")
        original_delta = struct.unpack_from("<i", source, call_file + 1)[0]
        original_target = call_rva + 5 + original_delta
        code = marker_write(marker)
        jump_rva = virtual_address + cursor + len(code)
        code += b"\xE9" + rel32(jump_rva + 5, original_target)
        trampolines.append((f"call-{marker}", cursor, code))
        call_metadata.append((call_rva, marker, original_target, cursor))
        cursor += len(code)

    virtual_size = cursor
    raw_size = align_up(virtual_size, pe["file_alignment"])
    new_size_of_image = align_up(
        virtual_address + virtual_size, pe["section_alignment"]
    )

    patched = bytearray(source)
    if len(patched) < raw_offset:
        patched += bytes(raw_offset - len(patched))
    patched += bytes(raw_size)

    # New section header.
    header = bytearray(40)
    header[0:8] = SECTION_NAME
    struct.pack_into(
        "<IIII", header, 8, virtual_size, virtual_address, raw_size, raw_offset
    )
    struct.pack_into("<I", header, 36, SECTION_CHARACTERISTICS)
    patched[new_header : new_header + 40] = header
    struct.pack_into("<H", patched, pe["pe"] + 6, pe["count"] + 1)
    struct.pack_into("<I", patched, pe["optional"] + 56, new_size_of_image)

    # Entry hook.
    entry_trampoline_rva = virtual_address + trampolines[0][1]
    patched[entry_file : entry_file + 5] = b"\xE9" + rel32(
        pe["entry_rva"] + 5, entry_trampoline_rva
    )

    # Main-path CALL hooks.  CALLing a trampoline keeps the caller's return
    # address on the stack; the trampoline JMPs to the original target, whose
    # RET therefore returns exactly to the original callsite+5.
    for call_rva, marker, original_target, trampoline_offset in call_metadata:
        call_file = rva_to_file(pe["sections"], call_rva)
        trampoline_rva = virtual_address + trampoline_offset
        patched[call_file : call_file + 5] = b"\xE8" + rel32(
            call_rva + 5, trampoline_rva
        )

    for _name, offset, code in trampolines:
        start = raw_offset + offset
        patched[start : start + len(code)] = code

    info = {
        "source_sha256": digest,
        "probe_sha256": hashlib.sha256(patched).hexdigest(),
        "entry_rva": pe["entry_rva"],
        "probe_section_rva": virtual_address,
        "probe_section_virtual_size": virtual_size,
        "probe_section_raw_size": raw_size,
        "markers": "0" + "".join(marker for _, marker in CALL_SITES),
    }
    return bytes(patched), info


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    probe, info = build(args.source.read_bytes())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(probe)
    for key, value in info.items():
        if isinstance(value, int):
            print(f"{key}={value:#x}")
        else:
            print(f"{key}={value}")


if __name__ == "__main__":
    main()
