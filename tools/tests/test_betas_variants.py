"""Host-only beta/variant metadata and RTC arguments. Never boots Windows."""
from pathlib import Path
import importlib.util
import os
import shutil
import struct
import subprocess
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
        self.assertEqual(self.rtc('2000-02-29').stdout.strip(), 'base=2000-02-29T12:00:00')
        for value in ('2001-02-29', '2005-04-31', '2009-1-15', '2009-01-15;echo BAD', '$(echo BAD)'):
            self.assertNotEqual(self.rtc(value).returncode, 0, value)
        self.assertNotEqual(self.rtc('auto', 'windows-nt-3-beta', '1').returncode, 0)

    def test_actual_nt3_nt4_posready_argument_functions(self):
        for helper, function in (('nt4_qemu_install.sh','nt4_vm_args'), ('posready_qemu_install.sh','posready_vm_args')):
            script = '. tools/w9x_phase1_qemu.sh; . tools/' + helper + '; W9X_VM_RUN=/run/test; NT4_VM_DISK_BYTES=1000000; ' + function + ' /dev/fixture tcg'
            out = self.shell(script, USOS_BETA_CLOCK='1999-12-11', USOS_LIB_DIR=posix(ROOT/'tools'))
            self.assertEqual(out.returncode, 0, out.stderr)
            args = out.stdout.splitlines()
            self.assertEqual(args[args.index('-rtc')+1], 'base=1999-12-11T12:00:00')
            self.assertIn('-nic', args)
            normal = self.shell(script)
            self.assertEqual(normal.returncode, 0, normal.stderr)
            args = normal.stdout.splitlines()
            self.assertEqual(args[args.index('-rtc')+1], 'base=localtime')

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

if __name__ == '__main__':
    unittest.main()
