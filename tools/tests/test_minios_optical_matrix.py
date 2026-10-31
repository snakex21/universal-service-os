# SPDX-License-Identifier: GPL-3.0-or-later
"""Sparse output safety and independent original-payload test plans."""
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'tools/minios'))
spec=importlib.util.spec_from_file_location('optical_matrix',REPO/'tools/minios/optical_matrix.py')
m=importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
TMP=REPO/'runtime/optical-unit-tmp'
TMP.mkdir(parents=True,exist_ok=True)


class OpticalMatrixTests(unittest.TestCase):
    def test_sparse_writer_keeps_unwritten_bytes_zero_and_refuses_overwrite(self):
        with tempfile.TemporaryDirectory(dir=TMP) as directory:
            output=Path(directory)/'own.iso'
            plan=dict(logical_bytes=65536,chunks=[(0,b'own'),(65530,b'ending')])
            m.write_sparse(plan,output)
            self.assertEqual(output.read_bytes(),b'own'+bytes(65527)+b'ending')
            with self.assertRaises(FileExistsError):m.write_sparse(plan,output)
            self.assertEqual(output.stat().st_size,65536)

    def test_sparse_writer_validates_size_offsets_and_path_before_creation(self):
        with tempfile.TemporaryDirectory(dir=TMP) as directory:
            output=Path(directory)/'never.iso'
            plans=[dict(logical_bytes=6*1024**3+1,chunks=[]),dict(logical_bytes=True,chunks=[]),
                   dict(logical_bytes=10,chunks=[(-1,b'bad')]),dict(logical_bytes=10,chunks=[(9,b'bad')]),
                   dict(logical_bytes=10,chunks=[(0,bytearray(b'bad'))])]
            for plan in plans:
                with self.subTest(plan=plan),self.assertRaises(ValueError):m.write_sparse(plan,output)
                self.assertFalse(output.exists())
            with self.assertRaises(ValueError):m.write_sparse(dict(logical_bytes=10,chunks=[]),Path('relative.iso'))
            with self.assertRaises(ValueError):m.write_sparse(dict(logical_bytes=10,chunks=[]),Path(directory)/'wrong.raw')

    def test_profiles_cover_declared_udf_layouts_and_corruption_classes(self):
        positives={name for name,*_ in m.profiles()}
        self.assertTrue({'iso','joliet','multi','multi-joliet','udf102','udf201','udf250','udf260',
                         'udf250-metadata','udf260-metadata','udf201-efe','udf260-efe-embedded',
                         'udf102-embedded','udf201-continuation','udf260-metadata-efe'}<=positives)
        errors={error for _,_,error in m.negative_profiles()}
        self.assertTrue({'DirectoryLoop','OpticalBounds','IsoEndianMismatch','UdfTagChecksum',
                         'UdfDescriptorCrc','UdfAllocationLoop','InvalidUdfPartition'}<=errors)


if __name__=='__main__':unittest.main()
