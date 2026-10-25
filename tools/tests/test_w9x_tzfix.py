"""98 / 98 SE first-boot time zone step (tools/w9x_tzfix.sh, C:\\USOS9X\\TZFIX.BAT)
and the MSBATCH TimeZone guard of tools/w9x_csmwrap_prepare.sh. Host only (Git sh);
the same output under the micro-Linux BusyBox was compared byte for byte."""
from pathlib import Path
import datetime
import shutil
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_w9x_phase1_qemu import sh

ROOT = Path(__file__).resolve().parents[2]
TZFIX = (ROOT / 'tools/w9x_tzfix.sh').as_posix()
NAMES = ('TZFIX.BAT', 'TZFIX.REG', 'TZDST.REG', 'TZRO1.REG', 'TZRO2.REG')
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

    def write(self, zone, when):
        rc, out, err = sh(f'. "{TZFIX}"\nw9x_tzfix_write "$Z" "{self.tmp.as_posix()}" "$W"', {'Z': zone, 'W': when})
        return rc, {name: (self.tmp / name).read_bytes() for name in NAMES if (self.tmp / name).exists()}

    def check_tzi(self, reg, tzi):
        bias, daylight, std, dlt = tzi
        self.assertIn(f'"Bias"=hex:{bias}\r\n'.encode(), reg)
        self.assertIn(f'"DaylightBias"=hex:{daylight}\r\n'.encode(), reg)
        self.assertIn(f'"StandardStart"=hex:{std}\r\n'.encode(), reg)
        self.assertIn(f'"DaylightStart"=hex:{dlt}\r\n'.encode(), reg)

    def test_central_european_matches_the_hardware_proven_file(self):
        rc, files = self.write('Central European', '2026-07-15 12:00')
        self.assertEqual(rc, 0)
        reg = files['TZFIX.REG']
        self.assertTrue(reg.startswith(b'REGEDIT4\r\n\r\n[HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\control\\TimeZoneInformation]\r\n'))
        self.check_tzi(reg, CE_TZI)
        self.assertIn('"StandardName"="Europa Środkowa (czas stand.)"\r\n'.encode('cp1250'), reg)
        self.assertIn(b'"ActiveTimeBias"=hex:88,ff,ff,ff\r\n', reg)   # 15 July, summer: -120
        self.assertIn(b'"DisableAutoDaylightTimeSet"=hex:01,00,00,00\r\n', reg)   # off during Setup
        self.assertNotIn(b'[-', reg)                                   # no key is deleted
        self.assertIn(b'"Strefa czasowa"="RUNDLL32.EXE SHELL32.DLL,Control_FillCache_RunDLL"\r\n', files['TZRO1.REG'])
        self.assertIn(b'"Time Zone"="RUNDLL32.EXE SHELL32.DLL,Control_FillCache_RunDLL"\r\n', files['TZRO2.REG'])
        self.assertIn(b'FIND.EXE "00,00,0a,00,00,00,05,00,03" TZ1.CHK', files['TZFIX.BAT'])

    def test_eastern_winter(self):
        rc, files = self.write('Eastern', '2026-01-15 12:00')
        self.assertEqual(rc, 0)
        self.check_tzi(files['TZFIX.REG'], EASTERN_TZI)
        self.assertIn(b'"ActiveTimeBias"=hex:2c,01,00,00\r\n', files['TZFIX.REG'])
        self.assertIn(b'FIND.EXE "00,00,0a,00,00,00,05,00,02" TZ1.CHK', files['TZFIX.BAT'])

    def test_other_zones_get_nothing(self):
        for zone in ('Pacific', 'W. Europe', ''):
            rc, files = self.write(zone, '2026-05-15 12:00')
            self.assertEqual(rc, 1, zone)
            self.assertEqual(files, {}, zone)

    def test_batch_is_dos_safe_and_acts_once(self):
        _, files = self.write('Central European', '2026-07-15 12:00')
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
        for marker in ('TZFIX.OK GOTO LATE', 'TZFIX.BAD GOTO END', 'TZFIX.RUN GOTO END'):
            self.assertIn(marker, text)
        bad = text[text.index(':BAD'):]
        self.assertIn('COPY /Y C:\\USOS9X\\SYSTEM.TB SYSTEM.DAT', bad)
        # +S +H +R registry files: without -S, ATTRIB refuses and COPY misses them.
        for name in ('SYSTEM.DAT', 'USER.DAT'):
            self.assertLess(text.index('ATTRIB.EXE -S -R -H ' + name), text.index('COPY /Y ' + name))
            self.assertIn('ATTRIB.EXE +S +R +H ' + name, text[text.index(':ATTR'):])
        self.assertNotIn('ATTRIB.EXE -R -H', text)


