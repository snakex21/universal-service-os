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
        files = {n: (out / n).read_bytes() for n in ('REG95.BAT', 'REG95.REG', 'START.HTM') if (out / n).exists()}
        for n in files:
            (out / n).unlink()
        return rc, files, err

    def test_run_values_persistent_first_lan_last(self):
        # The 95 shell starts Run values inside its RegEnumValue(index) loop:
        # a helper deleting its own value shifts the next one onto its index
        # and the shell skips it (X470: USOSLan hid USOSDisplay).
        _, files, _ = self.write(ANSWER_95, 'C:\\USOS9X\\USOSLOG.EXE')
        reg = files['REG95.REG'].decode('ascii')
        self.assertEqual(reg.count('[%s]' % RUN), 1)
        run = reg[reg.index('[%s]\r\n' % RUN):].split('\r\n\r\n')[0]
        self.assertEqual(re.findall(r'^"(\w+)"=', run, flags=re.M), ['USOSLog', 'USOSDisplay', 'USOSLan'])

    def test_vmd_values(self):
        # The mouse in MS-DOS boxes on 95: the RunOnce of USOSVMD.INF (95
        # Setup drops [USOS.CsmReg]) and VMOUSE kept off the PS/2 devnode.
        _, files, _ = self.write(ANSWER_95, '', 'C:\\USOS9X\\USOSVMD.INF')
        reg = files['REG95.REG'].decode('ascii')
        ro = '[HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce]\r\n'
        self.assertEqual(reg.count(ro), 1)
        self.assertIn(ro + '"USOSVmd"="rundll.exe setupx.dll,InstallHinfSection DefaultInstall 4 C:\\\\USOS9X\\\\USOSVMD.INF"\r\n', reg)
        self.assertIn('[HKEY_LOCAL_MACHINE\\Config\\0001\\Enum\\Root\\*PNP0F0E\\0000]\r\n"CSConfigFlags"=hex:06,00,00,00\r\n', reg)
        self.assertNotIn('USOSLog', reg)                               # empty logger argument
        self.assertNotIn('[-', reg)
        self.assertEqual(reg.count('\n'), reg.count('\r\n'))
        self.assertLess(reg.index('CSConfigFlags'), reg.index('; USOS: not converted'))
        _, files, _ = self.write(ANSWER_95)
        self.assertNotIn(b'USOSVmd', files['REG95.REG'])
        self.assertNotIn(b'CSConfigFlags', files['REG95.REG'])

    def test_start_page_file(self):
        _, files, _ = self.write(ANSWER_95)
        page = files['START.HTM']
        self.assertEqual(page.count(b'\n'), page.count(b'\r\n'))
        text = page.decode('ascii')
        self.assertIn('<A HREF="http://68k.news">', text)
        self.assertNotIn('<SCRIPT', text.upper())
        no_home = ANSWER_95.replace('"Start Page",,"about:blank"', '"Other",,"x"')
        self.assertNotEqual(no_home, ANSWER_95)
        _, files, _ = self.write(no_home)
        self.assertNotIn('START.HTM', files)
        self.assertNotIn(b'START.HTM', files['REG95.REG'])
        _, files, _ = self.write(ANSWER_95.replace('"about:blank"', '"http://example.org/"'))
        self.assertIn(b'"Start Page"="http://example.org/"', files['REG95.REG'])
        self.assertNotIn('START.HTM', files)

    def test_install_values_become_regedit4(self):
        rc, files, err = self.write(ANSWER_95, 'C:\\USOS9X\\USOSLOG.EXE')
        self.assertEqual(rc, 0, err)
        reg = files['REG95.REG'].decode('ascii')
        self.assertTrue(reg.startswith('REGEDIT4\r\n'))
        self.assertEqual(reg.count('\n'), reg.count('\r\n'))
        self.assertNotIn('[-', reg)                                     # 95 REGEDIT deletes nothing
        # HKCU = HKEY_USERS\.Default (95 without profiles; real-mode REGEDIT).
        self.assertIn('[HKEY_USERS\\.Default\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings]\r\n'
                      '"EnableAutodial"=hex:00,00,00,00\r\n"NoNetAutodial"=hex:01,00,00,00\r\n', reg)
        self.assertNotIn('dword:', reg)                                # 4 binary bytes (real-mode REGEDIT)
        self.assertIn('[HKEY_USERS\\.Default\\Software\\Microsoft\\Internet Connection Wizard]\r\n"Completed"=hex:01,00,00,00\r\n', reg)
        # IE 3 cannot open about:blank: the local start page instead.
        self.assertIn('"Start Page"="file://C:\\\\USOS9X\\\\START.HTM"\r\n', reg)
        self.assertNotIn('about:blank', reg)
        self.assertIn('"DefaultPassword"=""\r\n', reg)
        # The three helpers 95 never started (unquoted subkey of USOS.Display too).
        run = reg[reg.index('[%s]\r\n' % RUN):]
        for name, exe in (('USOSLan', 'USOSLAN'), ('USOSDisplay', 'USOSRES'), ('USOSLog', 'USOSLOG')):
            self.assertIn('"%s"="C:\\\\USOS9X\\\\%s.EXE"\r\n' % (name, exe), run)
        self.assertIn('"Quote"="say \\"hi\\""\r\n', reg)
        self.assertIn('"Hex"=hex:00,e0,01,00\r\n', reg)
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
        dhcp = ('[HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\VxD\\DHCP]\r\n'
                '"Version"=hex:01,00,00,00\r\n"PopupFlag"=hex:00,00,00,00\r\n')
        # No DHCP error popup with the cable unplugged (VDHCP PopupFlag), and
        # Version=1 in the same key: VDHCP.386 refuses to load when VxD\DHCP
        # exists without Version (X470 95 RTM, no DHCP lease).
        self.assertEqual(reg.count(dhcp), 1)
        self.assertEqual(reg.count('Services\\VxD\\DHCP]'), 1)
        self.assertNotIn('"PopupFlag"=hex:00\r\n', reg)
        self.assertLess(reg.index(dhcp), reg.index('; USOS: not converted') if '; USOS: not converted' in reg else len(reg))
        no_lan = re.sub(r'\[USOS\.Lan\].*?\r\n\r\n', '[USOS.Lan]\r\n\r\n', ANSWER_95, flags=re.S)
        _, files, _ = self.write(no_lan)
        self.assertNotIn('FBF23B42', files['REG95.REG'].decode('ascii'))
        self.assertIn(dhcp, files['REG95.REG'].decode('ascii'))      # also without the LAN step

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


