"""Windows 9x USB sticks through USOSUSB.MPD: on by default since the X470 Windows Me
pass (2026-10-19), off with DATA's Systems\\<category>\\<9x>\\Unattended\\usb-storage-off.txt
(docs/usb9x-hotswap-design-2026-10-19.md). Host only (Git sh):
the USOSUSB and int13 blocks of tools/w9x_csmwrap_target.sh are cut out of the
script and run as they are against a temp C:\\USOS9X; the prepare.sh flag, the
INSTALL.BAT lines (dos_startup.cmd), build_win9x_support.stage_usosusb with
stand-in miniport files and the payload lists. No VM, no disk, no miniport build."""
from pathlib import Path
import re
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_w9x_phase1_qemu import sh  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
TARGET = (ROOT / 'tools/w9x_csmwrap_target.sh').read_text(encoding='utf-8')
PREPARE = (ROOT / 'tools/w9x_csmwrap_prepare.sh').read_text(encoding='utf-8')
BAT = (ROOT / 'src/platform/bios/dos_startup.cmd').read_text(encoding='latin-1')


def cut(text, start, end):
    a = text.index(start)
    return text[a:text.index(end, a) + len(end)]


UDS = cut(TARGET, 'uds_ok=0\n',
          '[ "$uds_ok" = 1 ] || rm -f "$work/c/USOS9X/USOSUSB.MPD" "$work/c/USOS9X/USOSUSB.INF" '
          '"$work/c/USOS9X/USOSUSB.REG"\n')
GATE = cut(TARGET, 'int13_only=off\n', '\nfi\n')
CLASSIDX = re.search(r'^USOSUSB_CLASSIDX=(\d{4})$', TARGET, re.M).group(1)
REG = ('REGEDIT4\r\n\r\n[HKEY_LOCAL_MACHINE\\Enum\\Root\\SCSIAdapter\\@CLASSIDX@]\r\n'
       '"Driver"="SCSIAdapter\\\\@CLASSIDX@"\r\n\r\n'
       '[HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\Class\\SCSIAdapter\\@CLASSIDX@]\r\n'
       '"PortDriver"="usosusb.mpd"\r\n\r\n')
U9ENV = b'SET U9SYS=98SE\r\nSET U9DISK=1\r\n'