class Tzfix950(unittest.TestCase):
    """95 RTM / OSR1 (4.00.950) PL and EN CDs: TIMEZONE.INF keys, the
    pre-1996 EU rule of "Lisbon Warsaw" and MSPRINT.DLL's printer step."""
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='usos-w9x-tz950-'))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def run_sh(self, code, env=None):
        rc, out, err = sh(f'. "{TZFIX}"\n' + code, env or {})
        return rc, out

    def test_950_keys(self):
        for osr2, want in (('Warsaw', 'Lisbon Warsaw'), ('Central European', 'Lisbon Warsaw'),
                           ('Prague Bratislava', 'Czech'), ('Beijing', 'China'), ('AUS Eastern', 'Sydney'),
                           ('Bangkok', 'Bangkok'), ('Saudi Arabia', 'Saudi Arabia'), ('Eastern', 'Eastern'),
                           ('GTB', 'GFT'), ('E. Australia', ''), ('Pacific SA', '')):
            rc, out = self.run_sh('w9x_tz950_key "$Z"', {'Z': osr2})
            self.assertEqual(out, want, osr2)

    def test_msbatch_rewrite(self):
        inf = self.tmp / 'MSBATCH.INF'
        for zone, want in (('Warsaw', b'TimeZone="Lisbon Warsaw"\r\n'), ('E. Australia', None)):
            inf.write_bytes(b'[Setup]\r\nExpress=1\r\nTimeZone="%s"\r\nVRC=1\r\n' % zone.encode())
            rc, _ = self.run_sh(f'w9x_msbatch_tz950 "{inf.as_posix()}"')
            data = inf.read_bytes()
            self.assertEqual(rc, 0)
            self.assertIn(b'Express=1\r\n', data)
            self.assertIn(b'VRC=1\r\n', data)
            if want:
                self.assertIn(want, data)
            else:
                self.assertNotIn(b'TimeZone', data)

    def write(self, zone, src, lang='PL'):
        rc, _ = self.run_sh(f'w9x_tzfix_write "$Z" "{self.tmp.as_posix()}" "2026-10-10 12:00" {src} {lang}', {'Z': zone})
        return rc, {p.name: p.read_bytes() for p in self.tmp.iterdir()}

    def test_lisbon_warsaw_gets_the_eu_rule_and_list_tzi(self):
        rc, files = self.write('Lisbon Warsaw', 950)
        self.assertEqual(rc, 0)
        reg = files['TZFIX.REG']
        self.assertIn(b'"StandardStart"=hex:00,00,0a,00,00,00,05,00,03,00,00,00,00,00,00,00\r\n', reg)
        self.assertIn(b'"StandardName"="Lizbona/Warszawa - czas zimowy"\r\n', reg)
        self.assertIn(b'[HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows\\CurrentVersion\\Time Zones\\Lisbon Warsaw]\r\n'
                      b'"TZI"=hex:c4,ff,ff,ff,00,00,00,00,c4,ff,ff,ff,\\\r\n'
                      b'  00,00,0a,00,00,00,05,00,03,00,00,00,00,00,00,00,\\\r\n'
                      b'  00,00,03,00,00,00,05,00,02,00,00,00,00,00,00,00\r\n', reg)
        _, en = self.write('Lisbon Warsaw', 950, 'EN')
        self.assertIn(b'"StandardName"="Lisbon Warsaw Standard Time"\r\n', en['TZFIX.REG'])
        # Only 950 has the key; OSR2 / 98 never get it.
        for p in self.tmp.iterdir():
            p.unlink()
        rc, files = self.write('Lisbon Warsaw', '')
        self.assertEqual((rc, files), (1, {}))

    def test_printer_step_and_case_insensitive_step_names(self):
        _, files = self.write('Lisbon Warsaw', 950)
        harmless = b'"="RUNDLL32.EXE SHELL32.DLL,Control_FillCache_RunDLL"\r\n'
        self.assertIn(b'"Drukarki' + harmless, files['TZPR1.REG'])
        self.assertIn(b'"Set up printer' + harmless, files['TZPR2.REG'])
        text = files['TZFIX.BAT'].decode('ascii')
        self.assertIn('FIND.EXE /I "Time Zone" TZ0.CHK', text)        # EN 950: "Time zone"
        self.assertIn('FIND.EXE /I "Drukarki" TZ0.CHK > NUL\r\nIF NOT ERRORLEVEL 1 REGEDIT /L:SYSTEM.DAT /R:USER.DAT C:\\USOS9X\\TZPR1.REG', text)
        self.assertIn('FIND.EXE /I "Set up printer" TZ0.CHK > NUL\r\nIF NOT ERRORLEVEL 1 REGEDIT /L:SYSTEM.DAT /R:USER.DAT C:\\USOS9X\\TZPR2.REG', text)
        self.assertLess(text.index('TZPR2.REG'), text.index('/E TZ2.CHK'))
        self.assertIn('ECHO ok-printer-left>', text)
        self.assertLessEqual(max(len(line) for line in text.split('\r\n')), 127)
        # OSR2 / 98: no printer files, no printer lines.
        for p in self.tmp.iterdir():
            p.unlink()
        _, files = self.write('Warsaw', '')
        self.assertNotIn('TZPR1.REG', files)
        self.assertNotIn(b'Drukarki', files['TZFIX.BAT'])


