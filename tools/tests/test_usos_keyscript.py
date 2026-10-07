"""Host test: USOSKBC key scripts (tools/usos_keyscript.py, src/platform/bios/msdos/keys).

Every script compiles, fits the TSR's buffer, decodes back into whole ops,
has a DOS 8.3 name, and its key records carry matching make/break bytes.
Also the early-Windows mapping in tools/dos_csmwrap_target.sh names only
scripts that exist.
"""
from pathlib import Path
import re, struct, sys, unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import usos_keyscript as ks


def decode(data: bytes):
    assert data[:4] == b'UKS1'
    i, ops = 4, []
    while i < len(data):
        op = data[i]
        if op in (1, 5):
            n = data[i + 1]
            ops.append((op, data[i + 2:i + 2 + n].decode('ascii')))
            i += 2 + n
        elif op == 2:
            ops.append((op, struct.unpack_from('<H', data, i + 1)[0]))
            i += 3
        elif op == 3:
            n = data[i + 1]
            seq = data[i + 2:i + 2 + n]
            word = struct.unpack_from('<H', data, i + 2 + n)[0]
            ops.append((op, bytes(seq), word))
            i += 4 + n
        elif op == 4:
            ops.append((op,))
            i += 1
        else:
            raise AssertionError('unknown op %d at %d' % (op, i))
    assert i == len(data)
    return ops


class KeyScripts(unittest.TestCase):
    def test_all_scripts(self):
        sources = sorted(ks.SOURCES.glob('*.txt'))
        self.assertGreaterEqual(len(sources), 7)
        for src in sources:
            with self.subTest(src.name):
                self.assertRegex(src.stem, r'^[A-Z0-9]{1,8}$')
                data = ks.compile_script(src.read_text(encoding='ascii'))
                self.assertLess(len(data), 3072)
                ops = decode(data)
                self.assertTrue(any(o[0] == 1 for o in ops))
                for o in ops:
                    if o[0] != 3:
                        continue
                    seq = o[1].replace(b'\xe0', b'')
                    makes = [b for b in seq if b < 0x80]
                    breaks = [b & 0x7f for b in seq if b >= 0x80]
                    self.assertEqual(sorted(makes), sorted(breaks))

    def test_key_bytes(self):
        self.assertEqual(ks.key_bytes('enter'), bytes([3, 2, 0x1c, 0x9c]) + struct.pack('<H', 0x1c0d))
        self.assertEqual(ks.key_bytes('alt+p')[2:6], bytes([0x38, 0x19, 0x99, 0xb8]))
        self.assertEqual(ks.key_bytes('down')[2:6], b'\xe0\x50\xe0\xd0')
        self.assertEqual(struct.unpack_from('<H', ks.key_bytes('shift+a'), 6)[0], 0x1e41)

    def test_target_mapping(self):
        text = (ROOT / 'tools/dos_csmwrap_target.sh').read_text(encoding='utf-8')
        names = set(re.findall(r'key=(\w+)', text))
        self.assertTrue(names)
        for name in names:
            self.assertTrue((ks.SOURCES / (name + '.txt')).is_file(), name)


if __name__ == '__main__':
    unittest.main()
