"""Windows 95 answer registry (tools/w9x_reg95.sh, C:\\USOS9X\\REG95.BAT) and
the 98 FE Channel Bar answer (tools/w9x_csmwrap_target.sh).

95 OSR2 Setup ignores MSBATCH.INF [Install] AddReg (X470 fresh install,
95 OSR2.1 PL, B261020-111448-1F997795: no USOSRES / USOSLAN / USOSLOG Run
value, no IE / ICW defaults in SYSTEM.DAT / USER.DAT). REG95.BAT imports
the same values once with real-mode REGEDIT. Host only (Git sh).
Run: python tools/tests/test_w9x_reg95.py
"""
from pathlib import Path
import re
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_w9x_phase1_qemu import sh

ROOT = Path(__file__).resolve().parents[2]
REG95 = (ROOT / 'tools/w9x_reg95.sh').as_posix()
TARGET = ROOT / 'tools/w9x_csmwrap_target.sh'
DEFAULT_INF = ROOT / 'src/platform/bios/win9x/msbatch.inf'
RUN = 'HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows\\CurrentVersion\\Run'

# The [Install] part of a USOS-rendered 95 answer (the X470 install's file,
# product key left out), plus lines the conversion must refuse.
ANSWER_95 = r'''[Version]
Signature="$CHICAGO$"

[Setup]
Express=1

[Install]
AddReg=USOS.RunOnce,USOS.CsmReg,USOS.Lan,USOS.Addons,USOS.Display,USOS.Odd
UpdateInis=USOS.Memory

[USOS.Lan]
HKCU,"Software\Microsoft\Windows\CurrentVersion\Internet Settings",EnableAutodial,0x00010001,0
HKCU,"Software\Microsoft\Windows\CurrentVersion\Internet Settings",NoNetAutodial,0x00010001,1
HKLM,"Software\Microsoft\Windows\CurrentVersion\Internet Settings",EnableAutodial,0x00010001,0
HKCU,"Software\Microsoft\Internet Connection Wizard",Completed,1,01,00,00,00
HKCU,"Software\Microsoft\Internet Explorer\Main","Start Page",,"about:blank"
HKLM,"Software\Microsoft\Windows\CurrentVersion\Winlogon",DefaultPassword,,""
HKLM,"Software\Microsoft\Windows\CurrentVersion\Run",USOSLan,,"C:\USOS9X\USOSLAN.EXE"

[USOS.Addons]

[USOS.Memory]
system.ini,386Enh,,"MaxPhysPage=40000"

[USOS.RunOnce]
HKLM,"Software\Microsoft\Windows\CurrentVersion\RunOnce",USOSWelcome,,"%25%\rundll.exe setupx.dll,InstallHinfSection USOS.NoWelcome 4 %10%\msbatch.inf"

[USOS.Display]
HKLM,Software\Microsoft\Windows\CurrentVersion\Run,USOSDisplay,,"C:\USOS9X\USOSRES.EXE"

[USOS.Odd]
HKR,,Foo,,"bar"
HKLM,"Software\USOS",Multi,0x00010000,"a","b"
HKLM,"Software\USOS",Quote,,"say ""hi"""
HKLM,"Software\USOS",Hex,0x00010001,0x1E000
HKCR,"CLSID\{00000000-0000-0000-0000-000000000001}",,,"x"

[USOS.Csm]
'''.replace('\n', '\r\n')


