"""Validate the actual cold command adapter before starting a single VM."""
import importlib.util,json
from pathlib import Path
import unittest
s=importlib.util.spec_from_file_location('nt31_boot',Path(__file__).with_name('boot_nt31_fullmac.py'))
b=importlib.util.module_from_spec(s);s.loader.exec_module(b)
class ColdCommand(unittest.TestCase):
    def setUp(self):
        if not (b.SOURCE/'command.json').is_file():self.skipTest('Codex macierz-windows R19c evidence not on this host')
        self.prior=json.loads((b.SOURCE/'command.json').read_text(encoding='utf-8'))
    def test_exact_scoped_nic_and_retained_paths(self):
        cmd=b.command(self.prior,12345,['-object','owned-capture'])
        self.assertIn('igb,addr=0x05,netdev=usabilitynet,mac=52:54:00:55:53:01',cmd)
        self.assertNotIn('-nic',cmd)
        self.assertEqual(sum('file='+(b.WORK/'target.qcow2').as_posix() in v for v in cmd),1)
        self.assertFalse(any('file=G:/USOS-Kolekcja/_vm/r19c-' in v for v in cmd))
        self.assertIn('usb-kbd,id=coveragekbd,bus=xhci.0',cmd)
        self.assertEqual(cmd[cmd.index('-machine')+1],'q35')
        self.assertEqual(cmd[cmd.index('-smp')+1],'2')
    def test_mismatched_baseline_rejected(self):
        self.prior[self.prior.index('-machine')+1]='q35,i8042=off'
        with self.assertRaises(ValueError):b.command(self.prior,12345,[])
    def test_unexpected_existing_nic_rejected(self):
        self.prior+=['-device','igb,addr=0x06']
        with self.assertRaises(ValueError):b.command(self.prior,12345,[])
if __name__=='__main__':unittest.main()
