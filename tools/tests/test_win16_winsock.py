# Copyright (C) 2026 Maksymilian and the USOS Authors
# SPDX-License-Identifier: GPL-3.0-or-later
"""Checks for the USOS Win16 Winsock 1.1 DLL (milestone 1 skeleton).

Two contracts are pinned here:

* ``src/platform/bios/win16/winsock16/winsock16.def`` must export every
  function the public Winsock 1.1 specification requires, with the ordinals
  from the specification appendix (accept=1 .. socket=23, the database calls
  51..57, the WSA extensions 101..116 and __WSAFDIsSet=151).
* when ``zig-out/win16/WINSOCK.DLL`` exists, its NE export table must contain
  the same names with the same ordinals.  Without the artifact the check
  skips (the toolchain is optional on developer machines).

A third test guards against redistributing Trumpet Winsock material: the
Trumpet disk is shareware/registered software that USOS must not ship, so no
file from it may appear in the tree.
"""
from __future__ import annotations

import re
import struct
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SRC_DIR = ROOT / 'src' / 'platform' / 'bios' / 'win16' / 'winsock16'
DEF_FILE = SRC_DIR / 'winsock16.def'
ARTIFACT = ROOT / 'zig-out' / 'win16' / 'WINSOCK.DLL'

SKIP_ARTIFACT = 'brak artefaktu WINSOCK.DLL - uruchom tools/build_win16_winsock.py'

# Winsock 1.1 specification, appendix "Name and ordinal".
WINSOCK11 = {
    1: 'accept', 2: 'bind', 3: 'closesocket', 4: 'connect', 5: 'getpeername',
    6: 'getsockname', 7: 'getsockopt', 8: 'htonl', 9: 'htons', 10: 'inet_addr',
    11: 'inet_ntoa', 12: 'ioctlsocket', 13: 'listen', 14: 'ntohl', 15: 'ntohs',
    16: 'recv', 17: 'recvfrom', 18: 'select', 19: 'send', 20: 'sendto',
    21: 'setsockopt', 22: 'shutdown', 23: 'socket',
    51: 'gethostbyaddr', 52: 'gethostbyname', 53: 'getprotobyname',
    54: 'getprotobynumber', 55: 'getservbyname', 56: 'getservbyport',
    57: 'gethostname',
    101: 'WSAAsyncSelect', 102: 'WSAAsyncGetHostByAddr',
    103: 'WSAAsyncGetHostByName', 104: 'WSAAsyncGetProtoByNumber',
    105: 'WSAAsyncGetProtoByName', 106: 'WSAAsyncGetServByPort',
    107: 'WSAAsyncGetServByName', 108: 'WSACancelAsyncRequest',
    109: 'WSASetBlockingHook', 110: 'WSAUnhookBlockingHook',
    111: 'WSAGetLastError', 112: 'WSASetLastError', 113: 'WSACancelBlockingCall',
    114: 'WSAIsBlocking', 115: 'WSAStartup', 116: 'WSACleanup',
    151: '__WSAFDIsSet',
}


def parse_def(path: Path) -> dict[str, int]:
    """Return {lowercase name: ordinal} for the EXPORTS section of a .def."""
    exports: dict[str, int] = {}
    in_exports = False
    for raw in path.read_text(encoding='utf-8', errors='replace').splitlines():
        line = raw.split(';', 1)[0].strip()
        if not line:
            continue
        if re.match(r'(?i)^EXPORTS\b', line):
            in_exports = True
            continue
        if not in_exports:
            continue
        match = re.match(r'(?i)^([A-Za-z_][\w@$?]*)\s+@(\d+)', line)
        if match:
            exports[match.group(1).lower()] = int(match.group(2))
    return exports
