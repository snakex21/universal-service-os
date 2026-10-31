r"""Rebuilt NT 3.5x INF cabinets (cab.build, OEMNADLB.IN_ / INITIAL.IN_) use
fixed-Huffman blocks that NT 3.51's own text-mode decoder reads.

X470 2026-10-28 (B261028-204354): stored deflate blocks decoded by SETUPDD.SYS
as NLEN + data[:-2]; system32\OEMNADLB.INF began 08 96 "[Identification]" and
GUI Setup stopped with "non-existent section ... Identification".

- always: the cabinet written by nt3_cab_file.put (zig, own code) has only
  BTYPE 01 blocks and Python's zlib inflates them to the input;
- with USOS_NT351_SETUPDD = the CD's (expanded) SETUPDD.SYS: the real 3.51
  decoder under unicorn returns the input exactly, and reproduces the bug on
  a stored-block cabinet.
"""
from pathlib import Path
import os
import struct
import subprocess
import tempfile
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[2]
ZIG = ROOT / 'tools/zig/zig.exe'
MODULE = ROOT / 'src/compat/win3x/nt3_cab_file.zig'
SETUPDD = os.environ.get('USOS_NT351_SETUPDD', '')

WRAPPER = '''const std = @import("std");
const f = @import("nt3cab");
test "put" {
    try std.testing.expectEqual(@as(u8, 0), f.runPut(std.testing.io, std.testing.allocator, "orig.cab", "new.inf", "new.cab"));
}
'''


def stored_cab(name, data):
    """One-file MSCF 1.3 cabinet with one stored-block MSZIP CFDATA."""
    block = b'CK' + bytes([1]) + struct.pack('<HH', len(data), len(data) ^ 0xffff) + data
    files_off = 36 + 8
    data_off = files_off + 16 + len(name) + 1
    total = data_off + 8 + len(block)
    head = b'MSCF' + struct.pack('<IIIIIBBHHHHH', 0, total, 0, files_off, 0, 3, 1, 1, 1, 0, 0, 0)
    folder = struct.pack('<IHH', data_off, 1, 1)
    entry = struct.pack('<IIHHHH', len(data), 0, 0, 0x1eba, 0x5f20, 0x20) + name + b'\0'
    return head + folder + entry + struct.pack('<IHH', 0, len(block), len(data)) + block


def sample():
    lines = [b'[Identification]', b'    OptionType = NetAdapter', b'[InstallOption]']
    for i in range(700):
        lines.append(b'    set Line%d = "%s"' % (i, bytes([0x80 + i % 120]) * (i % 7)))
        if i % 50 == 0:
            lines.append(b'    ;USOS-NT351-LOOP-AUTO')
    return b'\r\n'.join(lines) + b'\r\n'


@unittest.skipUnless(ZIG.is_file(), 'tools/zig/zig.exe missing')
class FixedHuffmanCab(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = sample()
        cls.tmp = tempfile.TemporaryDirectory()
        d = Path(cls.tmp.name)
        (d / 'orig.cab').write_bytes(stored_cab(b'oemnadlb.inf', b'adapteroptions = +\r\n'))
        (d / 'new.inf').write_bytes(cls.data)
        (d / 'mk.zig').write_text(WRAPPER, newline='\n')
        subprocess.run([str(ZIG), 'test', '--dep', 'nt3cab', '-Mroot=mk.zig', '-Mnt3cab=' + str(MODULE)],
                       cwd=d, check=True, capture_output=True, timeout=110)
        cls.cab = (d / 'new.cab').read_bytes()

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def blocks(self):
        p = struct.unpack_from('<I', self.cab, 0x24)[0]
        for _ in range(struct.unpack_from('<H', self.cab, 0x28)[0]):
            _csum, cb, cu = struct.unpack_from('<IHH', self.cab, p)
            yield self.cab[p + 8:p + 8 + cb], cu
            p += 8 + cb

    def test_only_fixed_huffman_blocks_that_inflate(self):
        out = b''
        for block, cu in self.blocks():
            self.assertEqual(block[:2], b'CK')
            self.assertEqual(block[2] & 7, 3, 'BFINAL 1 + BTYPE 01 (fixed Huffman)')
            self.assertLessEqual(len(block), 32768 + 12)
            got = zlib.decompress(block[2:], -15)
            self.assertEqual(len(got), cu)
            out += got
        self.assertEqual(out, self.data)

    @unittest.skipUnless(SETUPDD and Path(SETUPDD).is_file(), 'USOS_NT351_SETUPDD not set')
    def test_real_nt351_text_mode_decoder(self):
        import sys
        sys.path.insert(0, str(ROOT / 'tools/nt3/mszipcheck'))
        import setupdd_mszip
        self.assertEqual(setupdd_mszip.decode(SETUPDD, self.cab), self.data)
        # the old writer's stored block: NLEN comes out as data, the end is lost
        broken = setupdd_mszip.decode(SETUPDD, stored_cab(b'x.inf', self.data[:4000]))
        self.assertEqual(broken, struct.pack('<H', 4000 ^ 0xffff) + self.data[:3998])


if __name__ == '__main__':
    unittest.main()
