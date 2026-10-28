# SPDX-License-Identifier: GPL-3.0-or-later
"""Own ISO geometry and independent AL collection, without mounting images."""
import importlib.util
from pathlib import Path
import struct
import sys
import unittest
from unittest.mock import patch

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'tools/minios'))
spec=importlib.util.spec_from_file_location('ntfs_fragmented_case',REPO/'tools/minios/ntfs_fragmented_case.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)


class FragmentedSourceTests(unittest.TestCase):
    def test_own_iso_is_small_real_joliet_with_consistent_declared_size(self):
        data=m.own_iso()
        self.assertEqual(len(data),2*1024*1024)
        for lba in (16,17):
            self.assertEqual(data[lba*2048+1:lba*2048+7],b'CD001\x01')
            self.assertEqual(struct.unpack_from('<I',data,lba*2048+80)[0],1024)
            self.assertEqual(struct.unpack_from('>I',data,lba*2048+84)[0],1024)
        self.assertEqual(data[17*2048+88:17*2048+91],b'%/E')

    def test_independent_parser_closes_file_when_bad_reference_is_refused(self):
        class File:
            closed=False
            def close(self):self.closed=True
        class Image:
            file=File()
            def file_extents(self,_):raise ValueError('Invalid NTFS reference')
        image=Image()
        with patch.object(m.inspect,'Image',return_value=image):
            with self.assertRaisesRegex(ValueError,'Invalid NTFS reference'):
                m.independent(Path('own.raw'),999)
        self.assertTrue(image.file.closed)


if __name__=='__main__':unittest.main()
