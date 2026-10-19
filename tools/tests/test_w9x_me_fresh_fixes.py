"""Host tests for the fixes after the X470 Windows Me fresh install of
2026-10-20 (build B261019-210547-5FDA8767): usosnet driver file, first-start
password dialog, ICW desktop link on the common desktop. No Windows run."""
from pathlib import Path
import hashlib
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SH = shutil.which('sh') or r'C:\Program Files\Git\usr\bin\sh.exe'
ENV = dict(os.environ, PATH=str(Path(SH).parent) + os.pathsep + os.environ.get('PATH', ''))
INSTALL = ROOT / 'src/platform/bios/dos_startup.cmd'
PWL = ROOT / 'src/platform/bios/win9x/usosme.pwl'
STOCK = ROOT / 'src/platform/bios/win9x/msbatch.inf'


def q(p):
    return "'" + str(p).replace('\\', '/') + "'"


def shell(code):
    return subprocess.run([SH, '-c', '. ' + q(ROOT / 'tools/w9x_logon.sh') + '; ' + code],
                          cwd=ROOT, env=ENV, capture_output=True)


def lines():
    return INSTALL.read_text(encoding='latin-1').splitlines()


class UsosnetFile(unittest.TestCase):
    def test_me_copies_driver_into_system_before_setup(self):
        text = lines()
        me = text.index('IF NOT "%U9SYS%"=="ME" GOTO CSMREG')
        md = text.index('MD C:\\WINDOWS\\SYSTEM', me)
        copy = text.index('IF EXIST C:\\%U9SRC%\\USOSNET.SYS COPY /Y C:\\%U9SRC%\\USOSNET.SYS C:\\WINDOWS\\SYSTEM >NUL', me)
        self.assertLess(md, copy)
        # The Setup folder copy exists by then (network staging comes first).
        self.assertLess(text.index('COPY /Y %U9T%\\NET\\USOSNET.SYS C:\\%U9SRC% >NUL'), copy)
        # Before Setup starts.
        self.assertLess(copy, text.index('C:\\%U9SRC%\\SETUP.EXE C:\\%U9SRC%\\MSBATCH.INF %U9SW%'))

    def test_95_98_autoexec_copy_inside_system_guard(self):
        text = lines()
        guard = text.index('ECHO @IF NOT EXIST C:\\WINDOWS\\SYSTEM\\NUL GOTO USOSDRV>C:\\AUTOEXEC.BAT')
        line = 'ECHO @IF NOT EXIST C:\\WINDOWS\\SYSTEM\\USOSNET.SYS COPY C:\\%U9SRC%\\USOSNET.SYS C:\\WINDOWS\\SYSTEM>>C:\\AUTOEXEC.BAT'
        self.assertLess(guard, text.index(line))
        self.assertLess(text.index(line), text.index('ECHO :USOSDRV>>C:\\AUTOEXEC.BAT'))
        # Only written when the driver was staged.
        self.assertEqual(text[text.index(line) - 1], 'IF NOT EXIST C:\\%U9SRC%\\USOSNET.SYS GOTO NETAUTO')
        # The firmware-CSM AUTOEXEC.BAT has its own guarded line.
        self.assertIn('ECHO @IF EXIST C:\\WINDOWS\\SYSTEM\\NUL IF NOT EXIST C:\\WINDOWS\\SYSTEM\\USOSNET.SYS '
                      'COPY C:\\%U9SRC%\\USOSNET.SYS C:\\WINDOWS\\SYSTEM>>C:\\AUTOEXEC.BAT', text)

    def test_inf_still_names_the_file_setup_does_not_copy(self):
        inf = (ROOT / 'tools/nt/usosnet/inf/usosnet9x.inf').read_text(encoding='latin-1')
        self.assertIn('HKR,,DeviceVxDs,,usosnet.sys', inf)
        self.assertIn('USOSNET.CopyFiles=11', inf)


