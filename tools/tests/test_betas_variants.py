"""Host-only beta/variant metadata and RTC arguments. Never boots Windows."""
from pathlib import Path
import importlib.util
import os
import shutil
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SH = next((p for p in (r'C:/Program Files/Git/usr/bin/sh.exe', shutil.which('sh')) if p and Path(p).is_file()), None)
ENV = dict(os.environ)
if SH:
    ENV['PATH'] = str(Path(SH).parent) + os.pathsep + ENV.get('PATH', '')

def posix(p):
    s = str(p).replace('\\', '/')
    return '/' + s[0].lower() + s[2:] if len(s) > 1 and s[1] == ':' else s

def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'tools' / (name + '.py'))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m

class Metadata(unittest.TestCase):
    def test_permissive_source_sif_and_channel_facts(self):
        m = load('windows_media_facts')
        text = (ROOT/'src/image_probe/testdata/variants/whistler.sif').read_text()
        text += '\n[SourceDisksFiles]\nntdll.dll = 1,,,,,,,2,0,0\n[Pid]\nPid=55034000\n'
        facts = m.ini_facts(text)
        self.assertEqual(facts['SetupData.minorversion'], '1')
        self.assertEqual(facts['nls.defaultlayout'], '00000409')
        self.assertEqual(facts['Pid.pid'], '55034000')
        self.assertNotIn('SetupData.buildnumber', facts)
        self.assertNotIn('Version.driverver', facts)
        dosnet = m.ini_facts((ROOT/'src/image_probe/testdata/variants/whistler.dosnet.inf').read_text())
        self.assertEqual(dosnet['Version.driverver'], '07/01/2001,5.1.2542.0')

    def test_pre_rtm_wim_never_uses_modern_xml_offsets(self):
        m = load('windows_media_facts')
        class Source:
            entries = {'test': (0, 1000, False)}
            def read(self, name, offset=0, length=None):
                if length != 208:
                    assert offset == 0 and length == 1000
                    return bytes(1000)
                header = bytearray(208)
                header[:8] = b'MSWIM\0\0\0'
                struct.pack_into('<I', header, 12, 0x10c00)
                return header
        self.assertEqual(m.wim_facts(Source(), 'test')['format'], '0x10c00')

    def test_pe_false_magic_and_verified_version(self):
        m = load('windows_media_facts')
        data = bytearray(256)
        data[:2] = b'MZ'
        struct.pack_into('<I', data, 60, 64)
        data[64:68] = b'PE\0\0'
        struct.pack_into('<H', data, 68, 0x14c)
        data[90:94] = b'\xbd\x04\xef\xfe'  # code constant, not version resource
        self.assertNotIn('file_version', m.pe_facts(data))
        struct.pack_into('<IIII', data, 128, 0xfeef04bd, 0x10000, (5 << 16) | 1, 2542 << 16)
        self.assertEqual(m.pe_facts(data)['file_version'], [5, 1, 2542, 0])
        data[64:66] = b'XX'
        self.assertNotIn('file_version', m.pe_facts(data))

    def test_language_zero_is_not_installed(self):
        m = load('windows_media_facts')
        text = (ROOT/'src/image_probe/testdata/variants/wes7-lang.ini').read_text()
        facts = m.ini_facts(text)['available_languages']
        self.assertEqual([lang for lang, flag in facts.items() if flag != '0'], ['en-US'])