class TargetScript(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='usos-w9x-uds-'))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.c = self.tmp / 'work/c/USOS9X'
        self.c.mkdir(parents=True)
        (self.c / 'U9ENV.BAT').write_bytes(U9ENV)
        (self.c / 'USOSUSB.MPD').write_bytes(b'MZ stand-in')
        (self.c / 'USOSUSB.INF').write_bytes(b'[Version]\r\n')
        (self.c / 'USOSUSB.REG').write_bytes(REG.encode('ascii'))
        self.xhci98 = self.tmp / 'xhci98.flag'
        self.int13_all = self.tmp / 'int13-all-disks.flag'

    def run_block(self, usb, tag='98SE', answer='USOS', nvme_ok=0):
        script = ('set -eu\nlog() { printf "%s\\n" "$*" >&2; }\n'
                  'fail() { printf "STOP %s\\n" "$1" >&2; exit 1; }\n'
                  f'work="{(self.tmp / "work").as_posix()}"\nUSB_STORAGE={usb}\nSYSTEM_TAG={tag}\n'
                  f'ANSWER_KIND={answer}\nUSOSUSB_CLASSIDX={CLASSIDX}\nnvme_ok={nvme_ok}\n'
                  f'XHCI98_FLAG="{self.xhci98.as_posix()}"\nINT13_ALL_FLAG="{self.int13_all.as_posix()}"\n'
                  + UDS + GATE + 'printf "%s" "$int13_only"\n')
        # From a file: through `sh -c` the Windows command line folds the
        # heredoc's backslashes (MSYS argument parsing), busybox never sees that.
        path = self.tmp / 'block.sh'
        path.write_bytes(script.encode('utf-8'))
        rc, out, err = sh(f'. "{path.as_posix()}"')
        self.assertEqual(rc, 0, err)
        return out, err

    def names(self):
        return sorted(p.name for p in self.c.iterdir())

    def assert_no_usosusb(self):
        self.assertEqual(self.names(), ['U9ENV.BAT'])
        self.assertEqual((self.c / 'U9ENV.BAT').read_bytes(), U9ENV)

    def test_flag_off_changes_nothing(self):
        for tag in ('98SE', '98', 'ME', '95'):
            with self.subTest(tag=tag):
                self.setUp()
                out, err = self.run_block(0, tag)
                self.assert_no_usosusb()
                self.assertEqual((out, err), ('off', ''))
                # the NVMe rule is unchanged without the flag
                self.setUp()
                self.assertEqual(self.run_block(0, tag, nvme_ok=1)[0], 'on')
                self.assertNotIn('usb storage', self.run_block(0, tag, nvme_ok=1)[1])

    def test_flag_on_stages_usosusb(self):
        out, err = self.run_block(1)
        self.assertEqual(out, 'on')                         # SATA target: boot disk only, too
        self.assertIn('only the boot disk is a BIOS hard disk', err)
        self.assertIn('3.1.2-usos17', err)
        self.assertIn(f'SCSIAdapter\\{CLASSIDX}', err)
        self.assertEqual(self.names(), ['U9ENV.BAT', 'USBREG.BAT', 'USOSUSB.INF', 'USOSUSB.MPD', 'USOSUSB.REG'])
        self.assertEqual((self.c / 'U9ENV.BAT').read_bytes(), U9ENV + b'SET U9UDS=1\r\n')
        self.assertNotIn(b'U9USB', (self.c / 'U9ENV.BAT').read_bytes())   # xhci98's variable
        reg = (self.c / 'USOSUSB.REG').read_bytes().replace(b'\r\n', b'\n')
        self.assertNotIn(b'@CLASSIDX@', reg)
        self.assertEqual(reg.count(CLASSIDX.encode()), 3)   # root instance, Driver, class key
        self.assertTrue(reg.startswith(b'REGEDIT4\n'))
        self.assertEqual((self.c / 'USOSUSB.MPD').read_bytes(), b'MZ stand-in')
        bat = (self.c / 'USBREG.BAT').read_bytes()
        self.assertEqual(bat.count(b'\n'), bat.count(b'\r\n'))
        lines = bat.decode('ascii').split('\r\n')
        self.assertTrue(all(len(line) < 128 for line in lines))
        # no IF with a redirection (COMMAND.COM opens the file even when false)
        self.assertFalse([l for l in lines if l.startswith('IF ') and '>' in l])
        text = '\n'.join(lines)
        for line in (r'IF EXIST C:\USOS9X\USBREG.RUN GOTO END',
                     r'IF NOT EXIST C:\WINDOWS\SYSTEM.DAT GOTO END',
                     r'COPY /Y C:\USOS9X\USOSUSB.MPD C:\WINDOWS\SYSTEM\IOSUBSYS > NUL',
                     r'C:\WINDOWS\COMMAND\ATTRIB.EXE -S -R -H SYSTEM.DAT',
                     r'REGEDIT /L:SYSTEM.DAT /R:USER.DAT C:\USOS9X\USOSUSB.REG',
                     r'C:\WINDOWS\COMMAND\ATTRIB.EXE +S +R +H USER.DAT',
                     r'ECHO ok> C:\USOS9X\USBREG.OK', 'CD \\'):
            self.assertIn('\n' + line + '\n', text)
        # one attempt: the marker before REGEDIT, after the MPD copy
        self.assertLess(text.index('IOSUBSYS\\USOSUSB.MPD GOTO END'), text.index('ECHO run>'))
        self.assertLess(text.index('ECHO run>'), text.index(r'/R:USER.DAT C:\USOS9X\USOSUSB.REG'))

    def test_flag_on_nvme(self):
        out, err = self.run_block(1, nvme_ok=1)
        self.assertEqual(out, 'on')
        self.assertIn('USOSUSB.MPD (default; usb-storage-off.txt', err)

    def test_me(self):
        out, err = self.run_block(1, 'ME')
        self.assertEqual(out, 'on')
        self.assertEqual(self.names(), ['U9ENV.BAT', 'USOSUSB.INF', 'USOSUSB.MPD', 'USOSUSB.REG'])
        self.assertIn(b'SET U9UDS=1\r\n', (self.c / 'U9ENV.BAT').read_bytes())
        # the Me import lives in the USOS answer (INSTALL.BAT): not with the user's own file
        self.setUp()
        out, err = self.run_block(1, 'ME', 'USER')
        self.assert_no_usosusb()
        self.assertEqual(out, 'off')
        self.assertIn("user's own answer file", err)
        self.setUp()
        self.assertEqual(self.run_block(1, '98SE', 'USER')[0], 'on')
        self.assertIn('USBREG.BAT', self.names())

    def test_not_with_xhci98(self):
        self.xhci98.write_bytes(b'')
        out, err = self.run_block(1)
        self.assert_no_usosusb()
        self.assertEqual(out, 'off')
        self.assertIn('USOSUSB.MPD skipped: win9x/xhci98.flag', err)

    def test_int13_all_disks_opt_out(self):
        self.int13_all.write_bytes(b'')
        out, err = self.run_block(1)
        self.assertEqual(out, 'off')
        self.assertIn('int13-all-disks.flag', err)
        self.assertIn('USOSUSB.MPD will offer no stick', err)
        self.assertIn('USBREG.BAT', self.names())         # still installed, offers nothing
        self.setUp()
        self.int13_all.write_bytes(b'')
        self.assertNotIn('will offer no stick', self.run_block(0, nvme_ok=1)[1])

    def test_missing_or_bad_payload(self):
        (self.c / 'USOSUSB.REG').unlink()
        out, err = self.run_block(1)
        self.assert_no_usosusb()
        self.assertEqual(out, 'off')
        self.assertIn('not in this payload', err)
        self.setUp()
        (self.c / 'USOSUSB.REG').write_bytes(b'Windows Registry Editor Version 5.00\r\n')
        out, err = self.run_block(1)
        self.assert_no_usosusb()
        self.assertIn('not a REGEDIT4 file', err)

    def test_wiring(self):
        self.assertIn('USB_STORAGE=${W9X_USB_STORAGE:-0}', TARGET)
        # after the helpers were copied and U9ENV.BAT exists, before the int13 decision
        self.assertLess(TARGET.index('for file in "$HELPERS"/*; do'), TARGET.index('uds_ok=0'))
        self.assertLess(TARGET.index('> "$work/c/USOS9X/U9ENV.BAT"'), TARGET.index('uds_ok=0'))
        self.assertLess(TARGET.index('uds_ok=0'), TARGET.index('int13_only=off'))
        self.assertIn('if [ "$nvme_ok" = 1 ] || [ "$uds_ok" = 1 ]; then', TARGET)
        # class instance: four digits, far above what the class installer hands out
        self.assertGreaterEqual(int(CLASSIDX), 50)


