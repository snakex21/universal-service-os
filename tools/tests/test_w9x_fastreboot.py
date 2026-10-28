"""FastReboot "0" for 98 FE / 98 SE / Me, never for 95 (host-only).

X470 98 FE PL B261028-114842 (and the run before it): some USOSFB restarts
(ExitWindowsEx EWX_REBOOT|EWX_FORCE) powered the PC off instead of resetting;
the hive after Setup had Control\\Shutdown FastReboot="1". Two places:
INSTALL.BAT's [USOS.CsmReg] (Setup of 98 / 98 SE / Me applies it) and, for
98 / 98 SE, FIRSTBT.REG (real-mode REGEDIT every boot until FIRSTBT.OK).
"""
from pathlib import Path
import shutil,subprocess,tempfile,unittest
ROOT=Path(__file__).resolve().parents[2]
INSTALL=ROOT/'src/platform/bios/dos_startup.cmd'
OUT=ROOT/'artifacts/firstboot/host-tests';OUT.mkdir(parents=True,exist_ok=True)
KEY=b'[HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Control\\Shutdown]\r\n"FastReboot"="0"\r\n'
LINE=r'ECHO HKLM,"System\CurrentControlSet\Control\Shutdown",FastReboot,,"0">>C:\%U9SRC%\MSBATCH.INF'

class InstallBat(unittest.TestCase):
    def test_csmreg_line_gated_out_of_95(self):
        text=INSTALL.read_text(encoding='latin-1').splitlines()
        i=text.index(LINE)
        self.assertEqual(text[i-1],'IF "%U9SYS%"=="95" GOTO FRBDONE')
        self.assertEqual(text[i+1],':FRBDONE')
        self.assertEqual(sum(1 for l in text if l.upper().startswith(':FRBDONE')),1)
        # inside [USOS.CsmReg], before the next section header
        start=text.index(r'ECHO [USOS.CsmReg]>>C:\%U9SRC%\MSBATCH.INF')
        nxt=[j for j,l in enumerate(text) if j>start and l.startswith('ECHO [') and 'MSBATCH.INF' in l]
        self.assertLess(start,i);self.assertTrue(not nxt or i<nxt[0])
        # every path to [USOS.CsmReg] skips USER answers, so a user's file stays 1:1
        self.assertLessEqual(len(LINE.replace('%U9SRC%','WINME')),127)

class FirstbtReg(unittest.TestCase):
    def reg(self,version):
        target=Path(tempfile.mkdtemp(dir=OUT));self.addCleanup(shutil.rmtree,target)
        (target/'USOSFB.EXE').write_bytes(b'own helper fixture')
        r=subprocess.run([r'C:\Program Files\Git\bin\sh.exe','-c','. "$1"; w9x_firstboot_write "$2" "$3"','test',
                          str(ROOT/'tools/w9x_firstboot.sh').replace('\\','/'),str(target).replace('\\','/'),version],
                         capture_output=True,timeout=60)
        self.assertEqual(r.returncode,0,r.stderr)
        return (target/'FIRSTBT.REG').read_bytes()

    def test_98_only(self):
        for version in ('4 10 0 1998','4 10 0 2222'):
            reg=self.reg(version);self.assertTrue(reg.endswith(b'\r\n'+KEY),version)
            self.assertEqual(reg.count(b'\n'),reg.count(b'\r\n'))
        for version in ('4 0 0 950','4 0 0 1111','4 0 0 1216'):
            self.assertNotIn(b'FastReboot',self.reg(version),version)

if __name__=='__main__':unittest.main()
