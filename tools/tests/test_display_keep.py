"""Host tests only: the "keep Windows' own mode" option (docs/display-policy.md).

A profile's display=keep (request keepx..., settings display=keep) or DATA's
Systems\\<category>\\<version>\\Unattended\\display-keep.txt (USOS_DISPLAY_KEEP=1)
stages no USOSRES and registers nothing, for every family that has the
automatic resolution: 9x, NT 3.5x / 4.0, 2000, XP / 2003, POSReady
(tools/tests/test_display_posready.py) and the 6.x CSMWrap paths. The staging
blocks run on scratch folders; no Windows install, VM or physical disk.
"""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/tests'))
from test_nt4_flow import function_text

OUT = ROOT / 'artifacts/display-keep/host'
SH = shutil.which('sh') or r'C:\Program Files\Git\usr\bin\sh.exe'
ENV = dict(os.environ, PATH=str(Path(SH).parent) + os.pathsep + os.environ.get('PATH', ''))
GOLDEN = ROOT / 'src/flow/answer/testdata/golden'
FIXTURE = b'own helper fixture'


def shell(code):
    return subprocess.run([SH, '-c', code], cwd=ROOT, env=ENV, capture_output=True)


def quote(p):
    return "'" + str(p).replace('\\', '/') + "'"


def block(path, start, end):
    text = (ROOT / path).read_text(encoding='utf-8')
    i = text.index(start)
    return text[i:text.index(end, i)]


