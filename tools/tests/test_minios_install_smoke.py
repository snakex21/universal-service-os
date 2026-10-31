#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Own small ISO envelope shape; no media access or generated disk files."""
from pathlib import Path
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'minios'))
from install_smoke import own_wim_iso


class OwnIsoTests(unittest.TestCase):
    def test_bounded_wim_envelope_extends_descriptors_and_exact_file(self):
        payload=b'MSWIM\0\0\0'+bytes((i%251 for i in range(1_000_000)))
        iso=own_wim_iso(payload)
        self.assertEqual(len(iso)%2048,0)
        self.assertEqual(struct.unpack_from('<I',iso,16*2048+80)[0],len(iso)//2048)
        self.assertEqual(struct.unpack_from('>I',iso,16*2048+84)[0],len(iso)//2048)
        self.assertEqual(iso[28*2048:28*2048+len(payload)],payload)
        at=25*2048+68
        self.assertEqual(iso[at+33:at+33+iso[at+32]],b'INSTALL.WIM;1')
        self.assertEqual(struct.unpack_from('<I',iso,at+10)[0],len(payload))

    def test_empty_non_wim_and_large_payload_refused(self):
        for payload in (b'', b'notWIM00'+bytes(300), b'MSWIM\0\0\0'+bytes(8*1024**2)):
            with self.assertRaises(ValueError):own_wim_iso(payload)


if __name__=='__main__':unittest.main()
