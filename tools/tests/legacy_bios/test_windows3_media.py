from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))
from dos_media_fat12 import files
from flat_iso9660 import build

class MediaTests(unittest.TestCase):
    def test_iso_extents_preserve_files_across_directory_blocks(self):
        expected = {f'F{i:04}.EXE': bytes([i % 256]) * (i * 43) for i in range(160)}
        data = build(expected)
        self.assertEqual(len(data) // 2048, struct.unpack_from('<I', data, 16 * 2048 + 80)[0])
        self.assertEqual(len(data) // 2048, struct.unpack_from('>I', data, 16 * 2048 + 84)[0])
        pos = 20 * 2048
        limit = pos + struct.unpack_from('<I', data, 16 * 2048 + 166)[0]
        recovered = {}
        while pos < limit:
            length = data[pos]
            if not length:
                pos = (pos // 2048 + 1) * 2048
                continue
            self.assertLessEqual(pos % 2048 + length, 2048)
            if data[pos + 25] & 2 == 0:
                name = data[pos + 33:pos + 33 + data[pos + 32]].decode().split(';')[0]
                lba, = struct.unpack_from('<I', data, pos + 2)
                size, = struct.unpack_from('<I', data, pos + 10)
                recovered[name] = data[lba * 2048:lba * 2048 + size]
            pos += length
        self.assertEqual(expected, recovered)

    def test_rejects_unsafe_iso_names_and_non_floppy_input(self):
        for name in ('../IO.SYS', 'LONGFILENAME.EXE', 'FILE NAME.COM', 'A/B.COM'):
            with self.assertRaises(ValueError):
                build({name: b'file'})
        for data in (b'', bytes(1474560)):
            with self.assertRaises(ValueError):
                list(files(data))

if __name__ == '__main__':
    unittest.main()