def decode_reg(data):
    """TimeZoneInformation values of a TZFIX.REG: name -> bytes (hex) or str."""
    text = data.decode('cp1250').replace('\\\r\n  ', '')
    key = '[HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\control\\TimeZoneInformation]\r\n'
    body = text[text.index(key) + len(key):].split('\r\n\r\n', 1)[0]
    values = {}
    for line in body.split('\r\n'):
        name, _, value = line.partition('=')
        name = name.strip('"')
        values[name] = bytes.fromhex(value[4:].replace(',', '')) if value.startswith('hex:') else value.strip('"')
    return values


def windows_rule(st, year):
    """Independent reference: a SYSTEMTIME rule date (week 5 = last) in YEAR."""
    _, month, dow, week, hour, minute, _, _ = struct.unpack('<8H', st)
    day = datetime.date(year, month, 1)
    day += datetime.timedelta((dow - (day.weekday() + 1) % 7) % 7 + 7 * (week - 1))
    while day.month != month:
        day -= datetime.timedelta(7)
    return datetime.datetime(day.year, day.month, day.day, hour, minute)


class TzfixDaylight(unittest.TestCase):
    """ActiveTimeBias from the local date and time under the zone's own rule
    (last / n-th Sunday incl. the hour); DisableAutoDaylightTimeSet=1 (off)
    for Setup's boots, TZDST.REG's 0 after them (TzdstLate)."""
    ZONES = (('Lisbon Warsaw', '950'), ('Central European', ''), ('Warsaw', ''), ('Eastern', ''), ('Eastern', '950'))

    def active(self, zone, src, when):
        tmp = Path(tempfile.mkdtemp(prefix='usos-w9x-tzdst-'))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        rc, out, err = sh(f'. "{TZFIX}"\nw9x_tzfix_write "$Z" "{tmp.as_posix()}" "$W" "$S" PL',
                          {'Z': zone, 'W': when, 'S': src})
        self.assertEqual(rc, 0, (zone, src, when, err))
        values = decode_reg((tmp / 'TZFIX.REG').read_bytes())
        self.assertEqual(values['DisableAutoDaylightTimeSet'], b'\1\0\0\0', zone)
        return values, struct.unpack('<i', values['ActiveTimeBias'])[0]

    def test_central_europe_switch_hours(self):
        for zone, src in self.ZONES[:3]:
            for when, want in (('2026-10-25 16:25', -60), ('2026-10-25 02:30', -120), ('2026-10-25 03:00', -60),
                               ('2026-10-24 23:59', -120), ('2026-03-29 01:59', -60), ('2026-03-29 03:00', -120),
                               ('2026-03-28 12:00', -60), ('2026-01-01 00:00', -60), ('2026-12-31 23:59', -60),
                               ('2026-07-01 12:00', -120), ('2026-10-01 12:00', -120), ('2026-04-01 12:00', -120),
                               ('2027-10-31 02:59', -120), ('2027-10-31 03:00', -60)):
                self.assertEqual(self.active(zone, src, when)[1], want, (zone, when))
        values, _ = self.active('Lisbon Warsaw', '950', '2026-10-25 16:25')
        self.assertEqual(values['ActiveTimeBias'], bytes.fromhex('c4ffffff'))

    def test_eastern_switch_hours(self):
        # Eastern's 9x TZI is the old US rule: first Sunday of April and last
        # Sunday of October, 02:00 (Windows applies the zone's own data).
        for zone, src in self.ZONES[3:]:
            for when, want in (('2026-04-05 01:59', 300), ('2026-04-05 02:00', 240), ('2026-10-25 01:59', 240),
                               ('2026-10-25 02:00', 300), ('2026-11-01 12:00', 300), ('2026-03-20 12:00', 300),
                               ('2026-07-04 12:00', 240)):
                self.assertEqual(self.active(zone, src, when)[1], want, (zone, when))

    def test_matches_an_independent_rule_over_years(self):
        for zone, src in (('Lisbon Warsaw', '950'), ('Eastern', '')):
            for year in (2024, 2025, 2027, 2028, 2100):
                values, _ = self.active(zone, src, f'{year}-06-01 00:00')
                std, dlt = windows_rule(values['StandardStart'], year), windows_rule(values['DaylightStart'], year)
                bias = struct.unpack('<i', values['Bias'])[0]
                daylight = struct.unpack('<i', values['DaylightBias'])[0]
                for moment in (dlt - datetime.timedelta(minutes=1), dlt, std - datetime.timedelta(minutes=1), std):
                    want = bias + (daylight if dlt <= moment < std else 0)
                    self.assertEqual(self.active(zone, src, moment.strftime('%Y-%m-%d %H:%M'))[1], want, (zone, moment))

    def test_unusable_time_is_standard_time(self):
        for when in ('garbage', '2026-07'):
            self.assertEqual(self.active('Central European', '', when)[1], -60, when)

    def test_target_passes_the_local_wall_time(self):
        text = (ROOT / 'tools/w9x_csmwrap_target.sh').read_text(encoding='utf-8')
        self.assertIn("tz_when=$(date '+%Y-%m-%d %H:%M' 2>/dev/null || :)", text)
        self.assertIn('w9x_tzfix_write "$TIME_ZONE" "$work/c/USOS9X" "$tz_when"', text)


