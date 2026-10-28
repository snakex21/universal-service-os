"""Mark a WDK 7.1 i386 driver build as an NT 4.0 image.

    python tools/nt4/pe_nt4_version.py DRIVER.sys
    python tools/nt4/pe_nt4_version.py --version 3.10 PROGRAM.exe

The WDK 7.1 linker writes at least 5.00 as the operating-system and
subsystem version even with /subsystem:native,4.00. This sets both to 4.00
in the PE optional header and recomputes the PE checksum (kernel images
carry one). Nothing else in the file changes. Used by the build-nt4.cmd
scripts (AHCINT, usosrst); idempotent. --version M.mm writes another
version (NT 3.51 refuses programs marked newer than 3.51: the NT 3.51
builds use 3.10).

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


def set_nt4(b: bytes, major: int = 4, minor: int = 0) -> bytes:
    p = struct.unpack_from('<I', b, 60)[0]
    if b[p:p + 4] != b'PE\0\0' or struct.unpack_from('<H', b, p + 4)[0] != 0x14c:
        raise ValueError('not an i386 PE image')
    opt = p + 24
    if struct.unpack_from('<H', b, opt)[0] != 0x10b:
        raise ValueError('not a PE32 optional header')
    out = bytearray(b)
    struct.pack_into('<HH', out, opt + 40, major, minor)   # Major/MinorOperatingSystemVersion
    struct.pack_into('<HH', out, opt + 48, major, minor)   # Major/MinorSubsystemVersion
    struct.pack_into('<I', out, opt + 64, pe_checksum(bytes(out), opt + 64))
    return bytes(out)


def main() -> int:
    args = sys.argv[1:]
    major, minor = 4, 0
    if len(args) >= 2 and args[0] == '--version':
        major, minor = (int(x) for x in args[1].split('.'))
        args = args[2:]
    for name in args:
        path = Path(name)
        path.write_bytes(set_nt4(path.read_bytes(), major, minor))
        print(f'{path}: PE OS/subsystem version {major}.{minor:02d}')
    return 0 if args else 2


if __name__ == '__main__':
    sys.exit(main())
