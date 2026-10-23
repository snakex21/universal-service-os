"""FreeDOS network staging (tools/image_disk_target.sh freedos_net): the
MS-DOS flow's C:\\NET (USOSPKT.COM + mTCP, tools/build_dos_network.py) into
C:\\NET of the written FreeDOS FullUSB disk and one guarded call in
FDAUTO.BAT (once; before the installer check; CRLF kept).

Host only: Git sh, the function from the script, mtools replaced by a shim
that maps "::/x" of "disk@@offset" to a folder; no VM, no disk. The real
mtools run: tools/tests/run_custom_os_micro_linux_qemu.py (QEMU only,
docs/freedos-net-2026-10-23.md).
Run: python tools/tests/test_freedos_net.py
"""
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

from test_nt4_flow import function_text
from test_w9x_phase1_qemu import sh

ROOT = Path(__file__).resolve().parents[2]
TARGET = ROOT / 'tools/image_disk_target.sh'
sys.path.insert(0, str(ROOT / 'tools'))
import build_dos_network as net  # noqa: E402

CALL = 'if exist C:\\NET\\USOSPKT.COM call C:\\NET\\NETSTART.BAT'

# The lines of the FreeDOS 1.4 FullUSB FDAUTO.BAT around the insertion point.
FDAUTO = ('@echo off\r\nSET DOSDIR=\\FREEDOS\r\nSET PATH=%dosdir%\\BIN\r\n'
          'if exist %dosdir%\\bin\\fdnet.bat call %dosdir%\\bin\\fdnet.bat start\r\n'
          'if exist %dosdir%\\bin\\fdassist.bat call %dosdir%\\bin\\fdassist.bat\r\n\r\n'
          'if not exist SETUP.BAT goto Done\r\n:RunSetup\r\nCALL SETUP.BAT full\r\n\r\n'
          ':Done\r\nif exist %dosdir%\\bin\\welcome.bat call %dosdir%\\bin\\welcome.bat\r\n')

# mtools shim: "-i disk@@offset" -> $FAKEFAT, "::/x" -> $FAKEFAT/x.
SHIM = r'''#!/bin/sh
cmd=${0##*/}
args=
while [ $# -gt 0 ]; do
    case "$1" in
        -i) shift ;;
        -o|-n) ;;
        *) args="$args
$1" ;;
    esac
    shift
done
map() { case "$1" in ::*) printf '%s%s' "$FAKEFAT" "${1#::}" ;; *) printf '%s' "$1" ;; esac; }
set -f; IFS='
'; set -- $args; IFS=' '
echo "$cmd $*" >> "$FAKELOG"
case "$cmd" in
    mdir) [ -e "$(map "$1")" ] ;;
    mmd) [ -n "$FAKE_MMD_FAIL" ] && exit 1; mkdir "$(map "$1")" ;;
    mcopy) cp "$(map "$1")" "$(map "$2")" ;;
esac
'''


def msys(path: Path) -> str:
    # PATH entry for Git sh: "C:/x" would split at the drive colon.
    p = path.resolve().as_posix()
    return '/' + p[0].lower() + p[2:] if p[1:2] == ':' else p


