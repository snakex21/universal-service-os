#!/usr/bin/env python3
"""Rasterize the USOS boot UI font pack (src/gui/fonts/usos-font.bin).

Sources (see assets/fonts/README.md for licenses):
  assets/fonts/Roboto-Regular.ttf, Roboto-Medium.ttf   Apache License 2.0
  assets/fonts/NotoSans-UsosSymbols.ttf                SIL OFL 1.1 (arrows, check mark)

Only the codepoints the boot UI can show are packed: printable ASCII (file
and system names are ASCII), the UI punctuation and arrows, and every
character used by any boot.* string or language name in
installer/internal/i18n/locales (Latin-1/Extended-A diacritics, Greek and
Cyrillic as the 27 catalogs need them).

Glyphs are hinted by FreeType (Pillow), stored as 4-bit alpha coverage and
laid out per face. Two tiers are rasterized natively (1x and 1.5x); the
renderer draws 2x/3x by bilinear integer upscaling of those tiers.

Format (little endian), see src/gui/font.zig:
  header 32 bytes: "USOSFONT", u16 version=1, u16 face_count, u32 payload_len,
                   u32 crc32(payload), u16 glyph_count, 10 reserved bytes
  payload (offsets are relative to the payload start):
    glyph_count * u16 codepoints, sorted, padded to 4 bytes
    face_count * 16-byte faces: u8 role, u8 tier, u8 px size, u8 ascent,
        u8 descent, u8 line height, u8 weight, u8 0, u32 metrics offset,
        u32 bitmap offset
    per face: glyph_count * 8-byte metrics (u8 w, u8 h, i8 left, i8 top,
        u8 advance, u24 bitmap offset) in codepoint order, then the bitmaps:
        4-bit coverage, two pixels per byte (high nibble first), rows packed.

  python tools/usos_font_gen.py           regenerate
  python tools/usos_font_gen.py --check   fail when the committed pack is stale
"""
from __future__ import annotations

import argparse
import json
import struct
import sys
import zlib
from pathlib import Path

from PIL import ImageFont

ROOT = Path(__file__).resolve().parents[1]
FONT_DIR = ROOT / "assets" / "fonts"
LOCALES = ROOT / "installer" / "internal" / "i18n" / "locales"
OUTPUT = ROOT / "src" / "gui" / "fonts" / "usos-font.bin"

MAGIC = b"USOSFONT"
VERSION = 1
HEADER = 32
FACE_RECORD = 16
METRICS_RECORD = 8

# role ids are mirrored by src/gui/font.zig Role.
ROLES = [
    # (role id, name, weight file, base pixel size)
    (0, "small", "Roboto-Regular.ttf", 13),
    (1, "body", "Roboto-Regular.ttf", 15),
    (2, "strong", "Roboto-Medium.ttf", 15),
    (3, "heading", "Roboto-Medium.ttf", 21),
]
TIERS = [(0, 2), (1, 3)]  # (tier id, scale numerator over 2): 1x and 1.5x
SYMBOL_FONT = "NotoSans-UsosSymbols.ttf"
# Light text on a dark background looks thinner with linear blending; lift
# partial coverage slightly before quantizing.
COVERAGE_GAMMA = 0.82


def base_codepoints() -> set[int]:
    # File and system names on USOS media are ASCII (see src/core/fixed_text.zig);
    # everything else the UI shows comes from the boot.* catalog strings.
    cps = set(range(0x20, 0x7F))
    cps |= {0xA0, 0xA9, 0xB0, 0xB7, 0xD7, 0xAB, 0xBB,
            0x2013, 0x2014, 0x2018, 0x2019, 0x201A, 0x201C, 0x201D, 0x201E,
            0x2022, 0x2026, 0x2190, 0x2191, 0x2192, 0x2193, 0x2713}
    return cps


def catalog_codepoints() -> set[int]:
    cps: set[int] = set()
    for path in sorted(LOCALES.glob("*.json")):
        data = json.loads(path.read_text(encoding="utf-8"))
        for key, value in data.items():
            if key == "_meta":
                cps |= {ord(c) for c in value.get("native_name", "")}
                continue
            if key.startswith("boot."):
                cps |= {ord(c) for c in value if c != "\n"}
    return cps


def quantize(value: int) -> int:
    if value <= 0:
        return 0
    lifted = (value / 255.0) ** COVERAGE_GAMMA
    return max(0, min(15, int(lifted * 15 + 0.5)))