def parse_ne_exports(path: Path) -> dict[str, int]:
    """Return exact on-disk names; normalizing them would hide loader bugs."""
    data = path.read_bytes()
    ne = struct.unpack_from('<I', data, 0x3C)[0]
    if data[ne:ne + 2] != b'NE':
        raise AssertionError('%s is not an NE module' % path.name)

    exports: dict[str, int] = {}

    def read_names(offset: int) -> None:
        pos = offset
        while pos < len(data) and data[pos] != 0:
            length = data[pos]
            pos += 1
            assert pos + length + 2 <= len(data), 'truncated NE name entry'
            name = data[pos:pos + length].decode('latin1')
            assert '\x00' not in name, 'NE names have no NUL suffix'
            pos += length
            ordinal = struct.unpack_from('<H', data, pos)[0]
            pos += 2
            if ordinal:
                assert name not in exports or exports[name] == ordinal
                exports[name] = ordinal
        assert pos < len(data) and data[pos] == 0, 'unterminated NE names'

    read_names(ne + struct.unpack_from('<H', data, ne + 0x26)[0])
    read_names(struct.unpack_from('<I', data, ne + 0x2C)[0])
    return exports


TRUMPET_NAMES = {
    'winsock.dl_', 'twsk16.dl_', 'wsock32.dl_', 'tcpman.ex_', 'trumpwsk.hlp',
    'trumpdig.ex_', 'trumphop.ex_', 'trumping.ex_', 'tcpmeter.ex_', 'fimain.ex_',
    'llatsni.ex_', 'lzpunz.dll', 'disk1.img', 'install.hl_',
}


def test_def_covers_winsock_1_1() -> None:
    """The .def must carry every Winsock 1.1 export at its spec ordinal."""
    assert DEF_FILE.is_file(), 'missing %s' % DEF_FILE
    exports = parse_def(DEF_FILE)
    missing = [name for name in WINSOCK11.values() if name.lower() not in exports]
    assert not missing, 'def is missing Winsock 1.1 exports: %s' % ', '.join(missing)
    wrong = []
    for ordinal, name in WINSOCK11.items():
        actual = exports[name.lower()]
        if actual != ordinal:
            wrong.append('%s @%d (expected @%d)' % (name, actual, ordinal))
    assert not wrong, 'wrong ordinals: %s' % ', '.join(wrong)
    assert len(exports) >= len(WINSOCK11)


def test_dll_exports_match_def() -> None:
    """If the DLL was built, its NE exports must match the .def table."""
    if not ARTIFACT.is_file():
        pytest.skip(SKIP_ARTIFACT)
    exports = parse_ne_exports(ARTIFACT)
    assert all(name == name.upper() for name in exports), 'NE exports must be uppercase'
    wrong = []
    for ordinal, name in WINSOCK11.items():
        key = name.upper()
        if key not in exports:
            wrong.append('%s missing' % name)
        elif exports[key] != ordinal:
            wrong.append('%s @%d (expected @%d)' % (name, exports[key], ordinal))
    assert not wrong, 'WINSOCK.DLL export mismatch: %s' % ', '.join(wrong)


def test_no_trumpet_winsock_files() -> None:
    """Trumpet Winsock is proprietary: none of its files may be committed."""
    offenders = []
    for path in ROOT.rglob('*'):
        if not path.is_file() or '.git' in path.parts:
            continue
        name = path.name.lower()
        if name in TRUMPET_NAMES:
            offenders.append(str(path.relative_to(ROOT)))
    assert not offenders, 'Trumpet Winsock material in the tree: %s' % ', '.join(offenders)


def test_ne_names_use_absolute_nonresident_offset_and_preserve_case(tmp_path):
    # Deliberately different NE-relative and file-relative locations. Names
    # carry an exact byte count, no C NUL; the ordinal follows immediately.
    data = bytearray(0x280)
    struct.pack_into('<I', data, 0x3c, 0x80)
    data[0x80:0x82] = b'NE'
    struct.pack_into('<H', data, 0x80+0x26, 0x40)
    struct.pack_into('<I', data, 0x80+0x2c, 0x210)
    data[0xc0:0xc7] = b'\x03WEP\x00\x04\x00'
    data[0x210:0x21e] = b'\x0aWSAStartup\x73\x00\x00'
    path = tmp_path/'exports.dll'
    path.write_bytes(data)
    assert parse_ne_exports(path) == {'WEP': 1024, 'WSAStartup': 115}
