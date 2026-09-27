"""The micro-Linux initramfs files are followed by EFI/USOS/lang.cpio (a second
initrd= on the XP and Vista preparation command lines, and in the systemd-boot
entry). Loaders concatenate the files without padding and the kernel accepts
a cpio header only at a 4-byte-aligned offset, so an initramfs whose size is
not a multiple of 4 silently drops the language: X470, build B260927-153019
("rootfs image is not initramfs (invalid magic at start of compressed
archive)"), with the menus in English. Host-only."""
from pathlib import Path
import gzip, re, sys, unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
from build_micro_linux import pad_initrd  # noqa: E402


def second_archive_offset(first: bytes, second: bytes) -> int | None:
    """Model of init/initramfs.c unpack_to_rootfs over first+second: the gzip
    member of `first` is consumed, zero bytes are skipped, and a "070701"
    header is recognised only at a 4-aligned offset (else: invalid magic)."""
    blob = first + second
    decompressor = gzip.zlib.decompressobj(31)
    decompressor.decompress(blob)
    offset = len(blob) - len(decompressor.unused_data)
    while offset < len(blob) and blob[offset] == 0:
        offset += 1
    if blob[offset:offset + 6] == b'070701' and offset % 4 == 0:
        return offset
    return None


class InitrdAlignment(unittest.TestCase):
    LANG_CPIO = b'070701' + b'0' * 104 + b'TRAILER!!!\0\0'
    def test_pad_initrd_aligns_and_stays_readable(self):
        for size in range(1, 64):
            data = gzip.compress(bytes(range(size)) * 7, mtime=0)
            padded = pad_initrd(data)
            self.assertEqual(len(padded) % 4, 0)
            self.assertLess(len(padded) - len(data), 4)
            self.assertEqual(padded[:len(data)], data)
            self.assertEqual(gzip.decompress(padded), bytes(range(size)) * 7)
            self.assertEqual(second_archive_offset(padded, self.LANG_CPIO), len(padded))
            if len(data) % 4:
                self.assertIsNone(second_archive_offset(data, self.LANG_CPIO))

    def test_builders_pad_every_initramfs(self):
        for name in ('build_micro_linux.py', 'build_xp_uefi_csm_trial.py'):
            text = (ROOT / 'tools' / name).read_text(encoding='utf-8')
            calls = re.findall(r'^.*gzip\.compress\(.*$', text, re.M)
            self.assertTrue(calls, name)
            for line in calls:
                self.assertIn('pad_initrd(gzip.compress(', line, f'{name}: {line.strip()}')

    def test_built_packages_are_aligned(self):
        # Checks the local outputs when they exist (skipped on a clean tree).
        found = False
        for path in [ROOT / 'zig-out/micro-linux/initramfs-usos', ROOT / 'zig-out/xp-uefi-csm/initramfs-xp']:
            if path.is_file() and path.stat().st_mtime > (ROOT / 'tools/build_micro_linux.py').stat().st_mtime:
                found = True
                self.assertEqual(path.stat().st_size % 4, 0, path)
        if not found:
            self.skipTest('no initramfs built since the padding change')


if __name__ == '__main__':
    unittest.main()
