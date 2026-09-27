#!/usr/bin/env python3
"""Pack the static /usos/init helper into usos-linux.cpio (newc, uncompressed,
deterministic: mtime 0, uid/gid 0, 4-byte padded end).

The cpio is appended by the USOS menu / Core to a distro initramfs when a
Linux ISO is booted from DATA (docs/design/linux-iso-boot.md). Only entries
under usos/ (never lib/bin/sbin: those may be symlinks in the distro image).

    python tools/build_linux_iso_helper.py --init zig-out/linux-iso/usos-init --out zig-out/usb/EFI/USOS/linux/usos-linux.cpio
"""
from __future__ import annotations

import argparse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def entry(path: str, mode: int, data: bytes, ino: int) -> bytes:
    name = path.encode() + b"\0"
    nlink = 2 if mode & 0o170000 == 0o040000 else 1
    fields = [ino, mode, 0, 0, nlink, 0, len(data), 0, 0, 0, 0, len(name), 0]
    head = b"070701" + b"".join(b"%08x" % f for f in fields) + name
    head += b"\0" * (-len(head) % 4)
    return head + data + b"\0" * (-len(data) % 4)


def build(init: bytes, hook: bytes) -> bytes:
    out = b""
    items = [
        ("usos", 0o040755, b""),
        ("usos/hooks", 0o040755, b""),
        ("usos/init", 0o100755, init),
        ("usos/hooks/init-bottom", 0o100755, hook),
    ]
    for ino, (path, mode, data) in enumerate(items, start=0x55530001):
        out += entry(path, mode, data, ino)
    out += entry("TRAILER!!!", 0, b"", 0)
    return out + b"\0" * (-len(out) % 4)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--init", required=True)
    parser.add_argument("--hook", default=str(ROOT / "assets" / "linux-iso" / "init-bottom"))
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    hook = Path(args.hook).read_bytes().replace(b"\r\n", b"\n")
    data = build(Path(args.init).read_bytes(), hook)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(data)
    print(f"[PASS] {out} ({len(data)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
