"""Windows 95 VESA display step (tools/w9x_vesa95.sh, C:\\USOS9X\\VESA95.BAT).

95 never enumerates PCI under SeaBIOS (VM phase 1, CSMWrap), so Setup leaves
the legacy-detected *PNP0900 on MSDISP.INF [VGA]; VESA95.BAT moves it to
USOSVESA.INF [VESA] once (X470, 95 OSR2.1 PL, 2026-10-07). Host only (Git sh).
Run: python tools/tests/test_w9x_vesa95.py
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
VESA95 = (ROOT / 'tools/w9x_vesa95.sh').as_posix()
INF = ROOT / 'src/platform/bios/win9x/usosvesa.inf'
CLS = 'HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\Class\\Display\\0000'


class Vesa95(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='usos-w9x-vesa95-'))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def write(self, *args):
        quoted = ' '.join('"%s"' % a for a in args)
        rc, out, err = sh(f'. "{VESA95}"\nw9x_vesa95_write "{self.tmp.as_posix()}" {quoted}', {})
        files = {n: (self.tmp / n).read_bytes() for n in ('VESA95.BAT', 'VESA95.REG') if (self.tmp / n).exists()}
        return rc, files

    def test_registry_matches_usosvesa_inf(self):
        rc, files = self.write()
        self.assertEqual(rc, 0)
        reg = files['VESA95.REG'].decode('ascii')
        self.assertTrue(reg.startswith('REGEDIT4\r\n\r\n[%s]\r\n' % CLS))
        self.assertNotIn('[-', reg)                                    # 95 REGEDIT deletes nothing
        self.assertIn('"InfPath"="USOSVESA.INF"\r\n"InfSection"="VESA"\r\n', reg)
        default = '[%s\\DEFAULT]\r\n"drv"="vesamini.drv"\r\n"minivdd"="vesamini.vxd"\r\n"vdd"="*vdd"\r\n' % CLS
        self.assertIn(default + '"Mode"="16,1024,768"\r\n', reg)
        self.assertIn('[HKEY_LOCAL_MACHINE\\Software\\vmdisp9x\\vesa]\r\n"VRAMLimit"="128"\r\n"NoMemTest"="1"\r\n', reg)
        self.assertIn('"BitsPerPixel"="16"\r\n"Resolution"="1024,768"\r\n', reg)
        # Every MODES key of the INF, nothing more.
        inf = INF.read_text(encoding='ascii')
        inf_modes = set(re.findall(r'^HKR,"MODES\\(\d+\\\d+,\d+)"', inf, re.M))
        reg_modes = set(re.findall(r'^\[' + re.escape(CLS) + r'\\MODES\\(\d+\\\d+,\d+)\]', reg, re.M))
        self.assertEqual(reg_modes, inf_modes)
        self.assertIn('%VESAISA.DeviceDesc%=VESA, *PNP0900', inf)       # the device 95 has

    def test_mode_choice_and_rejects(self):
        rc, files = self.write('32', '1920,1080')
        self.assertEqual(rc, 0)
        self.assertIn(b'"Mode"="32,1920,1080"\r\n', files['VESA95.REG'])
        for args in (('15', '1024,768'), ('16', '1366,768')):
            shutil.rmtree(self.tmp); self.tmp.mkdir()
            rc, files = self.write(*args)
            self.assertEqual(rc, 1, args)
            self.assertEqual(files, {}, args)

    def test_batch_is_dos_safe_and_acts_once(self):
        _, files = self.write()
        bat = files['VESA95.BAT']
        self.assertEqual(bat.count(b'\n'), bat.count(b'\r\n'))
        self.assertLessEqual(max(len(line) for line in bat.split(b'\r\n')), 125)
        text = bat.decode('ascii')
        for marker in ('VESA95.OK GOTO END', 'VESA95.BAD GOTO END', 'VESA95.RUN GOTO END'):
            self.assertIn(marker, text)
        # Nothing changes unless Display\0000 is still MSDISP.INF's.
        self.assertLess(text.index('FIND.EXE /I "msdisp.inf" VG0.CHK'), text.index('ECHO run>'))
        self.assertLess(text.index('ECHO run>'), text.index('COPY /Y C:\\USOS9X\\%%F C:\\WINDOWS\\SYSTEM'))
        self.assertLess(text.index('GOTO NOFILES'), text.index('COPY /Y SYSTEM.DAT'))
        self.assertLess(text.index('COPY /Y USER.DAT'), text.index('REGEDIT /L:SYSTEM.DAT /R:USER.DAT C:\\USOS9X\\VESA95.REG'))
        for name in ('VESAMINI.DRV', 'VESAMINI.VXD', 'VMDISP9X.DLL', 'VMHAL9X.DLL', 'VMHAL486.DLL'):
            self.assertIn(name, text)
        bad = text[text.index(':BAD'):]
        self.assertIn('COPY /Y C:\\USOS9X\\SYSTEM.V5 SYSTEM.DAT', bad)
        self.assertIn('COPY /Y C:\\USOS9X\\USER.V5 USER.DAT', bad)

    def test_registry_files_lose_the_system_attribute_before_the_backup(self):
        # SYSTEM.DAT / USER.DAT are +S +H +R: ATTRIB -R -H alone is refused
        # ("Not resetting system file"), COPY then misses the hidden file and
        # no backup is made (X470, 95 OSR2.1 PL, 2026-10-07: only VESA95.RUN).
        text = self.write()[1]['VESA95.BAT'].decode('ascii')
        for name in ('SYSTEM.DAT', 'USER.DAT'):
            self.assertLess(text.index('ATTRIB.EXE -S -R -H ' + name), text.index('COPY /Y ' + name))
            self.assertIn('ATTRIB.EXE +S +R +H ' + name, text[text.index(':ATTR'):])
        self.assertNotIn('ATTRIB.EXE -R -H', text)


class Wiring(unittest.TestCase):
    def test_target_writes_vesa95_for_95_only(self):
        text = (ROOT / 'tools/w9x_csmwrap_target.sh').read_text(encoding='utf-8')
        block = text[text.index('if [ "$SYSTEM_TAG" = 95 ]; then\n    if [ -r "$LIB/w9x_vesa95.sh" ]'):
                     text.index('# The boot floppy runs INSTALL.BAT')]
        for tag, expected in (('95', True), ('98SE', False), ('98', False), ('ME', False)):
            tmp = Path(tempfile.mkdtemp(prefix='usos-w9x-vesablock-'))
            self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
            (tmp / 'c/USOS9X').mkdir(parents=True)
            script = ('set -eu\nlog() { printf "%s\\n" "$*"; }\n'
                      f'SYSTEM_TAG={tag}\nLIB="{(ROOT / "tools").as_posix()}"\nwork="{tmp.as_posix()}"\n' + block)
            rc, out, err = sh(script, {})
            self.assertEqual(rc, 0, err)
            self.assertEqual((tmp / 'c/USOS9X/VESA95.BAT').exists(), expected, (tag, out))
            self.assertEqual((tmp / 'c/USOS9X/VESA95.REG').exists(), expected, tag)
        build = (ROOT / 'tools/build_micro_linux.py').read_text(encoding='utf-8')
        self.assertIn('("tools/w9x_vesa95.sh", "usr/lib/usos/w9x_vesa95.sh")', build)

    def test_autoexec_calls_vesa95_in_csm_mode_before_the_bridge(self):
        lines = (ROOT / 'src/platform/bios/dos_startup.cmd').read_text(encoding='ascii').splitlines()
        hook = 'ECHO @IF EXIST C:\\USOS9X\\VESA95.BAT CALL C:\\USOS9X\\VESA95.BAT>>C:\\AUTOEXEC.BAT'
        self.assertEqual(lines.count(hook), 1)
        at = lines.index(hook)
        self.assertGreater(at, lines.index(':CSMAUTO'))
        self.assertLess(at, lines.index('ECHO @C:\\USOS9X\\USOSKEY.COM>>C:\\AUTOEXEC.BAT'))


if __name__ == '__main__':
    unittest.main()
