"""Compare packed icons against original RGBA pixels, including long runs."""
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))
from legacy_rgba_rle import encode
from generate_legacy_icons import rgba_bytes


def decode(encoded):
    output = bytearray()
    cursor = 0
    while cursor < len(encoded):
        control = encoded[cursor]
        cursor += 1
        if control == 0x7f:
            if encoded[cursor] & 128:
                count = (encoded[cursor] & 127) + 3
                distance = int.from_bytes(encoded[cursor + 1:cursor + 3], 'little') * 4
                cursor += 3
                assert distance and distance <= len(output)
                for _ in range(count * 4):
                    output.append(output[-distance])
                continue
            count = encoded[cursor] + 1
            cursor += 1
            assert count <= 128
            for _ in range(count):
                chunk = encoded[cursor:cursor + 3]
                assert len(chunk) == 3
                output.extend(chunk + b'\xff')
                cursor += 3
            continue
        count = (control & 127) + 1
        length = 4 if control & 128 else count * 4
        chunk = encoded[cursor:cursor + length]
        assert len(chunk) == length
        output.extend(chunk * count if control & 128 else chunk)
        cursor += length
    return bytes(output)


class TestIcons(unittest.TestCase):
    def test_all_source_icons_are_lossless(self):
        files = list((ROOT / 'media/UI/Icons/Systems').glob('*.png'))
        self.assertTrue(files)
        original_size = packed_size = 0
        for path in files:
            pixels = rgba_bytes(path)
            packed = encode(pixels)
            with self.subTest(icon=path.name):
                self.assertEqual(pixels, decode(packed))
            original_size += len(pixels)
            packed_size += len(packed)
        self.assertLess(packed_size, original_size)
        print(f'Icons: {original_size} original bytes, {packed_size} packed bytes')

    def test_boundaries(self):
        for count in (0, 1, 2, 127, 128, 129, 255, 256, 1024):
            for pixels in (b'\x01\x02\x03\x04' * count, bytes(range(256)) * count,
                           b''.join(bytes((i % 256, 2, 3, 255)) for i in range(count))):
                self.assertEqual(pixels, decode(encode(pixels)))
        with self.assertRaises(ValueError):
            encode(b'abc')


if __name__ == '__main__':
    unittest.main()