class FreeDosNet(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='usos-fdnet-'))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.fat = self.tmp / 'fat'
        self.fat.mkdir()
        (self.fat / 'FDAUTO.BAT').write_bytes(FDAUTO.encode('ascii'))
        self.src = self.tmp / 'msdos'
        self.src.mkdir()
        for name in net.NET_FILES:
            (self.src / name).write_bytes(b'USOS ' + name.encode() + b'\r\n')
        self.bin = self.tmp / 'bin'
        self.bin.mkdir()
        for name in ('mdir', 'mmd', 'mcopy'):
            (self.bin / name).write_text(SHIM, newline='\n')
            (self.bin / name).chmod(0o755)
        (self.tmp / 'work').mkdir()

    def run_net(self, extra=''):
        lines = TARGET.read_text(encoding='utf-8').splitlines()
        assigns = '\n'.join(l for l in lines if l.startswith(('DOS_NET_DIR=', 'DOS_NET_FILES=', 'DOS_NET_CALL=')))
        script = (f'log() {{ printf "[IMAGE_DISK] %s\\n" "$*"; }}\n'
                  f'fail() {{ printf "STOP: %s\\n" "$1"; exit 1; }}\n'
                  f'PATH="{msys(self.bin)}:$PATH"; FAKEFAT="{self.fat.as_posix()}"; '
                  f'FAKELOG="{(self.tmp / "log").as_posix()}"; export FAKEFAT FAKELOG\n'
                  f'USOS_DOS_NET_DIR="{self.src.as_posix()}"; work="{(self.tmp / "work").as_posix()}"\n{extra}\n'
                  f'{assigns}\n{function_text(TARGET, "freedos_net")}\nfreedos_net /dev/sdz@@32256')
        return sh(script)

    def auto(self):
        return (self.fat / 'FDAUTO.BAT').read_bytes().decode('ascii')

    def test_files_and_call(self):
        rc, out, err = self.run_net()
        self.assertEqual(rc, 0, out + err)
        self.assertIn('read-back PASS', out)
        for name in net.NET_FILES:
            self.assertEqual((self.fat / 'NET' / name).read_bytes(), (self.src / name).read_bytes(), name)
        text = self.auto()
        self.assertEqual(text.count(CALL), 1)
        # after the FDNET line, before the installer check and the welcome text
        self.assertLess(text.index('fdnet.bat start'), text.index(CALL))
        self.assertLess(text.index(CALL), text.index('if not exist SETUP.BAT goto Done'))
        self.assertIn(CALL + '\r\nif not exist SETUP.BAT', text)
        self.assertNotIn('\n', text.replace('\r\n', ''))      # CRLF only
        self.assertEqual(text.replace('rem USOS network: C:\\NET\\NETSTART.BAT (USOSPKT + mTCP DHCP)\r\n' + CALL + '\r\n', ''), FDAUTO)

    def test_second_run_adds_nothing(self):
        self.assertEqual(self.run_net()[0], 0)
        first = self.auto()
        rc, out, err = self.run_net()
        self.assertEqual(rc, 0, out + err)
        self.assertIn('already calls NETSTART.BAT', out)
        self.assertEqual(self.auto(), first)

    def test_no_installer_check_appends(self):
        (self.fat / 'FDAUTO.BAT').write_bytes(b'@echo off\r\nSET DOSDIR=\\FREEDOS\r\n')
        self.assertEqual(self.run_net()[0], 0)
        self.assertTrue(self.auto().endswith(CALL + '\r\n'))

    def test_missing_file_skips_without_change(self):
        (self.src / 'HTGET.EXE').unlink()
        rc, out, err = self.run_net()
        self.assertEqual(rc, 0, out + err)
        self.assertIn('HTGET.EXE missing', out)
        self.assertFalse((self.fat / 'NET').exists())
        self.assertEqual(self.auto(), FDAUTO)

    def test_mkdir_failure_stops(self):
        rc, out, err = self.run_net('FAKE_MMD_FAIL=1; export FAKE_MMD_FAIL')
        self.assertEqual(rc, 1)
        self.assertIn('STOP: FreeDOS: cannot create C:\\NET', out)
        self.assertEqual(self.auto(), FDAUTO)

    def test_lists_match_the_ms_dos_flow(self):
        text = TARGET.read_text(encoding='utf-8')
        files = next(l for l in text.splitlines() if l.startswith('DOS_NET_FILES='))
        self.assertEqual(files.split('=', 1)[1].strip("'").split(), list(net.NET_FILES))
        self.assertIn("DOS_NET_CALL='%s'" % CALL, text)
        self.assertLessEqual(len(CALL), 127)
        # the files come from the stick's MS-DOS helper folder (payload list)
        self.assertIn('/mnt/esp/EFI/USOS/dos-native/msdos', text)
        # staged after the installer switch, inside freedos_fix
        fix = function_text(TARGET, 'freedos_fix')
        self.assertLess(fix.index('SETUP.OFF'), fix.index('freedos_net "$part"'))

    def test_netstart_uses_c_net(self):
        start = (ROOT / 'src/platform/bios/msdos/network_start.cmd').read_text(encoding='ascii')
        self.assertIn('set MTCPCFG=C:\\NET\\MTCP.CFG', start)
        self.assertIn('if errorlevel 1 goto no_driver', start)


if __name__ == '__main__':
    unittest.main()
