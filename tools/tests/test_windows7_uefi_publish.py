"""Run the real EFI publisher against disposable files, never physical disks."""
from pathlib import Path
import os, shutil, subprocess, tempfile, unittest
ROOT=Path(__file__).resolve().parents[2]

class Publish(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work=ROOT/'zig-out/uefi-publish-tests';cls.work.mkdir(exist_ok=True)
        cls.exe=cls.work/'publish.exe'
        env=dict(os.environ,TEMP=str(cls.work),TMP=str(cls.work),ZIG_GLOBAL_CACHE_DIR=str(ROOT/'tools/cache/zig-global'),ZIG_LOCAL_CACHE_DIR=str(cls.work/'zig-cache'))
        subprocess.run([str(ROOT/'tools/zig/zig.exe'),'cc','-target','x86_64-windows.win7-gnu','-Os','-nostdlib','-fno-stack-protector','-fno-builtin','-I'+str(ROOT/'tools/zig/lib/libc/include/any-windows-any'),str(ROOT/'tools/tests/windows7_uefi_publish_harness.c'),'-Wl,--entry,entry','-lkernel32','-ladvapi32','-lversion','-o',str(cls.exe)],env=env,check=True)
    def setUp(self):
        temp=tempfile.TemporaryDirectory(dir=self.work);self.addCleanup(temp.cleanup)
        self.dir=Path(temp.name);shutil.copyfile(self.exe,self.dir/'publish.exe')
        for name in ['win7.original.efi','win7.efi','UefiSeven.ini','uefiseven-LICENSE.txt','win7-wrapper.efi']:
            (self.dir/name).write_bytes(name.encode())
        self.ms=self.dir/'target/EFI/Microsoft/Boot';self.ms.mkdir(parents=True)
        self.fallback=self.dir/'target/EFI/Boot';self.fallback.mkdir(parents=True)
        (self.ms/'bootmgfw.efi').write_bytes(b'win7.original.efi')
    def run_publish(self):
        return subprocess.run([str(self.dir/'publish.exe')],capture_output=True).returncode
    def test_both_entries_and_preserved_originals(self):
        (self.fallback/'bootx64.efi').write_bytes(b'win7.original.efi')
        self.assertEqual(0,self.run_publish())
        for directory,entry in [(self.ms,'bootmgfw.efi'),(self.fallback,'bootx64.efi')]:
            self.assertEqual(b'win7-wrapper.efi',(directory/entry).read_bytes())
            self.assertEqual(b'win7.original.efi',(directory/'win7.original.efi').read_bytes())
    def test_missing_fallback_created(self):
        self.assertEqual(0,self.run_publish())
        self.assertEqual(b'win7-wrapper.efi',(self.fallback/'bootx64.efi').read_bytes())
    def test_foreign_fallback_stops_before_boot_changes(self):
        (self.fallback/'bootx64.efi').write_bytes(b'other OS')
        self.assertNotEqual(0,self.run_publish())
        self.assertEqual(b'win7.original.efi',(self.ms/'bootmgfw.efi').read_bytes())
        self.assertEqual(b'other OS',(self.fallback/'bootx64.efi').read_bytes())
    def test_conflicting_preserved_original_stops(self):
        (self.fallback/'win7.original.efi').write_bytes(b'keep')
        self.assertNotEqual(0,self.run_publish())
        self.assertEqual(b'win7.original.efi',(self.ms/'bootmgfw.efi').read_bytes())
        self.assertFalse((self.fallback/'bootx64.efi').exists())

if __name__=='__main__':unittest.main()
