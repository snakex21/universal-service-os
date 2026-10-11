"""The USOS stick ESP stays read-only during long phases (tools/stick_write.sh).

X470 2026-10-11 (B261011-151241): a POSReady install ended by a power-off
after 1 h (micro-Linux still in the VM loop) left the stick ESP's FAT32 dirty
flag set. Linux vfat keeps the flag while the volume is mounted read-write;
micro-Linux kept /mnt/esp read-write for the whole VM loop. Now the 9x / NT3
/ NT4 / POSReady / Custom OS flow remounts it read-only before the disk picker,
logs go to tmpfs and reach the ESP in short read-write windows only.
"""
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / 'tools'
LIB = TOOLS / 'stick_write.sh'
SH = shutil.which('sh') or r'C:\Program Files\Git\usr\bin\sh.exe'


def code_lines(path):
    for number, line in enumerate(path.read_text(encoding='utf-8', errors='replace').splitlines(), 1):
        yield number, line.split('#', 1)[0] if not line.lstrip().startswith('#') else ''


class StickWriteStatic(unittest.TestCase):
    def test_no_long_lived_rw_mount_of_the_stick(self):
        # remount,rw only inside the helper, which always pairs it with a
        # remount back to ro; the one rw mount of /mnt/esp is init's.
        offenders = []
        for path in TOOLS.rglob('*.sh'):
            rel = path.relative_to(ROOT).as_posix()
            if rel.startswith(('tools/vendor/', 'tools/tests/', 'tools/cache/')) or path == LIB:
                continue
            for number, code in code_lines(path):
                if re.search(r'remount\s*,\s*rw|-o\s+rw\b.*remount', code):
                    offenders.append(f'{rel}:{number}: {code.strip()}')
                if re.search(r'\bmount\b.*-o\s+rw\b', code) and '/mnt/esp' in code and rel != 'tools/micro_linux_init.sh':
                    offenders.append(f'{rel}:{number}: {code.strip()}')
        self.assertEqual(offenders, [])
        lib = LIB.read_text(encoding='utf-8')
        body = lib[lib.index('usos_stick_write() {'):]
        self.assertLess(body.index('usos_stick_rw'), body.index('"$@"'))
        self.assertLess(body.index('"$@"'), body.index('usos_stick_ro'))

    def test_w9x_flow_keeps_the_esp_read_only(self):
        text = (TOOLS / 'w9x_csmwrap_prepare.sh').read_text(encoding='utf-8')
        prepare = text[text.index('usos_w9x_csmwrap_prepare() {'):]
        ro = prepare.index('usos_stick_ro ||')
        for later in ('usos_xp_choose_disk', 'posready_vm_install', 'nt4_vm_install', 'w9x_phase1_run', 'usos_ui_notice_continue'):
            self.assertLess(ro, prepare.index(later), later)
        # After the remount: no direct write onto the ESP, only through
        # usos_stick_write (W9X_LOG is the tmpfs copy).
        offenders = []
        for line in prepare[ro:].splitlines():
            code = line.split('#', 1)[0]
            if 'usos_stick_write' in code:
                continue
            if re.search(r'(>>?|\bcp\b|\bmv\b|\brm\b|\bmkdir\b|\btouch\b)[^|;]*("\$W9X_DIR|/mnt/esp|\$request)', code):
                offenders.append(code.strip())
            for d in ('posready', 'nt4', 'phase1'):
                if f'"$W9X_DIR/{d}"' in code:
                    offenders.append(code.strip())
        self.assertEqual(offenders, [])
        self.assertIn('W9X_LOG=/run/', prepare)

    def test_flush_points(self):
        init = (TOOLS / 'micro_linux_init.sh').read_text(encoding='utf-8')
        stop = init[init.index('stop() {'):init.index('exec /bin/sh')]
        self.assertLess(stop.index('usos_stick_flush'), stop.index('stick_release.sh ro'))
        keep = (TOOLS / 'w9x_phase1_qemu.sh').read_text(encoding='utf-8')
        keep = keep[keep.index('w9x_phase1_keep_logs() {'):]
        self.assertIn('usos_stick_flush', keep[:keep.index('\n}')])
        posr = (TOOLS / 'posready_qemu_install.sh').read_text(encoding='utf-8')
        live = posr[posr.index('mkdir -p "$logs/live"'):posr.index('return 0', posr.index('mkdir -p "$logs/live"'))]
        self.assertIn('usos_stick_flush', live)

    def test_menu_waits_read_only(self):
        menu = (TOOLS / 'xp_menu_ui.sh').read_text(encoding='utf-8')
        fb = menu.index('"$USOS_FB_UI" --menu')
        self.assertLess(menu.index('usos_stick_ro'), fb)
        self.assertGreater(menu.index('usos_stick_rw'), fb)
        vista = (TOOLS / 'vista_csmwrap_prepare.sh').read_text(encoding='utf-8')
        self.assertLess(vista.index('stick_release.sh ro'), vista.index('read -r _vista_ack'))

    def test_packed_into_initramfs(self):
        self.assertIn('("tools/stick_write.sh", "usr/lib/usos/stick_write.sh")',
                      (TOOLS / 'build_micro_linux.py').read_text(encoding='utf-8'))


