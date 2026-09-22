"""GPT layout with one full-size partition, for disposable reset tests only."""
import struct
import uuid
import zlib


def write_gpt(path, size):
    last = size // 512 - 1
    table = bytearray(128 * 128)
    table[:16] = uuid.UUID('ebd0a0a2-b9e5-4433-87c0-68b6b72699c7').bytes_le
    table[16:32] = uuid.UUID('32108ea7-5683-488f-afcc-40d4735245cd').bytes_le
    struct.pack_into('<QQQ', table, 32, 2048, last - 2048, 0)
    name = 'OLD DATA'.encode('utf-16le')
    table[56:56 + len(name)] = name
    mbr = bytearray(512)
    struct.pack_into('<B3sB3sII', mbr, 446, 0, bytes(3), 238, b'\xff' * 3, 1, min(last, 0xffffffff))
    mbr[510:] = b'\x55\xaa'

    def header(current, backup, entries):
        result = bytearray(512)
        struct.pack_into('<8sIIIIQQQQ16sQIII', result, 0, b'EFI PART', 0x10000, 92, 0, 0,
                         current, backup, 34, last - 33,
                         uuid.UUID('b3c8ceaf-cf46-4a77-bdf6-cf6139cbdfef').bytes_le,
                         entries, 128, 128, zlib.crc32(table))
        struct.pack_into('<I', result, 16, zlib.crc32(result[:92]))
        return result

    with path.open('r+b') as handle:
        for offset, data in [(0, mbr), (512, header(1, last, 2)), (1024, table),
                             ((last - 32) * 512, table), (last * 512, header(last, 1, last - 32))]:
            handle.seek(offset); handle.write(data)
