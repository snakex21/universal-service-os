"""An old resource build must not override the kernel's real data variable."""
from pathlib import Path
import importlib.util
import struct
import unittest

spec=importlib.util.spec_from_file_location('inspection',Path(__file__).with_name('inspect_media.py'))
inspection=importlib.util.module_from_spec(spec);spec.loader.exec_module(inspection)


def sample():
    # Synthetic metadata-only PE; no Windows bytes, code or resources.
    b=bytearray(0x600);b[:2]=b'MZ';struct.pack_into('<I',b,0x3c,0x80)
    b[0x80:0x84]=b'PE\0\0';struct.pack_into('<HH',b,0x84,0x14c,1)
    struct.pack_into('<H',b,0x94,0xe0);struct.pack_into('<H',b,0x98,0x10b)
    struct.pack_into('<II',b,0x98+96,0x1000,0x100)
    struct.pack_into('<IIII',b,0x178+8,0x400,0x1000,0x400,0x200)
    for offset,value in ((0x214,1),(0x218,1),(0x21c,0x1040),(0x220,0x1044),(0x224,0x1048),(0x240,0x1200),(0x244,0x1050),(0x400,0xf0000421)):
        struct.pack_into('<I',b,offset,value)
    b[0x250:0x25e]=b'NtBuildNumber\0'
    return b


class KernelBuildTests(unittest.TestCase):
    def test_exported_data(self):
        self.assertEqual(inspection.nt_build_number(sample()),dict(rva=0x1200,raw=0xf0000421,build=1057))

    def test_forwarder_and_invalid_input_are_not_numbers(self):
        b=sample();struct.pack_into('<I',b,0x240,0x1060)
        self.assertIsNone(inspection.nt_build_number(b))
        self.assertIsNone(inspection.nt_build_number(b'MZ'))


if __name__ == '__main__':unittest.main()