class InitShell(unittest.TestCase):
    """Every 95 version: HKLM RunOnce InitShell (SHELL.INF, written in phase
    1) makes the 95 Explorer start Welcome.exe -f whatever Tips\\Show says;
    REG95.BAT removes it with VESBIND DELVAL before the first GUI start."""
    LINE = ('C:\\USOS9X\\VESBIND.EXE DELVAL SYSTEM.DAT Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce '
            'InitShell C:\\USOS9X\\ISDEL.LOG')

    def batch(self, version):
        tmp = Path(tempfile.mkdtemp(prefix='usos-w9x-initshell-'))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        (tmp / 'MSBATCH.INF').write_bytes(ANSWER_95.encode('ascii'))
        (tmp / 'out/NET').mkdir(parents=True)
        rc, so, err = sh(f'. "{REG95}"\nw9x_reg95_write "{(tmp / "out").as_posix()}" "{(tmp / "MSBATCH.INF").as_posix()}" '
                         f'"" "" "" "$V"', {'V': version})
        self.assertEqual(rc, 0, err)
        return (tmp / 'out/REG95.BAT').read_bytes().decode('ascii')

    def test_every_version_deletes_it_once_before_the_import(self):
        for version in ('4 0 0 950', '4 0 0 1111', '4 0 0 1216', ''):
            with self.subTest(version=version):
                text = self.batch(version)
                self.assertEqual(text.count(self.LINE + '\r\n'), 1)
                self.assertLessEqual(len(self.LINE), 125)
                at = text.index(self.LINE)
                # Once (after the REG95.OK / REG95.RUN guards and the journal),
                # with SYSTEM.DAT writable, in C:\WINDOWS, before the import.
                self.assertLess(text.index('IF EXIST C:\\USOS9X\\REG95.OK GOTO END'), at)
                self.assertLess(text.index('ECHO run> C:\\USOS9X\\REG95.RUN'), at)
                self.assertLess(text.index('CD \\WINDOWS'), at)
                self.assertLess(text.index('ATTRIB.EXE -S -R -H SYSTEM.DAT'), at)
                self.assertLess(at, text.index('REGEDIT /L:SYSTEM.DAT /R:USER.DAT C:\\USOS9X\\REG95.REG'))
                block = text[text.index('IF NOT EXIST C:\\USOS9X\\VESBIND.EXE GOTO ISSKIP'):text.index(':ISSKIP')]
                self.assertIn('COPY /Y SYSTEM.DAT C:\\USOS9X\\SYSTEM.RIS > NUL\r\nIF NOT EXIST C:\\USOS9X\\SYSTEM.RIS GOTO ISSKIP\r\n'
                              + self.LINE + '\r\nIF ERRORLEVEL 3 COPY /Y C:\\USOS9X\\SYSTEM.RIS SYSTEM.DAT > NUL\r\n'
                              'IF ERRORLEVEL 2 ECHO REG95: RunOnce InitShell not deleted, see ISDEL.LOG>> C:\\USOS9X\\USOSLOG.TXT\r\n', block)
                self.assertNotIn('GOTO END', block)          # fail-soft: the import always follows
                labels = re.findall(r'^:([A-Z0-9]+)\r?$', text, re.M)
                self.assertEqual(len(labels), len(set(labels)))


