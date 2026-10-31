# SPDX-License-Identifier: GPL-3.0-or-later
"""Semantic oracle normalization must preserve actual partition identities."""
import importlib.util
from pathlib import Path
import sys
import unittest

TOOLS = Path(__file__).resolve().parents[1] / 'minios'
sys.path.insert(0, str(TOOLS))
import bcd_compare as bcd


def fixture():
    manager, loader = bcd.oracle.GUID_BOOTMGR, bcd.oracle.GUID_LOADER
    tree = {f'objects\\{manager}\\description': {'type': (4, bytes.fromhex('02001010'))},
            f'objects\\{loader}\\description': {'type': (4, bytes.fromhex('03002010'))}}
    def elem(obj, code, kind, raw):
        tree[f'objects\\{obj}\\elements\\{code}'] = {'element': (kind, raw)}
    def text(obj, code, value):
        elem(obj, code, 1, (value + '\0').encode('utf-16le'))
    text(manager, '23000003', loader)
    elem(manager, '24000001', 7, (loader + '\0\0').encode('utf-16le'))
    text(manager, '12000005', 'pl-PL')
    text(loader, '12000005', 'pl-PL')
    text(loader, '12000002', '\\Windows\\system32\\winload.exe')
    text(loader, '22000002', '\\Windows')
    data = bytearray(88)
    data[16:20] = (6).to_bytes(4, 'little')
    data[24:28] = (72).to_bytes(4, 'little')
    data[32:40] = (1048576).to_bytes(8, 'little')
    data[52:56] = (1).to_bytes(4, 'little')
    data[56:60] = (0x12345678).to_bytes(4, 'little')
    for obj, code in [(manager, '11000001'), (loader, '11000001'), (loader, '21000001')]:
        elem(obj, code, 3, bytes(data))
    return tree


class BcdComparison(unittest.TestCase):
    def test_bios_default_path_and_winpe_false(self):
        tree = fixture()
        route = bcd.route(tree)
        self.assertEqual(route['manager_path'], '\\bootmgr')
        self.assertFalse(route['winpe'])
        self.assertEqual(route['windows']['signature'], 0x12345678)
        self.assertEqual(route['windows']['byte_offset'], 1048576)

    def test_actual_offset_difference_survives_normalization(self):
        tree = fixture()
        key = f'objects\\{bcd.oracle.GUID_LOADER}\\elements\\21000001'
        raw = bytearray(tree[key]['element'][1])
        raw[32:40] = (2097152).to_bytes(8, 'little')
        tree[key]['element'] = (3, bytes(raw))
        route = bcd.route(tree)
        self.assertNotEqual(route['windows'], route['osdevice'])

    def test_winpe_and_bad_default_display_refused(self):
        tree = fixture()
        key = f'objects\\{bcd.oracle.GUID_LOADER}\\elements\\26000022'
        tree[key] = {'element': (3, b'\1')}
        with self.assertRaisesRegex(ValueError, 'WinPE'):
            bcd.route(tree)
        del tree[key]
        tree[f'objects\\{bcd.oracle.GUID_BOOTMGR}\\elements\\24000001']['element'] = (7, b'\0\0\0\0')
        with self.assertRaisesRegex(ValueError, 'displayorder'):
            bcd.route(tree)

    def test_missing_uefi_manager_path_refused(self):
        tree = fixture()
        tree[f'objects\\{bcd.oracle.GUID_LOADER}\\elements\\12000002']['element'] = (1, '\\Windows\\system32\\winload.efi\0'.encode('utf-16le'))
        with self.assertRaisesRegex(ValueError, 'UEFI manager path'):
            bcd.route(tree)


if __name__ == '__main__':
    unittest.main()
