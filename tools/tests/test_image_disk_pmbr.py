"""Custom OS, step 620: a GPT image with a hybrid MBR (KolibriOS raw image)
gets a protective MBR (tools/image_disk_target.sh pmbr_fix), so firmware that
reads the MBR first still uses the GPT and the boot entry's GPT HD() node
(tools/uefi_boot_entry.sh) matches. X470 2026-10-12: KolibriOS was not started
first after the write, Haiku (a pure MBR image) was.

Also the deterministic disk clear before the write (start and end only, no
whole-disk scan) and the image size from stat instead of reading the image.
Host only: Git sh on a temp file standing in for the disk; no VM, no disk.
"""
from pathlib import Path
import shutil
import struct
import tempfile
import unittest

from test_nt4_flow import function_text
from test_w9x_phase1_qemu import sh

ROOT = Path(__file__).resolve().parents[2]
TARGET = ROOT / 'tools/image_disk_target.sh'


def mbr(slots, code=b'\xEB\x63' + b'\x90' * 438, signature=b'\0\0\0\0'):
    table = b''.join(slots) + b'\0' * 16 * (4 - len(slots))
    return code + signature + b'\0\0' + table + b'\x55\xaa'


def slot(boot, ptype, start, size):
    return bytes([boot, 0x20, 0x21, 0x00, ptype, 0x30, 0x20, 0x10]) + struct.pack('<II', start, size)


class ProtectiveMbr(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='usos-pmbr-'))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        (self.tmp / 'work').mkdir()
        self.disk = self.tmp / 'disk.raw'

    def run_fix(self, first, total=262144 * 4):
        self.disk.write_bytes(first + b'\xAB' * 4096)
        (self.tmp / 'work' / 'head.bin').write_bytes(first)
        fn = function_text(TARGET, 'pmbr_fix')
        script = (f'log() {{ printf "[IMAGE_DISK] %s\\n" "$*"; }}\n'
                  f'fail() {{ printf "STOP: %s\\n" "$1"; exit 1; }}\n'
                  f'u8() {{ od -An -tu1 -j"$2" -N1 "$1" | tr -d " \\n"; }}\n'
                  f'TARGET_DEVICE="{self.disk.as_posix()}"; total={total}; '
                  f'work="{(self.tmp / "work").as_posix()}"; head="$work/head.bin"\n{fn}\npmbr_fix')
        rc, out, err = sh(script)
        self.assertEqual(rc, 0, out + err)
        return out

    def test_kolibrios_hybrid_becomes_protective(self):
        # The KolibriOS 0.7.7.0 raw image: slot 1 EF (bootable) at 2048, slot 2 EE over LBA 1-2047.
        first = mbr([slot(0x80, 0xEF, 2048, 0x3F000), slot(0, 0xEE, 1, 0x7FF)])
        out = self.run_fix(first)
        self.assertIn('protective MBR', out)
        data = self.disk.read_bytes()
        self.assertEqual(data[:446], first[:446])          # boot code and signature kept
        self.assertEqual(data[446:462], bytes([0, 0, 2, 0, 0xEE, 0xFF, 0xFF, 0xFF]) + struct.pack('<II', 1, 262144 * 4 - 1))
        self.assertEqual(data[462:510], b'\0' * 48)
        self.assertEqual(data[510:512], b'\x55\xaa')
        self.assertEqual(data[512:], b'\xAB' * 4096)

    def test_size_is_capped_at_2_tib(self):
        first = mbr([slot(0x80, 0xEF, 2048, 4096), slot(0, 0xEE, 1, 2047)])
        self.run_fix(first, total=8 * 2**32)
        self.assertEqual(self.disk.read_bytes()[458:462], b'\xff\xff\xff\xff')

    def test_protective_mbr_is_left_alone(self):
        first = mbr([slot(0, 0xEE, 1, 0xFFFFFFFF)])
        out = self.run_fix(first)
        self.assertNotIn('protective MBR', out)
        self.assertEqual(self.disk.read_bytes()[:512], first)

    def test_called_for_gpt_images_in_uefi_mode_before_the_boot_entry(self):
        text = TARGET.read_text(encoding='utf-8')
        call = text.index('    pmbr_fix\n')
        self.assertIn('if [ "$gpt" = yes ] && [ "$mode" = uefi ]; then', text[call - 80:call])
        self.assertLess(text.index('sfdisk --relocate'), call)
        self.assertLess(call, text.index('sh "$LIB/uefi_boot_entry.sh" add'))


class FastWrite(unittest.TestCase):
    """Step 620 slowness (X470 2026-10-12, Haiku after KolibriOS): BusyBox
    `wc -c` reads the whole image (1.4 GB for Haiku) from the stick, twice
    (confirmation screen and the write); the size comes from stat now."""

    def test_image_size_from_stat(self):
        text = TARGET.read_text(encoding='utf-8')
        self.assertNotIn('wc -c < "$IMAGE"', text)
        self.assertIn('usos_file_bytes "$IMAGE"', text)
        prepare = (ROOT / 'tools/w9x_csmwrap_prepare.sh').read_text(encoding='utf-8')
        self.assertIn('stat -L -c %s "/mnt/data/$iso"', prepare)

    def test_file_bytes_helper(self):
        f = Path(tempfile.mkdtemp(prefix='usos-size-')) / 'img'
        self.addCleanup(shutil.rmtree, f.parent, ignore_errors=True)
        f.write_bytes(b'x' * 123457)
        fn = function_text(TARGET, 'usos_file_bytes')
        rc, out, err = sh(f'{fn}\nusos_file_bytes "{f.as_posix()}"')
        self.assertEqual((rc, out.strip()), (0, '123457'), err)

    def test_clear_is_start_and_end_only(self):
        text = TARGET.read_text(encoding='utf-8')
        for slow in ('blkdiscard', 'wipefs -a', 'partprobe', 'udevadm settle', 'count=$total'):
            self.assertNotIn(slow, text)


if __name__ == '__main__':
    unittest.main()
