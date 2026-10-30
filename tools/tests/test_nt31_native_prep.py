# SPDX-License-Identifier: GPL-3.0-or-later
from pathlib import Path
import importlib.util
import subprocess
import unittest

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('nt31_native_source',ROOT/'tools/nt31_native_source.py')
source=importlib.util.module_from_spec(spec);spec.loader.exec_module(source)

class Source(unittest.TestCase):
    def test_literals_round_trip(self):
        for n in (0,1,7,8,9,4095,4096,8192):
            data=bytes(i%256 for i in range(n))
            self.assertEqual(source.unpack(source.pack(data)),data)
    def test_overlap_match(self):
        data=source.MAGIC+b'F'+(6).to_bytes(4,'little')+bytes((1,ord('a'),0xf0,0xf2))
        self.assertEqual(source.unpack(data),b'aaaaaa')
    def test_truncated_and_oversized(self):
        encoded=source.pack(b'example')
        for i in range(len(encoded)):
            with self.assertRaises(ValueError):source.unpack(encoded[:i])
        with self.assertRaises(ValueError):source.unpack(source.MAGIC+b'F'+(source.MAX_SIZE+1).to_bytes(4,'little'))
        with self.assertRaises(ValueError):source.unpack(encoded+b'junk')
    def test_unsupported_method(self):
        with self.assertRaises(ValueError):source.unpack(b'MSCF'+bytes(40))
        with self.assertRaises(ValueError):source.unpack(source.pack(b'x').replace(b'3A',b'3B',1))
    def test_protected_351_binary(self):
        rel='tools/nt/usosnet/bin/i386/usosnet351n.sys'
        self.assertEqual((ROOT/rel).read_bytes(),subprocess.check_output(['git','show','2d7f2a23:'+rel],cwd=ROOT,timeout=10))
    def test_unknown_inf_refused(self):
        shell=r'C:\Program Files\Git\usr\bin\sh.exe'
        if not Path(shell).is_file(): self.skipTest('Explicit Git sh unavailable')
        with self.assertRaises(ValueError):source.patch(b'[Unknown]\r\n','initial',shell=shell)
    def test_unsafe_profile_refused(self):
        with self.assertRaises(ValueError):source.patch(b'[Unknown]','initial',owner='a"b')
    def test_native_route_stays_closed_until_input_hook(self):
        text=(ROOT/'tools/w9x_csmwrap_prepare.sh').read_text()
        self.assertNotIn('NT31|NT31S) nt_native_flag',text)
    def test_hook_copy_64mib_and_identity_guard(self):
        sector=bytes(510)+b'U3'
        out=source.hook_for_nt31(sector)
        self.assertEqual((out[508],out[509]),(4,0))
        self.assertEqual(sector,bytes(510)+b'U3')
        with self.assertRaises(ValueError):source.hook_for_nt31(bytes(512))
    def test_gui_uses_original_control_ids_and_no_getversionex(self):
        src=(ROOT/'tools/nt3/native31/usosans31.c').read_text()
        self.assertIn('control(w,740,"ComboBox")',src)
        self.assertIn('IsDlgButtonChecked(w,1213)',src)
        self.assertIn('SetDlgItemTextA(w,1211,domain)',src)
        self.assertNotIn('GetVersionExA(',src)
    def test_generic_finish_refuses_nt31_before_usb_start_one(self):
        src=(ROOT/'tools/nt3/usosnt3/src/usosnt3.c').read_text()
        block=src[src.index('if (lstrcmpA(opt, "finish") == 0)'):]
        self.assertLess(block.index('GetVersion() & 0xFFFFUL'),block.index('usb_early();'))
        self.assertLess(block.index('ExitProcess(3);'),block.index('open_log("POST.LOG")'))

if __name__=='__main__':unittest.main()