class TzdstLate(unittest.TestCase):
    """Automatic summer time: off (1) in TZFIX.REG for Setup's first GUI boots
    (the X470 950 first GUI boots on the 2026-10-25 summer-time end day hung
    in GRPCONV with it on: suspected cause), on (0) through TZDST.REG once
    RunOnce\\Setup is gone. The same for 95 / 98 / 98 SE."""
    CASES = (('Lisbon Warsaw', '950'), ('Central European', ''), ('Eastern', ''))

    def write(self, zone, src):
        tmp = Path(tempfile.mkdtemp(prefix='usos-w9x-tzlate-'))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        rc, out, err = sh(f'. "{TZFIX}"\nw9x_tzfix_write "$Z" "{tmp.as_posix()}" "2026-10-25 16:25" "$S" PL', {'Z': zone, 'S': src})
        self.assertEqual(rc, 0, err)
        return {p.name: p.read_bytes() for p in tmp.iterdir()}

    def test_late_reg_sets_only_the_switch(self):
        for zone, src in self.CASES:
            files = self.write(zone, src)
            self.assertEqual(files['TZDST.REG'], b'REGEDIT4\r\n\r\n[HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\control\\'
                             b'TimeZoneInformation]\r\n"DisableAutoDaylightTimeSet"=hex:00,00,00,00\r\n\r\n')
            self.assertEqual(decode_reg(files['TZFIX.REG'])['DisableAutoDaylightTimeSet'], b'\1\0\0\0')

    def test_late_step_waits_for_setup_and_runs_once(self):
        for zone, src in self.CASES:
            bat = self.write(zone, src)['TZFIX.BAT']
            self.assertEqual(bat.count(b'\n'), bat.count(b'\r\n'))
            text = bat.decode('ascii')
            self.assertLessEqual(max(len(line) for line in text.split('\r\n')), 127)
            labels = [line[1:] for line in text.split('\r\n') if line.startswith(':')]
            self.assertEqual(len(labels), len(set(labels)))
            # The first-boot import marks the late step only after the zone check.
            first = text[:text.index(':LATE')]
            self.assertLess(first.index('FIND.EXE "00,00,'), first.index('ECHO pending> C:\\USOS9X\\TZDST.PND'))
            self.assertLess(first.index('TZDST.PND'), first.index('/E TZ2.CHK'))
            self.assertIn('IF EXIST C:\\USOS9X\\TZDST.PND DEL C:\\USOS9X\\TZDST.PND', first[first.index(':BAD'):])
            self.assertTrue(first.endswith('GOTO END\r\nREM Once, only after this step imported TZFIX.REG, never while RunOnce\\Setup exists.\r\n'))
            self.assertNotIn('TZDST.REG', first)
            late = text[text.index(':LATE'):]
            order = ['IF NOT EXIST C:\\USOS9X\\TZDST.PND GOTO END', 'IF EXIST C:\\USOS9X\\TZDST.OK GOTO END',
                     'IF EXIST C:\\USOS9X\\TZDST.ERR GOTO END',
                     'REGEDIT /L:SYSTEM.DAT /R:USER.DAT /E TZ3.CHK HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce\r\n',
                     'FIND.EXE "REGEDIT4" TZ3.CHK', 'FIND.EXE /I "\\RunOnce\\Setup]" TZ3.CHK',
                     'IF ERRORLEVEL 2 GOTO DSTERR\r\nIF NOT ERRORLEVEL 1 GOTO DSTWAIT',
                     'ATTRIB.EXE -S -R -H SYSTEM.DAT', 'REGEDIT /L:SYSTEM.DAT /R:USER.DAT C:\\USOS9X\\TZDST.REG',
                     '/E TZ4.CHK HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\control\\TimeZoneInformation',
                     'ATTRIB.EXE +S +R +H SYSTEM.DAT', 'ATTRIB.EXE +S +R +H USER.DAT',
                     'FIND.EXE /I "DisableAutoDaylightTimeSet" TZ4.CHK',
                     'FIND.EXE /I "hex:01,00,00,00" TZ4.CHK > NUL\r\nIF NOT ERRORLEVEL 1 GOTO DSTERR',
                     'ECHO ok> C:\\USOS9X\\TZDST.OK', ':DSTERR', '>> C:\\USOS9X\\USOSLOG.TXT', ':DSTWAIT', ':END']
            at = [late.index(o) for o in order]
            self.assertEqual(at, sorted(at), (zone, src))
            # No backup copy, no PAUSE; a failure is logged and Windows starts.
            self.assertNotIn('PAUSE', text)
            self.assertNotIn('COPY', late)


