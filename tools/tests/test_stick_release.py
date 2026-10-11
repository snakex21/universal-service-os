"""micro-Linux leaves the USOS stick volumes clean (tools/stick_release.sh).

X470 2026-10-11: Windows 10 x86 phase 2 ran "Scanning and repairing drive"
on the USOS stick. Linux vfat / ntfs3 / exfat mark a volume dirty while it is
mounted read-write; `reboot -f` / `poweroff -f` without an unmount left the
stick ESP dirty. Every restart / power-off must go through stick_release.sh.
"""
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'tools/stick_release.sh'
SH = shutil.which('sh') or r'C:\Program Files\Git\usr\bin\sh.exe'


class StickRelease(unittest.TestCase):
    def test_no_direct_restart_in_micro_linux_scripts(self):
        offenders = []
        for path in (ROOT / 'tools').rglob('*.sh'):
            rel = path.relative_to(ROOT).as_posix()
            if rel.startswith(('tools/vendor/', 'tools/tests/', 'tools/cache/')) or path == SCRIPT:
                continue
            for number, line in enumerate(path.read_text(encoding='utf-8', errors='replace').splitlines(), 1):
                code = line.split('#', 1)[0]
                if re.search(r'\b(reboot|poweroff|halt)\s+-f\b', code) or 'sysrq-trigger' in code:
                    offenders.append(f'{rel}:{number}: {line.strip()}')
        self.assertEqual(offenders, [], 'restart without stick_release.sh')

    def test_stop_releases_mounts(self):
        init = (ROOT / 'tools/micro_linux_init.sh').read_text(encoding='utf-8')
        stop = init[init.index('stop() {'):init.index('exec /bin/sh')]
        self.assertIn('stick_release.sh ro', stop)

    def test_packed_into_initramfs(self):
        self.assertIn('("tools/stick_release.sh", "usr/lib/usos/stick_release.sh")',
                      (ROOT / 'tools/build_micro_linux.py').read_text(encoding='utf-8'))

    def test_lists_writable_fat_ntfs_exfat_deepest_first(self):
        mounts = '\n'.join([
            'rootfs / rootfs rw 0 0',
            'proc /proc proc rw,relatime 0 0',
            '/dev/sdb1 /mnt/esp vfat rw,noatime,fmask=0022 0 0',
            '/dev/sdb2 /mnt/data ntfs3 ro,noatime 0 0',
            '/dev/sdb3 /mnt/work exfat rw,noatime 0 0',
            '/dev/loop0 /mnt/source iso9660 ro 0 0',
            '/dev/sda1 /tmp/w/staging ntfs3 rw,relatime 0 0',
            '/dev/sdb1 /mnt/esp/sub vfat rw 0 0',
            '/dev/sdc1 /mnt/rwx ext4 rw 0 0',
        ]) + '\n'
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp) / 'mounts'
            fake.write_text(mounts, encoding='ascii', newline='\n')
            out = subprocess.run([SH, SCRIPT.as_posix(), 'list'], capture_output=True, text=True, check=True,
                                 env=dict(os.environ, USOS_STICK_MOUNTS=fake.as_posix())).stdout.split()
        self.assertEqual(out, ['/mnt/esp/sub', '/tmp/w/staging', '/mnt/work', '/mnt/esp'])


if __name__ == '__main__':
    unittest.main()