@unittest.skipUnless(SH, 'POSIX shell required')
class ClockAndAdapters(unittest.TestCase):
    def shell(self, text, **env):
        return subprocess.run([SH, '-c', text], cwd=ROOT, env=dict(ENV, **env), capture_output=True, text=True, timeout=20)

    def rtc(self, value, system='', build='0'):
        return self.shell('. tools/beta_clock.sh; usos_beta_clock_rtc "$SETTING" "$SYSTEM" "$BUILD"', SETTING=value, SYSTEM=system, BUILD=build)

    def test_calendar_and_unknown_auto_build(self):
        self.assertEqual(self.rtc('').stdout.strip(), 'base=localtime')
        self.assertEqual(self.rtc('auto', 'windows-7-beta', '7000').stdout.strip(), 'base=2009-01-15T12:00:00')
        self.assertEqual(self.rtc('2000-02-29', 'windows-nt-3-beta').stdout.strip(), 'base=2000-02-29T12:00:00')
        self.assertEqual(self.rtc('auto', 'windows-millennium', '2525').stdout.strip(), 'base=2000-05-15T12:00:00')
        for value in ('2001-02-29', '2005-04-31', '2009-1-15', '2009-01-15;echo BAD', '$(echo BAD)'):
            self.assertNotEqual(self.rtc(value, 'windows-nt-3-beta').returncode, 0, value)
        self.assertNotEqual(self.rtc('auto', 'windows-nt-3-beta', '1').returncode, 0)

    def test_actual_nt3_nt4_posready_argument_functions(self):
        for helper, function in (('nt4_qemu_install.sh','nt4_vm_args'), ('posready_qemu_install.sh','posready_vm_args')):
            script = '. tools/w9x_phase1_qemu.sh; . tools/' + helper + '; W9X_VM_RUN=/run/test; NT4_VM_DISK_BYTES=1000000; ' + function + ' /dev/fixture tcg'
            # These shared helpers may carry metadata only for a beta id.
            out = self.shell(script, USOS_BETA_CLOCK='1999-12-11', USOS_BETA_SYSTEM='windows-nt-3-beta', USOS_LIB_DIR=posix(ROOT/'tools'))
            self.assertEqual(out.returncode, 0, out.stderr)
            args = out.stdout.splitlines()
            self.assertEqual(args[args.index('-rtc')+1], 'base=1999-12-11T12:00:00')
            self.assertIn('-nic', args)
            normal = self.shell(script)
            self.assertEqual(normal.returncode, 0, normal.stderr)
            args = normal.stdout.splitlines()
            self.assertEqual(args[args.index('-rtc')+1], 'base=localtime')

            for system in ('windows-nt-4', 'windows-embedded-posready-2009', ''):
                for setting in ('auto', '2005-05-01'):
                    out = self.shell(script, USOS_BETA_CLOCK=setting, USOS_BETA_SYSTEM=system, USOS_LIB_DIR=posix(ROOT/'tools'))
                    self.assertEqual(out.returncode, 0, out.stderr)
                    args = out.stdout.splitlines()
                    self.assertEqual(args[args.index('-rtc')+1], 'base=localtime')
                    self.assertIn('ignored setting for non-beta', out.stderr)

    def test_nt5_beta_identity_uses_own_category_without_changing_base(self):
        cmd = '. tools/nt5_profile.sh; usos_nt5_profile && printf "%s|%s|%s" "$NT5_SYSTEM" "$NT5_CATEGORY" "$NT5_NAME"'
        out = self.shell(cmd, NT5_SYSTEM='windows-xp', USOS_NT5_VARIANT='whistler')
        self.assertEqual(out.stdout, 'windows-xp|Betas|Windows Whistler')
        out = self.shell(cmd, NT5_SYSTEM='windows-2000', USOS_NT5_VARIANT='neptune')
        self.assertEqual(out.stdout, 'windows-2000|Betas|Windows Neptune')
        out = self.shell(cmd, NT5_SYSTEM='windows-xp', USOS_NT5_VARIANT='neptune')
        self.assertNotEqual(out.returncode, 0)
        out = self.shell(cmd, NT5_SYSTEM='windows-xp', USOS_NT5_VARIANT='')
        self.assertEqual(out.stdout, 'windows-xp|Windows|Windows XP')

    def test_unsupported_setup_stops_before_disk_selection(self):
        text = (ROOT/'tools/w9x_csmwrap_prepare.sh').read_text(encoding='utf-8')
        limit = text.index('CANDIDATES=/run/w9x-candidates')
        for marker in ('Nashville 999 is upgrade-only', 'FLP is WinPE plus WinFLP.wim', 'Citrix licensing'):
            self.assertLess(text.index(marker), limit)
        out = self.shell('NT5_SYSTEM=windows-xp USOS_NT5_VARIANT=whistler sh tools/probe_nt5_source.sh')
        self.assertNotEqual(out.returncode, 0)
        self.assertIn('no target write occurred', out.stderr)

    def test_nt5_staging_guard_precedes_all_file_access_and_disk_selection(self):
        script = '''. tools/legacy_xp_staging.sh
stop() { printf 'STOP: %s\n' "$*"; exit 42; }
mkdir() { echo UNEXPECTED_FILE_ACCESS; exit 99; }
xp_stage_set() { echo UNEXPECTED_SOURCE_DISCOVERY; exit 99; }
usos_xp_choose_disk() { echo UNEXPECTED_DISK_PICKER; exit 99; }
usos_legacy_xp_staging 00
'''
        for system, variant in (('windows-xp', 'whistler'), ('windows-2000', 'neptune'), ('windows-2000', 'w2k-beta')):
            out = self.shell(script, NT5_SYSTEM=system, USOS_NT5_VARIANT=variant,
                             USOS_LIB_DIR=posix(ROOT/'tools'), USOS_XP_ESP_DIR='/forbidden-test-esp')
            self.assertEqual(out.returncode, 42, out.stdout + out.stderr)
            self.assertNotIn('UNEXPECTED_', out.stdout)
            self.assertIn('no target write occurred', out.stderr)

    def test_request_directory_uses_actual_beta_category_and_rejects_mismatch(self):
        script = '. tools/vista_csmwrap_prepare.sh; vista_request_directory "$ISO" "$FOLDER"'
        for folder, category in (('Windows 7 Beta', 'Betas'), ('Windows Longhorn', 'Betas'), ('Windows Vista', 'Windows')):
            out = self.shell(script, ISO=f'Systems/{category}/{folder}/Images/arbitrary.iso', FOLDER=folder)
            self.assertEqual(out.returncode, 0, out.stderr)
            self.assertEqual(out.stdout.strip(), f'Systems/{category}/{folder}')
        for iso in ('Systems/Windows/Other/Images/a.iso', 'Systems/Betas/Windows 7 Beta/Images/sub/Images/a.iso', '../a.iso'):
            self.assertNotEqual(self.shell(script, ISO=iso, FOLDER='Windows 7 Beta').returncode, 0)

    def test_real_source_probe_rejects_beta_driverversion_in_rtm_folder(self):
        for fixture, version, system, identity in (('whistler', '5.1.2542.0', 'windows-xp', 'windows-whistler'), ('neptune', '5.50.5111.1', 'windows-2000', 'windows-neptune')):
            with tempfile.TemporaryDirectory() as temp:
                source = Path(temp)
                (source/'i386').mkdir()
                sif = source/'i386/TxtSetup.Sif'
                sif.write_bytes((ROOT/f'src/image_probe/testdata/variants/{fixture}.sif').read_bytes())
                (source/'i386/Dosnet.Inf').write_bytes((ROOT/f'src/image_probe/testdata/variants/{fixture}.dosnet.inf').read_bytes())
                out = self.shell('sh tools/probe_nt5_source.sh', SOURCE_ROOT=posix(source), NT5_SYSTEM=system, USOS_NT5_VARIANT='')
                self.assertNotEqual(out.returncode, 0)
                self.assertIn('driver_version=' + version, out.stdout)
                self.assertIn('source_identity=' + identity, out.stdout)
                self.assertIn('pre-release DriverVer', out.stderr)

    def test_rtm_dosnet_versions_are_unknown_to_beta_classifier(self):
        for version in ('5.00.2195.1', '5.1.2600.5512'):
            with tempfile.TemporaryDirectory() as temp:
                inf = Path(temp)/'DOSNET.INF'
                inf.write_text('[Version]\nDriverVer=07/01/2001,'+version+'\n')
                out = self.shell('. tools/nt5_profile.sh; usos_nt5_source_metadata "$INF"', INF=posix(inf))
                self.assertEqual(out.returncode, 0, out.stderr)
                self.assertIn('source_identity=unknown', out.stdout)

    def test_shell_beta_clock_ids_match_catalog(self):
        import re
        catalog = (ROOT/'src/catalog/windows_betas.zig').read_text()
        script = (ROOT/'tools/beta_clock.sh').read_text().split('usos_beta_clock_date()', 1)[0]
        expected = set(re.findall(r'beta\("([^"]+)"', catalog))
        actual = set(re.findall(r'windows-[a-z0-9-]+', script))
        self.assertEqual(actual, expected)

    def test_driverversion_unknown_invalid_and_duplicate(self):
        with tempfile.TemporaryDirectory() as temp:
            sif = Path(temp)/'TXTSETUP.SIF'
            for body, expected in (('[SetupData]\nMajorVersion=5', 0), ('[Version]\nDriverVer=x,5.1.2600.0', 0), ('[Version]\nDriverVer=x,5.1.BAD.0', 1), ('[Version]\nDriverVer=x,5.1.2600.0\nDriverVer=x,5.1.2600.0', 1)):
                sif.write_text(body)
                out = self.shell('. tools/nt5_profile.sh; usos_nt5_source_metadata "$SIF"', SIF=posix(sif))
                self.assertEqual(out.returncode, expected, out.stdout + out.stderr)

if __name__ == '__main__':
    unittest.main()