STUB_MOUNT = r'''#!/bin/sh
# fake mount: "mount -o remount,MODE MP" rewrites MODE of MP in $FAKE_MOUNTS
echo "mount $*" >> "$FAKE_LOG"
[ "$1" = -o ] || exit 1
mode=${2#remount,}
awk -v mp="$3" -v mode="$mode" '$2 == mp { sub(/^r[ow]/, mode, $4) } { print }' "$FAKE_MOUNTS" > "$FAKE_MOUNTS.new" && mv "$FAKE_MOUNTS.new" "$FAKE_MOUNTS"
'''


class StickWriteBehaviour(unittest.TestCase):
    def run_sh(self, mode, script):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / 'bin').mkdir()
            stub = tmp / 'bin' / 'mount'
            stub.write_text(STUB_MOUNT, encoding='ascii', newline='\n')
            stub.chmod(0o755)
            for name in ('sync',):
                s = tmp / 'bin' / name
                s.write_text('#!/bin/sh\nexit 0\n', encoding='ascii', newline='\n')
                s.chmod(0o755)
            mounts = tmp / 'mounts'
            mounts.write_text(f'/dev/sdb1 /mnt/esp vfat {mode},noatime 0 0\n', encoding='ascii', newline='\n')
            log = tmp / 'log'
            log.write_text('', encoding='ascii')
            env = dict(os.environ, FAKE_MOUNTS=mounts.as_posix(), FAKE_LOG=log.as_posix(),
                       USOS_STICK_PROC_MOUNTS=mounts.as_posix(),
                       PATH=(tmp / 'bin').as_posix() + os.pathsep + os.environ.get('PATH', ''))
            full = f'. "{LIB.as_posix()}"\n{script}\n'
            out = subprocess.run([SH, '-c', full], capture_output=True, text=True, env=env, timeout=60)
            calls = [line for line in log.read_text(encoding='ascii').splitlines() if line]
            return out, calls, mounts.read_text(encoding='ascii')

    def test_write_from_read_only_is_a_short_rw_window(self):
        out, calls, mounts = self.run_sh('ro', 'usos_stick_write sh -c "echo inside \\$(usos_stick_mode 2>/dev/null)"; echo rc=$?; usos_stick_mode')
        self.assertEqual(calls, ['mount -o remount,rw /mnt/esp', 'mount -o remount,ro /mnt/esp'], out.stderr)
        self.assertIn('rc=0', out.stdout)
        self.assertTrue(out.stdout.strip().endswith('ro'))
        self.assertIn(' ro,noatime', mounts)

    def test_write_keeps_rw_when_it_was_rw(self):
        out, calls, _ = self.run_sh('rw', 'usos_stick_write true; usos_stick_mode')
        self.assertEqual(calls, [])
        self.assertTrue(out.stdout.strip().endswith('rw'))

    def test_write_returns_the_command_status_and_still_goes_back_ro(self):
        out, calls, _ = self.run_sh('ro', 'usos_stick_write false; echo rc=$?; usos_stick_mode')
        self.assertIn('rc=1', out.stdout)
        self.assertEqual(calls[-1], 'mount -o remount,ro /mnt/esp')
        self.assertTrue(out.stdout.strip().endswith('ro'))

    def test_ro_then_rw(self):
        out, calls, _ = self.run_sh('rw', 'usos_stick_ro; usos_stick_mode; usos_stick_ro; usos_stick_rw; usos_stick_mode')
        self.assertEqual(out.stdout.split(), ['ro', 'rw'])
        self.assertEqual(calls, ['mount -o remount,ro /mnt/esp', 'mount -o remount,rw /mnt/esp'])


if __name__ == '__main__':
    unittest.main()
