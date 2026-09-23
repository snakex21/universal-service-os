#!/usr/bin/env python3
"""Build EFI/USOS/bios-ui.bin, the Legacy BIOS menu resources.

The Legacy Core lives in a fixed 256 KiB slot, so its font and system icons
are not compiled in. At startup the Core reads this file from the ESP into
high memory and validates it (src/platform/bios/boot_ui.zig):

  header 32 bytes: "USOSBUI1", u32 payload_len, u32 crc32(payload),
                   u32 font_offset, u32 font_len, u32 icons_offset,
                   u32 icons_len  (offsets relative to the payload)
  font:  a USOS font pack (tools/usos_font_gen.py) with only the 1x tier;
         BIOS VBE modes stay at or below 1280x1024.
  icons: u16 count, then per icon: u8 id_len, id, u16 rle_len, RGBA RLE
         (tools/legacy_rgba_rle.py) of the 32x32 system icon.
"""
from __future__ import annotations

import argparse
import struct
import sys
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import usos_font_gen  # noqa: E402
from generate_legacy_icons import rgba_bytes  # noqa: E402
from legacy_rgba_rle import encode  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
MAGIC = b"USOSBUI1"


def build(icon_dir: Path) -> bytes:
    font, _ = usos_font_gen.build(tiers=[(0, 2)])
    icons = sorted(icon_dir.glob("*.png"), key=lambda item: item.stem.lower())
    table = bytearray(struct.pack("<H", len(icons)))
    for path in icons:
        rle = encode(rgba_bytes(path))
        name = path.stem.encode("ascii")
        if len(name) > 255 or len(rle) > 65535:
            raise SystemExit(f"[ERROR] icon {path.name} does not fit the pack format")
        table += bytes([len(name)]) + name + struct.pack("<H", len(rle)) + rle
    payload = font + bytes(table)
    header = MAGIC + struct.pack("<IIIIII", len(payload), zlib.crc32(payload) & 0xFFFFFFFF, 0, len(font), len(font), len(table))
    return header + payload


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--icons", type=Path, default=ROOT / "media" / "UI" / "Icons" / "Systems")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    data = build(args.icons)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(data)
    print(f"[PASS] Legacy BIOS UI pack: {len(data)} bytes -> {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