class Prepare(unittest.TestCase):
    def test_flag(self):
        gate = PREPARE[PREPARE.index('    usb9x=0\n'):]
        # default on, the opt-out file in the catalog category's Unattended folder
        self.assertIn('unattended="/mnt/data/Systems/$data_category/$folder/Unattended"', gate)
        off = gate.index('[ -f "$unattended/usb-storage-off.txt" ]')
        self.assertLess(off, gate.index('usb9x=1'))
        self.assertIn('else\n            usb9x=1', gate)
        self.assertNotIn('usb-storage-experimental.txt ]', gate)
        self.assertIn('[ -z "$img$posr$nt4$dos_iso" ]', gate[:gate.index('usb9x=1')])
        self.assertLess(gate.index('usb9x=1'), gate.index('W9X_USB_STORAGE="$usb9x"'))
        self.assertIn('3.1.2-usos17', gate[:gate.index('W9X_USB_STORAGE')])
        # set before any flow script is chosen, next to the NVMe flag
        self.assertLess(PREPARE.index('    nvme9x=0\n'), PREPARE.index('    usb9x=0\n'))
        self.assertIn('W9X_NVME_DRIVER="$nvme9x" W9X_USB_STORAGE="$usb9x"', PREPARE)
        self.assertEqual(PREPARE.count('W9X_USB_STORAGE'), 1)


class InstallBat(unittest.TestCase):
    def block(self, start, end):
        return BAT[BAT.index(start):BAT.index(end, BAT.index(start)) + len(end)]

    def test_autoexec_line(self):
        b = self.block('IF NOT "%U9UDS%"=="1" GOTO UDSAUTO', ':UDSAUTO')
        self.assertIn('IF "%U9SYS%"=="ME" GOTO UDSAUTO', b)
        self.assertIn(r'ECHO @IF EXIST C:\USOS9X\USBREG.BAT CALL C:\USOS9X\USBREG.BAT>>C:\AUTOEXEC.BAT', b)
        # in the CSMWrap AUTOEXEC.BAT, after it was created
        self.assertLess(BAT.index(':CSMAUTO'), BAT.index('GOTO UDSAUTO'))
        self.assertLess(BAT.index(r'GOTO USOSDRV>C:\AUTOEXEC.BAT'), BAT.index('GOTO UDSAUTO'))

    def test_me(self):
        b = self.block('IF NOT "%U9UDS%"=="1" GOTO MEUDS\n', ':MEUDS\n')
        self.assertIn(r'COPY /Y C:\USOS9X\USOSUSB.MPD C:\WINDOWS\SYSTEM\IOSUBSYS >NUL', b)
        self.assertLess(BAT.index('IF NOT "%U9SYS%"=="ME" GOTO CSMREG'), BAT.index('GOTO MEUDS\n'))
        # the RunOnce value only on Me and only with U9UDS=1 (95/98/98 SE: USBREG.BAT)
        ro = self.block('IF NOT "%U9SYS%"=="ME" GOTO UDSRO', ':UDSRO')
        self.assertIn('IF NOT "%U9UDS%"=="1" GOTO UDSRO', ro)
        self.assertIn('ECHO HKLM,%%USOSRO%%,USOSUsb,,"%%USOSUC%%">>', ro)
        tail = BAT[BAT.index(':LOGRO'):BAT.index(':AUTODONE')]
        self.assertIn(r'ECHO USOSUC="regedit /s C:\USOS9X\USOSUSB.REG">>C:\%U9SRC%\MSBATCH.INF', tail)

    def test_batch_rules(self):
        new = [l for l in BAT.splitlines() if 'U9UDS' in l or 'USOSUSB' in l or 'USBREG' in l]
        self.assertTrue(new)
        for line in new:
            self.assertLess(len(line), 128, line)
            if line.startswith('IF '):
                self.assertNotIn('>', line, line)
        self.assertNotIn('U9USB=1 GOTO', BAT)   # U9USB stays xhci98's


