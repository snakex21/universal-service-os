"""Host tests only: profile transport, executable imports and mode transactions.

No display API is called on the host, no Windows install or physical disk.
Set USOS_ZIG / USOS_WATCOM when the compilers are outside this worktree.
"""
from pathlib import Path
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'tools'))
sys.path.insert(0, str(ROOT/'tools/tests'))
from build_windows_usos_res import build, build_collector
from check_nt52_driver_imports import pe

OUT = ROOT/'artifacts/display-from-profile/host'
OUT.mkdir(parents=True, exist_ok=True)
tempfile.tempdir = str(OUT)
SH = shutil.which('sh') or r'C:\Program Files\Git\usr\bin\sh.exe'
ENV = dict(os.environ, PATH=str(Path(SH).parent)+os.pathsep+os.environ.get('PATH', ''))


def shell(code):
    return subprocess.run([SH, '-c', code], cwd=ROOT, env=ENV, capture_output=True)


def quote(p):
    return "'"+str(p).replace('\\', '/')+"'"


def exports(name):
    result, current = {}, None
    for line in (ROOT/'tools/tests/data'/name).read_text().splitlines():
        if not line or line.startswith('#'):
            continue
        if line.startswith('['):
            current = result.setdefault(line[1:-1].lower(), set())
        else:
            current.add(line.split(' -> ')[0])
    return result


