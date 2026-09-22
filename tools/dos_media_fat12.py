"""Read a flat DOS 1.44 MiB FAT12 disk without mounting it on the host."""
import struct


def files(data: bytes):
    def u16(offset):
        return struct.unpack_from('<H', data, offset)[0]
    if (len(data) != 1474560 or data[510:512] != b'\x55\xaa' or
            u16(11) != 512 or data[13] != 1 or u16(14) != 1 or data[16] != 2 or
            u16(17) != 224 or u16(19) != 2880 or u16(22) != 9):
        raise ValueError('Expected a 1.44 MiB FAT12 disk')
    if data[512:5120] != data[5120:9728]:
        raise ValueError('The two FAT copies differ')
    for pos in range(19 * 512, 33 * 512, 32):
        entry = data[pos:pos + 32]
        if entry[0] == 0:
            return
        if entry[0] == 0xe5 or entry[11] & 8:
            continue
        if entry[11] & 0x10:
            raise ValueError('Nested diskette directories are not supported')
        name = entry[:8].decode('ascii').rstrip()
        extension = entry[8:11].decode('ascii').rstrip()
        if extension:
            name += '.' + extension
        if not name or any(ch not in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-$~!#%&'()@^`{}" for ch in name):
            raise ValueError('Unsupported DOS filename: ' + repr(name))
        length = struct.unpack_from('<I', entry, 28)[0]
        cluster = struct.unpack_from('<H', entry, 26)[0]
        output = bytearray()
        visited = set()
        while len(output) < length:
            if not 2 <= cluster < 2849 or cluster in visited:
                raise ValueError('Invalid FAT12 chain for ' + name)
            visited.add(cluster)
            start = 33 * 512 + (cluster - 2) * 512
            output.extend(data[start:start + min(512, length - len(output))])
            word = u16(512 + cluster * 3 // 2)
            cluster = (word >> 4 if cluster & 1 else word) & 0xfff
        if length and cluster < 0xff8:
            raise ValueError('FAT12 chain length differs from directory size: ' + name)
        yield name, bytes(output)
