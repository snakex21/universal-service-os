"""950 "The Internet" icon: the IE 3 path command only with an IE package.

X470 95 OSR1 EN (2026-10-27): the desktop icon pointed at
C:\\Program Files\\Internet Explorer\\IEXPLORE.EXE, which OSR1 EN without
IE 5.5 does not have (its IE 2.0 lives in Program Files\\Plus!\\Microsoft
Internet and works from the Start menu). Host only (Git sh).
"""
from pathlib import Path
import shutil,sys,tempfile,unittest
sys.path.insert(0,str(Path(__file__).resolve().parent))
from test_w9x_phase1_qemu import sh
from test_w9x_reg95 import ANSWER_95
ROOT=Path(__file__).resolve().parents[2]
REG95=(ROOT/'tools/w9x_reg95.sh').as_posix()
ADDONS=(ROOT/'tools/legacy_addons.sh').as_posix()

class InternetIcon(unittest.TestCase):
    def tmp(self):
        t=Path(tempfile.mkdtemp(prefix='usos-w9x-ie-'));self.addCleanup(shutil.rmtree,t,ignore_errors=True);return t
    def write(self,version,ie):
        t=self.tmp();(t/'MSBATCH.INF').write_bytes(ANSWER_95.encode('ascii'));(t/'out/NET').mkdir(parents=True)
        rc,so,err=sh(f'. "{REG95}"\nw9x_reg95_write "{(t/"out").as_posix()}" "{(t/"MSBATCH.INF").as_posix()}" '
                     f'"" "C:\\USOS9X\\USOSVMD.INF" "" "$V" "$I"',{'V':version,'I':ie})
        self.assertEqual(rc,0,err);return t/'out'

    def test_950_without_ie_keeps_the_system_value(self):
        out=self.write('4 0 0 950','noie')
        for name in ('REG95.REG','R95LATE.REG','R95LATE.BAT'):
            data=(out/name).read_bytes()
            self.assertNotIn(b'FBF23B42',data,name);self.assertNotIn(b'IEXPLORE',data,name)
        late=(out/'R95LATE.REG').read_bytes()
        self.assertIn(b'"Start Page"="file://C:\\\\USOS9X\\\\START.HTM"',late)  # start page stays
        self.assertNotIn(b'RL3.REG',(out/'R95LATE.BAT').read_bytes())

    def test_950_with_ie_and_other_versions_write_the_command(self):
        for version,ie in (('4 0 0 950',''),('4 0 0 1111',''),('','')):
            out=self.write(version,ie)
            both=(out/'REG95.REG').read_bytes()+((out/'R95LATE.REG').read_bytes() if (out/'R95LATE.REG').exists() else b'')
            self.assertIn(b'@="\\"C:\\\\Program Files\\\\Internet Explorer\\\\IEXPLORE.EXE\\""\r\n',both,version)

    def staged(self,plan,legacy,pkgs):
        t=self.tmp();app=t/'c/USOS/ADDONS';app.mkdir(parents=True)
        (app/'PLAN.TXT').write_text(plan,newline='');(app/'LEGACY.INI').write_text(legacy,newline='')
        (app/'USOSADD.EXE').write_bytes(b'x')
        for d in pkgs:(app/'PKG'/d).mkdir(parents=True);(app/'PKG'/d/'F.EXE').write_bytes(b'x')
        rc,so,err=sh(f'. "{ADDONS}"\nif usos_addons_staged "{(t/"c").as_posix()}" ie; then echo YES; else echo NO; fi',{})
        self.assertEqual(rc,0,err);return so.strip()

    LEGACY=('[pack]\r\nos=95RTM\r\n[pkg:ie55sp2-pl]\r\nos=95\r\nprovides = ie:5.5\r\n'
            '[pkg:ie55sp2-q810847-pl]\r\nos=95\r\nneeds=ie:5.5\r\n[pkg:dcom95]\r\nprovides=dcom:1.3\r\n')
    def test_staged_ie_detection(self):
        ie='file|ie55sp2-pl|IE55SP2|IE55PL.ZIP|aa|1|zip\n';q='file|ie55sp2-q810847-pl|Q810847|Q.EXE|bb|1|\n'
        dcom='file|dcom95|DCOM95|DCOM95.EXE|cc|1|\n'
        self.assertEqual(self.staged(dcom+ie,self.LEGACY,['DCOM95','IE55SP2']),'YES')
        self.assertEqual(self.staged(dcom+ie,self.LEGACY,['DCOM95']),'NO')       # planned, file missing
        self.assertEqual(self.staged(dcom+q,self.LEGACY,['DCOM95','Q810847']),'NO')  # hotfix needs IE, gives none
        self.assertEqual(self.staged(dcom,self.LEGACY,['DCOM95']),'NO')            # OSR1 EN run 2026-10-27
        self.assertEqual(self.staged('unavailable|ie55sp2-pl|||||x\n',self.LEGACY,[]),'NO')

    def test_target_passes_noie_on_950_only_without_ie(self):
        text=(ROOT/'tools/w9x_csmwrap_target.sh').read_text(encoding='utf-8')
        block=text[text.index('        reg95_ie=\n'):text.index('"$reg95_ie"; then')]
        self.assertIn("if [ \"${setup_version:-}\" = '4 0 0 950' ]; then",block)
        self.assertIn('usos_addons_staged "$work/c" ie',block)
        self.assertIn('reg95_ie=noie',block)
        # staging happens before the registry conversion
        self.assertLess(text.index('usos_addons_stage "$work/addons.ini"'),text.index('w9x_reg95_write "$work/c/USOS9X"'))

if __name__=='__main__':unittest.main()