class DisplayTransport(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='transport-'))
        self.addCleanup(shutil.rmtree, self.tmp)
        self.lib = '. '+quote(ROOT/'tools/display_profile.sh')+'; '

    def test_run_registry_is_crlf_and_escaped(self):
        r = shell(self.lib+'usos_display_run_reg W2K')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, b'REGEDIT4\r\n\r\n[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run]\r\n"USOSDisplay"="C:\\\\USOS\\\\W2K\\\\USOSRES.EXE"\r\n')
        self.assertNotEqual(shell(self.lib+'usos_display_run_reg XP').returncode, 0)

    def test_token_staging_rejects_injection_and_duplicate_metadata(self):
        source = self.tmp/'answer.inf'
        source.write_bytes(b';USOS-DISPLAY=1920x1080x16\r\n')
        self.assertEqual(shell(self.lib+'usos_display_from_answer '+quote(source)).stdout, b'1920x1080x16\n')
        source.write_bytes(source.read_bytes()*2)
        self.assertNotEqual(shell(self.lib+'usos_display_from_answer '+quote(source)).returncode, 0)
        exe = self.tmp/'fake.exe'
        exe.write_bytes(b'own test placeholder')
        r = shell(self.lib+'usos_display_stage '+quote(self.tmp)+' '+quote(exe)+" '1920x1080x16;echo bad'")
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse((self.tmp/'DISPLAY.TXT').exists())
        r = shell(self.lib+'usos_display_stage '+quote(self.tmp)+' '+quote(exe)+" 'autoxauto'")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.tmp/'DISPLAY.TXT').read_bytes(), b'autoxauto\r\n')

    def test_stage_appends_prep_time_native_size(self):
        exe = self.tmp/'fake.exe'; exe.write_bytes(b'own test placeholder')
        record = self.tmp/'display-native.txt'
        stage = 'USOS_DISPLAY_NATIVE_FILE='+quote(record)+' usos_display_stage '+quote(self.tmp)+' '+quote(exe)+' autoxauto'
        for text, expected in ((b'2560x1440\r\n', b'autoxauto\r\nnative=2560x1440\r\n'),
                               (b'3840x2160', b'autoxauto\r\nnative=3840x2160\r\n'),
                               (b'100x100\r\n', b'autoxauto\r\n'), (b'2560x1440;x\r\n', b'autoxauto\r\n'),
                               (b'99999x1440\r\n', b'autoxauto\r\n'), (None, b'autoxauto\r\n')):
            if text is None: record.unlink()
            else: record.write_bytes(text)
            r = shell(self.lib+stage)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual((self.tmp/'DISPLAY.TXT').read_bytes(), expected, text)

    def test_xp_2003_stage_helper_and_register_before_exit(self):
        from test_nt4_flow import function_text
        lib = self.tmp/'lib'; lib.mkdir()
        shutil.copy(ROOT/'tools/display_profile.sh', lib/'display_profile.sh')
        (lib/'USOSRES.EXE').write_bytes(b'own helper fixture')
        settings = self.tmp/'usos-xp.ini'
        setup = self.tmp/'vol/USOS/XP'; setup.mkdir(parents=True)
        cmd = self.tmp/'accounts.cmd'
        script = ROOT/'tools/prepare_xp_ntfs_target.sh'
        funcs = function_text(script, 'usos_nt52_display_stage')+'; '+function_text(script, 'usos_nt52_insert_before_exit')+'; '
        pre = 'fail() { echo "$*" >&2; exit 1; }; SCRIPT_DIR='+quote(lib)+' USOS_DISPLAY_NATIVE_FILE='+quote(self.tmp/'none')+'; '
        run = 'line=$(usos_nt52_display_stage '+quote(setup)+') && [ -n "$line" ] && usos_nt52_insert_before_exit '+quote(cmd)+' "$line"'
        for system, text, request in (('windows-xp', 'user=Bob\nfamily=xp\n', b'autoxauto\r\n'),
                                      ('windows-server-2003', 'user=Bob\nfamily=2003\ndisplay=1280x1024\n', b'1280x1024xauto\r\n')):
            settings.write_text(text)
            cmd.write_bytes(b'@echo off\r\nnet user Bob /add\r\nexit /b 0\r\n')
            env = 'NT5_SYSTEM='+system+' XP_USER_SETTINGS='+quote(settings)+' XP_CUSTOM_SIF=; '
            r = shell(pre+env+funcs+run)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual((setup/'DISPLAY.TXT').read_bytes(), request)
            self.assertEqual((setup/'USOSRES.EXE').read_bytes(), b'own helper fixture')
            self.assertEqual(cmd.read_bytes(), b'@echo off\r\nnet user Bob /add\r\n'
                b'if exist "%SystemDrive%\\USOS\\XP\\USOSRES.EXE" reg add "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run" /v USOSDisplay /t REG_SZ /d "%SystemDrive%\\USOS\\XP\\USOSRES.EXE" /f >> "%USOS_LOG%" 2>&1\r\nexit /b 0\r\n')
            (setup/'DISPLAY.TXT').unlink()
        # Windows 2000 (vesa.cmd path) or a user's .sif that sets [Display]:
        # nothing here (user decision 2026-10-22: a user's .sif without one
        # gets auto, tools/tests/test_display_register.py).
        fixed = self.tmp/'fixed.sif'; fixed.write_bytes(b'[Display]\r\nXResolution=1280\r\n')
        for env in ('NT5_SYSTEM=windows-xp XP_USER_SETTINGS='+quote(settings)+' XP_CUSTOM_SIF='+quote(fixed)+'; ',
                    'NT5_SYSTEM=windows-2000 XP_USER_SETTINGS='+quote(settings)+' XP_CUSTOM_SIF=; '):
            r = shell(pre+env+funcs+'line=$(usos_nt52_display_stage '+quote(setup)+'); [ -z "$line" ]')
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertFalse((setup/'DISPLAY.TXT').exists())

    def test_nt5_scoping_and_depth_only_request(self):
        source = self.tmp/'settings.ini'
        for text, expected in [('family=xp\ndisplay=1920x1080\n', b''),
                               ('family=2000\n', b''),
                               ('family=2000\ndisplay_bpp=16\n', b'autox16\n'),
                               ('family=2000\ndisplay=auto\ndisplay_bpp=auto\n', b'autoxauto\n')]:
            source.write_text(text)
            r = shell(self.lib+'usos_display_from_nt5 '+quote(source))
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(r.stdout, expected)

    def test_9x_addreg_preserves_other_sections(self):
        source = self.tmp/'MSBATCH.INF'
        source.write_bytes(b'[Install]\r\nAddReg=USOS.RunOnce,USOS.CsmReg\r\n[Other]\r\nAddReg=Other\r\n')
        r = shell(self.lib+'usos_display_9x_answer '+quote(source))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(b'AddReg=USOS.RunOnce,USOS.CsmReg,USOS.Display\r\n', r.stdout)
        self.assertIn(b'[Other]\r\nAddReg=Other\r\n', r.stdout)
        self.assertIn(b'"C:\\USOS9X\\USOSRES.EXE"\r\n', r.stdout)
        self.assertNotIn(b'\n', r.stdout.replace(b'\r\n', b''))
        source.write_text('[Install]\n;no AddReg\n')
        self.assertNotEqual(shell(self.lib+'usos_display_9x_answer '+quote(source)).returncode, 0)

    def test_2000_safe_initial_mode_and_registration_only_when_requested(self):
        pkg, source, dest = [self.tmp/n for n in ('pkg', 'source', 'dest')]
        (pkg/'usosvbe').mkdir(parents=True)
        source.mkdir(); dest.mkdir()
        (pkg/'usosvbe/usosvbe.sys').write_bytes(b'own fixture')
        (pkg/'USOSRES.EXE').write_bytes(b'own helper fixture')
        shutil.copy(ROOT/'tools/display_profile.sh', pkg/'display_profile.sh')
        setup = self.tmp/'settings.ini'
        setup.write_text('family=2000\ndisplay=1920x1080\ndisplay_bpp=32\n')
        code = '. '+quote(ROOT/'tools/w2k_stage.sh')+'; '
        code += 'USOS_W2K_DIR='+quote(pkg)+' USOS_LIB_DIR='+quote(pkg)+' XP_USER_SETTINGS='+quote(setup)
        code += ' usos_w2k_vesa_stage '+quote(dest)+' '+quote(source)
        r = shell(code)
        self.assertEqual(r.returncode, 0, r.stdout+r.stderr)
        self.assertEqual((dest/'DISPLAY.TXT').read_bytes(), b'1920x1080x32\r\n')
        self.assertIn(b'"DefaultSettings.XResolution"=dword:00000400', (dest/'VESA.REG').read_bytes())
        cmd = (dest/'vesa.cmd').read_bytes()
        self.assertIn(b'if exist "%USOS_DIR%\\DISPLAY.REG" "%SystemRoot%\\regedit.exe" /s "%USOS_DIR%\\DISPLAY.REG"\r\n', cmd)
        self.assertLess(cmd.index(b'if exist "%USOS_DIR%\\DISPLAY.REG"'), cmd.index(b'echo vesa on:'))
        self.assertIn(b'echo display helper registered >> "%USOS_LOG%"', cmd)
        self.assertNotIn(b'\n', cmd.replace(b'\r\n', b''))
        for p in dest.iterdir():
            p.unlink()
        # No request (user decision 2026-10-20): auto, still 1024x768x16 first.
        setup.write_text('family=2000\n')
        self.assertEqual(shell(code).returncode, 0)
        self.assertEqual((dest/'DISPLAY.TXT').read_bytes(), b'autoxauto\r\n')
        self.assertIn(b'DISPLAY.REG', (dest/'vesa.cmd').read_bytes())
        self.assertIn(b'"DefaultSettings.XResolution"=dword:00000400', (dest/'VESA.REG').read_bytes())
        for p in dest.iterdir():
            p.unlink()
        (pkg/'USOSRES.EXE').unlink()
        self.assertEqual(shell(code).returncode, 0)
        self.assertFalse((dest/'DISPLAY.TXT').exists())
        self.assertNotIn(b'DISPLAY.REG', (dest/'vesa.cmd').read_bytes())

    def test_target_blocks_keep_staged_changes_and_register_nt_requests(self):
        from test_nt4_flow import function_text
        lib=self.tmp/'lib';lib.mkdir();(lib/'w9x-display').mkdir()
        shutil.copy(ROOT/'tools/display_profile.sh',lib/'display_profile.sh')
        for name in ('USOSRES.EXE','w9x-display/USOSRES.EXE','w9x-display/USOSVBI.EXE'):(lib/name).write_bytes(b'own helper fixture')
        answer=self.tmp/'answer';answer.write_text(';USOS-DISPLAY=1920x1080x16\n[Install]\nAddReg=USOS.RunOnce,USOS.Lan,USOS.Addons\nHKLM,Run,USOSLan,,missing.exe\n')
        target=self.tmp/'c/USOS9X';target.mkdir(parents=True)
        # Network/addons have already removed an unavailable helper's Run row.
        staged=target/'MSBATCH.INF';staged.write_bytes(answer.read_bytes().replace(b'\r',b'').replace(b'HKLM,Run,USOSLan,,missing.exe\n',b''))
        text=(ROOT/'tools/w9x_csmwrap_target.sh').read_text();start=text.index("display_request=\nif grep -q '^;USOS-DISPLAY='");end=text.index('# Me, stock user USOS',start)
        pre='fail() { echo "$*" >&2; exit 1; }; log() { :; }; '
        env='LIB='+quote(lib)+' work='+quote(self.tmp)+' ANSWER_INF='+quote(answer)+' ANSWER_SIF='+quote(answer)+' ANSWER_KIND=PROFILE; '
        r=shell(pre+env+text[start:end]);self.assertEqual(r.returncode,0,r.stderr)
        rendered=staged.read_bytes();self.assertNotIn(b'missing.exe',rendered);self.assertIn(b'AddReg=USOS.RunOnce,USOS.Lan,USOS.Addons,USOS.Display',rendered)
        nt=self.tmp/'NT3';nt.mkdir()
        r=shell(pre+env+'usos='+quote(nt)+" nt3=1 nt31=''; "+function_text(ROOT/'tools/nt4_csmwrap_target.sh','nt3_stage_profile')+'; nt3_stage_profile')
        self.assertEqual(r.returncode,0,r.stderr);self.assertEqual((nt/'DISPLAY.TXT').read_bytes(),b'1920x1080x16\r\n')
        nt4=self.tmp/'NT4';nt4.mkdir();(nt4/'VESA.REG').write_bytes(b'REGEDIT4\r\n; preserved driver values\r\n')
        text=(ROOT/'tools/nt4_csmwrap_target.sh').read_text();start=text.index('nt4_display_request=\nif [ -z "$nt3" ] && [ -z "$nt31" ] && grep');end=text.index('\nfor file in "$SYSLINUX_DIR',start)
        r=shell(pre+env+'usos='+quote(nt4)+" nt3='' nt31=''; "+text[start:end]);self.assertEqual(r.returncode,0,r.stderr)
        self.assertIn(b'; preserved driver values\r\n',(nt4/'VESA.REG').read_bytes());self.assertIn(b'"USOSDisplay"=',(nt4/'VESA.REG').read_bytes())

    def test_nt6_xml_request_and_registration_marker(self):
        source = self.tmp/'autounattend.xml'
        source.write_bytes(b'<?xml version="1.0"?>\n<!-- USOS-DISPLAY=1920x1080xauto -->\n<unattend/>\n')
        self.assertEqual(shell(self.lib+'usos_display_from_xml '+quote(source)).stdout, b'1920x1080xauto\n')
        source.write_bytes(b'<!-- USOS-DISPLAY=autox16 -->\r\n<!-- USOS-DISPLAY=autox16 -->\r\n')
        self.assertNotEqual(shell(self.lib+'usos_display_from_xml '+quote(source)).returncode, 0)
        source.write_bytes(b'<unattend><Path>x &quot;%SystemDrive%\\USOS\\NT6\\USOSRES.EXE&quot;</Path></unattend>\n')
        r = shell(self.lib+'usos_display_from_xml '+quote(source))
        self.assertEqual((r.returncode, r.stdout), (0, b''))
        self.assertEqual(shell(self.lib+'usos_display_nt6_answer '+quote(source)).returncode, 0)
        source.write_bytes(b'<unattend/>\n')
        self.assertNotEqual(shell(self.lib+'usos_display_nt6_answer '+quote(source)).returncode, 0)

    def nt6_display_block(self, answer_bytes, helper=True):
        lib = self.tmp/'lib-nt6'; lib.mkdir(exist_ok=True)
        shutil.copy(ROOT/'tools/display_profile.sh', lib/'display_profile.sh')
        if helper: (lib/'USOSRES.EXE').write_bytes(b'own helper fixture')
        work = self.tmp/'work'; shutil.rmtree(work, ignore_errors=True); work.mkdir()
        answer = ''
        if answer_bytes is not None:
            answer = str(work/'answer.xml'); Path(answer).write_bytes(answer_bytes)
        text = (ROOT/'tools/vista_csmwrap_target.sh').read_text()
        start = text.index('# 2b. Display'); end = text.index('# 3. The PE10 donor', start)
        # The Windows partition is a host folder here: mount/umount do nothing.
        pre = 'fail() { echo "$*" >&2; exit 1; }; log() { echo "LOG $*"; }; modprobe() { :; }; mount() { :; }; umount() { :; }; '
        env = 'LIB='+quote(lib)+' work='+quote(work)+' ANSWER_XML='+quote(answer)+' windows_node=/dev/null; '
        r = shell(pre+env+text[start:end])
        self.assertEqual(r.returncode, 0, r.stderr)
        return work/'windows/USOS/NT6', r.stdout

    def test_nt6_csmwrap_stages_for_every_answer(self):
        registered = b'<!-- USOS answer profile rendered for windows-vista (amd64) -->\n<unattend><Path>cmd.exe /c if exist &quot;%SystemDrive%\\USOS\\NT6\\USOSRES.EXE&quot; reg.exe add</Path></unattend>\n'
        folder, out = self.nt6_display_block(registered)
        self.assertEqual((folder/'DISPLAY.TXT').read_bytes(), b'autoxauto\r\n')
        self.assertEqual((folder/'USOSRES.EXE').read_bytes(), b'own helper fixture')
        self.assertIn(b'DISPLAY request=autoxauto', out)
        folder, _ = self.nt6_display_block(registered.replace(b'<unattend>', b'<!-- USOS-DISPLAY=1280x1024x32 -->\n<unattend>'))
        self.assertEqual((folder/'DISPLAY.TXT').read_bytes(), b'1280x1024x32\r\n')
        # User decision 2026-10-22: a user's own answer (no registration) or
        # no answer gets auto as well (registered by the WinPE step after
        # Setup); a user's own <Display> keeps its mode.
        for answer in (b'<unattend/>\n', None):
            folder, _ = self.nt6_display_block(answer)
            self.assertEqual((folder/'DISPLAY.TXT').read_bytes(), b'autoxauto\r\n')
        folder, _ = self.nt6_display_block(b'<unattend><HorizontalResolution>1280</HorizontalResolution></unattend>\n')
        self.assertFalse(folder.exists())
        folder, out = self.nt6_display_block(registered.replace(b'<unattend>', b'<!-- USOS-DISPLAY=800x600xauto -->\n<unattend>'))
        self.assertFalse(folder.exists()); self.assertIn(b'invalid request', out)
        shutil.rmtree(self.tmp/'lib-nt6')
        folder, out = self.nt6_display_block(registered, helper=False)
        self.assertFalse(folder.exists()); self.assertIn(b'USOSRES.EXE missing', out)

    def test_x86_modern_csmwrap_stages_from_rendered_answers(self):
        # win-x86-uefi-csmwrap (32-bit 8 / 8.1 / 10) runs the same target
        # script (X86_SELF=1); step 2b is not tied to the Vista profile.
        text = (ROOT/'tools/vista_csmwrap_target.sh').read_text()
        block = text[text.index('# 2b. Display'):text.index('# 3. The PE10 donor')]
        self.assertNotIn('$X86_SELF', block)
        golden = ROOT/'src/flow/answer/testdata/golden'
        for name in ('full.windows-10.x86.xml', 'full.windows-8-1.x86.xml', 'options.windows-10.x86.xml',
                     'full.windows-8.amd64.xml'):
            folder, out = self.nt6_display_block((golden/name).read_bytes())
            self.assertEqual((folder/'DISPLAY.TXT').read_bytes(), b'autoxauto\r\n', name)
            self.assertIn(b'DISPLAY request=autoxauto apply=first-sign-in', out, name)
        folder, _ = self.nt6_display_block((golden/'tweaks.windows-8-1.x86.xml').read_bytes())
        self.assertTrue((folder/'DISPLAY.TXT').read_bytes().startswith(b'1024x768x'))
        # Windows 11 / Server 2012+ / arm64 answers never reach this script
        # (no 32-bit or Vista-x64 CSMWrap route) and never register it.
        for name in ('full.windows-11.amd64.xml', 'full.windows-10.arm64.xml', 'full.windows-server-2012-r2.amd64.xml'):
            if (golden/name).exists():
                self.assertNotIn(b'\\USOS\\NT6\\USOSRES.EXE', (golden/name).read_bytes(), name)

    def test_display_section_stays_before_usos_csm(self):
        # INSTALL.BAT appends Me's usoskey.drv line to the last section, which
        # must stay [USOS.Csm] (else the Me USB keyboard driver is lost).
        source = self.tmp/'MSBATCH.INF'
        source.write_bytes(b'[Install]\r\nAddReg=USOS.RunOnce\r\n[USOS.RunOnce]\r\nHKLM,x,y,,z\r\n; last\r\n[USOS.Csm]\r\n')
        r = shell(self.lib+'usos_display_9x_answer '+quote(source))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(r.stdout.endswith(b'[USOS.Csm]\r\n'), r.stdout)
        self.assertLess(r.stdout.index(b'[USOS.Display]'), r.stdout.index(b'[USOS.Csm]'))
        self.assertEqual(r.stdout.count(b'[USOS.Display]'), 1)
        self.assertIn(b'HKLM,Software\\Microsoft\\Windows\\CurrentVersion\\Run,USOSDisplay,,"C:\\USOS9X\\USOSRES.EXE"\r\n', r.stdout)

    def w9x_display_block(self, answer_text, kind):
        lib=self.tmp/('lib-'+kind);lib.mkdir();(lib/'w9x-display').mkdir()
        shutil.copy(ROOT/'tools/display_profile.sh',lib/'display_profile.sh')
        for name in ('w9x-display/USOSRES.EXE','w9x-display/USOSVBI.EXE'):(lib/name).write_bytes(b'own helper fixture')
        work=self.tmp/('w-'+kind);target=work/'c/USOS9X';target.mkdir(parents=True)
        answer=work/'answer.inf';answer.write_bytes(answer_text)
        (target/'MSBATCH.INF').write_bytes(answer_text)
        text=(ROOT/'tools/w9x_csmwrap_target.sh').read_text();start=text.index("display_request=\nif grep -q '^;USOS-DISPLAY='");end=text.index('# Me, stock user USOS',start)
        pre='fail() { echo "$*" >&2; exit 1; }; log() { echo "LOG $*"; }; '
        env='LIB='+quote(lib)+' work='+quote(work)+' ANSWER_INF='+quote(answer)+' ANSWER_KIND='+kind+'; '
        r=shell(pre+env+text[start:end]);self.assertEqual(r.returncode,0,r.stderr)
        return target, r.stdout

    def test_9x_default_auto_without_request_except_user_answer(self):
        answer=b'[Install]\r\nAddReg=USOS.RunOnce\r\n[USOS.Csm]\r\n'
        for kind in ('USOS','PROFILE'):
            target,out=self.w9x_display_block(answer,kind)
            self.assertEqual((target/'DISPLAY.TXT').read_bytes(),b'autoxauto\r\n')
            self.assertTrue((target/'USOSRES.EXE').is_file() and (target/'USOSVBI.EXE').is_file())
            staged=(target/'MSBATCH.INF').read_bytes()
            self.assertIn(b'AddReg=USOS.RunOnce,USOS.Display\r\n',staged)
            self.assertTrue(staged.endswith(b'[USOS.Csm]\r\n'))
            self.assertIn(b'default auto',out)
        target,_=self.w9x_display_block(answer,'USER')
        self.assertFalse((target/'DISPLAY.TXT').exists());self.assertEqual((target/'MSBATCH.INF').read_bytes(),answer)

    def test_nt4_default_auto_only_with_vesa_and_not_user_answer(self):
        lib=self.tmp/'lib';lib.mkdir();shutil.copy(ROOT/'tools/display_profile.sh',lib/'display_profile.sh');(lib/'USOSRES.EXE').write_bytes(b'own helper fixture')
        answer=self.tmp/'unattend.txt';answer.write_bytes(b'[Unattended]\r\n')
        text=(ROOT/'tools/nt4_csmwrap_target.sh').read_text();start=text.index('nt4_display_request=\nif [ -z "$nt3" ]');end=text.index('\nfor file in "$SYSLINUX_DIR',start)
        pre='fail() { echo "$*" >&2; exit 1; }; log() { :; }; '
        for kind,vesa,expect in (('PROFILE',True,True),('USOS',True,True),('USER',True,False),('PROFILE',False,False)):
            usos=self.tmp/('NT4-'+kind+str(vesa));usos.mkdir()
            if vesa:(usos/'VESA.REG').write_bytes(b'REGEDIT4\r\n; driver\r\n')
            env='LIB='+quote(lib)+' ANSWER_SIF='+quote(answer)+' ANSWER_KIND='+kind+' usos='+quote(usos)+" nt3='' nt31=''; "
            r=shell(pre+env+text[start:end]);self.assertEqual(r.returncode,0,r.stderr)
            self.assertEqual((usos/'DISPLAY.TXT').exists(),expect,(kind,vesa))
            if expect:
                self.assertEqual((usos/'DISPLAY.TXT').read_bytes(),b'autoxauto\r\n')
                self.assertIn(b'"USOSDisplay"=',(usos/'VESA.REG').read_bytes())

    def test_collector_uses_pinned_buildkit_resolver_when_no_override(self):
        from unittest.mock import patch
        import build_win3_usb_keyboard
        watcom=Path(os.environ['USOS_WATCOM'])
        with patch.dict(os.environ,{},clear=False):
            os.environ.pop('USOS_WATCOM',None)
            with patch.object(build_win3_usb_keyboard,'openwatcom',return_value=watcom) as resolve:
                build_collector(ROOT,self.tmp/'collector')
                resolve.assert_called_once_with()