class Reg95Escaping(unittest.TestCase):
    """REGEDIT4 strings need doubled backslashes. The micro-Linux awk is not
    gawk: its gsub wrote one backslash for "\\\\", and 950's real-mode
    REGEDIT dropped every value with a path (X470 95 RTM PL, 2026-10-25:
    REG95CHK.REG without USOSLog / USOSDisplay / USOSLan, no USOSVmd)."""
    def test_posix_awk_doubles_backslashes(self):
        tmp = Path(tempfile.mkdtemp(prefix='usos-w9x-reg95esc-'))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        (tmp / 'MSBATCH.INF').write_bytes(ANSWER_95.encode('ascii'))
        (tmp / 'out').mkdir()
        for wrapper in ('', 'awk() { command awk --posix "$@"; }\n'):
            rc, so, err = sh(wrapper + f'. "{REG95}"\nw9x_reg95_write "{(tmp / "out").as_posix()}" '
                             f'"{(tmp / "MSBATCH.INF").as_posix()}" \'C:\\USOS9X\\USOSLOG.EXE\' \'C:\\USOS9X\\USOSVMD.INF\'', {})
            self.assertEqual(rc, 0, err)
            reg = (tmp / 'out/REG95.REG').read_bytes().decode('ascii')
            self.assertIn('"USOSLog"="C:\\\\USOS9X\\\\USOSLOG.EXE"\r\n', reg, wrapper)
            self.assertIn('"USOSLan"="C:\\\\USOS9X\\\\USOSLAN.EXE"\r\n', reg, wrapper)
            self.assertIn('DefaultInstall 4 C:\\\\USOS9X\\\\USOSVMD.INF"\r\n', reg, wrapper)
            self.assertIn('@="\\"C:\\\\Program Files\\\\Internet Explorer\\\\IEXPLORE.EXE\\""\r\n', reg, wrapper)
            # Every string value: a backslash only as \\ or \" (what 9x REGEDIT reads).
            for line in reg.split('\r\n'):
                if '="' in line:
                    self.assertIsNone(re.search(r'(?<!\\)\\(?![\\"])', re.sub(r'\\\\', '', line)), line)


