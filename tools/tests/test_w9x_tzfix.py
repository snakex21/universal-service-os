"""98 / 98 SE first-boot time zone step (tools/w9x_tzfix.sh, C:\\USOS9X\\TZFIX.BAT)
and the MSBATCH TimeZone guard of tools/w9x_csmwrap_prepare.sh. Host only (Git sh);
the same output under the micro-Linux BusyBox was compared byte for byte."""
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_w9x_phase1_qemu import sh

ROOT = Path(__file__).resolve().parents[2]
TZFIX = (ROOT / 'tools/w9x_tzfix.sh').as_posix()
NAMES = ('TZFIX.BAT', 'TZFIX.REG', 'TZRO1.REG', 'TZRO2.REG')
# Time Zones\Central European / Eastern of the Windows 98 SE PL OEM CD
# (TIMEZONE.INF, read back from the installed X470 registry): TZI fields.
CE_TZI = ('c4,ff,ff,ff', 'c4,ff,ff,ff', '00,00,0a,00,00,00,05,00,03,00,00,00,00,00,00,00',
          '00,00,03,00,00,00,05,00,02,00,00,00,00,00,00,00')
EASTERN_TZI = ('2c,01,00,00', 'c4,ff,ff,ff', '00,00,0a,00,00,00,05,00,02,00,00,00,00,00,00,00',
               '00,00,04,00,00,00,01,00,02,00,00,00,00,00,00,00')


class Tzfix(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='usos-w9x-tzfix-'))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def write(self, zone, month):
        rc, out, err = sh(f'. "{TZFIX}"\nw9x_tzfix_write "$Z" "{self.tmp.as_posix()}" {month}', {'Z': zone})
        return rc, {name: (self.tmp / name).read_bytes() for name in NAMES if (self.tmp / name).exists()}

    def check_tzi(self, reg, tzi):
        bias, daylight, std, dlt = tzi
        self.assertIn(f'"Bias"=hex:{bias}\r\n'.encode(), reg)
        self.assertIn(f'"DaylightBias"=hex:{daylight}\r\n'.encode(), reg)
        self.assertIn(f'"StandardStart"=hex:{std}\r\n'.encode(), reg)
        self.assertIn(f'"DaylightStart"=hex:{dlt}\r\n'.encode(), reg)

    def test_central_european_matches_the_hardware_proven_file(self):
        rc, files = self.write('Central European', 10)
        self.assertEqual(rc, 0)
        reg = files['TZFIX.REG']
        self.assertTrue(reg.startswith(b'REGEDIT4\r\n\r\n[HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\control\\TimeZoneInformation]\r\n'))
        self.check_tzi(reg, CE_TZI)
        self.assertIn('"StandardName"="Europa Środkowa (czas stand.)"\r\n'.encode('cp1250'), reg)
        self.assertIn(b'"ActiveTimeBias"=hex:88,ff,ff,ff\r\n', reg)   # summer: -120
        self.assertNotIn(b'[-', reg)                                   # no key is deleted
        self.assertIn(b'"Strefa czasowa"="RUNDLL32.EXE SHELL32.DLL,Control_FillCache_RunDLL"\r\n', files['TZRO1.REG'])
        self.assertIn(b'"Time Zone"="RUNDLL32.EXE SHELL32.DLL,Control_FillCache_RunDLL"\r\n', files['TZRO2.REG'])
        self.assertIn(b'FIND.EXE "00,00,0a,00,00,00,05,00,03" TZ1.CHK', files['TZFIX.BAT'])

    def test_eastern_winter(self):
        rc, files = self.write('Eastern', 1)
        self.assertEqual(rc, 0)
        self.check_tzi(files['TZFIX.REG'], EASTERN_TZI)
        self.assertIn(b'"ActiveTimeBias"=hex:2c,01,00,00\r\n', files['TZFIX.REG'])
        self.assertIn(b'FIND.EXE "00,00,0a,00,00,00,05,00,02" TZ1.CHK', files['TZFIX.BAT'])

    def test_other_zones_get_nothing(self):
        for zone in ('Pacific', 'W. Europe', ''):
            rc, files = self.write(zone, 5)
            self.assertEqual(rc, 1, zone)
            self.assertEqual(files, {}, zone)

    def test_batch_is_dos_safe_and_acts_once(self):
        _, files = self.write('Central European', 7)
        bat = files['TZFIX.BAT']
        lines = bat.split(b'\r\n')
        self.assertEqual(bat.count(b'\n'), bat.count(b'\r\n'))
        self.assertLessEqual(max(len(line) for line in lines), 127)    # COMMAND.COM line limit
        bat.decode('ascii')
        text = bat.decode('ascii')
        # Nothing is changed unless the Date/Time step is still pending.
        self.assertLess(text.index('FIND.EXE /I "TIMEDATE" TZ0.CHK'), text.index('ECHO run>'))
        self.assertLess(text.index('ECHO run>'), text.index('COPY /Y SYSTEM.DAT'))
        self.assertLess(text.index('COPY /Y USER.DAT'), text.index('REGEDIT /L:SYSTEM.DAT /R:USER.DAT C:\\USOS9X\\TZFIX.REG'))
        for marker in ('TZFIX.OK GOTO END', 'TZFIX.BAD GOTO END', 'TZFIX.RUN GOTO END'):
            self.assertIn(marker, text)
        bad = text[text.index(':BAD'):]
        self.assertIn('COPY /Y C:\\USOS9X\\SYSTEM.TB SYSTEM.DAT', bad)


