"""Adapt ntfs-3g's Windows 6.1 UpCase algorithm to generated Zig.

SPDX-License-Identifier: GPL-2.0-or-later
Adapted from ntfs_upcase_table_build in pinned libntfs-3g/unistr.c:
Copyright (c) 2000-2004 Anton Altaparmakov
Copyright (c) 2002-2009 Szabolcs Szakacsits
Copyright (c) 2008-2015 Jean-Pierre Andre
Copyright (c) 2008 Bernhard Kaindl
This is a GPL adaptation, not UnicodeData conversion. No C library is linked.
"""
import argparse
import hashlib
from pathlib import Path
import re
import struct

PIN = "7f0f841fc52cf719106c5c93bafe465004e36816"
SOURCE = f"https://github.com/tuxera/ntfs-3g/blob/{PIN}/libntfs-3g/unistr.c"
SOURCE_SHA256 = "3cab19af2bb2775aeca55d77ce0453e4492151be9b5e7f7f085de6facbdfa34d"

def rows(source, name, width):
    match = re.search(r"\b" + re.escape(name) + r"\[.*?=\s*\{(.*?)\}\s*;", source, re.S)
    if match is None: raise ValueError("Pinned source table absent: " + name)
    text = re.sub(r"/\*.*?\*/", "", match[1], flags=re.S)
    result = []
    for row in re.findall(r"\{([^{}]+)\}", text):
        values = [int(value.strip(), 0) for value in row.split(",") if value.strip()]
        if values == [0]: continue
        if len(values) != width: raise ValueError("Unexpected source row: " + name)
        result.append(values)
    if not result: raise ValueError("Empty source table: " + name)
    return result

def table_from_source(raw):
    if hashlib.sha256(raw).hexdigest() != SOURCE_SHA256:
        raise ValueError("Refusing source other than pinned unistr.c")
    source = raw.decode("utf-8")
    table = list(range(65536))
    for first, end, add in rows(source, "uc_run_table", 3):
        for value in range(first, end): table[value] = (value + add) & 65535
    for first, end in rows(source, "uc_dup_table", 2):
        for value in range(first, end, 2): table[value + 1] = value
    for offset, value in rows(source, "uc_byte_table", 2): table[offset] = value
    # The pinned include/ntfs-3g/param.h selects UPCASE_MAJOR=6, MINOR=1.
    for first, last, diff, step, major, minor in rows(source, "newuppercase", 6):
        if (major, minor) <= (6, 1):
            for value in range(first, last + 1, step): table[value] = (value + diff) & 65535
    return table

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("unistr_source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    table = table_from_source(args.unistr_source.read_bytes())
    blob = struct.pack("<65536H", *table)
    sha = hashlib.sha256(blob).hexdigest()
    pairs = [i << 16 | value for i, value in enumerate(table) if i != value]
    lines = [
        "//! SPDX-License-Identifier: GPL-2.0-or-later",
        "//! Windows 6.1 UpCase, adapted from ntfs_upcase_table_build (ntfs-3g).",
        "//! Copyright (c) 2000-2004 Anton Altaparmakov",
        "//! Copyright (c) 2002-2009 Szabolcs Szakacsits",
        "//! Copyright (c) 2008-2015 Jean-Pierre Andre",
        "//! Copyright (c) 2008 Bernhard Kaindl",
        f"//! Source: {SOURCE}",
        f"//! Source SHA256: {SOURCE_SHA256}",
        "//! Pinned param.h selects Windows 6.1; generator: generate_upcase.py.",
        "//! GPL adaptation: identity, run/duplicate/single mappings and versioned updates.",
        "//! Distributed without warranty; see the repository GPL license.",
        f'pub const table_sha256 = "{sha}";',
        "const pairs = [_]u32{",
    ]
    for start in range(0, len(pairs), 8):
        lines.append("    " + ", ".join(f"0x{x:08x}" for x in pairs[start:start+8]) + ",")
    lines.extend([
        "};",
        Path(__file__).with_name("unicode_upper_runtime.zig.inc").read_text(encoding="utf-8").rstrip(),
        'test "Windows 6.1 UpCase golden full table and version-specific mappings" {',
        '    const std = @import("std");',
        "    var table: [65536]u16 = undefined;",
        "    build(&table);",
        "    var bytes: [131072]u8 = undefined;",
        "    for (table, 0..) |value, i| std.mem.writeInt(u16, bytes[i*2..][0..2], value, .little);",
        "    var sha: [32]u8 = undefined; std.crypto.hash.sha2.Sha256.hash(&bytes, &sha, .{});",
        "    try std.testing.expectEqualStrings(table_sha256, &std.fmt.bytesToHex(sha, .lower));",
        "    try std.testing.expectEqual(@as(u16, 'A'), table['a']);",
        "    try std.testing.expectEqual(@as(u16, 0x0141), table[0x0142]);",
        "    try std.testing.expectEqual(@as(u16, 0x03c2), table[0x03c2]);",
        "    try std.testing.expectEqual(@as(u16, 0x023a), table[0x023a]);",
        "    try std.testing.expectEqual(@as(u16, 0xa77d), table[0x1d79]);",
        "    try std.testing.expectEqual(@as(u16, 0x4e2d), table[0x4e2d]);",
        "}",
        "",
    ])
    args.output.write_text("\n".join(lines), encoding="utf-8", newline="\n")
    print(f"Windows6.1 pairs={len(pairs)} bytes={len(blob)} sha256={sha} md5={hashlib.md5(blob).hexdigest()}")


if __name__ == "__main__":
    main()
