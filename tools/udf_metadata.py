"""Bounded read-only UDF metadata access, mirroring src/image_probe/udf.zig.

Only physical partition maps and recorded short/long allocation descriptors
are supported; unknown layouts fail instead of guessing offsets.
"""
import struct

LIMIT = 2 * 1024 * 1024


def u16(b, o): return struct.unpack_from('<H', b, o)[0]
def u32(b, o): return struct.unpack_from('<I', b, o)[0]
def u64(b, o): return struct.unpack_from('<Q', b, o)[0]


class UDF:
    def __init__(self, file):
        self.file = file
        self.file.seek(256 * 2048)
        anchor = self.file.read(2048)
        if u16(anchor, 0) != 2:
            raise ValueError('No UDF anchor')
        length, lba = u32(anchor, 16) & 0x3fffffff, u32(anchor, 20)
        if not 2048 <= length <= LIMIT:
            raise ValueError('Invalid UDF descriptor sequence')
        parts, maps, fsd = {}, [], None
        for offset in range(lba * 2048, lba * 2048 + length, 2048):
            b = self._at(offset, 2048)
            if u16(b, 0) == 5:
                parts[u16(b, 22)] = u32(b, 188) * 2048
            if u16(b, 0) == 6:
                self.block = u32(b, 212)
                fsd = self._ad(b, 248)
                start = 440
                for _ in range(u32(b, 268)):
                    if b[start:start + 2] != b'\x01\x06':
                        raise ValueError('Unsupported UDF partition map')
                    maps.append(u16(b, start + 4))
                    start += 6
            if u16(b, 0) == 8:
                break
        if not fsd or self.block not in (512, 1024, 2048, 4096):
            raise ValueError('Invalid UDF logical volume')
        self.starts = [parts[n] for n in maps]
        descriptor = self._at(self._absolute(fsd), self.block)
        if u16(descriptor, 0) != 256:
            raise ValueError('Invalid UDF file set')
        root = self._node(self._ad(descriptor, 400))
        self.entries = {}
        self._walk('', root, set())

    def _at(self, offset, length):
        if length < 0 or length > LIMIT:
            raise ValueError('UDF metadata bound exceeded')
        self.file.seek(offset)
        b = self.file.read(length)
        if len(b) != length:
            raise ValueError('Truncated UDF metadata')
        return b

    @staticmethod
    def _ad(b, o): return u32(b, o + 4), u16(b, o + 8)
    def _absolute(self, ad): return self.starts[ad[1]] + ad[0] * self.block

    def _node(self, ad):
        b = self._at(self._absolute(ad), self.block)
        tag = u16(b, 0)
        if tag not in (261, 266):
            raise ValueError('Unsupported UDF file entry')
        extended = tag == 266
        start = (216 if extended else 176) + u32(b, 208 if extended else 168)
        length = u32(b, 212 if extended else 172)
        if start + length > self.block:
            raise ValueError('Invalid UDF allocation length')
        size, directory, kind = u64(b, 56), b[27] == 4, u16(b, 34) & 7
        if kind == 3:
            return ([(None, b[start:start + length])], size, directory)
        stride = {0: 8, 1: 16}.get(kind)
        if not stride or length % stride:
            raise ValueError('Unsupported UDF allocations')
        extents = []
        for o in range(start, start + length, stride):
            encoded = u32(b, o)
            if encoded >> 30:
                raise ValueError('Unrecorded UDF extent')
            offset = self.starts[ad[1]] + u32(b, o + 4) * self.block if kind == 0 else self._absolute(self._ad(b, o))
            extents.append((offset, encoded & 0x3fffffff))
        return extents, size, directory

    def _read_node(self, node, offset, length):
        extents, size, _ = node
        if min(offset, length) < 0 or length > LIMIT or offset + length > size:
            raise ValueError('UDF read bound exceeded')
        result = bytearray()
        for absolute, n in extents:
            available = len(n) if absolute is None else n
            if offset >= available:
                offset -= available
                continue
            amount = min(length - len(result), available - offset)
            result += n[offset:offset + amount] if absolute is None else self._at(absolute + offset, amount)
            offset = 0
            if len(result) == length:
                return bytes(result)
        raise ValueError('Truncated UDF extents')

    def _walk(self, parent, node, seen):
        signature = repr(node[0])
        if signature in seen:
            return
        seen.add(signature)
        b = self._read_node(node, 0, node[1])
        pos = 0
        while pos + 38 <= len(b):
            if u16(b, pos) == 0:
                pos = (pos // self.block + 1) * self.block
                continue
            if u16(b, pos) != 257:
                raise ValueError('Invalid UDF directory entry')
            flags, count, extra = b[pos + 18], b[pos + 19], u16(b, pos + 36)
            end = pos + 38 + extra + count
            raw = b[pos + 38 + extra:end]
            ad = self._ad(b, pos + 20)
            pos = (end + 3) & ~3
            if flags & 12 or not raw:
                continue
            name = raw[1:].decode('latin-1' if raw[0] == 8 else 'utf-16-be').lower()
            relative = (parent + '/' + name).lstrip('/')
            child = self._node(ad)
            self.entries[relative] = child
            if child[2] and relative in ('sources', 'i386', 'amd64', 'setup', 'setup/wim'):
                self._walk(relative, child, seen)

    def read(self, name, offset=0, length=None):
        node = self.entries[name.lower()]
        return self._read_node(node, offset, node[1] - offset if length is None else length)
