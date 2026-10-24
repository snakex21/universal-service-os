"""Host test: the opt-in Winsock for Windows 3.1 / 3.11 / WfW 3.11 installs.

Copyright (C) 2026 Maksymilian and the USOS Authors
SPDX-License-Identifier: GPL-3.0-or-later

Answer profile dos_winsock -> DOS.INI winsock=yes (src/flow/answer/dos.zig)
-> tools/dos_win3_menu.sh dos_winsock_apply, called by dos_csmwrap_target.sh.

OFF (no DOS.INI, no winsock line, winsock=no): every file the installer
stages (C:\\USOSDOS helpers: W3AUTO, WINMENU, NETSTART, SETUP.INF) and the
target root stay byte-identical, and the default network start file is the
X470-proven one. ON: C:\\NET\\WIN16, USOSPKTQ.COM, the queue NETSTART, the
USOSPKT_QUEUE line before the NETSTART call, WINSOCK.DLL into C:\\WINDOWS
after Setup (only when none is there) and the Program Manager group.
"""
from __future__ import annotations

import hashlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MSDOS = ROOT / 'src/platform/bios/msdos'
LIB = ROOT / 'tools/dos_win3_menu.sh'
SH = shutil.which('sh') or shutil.which('bash')
# src/platform/bios/msdos/network_start.cmd as built into B261023-230446
# (668ca641, X470-proven default NETSTART.BAT), LF text.
DEFAULT_NETSTART_SHA256 = '45de6ce11a71be7d911fa61049605ca58b55e5ab84095e1955993f331d75e55a'
PAYLOAD = ('WINSOCK.DLL', 'GETHTTP.EXE', 'TESTLOAD.EXE', 'USOSPKTQ.COM', 'NETSTART.BAT', 'WINSOCK.TXT')

SETUP_INF = (
    '[setup]\r\n    help = setup.hlp\r\n\r\n'
    '[progman.groups]\r\ngroup3=Grupa g\u0088¢wna,1\r\ngroup4=Accessories\r\ngroup5=Games\r\ngroup1=StartUp\r\n\r\n'
    '[group3]\r\n"File Manager",     WINFILE.EXE\r\n\r\n'
    '[dosdisk]\r\nnumber=8:country.sys\r\n\r\n'
).encode('latin-1')  # CP852 bytes as in the Polish SETUP.INF


def crlf(name: str) -> bytes:
    return (MSDOS / name).read_text(encoding='ascii').replace('\r\n', '\n').replace('\n', '\r\n').encode('ascii')


def lf(data: bytes) -> bytes:
    # BusyBox awk (micro-Linux) keeps the CR of each line; MSYS awk on a
    # Windows host may drop it, so edited files compare as LF.
    return data.replace(b'\r\n', b'\n')


def tree(path: Path) -> dict[str, str]:
    return {p.relative_to(path).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(path.rglob('*')) if p.is_file()}


