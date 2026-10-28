"""Host test: floppy disk sets as installation media (2026-10-23).

tools/floppy_set.sh (micro-Linux, sourced by dos_csmwrap_target.sh) runs here
under the host's POSIX shell with stand-in mcopy/mdir (tools/dos_media_fat12.py
reads the same FAT12 images; the real mtools run is the QEMU test,
docs/floppy-sets-2026-10-23.md):

* floppy_set_images: diskette extensions and sizes only, natural disk order
  (disk2 before disk10, DISK_1 / disk01 / "Disk 3 of 10" alike);
* floppy_set_merge: every file of every diskette in one folder, directories
  kept, names upper case; an identical duplicate is skipped, a different one
  keeps the first copy and is logged as a conflict; an unreadable image fails.

Also the wiring: dos_csmwrap_target.sh takes a folder as DOS_WIN3_ISO,
w9x_csmwrap_prepare.sh lets a folder through only for Windows 1.0x-3.x, the
micro-Linux image carries floppy_set.sh, and the Zig detector
(src/catalog/floppy_set.zig) uses the same sizes and extensions.
"""
from __future__ import annotations

import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'tools' / 'floppy_set.sh'
SH = shutil.which('sh') or shutil.which('bash')

FAKE_MTOOLS = r'''
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from dos_media_fat12 import files
tool, args = sys.argv[2], sys.argv[3:]
image = args[args.index('-i') + 1]
try:
    content = list(files(Path(image).read_bytes()))
except Exception as error:
    print(error, file=sys.stderr)
    sys.exit(1)
if tool == 'mdir':
    sys.exit(0)
if not content:
    sys.exit(1)          # '::*' matches nothing on an empty diskette
dest = Path(args[-1])
for name, data in content:
    out = dest / name
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(data)
'''


def fat12(files: dict[str, bytes], size: int = 1474560) -> bytes:
    """A minimal FAT12 diskette: root files and one directory level, contiguous."""
    layout = {368640: (2, 112, 2, 0xFD), 737280: (2, 112, 3, 0xF9), 1228800: (1, 224, 7, 0xF9), 1474560: (1, 224, 9, 0xF0)}
    spc, root_entries, fat_sectors, media = layout[size]
    image = bytearray(size)
    image[0:3] = b'\xeb\x3c\x90'
    image[3:11] = b'USOSTEST'
    struct.pack_into('<HBHBHHBH', image, 11, 512, spc, 1, 2, root_entries, size // 512, media, fat_sectors)
    image[510:512] = b'\x55\xaa'
    fat = bytearray(fat_sectors * 512)
    fat[0:3] = bytes([media, 0xff, 0xff])
    root = 512 * (1 + 2 * fat_sectors)
    first = root + root_entries * 32
    cluster_bytes = spc * 512
    next_cluster = [2]

    def set_fat(cluster: int, value: int) -> None:
        offset = cluster * 3 // 2
        word = struct.unpack_from('<H', fat, offset)[0]
        word = (word & 0x000f) | (value << 4) if cluster & 1 else (word & 0xf000) | value
        struct.pack_into('<H', fat, offset, word)

    def store(data: bytes) -> int:
        if not data:
            return 0
        count = (len(data) + cluster_bytes - 1) // cluster_bytes
        start = next_cluster[0]
        for i in range(count):
            set_fat(start + i, start + i + 1 if i + 1 < count else 0xfff)
        position = first + (start - 2) * cluster_bytes
        image[position:position + len(data)] = data
        next_cluster[0] += count
        return start

    def entry(name: str, attr: int, cluster: int, length: int) -> bytes:
        base, _, ext = name.partition('.')
        raw = bytearray(32)
        raw[0:11] = (base.ljust(8) + ext.ljust(3)).encode('ascii')
        raw[11] = attr
        struct.pack_into('<HI', raw, 26, cluster, length)
        return bytes(raw)

    root_dir = bytearray()
    subdirs: dict[str, dict[str, bytes]] = {}
    for name, data in files.items():
        if '/' in name:
            folder, leaf = name.split('/', 1)
            subdirs.setdefault(folder, {})[leaf] = data
        else:
            root_dir += entry(name, 0x20, store(data), len(data))
    for folder, children in subdirs.items():
        body = bytearray()
        for leaf, data in children.items():
            body += entry(leaf, 0x20, store(data), len(data))
        body += bytes(cluster_bytes - len(body) % cluster_bytes if len(body) % cluster_bytes else 0)
        root_dir += entry(folder, 0x10, store(bytes(body)), 0)
    image[root:root + len(root_dir)] = root_dir
    image[512:512 + len(fat)] = fat
    image[512 + len(fat):512 + 2 * len(fat)] = fat
    return bytes(image)


@unittest.skipUnless(SH, 'needs a POSIX shell')
class FloppySetShell(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='usos-floppy-'))
        bin_dir = self.tmp / 'bin'
        bin_dir.mkdir()
        fake = self.tmp / 'fake_mtools.py'
        fake.write_text(FAKE_MTOOLS, encoding='utf-8')
        py = Path(sys.executable).as_posix()
        for tool in ('mcopy', 'mdir'):
            wrapper = bin_dir / tool
            wrapper.write_text(f'#!/bin/sh\nexec "{py}" -I "{fake.as_posix()}" "{(ROOT / "tools").as_posix()}" {tool} "$@"\n',
                               encoding='utf-8', newline='\n')
            wrapper.chmod(0o755)
        self.bin = bin_dir
        self.set = self.tmp / 'Images' / 'WfW 3.11 PL'
        self.set.mkdir(parents=True)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def sh(self, command: str) -> subprocess.CompletedProcess:
        env = dict(os.environ)
        env['PATH'] = self.bin.as_posix() + os.pathsep + env.get('PATH', '')
        script = f'. "{SCRIPT.as_posix()}"\n{command}\n'
        return subprocess.run([SH, '-c', script], capture_output=True, text=True, env=env, cwd=self.tmp)

    def names(self, output: str) -> list[str]:
        return [Path(line).name for line in output.splitlines() if line]

    def test_natural_order_and_filters(self):
        for name in ('disk10.img', 'disk2.img', 'disk1.img', 'DISK_3.IMA', 'Disk 4 of 10.vfd', 'disk05.flp'):
            (self.set / name).write_bytes(fat12({'A.TXT': b'a'}))
        (self.set / 'readme.txt').write_bytes(b'x')
        (self.set / 'harddisk.img').write_bytes(bytes(1474560 + 512))   # not a diskette size
        (self.set / 'small.img').write_bytes(bytes(368640))             # 360 KiB counts
        result = self.sh(f'floppy_set_images "{self.set.as_posix()}"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.names(result.stdout),
                         ['disk1.img', 'disk2.img', 'DISK_3.IMA', 'Disk 4 of 10.vfd', 'disk05.flp', 'disk10.img', 'small.img'])

    def test_merge_flat_with_directories_duplicates_and_conflicts(self):
        (self.set / 'disk1.img').write_bytes(fat12({'SETUP.EXE': b'MZ setup', 'COMMON.INF': b'same', 'README.TXT': b'first'}))
        (self.set / 'disk2.img').write_bytes(fat12({'VGA.DR_': b'driver', 'COMMON.INF': b'same', 'PIF/DOS.PIF': b'pif'}, 737280))
        (self.set / 'disk10.img').write_bytes(fat12({'README.TXT': b'second, different', 'LAST.DLL': b'last'}))
        dest = self.tmp / 'win'
        result = self.sh(f'floppy_set_merge "{self.set.as_posix()}" "{dest.as_posix()}"')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        got = sorted(p.relative_to(dest).as_posix() for p in dest.rglob('*') if p.is_file())
        self.assertEqual(got, ['COMMON.INF', 'LAST.DLL', 'PIF/DOS.PIF', 'README.TXT', 'SETUP.EXE', 'VGA.DR_'])
        self.assertEqual((dest / 'README.TXT').read_bytes(), b'first')
        self.assertIn('conflict README.TXT: disk10.img differs from disk1.img, the copy from disk1.img is kept', result.stdout)
        self.assertNotIn('conflict COMMON.INF', result.stdout)
        self.assertIn('3 diskettes merged, 6 files, 1 identical duplicates, 1 conflicts', result.stdout)
        # Only DEST is left behind (no work folders next to it).
        self.assertEqual(sorted(p.name for p in self.tmp.iterdir()), ['Images', 'bin', 'fake_mtools.py', 'win'])

    def test_unreadable_image_fails(self):
        (self.set / 'disk1.img').write_bytes(fat12({'SETUP.EXE': b'MZ'}))
        (self.set / 'disk2.img').write_bytes(bytes(1474560))   # no boot sector
        result = self.sh(f'floppy_set_merge "{self.set.as_posix()}" "{(self.tmp / "win").as_posix()}"')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('cannot read disk2.img', result.stdout)

    def test_empty_folder_fails(self):
        result = self.sh(f'floppy_set_merge "{self.set.as_posix()}" "{(self.tmp / "win").as_posix()}"')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('no diskette images', result.stdout)