class Late950(unittest.TestCase):
    r"""950: IE's Start Page / First Home Page and the Internet icon command
    (-> IEXPLORE.EXE, absent until the add-ons install IE) leave REG95.REG,
    which lands before Setup's first GUI boot (that boot hung in GRPCONV on
    the X470, 2026-10-25), for R95LATE.REG after RunOnce\Setup."""
    def write(self, version, answer=ANSWER_95):
        tmp = Path(tempfile.mkdtemp(prefix='usos-w9x-r95late-'))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        (tmp / 'MSBATCH.INF').write_bytes(answer.encode('ascii'))
        (tmp / 'out/NET').mkdir(parents=True)
        rc, so, err = sh(f'. "{REG95}"\nw9x_reg95_write "{(tmp / "out").as_posix()}" "{(tmp / "MSBATCH.INF").as_posix()}" '
                         f'"" "C:\\USOS9X\\USOSVMD.INF" "" "$V"', {'V': version})
        self.assertEqual(rc, 0, err)
        return tmp / 'out'

    def test_950_moves_the_ie_values_out_of_reg95(self):
        answer = ANSWER_95.replace('"Start Page",,"about:blank"\r\n',
                                   '"Start Page",,"about:blank"\r\nHKCU,"Software\\Microsoft\\Internet Explorer\\Main","First Home Page",,"about:blank"\r\n'
                                   'HKCU,"Software\\Microsoft\\Internet Explorer\\Main","Search Page",,"x"\r\n')
        out = self.write('4 0 0 950', answer)
        reg = (out / 'REG95.REG').read_bytes()
        for gone in (b'Start Page', b'First Home Page', b'FBF23B42', b'IEXPLORE'):
            self.assertNotIn(gone, reg)
        self.assertIn(b'"Search Page"="x"\r\n', reg)                        # other IE values stay
        self.assertIn(b'Internet Connection Wizard]\r\n"Completed"=hex:01,00,00,00', reg)
        late = (out / 'R95LATE.REG').read_bytes()
        self.assertEqual(late, b'REGEDIT4\r\n\r\n'
                         b'[HKEY_USERS\\.Default\\Software\\Microsoft\\Internet Explorer\\Main]\r\n'
                         b'"Start Page"="file://C:\\\\USOS9X\\\\START.HTM"\r\n'
                         b'"First Home Page"="file://C:\\\\USOS9X\\\\START.HTM"\r\n\r\n'
                         b'[HKEY_LOCAL_MACHINE\\SOFTWARE\\Classes\\CLSID\\{FBF23B42-E3F0-101B-8488-00AA003E56F8}\\Shell\\Open\\Command]\r\n'
                         b'@="\\"C:\\\\Program Files\\\\Internet Explorer\\\\IEXPLORE.EXE\\""\r\n\r\n')
        self.assertTrue((out / 'START.HTM').exists())
        self.assertFalse((out / 'R95LATE.NEW').exists())
        bat = (out / 'REG95.BAT').read_bytes().decode('ascii')
        self.assertIn('\r\nCALL C:\\USOS9X\\VMDLATE.BAT\r\nCALL C:\\USOS9X\\R95LATE.BAT\r\n', bat)
        self.assertLess(bat.index('R95LATE.BAT'), bat.index('REG95.OK GOTO END'))

    def test_other_versions_keep_them_in_reg95(self):
        for version in ('4 0 0 1111', '4 0 0 1212', ''):
            out = self.write(version)
            reg = (out / 'REG95.REG').read_bytes()
            self.assertIn(b'"Start Page"="file://C:\\\\USOS9X\\\\START.HTM"', reg, version)
            self.assertIn(b'FBF23B42', reg, version)
            self.assertFalse((out / 'R95LATE.REG').exists(), version)
            self.assertFalse((out / 'R95LATE.BAT').exists(), version)
            self.assertNotIn(b'R95LATE', (out / 'REG95.BAT').read_bytes(), version)

    def test_950_without_ie_values_has_no_late_step(self):
        answer = ANSWER_95.replace('HKCU,"Software\\Microsoft\\Internet Connection Wizard",Completed,1,01,00,00,00\r\n', '')
        answer = answer.replace('"Start Page",,"about:blank"', '"Other",,"x"')
        self.assertNotIn('Completed', answer)
        out = self.write('4 0 0 950', answer)
        self.assertFalse((out / 'R95LATE.REG').exists())
        self.assertFalse((out / 'R95LATE.NEW').exists())
        self.assertNotIn(b'R95LATE', (out / 'REG95.BAT').read_bytes())

    def test_batch_waits_for_setup_imports_once_and_checks(self):
        data = (self.write('4 0 0 950') / 'R95LATE.BAT').read_bytes()
        self.assertEqual(data.count(b'\n'), data.count(b'\r\n'))
        self.assertLessEqual(max(map(len, data.split(b'\r\n'))), 125)
        text = data.decode('ascii')
        labels = re.findall(r'^:([A-Z0-9]+)\r?$', text, re.M)
        self.assertEqual(len(labels), len(set(labels)))
        imp = text.index('REGEDIT /L:SYSTEM.DAT /R:USER.DAT C:\\USOS9X\\R95LATE.REG')
        for before in ('R95LATE.OK GOTO END', 'R95LATE.ERR GOTO END', 'NOT EXIST C:\\USOS9X\\REG95.OK GOTO END',
                       'IF EXIST C:\\USOS9X\\R95LATE.RUN GOTO FAIL', '"REGEDIT4" C:\\USOS9X\\RL1.REG',
                       '"\\RunOnce\\Setup]" C:\\USOS9X\\RL1.REG > NUL\r\nIF ERRORLEVEL 2 GOTO FAIL\r\nIF NOT ERRORLEVEL 1 GOTO PENDING',
                       'ECHO run> C:\\USOS9X\\R95LATE.RUN', 'ATTRIB.EXE -S -R -H SYSTEM.DAT', 'ATTRIB.EXE -S -R -H USER.DAT'):
            self.assertLess(text.index(before), imp, before)
        for after in ('ATTRIB.EXE +S +R +H USER.DAT', '/E C:\\USOS9X\\RL2.REG HKEY_USERS\\.Default\\Software\\Microsoft\r\n',
                      '/I "Start Page" C:\\USOS9X\\RL2.REG', '/E C:\\USOS9X\\RL3.REG HKEY_LOCAL_MACHINE\\SOFTWARE\\Classes\\CLSID\r\n',
                      '/I "IEXPLORE.EXE" C:\\USOS9X\\RL3.REG', 'ECHO ok> C:\\USOS9X\\R95LATE.OK', ':FAIL'):
            self.assertGreater(text.index(after), imp, after)
        failed = text[text.index(':FAIL'):text.index(':PENDING')]
        self.assertIn('>> C:\\USOS9X\\USOSLOG.TXT', failed)
        self.assertNotIn('PAUSE', text)


