"""Synthetic REGF 1.1 bounds, old-cell addressing and exact DWORD edits."""
import importlib.util
from pathlib import Path
import struct
import unittest

spec = importlib.util.spec_from_file_location('regf11', Path(__file__).with_name('regf11.py'))
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)


def fixture():
    data = bytearray(8192)
    data[:4] = b'regf'
    struct.pack_into('<II', data, 4, 7, 7)
    struct.pack_into('<II', data, 20, 1, 1)
    struct.pack_into('<I', data, 40, 4096)
    data[4096:4100] = b'hbin'
    struct.pack_into('<II', data, 4100, 0, 4096)
    cursor = 4128
    locations = {}

    def cell(name, payload):
        nonlocal cursor
        size = (8 + len(payload) + 7) & ~7
        locations[name] = cursor
        struct.pack_into('<i', data, cursor, -size)
        data[cursor + 4:cursor + 8] = b'OLD!'
        data[cursor + 8:cursor + 8 + len(payload)] = payload
        cursor += size
        return locations[name] - 4096

    def nk(name):
        raw = name.encode('utf-16-le')
        value = bytearray(76 + len(raw))
        value[:2] = b'nk'
        struct.pack_into('<H', value, 72, len(raw))
        value[76:] = raw
        return value

    root = cell('root', nk('SYSTEM'))
    child = cell('child', nk('Select'))
    li = cell('li', b'li' + struct.pack('<HI', 1, child))
    external = cell('external', struct.pack('<I', 1))
    raw = 'hello\0'.encode('utf-16-le')
    text = cell('text', raw)
    offsets = []
    for name, length, where, kind in [('Current', 0x80000004, 1, 4), ('Default', 4, external, 4), ('Text', len(raw), text, 1), ('', 0, 0xffffffff, 0)]:
        encoded = name.encode('utf-16-le')
        vk = bytearray(20 + len(encoded))
        vk[:2] = b'vk'
        struct.pack_into('<HIII', vk, 2, len(encoded), length, where, kind)
        vk[20:] = encoded
        offsets.append(cell('vk' + name, vk))
    vl = cell('vl', struct.pack('<4I', *offsets))
    struct.pack_into('<I', data, locations['root'] + 8 + 20, 1)
    struct.pack_into('<I', data, locations['root'] + 8 + 28, li)
    struct.pack_into('<II', data, locations['child'] + 8 + 36, 4, vl)
    struct.pack_into('<I', data, 36, root)
    struct.pack_into('<i', data, cursor, len(data) - cursor)
    struct.pack_into('<I', data, 508, h.checksum(data))
    return data, locations


class Regf11Tests(unittest.TestCase):
    def test_original_offsets_read_inline_external_unicode_and_zero(self):
        data, _ = fixture()
        got = h.Hive11(data).values
        self.assertEqual(set(got), {'', 'select'})
        self.assertEqual(got['select'], {'current': (4, struct.pack('<I', 1)), 'default': (4, struct.pack('<I', 1)), 'text': (1, 'hello\0'.encode('utf-16-le')), '': (0, b'')})

    def test_existing_inline_and_external_dword_change_only_four_bytes(self):
        for name in ('Current', 'Default'):
            data, loc = fixture()
            changed, at = h.Hive11(data).replace_dword('SELECT', name, 1, 4)
            expected_at = loc['vkCurrent'] + 16 if name == 'Current' else loc['external'] + 8
            self.assertEqual(at, expected_at)
            expected = bytearray(data)
            struct.pack_into('<I', expected, at, 4)
            self.assertEqual(changed, expected)
            self.assertEqual(h.Hive11(changed).values['select'][name.lower()], (4, struct.pack('<I', 4)))

    def test_wrong_version_and_header_fail_closed(self):
        for at, value in ((24, 2), (8, 8), (508, 0)):
            data, _ = fixture()
            struct.pack_into('<I', data, at, value)
            with self.assertRaises(ValueError):
                h.Hive11(data)

    def test_truncated_or_free_cell_references_fail(self):
        for mutation in ('truncated', 'free', 'unaligned'):
            data, loc = fixture()
            if mutation == 'truncated': data = data[:-1]
            elif mutation == 'free': struct.pack_into('<i', data, loc['child'], 96)
            else: struct.pack_into('<i', data, loc['child'], -95)
            with self.assertRaises(ValueError):
                h.Hive11(data)

    def test_cycle_is_rejected_without_unbounded_traversal(self):
        data, loc = fixture()
        struct.pack_into('<I', data, loc['li'] + 12, loc['root'] - 4096)
        with self.assertRaisesRegex(ValueError, 'Cyclic'):
            h.Hive11(data)

    def test_oversized_inline_value_is_rejected(self):
        data, loc = fixture()
        struct.pack_into('<I', data, loc['vkCurrent'] + 12, 0x80000005)
        with self.assertRaisesRegex(ValueError, 'inline'):
            h.Hive11(data)

    def test_truncated_value_and_subkey_lists_are_rejected(self):
        for atname, relative in (('child', 36), ('root', 20)):
            data, loc = fixture()
            struct.pack_into('<I', data, loc[atname] + 8 + relative, 1000)
            with self.assertRaises(ValueError):
                h.Hive11(data)

    def test_wrong_or_missing_dword_never_changes_input(self):
        data, _ = fixture()
        original = bytes(data)
        for key, name, expected in [('select', 'current', 2), ('missing', 'current', 1), ('select', 'text', 1), ('select', 'missing', 1)]:
            with self.assertRaises(ValueError):
                h.Hive11(data).replace_dword(key, name, expected, 4)
            self.assertEqual(data, original)


if __name__ == '__main__':
    unittest.main()
