"""Unit tests for tools/work_boot_relocate.sh (WORK EFI/BOOT -> EFI/USOS-WORK).

Runs the production script with a POSIX sh (Git Bash on Windows, sh elsewhere)
on throwaway directories; no disks are touched.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'tools' / 'work_boot_relocate.sh'


def shell():
    for candidate in ('C:/Program Files/Git/bin/sh.exe', 'C:/Program Files/Git/bin/bash.exe'):
        if os.path.exists(candidate):
            return candidate
    found = shutil.which('sh')
    if not found:
        raise unittest.SkipTest('no POSIX sh available')
    return found


def run(*args, check=True):
    result = subprocess.run([shell(), str(SCRIPT), *map(str, args)], capture_output=True, text=True)
    if check and result.returncode != 0:
        raise AssertionError(f'{args} failed rc={result.returncode}\n{result.stdout}\n{result.stderr}')
    return result


def names(directory):
    return sorted(p.name.lower() for p in Path(directory).iterdir()) if Path(directory).is_dir() else []


def find_ci(parent, name):
    parent = Path(parent)
    if not parent.is_dir():
        return None
    for child in parent.iterdir():
        if child.name.lower() == name.lower():
            return child
    return None


class WorkBootRelocateTest(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='usos-work-boot-'))
        (self.root / '.usos-work').write_text('nonce=test\n')

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def write(self, rel, data=b'x'):
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def usos_work(self):
        return find_ci(find_ci(self.root, 'efi'), 'usos-work')

    def legacy_boot(self):
        return find_ci(find_ci(self.root, 'efi'), 'boot')

    def test_windows_media_is_moved_whole(self):
        self.write('efi/boot/bootx64.efi', b'bootmgfw')
        self.write('efi/microsoft/boot/bcd', b'bcd')
        run('relocate', self.root)
        self.assertIsNone(self.legacy_boot())
        self.assertEqual(b'bootmgfw', (self.usos_work() / 'bootx64.efi').read_bytes())
        self.assertEqual(b'bcd', (self.root / 'efi/microsoft/boot/bcd').read_bytes())
        run('assert', self.root, '--require-entry')

    def test_windows7_chain_is_moved_whole(self):
        for name, data in [('BOOTX64.EFI', b'wrapper'), ('win7.efi', b'uefiseven'), ('win7.original.efi', b'bootmgfw'),
                           ('UefiSeven.ini', b'ini'), ('uefiseven-LICENSE.txt', b'lic'), ('usos-boot.log', b'log')]:
            self.write(f'EFI/BOOT/{name}', data)
        run('relocate', self.root)
        self.assertIsNone(self.legacy_boot())
        self.assertEqual(['bootx64.efi', 'uefiseven-license.txt', 'uefiseven.ini', 'usos-boot.log', 'win7.efi', 'win7.original.efi'],
                         names(self.usos_work()))
        self.assertEqual(b'bootmgfw', (self.usos_work() / 'win7.original.efi').read_bytes())
        run('assert', self.root, '--require-entry')

    def test_linux_loader_keeps_config_but_loses_entry(self):
        self.write('EFI/BOOT/BOOTx64.EFI', b'shim')
        self.write('EFI/BOOT/grubx64.efi', b'grub')
        self.write('EFI/BOOT/grub.cfg', b'cfg')
        self.write('EFI/BOOT/fonts/unicode.pf2', b'font')
        run('relocate', self.root)
        self.assertEqual(['fonts', 'grub.cfg', 'grubx64.efi'], names(self.legacy_boot()))
        self.assertEqual(['bootx64.efi', 'fonts', 'grub.cfg', 'grubx64.efi'], names(self.usos_work()))
        self.assertEqual(b'font', (self.usos_work() / 'fonts/unicode.pf2').read_bytes())
        run('assert', self.root, '--require-entry')

    def test_existing_usos_work_files_are_not_replaced(self):
        self.write('EFI/USOS-WORK/BOOTX64.EFI', b'published')
        self.write('EFI/BOOT/BOOTX64.EFI', b'stale')
        self.write('EFI/BOOT/BOOTIA32.EFI', b'ia32')
        run('relocate', self.root)
        self.assertIsNone(self.legacy_boot())
        self.assertEqual(b'published', (self.usos_work() / 'BOOTX64.EFI').read_bytes())
        self.assertEqual(b'ia32', (self.usos_work() / 'BOOTIA32.EFI').read_bytes())

    def test_relocate_is_idempotent_and_noop_without_efi(self):
        run('relocate', self.root)
        self.write('efi/boot/bootx64.efi')
        run('relocate', self.root)
        run('relocate', self.root)
        self.assertEqual(['bootx64.efi'], names(self.usos_work()))

    def test_boot_dir_without_entry_is_left_alone(self):
        self.write('EFI/BOOT/grub.cfg', b'cfg')
        run('relocate', self.root)
        self.assertEqual(['grub.cfg'], names(self.legacy_boot()))
        self.assertIsNone(self.usos_work())

    def test_assert_rejects_removable_entries(self):
        for entry in ('EFI/BOOT/BOOTX64.EFI', 'efi/Boot/bootia32.efi'):
            with self.subTest(entry=entry):
                path = self.write(entry)
                result = run('assert', self.root, check=False)
                self.assertNotEqual(0, result.returncode)
                self.assertIn('removable-media boot entry', result.stderr)
                warn = run('check', self.root)
                self.assertIn('WARNING', warn.stdout)
                path.unlink()
        run('assert', self.root)

    def test_assert_require_entry_needs_usos_work(self):
        result = run('assert', self.root, '--require-entry', check=False)
        self.assertNotEqual(0, result.returncode)
        self.assertIn('EFI/USOS-WORK/BOOTX64.EFI is missing', result.stderr)
        self.write('EFI/USOS-WORK/bootx64.efi')
        run('assert', self.root, '--require-entry')


if __name__ == '__main__':
    unittest.main()
