"""950 media (RTM / OSR1): prep stages what USOSADD plans there; plan log reasons.

X470 95 OSR1 EN (2026-10-27): staging used the OSR2 union and copied ws2-95
(OSR2 full pack, option-only on RTM/OSR1) that USOSADD never planned; the
log called the PL packages "not for this system". Host only.
"""
from pathlib import Path
import shutil,subprocess,sys,tempfile,unittest
ROOT=Path(__file__).resolve().parents[3]
sys.path[:0]=[str(ROOT/'tools'),str(ROOT/'tools/addons'),str(ROOT/'tools/tests')]
import depguard
import legacy_manifest as lm
from build_legacy_stage import build
OUT=ROOT/'artifacts/legacy-pack/stage-950';OUT.mkdir(parents=True,exist_ok=True)
SH=shutil.which('sh') or r'C:\Program Files\Git\usr\bin\sh.exe'
def q(p):return "'"+str(p).replace('\\','/')+"'"

class Stage950(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        depguard.require_zig('kompilator Zig (build_legacy_stage)')
        cls.exe=build(ROOT,(OUT/'native').resolve(),host=True)
    # dial-up off (the default): usos_addons_stage excludes every DUN package
    DUN=','.join(p.id for p in lm.Manifest.load().packages if p.id.startswith('dun'))
    def plan(self,os_,lang,options=''):
        d=Path(tempfile.mkdtemp(dir=OUT));self.addCleanup(shutil.rmtree,d)
        (d/'SELECT.INI').write_text(f'[select]\npreset=praca\noptions={options}\nexclude={self.DUN}\n')
        r=subprocess.run([str(self.exe),str(ROOT/'src/addons/legacy-pack.ini'),str(d/'SELECT.INI'),os_,lang,''],capture_output=True,text=True)
        self.assertEqual(r.returncode,0,r.stderr)
        return sorted({l.split('|')[1] for l in r.stdout.splitlines() if l.startswith('file|')})
    def test_950_stages_the_runtime_plan_only(self):
        m=lm.Manifest.load()
        for lang in ('EN','PL'):
            want=set()
            for os_ in ('95RTM','95OSR1'):
                want|={i for i in lm.resolve(m,os_,lang,'',True,[],self.DUN.split(',')).order if m.find(i).get('file1')}
            got=self.plan('95RTM',lang)
            self.assertEqual(set(got),want,lang)
            self.assertNotIn('ws2-95',got,lang)
        # OSR1 EN run: exactly the five packages USOSADD installed (+ none extra)
        self.assertEqual(self.plan('95RTM','EN'),['dcom95','msi20-9x','mslu','vbrun6sp6','vcredist6sp6'])
        self.assertNotIn('ie55sp2-pl',self.plan('95RTM','EN'))
        self.assertIn('ie55sp2-pl',self.plan('95RTM','PL'))
        self.assertIn('ws2-95',self.plan('95RTM','EN','ws2-95'))       # still selectable
        self.assertIn('ws2-95',self.plan('95','EN'))                    # OSR2 media unchanged

    def test_shell_accepts_95rtm_and_keeps_expect_95(self):
        root=Path(tempfile.mkdtemp(dir=OUT));self.addCleanup(shutil.rmtree,root)
        lib=root/'lib';(lib/'addons').mkdir(parents=True);data=root/'DATA';data.mkdir();target=root/'C'
        shutil.copyfile(self.exe,lib/'addons/legacy-stage-plan');(lib/'addons/USOSADD.EXE').write_bytes(b'x')
        text=(ROOT/'src/addons/legacy-pack.ini').read_text(encoding='utf-8')
        for lang in ('PL','EN'):(lib/'addons'/('LEGACY.'+lang)).write_bytes(text.encode('cp1252',errors='replace'))
        cfg=root/'config';cfg.write_text('preset=praca\noptions=\nexclude=\ndialup=off\n')
        r=subprocess.run([SH,'-c','. '+q(ROOT/'tools/legacy_addons.sh')+'; usos_addons_stage '+' '.join(map(q,(cfg,target,lib,data,'95RTM','EN','')))],
                         cwd=ROOT,capture_output=True)
        self.assertEqual(r.returncode,0,r.stderr)
        sel=(target/'USOS/ADDONS/SELECT.INI').read_text()
        self.assertIn('expect=95\n',sel.replace('\r',''))
        self.assertIn('staging system=95RTM lang=EN',(target/'USOS9X/LOGS/ADDONS.LOG').read_text())
        plan=(target/'USOS/ADDONS/PLAN.TXT').read_text()
        self.assertNotIn('|ws2-95|',plan)
        target_sh=(ROOT/'tools/w9x_csmwrap_target.sh').read_text(encoding='utf-8')
        self.assertIn("""[ "$addon_os:${setup_version:-}" != '95:4 0 0 950' ] || addon_os=95RTM""",target_sh)
        self.assertLess(target_sh.index('setup_version=$("$LIB/pe-file-version"'),target_sh.index('addon_os=95RTM'))

    def test_runtime_log_reasons(self):
        s=(ROOT/'src/platform/win32_legacy/usosadd/main.c').read_text()
        body=s[s.index('static void system_reason('):s.index('static int files_present(')]
        self.assertIn('" (language "',body);self.assertIn('", system "',body)
        self.assertIn('ua_os_match(&g_m, p->os, g_sys.os) && !ua_ieq(p->lang, "*") && !ua_ieq(p->lang, g_sys.lang)',body)
        self.assertIn('" (option, not selected)"',body)
        self.assertIn('if (p->tier == UA_TIER_OPTION) return 1;',body)
        self.assertIn('"option_os"',body)
        self.assertIn('if (w == UA_OUT_SYSTEM) system_reason(line, sizeof line, &g_p.pkg[i]);',body)

if __name__=='__main__':unittest.main()
