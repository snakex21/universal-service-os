"""Mark a WDK 7.1 i386 driver build as an NT 4.0 image.

    python tools/nt4/pe_nt4_version.py DRIVER.sys

The WDK 7.1 linker writes at least 5.00 as the operating-system and
subsystem version even with /subsystem:native,4.00. This sets both to 4.00
in the PE optional header and recomputes the PE checksum (kernel images
carry one). Nothing else in the file changes. Used by the build-nt4.cmd
scripts (AHCINT, usosrst); idempotent.

Universal Service OS (USOS), GPL-3.0-or-later.
"""
from __future__ import annotations
from pathlib import Path
import struct, sys


def pe_checksum(b: bytes, field: int) -> int:
    total = 0
    data = b[:field] + b'\0\0\0\0' + b[field + 4:]
    if len(data) % 2:
        data += b'\0'
    for (w,) in struct.iter_unpack('<H', data):
        total += w
        total = (total & 0xffff) + (total >> 16)
    total = (total & 0xffff) + (total >> 16)
    return (total + len(b)) & 0xffffffff


def set_nt4(b: bytes) -> bytes:
    p = struct.unpack_from('<I', b, 60)[0]
    if b[p:p + 4] != b'PE\0\0' or struct.unpack_from('<H', b, p + 4)[0] != 0x14c:
        raise ValueError('not an i386 PE image')
    opt = p + 24
    if struct.unpack_from('<H', b, opt)[0] != 0x10b:
        raise ValueError('not a PE32 optional header')
    out = bytearray(b)
    struct.pack_into('<HH', out, opt + 40, 4, 0)   # Major/MinorOperatingSystemVersion
    struct.pack_into('<HH', out, opt + 48, 4, 0)   # Major/MinorSubsystemVersion
    struct.pack_into('<I', out, opt + 64, pe_checksum(bytes(out), opt + 64))
    return bytes(out)


def main() -> int:
    for name in sys.argv[1:]:
        path = Path(name)
        path.write_bytes(set_nt4(path.read_bytes()))
        print(f'{path}: PE OS/subsystem version 4.00')
    return 0 if len(sys.argv) > 1 else 2


if __name__ == '__main__':
    sys.exit(main())
