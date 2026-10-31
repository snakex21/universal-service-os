"""Generate own chunk fixtures with the host-only wimlib oracle.

No archive/Windows data. The production Zig codecs never load this library.
All generated compressed chunks, originals and receipts go to --output.
"""
from __future__ import annotations
import argparse
import ctypes
import hashlib
import json
from pathlib import Path
import random
import struct


def patterns(size: int):
    rng = random.Random(0x554F5300 + size)
    dictionary = bytes(rng.randrange(256) for _ in range(512))
    yield "zero", bytes(size)
    yield "constant", bytes([0xAB]) * size
    yield "alternating", (b"AB" * ((size + 1) // 2))[:size]
    yield "dictionary", (dictionary * ((size + 511) // 512))[:size]
    yield "gradient", bytes((i // 3) & 255 for i in range(size))
    yield "words", b"".join(struct.pack("<I", i * 3) for i in range((size + 3) // 4))[:size]
    text = b"<SYSTEM><FILE path='Windows/system32/own-fixture' size='12345'/>\r\n"
    yield "xml", (text * ((size + len(text) - 1) // len(text)))[:size]
    data = bytearray((dictionary * ((size + 511) // 512))[:size])
    for i in range(7, size - 5, 23):
        data[i] = 0xE8
        struct.pack_into("<i", data, i + 1, (i * 31 if i & 1 else -i) % 12000000)
    yield "e8", bytes(data)
    data = bytearray(size)
    for i in range(0, size, 127):
        block = bytes(rng.randrange(256) for _ in range(min(15, size - i)))
        data[i:i + len(block)] = block
    yield "sparse-random", bytes(data)
    data = bytearray(size)
    for i in range(7, size - 8, 11):
        data[i] = 0xE8
        struct.pack_into("<i", data, i + 1, -i)
    yield "x86-same-target", bytes(data)
    prefix = bytes(rng.randrange(256) for _ in range((size + 1) // 2))
    yield "far-reference", (prefix + prefix)[:size]
    data = bytearray([0x90]) * size
    instructions = (b"\xff\x15", b"\xf0\x83\x05", b"\x48\x8d\x05", b"\x4c\x8d\x05", b"\x48\x8b\x05")
    for number, i in enumerate(range(1, size - 8, 13)):
        opcode = instructions[number % len(instructions)]
        data[i:i + len(opcode)] = opcode
        struct.pack_into("<i", data, i + len(opcode), -i)
    yield "x86-prefixes", bytes(data)


def generate(library: Path, output: Path, kinds: list[str]):
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        raise ValueError("Never overwrite compressed fixtures/evidence")
    dll = ctypes.CDLL(str(library.resolve()))
    pointer = ctypes.c_void_p
    size_t = ctypes.c_size_t
    dll.wimlib_create_compressor.argtypes = [ctypes.c_int, size_t, ctypes.c_uint, ctypes.POINTER(pointer)]
    dll.wimlib_compress.argtypes = [pointer, size_t, pointer, size_t, pointer]
    dll.wimlib_compress.restype = size_t
    dll.wimlib_free_compressor.argtypes = [pointer]
    dll.wimlib_create_decompressor.argtypes = [ctypes.c_int, size_t, ctypes.POINTER(pointer)]
    dll.wimlib_decompress.argtypes = [pointer, size_t, pointer, size_t, pointer]
    dll.wimlib_free_decompressor.argtypes = [pointer]
    vectors = []
    records = []
    for name in kinds:
        kind = {"xpress": 1, "lzx": 2, "lzms": 3}[name]
        maximum = 131072 if name == "lzms" else 32768
        for level in (20, 50, 80):
            compressor, decompressor = pointer(), pointer()
            if dll.wimlib_create_compressor(kind, maximum, level, ctypes.byref(compressor)):
                raise ValueError("wimlib compressor unavailable")
            if dll.wimlib_create_decompressor(kind, maximum, ctypes.byref(decompressor)):
                raise ValueError("wimlib decompressor unavailable")
            try:
                for length in (512, 4095, 4096, 16003, 32767, 32768) + ((65536, 131072) if name == "lzms" else ()):
                    for pattern, original in patterns(length):
                        source = ctypes.create_string_buffer(original)
                        packed = ctypes.create_string_buffer(length * 2 + 4096)
                        compressed = dll.wimlib_compress(source, length, packed, len(packed), compressor)
                        if not compressed:
                            continue  # WIM stores incompressible chunks verbatim.
                        decoded = ctypes.create_string_buffer(length)
                        if dll.wimlib_decompress(packed, compressed, decoded, length, decompressor) or decoded.raw != original:
                            raise ValueError("Oracle self-check failed")
                        value = packed.raw[:compressed]
                        vectors.append(struct.pack("<BII", kind, length, compressed) + original + value)
                        records.append({"kind": name, "level": level, "pattern": pattern,
                            "size": length, "compressed": compressed,
                            "sha256": hashlib.sha256(original).hexdigest(),
                            "compressed_sha256": hashlib.sha256(value).hexdigest()})
            finally:
                dll.wimlib_free_compressor(compressor)
                dll.wimlib_free_decompressor(decompressor)
    output.write_bytes(b"USWIMC01" + struct.pack("<I", len(vectors)) + b"".join(vectors))
    result = {"schema": 1, "own_generated_data": True, "oracle": "wimlib host compression API",
        "library_sha256": hashlib.sha256(library.read_bytes()).hexdigest(),
        "bundle_sha256": hashlib.sha256(output.read_bytes()).hexdigest(), "vectors": records}
    with output.with_suffix(".json").open("x", encoding="utf-8") as out:
        json.dump(result, out, indent=2)
    print(json.dumps({"vectors": len(records), "kinds": kinds, "bundle_sha256": result["bundle_sha256"]}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--kind", action="append", choices=("xpress", "lzx", "lzms"), required=True)
    args = parser.parse_args()
    generate(args.library, args.output, args.kind)
