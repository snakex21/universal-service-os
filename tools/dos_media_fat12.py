"""Read a DOS FAT12 diskette image without mounting it on the host.

Formats: 360 KiB and 1.2 MiB (5.25"), 720 KiB and 1.44 MiB (3.5"). Files in
the root and one directory level below it (Windows 1.0x: PIF\\*.PIF) are
returned as 'NAME.EXT' or 'DIR/NAME.EXT'.
"""
import struct

# size: (sectors per cluster, root entries, sectors per FAT, media byte)
FORMATS = {
    368640: (2, 112, 2, 0xFD),
    737280: (2, 112, 3, 0xF9),
    1228800: (1, 224, 7, 0xF9),
    1474560: (1, 224, 9, 0xF0),
}
ALLOWED = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-$~!#%&'()@^`{}"


def files(data: bytes):
    def u16(offset):
        return struct.unpack_from('<H', data, offset)[0]
    fmt = FORMATS.get(len(data))
    if (fmt is None or data[510:512] != b'\x55\xaa' or u16(11) != 512 or data[13] != fmt[0] or
            u16(14) != 1 or data[16] != 2 or u16(17) != fmt[1] or u16(19) != len(data) // 512 or
            u16(22) != fmt[2]):
        raise ValueError('Expected a 360 KiB, 720 KiB, 1.2 MiB or 1.44 MiB FAT12 disk')
    spc, root_entries, fat_sectors = fmt[0], fmt[1], fmt[2]
    fat = data[512:512 + fat_sectors * 512]
    if fat != data[512 + fat_sectors * 512:512 + 2 * fat_sectors * 512]:
        raise ValueError('The two FAT copies differ')
    root = 512 * (1 + 2 * fat_sectors)
    first = root + root_entries * 32
    clusters = (len(data) - first) // (spc * 512) + 2

    def chain(cluster, length, name):
        output = bytearray()
        visited = set()
        while length is None or len(output) < length:
            if not 2 <= cluster < clusters or cluster in visited:
                if length is None and cluster >= 0xff8:
                    break
                raise ValueError('Invalid FAT12 chain for ' + name)
            visited.add(cluster)
            start = first + (cluster - 2) * spc * 512
            take = spc * 512 if length is None else min(spc * 512, length - len(output))
            output.extend(data[start:start + take])
            word = struct.unpack_from('<H', fat, cluster * 3 // 2)[0]
            cluster = (word >> 4 if cluster & 1 else word) & 0xfff
        if length and cluster < 0xff8:
            raise ValueError('FAT12 chain length differs from directory size: ' + name)
        return bytes(output)

    def entries(raw, prefix, depth):
        for pos in range(0, len(raw), 32):
            entry = raw[pos:pos + 32]
            if entry[0] == 0:
                return
            if entry[0] == 0xe5 or entry[11] & 8 or entry[11] == 0x0f:
                continue
            name = entry[:8].decode('ascii').rstrip()
            extension = entry[8:11].decode('ascii').rstrip()
            if name in ('.', '..'):
                continue
            if extension:
                name += '.' + extension
            if not name or any(ch not in ALLOWED for ch in name):
                raise ValueError('Unsupported DOS filename: ' + repr(name))
            length = struct.unpack_from('<I', entry, 28)[0]
            cluster = struct.unpack_from('<H', entry, 26)[0]
            if entry[11] & 0x10:
                if depth:
                    raise ValueError('Nested diskette directories are not supported')
                yield from entries(chain(cluster, None, name), name + '/', depth + 1)
                continue
            yield prefix + name, chain(cluster, length, name) if length else b''

    yield from entries(data[root:first], '', 0)