class Vmdlate950(unittest.TestCase):
    r"""950: Setup's first GUI boot rebuilds machine RunOnce; VMDLATE.BAT queues
    USOSVMD.INF again after RunOnce\Setup is gone when SYSTEM.INI lacks it."""
    def write(self, version, vmd='C:\\USOS9X\\USOSVMD.INF'):
        tmp = Path(tempfile.mkdtemp(prefix='usos-w9x-vmdlate-'))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        (tmp / 'MSBATCH.INF').write_bytes(ANSWER_95.encode('ascii'))
        (tmp / 'out').mkdir()
        (tmp / 'out/NET').mkdir()
        rc, so, err = sh(f'. "{REG95}"\nw9x_reg95_write "{(tmp / "out").as_posix()}" "{(tmp / "MSBATCH.INF").as_posix()}" '
                         f'"" "$VMD" "" "$V"', {'VMD': vmd, 'V': version})
        self.assertEqual(rc, 0, err)
        return tmp / 'out'

    def test_950_gets_the_fallback_others_do_not(self):
        out = self.write('4 0 0 950')
        bat = (out / 'REG95.BAT').read_bytes().decode('ascii')
        self.assertIn('\r\nCALL C:\\USOS9X\\VMDLATE.BAT\r\n', bat)
        self.assertLess(bat.index('VMDLATE.BAT'), bat.index('REG95.OK GOTO END'))
        self.assertEqual((out / 'VMDRO.REG').read_bytes(),
                         b'REGEDIT4\r\n\r\n[HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce]\r\n'
                         b'"USOSVmd"="rundll.exe setupx.dll,InstallHinfSection DefaultInstall 4 C:\\\\USOS9X\\\\USOSVMD.INF"\r\n\r\n')
        for version, vmd in (('4 0 0 1111', 'C:\\USOS9X\\USOSVMD.INF'), ('', 'C:\\USOS9X\\USOSVMD.INF'), ('4 0 0 950', '')):
            other = self.write(version, vmd)
            self.assertNotIn(b'VMDLATE', (other / 'REG95.BAT').read_bytes(), version)
            self.assertFalse((other / 'VMDLATE.BAT').exists(), version)
            self.assertFalse((other / 'VMDRO.REG').exists(), version)

    def test_950_reg95_has_no_runonce_vmd(self):
        # X470 95 RTM PL 2026-10-25: USOSVmd queued by REG95.REG before the
        # first GUI boot froze Setup inside RunOnce\Setup (GRPCONV).
        reg = (self.write('4 0 0 950') / 'REG95.REG').read_bytes()
        self.assertNotIn(b'USOSVmd', reg)
        self.assertNotIn(b'USOSVMD.INF', reg)
        self.assertNotIn(b'CurrentVersion\\RunOnce]', reg)
        self.assertIn(b'[HKEY_LOCAL_MACHINE\\Config\\0001\\Enum\\Root\\*PNP0F0E\\0000]\r\n"CSConfigFlags"=hex:06,00,00,00\r\n', reg)
        # OSR2 and an unknown version keep it (no VMDLATE there).
        for version in ('4 0 0 1111', ''):
            reg = (self.write(version) / 'REG95.REG').read_bytes()
            self.assertIn(b'"USOSVmd"="rundll.exe setupx.dll,InstallHinfSection DefaultInstall 4 C:\\\\USOS9X\\\\USOSVMD.INF"\r\n', reg, version)
            self.assertIn(b'CSConfigFlags', reg, version)

    def test_batch_gates_journal_and_dos_limits(self):
        data = (self.write('4 0 0 950') / 'VMDLATE.BAT').read_bytes()
        self.assertEqual(data.count(b'\n'), data.count(b'\r\n'))
        self.assertLessEqual(max(map(len, data.split(b'\r\n'))), 125)
        text = data.decode('ascii')
        labels = re.findall(r'^:([A-Z0-9]+)\r?$', text, re.M)
        self.assertEqual(len(labels), len(set(labels)))
        for guard in ('VMDLATE.ERR GOTO END', 'VMDLATE.OK GOTO END', 'NOT EXIST C:\\USOS9X\\USOSVMD.ON GOTO END',
                      'NOT EXIST C:\\USOS9X\\REG95.OK GOTO END'):
            self.assertLess(text.index(guard), text.index('FIND.EXE /I "USOSVMD.VXD"'))
        # SYSTEM.INI already has the line: done, nothing imported.
        sysini = text.index('FIND.EXE /I "USOSVMD.VXD" C:\\WINDOWS\\SYSTEM.INI')
        self.assertTrue(text[sysini:].split('\r\n')[2] == 'IF NOT ERRORLEVEL 1 GOTO DONE')
        # Only after RunOnce\Setup is gone, only when the value is not queued,
        # at most once (VMDLATE.RUN), then read back.
        imp = text.index('REGEDIT /L:SYSTEM.DAT /R:USER.DAT C:\\USOS9X\\VMDRO.REG')
        for before in ('"\\RunOnce\\Setup]" C:\\USOS9X\\VM1.REG', '"USOSVMD.INF" C:\\USOS9X\\VM1.REG',
                       'IF EXIST C:\\USOS9X\\VMDLATE.RUN GOTO FAIL', 'ECHO run> C:\\USOS9X\\VMDLATE.RUN',
                       'ATTRIB.EXE -S -R -H SYSTEM.DAT'):
            self.assertLess(text.index(before), imp, before)
        self.assertGreater(text.index('"USOSVMD.INF" C:\\USOS9X\\VM2.REG'), imp)
        self.assertGreater(text.index('ATTRIB.EXE +S +R +H SYSTEM.DAT'), imp)
        # RunOnce\Setup present: PENDING, checked first in the export; a
        # missing RunOnce key queues only with REGEDIT's REGEDIT4 header.
        setup = text.index('"\\RunOnce\\Setup]" C:\\USOS9X\\VM1.REG')
        self.assertEqual(text[setup:].split('\r\n')[1:3], ['IF ERRORLEVEL 2 GOTO FAIL', 'IF NOT ERRORLEVEL 1 GOTO PENDING'])
        self.assertLess(setup, text.index('"\\RunOnce]" C:\\USOS9X\\VM1.REG'))
        nokey = text[text.index(':NOKEY\r\n'):text.index(':QUEUE\r\n')]
        self.assertIn('"REGEDIT4" C:\\USOS9X\\VM1.REG', nokey)
        self.assertIn('IF ERRORLEVEL 1 GOTO FAIL', nokey)
        self.assertLess(setup, text.index(':NOKEY\r\n'))
        self.assertLess(text.index(':QUEUE\r\n'), imp)
        fail = text[text.index(':FAIL\r\n'):text.index(':PENDING\r\n')]
        self.assertIn('>> C:\\USOS9X\\USOSLOG.TXT', fail)
        self.assertNotIn('PAUSE', text)
        self.assertNotIn('SYSTEM.INI\r\n', text.replace('C:\\WINDOWS\\SYSTEM.INI GOTO FAIL', ''))  # never rewritten
        self.assertNotIn('>C:\\WINDOWS\\SYSTEM.INI', text.replace(' ', ''))