class FirstLogon(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='w9xlogon-', dir=ROOT / 'artifacts'))
        self.addCleanup(shutil.rmtree, self.tmp)

    def test_pwl_data_is_the_x470_empty_password_list(self):
        data = PWL.read_bytes()
        self.assertEqual(len(data), 688)
        self.assertEqual(data[:4], bytes.fromhex('e3828596'))
        self.assertEqual(hashlib.sha256(data).hexdigest(),
                         '3e5577fd9022f092ad2d8d3a63192f143cddf072bf006c08457d0f2448b2d42c')

    def test_wanted_only_for_me_usos_answers_with_user_usos(self):
        stock = self.tmp / 'stock.inf'
        stock.write_bytes(STOCK.read_bytes())
        self.assertEqual(shell('usos_w9x_pwl_wanted ' + q(stock) + ' ME USOS').returncode, 0)
        self.assertEqual(shell('usos_w9x_pwl_wanted ' + q(stock) + ' ME PROFILE').returncode, 0)
        for system, kind in (('ME', 'USER'), ('98SE', 'USOS'), ('95', 'USOS')):
            self.assertNotEqual(shell('usos_w9x_pwl_wanted ' + q(stock) + ' ' + system + ' ' + kind).returncode, 0)
        other = self.tmp / 'tester.inf'
        other.write_text(STOCK.read_text().replace('DefaultUserName,,"USOS"', 'DefaultUserName,,"Tester"'))
        self.assertNotEqual(shell('usos_w9x_pwl_wanted ' + q(other) + ' ME PROFILE').returncode, 0)
        own = self.tmp / 'own.inf'
        own.write_text(STOCK.read_text() + '\n[Mine]\nsystem.ini,"Password Lists",,"X=C:\\X.PWL"\n')
        self.assertNotEqual(shell('usos_w9x_pwl_wanted ' + q(own) + ' ME PROFILE').returncode, 0)

    def test_answer_keeps_usos_csm_last_and_adds_both_sections(self):
        stock = self.tmp / 'stock.inf'
        stock.write_bytes(STOCK.read_bytes())
        r = shell('usos_w9x_pwl_answer ' + q(stock))
        self.assertEqual(r.returncode, 0, r.stderr)
        out = r.stdout
        self.assertIn(b'AddReg=USOS.RunOnce,USOS.CsmReg,USOS.Lan,USOS.Addons,USOS.PwlReg\r\n', out)
        self.assertIn(b'UpdateInis=USOS.Memory,USOS.Pwl\r\n', out)
        self.assertIn(b'[USOS.Pwl]\r\nsystem.ini,"Password Lists",,"USOS=C:\\WINDOWS\\USOS.PWL"\r\n', out)
        self.assertIn(b'[USOS.PwlReg]\r\nHKLM,"Network\\Logon",username,,"USOS"\r\n', out)
        self.assertTrue(out.endswith(b'[USOS.Csm]\r\n'), out[-200:])
        self.assertNotIn(b'\n', out.replace(b'\r\n', b''))
        broken = self.tmp / 'broken.inf'
        broken.write_text('[Install]\nAddReg=A\n')
        self.assertNotEqual(shell('usos_w9x_pwl_answer ' + q(broken)).returncode, 0)

    def test_target_block_stages_list_and_install_bat_copies_it(self):
        text = (ROOT / 'tools/w9x_csmwrap_target.sh').read_text()
        start = text.index('# Me, stock user USOS')
        end = text.index('. "$LIB/network_setup.sh"', start)
        lib = self.tmp / 'lib'
        (lib / 'w9x').mkdir(parents=True)
        shutil.copy(ROOT / 'tools/w9x_logon.sh', lib / 'w9x_logon.sh')
        shutil.copy(PWL, lib / 'w9x/USOSME.PWL')
        pre = 'fail() { echo "$*" >&2; exit 1; }; log() { echo "LOG $*"; }; '
        for system, kind, expect in (('ME', 'USOS', True), ('ME', 'USER', False), ('98SE', 'USOS', False)):
            work = self.tmp / ('w-' + system + kind)
            (work / 'c/USOS9X').mkdir(parents=True)
            (work / 'c/USOS9X/MSBATCH.INF').write_bytes(STOCK.read_bytes())
            env = 'LIB=' + q(lib) + ' work=' + q(work) + ' SYSTEM_TAG=' + system + ' ANSWER_KIND=' + kind + '; '
            r = subprocess.run([SH, '-c', pre + env + text[start:end]], cwd=ROOT, env=ENV, capture_output=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            staged = (work / 'c/USOS9X/MSBATCH.INF').read_bytes()
            self.assertEqual((work / 'c/USOS9X/USOS.PWL').is_file(), expect)
            self.assertEqual(b'[USOS.Pwl]' in staged, expect)
            if expect:
                self.assertEqual((work / 'c/USOS9X/USOS.PWL').read_bytes(), PWL.read_bytes())
        text = lines()
        me = text.index('IF NOT "%U9SYS%"=="ME" GOTO CSMREG')
        self.assertLess(text.index('MD C:\\WINDOWS', me),
                        text.index('IF EXIST C:\\USOS9X\\USOS.PWL COPY /Y C:\\USOS9X\\USOS.PWL C:\\WINDOWS >NUL', me))

    def test_payload_carries_the_script_and_list(self):
        builder = (ROOT / 'tools/build_micro_linux.py').read_text()
        self.assertIn('("tools/w9x_logon.sh", "usr/lib/usos/w9x_logon.sh")', builder)
        self.assertIn('"usr/lib/usos/w9x/USOSME.PWL"', builder)


class IcwCommonDesktop(unittest.TestCase):
    def test_9x_helper_scans_the_common_desktop(self):
        src = (ROOT / 'tools/windows_usos_lan.c').read_text()
        body = src[src.index('static void shortcuts(void)'):src.index('#ifdef USOS_LAN_NT\n/* Same Default User')]
        self.assertIn('desktop_links(HKEY_LOCAL_MACHINE,"Common Desktop",create);', body)
        before = body[:body.index('"Common Desktop"')]
        self.assertNotIn('#ifdef', before)


if __name__ == '__main__':
    unittest.main()