class TargetBuilds(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.nt = build(ROOT, OUT/'nt')
        cls.registrar = build(ROOT, OUT/'nt', registrar=True)
        cls.w9x = build(ROOT, OUT/'9x', win9x=True)
        cls.collector = build_collector(ROOT, OUT/'9x')

    def test_nt_static_imports_exist_on_every_original_media(self):
        for fixture in ('nt35_display_exports.txt', 'nt351_display_exports.txt', 'nt4rtm_display_exports.txt'):
            table = exports(fixture)
            for binary in (self.nt, self.registrar):
                for module, name in pe(binary)[1]:
                    self.assertIn(name, table.get(module.lower(), set()), (fixture, binary.name, module, name))

    def test_old_pe_and_no_runtime_or_static_user32(self):
        for binary in (self.nt, self.registrar, self.w9x):
            data = binary.read_bytes()
            opt = struct.unpack_from('<I', data, 0x3c)[0]+24
            self.assertEqual(struct.unpack_from('<HH', data, opt+48), (3, 10))
            self.assertEqual(struct.unpack_from('<H', data, opt+68)[0], 3 if binary==self.registrar else 2)
            self.assertEqual({m.lower() for m, _ in pe(binary)[1]}, {'kernel32.dll', 'advapi32.dll'})
        prohibited = {'OpenSCManagerA', 'OpenServiceA', 'QueryServiceStatus', 'StartServiceCtrlDispatcherA', 'InitiateSystemShutdownA'}
        self.assertTrue(prohibited.isdisjoint({n for _, n in pe(self.w9x)[1]}))

    def test_win16_ne_and_no_crt(self):
        data = self.collector.read_bytes()
        self.assertEqual(data[struct.unpack_from('<I', data, 0x3c)[0]:][:2], b'NE')
        self.assertNotIn('clib', (self.collector.parent/'usosvbi.map').read_text().lower())

    def test_win16_instance_header_reserved(self):
        # 98 SE X470 2026-10-20: InitTask/LocalInit wrote the first 16 bytes of
        # DGROUP over "VBE.DAT"; no VBE.DAT, USOSRES "no fresh VBE/INF evidence".
        data = self.collector.read_bytes()
        ne = struct.unpack_from('<I', data, 0x3c)[0]
        table = ne + struct.unpack_from('<H', data, ne+0x22)[0]
        auto, align = struct.unpack_from('<H', data, ne+0x0e)[0], struct.unpack_from('<H', data, ne+0x32)[0]
        offset = struct.unpack_from('<H', data, table+(auto-1)*8)[0] << align
        self.assertEqual(data[offset:offset+16], bytes(16))
        source = (ROOT/'tools/windows9x_vbe_collect.c').read_text()
        self.assertIn('#pragma data_seg("_NULL", "BEGDATA")', source)
        self.assertIn('write_log();', source)

    def test_9x_helper_logs_collector_result(self):
        source = (ROOT/'tools/windows_usos_res.c').read_text()
        for text in ('DISPLAY VBI start failed error=', 'DISPLAY VBI wait=', 'copy_vbi_log();', 'DISPLAY VBE.DAT absent', '" rejected"'):
            self.assertIn(text, source)

    def test_original_media_proves_nt35_fallback_is_required(self):
        for fixture, expected in [('nt35_display_exports.txt', False), ('nt351_display_exports.txt', True), ('nt4rtm_display_exports.txt', True)]:
            table = exports(fixture)['user32.dll']
            for name in ('EnumDisplaySettingsA', 'ChangeDisplaySettingsA'):
                self.assertEqual(name in table, expected)

    def test_compiled_selector_memory_inf_and_apply_transactions(self):
        zig = Path(os.environ.get('USOS_ZIG', ROOT/'tools/zig/zig.exe'))
        exe = OUT/'policy.exe'
        env = dict(os.environ, TEMP=str(OUT), TMP=str(OUT), ZIG_GLOBAL_CACHE_DIR=str(ROOT/'tools/cache/zig-global'), ZIG_LOCAL_CACHE_DIR=str(OUT/'zig-cache'))
        subprocess.run([str(zig), 'cc', '-target', 'x86_64-windows-gnu', '-O2', '-nostdlib',
                        '-I'+str(zig.parent/'lib/libc/include/any-windows-any'), str(ROOT/'tools/tests/display_policy_test.c'),
                        '-Wl,--entry,entry', '-lkernel32', '-o', str(exe)], env=env, check=True)
        self.assertEqual(subprocess.run([str(exe)], env=env).returncode, 0)

    def test_install_vm_pentium3_exposes_hypervisor_flag(self):
        qemu = Path(os.environ.get('USOS_QEMU', ROOT/'tools/qemu/qemu-system-i386.exe'))
        if not qemu.is_file():
            self.skipTest('set USOS_QEMU for the CPUID-only BIOS probe; no Windows boot')
        image, log = OUT/'cpuid-only.img', OUT/'cpuid-only.log'
        # 16-bit real-mode boot sector: EAX=1; CPUID; ECX>>31; print CL+'0'
        # to debugcon E9; exit through isa-debug-exit F4. No disk writes.
        code = bytes.fromhex('66b8010000000fa266c1e91f88c80430e6e9b010e6f4faf4ebfd')
        image.write_bytes(code+bytes(510-len(code))+b'\x55\xaa')
        try:
            r = subprocess.run([str(qemu), '-machine', 'pc', '-accel', 'tcg', '-cpu', 'pentium3',
                                '-m', '16', '-display', 'none', '-monitor', 'none', '-serial', 'none',
                                '-no-user-config', '-no-reboot', '-drive', 'file='+str(image)+',format=raw,if=floppy,readonly=on',
                                '-boot', 'a', '-debugcon', 'file:'+str(log), '-device', 'isa-debug-exit,iobase=0xf4,iosize=4'],
                               capture_output=True, timeout=30)
            self.assertEqual(r.returncode, 33, r.stderr)
            self.assertEqual(log.read_bytes(), b'1')
        finally:
            image.unlink(missing_ok=True)


if __name__ == '__main__':
    unittest.main(verbosity=2)