class Wiring(unittest.TestCase):
    def test_prepare_guards_the_msbatch_zone_and_passes_it_on(self):
        text = (ROOT / 'tools/w9x_csmwrap_prepare.sh').read_text(encoding='utf-8')
        none = text[text.index('        none)'):text.index('        profile)')]
        self.assertIn('w9x_csmwrap_log "TIMEZONE ${time_zone:-none', none)
        self.assertIn("grep -q 'TimeZone=' \"$answer_inf\"", none)
        self.assertIn('W9X_TIME_ZONE="${time_zone:-}"', text)

    def test_target_writes_tzfix_for_98_only(self):
        text = (ROOT / 'tools/w9x_csmwrap_target.sh').read_text(encoding='utf-8')
        self.assertIn('98SE:?*|98:?*)', text)
        self.assertIn('w9x_tzfix_write "$TIME_ZONE" "$work/c/USOS9X"', text)
        build = (ROOT / 'tools/build_micro_linux.py').read_text(encoding='utf-8')
        self.assertIn('("tools/w9x_tzfix.sh", "usr/lib/usos/w9x_tzfix.sh")', build)

    def test_target_block_runs(self):
        text = (ROOT / 'tools/w9x_csmwrap_target.sh').read_text(encoding='utf-8')
        block = text[text.index('case "$SYSTEM_TAG:$TIME_ZONE" in'):text.index('# The boot floppy runs INSTALL.BAT')]
        for tag, zone, expected in (('98SE', 'Central European', True), ('98', 'Eastern', True),
                                    ('ME', 'Central European', False), ('98SE', '', False), ('98SE', 'Pacific', False)):
            tmp = Path(tempfile.mkdtemp(prefix='usos-w9x-tzblock-'))
            self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
            (tmp / 'c/USOS9X').mkdir(parents=True)
            script = ('set -eu\nlog() { printf "%s\\n" "$*"; }\n'
                      f'SYSTEM_TAG={tag}\nTIME_ZONE="$Z"\nLIB="{(ROOT / "tools").as_posix()}"\nwork="{tmp.as_posix()}"\n' + block)
            rc, out, err = sh(script, {'Z': zone})
            self.assertEqual(rc, 0, err)
            self.assertEqual((tmp / 'c/USOS9X/TZFIX.BAT').exists(), expected, (tag, zone, out))
            self.assertEqual((tmp / 'c/USOS9X/TZFIX.REG').exists(), expected, (tag, zone))

    def test_autoexec_calls_tzfix_after_u9fix_in_csm_mode(self):
        lines = (ROOT / 'src/platform/bios/dos_startup.cmd').read_text(encoding='ascii').splitlines()
        hook = 'ECHO @IF EXIST C:\\USOS9X\\TZFIX.BAT CALL C:\\USOS9X\\TZFIX.BAT>>C:\\AUTOEXEC.BAT'
        self.assertEqual(lines.count(hook), 1)
        at = lines.index(hook)
        self.assertGreater(at, lines.index(':CSMAUTO'))
        self.assertGreater(at, lines.index('ECHO @C:\\USOS9X\\U9FIX.COM /CSM C:\\WINDOWS\\SYSTEM.INI>>C:\\AUTOEXEC.BAT'))
        self.assertLess(at, lines.index('ECHO @C:\\USOS9X\\USOSKEY.COM>>C:\\AUTOEXEC.BAT'))


if __name__ == '__main__':
    unittest.main()
