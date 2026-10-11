"""ReactOS / own BIOS image behind CSMWrap: the ELCR MBR step of
tools/image_disk_target.sh (elcr_fix) and its build wiring
(src/platform/bios/reactos/elcr_mbr.S, docs/custom-os-2026-10-11.md 3.1).
Host only: Git sh on a temp file standing in for the disk; no VM, no disk.
"""
from pathlib import Path
import os
import shutil
import tempfile
import unittest

from test_nt4_flow import function_text
from test_w9x_phase1_qemu import sh

ROOT = Path(__file__).resolve().parents[2]
TARGET = ROOT / 'tools/image_disk_target.sh'


class ElcrMbr(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='usos-elcr-'))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        (self.tmp / 'lib').mkdir()
        (self.tmp / 'work').mkdir()
        self.stub = bytes((i * 7 + 1) & 0xFF or 1 for i in range(440))
        (self.tmp / 'lib' / 'elcr-mbr-440.bin').write_bytes(self.stub)
        self.mbr = bytes(range(256)) * 2
        self.mbr = self.mbr[:510] + b'\x55\xaa'
        self.disk = self.tmp / 'disk.raw'

    def run_fix(self, lba1=b'\0' * 512):
        self.disk.write_bytes(self.mbr + lba1 + b'\xEE' * 4096)
        fn = function_text(TARGET, 'elcr_fix')
        script = (f'log() {{ printf "[IMAGE_DISK] %s\\n" "$*"; }}\n'
                  f'fail() {{ printf "STOP: %s\\n" "$1"; exit 1; }}\n'
                  f'TARGET_DEVICE="{self.disk.as_posix()}"; LIB="{(self.tmp / "lib").as_posix()}"; '
                  f'work="{(self.tmp / "work").as_posix()}"\n{fn}\nelcr_fix')
        rc, out, err = sh(script)
        self.assertEqual(rc, 0, out + err)
        return out

    def test_stub_in_front_image_mbr_at_lba1(self):
        out = self.run_fix()
        self.assertIn('ELCR MBR written', out)
        data = self.disk.read_bytes()
        self.assertEqual(data[:440], self.stub)
        self.assertEqual(data[440:512], self.mbr[440:])   # signature, table, 55AA kept
        self.assertEqual(data[512:1024], self.mbr)         # the image MBR, unchanged
        self.assertEqual(data[1024:], b'\xEE' * 4096)

    def test_lba1_in_use_is_left_alone(self):
        out = self.run_fix(lba1=b'\0' * 100 + b'\x01' + b'\0' * 411)
        self.assertIn('LBA 1 is in use', out)
        self.assertEqual(self.disk.read_bytes()[:512], self.mbr)

    def test_missing_stub_keeps_the_image(self):
        os.remove(self.tmp / 'lib' / 'elcr-mbr-440.bin')
        out = self.run_fix()
        self.assertIn('missing', out)
        self.assertEqual(self.disk.read_bytes()[:1024], self.mbr + b'\0' * 512)

    def test_only_reactos_and_own_images_after_the_esp(self):
        text = TARGET.read_text(encoding='utf-8')
        esp = text.index('sh "$LIB/xp_csmwrap_esp.sh"')
        call = text.index('case "$SYSTEM" in reactos|other-os) elcr_fix ;; esac')
        self.assertLess(esp, call)   # the stub copies the final partition table

    def test_build_wiring(self):
        src = (ROOT / 'src/platform/bios/reactos/elcr_mbr.S').read_text(encoding='utf-8')
        for want in ('0x0CF8', '0x04D0', '0xDEF8', 'mov cx, 0x0002', '0xAA55'):
            self.assertIn(want, src)
        self.assertIn("elcr-mbr-440.bin", (ROOT / 'tools/build_xp_geometry_fix_mbr.ps1').read_text(encoding='utf-8'))
        self.assertIn('usr/lib/usos/elcr-mbr-440.bin', (ROOT / 'tools/build_micro_linux.py').read_text(encoding='utf-8'))


if __name__ == '__main__':
    unittest.main()
