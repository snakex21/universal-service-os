#!/usr/bin/env python3
"""Read the boot variables out of an OVMF VARS file (QEMU tests only).

    python tools/tests/ovmf_vars.py OUT/vars.fd

Prints BootOrder, BootNext and every Boot#### (description and device path
in hex). Parses the EDK2 variable store behind the firmware volume header
(authenticated or plain variable headers); the last live copy of a variable
wins. Read only.
"""
from __future__ import annotations

import struct
import sys
import uuid
from pathlib import Path

GLOBAL = uuid.UUID('8be4df61-93ca-11d2-aa0d-00e098032b8c')
AUTH_STORE = uuid.UUID('aaf32c78-947b-439a-a180-2e144ec37792')
LIVE = (0x3F, 0x3E)  # VAR_ADDED, VAR_ADDED & VAR_IN_DELETED_TRANSITION


def variables(data: bytes) -> dict[tuple[uuid.UUID, str], tuple[int, bytes]]:
    header_length = struct.unpack_from('<H', data, 0x30)[0]
    store = header_length
    auth = uuid.UUID(bytes_le=data[store:store + 16]) == AUTH_STORE
    size = struct.unpack_from('<I', data, store + 16)[0]
    off = store + 28
    end = store + size
    result: dict[tuple[uuid.UUID, str], tuple[int, bytes]] = {}
    while off + 32 <= end:
        start_id, state, _, attributes = struct.unpack_from('<HBBI', data, off)
        if start_id != 0x55AA:
            break
        if auth:
            name_size, data_size = struct.unpack_from('<II', data, off + 36)
            guid = uuid.UUID(bytes_le=data[off + 44:off + 60])
            head = 60
        else:
            name_size, data_size = struct.unpack_from('<II', data, off + 8)
            guid = uuid.UUID(bytes_le=data[off + 16:off + 32])
            head = 32
        name = data[off + head:off + head + name_size].decode('utf-16-le').rstrip('\0')
        value = data[off + head + name_size:off + head + name_size + data_size]
        if state in LIVE:
            result[(guid, name)] = (attributes, value)
        off += head + name_size + data_size
        off = (off + 3) & ~3
    return result


def boot_summary(path: Path) -> dict[str, object]:
    found = variables(path.read_bytes())
    summary: dict[str, object] = {'entries': {}}
    for (guid, name), (_, value) in sorted(found.items(), key=lambda item: item[0][1]):
        if guid != GLOBAL:
            continue
        if name == 'BootOrder':
            summary['BootOrder'] = [f'{n:04X}' for n in struct.unpack(f'<{len(value) // 2}H', value)]
        elif name == 'BootNext':
            summary['BootNext'] = f'{struct.unpack("<H", value)[0]:04X}'
        elif len(name) == 8 and name.startswith('Boot') and all(c in '0123456789ABCDEF' for c in name[4:]):
            path_length = struct.unpack_from('<H', value, 4)[0]
            end = 6
            while value[end:end + 2] != b'\0\0':
                end += 2
            description = value[6:end].decode('utf-16-le')
            device_path = value[end + 2:end + 2 + path_length]
            summary['entries'][name[4:]] = (description, device_path.hex())
    return summary


def main() -> int:
    summary = boot_summary(Path(sys.argv[1]))
    print('BootOrder', ','.join(summary.get('BootOrder', [])))
    print('BootNext', summary.get('BootNext', '-'))
    for number, (description, device_path) in summary['entries'].items():
        print(f'Boot{number} {description!r} {device_path}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