class Staging(unittest.TestCase):
    def setUp(self):
        sys.path.insert(0, str(ROOT / 'tools'))
        import build_win9x_support
        self.b = build_win9x_support
        self.tmp = Path(tempfile.mkdtemp(prefix='usos-usosusb-stage-'))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.src = self.tmp / 'usosusb9x'
        (self.src / 'bin/W9X').mkdir(parents=True)
        self.out = self.tmp / 'out'
        self.out.mkdir()

    def stand_in(self):
        mpd = bytearray(0x200)
        mpd[:2] = b'MZ'
        mpd[0x3c:0x40] = (0x80).to_bytes(4, 'little')
        mpd[0x80:0x84] = b'PE\0\0'
        mpd[0x100:0x10c] = b'SCSIPORT.SYS'
        (self.src / 'bin/W9X/usosusb.mpd').write_bytes(bytes(mpd))
        (self.src / 'usosusb.inf').write_bytes(b'[Version]\nSignature="$CHICAGO$"\n')
        (self.src / 'usosusb.reg').write_bytes(REG.replace('\r\n', '\n').encode('ascii'))
        return bytes(mpd)

    def test_lists(self):
        for name in ('USOSUSB.MPD', 'USOSUSB.INF', 'USOSUSB.REG'):
            self.assertIn(name, self.b.STAGED)
            self.assertNotIn(name, self.b.FILES)      # never on the Legacy Core RAM disk
        self.assertEqual(self.b.USOSUSB, ROOT / 'tools/nt/usosusb9x')
        go = (ROOT / 'installer/cmd/usos-payload-pack/main.go').read_text(encoding='utf-8')
        ps1 = (ROOT / 'tools/verify_release_consistency.ps1').read_text(encoding='utf-8-sig')
        for ext in ('MPD', 'INF', 'REG'):
            self.assertIn(f'{{`zig-out/dos-native/win9x/USOSUSB.{ext}`, `EFI/USOS/dos-native/win9x/USOSUSB.{ext}`}}', go)
            self.assertIn(f"'EFI/USOS/dos-native/win9x/USOSUSB.{ext}'", ps1)
        build = (ROOT / 'tools/build_win9x_support.py').read_text(encoding='utf-8')
        self.assertLess(build.index('    stage_usosnvme(out)\n'), build.index('    stage_usosusb(out)\n'))

    def test_stage(self):
        mpd = self.stand_in()
        self.b.stage_usosusb(self.out, self.src)
        self.assertEqual((self.out / 'USOSUSB.MPD').read_bytes(), mpd)
        self.assertEqual((self.out / 'USOSUSB.INF').read_bytes(), b'[Version]\r\nSignature="$CHICAGO$"\r\n')
        self.assertEqual((self.out / 'USOSUSB.REG').read_bytes(), REG.encode('ascii'))

    def test_missing_fails_clearly(self):
        with self.assertRaisesRegex(ValueError, 'USOSUSB miniport not built yet: missing bin/W9X/usosusb.mpd'):
            self.b.stage_usosusb(self.out, self.src)

    def test_bad_inputs(self):
        self.stand_in()
        (self.src / 'usosusb.reg').write_bytes(b'REGEDIT4\n\n[HKEY_LOCAL_MACHINE\\X]\n')
        with self.assertRaisesRegex(ValueError, '@CLASSIDX@'):
            self.b.stage_usosusb(self.out, self.src)
        self.stand_in()
        (self.src / 'bin/W9X/usosusb.mpd').write_bytes(b'MZ' + bytes(100))
        with self.assertRaisesRegex(ValueError, 'not a PE miniport'):
            self.b.stage_usosusb(self.out, self.src)
        self.assertFalse(list(self.out.iterdir()))


if __name__ == '__main__':
    unittest.main()