class Reg95(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='usos-w9x-reg95-'))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def write(self, answer, *extra):
        inf = self.tmp / 'MSBATCH.INF'
        inf.write_bytes(answer.encode('ascii') if isinstance(answer, str) else answer)
        out = self.tmp / 'out'
        out.mkdir(exist_ok=True)
        quoted = ' '.join("'%s'" % a for a in extra)
        rc, so, err = sh(f'. "{REG95}"\nw9x_reg95_write "{out.as_posix()}" "{inf.as_posix()}" {quoted}', {})
        files = {n: (out / n).read_bytes() for n in ('REG95.BAT', 'REG95.REG') if (out / n).exists()}
        return rc, files, err

    def test_install_values_become_regedit4(self):
        rc, files, err = self.write(ANSWER_95, 'C:\\USOS9X\\USOSLOG.EXE')
        self.assertEqual(rc, 0, err)
        reg = files['REG95.REG'].decode('ascii')
        self.assertTrue(reg.startswith('REGEDIT4\r\n'))
        self.assertEqual(reg.count('\n'), reg.count('\r\n'))
        self.assertNotIn('[-', reg)                                     # 95 REGEDIT deletes nothing
        # HKCU = HKEY_USERS\.Default (95 without profiles; real-mode REGEDIT).
        self.assertIn('[HKEY_USERS\\.Default\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings]\r\n'
                      '"EnableAutodial"=dword:00000000\r\n"NoNetAutodial"=dword:00000001\r\n', reg)
        self.assertIn('[HKEY_USERS\\.Default\\Software\\Microsoft\\Internet Connection Wizard]\r\n"Completed"=hex:01,00,00,00\r\n', reg)
        self.assertIn('"Start Page"="about:blank"\r\n', reg)
        self.assertIn('"DefaultPassword"=""\r\n', reg)
        # The three helpers 95 never started (unquoted subkey of USOS.Display too).
        run = reg[reg.index('[%s]\r\n' % RUN):]
        for name, exe in (('USOSLan', 'USOSLAN'), ('USOSDisplay', 'USOSRES'), ('USOSLog', 'USOSLOG')):
            self.assertIn('"%s"="C:\\\\USOS9X\\\\%s.EXE"\r\n' % (name, exe), run)
        self.assertIn('"Quote"="say \\"hi\\""\r\n', reg)
        self.assertIn('"Hex"=dword:0001e000\r\n', reg)
        self.assertIn('[HKEY_LOCAL_MACHINE\\SOFTWARE\\Classes\\CLSID\\{00000000-0000-0000-0000-000000000001}]\r\n@="x"\r\n', reg)
        # Not expressible: listed as comments, not imported.
        comments = [l for l in reg.split('\r\n') if l.startswith(';')]
        self.assertEqual(len(comments), 3, comments)
        self.assertTrue(any('ldid' in c and 'USOSWelcome' in c for c in comments))
        self.assertTrue(any(c.startswith('; USOS: not converted (root: HKR') for c in comments))
        self.assertTrue(any('flags 0x00010000' in c for c in comments))
        self.assertNotIn('USOSWelcome"=', reg)
        self.assertNotIn('MaxPhysPage', reg)                           # UpdateInis: U9FIX's job

    def test_95_additions(self):
        rc, files, _ = self.write(ANSWER_95)
        reg = files['REG95.REG'].decode('ascii')
        # The desktop "Internet" icon opens IE 3, not ICWCONN1.EXE (LAN policy on).
        self.assertIn('[HKEY_LOCAL_MACHINE\\SOFTWARE\\Classes\\CLSID\\{FBF23B42-E3F0-101B-8488-00AA003E56F8}\\Shell\\Open\\Command]\r\n'
                      '@="\\"C:\\\\Program Files\\\\Internet Explorer\\\\IEXPLORE.EXE\\""\r\n', reg)
        # No Welcome window (NoWelcome's RunOnce cannot run on 95).
        self.assertIn('[HKEY_USERS\\.Default\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Tips]\r\n"Show"=hex:00,00,00,00\r\n', reg)
        self.assertNotIn('USOSLog', reg)                               # no logger argument
        no_lan = re.sub(r'\[USOS\.Lan\].*?\r\n\r\n', '[USOS.Lan]\r\n\r\n', ANSWER_95, flags=re.S)
        _, files, _ = self.write(no_lan)
        self.assertNotIn('FBF23B42', files['REG95.REG'].decode('ascii'))

    def test_default_answer_converts(self):
        rc, files, err = self.write(DEFAULT_INF.read_bytes())
        self.assertEqual(rc, 0, err)
        reg = files['REG95.REG'].decode('ascii')
        self.assertIn('"USOSLan"="C:\\\\USOS9X\\\\USOSLAN.EXE"', reg)
        self.assertIn('FBF23B42', reg)

    def test_no_install_section_writes_nothing(self):
        rc, files, _ = self.write('[Version]\r\nSignature="$CHICAGO$"\r\n')
        self.assertEqual(rc, 1)
        self.assertEqual(files, {})

    def test_batch_is_dos_safe_and_acts_once(self):
        _, files, _ = self.write(ANSWER_95)
        bat = files['REG95.BAT']
        self.assertEqual(bat.count(b'\n'), bat.count(b'\r\n'))
        self.assertLessEqual(max(len(line) for line in bat.split(b'\r\n')), 125)
        text = bat.decode('ascii')
        for marker in ('REG95.OK GOTO END', 'REG95.RUN GOTO END', 'NOT EXIST C:\\WINDOWS\\SYSTEM.DAT GOTO END',
                       'NOT EXIST C:\\WINDOWS\\USER.DAT GOTO END'):
            self.assertIn(marker, text)
        self.assertLess(text.index('ECHO run> C:\\USOS9X\\REG95.RUN'), text.index('REGEDIT /L:SYSTEM.DAT /R:USER.DAT C:\\USOS9X\\REG95.REG'))
        imp = text.index('REGEDIT /L:SYSTEM.DAT /R:USER.DAT C:\\USOS9X\\REG95.REG')
        for name in ('SYSTEM.DAT', 'USER.DAT'):
            self.assertLess(text.index('ATTRIB.EXE -S -R -H ' + name), imp)
            self.assertGreater(text.index('ATTRIB.EXE +S +R +H ' + name), imp)
        self.assertIn('/E C:\\USOS9X\\REG95CHK.REG ' + RUN, text)    # evidence for the next read-back


def target_block(start, end):
    text = TARGET.read_text(encoding='utf-8')
    return text[text.index(start):text.index(end)]