class Keep(unittest.TestCase):
    def setUp(self):
        OUT.mkdir(parents=True, exist_ok=True)
        self.tmp = Path(tempfile.mkdtemp(prefix='keep-', dir=OUT))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.lib = self.tmp / 'lib'
        (self.lib / 'w9x-display').mkdir(parents=True)
        shutil.copy(ROOT / 'tools/display_profile.sh', self.lib / 'display_profile.sh')
        for name in ('USOSRES.EXE', 'w9x-display/USOSRES.EXE', 'w9x-display/USOSVBI.EXE'):
            (self.lib / name).write_bytes(FIXTURE)
        self.pre = 'fail() { echo "$*" >&2; exit 1; }; log() { echo "LOG $*"; }; modprobe() { :; }; mount() { :; }; umount() { :; }; '
        self.pre += 'USOS_DISPLAY_NATIVE_FILE=' + quote(self.tmp / 'none') + '; '

    def test_keep_predicate(self):
        lib = '. ' + quote(ROOT / 'tools/display_profile.sh') + '; '
        for request, env, expected in (('keepxauto', '', 0), ('keep', '', 0), ('autoxauto', '', 1), ('', '', 1),
                                       ('1920x1080xauto', '', 1), ('autoxauto', 'USOS_DISPLAY_KEEP=1 ', 0),
                                       ('', 'USOS_DISPLAY_KEEP=1 ', 0), ('', 'USOS_DISPLAY_KEEP=0 ', 1)):
            r = shell(lib + env + "usos_display_keep '" + request + "'")
            self.assertEqual(r.returncode, expected, (request, env))
        # keep is no mode: the stage refuses it, so a caller cannot stage it by mistake.
        self.assertNotEqual(shell(lib + 'usos_display_valid keepxauto').returncode, 0)

    def w9x(self, answer, kind, env=''):
        work = Path(tempfile.mkdtemp(prefix='w9x-', dir=self.tmp))
        target = work / 'c/USOS9X'; target.mkdir(parents=True)
        source = work / 'answer.inf'; source.write_bytes(answer)
        (target / 'MSBATCH.INF').write_bytes(answer)
        code = block('tools/w9x_csmwrap_target.sh', "display_request=\nif grep -q '^;USOS-DISPLAY='", '# Me, stock user USOS')
        r = shell(self.pre + env + 'LIB=' + quote(self.lib) + ' work=' + quote(work) + ' ANSWER_INF=' + quote(source) + ' ANSWER_KIND=' + kind + '; ' + code)
        self.assertEqual(r.returncode, 0, r.stderr)
        return target, r.stdout

    def test_9x_keep_request_and_flag(self):
        plain = b'[Install]\r\nAddReg=USOS.RunOnce\r\n[USOS.Csm]\r\n'
        for answer, kind, env in ((b';USOS-DISPLAY=keepxauto\r\n' + plain, 'PROFILE', ''),
                                  (plain, 'USOS', 'USOS_DISPLAY_KEEP=1; '),
                                  (b';USOS-DISPLAY=1920x1080x32\r\n' + plain, 'PROFILE', 'USOS_DISPLAY_KEEP=1; ')):
            target, out = self.w9x(answer, kind, env)
            for name in ('DISPLAY.TXT', 'USOSRES.EXE', 'USOSVBI.EXE'):
                self.assertFalse((target / name).exists(), (name, kind, env))
            # The answer stays as rendered: no [USOS.Display], the INF's first mode stays.
            self.assertEqual((target / 'MSBATCH.INF').read_bytes(), answer)
            self.assertIn(b'display: keep', out)
        # Without keep the default auto still stages (unchanged behaviour).
        target, _ = self.w9x(plain, 'USOS', 'USOS_DISPLAY_KEEP=0; ')
        self.assertEqual((target / 'DISPLAY.TXT').read_bytes(), b'autoxauto\r\n')

    def nt4(self, answer, kind, vesa=True, env=''):
        usos = Path(tempfile.mkdtemp(prefix='nt4-', dir=self.tmp))
        if vesa:
            (usos / 'VESA.REG').write_bytes(b'REGEDIT4\r\n; driver\r\n')
        sif = usos / 'unattend.txt'; sif.write_bytes(answer)
        code = block('tools/nt4_csmwrap_target.sh', 'nt4_display_request=\nif [ -z "$nt3" ]', '\nfor file in "$SYSLINUX_DIR')
        r = shell(self.pre + env + 'LIB=' + quote(self.lib) + ' ANSWER_SIF=' + quote(sif) + ' ANSWER_KIND=' + kind + ' usos=' + quote(usos) + " nt3='' nt31=''; " + code)
        self.assertEqual(r.returncode, 0, r.stderr)
        return usos

    def test_nt4_keep_keeps_vesa_first_mode(self):
        for answer, kind, vesa, env in ((b'[Unattended]\r\n;USOS-DISPLAY=keepxauto\r\n', 'PROFILE', True, ''),
                                        (b'[Unattended]\r\n;USOS-DISPLAY=keepxauto\r\n', 'PROFILE', False, ''),
                                        (b'[Unattended]\r\n', 'USOS', True, 'USOS_DISPLAY_KEEP=1; ')):
            usos = self.nt4(answer, kind, vesa, env)
            self.assertFalse((usos / 'DISPLAY.TXT').exists())
            self.assertFalse((usos / 'USOSRES.EXE').exists())
            if vesa:
                self.assertEqual((usos / 'VESA.REG').read_bytes(), b'REGEDIT4\r\n; driver\r\n')
        usos = self.nt4(b'[Unattended]\r\n', 'USOS')
        self.assertEqual((usos / 'DISPLAY.TXT').read_bytes(), b'autoxauto\r\n')

    def test_nt3_keep_request(self):
        for answer, env in ((b';USOS-DISPLAY=keepxauto\r\n', ''), (b';USOS-DISPLAY=1024x768x16\r\n', 'USOS_DISPLAY_KEEP=1; ')):
            nt = self.tmp / ('NT3' + str(len(env))); nt.mkdir()
            sif = nt / 'unattend.txt'; sif.write_bytes(answer)
            code = function_text(ROOT / 'tools/nt4_csmwrap_target.sh', 'nt3_stage_profile') + '; nt3_stage_profile'
            r = shell(self.pre + env + 'LIB=' + quote(self.lib) + ' work=' + quote(self.tmp) + ' ANSWER_SIF=' + quote(sif) + ' usos=' + quote(nt) + " nt3=1 nt31=''; " + code)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertFalse((nt / 'DISPLAY.TXT').exists())
            self.assertIn(b'DISPLAY keep', r.stdout)

    def test_2000_keep_keeps_vesa_without_helper(self):
        pkg, source = self.tmp / 'pkg', self.tmp / 'source'
        (pkg / 'usosvbe').mkdir(parents=True); source.mkdir()
        (pkg / 'usosvbe/usosvbe.sys').write_bytes(b'own fixture')
        (pkg / 'USOSRES.EXE').write_bytes(FIXTURE)
        shutil.copy(ROOT / 'tools/display_profile.sh', pkg / 'display_profile.sh')
        settings = self.tmp / 'settings.ini'
        for text, env in (('family=2000\ndisplay=keep\ndisplay_bpp=auto\n', ''), ('family=2000\n', 'USOS_DISPLAY_KEEP=1 ')):
            dest = self.tmp / ('dest' + str(len(env))); dest.mkdir()
            settings.write_text(text)
            code = '. ' + quote(ROOT / 'tools/w2k_stage.sh') + '; ' + env
            code += 'USOS_W2K_DIR=' + quote(pkg) + ' USOS_LIB_DIR=' + quote(pkg) + ' XP_USER_SETTINGS=' + quote(settings)
            code += ' usos_w2k_vesa_stage ' + quote(dest) + ' ' + quote(source)
            r = shell(code)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn(b'DISPLAY keep', r.stdout)
            self.assertFalse((dest / 'DISPLAY.TXT').exists())
            self.assertFalse((dest / 'DISPLAY.REG').exists())
            self.assertNotIn(b'DISPLAY.REG', (dest / 'vesa.cmd').read_bytes())
            self.assertIn(b'"DefaultSettings.XResolution"=dword:00000400', (dest / 'VESA.REG').read_bytes())

    def test_xp_2003_keep_stages_and_registers_nothing(self):
        script = ROOT / 'tools/prepare_xp_ntfs_target.sh'
        funcs = function_text(script, 'usos_nt52_display_stage') + '; '
        setup = self.tmp / 'vol/USOS/XP'; setup.mkdir(parents=True)
        settings = self.tmp / 'usos-xp.ini'
        sif = self.tmp / 'user.sif'; sif.write_bytes(b'[Unattended]\r\n')
        for system, text, custom, env in (('windows-xp', 'user=Bob\nfamily=xp\ndisplay=keep\n', '', ''),
                                          ('windows-server-2003', 'user=Bob\nfamily=2003\ndisplay=keep\n', '', ''),
                                          ('windows-xp', '', quote(sif), 'USOS_DISPLAY_KEEP=1; '),
                                          ('windows-xp', 'user=Bob\nfamily=xp\ndisplay=1280x1024\n', '', 'USOS_DISPLAY_KEEP=1; ')):
            settings.write_text(text)
            pre = self.pre.replace('log() { echo "LOG $*"; }; ', '') + env + 'SCRIPT_DIR=' + quote(self.lib) + '; '
            pre += 'NT5_SYSTEM=' + system + ' XP_USER_SETTINGS=' + (quote(settings) if text else "''") + ' XP_CUSTOM_SIF=' + (custom or "''") + '; '
            r = shell(pre + funcs + 'line=$(usos_nt52_display_stage ' + quote(setup) + ') && [ -z "$line" ]')
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn(b'DISPLAY keep', r.stderr)
            self.assertFalse((setup / 'DISPLAY.TXT').exists())
            self.assertFalse((setup / 'USOSRES.EXE').exists())

    def test_xp_settings_keep_writes_no_display_section(self):
        lib = '. ' + quote(ROOT / 'tools/xp_user_settings.sh') + '; '
        settings = self.tmp / 'profile.ini'; settings.write_text('user=Bob\nfamily=xp\ndisplay=keep\n')
        normalized = self.tmp / 'normalized.ini'
        r = shell(lib + 'usos_xp_settings_load ' + quote(settings) + ' ' + quote(normalized) + ' 00000415 profile')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('display=keep\n', normalized.read_text())
        r = shell(lib + 'usos_xp_settings_sif ' + quote(ROOT / 'tools/xp_selected_partition_uefi_csm.sif') + ' ' + quote(normalized))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn(b'[Display]', r.stdout)
        self.assertNotIn(b'resolution=keep', r.stdout.lower())

    def nt6(self, answer, env=''):
        work = Path(tempfile.mkdtemp(prefix='nt6-', dir=self.tmp))
        path = ''
        if answer is not None:
            path = str(work / 'answer.xml'); Path(path).write_bytes(answer)
        code = block('tools/vista_csmwrap_target.sh', '# 2b. Display', '# 3. The PE10 donor')
        r = shell(self.pre + env + 'LIB=' + quote(self.lib) + ' work=' + quote(work) + ' ANSWER_XML=' + quote(path) + ' windows_node=/dev/null; ' + code)
        self.assertEqual(r.returncode, 0, r.stderr)
        return work / 'windows/USOS/NT6', r.stdout

    def test_nt6_keep_answer_and_flag(self):
        cases = [[(GOLDEN / 'display-keep.windows-7.x86.xml').read_bytes(), ''], [(GOLDEN / 'display-keep.windows-10.x86.xml').read_bytes(), '']]
        cases += [[None, 'USOS_DISPLAY_KEEP=1; '], [b'<unattend/>\n', 'USOS_DISPLAY_KEEP=1; '],
                  [(GOLDEN / 'full.windows-7.x86.xml').read_bytes(), 'USOS_DISPLAY_KEEP=1; ']]
        for answer, env in cases:
            folder, out = self.nt6(answer, env)
            self.assertFalse(folder.exists(), env)
            self.assertIn(b'DISPLAY keep', out)
        folder, _ = self.nt6(None, 'USOS_DISPLAY_KEEP=0; ')
        self.assertEqual((folder / 'DISPLAY.TXT').read_bytes(), b'autoxauto\r\n')

    def test_prepare_scripts_read_the_data_flag(self):
        fn = function_text(ROOT / 'tools/vista_csmwrap_prepare.sh', 'vista_display_keep')
        data = self.tmp / 'data'
        flag = data / 'Systems/Windows/Windows 7/Unattended'; flag.mkdir(parents=True)
        self.assertNotEqual(shell(fn + "; vista_display_keep " + quote(data) + " 'Windows 7'").returncode, 0)
        (flag / 'display-keep.txt').write_bytes(b'')
        self.assertEqual(shell(fn + "; vista_display_keep " + quote(data) + " 'Windows 7'").returncode, 0)
        self.assertEqual(shell(fn + "; vista_display_keep " + quote(data) + " x 'Systems/Windows/Windows 7'").returncode, 0)
        self.assertNotEqual(shell(fn + "; vista_display_keep " + quote(data) + " 'Windows 10'").returncode, 0)
        vista = (ROOT / 'tools/vista_csmwrap_prepare.sh').read_text(encoding='utf-8')
        self.assertIn('USOS_DISPLAY_KEEP=$display_keep TARGET_DEVICE=$TARGET_DEVICE', vista)
        w9x = (ROOT / 'tools/w9x_csmwrap_prepare.sh').read_text(encoding='utf-8')
        i = w9x.index('/Unattended/display-keep.txt')
        self.assertLess(w9x.index('export USOS_DISPLAY_KEEP', i), w9x.index('sh /usr/lib/usos/posready_csmwrap_target.sh', i))
        nt5 = (ROOT / 'tools/legacy_xp_staging.sh').read_text(encoding='utf-8')
        i = nt5.index('/Unattended/display-keep.txt')
        self.assertLess(nt5.index('export USOS_DISPLAY_KEEP', i), nt5.index('XP_SOURCE_OPEN=yes', i))


if __name__ == '__main__':
    unittest.main()
