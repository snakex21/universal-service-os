"""tools/win3x_logo_patch.py: site matching on a synthetic logo image (and
on the same image inside a WIN.COM-style concatenation), and Unicorn
emulation of both logo helpers with the planar VGA model of
test_usosvgar.py: original and patched helpers give the same registers,
flags, port writes, RAM and VGA planes/latches on a faithful VGA; on the
X470 fault model (latches of a locked read come from byte offset|3) the
original differs and the patched helpers still give the faithful result.

USOS_WIN3X_LGO may name the user's own VGALOGO.LGO / WIN.COM (os.pathsep
separated) to run the same emulation over the real file; those files are
never part of the repository.
"""
from pathlib import Path
import os
import random
import sys
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import win3x_logo_patch as lp                      # noqa: E402
from test_win3x_vga_patch import Cpu, make_vga, MODES, RAMSEG  # noqa: E402

A, B = 0x3cb, 0x3d6


def synthetic_logo():
    """0x500-byte image: 'LOGO' + the two pointer loads at 020F + the
    helpers at 03CB/03D6 (the byte form the patcher matches), rest NOPs."""
    img = bytearray(b'\x90' * 0x500)
    img[0:4] = b'LOGO'
    img[0x20f:0x20f + 12] = (b'\xb8' + A.to_bytes(2, 'little') + b'\x89\x46\xca'
                             + b'\xb8' + B.to_bytes(2, 'little') + b'\x89\x46\xc8')
    img[A:A + len(lp.ORIG_HELPERS)] = lp.ORIG_HELPERS
    return bytes(img)


def caller(img, target):
    """Image + a driver at its end: call target / (stop address)."""
    at = len(img)
    rel = (target - (at + 3)) & 0xffff
    return img + b'\xe8' + rel.to_bytes(2, 'little') + b'\x90', at, at + 3


def helper_ptrs(img):
    """(A, B) as the logo code loads them."""
    m = lp.PTR_RE.search(img)
    return tuple(int.from_bytes(m.group(k), 'little') for k in (1, 2))


def run_helper(img, which, seed, mode, fault):
    target = helper_ptrs(img)[which]
    code, start, stop = caller(img, target)
    vga = make_vga(seed, mode, fault)
    vga.out(0x3ce, 8)                       # GC index: bit mask, as the logo code leaves it
    cpu = Cpu(code, vga, seed)
    rnd = random.Random(seed ^ 0x5a5a)
    regs = [rnd.getrandbits(16) for _ in range(8)]
    regs[3] = 0x3cf                         # DX: GC data port (helper A)
    regs[5] = rnd.randrange(0, 0xfff0)      # DI
    regs[7] = 0xff00                        # SP
    st = cpu.run(start, stop, regs, RAMSEG)
    return st


def check_image(tc, orig, patched, n=40):
    for which in (0, 1):
        differs = 0
        for seed in range(n):
            mode = MODES[seed % len(MODES)]
            good = run_helper(orig, which, seed, mode, False)
            tc.assertEqual(run_helper(patched, which, seed, mode, False), good,
                           f'helper {which} seed {seed}: patched != original (faithful VGA)')
            tc.assertEqual(run_helper(patched, which, seed, mode, True), good,
                           f'helper {which} seed {seed}: patched wrong on the fault model')
            differs += run_helper(orig, which, seed, mode, True) != good
        tc.assertGreater(differs, n // 2, f'helper {which}: fault model does not hit the original')


class SyntheticLogoTest(unittest.TestCase):
    def test_sites_and_bytes(self):
        img = synthetic_logo()
        out, sites, base = lp.patch(img)
        self.assertEqual(base, 0)
        self.assertEqual([o for o, _ in sites], [A + 4, A + 12, 0x216])
        self.assertEqual(helper_ptrs(out), (A, A + len(lp.NEW_A)))
        self.assertEqual(out[A:A + 17], lp.NEW_A + lp.NEW_B + b'\x90' * 3)
        diff = [i for i in range(len(img)) if img[i] != out[i]]
        self.assertTrue(all(A <= i < A + 17 or i in (0x216, 0x217) for i in diff))
        self.assertNotIn(b'\x26\x86', out)          # no xchg with ES left
        with self.assertRaisesRegex(lp.PatchError, 'already patched'):
            lp.patch(out)

    def test_wincom_concatenation(self):
        img = synthetic_logo()
        cnf, rle = b'\xeb\x45' + bytes(range(256)) * 3, b'BM' + bytes(4000)
        win = cnf + img + rle
        out, sites, base = lp.patch(win)
        self.assertEqual(base, len(cnf))
        self.assertEqual(out, cnf + lp.patch(img)[0] + rle)   # = COPY /B of the patched LGO

    def test_refuses_unknown(self):
        img = bytearray(synthetic_logo())
        img[0x210] ^= 1                              # pointer does not match the helpers
        with self.assertRaises(lp.PatchError):
            lp.patch(bytes(img))
        with self.assertRaises(lp.PatchError):
            lp.patch(synthetic_logo() * 2)           # helpers twice

    def test_emulation(self):
        img = synthetic_logo()
        check_image(self, img, lp.patch(img)[0])


@unittest.skipUnless(os.environ.get('USOS_WIN3X_LGO'), 'USOS_WIN3X_LGO not set')
class RealLogoTest(unittest.TestCase):
    def test_real_files(self):
        for name in os.environ['USOS_WIN3X_LGO'].split(os.pathsep):
            raw = Path(name).read_bytes()
            out, sites, base = lp.patch(raw)
            check_image(self, raw[base:base + 0x500], out[base:base + 0x500], n=24)


if __name__ == '__main__':
    unittest.main()
