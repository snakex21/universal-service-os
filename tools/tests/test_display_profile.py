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
        self.assertNotIn(b'\n', cmd.replace(b'\r\n', b''))
        for p in dest.iterdir():
            p.unlink()
        setup.write_text('family=2000\n')
        self.assertEqual(shell(code).returncode, 0)
        self.assertFalse((dest/'DISPLAY.TXT').exists())
        self.assertNotIn(b'DISPLAY.REG', (dest/'vesa.cmd').read_bytes())


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
