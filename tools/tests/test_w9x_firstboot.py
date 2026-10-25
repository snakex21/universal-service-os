"""Functional source950 generator boundaries; real DOS/QEMU evidence separate."""
from pathlib import Path
import os,shutil,subprocess,tempfile,unittest
ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'artifacts/firstboot/host-tests';OUT.mkdir(parents=True,exist_ok=True)
class FirstBoot(unittest.TestCase):
    def generate(self,version,helper=True):
        target=Path(tempfile.mkdtemp(dir=OUT));self.addCleanup(shutil.rmtree,target)
        if helper:(target/'USOSFB.EXE').write_bytes(b'own helper fixture')
        script='. "$1"; w9x_firstboot_write "$2" "$3"'
        result=subprocess.run([r'C:\Program Files\Git\bin\sh.exe','-c',script,'test',str(ROOT/'tools/w9x_firstboot.sh').replace('\\','/'),str(target).replace('\\','/'),version],capture_output=True)
        return target,result
    def test_other_source_versions_and_missing_helper_do_not_arm(self):
        for version,helper in [('4 0 0 1111',True),('4 10 0 2222',True),('4 0 0 950',False),('',True)]:
            folder,result=self.generate(version,helper)
            self.assertNotEqual(result.returncode,0)
            self.assertFalse(list(folder.glob('FIRST*')))
    def test_real_mode_queue_is_ordinary_runonce_and_dos_sized(self):
        folder,result=self.generate('4 0 0 950');self.assertEqual(result.returncode,0,result.stderr)
        reg=(folder/'FIRSTBT.REG').read_bytes();batch=(folder/'FIRSTBT.BAT').read_bytes()
        self.assertIn(b'\\CurrentVersion\\RunOnce]',reg)
        self.assertNotIn(b'\\RunOnce\\Setup',reg)
        self.assertIn(b'"USOSFirstBoot"=',reg)
        self.assertLessEqual(max(map(len,batch.splitlines())),127)
        self.assertEqual(batch.count(b'\n'),batch.count(b'\r\n'))
        self.assertIn(b'PHASE1.OK',batch)
        self.assertIn(b':FAILWAIT\r\nGOTO FAILWAIT',batch)
if __name__=='__main__':unittest.main()