class Wiring(unittest.TestCase):
    def test_prepare_guards_the_msbatch_zone_and_passes_it_on(self):
        text = (ROOT / 'tools/w9x_csmwrap_prepare.sh').read_text(encoding='utf-8')
        # The 9x answer switch; the POSReady and NT switches above it have
        # their own none) / profile) arms.
        begin = text.index('\n        none)', text.index('        nt4|posr) ;;'))
        none = text[begin:text.index('\n        profile)', begin)]
        self.assertIn('w9x_csmwrap_log "TIMEZONE ${time_zone:-none', none)
        self.assertIn("grep -q 'TimeZone=' \"$answer_inf\"", none)
        self.assertIn('W9X_TIME_ZONE="${time_zone:-}"', text)

    def test_target_writes_tzfix_for_95_and_98_only(self):
        text = (ROOT / 'tools/w9x_csmwrap_target.sh').read_text(encoding='utf-8')
        self.assertIn('98SE:?*|98:?*|95:?*)', text)
        self.assertIn('w9x_tzfix_write "$TIME_ZONE" "$work/c/USOS9X"', text)
        build = (ROOT / 'tools/build_micro_linux.py').read_text(encoding='utf-8')
        self.assertIn('("tools/w9x_tzfix.sh", "usr/lib/usos/w9x_tzfix.sh")', build)

    def test_target_block_runs(self):
        text = (ROOT / 'tools/w9x_csmwrap_target.sh').read_text(encoding='utf-8')
        block = text[text.index('case "$SYSTEM_TAG:$TIME_ZONE" in'):text.index('# The boot floppy runs INSTALL.BAT')]
        for tag, zone, expected in (('98SE', 'Central European', True), ('98', 'Eastern', True),
                                    ('95', 'Warsaw', True), ('95', 'Eastern', True),
                                    ('ME', 'Central European', False), ('98SE', '', False), ('98SE', 'Pacific', False)):
            tmp = Path(tempfile.mkdtemp(prefix='usos-w9x-tzblock-'))
            self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
            (tmp / 'c/USOS9X').mkdir(parents=True)
            # REG95 / Channel Bar steps share the block: off here (test_w9x_reg95.py).
            script = ('set -eu\nlog() { printf "%s\\n" "$*"; }\nANSWER_KIND=USER\nlog_ok=0\n'
                      f'SYSTEM_TAG={tag}\nTIME_ZONE="$Z"\nLIB="{(ROOT / "tools").as_posix()}"\nwork="{tmp.as_posix()}"\n' + block)
            rc, out, err = sh(script, {'Z': zone})
            self.assertEqual(rc, 0, err)
            self.assertEqual((tmp / 'c/USOS9X/TZFIX.BAT').exists(), expected, (tag, zone, out))
            self.assertEqual((tmp / 'c/USOS9X/TZFIX.REG').exists(), expected, (tag, zone))

    def test_target_answer_zone_950_and_profile_runs(self):
        text = (ROOT / 'tools/w9x_csmwrap_target.sh').read_text(encoding='utf-8')
        start = text.index('cp "$ANSWER_INF" "$work/c/USOS9X/MSBATCH.INF"')
        block = text[start:text.index('# The pinned MIT VESA driver', start)]
        for tag, version, given, zone, want in (('95', '4 0 0 950', '', 'Warsaw', 'Lisbon Warsaw'),
                                                ('95', '4 0 0 950', 'Warsaw', 'Warsaw', 'Lisbon Warsaw'),
                                                ('95', '4 0 0 1111', '', 'Warsaw', 'Warsaw'),
                                                ('98SE', '', '', 'Central European', 'Central European'),
                                                ('98SE', '', 'Eastern', 'Central European', 'Eastern')):
            tmp = Path(tempfile.mkdtemp(prefix='usos-w9x-tzans-'))
            self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
            (tmp / 'c/USOS9X').mkdir(parents=True)
            (tmp / 'A.INF').write_bytes(b'[Setup]\r\nTimeZone="%s"\r\n' % zone.encode())
            script = ('set -eu\nlog() { printf "%s\\n" "$*"; }\nfail() { exit 9; }\n'
                      f'SYSTEM_TAG={tag}\nsetup_version="$V"\nTIME_ZONE="$G"\nANSWER_INF="{(tmp / "A.INF").as_posix()}"\n'
                      f'LIB="{(ROOT / "tools").as_posix()}"\nwork="{tmp.as_posix()}"\n' + block + '\nprintf "%s" "$TIME_ZONE"')
            rc, out, err = sh(script, {'V': version, 'G': given})
            self.assertEqual(rc, 0, err)
            self.assertTrue(out.endswith(want), (tag, version, given, out))
            if version == '4 0 0 950':
                self.assertIn(b'TimeZone="Lisbon Warsaw"\r\n', (tmp / 'c/USOS9X/MSBATCH.INF').read_bytes())

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