class Wiring(unittest.TestCase):
    def run_block(self, tag, kind='USOS', log_ok='1', answer=None):
        tmp = Path(tempfile.mkdtemp(prefix='usos-w9x-reg95block-'))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        (tmp / 'c/USOS9X').mkdir(parents=True)
        (tmp / 'c/USOS9X/MSBATCH.INF').write_bytes((answer or DEFAULT_INF.read_text(encoding='ascii').replace('\n', '\r\n')).encode('ascii'))
        text = TARGET.read_text(encoding='utf-8')
        helper = text[text.index('w9x_98fe_channelbar_answer() {'):text.index('\nfor tool in ')]
        block = target_block('if [ "$SYSTEM_TAG" = 95 ]; then\n    if [ -r "$LIB/w9x_vesa95.sh" ]', '# The boot floppy runs INSTALL.BAT')
        script = ('set -eu\nlog() { printf "%s\\n" "$*"; }\nfail() { echo "FAIL $*"; exit 9; }\n' + helper + '\n'
                  f'SYSTEM_TAG={tag}\nANSWER_KIND={kind}\nlog_ok={log_ok}\nLIB="{(ROOT / "tools").as_posix()}"\nwork="{tmp.as_posix()}"\n' + block)
        rc, out, err = sh(script, {})
        self.assertEqual(rc, 0, out + err)
        return tmp / 'c/USOS9X', out

    def test_reg95_for_95_usos_answers_only(self):
        for tag, kind, expected in (('95', 'USOS', True), ('95', 'USER', False), ('98SE', 'USOS', False),
                                    ('98', 'USOS', False), ('ME', 'USOS', False)):
            d, out = self.run_block(tag, kind)
            self.assertEqual((d / 'REG95.BAT').exists(), expected, (tag, kind, out))
            self.assertEqual((d / 'REG95.REG').exists(), expected, (tag, kind))
        d, _ = self.run_block('95', log_ok='1')
        self.assertIn(b'"USOSLog"=', (d / 'REG95.REG').read_bytes())
        d, _ = self.run_block('95', log_ok='0')
        self.assertNotIn(b'"USOSLog"=', (d / 'REG95.REG').read_bytes())
        build = (ROOT / 'tools/build_micro_linux.py').read_text(encoding='utf-8')
        self.assertIn('("tools/w9x_reg95.sh", "usr/lib/usos/w9x_reg95.sh")', build)

    def test_autoexec_calls_reg95_after_vesa95_before_the_bridge(self):
        lines = (ROOT / 'src/platform/bios/dos_startup.cmd').read_text(encoding='ascii').splitlines()
        hook = 'ECHO @IF EXIST C:\\USOS9X\\REG95.BAT CALL C:\\USOS9X\\REG95.BAT>>C:\\AUTOEXEC.BAT'
        vesa = 'ECHO @IF EXIST C:\\USOS9X\\VESA95.BAT CALL C:\\USOS9X\\VESA95.BAT>>C:\\AUTOEXEC.BAT'
        self.assertEqual(lines.count(hook), 1)
        at = lines.index(hook)
        self.assertGreater(at, lines.index(vesa))
        self.assertGreater(at, lines.index(':UDSAUTO'))                # not skipped with sticks off
        self.assertLess(at, lines.index('ECHO @C:\\USOS9X\\USOSKEY.COM>>C:\\AUTOEXEC.BAT'))

    def test_98fe_channel_bar_off(self):
        d, out = self.run_block('98')
        inf = (d / 'MSBATCH.INF').read_bytes().decode('ascii')
        self.assertIn('Channel Bar off', out)
        self.assertRegex(inf, r'\r\nAddReg=[^\r\n]*,USOS\.ChannelBar\r\n')
        section = '[USOS.ChannelBar]\r\nHKCU,"Software\\Microsoft\\Internet Explorer\\Main",Show_ChannelBand,,"no"\r\n'
        self.assertEqual(inf.count(section), 1)
        # Before [USOS.Csm]: INSTALL.BAT appends USOS.CsmReg after that header.
        self.assertLess(inf.index(section), inf.index('[USOS.Csm]'))
        self.assertTrue(inf.rstrip('\r\n').endswith('[USOS.Csm]'))
        self.assertEqual(inf.count('\n'), inf.count('\r\n'))
        for tag, kind in (('98SE', 'USOS'), ('98', 'USER'), ('95', 'USOS'), ('ME', 'USOS')):
            d, _ = self.run_block(tag, kind)
            self.assertNotIn('ChannelBar', (d / 'MSBATCH.INF').read_bytes().decode('ascii'), (tag, kind))

    def test_98fe_channel_bar_needs_one_addreg(self):
        d, out = self.run_block('98', answer='[Version]\r\nSignature="$CHICAGO$"\r\n')
        self.assertIn('Channel Bar left as Setup sets it', out)
        self.assertNotIn('ChannelBar', (d / 'MSBATCH.INF').read_bytes().decode('ascii'))


if __name__ == '__main__':
    unittest.main()
