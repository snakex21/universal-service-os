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
        for version,helper in [('4 0 0 1112',True),('4 10 0 2222',True),('4 0 0 950',False),('4 0 0 1111',False),('',True)]:
            folder,result=self.generate(version,helper)
            self.assertNotEqual(result.returncode,0)
            self.assertFalse(list(folder.glob('FIRST*')))
    def test_osr2_gets_the_same_coordinator(self):
        # X470 95 OSR2.1 PL native (2026-10-27): no first-desktop hold before.
        base,result=self.generate('4 0 0 950');self.assertEqual(result.returncode,0,result.stderr)
        for version in ('4 0 0 1068','4 0 0 1111','4 0 0 1212','4 0 0 1214','4 0 0 1216'):
            folder,result=self.generate(version);self.assertEqual(result.returncode,0,result.stderr)
            for name in ('FIRSTBT.BAT','FIRSTBT.REG','SHELLHDR.INI'):
                self.assertEqual((folder/name).read_bytes(),(base/name).read_bytes(),(version,name))
            self.assertEqual((folder/'FIRSTBT.ON').read_bytes(),f'95 OSR2 ({version}) first complete desktop\r\n'.encode())
        self.assertEqual((base/'FIRSTBT.ON').read_bytes(),b'source950 first complete desktop\r\n')
    def test_real_mode_queue_is_ordinary_runonce_and_dos_sized(self):
        folder,result=self.generate('4 0 0 950');self.assertEqual(result.returncode,0,result.stderr)
        reg=(folder/'FIRSTBT.REG').read_bytes();batch=(folder/'FIRSTBT.BAT').read_bytes()
        self.assertIn(b'\\CurrentVersion\\RunOnce]',reg)
        self.assertNotIn(b'\\RunOnce\\Setup',reg)
        self.assertIn(b'"USOSFirstBoot"=',reg)
        self.assertLessEqual(max(map(len,batch.splitlines())),127)
        self.assertEqual(batch.count(b'\n'),batch.count(b'\r\n'))
        self.assertIn(b'PHASE1.OK',batch)
        self.assertNotIn(b'FAILWAIT',batch)
    def test_failures_never_hang_and_never_block_the_coordinator(self):
        folder,result=self.generate('4 0 0 950');self.assertEqual(result.returncode,0,result.stderr)
        lines=(folder/'FIRSTBT.BAT').read_bytes().split(b'\r\n')
        # X470 95 RTM: ':FAILWAIT / GOTO FAILWAIT' hung the boot at a cursor.
        # Every GOTO jumps forward, so the batch always reaches :END.
        for i,l in enumerate(lines):
            if b'GOTO ' in l:self.assertGreater(lines.index(b':'+l.rsplit(b'GOTO ',1)[1]),i,l)
        # 950 real-mode REGEDIT /E fails on ~2 MB hives: no export read-back
        self.assertFalse([l for l in lines if l.startswith(b'REGEDIT') and b' /E ' in l])
        self.assertNotIn(b'FIRSTRO',b'\n'.join(lines))
        # a failure logs, writes the non-blocking DER marker (never FIRSTBT.ERR,
        # which USOSFB treats as "stop"), relocks the hives and ends
        fail=lines.index(b':FAIL');lock=lines.index(b':LOCK');body=b'\n'.join(lines[fail:lock])
        self.assertIn(rb'>> C:\USOS9X\USOSLOG.TXT',body)
        self.assertIn(rb'> C:\USOS9X\FIRSTBT.DER',body)
        self.assertNotIn(rb'> C:\USOS9X\FIRSTBT.ERR',b'\n'.join(lines))
        self.assertEqual(lines[lock+1:lock+4],[rb'C:\WINDOWS\COMMAND\ATTRIB.EXE +S +R +H SYSTEM.DAT',
                                               rb'C:\WINDOWS\COMMAND\ATTRIB.EXE +S +R +H USER.DAT',b':END'])
        arm=lines.index(rb'REGEDIT /L:SYSTEM.DAT /R:USER.DAT C:\USOS9X\FIRSTBT.REG')
        self.assertEqual(lines[arm+1:arm+3],[b'IF ERRORLEVEL 1 GOTO FAIL',b'GOTO LOCK'])
    def test_logon_key_replaced_before_runonce_import_every_boot(self):
        folder,result=self.generate('4 0 0 950');self.assertEqual(result.returncode,0,result.stderr)
        lines=(folder/'FIRSTBT.BAT').read_bytes().split(b'\r\n')
        delkey=lines.index(rb'C:\USOS9X\VESBIND.EXE DELKEY C:\WINDOWS\SYSTEM.DAT HKEY_LOCAL_MACHINE\Network\Logon C:\USOS9X\LGNDEL.LOG')
        imp=lines.index(rb'REGEDIT /L:SYSTEM.DAT /R:USER.DAT C:\USOS9X\REG95LGN.REG')
        arm=lines.index(rb'REGEDIT /L:SYSTEM.DAT /R:USER.DAT C:\USOS9X\FIRSTBT.REG')
        done=lines.index(rb'IF EXIST C:\USOS9X\FIRSTBT.OK GOTO END')
        unlock=lines.index(rb'C:\WINDOWS\COMMAND\ATTRIB.EXE -S -R -H SYSTEM.DAT')
        self.assertTrue(done<unlock<delkey<imp<arm)
        # 950 real-mode REGEDIT has no /D; refusal/failure never stops the RunOnce arm
        self.assertFalse([l for l in lines if l.startswith(b'REGEDIT') and b' /D ' in l])
        self.assertEqual(lines[delkey+1:delkey+3],[b'IF ERRORLEVEL 3 GOTO LGNBACK',b'IF ERRORLEVEL 2 GOTO LGNLOG'])
        back=lines.index(b':LGNBACK');self.assertEqual(lines[back+1],rb'COPY /Y C:\USOS9X\SYSTEM.LGN SYSTEM.DAT > NUL')
        self.assertLess(lines.index(b':LGNEND'),arm)
        for guard in (rb'IF NOT EXIST C:\USOS9X\REG95.OK GOTO LGNEND',rb'IF NOT EXIST C:\USOS9X\REG95LGN.REG GOTO LGNEND',
                      rb'IF NOT EXIST C:\USOS9X\VESBIND.EXE GOTO LGNEND'):
            self.assertLess(lines.index(guard),delkey)
        self.assertNotIn(b'GOTO FAIL',b'\n'.join(lines[unlock:lines.index(b':LGNEND')]))
if __name__=='__main__':unittest.main()