@unittest.skipIf(SH is None, 'no POSIX shell on this host')
class WinsockApply(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='usos-ws-'))
        self.u = self.tmp / 'c/USOSDOS'
        self.c = self.tmp / 'c'
        self.src = self.tmp / 'winsock16'
        (self.u / 'WINSETUP').mkdir(parents=True)
        self.src.mkdir()
        (self.u / 'W3AUTO.BAT').write_bytes(crlf('windows_auto.cmd'))
        (self.u / 'W3AUTO.CSM').write_bytes(crlf('windows_auto.cmd'))
        (self.u / 'WINMENU.BAT').write_bytes(crlf('windows_menu.cmd'))
        (self.u / 'NETSTART.BAT').write_bytes(crlf('network_start.cmd'))
        (self.u / 'INSTALL.BAT').write_bytes(crlf('install.cmd'))
        (self.u / 'WINSETUP/SETUP.INF').write_bytes(SETUP_INF)
        for name in PAYLOAD:
            (self.src / name).write_bytes(b'payload ' + name.encode())
        (self.src / 'NETSTART.BAT').write_bytes(crlf('network_start_queue.cmd'))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_apply(self, ini: bytes | None) -> subprocess.CompletedProcess:
        path = self.tmp / 'DOS.INI'
        if ini is not None:
            path.write_bytes(ini)
        script = f'. "{LIB.as_posix()}"; dos_winsock_apply "$1" "$2" "$3" "$4"'
        return subprocess.run([SH, '-c', script, 'sh', self.u.as_posix(), path.as_posix(),
                               self.src.as_posix(), self.c.as_posix()],
                              capture_output=True, text=True, timeout=60)

    def test_off_is_byte_identical(self):
        before = tree(self.c)
        head = b'; USOS MS-DOS / Windows 1.x-3.x regional settings (src/flow/answer/dos.zig)\r\n[dos]\r\n'
        for ini in (None, head + b'mode=auto\r\ncountry=048\r\ncodepage=852\r\ncpi=EGA.CPI\r\n',
                    head + b'mode=manual\r\n', head + b'mode=auto\r\nwinsock=no\r\n'):
            r = self.run_apply(ini)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(r.stdout, '')
            after = tree(self.c)
            after.pop('USOSDOS/../DOS.INI', None)
            self.assertEqual(before, after, ini)
            self.assertFalse((self.c / 'NET').exists())

    def test_on_stages_everything(self):
        r = self.run_apply(b'[dos]\r\nmode=auto\r\nwinsock=yes\r\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('Winsock (experimental)', r.stdout)
        self.assertIn('icon "USOS Winsock test (GETHTTP)" in the Main group (group3)', r.stdout)
        net = self.c / 'NET'
        for name in ('WINSOCK.DLL', 'GETHTTP.EXE', 'TESTLOAD.EXE', 'WINSOCK.TXT'):
            self.assertEqual((net / 'WIN16' / name).read_bytes(), (self.src / name).read_bytes(), name)
        self.assertTrue((net / 'WIN16/STAGE.LOG').read_bytes().endswith(b'\r\n'))
        self.assertEqual((net / 'USOSPKTQ.COM').read_bytes(), b'payload USOSPKTQ.COM')
        self.assertFalse((net / 'WINSOCK.DLL').exists())
        # INSTALL.BAT copies C:\USOSDOS\NETSTART.BAT to C:\NET: the queue one.
        self.assertEqual((self.u / 'NETSTART.BAT').read_bytes(), crlf('network_start_queue.cmd'))
        for name in ('W3AUTO.BAT', 'W3AUTO.CSM'):
            lines = lf((self.u / name).read_bytes()).decode('ascii').split('\n')
            call = lines.index('if exist C:\\NET\\NETSTART.BAT call C:\\NET\\NETSTART.BAT')
            self.assertEqual(lines[call - 1], 'set USOSPKT_QUEUE=1', name)
            self.assertEqual(lines.count('set USOSPKT_QUEUE=1'), 1)
            # Nothing else changed.
            del lines[call - 1]
            self.assertEqual('\n'.join(lines).encode('ascii'), lf(crlf('windows_auto.cmd')))
        menu = lf((self.u / 'WINMENU.BAT').read_bytes()).decode('ascii').split('\n')
        at = menu.index(':ini_done')
        self.assertEqual(menu[at + 1:at + 4], [
            'if exist C:\\WINDOWS\\WINSOCK.DLL echo WINSOCK.DLL: C:\\WINDOWS has one already, kept>>C:\\NET\\WIN16\\STAGE.LOG',
            'if not exist C:\\WINDOWS\\WINSOCK.DLL echo WINSOCK.DLL: copied to C:\\WINDOWS>>C:\\NET\\WIN16\\STAGE.LOG',
            'if not exist C:\\WINDOWS\\WINSOCK.DLL copy C:\\NET\\WIN16\\WINSOCK.DLL C:\\WINDOWS >nul'])
        for line in menu:
            self.assertLessEqual(len(line), 127)
        del menu[at + 1:at + 4]
        self.assertEqual('\n'.join(menu).encode('ascii'), lf(crlf('windows_menu.cmd')))
        inf = lf((self.u / 'WINSETUP/SETUP.INF').read_bytes()).decode('latin-1')
        # Setup ignores new groups: the icon goes into the Main group (",1",
        # a CP852 name in the Polish INF).
        self.assertIn('[progman.groups]\ngroup3=Grupa\u00a0g\u0088\u00a2wna,1\n', inf)
        self.assertIn('[group3]\n"USOS Winsock test (GETHTTP)", C:\\NET\\WIN16\\GETHTTP.EXE\n"File Manager",', inf)
        self.assertEqual(inf.count('GETHTTP.EXE'), 1)
        self.assertEqual(inf.replace('"USOS Winsock test (GETHTTP)", C:\\NET\\WIN16\\GETHTTP.EXE\n', ''),
                         lf(SETUP_INF).decode('latin-1'))
        # INSTALL.BAT itself is never edited.
        self.assertEqual((self.u / 'INSTALL.BAT').read_bytes(), crlf('install.cmd'))

    def test_on_without_files_fails_cleanly(self):
        (self.src / 'USOSPKTQ.COM').unlink()
        r = self.run_apply(b'[dos]\r\nwinsock=yes\r\n')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('missing USOSPKTQ.COM', r.stderr)
        self.assertFalse((self.c / 'NET').exists())
        self.assertEqual((self.u / 'NETSTART.BAT').read_bytes(), crlf('network_start.cmd'))

    def test_on_setup_inf_without_groups(self):
        (self.u / 'WINSETUP/SETUP.INF').write_bytes(b'[setup]\r\n')
        r = self.run_apply(b'[dos]\r\nwinsock=yes\r\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('File > Run C:\\NET\\WIN16\\GETHTTP.EXE', r.stdout)
        self.assertEqual((self.u / 'WINSETUP/SETUP.INF').read_bytes(), b'[setup]\r\n')


class Wiring(unittest.TestCase):
    def test_default_netstart_unchanged(self):
        data = (MSDOS / 'network_start.cmd').read_bytes().replace(b'\r\n', b'\n')
        self.assertEqual(hashlib.sha256(data).hexdigest(), DEFAULT_NETSTART_SHA256)
        self.assertNotIn(b'USOSPKTQ', data)
        queue = (MSDOS / 'network_start_queue.cmd').read_text(encoding='ascii')
        self.assertIn('if "%USOSPKT_QUEUE%"=="1" goto queue_driver', queue)
        self.assertIn('C:\\NET\\USOSPKTQ.COM /Q 0x60 >C:\\NET\\USOSPKT.LOG', queue)
        self.assertIn('C:\\NET\\USOSPKT.COM 0x60 >C:\\NET\\USOSPKT.LOG', queue)

    def test_target_calls_only_for_win31_family(self):
        target = (ROOT / 'tools/dos_csmwrap_target.sh').read_text(encoding='ascii')
        self.assertIn('if [ -z "$WIN_EARLY" ] && [ -n "$REGIONAL" ]; then', target)
        self.assertIn('dos_winsock_apply "$U" "$REGIONAL" "$ESP_DIR/dos-native/winsock16" "$work/c"', target)
        # After WINSETUP is copied (SETUP.INF), before the target is unmounted.
        self.assertLess(target.index("log 'Windows 3.x Setup files copied'"), target.index('dos_winsock_apply'))
        self.assertLess(target.index('dos_winsock_apply'), target.index('umount "$work/c" || fail'))

    def test_payload_folder_separate(self):
        import sys
        sys.path.insert(0, str(ROOT / 'tools'))
        from build_dos_network import NET_FILES
        from build_win16_winsock import PAYLOAD_FILES
        self.assertEqual(PAYLOAD_FILES, PAYLOAD)
        self.assertNotIn('USOSPKTQ.COM', NET_FILES)
        pack = (ROOT / 'installer/cmd/usos-payload-pack/main.go').read_text(encoding='utf-8')
        for name in PAYLOAD:
            self.assertIn(f'{{`zig-out/dos-native/winsock16/{name}`, `EFI/USOS/dos-native/winsock16/{name}`}}', pack)
        self.assertNotIn('dos-native/msdos/USOSPKTQ', pack)
        self.assertNotIn('dos-native/msdos/WINSOCK', pack)
        native = (ROOT / 'tools/build_dos_native_support.py').read_text(encoding='utf-8')
        self.assertIn("build_winsock16(root, out / 'winsock16')", native)

    def test_gethttp_logs_under_net(self):
        src = (ROOT / 'src/platform/bios/win16/winsock16/gethttp.c').read_text(encoding='ascii')
        self.assertIn('_lcreat("C:\\\\NET\\\\WIN16\\\\GETHTTP.LOG", 0)', src)
        self.assertIn('_lcreat("C:\\\\NET\\\\WIN16\\\\GETHTTP.RSP", 0)', src)
        self.assertNotIn('"C:\\\\GETHTTP', src)
        self.assertIn('_fstrstr(cmdline, "/EXIT")', src)

    def test_profile_option_wiring(self):
        dos = (ROOT / 'src/flow/answer/dos.zig').read_text(encoding='utf-8')
        self.assertIn('if (p.dos_winsock) try w.writeAll("winsock=yes\\r\\n");', dos)
        editor = (ROOT / 'src/platform/uefi/profile_editor.zig').read_text(encoding='utf-8')
        self.assertIn('if (answer.dos.winsockCapable(system_id)) addField(.dos_winsock', editor)
        import json
        locales = sorted((ROOT / 'installer/internal/i18n/locales').glob('*.json'))
        self.assertEqual(len(locales), 27)
        for f in locales:
            data = json.loads(f.read_text(encoding='utf-8'))
            self.assertIn('Winsock', data['boot.profile.field.dos_winsock'], f.name)
            self.assertIn('GETHTTP', data['boot.profile.help.dos_winsock'], f.name)
        self.assertEqual(json.loads((ROOT / 'installer/internal/i18n/locales/pl.json').read_text(encoding='utf-8'))
                         ['boot.profile.field.dos_winsock'], 'Winsock (eksperymentalny)')


if __name__ == '__main__':
    unittest.main()