def target_block(start, end):
    text = TARGET.read_text(encoding='utf-8')
    return text[text.index(start):text.index(end)]


class Wiring(unittest.TestCase):
    def run_block(self, tag, kind='USOS', log_ok='1', answer=None, vmd_ok='0', lib=None):
        tmp = Path(tempfile.mkdtemp(prefix='usos-w9x-reg95block-'))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        (tmp / 'c/USOS9X').mkdir(parents=True)
        for name in ('USOSVMD.VXD', 'USOSVMD.ON', 'USOSVMD.INF'):
            (tmp / 'c/USOS9X' / name).write_bytes(b'stand-in')
        (tmp / 'c/USOS9X/MSBATCH.INF').write_bytes((answer or DEFAULT_INF.read_text(encoding='ascii').replace('\n', '\r\n')).encode('ascii'))
        text = TARGET.read_text(encoding='utf-8')
        helper = text[text.index('w9x_98fe_channelbar_answer() {'):text.index('\nfor tool in ')]
        block = target_block('if [ "$SYSTEM_TAG" = 95 ]; then\n    vesa95_source=', '# The boot floppy runs INSTALL.BAT')
        script = ('set -eu\nlog() { printf "%s\\n" "$*"; }\nfail() { echo "FAIL $*"; exit 9; }\n' + helper + '\n'
                  f'SYSTEM_TAG={tag}\nANSWER_KIND={kind}\nlog_ok={log_ok}\nvmd_ok={vmd_ok}\nSETUP_FOLDER=WIN95\nw95_net_late=\n'
                  f'LIB="{(lib or ROOT / "tools").as_posix()}"\nwork="{tmp.as_posix()}"\n' + block)
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

    def test_vmd_on_95_through_reg95(self):
        d, _ = self.run_block('95', vmd_ok='1')
        reg = (d / 'REG95.REG').read_bytes()
        self.assertIn(b'"USOSVmd"="rundll.exe setupx.dll,InstallHinfSection DefaultInstall 4 C:\\\\USOS9X\\\\USOSVMD.INF"\r\n', reg)
        self.assertIn(b'[HKEY_LOCAL_MACHINE\\Config\\0001\\Enum\\Root\\*PNP0F0E\\0000]\r\n"CSConfigFlags"=hex:06,00,00,00\r\n', reg)
        self.assertTrue((d / 'USOSVMD.VXD').exists())
        d, _ = self.run_block('95', vmd_ok='0')
        reg = (d / 'REG95.REG').read_bytes()
        self.assertNotIn(b'USOSVmd', reg)
        self.assertNotIn(b'PNP0F0E', reg)
        # No REG95.BAT (here: no w9x_reg95.sh): the VMD files go, nothing half on.
        nolib = Path(tempfile.mkdtemp(prefix='usos-w9x-nolib-'))
        self.addCleanup(shutil.rmtree, nolib, ignore_errors=True)
        (nolib / 'w9x_vesa95.sh').write_bytes((ROOT / 'tools/w9x_vesa95.sh').read_bytes())
        d, out = self.run_block('95', vmd_ok='1', lib=nolib)
        self.assertFalse((d / 'REG95.BAT').exists())
        for name in ('USOSVMD.VXD', 'USOSVMD.ON', 'USOSVMD.INF'):
            self.assertFalse((d / name).exists(), name)
        self.assertIn('USOSVMD.VXD removed again', out)
        # 98 SE keeps its files (its RunOnce comes from [USOS.CsmReg]).
        d, _ = self.run_block('98SE', vmd_ok='1')
        self.assertTrue((d / 'USOSVMD.VXD').exists())

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