class Wiring(unittest.TestCase):
    def test_dos_target_merges_a_folder(self):
        text = (ROOT / 'tools/dos_csmwrap_target.sh').read_text(encoding='utf-8')
        self.assertIn('if [ -d "$WIN3_ISO" ]; then', text)
        self.assertIn('. "$LIB/floppy_set.sh"', text)
        self.assertIn('floppy_set_merge "$WIN3_ISO" "$work/win"', text)
        # The merged folder goes through the same WINSETUP copy and display patch.
        self.assertLess(text.index('floppy_set_merge'), text.index('usos-fb-ui --win3x-display "$U/WINSETUP"'))

    def test_prepare_allows_folders_for_windows_3x_only(self):
        text = (ROOT / 'tools/w9x_csmwrap_prepare.sh').read_text(encoding='utf-8')
        self.assertIn('if [ -d "/mnt/data/$iso" ]; then', text)
        self.assertIn('[ "$tag" = W3 ] || stop "floppy disk sets are supported only', text)

    def test_micro_linux_carries_the_helper(self):
        text = (ROOT / 'tools/build_micro_linux.py').read_text(encoding='utf-8')
        self.assertIn('("tools/floppy_set.sh", "usr/lib/usos/floppy_set.sh")', text)

    def test_zig_detector_uses_the_same_sizes_and_extensions(self):
        shell = SCRIPT.read_text(encoding='utf-8')
        zig = (ROOT / 'src/catalog/floppy_set.zig').read_text(encoding='utf-8')
        sizes = re.search(r'case "\$1" in ([0-9|]+)\)', shell).group(1).split('|')
        for size in sizes:
            self.assertIn(size, zig)
        self.assertEqual(len(sizes), 8)
        for ext in ('img', 'ima', 'vfd', 'flp'):
            self.assertIn(f'*.{ext}', shell)
            self.assertIn(f'".{ext}"', zig)


if __name__ == '__main__':
    unittest.main()
