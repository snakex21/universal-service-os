"""SPDX-License-Identifier: GPL-3.0-or-later
Scope, real finalizer staging and immutable USB payload checks. File fixtures
only; no target OS registration or physical disk access.
"""
from pathlib import Path
import argparse,hashlib,os,shutil,subprocess,tempfile,unittest

ROOT=Path(__file__).resolve().parents[2]
TOOLS=ROOT/'tools'
class WatermarkStaging(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work=ROOT/'zig-out/watermark/staging-tests';cls.work.mkdir(parents=True,exist_ok=True)
        cls.generated=ROOT/'zig-out/vista/usb-install'
        cls.bash=Path(r'C:\Program Files\Git\bin\bash.exe')
        cls.env=dict(os.environ,TEMP=str(cls.work),TMP=str(cls.work),ZIG_GLOBAL_CACHE_DIR=str(cls.work/'zig-global'),ZIG_LOCAL_CACHE_DIR=str(cls.work/'zig-local'))
        cls.harness=cls.work/'stage.exe'
        subprocess.run([str(TOOLS/'zig/zig.exe'),'cc','-target','x86_64-windows.win10-gnu','-Os','-nostdlib','-fno-stack-protector','-fno-builtin','-I'+str(TOOLS/'zig/lib/libc/include/any-windows-any'),'-I'+str(cls.generated),str(ROOT/'tools/tests/watermark_stage_harness.c'),'-Wl,--entry,entry','-lkernel32','-ladvapi32','-lversion','-luser32','-o',str(cls.harness)],env=cls.env,check=True)
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(dir=self.work);self.addCleanup(self.tmp.cleanup);self.folder=Path(self.tmp.name)
        shutil.copyfile(self.harness,self.folder/'stage.exe')
        for i,name in enumerate(('usoswm-desktop.dll','usoswm.exe','usoswm-register.exe')):
            shutil.copyfile(self.generated/'usoswm'/name,self.folder/('vista-watermark-%02d.bin'%i))
    def run_stage(self):
        subprocess.run([str(self.folder/'stage.exe')],env=self.env,check=True,capture_output=True,timeout=20)
        return self.folder/'target/USOS/usoswm'
    def test_real_staging_and_second_run(self):
        target=self.run_stage();before={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in target.iterdir()}
        self.assertEqual(3,len(before));self.run_stage();self.assertEqual(before,{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in target.iterdir()})
        self.assertFalse((target/'testmode-watermark-on.txt').exists())
    def test_empty_opt_out_transmitted_and_removed(self):
        marker=self.folder/'usos-testmode-watermark-on.flag';marker.touch();target=self.run_stage()
        self.assertEqual(b'',(target/'testmode-watermark-on.txt').read_bytes())
        marker.unlink();self.run_stage();self.assertFalse((target/'testmode-watermark-on.txt').exists())
    def test_corrupted_component_is_not_installed(self):
        (self.folder/'vista-watermark-00.bin').write_bytes(b'corrupt')
        self.run_stage();self.assertFalse((self.folder/'target/USOS/usoswm/usoswm-register.exe').exists())
    def test_opt_out_never_leaks_to_x86_or_nt61(self):
        if not self.bash.exists():self.skipTest('Git Bash required')
        data=self.folder/'DATA';flag=data/'Systems/Windows/Windows Vista/Unattended/testmode-watermark-on.txt';flag.parent.mkdir(parents=True);flag.touch()
        script='. "$1"; vista_testmode_watermark_visible "$2" "$3" "$4"'
        def status(profile,folder):
            return subprocess.run([str(self.bash),'--noprofile','--norc','-c',script,'test',str(ROOT/'tools/vista_csmwrap_prepare.sh').replace('\\','/'),profile,str(data).replace('\\','/'),folder],env=self.env).returncode
        self.assertEqual(0,status('vista-x64-sp2-uefi-csmwrap','Windows Vista'))
        for profile in ('win-x86-uefi-csmwrap','win-nt6-x86-uefi-csmwrap','win7-x64'):
            self.assertEqual(1,status(profile,'Windows Vista'))
        self.assertEqual(1,status('vista-x64-sp2-uefi-csmwrap','Windows 7'))
        self.assertEqual(1,status('vista-x64-sp2-uefi-csmwrap','Windows Server 2008 R2'))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--tool-root',type=Path,default=TOOLS);a=p.parse_args();TOOLS=a.tool_root.resolve();unittest.main(argv=['watermark-staging'],verbosity=2)
