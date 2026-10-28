#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
import io,struct,sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'minios'))
import diagnostic_boot_overlay as overlay

def fixture(name,fmt,header_bytes=104):
    b=bytearray(512);b[:4]=b'QFI\xfb';struct.pack_into('>I',b,4,3)
    raw=name.encode();struct.pack_into('>QIIQ',b,8,256,len(raw),16,32*1024**3)
    struct.pack_into('>I',b,100,header_bytes);value=fmt.encode();struct.pack_into('>II',b,header_bytes,0xe2792aca,len(value));b[header_bytes+8:header_bytes+8+len(value)]=value
    b[256:256+len(raw)]=raw
    return b

class Tests(unittest.TestCase):
    def test_exact_backing_path_and_format(self):
        path=r'K:\case\base.vhdx';b=fixture(path,'vhdx')
        self.assertEqual(overlay.inspect_header(io.BytesIO(b),len(b),path,'vhdx')['backing'],path)
        for expected,fmt in ((r'K:\case\other.vhdx','vhdx'),(path,'qcow2')):
            with self.assertRaises(ValueError):overlay.inspect_header(io.BytesIO(b),len(b),expected,fmt)
    def test_unsupported_features_or_extension_rejected(self):
        path=r'K:\case\base.vhdx'
        for position in (72,104,100):
            b=fixture(path,'vhdx');b[position]^=1
            with self.assertRaises(ValueError):overlay.inspect_header(io.BytesIO(b),len(b),path,'vhdx')
    def test_112_byte_header_only_accepts_zero_extension(self):
        path=r'K:\case\base.vhdx';b=fixture(path,'vhdx',112)
        self.assertEqual(overlay.inspect_header(io.BytesIO(b),len(b),path,'vhdx')['format'],'vhdx')
        b[104]=1
        with self.assertRaisesRegex(ValueError,'header extension'):overlay.inspect_header(io.BytesIO(b),len(b),path,'vhdx')

if __name__=='__main__':unittest.main()