def rasterize(font: ImageFont.FreeTypeFont, symbols: ImageFont.FreeTypeFont, cp: int, cmap, symbol_cmap):
    ch = chr(cp)
    source = font
    if cp not in cmap:
        if cp not in symbol_cmap:
            return None
        source = symbols
    advance = int(round(source.getlength(ch)))
    if ch == " " or ch == " ":
        return (0, 0, 0, 0, advance, b"")
    mask, offset = source.getmask2(ch, mode="L")
    width, height = mask.size
    if width == 0 or height == 0:
        return (0, 0, 0, 0, advance, b"")
    raw = bytes(mask)
    # Trim empty borders so bitmaps stay compact.
    rows = [raw[y * width:(y + 1) * width] for y in range(height)]
    top = 0
    while top < height and not any(rows[top]):
        top += 1
    bottom = height
    while bottom > top and not any(rows[bottom - 1]):
        bottom -= 1
    if top == bottom:
        return (0, 0, 0, 0, advance, b"")
    left = min((next(i for i, v in enumerate(r) if v) for r in rows[top:bottom] if any(r)))
    right = max((len(r) - next(i for i, v in enumerate(reversed(r)) if v) for r in rows[top:bottom] if any(r)))
    w = right - left
    h = bottom - top
    nibbles = [quantize(rows[y][x]) for y in range(top, bottom) for x in range(left, right)]
    if len(nibbles) % 2:
        nibbles.append(0)
    packed = bytes((nibbles[i] << 4) | nibbles[i + 1] for i in range(0, len(nibbles), 2))
    return (w, h, offset[0] + left, offset[1] + top, advance, packed)


def build(tiers=TIERS) -> tuple[bytes, dict]:
    codepoints = sorted(base_codepoints() | catalog_codepoints())
    symbol_path = FONT_DIR / SYMBOL_FONT
    faces = []
    report = {"codepoints": len(codepoints), "faces": []}
    for tier, numerator in tiers:
        for role, name, file_name, base in ROLES:
            size = (base * numerator + 1) // 2
            font = ImageFont.truetype(str(FONT_DIR / file_name), size)
            symbols = ImageFont.truetype(str(symbol_path), size)
            cmap = cmap_of(FONT_DIR / file_name)
            symbol_cmap = cmap_of(symbol_path)
            ascent, descent = font.getmetrics()
            glyphs = []
            missing = []
            for cp in codepoints:
                glyph = rasterize(font, symbols, cp, cmap, symbol_cmap)
                if glyph is None:
                    missing.append(cp)
                    continue
                glyphs.append((cp, glyph))
            if missing:
                raise SystemExit(f"[ERROR] {file_name} {size}px lacks " + " ".join(f"U+{cp:04X}" for cp in missing))
            line_height = ascent + descent + max(2, size // 5)
            faces.append({"role": role, "tier": tier, "size": size, "ascent": ascent, "descent": descent,
                          "line_height": line_height, "weight": 1 if "Medium" in file_name else 0, "glyphs": glyphs})
            report["faces"].append((name, tier, size, len(glyphs), sum(len(g[1][5]) for g in glyphs)))

    count = len(codepoints)
    if any(cp > 0xFFFF for cp in codepoints):
        raise SystemExit("[ERROR] codepoints above U+FFFF need a format change")
    cp_table = bytearray(struct.pack(f"<{count}H", *codepoints))
    while len(cp_table) % 4:
        cp_table.append(0)
    faces_offset = len(cp_table)
    body = bytearray()
    body_base = faces_offset + len(faces) * FACE_RECORD
    face_table = bytearray()
    for face in faces:
        metrics = bytearray()
        bitmaps = bytearray()
        for cp, (w, h, left, top, advance, packed) in face["glyphs"]:
            if not (-128 <= left < 128 and -128 <= top < 128 and 0 <= advance < 256 and w < 256 and h < 256):
                raise SystemExit(f"[ERROR] glyph U+{cp:04X} does not fit the record format")
            offset = len(bitmaps)
            metrics += struct.pack("<BBbbB", w, h, left, top, advance) + offset.to_bytes(3, "little")
            bitmaps += packed
        metrics_offset = body_base + len(body)
        body += metrics
        bitmap_offset = body_base + len(body)
        body += bitmaps
        face_table += struct.pack("<BBBBBBBxII", face["role"], face["tier"], face["size"], face["ascent"],
                                  face["descent"], face["line_height"], face["weight"], metrics_offset, bitmap_offset)
    payload = bytes(cp_table + face_table + body)
    header = MAGIC + struct.pack("<HHIIH10x", VERSION, len(faces), len(payload), zlib.crc32(payload) & 0xFFFFFFFF, count)
    assert len(header) == HEADER
    return header + payload, report


_CMAPS: dict[Path, set[int]] = {}


def cmap_of(path: Path) -> set[int]:
    if path not in _CMAPS:
        from fontTools.ttLib import TTFont
        _CMAPS[path] = set(TTFont(str(path), lazy=True).getBestCmap().keys())
    return _CMAPS[path]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    data, report = build()
    for name, tier, size, count, bitmap_bytes in report["faces"]:
        print(f"[FACE] {name:8s} tier={tier} {size:2d}px glyphs={count} bitmap={bitmap_bytes} bytes")
    print(f"[FONT] codepoints={report['codepoints']} pack={len(data)} bytes")
    current = OUTPUT.read_bytes() if OUTPUT.exists() else b""
    if current == data:
        print(f"[OK] {OUTPUT.relative_to(ROOT)}")
        return 0
    if args.check:
        print(f"[STALE] {OUTPUT.relative_to(ROOT)}; run python tools/usos_font_gen.py")
        return 1
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_bytes(data)
    print(f"[WROTE] {OUTPUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
