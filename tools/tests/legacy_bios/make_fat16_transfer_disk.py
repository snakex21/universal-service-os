"""Small raw test disk (MBR + one FAT16 partition, 8.3 files in the root) that
MS-DOS sees as the next drive letter: moves test files into a QEMU guest.

  python make_fat16_transfer_disk.py OUT.img FILE [FILE ...]

Disposable image files only (docs/design/bios-via-csmwrap.md tests).
"""
from pathlib import Path
import struct, sys

TOTAL = 32 * 2048          # 32 MiB disk
START = 63
PART = TOTAL - START
SPC, RESERVED, FATS, ROOT_ENTRIES = 4, 1, 2, 512
FAT_SECTORS = ((PART // SPC) * 2 + 511) // 512 + 1
DATA = RESERVED + FATS * FAT_SECTORS + ROOT_ENTRIES * 32 // 512


def main():
    out, files = Path(sys.argv[1]), [Path(p) for p in sys.argv[2:]]
    disk = bytearray(TOTAL * 512)
    mbr = bytearray(512)
    mbr[446:462] = bytes([0x00, 1, 1, 0, 0x06, 0xFE, 0xFF, 0xFF]) + struct.pack('<II', START, PART)
    mbr[510:512] = b'\x55\xAA'
    disk[0:512] = mbr
    base = START * 512
    boot = bytearray(512)
    boot[0:3] = b'\xEB\x3C\x90'
    boot[3:11] = b'USOSTEST'
    struct.pack_into('<HBHBHHBHHHII', boot, 11, 512, SPC, RESERVED, FATS, ROOT_ENTRIES, 0, 0xF8, FAT_SECTORS, 63, 16, START, PART)
    boot[36], boot[38] = 0x80, 0x29
    boot[43:54], boot[54:62] = b'TRANSFER   ', b'FAT16   '
    boot[510:512] = b'\x55\xAA'
    disk[base:base + 512] = boot
    fat = [0xFFF8, 0xFFFF]
    root = bytearray()
    cluster_bytes = SPC * 512
    for f in files:
        data = f.read_bytes()
        stem, _, ext = f.name.upper().partition('.')
        assert len(stem) <= 8 and len(ext) <= 3, f.name
        count = max(1, -(-len(data) // cluster_bytes))
        first = len(fat)
        fat += [first + i + 1 if i + 1 < count else 0xFFFF for i in range(count)]
        off = base + (DATA + (first - 2) * SPC) * 512
        disk[off:off + len(data)] = data
        e = bytearray(32)
        e[0:11] = (stem.ljust(8) + ext.ljust(3)).encode()
        e[11] = 0x20
        struct.pack_into('<HHI', e, 24, (46 << 9) | (9 << 5) | 29, first, len(data))
        root += e
    fat_bytes = b''.join(struct.pack('<H', v) for v in fat).ljust(FAT_SECTORS * 512, b'\0')
    for i in range(FATS):
        off = base + (RESERVED + i * FAT_SECTORS) * 512
        disk[off:off + len(fat_bytes)] = fat_bytes
    off = base + (RESERVED + FATS * FAT_SECTORS) * 512
    disk[off:off + len(root)] = root
    out.write_bytes(disk)
    print(out, len(files), 'files')


if __name__ == '__main__':
    main()
