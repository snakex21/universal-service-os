"""Vista Int10 dispatcher step of the Vista finalizer (docs/design/win7-vista-no-csm.md 7):
run the real code against disposable files, never physical disks.

Needs zig-out/vista/usb-install (python tools/build_windows_vista_support.py) for
the generated payload headers.
"""
from pathlib import Path
import os, shutil, subprocess, tempfile, unittest
ROOT = Path(__file__).resolve().parents[2]
VISTA_LOADER = b'Vista 6.0.6001 bootmgfw.efi'


class VistaInt10(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work = ROOT / 'zig-out/vista-int10-tests'
        cls.work.mkdir(parents=True, exist_ok=True)
        cls.exe = cls.work / 'vista-int10.exe'
        generated = ROOT / 'zig-out/vista/usb-install'
        if not (generated / 'vista_deploy_files.h').exists():
            subprocess.run(['python', str(ROOT / 'tools/build_windows_vista_support.py')], check=True)
        env = dict(os.environ, TEMP=str(cls.work), TMP=str(cls.work), ZIG_GLOBAL_CACHE_DIR=str(ROOT / 'tools/cache/zig-global'), ZIG_LOCAL_CACHE_DIR=str(cls.work / 'zig-cache'))
        subprocess.run([str(ROOT / 'tools/zig/zig.exe'), 'cc', '-target', 'x86_64-windows.win10-gnu', '-Os', '-nostdlib', '-fno-stack-protector', '-fno-builtin',
                        '-I' + str(ROOT / 'tools/zig/lib/libc/include/any-windows-any'), '-I' + str(generated), '-I' + str(ROOT / 'tools'),
                        str(ROOT / 'tools/tests/vista_int10_harness.c'), '-Wl,--entry,entry', '-lkernel32', '-ladvapi32', '-lversion', '-luser32', '-o', str(cls.exe)],
                       env=env, check=True)

    def setUp(self):
        temp = tempfile.TemporaryDirectory(dir=self.work)
        self.addCleanup(temp.cleanup)
        self.dir = Path(temp.name)
        shutil.copyfile(self.exe, self.dir / 'vista-int10.exe')
        for name in ['win7.efi', 'UefiSeven.ini', 'uefiseven-LICENSE.txt', 'win7-wrapper.efi']:
            (self.dir / name).write_bytes(name.encode())
        self.ms = self.dir / 'target/EFI/Microsoft/Boot'
        self.ms.mkdir(parents=True)
        self.fallback = self.dir / 'target/EFI/Boot'
        self.fallback.mkdir(parents=True)
        # configure_boot has just copied the Vista loader to the fallback path.
        (self.ms / 'bootmgfw.efi').write_bytes(VISTA_LOADER)
        (self.fallback / 'bootx64.efi').write_bytes(VISTA_LOADER)

    def run_step(self):
        return subprocess.run([str(self.dir / 'vista-int10.exe')], capture_output=True)

    def test_without_flag_nothing_changes(self):
        r = self.run_step()
        self.assertEqual(0, r.returncode)
        self.assertEqual(VISTA_LOADER, (self.ms / 'bootmgfw.efi').read_bytes())
        self.assertEqual(VISTA_LOADER, (self.fallback / 'bootx64.efi').read_bytes())
        self.assertFalse((self.ms / 'win7.efi').exists())

    def test_flag_publishes_dispatcher_with_the_vista_loader_as_original(self):
        (self.dir / 'usos-int10-dispatcher.flag').write_bytes(b'1\r\n')
        r = self.run_step()
        self.assertEqual(0, r.returncode, r.stdout)
        for directory, entry in [(self.ms, 'bootmgfw.efi'), (self.fallback, 'bootx64.efi')]:
            self.assertEqual(b'win7-wrapper.efi', (directory / entry).read_bytes())
            self.assertEqual(VISTA_LOADER, (directory / 'win7.original.efi').read_bytes())
            self.assertEqual(b'win7.efi', (directory / 'win7.efi').read_bytes())
            self.assertEqual(b'UefiSeven.ini', (directory / 'UefiSeven.ini').read_bytes())
        self.assertIn(b'Int10 dispatcher installed', r.stdout)

    def test_foreign_fallback_keeps_the_vista_loader(self):
        (self.dir / 'usos-int10-dispatcher.flag').write_bytes(b'1\r\n')
        (self.fallback / 'bootx64.efi').write_bytes(b'other OS')
        r = self.run_step()
        self.assertNotEqual(0, r.returncode)
        self.assertEqual(VISTA_LOADER, (self.ms / 'bootmgfw.efi').read_bytes())
        self.assertEqual(b'other OS', (self.fallback / 'bootx64.efi').read_bytes())


if __name__ == '__main__':
    unittest.main()
