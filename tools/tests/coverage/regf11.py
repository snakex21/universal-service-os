"""Bounded in-memory REGF 1.1 reader for stopped NT 3.1/3.5 test disks.

Version 1.1 has four extra payload bytes in every allocated cell. It must
not be passed to the modern xp_hive reader/writer. This helper neither
loads host registry keys nor exports hives. Only an existing DWORD can be
changed, with a complete content and byte-difference check afterwards.
"""
import struct

HBIN = 4096
MAX_BYTES = 4 * 1024 * 1024


def checksum(data):
    value = 0
    for at in range(0, 508, 4):
        value ^= struct.unpack_from('<I', data, at)[0]
    return {0: 1, 0xffffffff: 0xfffffffe}.get(value, value)


class Hive11:
    def __init__(self, data):
        self.data = bytes(data)
        if not 8192 <= len(data) <= MAX_BYTES or data[:4] != b'regf':
            raise ValueError('Invalid bounded REGF file')
        if struct.unpack_from('<II', data, 20) != (1, 1):
            raise ValueError('Only REGF 1.1 is supported')
        if data[4:8] != data[8:12] or checksum(data) != self.u32(508):
            raise ValueError('Unclean hive or invalid header checksum')
        size = self.u32(40)
        if not size or size % 4096 or HBIN + size > len(data):
            raise ValueError('Invalid hive-bin area')
        self.cells = {}
        pos = HBIN
        while pos < HBIN + size:
            if data[pos:pos + 4] != b'hbin' or self.u32(pos + 4) != pos - HBIN:
                raise ValueError('Invalid hive bin')
            length = self.u32(pos + 8)
            if not length or length % 4096 or pos + length > HBIN + size:
                raise ValueError('Invalid hive-bin length')
            at, end = pos + 32, pos + length
            while at < end:
                length = struct.unpack_from('<i', data, at)[0]
                if not length or abs(length) % 8 or at + abs(length) > end:
                    raise ValueError('Invalid cell boundary')
                if length < 0:
                    if length > -8:
                        raise ValueError('Cell too short for REGF 1.1')
                    self.cells[at - HBIN] = (at + 8, at - length)
                at += abs(length)
            pos = end
        self.values = {}
        self.locations = {}
        self._read()

    def u32(self, at):
        return struct.unpack_from('<I', self.data, at)[0]

    def cell(self, offset, minimum=0):
        if offset not in self.cells:
            raise ValueError('Reference is not an allocated cell')
        start, end = self.cells[offset]
        if end - start < minimum:
            raise ValueError('Truncated cell payload')
        return self.data[start:end], start

    @staticmethod
    def name(data, compressed):
        return data.decode('latin1' if compressed else 'utf-16-le')

    def _read(self):
        stack = [(self.u32(36), '', 0)]
        visited = set()
        while stack:
            off, parent, depth = stack.pop()
            if off in visited or depth > 512 or len(visited) >= 50000:
                raise ValueError('Cyclic, shared or oversized key tree')
            visited.add(off)
            nk, _ = self.cell(off, 76)
            if nk[:2] != b'nk':
                raise ValueError('Invalid named-key signature')
            flags = struct.unpack_from('<H', nk, 2)[0]
            nlen = struct.unpack_from('<H', nk, 72)[0]
            if 76 + nlen > len(nk):
                raise ValueError('Truncated key name')
            name = self.name(nk[76:76 + nlen], flags & 32)
            if '\\' in name:
                raise ValueError('Ambiguous key name')
            path = parent + '\\' + name if parent else name
            rel = path.split('\\', 1)[1].lower() if '\\' in path else ''
            if rel in self.values:
                raise ValueError('Duplicate key path')
            values = self.values[rel] = {}
            count, vlist = struct.unpack_from('<II', nk, 36)
            if count > 65535:
                raise ValueError('Oversized value list')
            if count:
                entries, _ = self.cell(vlist, 4 * count)
                for i in range(count):
                    vk, at = self.cell(struct.unpack_from('<I', entries, 4 * i)[0], 20)
                    if vk[:2] != b'vk':
                        raise ValueError('Invalid value signature')
                    nlen = struct.unpack_from('<H', vk, 2)[0]
                    length, location, kind = struct.unpack_from('<III', vk, 4)
                    flag = struct.unpack_from('<H', vk, 16)[0]
                    if 20 + nlen > len(vk):
                        raise ValueError('Truncated value name')
                    name = self.name(vk[20:20 + nlen], flag & 1).lower()
                    if name in values:
                        raise ValueError('Duplicate value name')
                    if length & 0x80000000:
                        length &= 0x7fffffff
                        if length > 4:
                            raise ValueError('Oversized inline value')
                        value, address = vk[8:8 + length], at + 8
                    elif length:
                        external, address = self.cell(location, length)
                        value = external[:length]
                    else:
                        value, address = b'', None
                    values[name] = (kind, value)
                    self.locations[rel, name] = address
            count = struct.unpack_from('<I', nk, 20)[0]
            sublist = struct.unpack_from('<I', nk, 28)[0]
            if count > 50000:
                raise ValueError('Oversized subkey list')
            if count:
                entries, _ = self.cell(sublist, 4 + 4 * count)
                if entries[:2] != b'li' or struct.unpack_from('<H', entries, 2)[0] != count:
                    raise ValueError('Invalid REGF 1.1 subkey list')
                for i in reversed(range(count)):
                    stack.append((struct.unpack_from('<I', entries, 4 + 4 * i)[0], path, depth + 1))

    def replace_dword(self, key, name, expected, replacement):
        key, name = key.lower(), name.lower()
        wanted = (4, struct.pack('<I', expected))
        if self.values.get(key, {}).get(name) != wanted:
            raise ValueError('Existing DWORD does not match the expected value')
        at = self.locations[key, name]
        if at is None:
            raise ValueError('DWORD has no storage location')
        result = bytearray(self.data)
        result[at:at + 4] = struct.pack('<I', replacement)
        wanted = {k: dict(v) for k, v in self.values.items()}
        wanted[key][name] = (4, struct.pack('<I', replacement))
        if Hive11(result).values != wanted:
            raise ValueError('Unexpected hive content change')
        if result[:at] != self.data[:at] or result[at + 4:] != self.data[at + 4:]:
            raise ValueError('Unexpected bytes changed outside the DWORD')
        return bytes(result), at


def read_hive_content(data):
    return Hive11(data).values
