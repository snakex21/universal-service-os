"""Offline checks for the NT4 QEMU lab helper (no QEMU, no media, no keys)."""
import importlib.util
import struct
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('nt4lab', HERE / 'run_nt4_qemu_lab.py')
lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)


class Nt4LabTest(unittest.TestCase):
    def test_mbr_code_fits(self):
        self.assertLessEqual(len(lab.MBR_CODE), 440)
        self.assertEqual(lab.MBR_CODE[25:30], bytes.fromhex('ea1e060000'))  # far jmp to relocated code
        self.assertEqual(lab.MBR_CODE[-2:], b'\xcd\x18')

    def test_sif_local_source(self):
        sif = lab.winnt_sif('00000-OEM-0000000-00000', local_source=True)
        self.assertIn('MsDosInitiated = 1', sif)
        self.assertIn('Floppyless = 1', sif)
        self.assertIn('[GuiRunOnce]', sif)
        self.assertIn('MsDosInitiated = "0"', lab.winnt_sif('x'))

    def test_fat16_tree(self):
        with tempfile.TemporaryDirectory() as t:
            tree = Path(t) / 'tree'
            (tree / '$WIN_NT$.~LS' / 'I386').mkdir(parents=True)
            (tree / '$WIN_NT$.~LS' / 'I386' / 'TXTSETUP.SIF').write_bytes(b'x' * 70000)
            disk = Path(t) / 'd.raw'
            lab.fat16_disk(disk, 1, str(tree))
            b = disk.read_bytes()
            self.assertEqual(b[510:512], b'\x55\xaa')
            self.assertEqual(b[0:len(lab.MBR_CODE)], lab.MBR_CODE)
            start = struct.unpack_from('<I', b, 446 + 8)[0]
            self.assertEqual(b[446], 0x80)
            self.assertEqual(b[450], 0x06)
            vbr = b[start * 512:start * 512 + 512]
            self.assertEqual(vbr[54:62], b'FAT16   ')
            root = (start + 1 + 2 * 256) * 512
            self.assertEqual(b[root:root + 11], b'$WIN_NT$~LS')
            self.assertEqual(b[root + 11], 0x10)


if __name__ == '__main__':
    unittest.main()
