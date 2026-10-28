"""Windows 98 / 98 SE / Me Setup phase 1 in a VM (tools/w9x_phase1_qemu.sh, the VM parts
of tools/w9x_csmwrap_target.sh and INSTALL.BAT). Host only: Git sh, a fake
qemu-system-i386 script, temp folders; no VM, no disk.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
LIB = (ROOT / 'tools/w9x_phase1_qemu.sh').as_posix()
TARGET = ROOT / 'tools/w9x_csmwrap_target.sh'


def scratch(prefix):
    parent = (ROOT / 'zig-out/w9x-phase1-tests').resolve()
    parent.mkdir(parents=True, exist_ok=True)
    folder = Path(tempfile.mkdtemp(prefix=prefix, dir=parent)).resolve()
    assert folder.is_relative_to(parent)
    return folder


def shell():
    for candidate in ('C:/Program Files/Git/bin/sh.exe', 'C:/Program Files/Git/bin/bash.exe'):
        if os.path.exists(candidate):
            return candidate
    found = shutil.which('sh')
    if not found:
        raise unittest.SkipTest('no POSIX sh available')
    return found


def sh(script, env=None):
    # The script goes in a file, not as "-c script": Windows argv quoting
    # (CreateProcess -> MSYS) mangles embedded quotes and backslashes of a
    # long multi-line block ("unexpected EOF while looking for matching").
    # Not on stdin either: a command in the script may read stdin.
    fd, name = tempfile.mkstemp(prefix='usos-sh-', suffix='.sh')
    try:
        with os.fdopen(fd, 'w', encoding='utf-8', newline='\n') as f:
            f.write(script)
        result = subprocess.run([shell(), Path(name).as_posix()], capture_output=True, text=True,
                                stdin=subprocess.DEVNULL, env=dict(os.environ, **(env or {})))
    finally:
        os.unlink(name)
    return result.returncode, result.stdout, result.stderr


class Phase1Vm(unittest.TestCase):
    def setUp(self):
        self.tmp = scratch('usos-w9x-vm-')
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        (self.tmp / 'share').mkdir()
        (self.tmp / 'share/keymaps').mkdir()
        (self.tmp / 'share/keymaps/en-us').write_bytes(b'# fake QEMU test input only\n')
        for name in ('bios-256k.bin', 'vgabios-stdvga.bin'):
            (self.tmp / 'share' / name).write_bytes(b'x')
        (self.tmp / 'flags').mkdir()
        self.qemu = self.tmp / 'qemu-system-i386'
        self.qemu.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$W9X_FAKE_ARGS"\nsleep "${W9X_FAKE_SLEEP:-0}"\nexit "${W9X_FAKE_RC:-0}"\n', newline='\n')
        self.qemu.chmod(0o755)
        self.meminfo = self.tmp / 'meminfo'
        self.meminfo.write_text('MemTotal:       16336004 kB\nMemFree: 1 kB\n', newline='\n')
        self.page_helper = self.tmp / 'page-helper'
        self.page_helper.write_text('#!/bin/sh\necho unknown\n', newline='\n')
        self.page_helper.chmod(0o755)
        self.event_helper = self.tmp / 'event-helper'
        self.event_helper.write_text('#!/bin/sh\necho ready\nif [ "${W9X_FAKE_PAGE:-}" = coa ]; then echo "page coa"; fi\nsleep 60\n', newline='\n')
        self.event_helper.chmod(0o755)

    def env(self, **extra):
        env = {
            'W9X_VM_QEMU': self.qemu.as_posix(), 'W9X_VM_DATADIR': (self.tmp / 'share').as_posix(),
            'W9X_VM_MEMINFO': self.meminfo.as_posix(), 'W9X_VM_FLAGS': (self.tmp / 'flags').as_posix(),
            'W9X_VM_RUN': (self.tmp / 'run').as_posix(), 'W9X_VM_KVM_DEV': (self.tmp / 'nokvm').as_posix(),
            'W9X_FAKE_ARGS': (self.tmp / 'args.txt').as_posix(),
            'W9X_VM_95_LIB': (ROOT / 'tools/w9x_95_ui.sh').as_posix(),
            'W9X_VM_95_HELPER': self.page_helper.as_posix(),
            'W9X_VM_95_EVENT_LIB': (ROOT / 'tools/w9x_95_event_wait.sh').as_posix(),
            'W9X_VM_95_EVENTS': self.event_helper.as_posix(),
        }
        env.update(extra)
        return env

    def run_lib(self, body, **extra):
        return sh(f'. "{LIB}"\n{body}', self.env(**extra))

    def test_only_9x_with_qemu_ram_and_no_opt_out(self):
        for tag in ('98SE', '98', 'ME', '95'):
            rc, out, _ = self.run_lib(f'w9x_vm_available {tag}')
            self.assertEqual(rc, 0, out)
        for tag in ('DOS', 'W3'):
            self.assertNotEqual(self.run_lib(f'w9x_vm_available {tag}')[0], 0, tag)
        self.assertNotEqual(self.run_lib('w9x_vm_available 98SE', W9X_VM_QEMU=(self.tmp / 'none').as_posix())[0], 0)
        self.meminfo.write_text('MemTotal:       786432 kB\n', newline='\n')
        rc, out, _ = self.run_lib('w9x_vm_available 98SE')
        self.assertNotEqual(rc, 0)
        self.assertIn('RAM', out)
        self.meminfo.write_text('MemTotal:       16336004 kB\n', newline='\n')
        (self.tmp / 'flags/phase1-native.flag').write_bytes(b'')
        for tag in ('98SE', '98', 'ME', '95'):
            self.assertNotEqual(self.run_lib(f'w9x_vm_available {tag}')[0], 0, tag)
        # The 9x native flag never blocks the NT / POSReady VM installs.
        for tag in ('NT4', 'NT4S', 'NT4T', 'NT351', 'NT351S', 'NT35', 'NT35S', 'NT31', 'NT31S', 'POSR'):
            rc, out, _ = self.run_lib(f'w9x_vm_available {tag}')
            self.assertEqual(rc, 0, f'{tag}: {out}')
        (self.tmp / 'flags/phase1-native.flag').unlink()
        (self.tmp / 'share/vgabios-stdvga.bin').unlink()
        self.assertNotEqual(self.run_lib('w9x_vm_available 98SE')[0], 0)

    def test_windows_95_key_digits_from_the_answer(self):
        inf = self.tmp / 'MSBATCH.INF'
        cases = {
            b'[Setup]\r\nExpress=1\r\nProductID="12345-oem-0012345-12345"\r\n[NameAndOrg]\r\n': '12345001234512345',
            b'[Setup]\r\nProductID=123-4567890\r\n': '1234567890',
            b'[Setup]\r\nProductKey="ABCDE-12345-FGHIJ-67890-KLMNO"\r\n': None,
            b'[Setup]\r\nExpress=1\r\n[Other]\r\nProductID="12345-OEM-0012345-12345"\r\n': None,
            b'[Setup]\r\nProductID="12345-OEM-001234-12345"\r\n': None,
            b'[Setup]\r\nProductID="12345-OEM-0012345-12345;rm"\r\n': None,
        }
        for text, digits in cases.items():
            inf.write_bytes(text)
            rc, out, _ = self.run_lib(f'w9x_vm_key_digits "{inf.as_posix()}"')
            if digits is None:
                self.assertNotEqual(rc, 0, text)
                self.assertEqual(out, '', text)
            else:
                self.assertEqual((rc, out.strip()), (0, digits), text)

    def test_missing_95_classifier_stops_before_qemu_starts(self):
        if self.run_lib('command -v mkfifo')[0] != 0:
            self.skipTest('no mkfifo in this sh')
        rc, out, err = self.run_lib('w9x_phase1_run /dev/fake tcg; echo "rc=$?"',
            W9X_VM_KEY='98765001234554321', W9X_VM_95_SETUP950='1', W9X_VM_95_EVENTS=(self.tmp / 'absent').as_posix())
        self.assertIn('rc=2', out, err)
        self.assertFalse((self.tmp / 'args.txt').exists())
        self.assertFalse((self.tmp / 'run/command.txt').exists())

    def test_missing_95_keymap_stops_before_qemu_starts(self):
        (self.tmp / 'share/keymaps/en-us').unlink()
        rc,out,err=self.run_lib('w9x_phase1_run /dev/fake tcg; echo "rc=$?"',W9X_VM_KEY='98765001234554321',W9X_VM_95_SETUP950='1')
        self.assertIn('rc=2',out,err)
        self.assertFalse((self.tmp/'args.txt').exists())
        self.assertIn('keymap missing',(self.tmp/'run/event-errors.log').read_text())

    def test_unsupported_95_page_stops_without_typing(self):
        self.event_helper.write_text('#!/bin/sh\necho ready\nsleep .2\necho "unsupported c001cafe"\nexit 4\n',newline='\n')
        rc,out,err=self.run_lib('w9x_phase1_run /dev/fake tcg; echo "rc=$?"',
            W9X_VM_KEY='98765001234554321',W9X_VM_95_SETUP950='1',W9X_FAKE_SLEEP='2')
        self.assertIn('rc=2',out,err)
        self.assertIn('public heading hash=c001cafe',(self.tmp/'run/event-errors.log').read_text())
        command=(self.tmp/'run/command.txt').read_text()
        self.assertNotIn('95 input:',command);self.assertNotIn('98765',command)

    def test_missing_95_classifier_stops_the_osr2_timed_controller(self):
        # OSR2 / OSR2.1 (no W9X_VM_95_SETUP950): the 4e084310 timed controller.
        if self.run_lib('command -v mkfifo')[0] != 0:
            self.skipTest('no mkfifo in this sh')
        rc, out, err = self.run_lib('w9x_phase1_run /dev/fake tcg; echo "rc=$?"',
            W9X_VM_KEY='98765001234554321', W9X_VM_95_HELPER=(self.tmp / 'absent').as_posix())
        self.assertIn('rc=2', out, err)
        self.assertFalse((self.tmp / 'args.txt').exists())
        self.assertNotIn('98765', (self.tmp / 'run/command.txt').read_text())

    def test_osr21_pl_key_uses_the_timed_controller_not_the_event_one(self):
        # 95 OSR2.1 PL (SETUP 4.0.0.1111, X470 PASS): a key but no SETUP 950
        # flag -> the old timed controller types the COA once; the RFB event
        # helper is never started.
        if self.run_lib('command -v mkfifo')[0] != 0:
            self.skipTest('no mkfifo in this sh')
        marker = self.tmp / 'event-helper-ran'
        self.event_helper.write_text(f'#!/bin/sh\n: > "{marker.as_posix()}"\necho ready\nsleep 60\n', newline='\n')
        for setup950 in (None, '0', ''):
            extra = {} if setup950 is None else {'W9X_VM_95_SETUP950': setup950}
            rc, out, err = self.run_lib('w9x_vm_graphics_screen() { W9X_VM_PAGE=coa; return 0; }\nw9x_phase1_run /dev/fake tcg; echo "rc=$?"', W9X_FAKE_SLEEP='12',
                                        W9X_VM_KEY='98765001234554321', W9X_VM_IDLE='1', W9X_VM_KEY_TRIES='1', **extra)
            self.assertIn('rc=0', out, err)
            command = (self.tmp / 'run/command.txt').read_text()
            self.assertEqual(command.count('95 input: coa'), 1, setup950)
            self.assertNotIn('controller=rfb-blocking-events', command)
            self.assertFalse((self.tmp / 'run/event-errors.log').exists())
            self.assertFalse(marker.exists(), setup950)
            self.assertNotIn('98765', command)

    def test_timed_controller_never_acts_on_950_only_pages(self):
        lib = (ROOT / 'tools/w9x_95_ui.sh').as_posix()
        roles = ('coa-single', 'coa-single-en', 'owner-en', 'welcome-en', 'directory-en', 'setup-type-en',
                 'hardware-list-en', 'communication', 'communication-en', 'components-en', 'copy-ready-en',
                 'finish-en', 'network-device-en')
        for role in roles:
            body = (f'. "{lib}"\nkey=98765001234554321 key_tries=0 written=0 W9X_VM_KEY_MAX_MB=64 w95_last_page=\n'
                    f'W9X_VM_PAGE={role}\nw9x_vm_95_page_ready; echo "old=$?"\n'
                    'W9X_VM_95_SETUP950=1; w9x_vm_95_page_ready; echo "new=$?"')
            rc, out, err = sh(body)
            self.assertIn('old=1', out, (role, err))
            self.assertIn('new=0', out, (role, err))
        # The OSR2 roles keep their 4e084310 answers without the flag.
        for role in ('coa', 'owner', 'welcome', 'restart', 'reboot-confirm', 'startup-disk'):
            body = (f'. "{lib}"\nkey=98765001234554321 key_tries=0 written=0 W9X_VM_KEY_MAX_MB=64 w95_last_page=\n'
                    f'W9X_VM_PAGE={role}\nw9x_vm_95_page_ready; echo "old=$?"')
            self.assertIn('old=0', sh(body)[1], role)

    def test_the_key_is_typed_once_idle_and_never_logged(self):
        if self.run_lib('command -v mkfifo')[0] != 0:
            self.skipTest('no mkfifo in this sh')
        # No /sys/block here: the written counter stays 0, i.e. a waiting page;
        # the fake QEMU draws nothing, so the screen test is replaced.
        rc, out, err = self.run_lib('w9x_vm_graphics_screen() { echo forbidden-screen-query >&2; return 2; }\nw9x_phase1_run /dev/fake tcg; echo "rc=$?"', W9X_FAKE_SLEEP='12',
                                    W9X_VM_KEY='98765001234554321', W9X_VM_95_SETUP950='1', W9X_FAKE_PAGE='coa')
        self.assertIn('rc=0', out, err)
        self.assertNotIn('forbidden-screen-query', err)
        self.assertIn('controller=rfb-blocking-events', (self.tmp / 'run/command.txt').read_text())
        command = (self.tmp / 'run/command.txt').read_text()
        self.assertEqual(command.count('95 input: coa'), 1)
        for name in ('command.txt', 'monitor.log', 'qemu.log'):
            path = self.tmp / 'run' / name
            if path.exists():
                self.assertNotIn('98765', path.read_text(errors='replace'), name)
                self.assertNotIn('sendkey', path.read_text(errors='replace'), name)
        args = (self.tmp / 'args.txt').read_text().splitlines()
        monitors = [args[i + 1] for i, a in enumerate(args) if a == '-monitor']
        self.assertEqual([m.rsplit('/', 1)[1] for m in monitors], ['mon', 'key'])
        # A text-mode screen (DOS) never gets the key.
        rc, out, err = self.run_lib('w9x_phase1_run /dev/fake tcg; echo "rc=$?"', W9X_FAKE_SLEEP='8',
                                    W9X_VM_KEY='98765001234554321', W9X_VM_IDLE='1')
        self.assertIn('rc=0', out, err)
        self.assertNotIn('95 input: coa', (self.tmp / 'run/command.txt').read_text())
        for header, graphics in ((b'P6\n720 400\n255\n', False), (b'P6\n640 480\n255\n', True)):
            (self.tmp / 'hdr.bin').write_bytes(header + b'\0' * 32)
            body = (f'mkdir -p "$W9X_VM_RUN"\nw9x_vm_monitor() {{ cp "{(self.tmp / "hdr.bin").as_posix()}" "${{1#screendump }}"; }}\n'
                    'w9x_vm_graphics_screen; echo "g=$?"; ls "$W9X_VM_RUN"')
            rc, out, err = self.run_lib(body)
            self.assertIn('g=0' if graphics else 'g=1', out, err)
            self.assertNotIn('mode.ppm', out)
        # Without a key nothing is typed and the stall rule is off.
        self.run_lib('w9x_phase1_run /dev/fake tcg', W9X_FAKE_SLEEP='3', W9X_VM_IDLE='1', W9X_VM_STALL='1')
        command = (self.tmp / 'run/command.txt').read_text()
        self.assertNotIn('key typed', command)
        self.assertNotIn('stalled', command)

    def test_stall_rule_without_a_key_when_asked(self):
        # NT 4.0 (W9X_VM_STALL_ANY=1): no key, but a run without disk writes
        # still ends (rc 3) and reports the idle seconds.
        if self.run_lib('command -v mkfifo')[0] != 0:
            self.skipTest('no mkfifo in this sh')
        rc, out, err = self.run_lib('w9x_phase1_run /dev/fake tcg; echo "rc=$? stalled=$W9X_VM_STALLED"', W9X_FAKE_SLEEP='30',
                                    W9X_VM_STALL_ANY='1', W9X_VM_IDLE='1', W9X_VM_STALL='4')
        self.assertIn('rc=3 stalled=', out, err)
        self.assertGreaterEqual(int(out.split('stalled=')[1].split()[0]), 4)
        command = (self.tmp / 'run/command.txt').read_text()
        self.assertIn('stalled: no disk write', command)
        self.assertNotIn('key typed', command)
        self.assertNotIn('answer typed', command)

    def test_answer_key_for_a_waiting_message_box(self):
        if self.run_lib('command -v mkfifo')[0] != 0:
            self.skipTest('no mkfifo in this sh')
        rc, out, err = self.run_lib('w9x_vm_graphics_screen() { return 0; }\nw9x_phase1_run /dev/fake tcg; echo "rc=$?"', W9X_FAKE_SLEEP='14',
                                    W9X_VM_STALL_ANY='1', W9X_VM_ANSWER='alt-n', W9X_VM_ANSWER_IDLE='1', W9X_VM_ANSWER_TRIES='1')
        self.assertIn('rc=0', out, err)
        command = (self.tmp / 'run/command.txt').read_text()
        self.assertIn('answer typed: alt-n attempt 1', command)
        self.assertNotIn('attempt 2', command)
        # Text mode (no graphics screen): never typed.
        rc, out, err = self.run_lib('w9x_vm_graphics_screen() { return 1; }\nw9x_phase1_run /dev/fake tcg; echo "rc=$?"', W9X_FAKE_SLEEP='8',
                                    W9X_VM_STALL_ANY='1', W9X_VM_ANSWER='alt-n', W9X_VM_ANSWER_IDLE='1')
        self.assertNotIn('answer typed', (self.tmp / 'run/command.txt').read_text())

    def test_answer_while_the_guest_keeps_writing_a_little(self):
        # XP's logon dialog (POSReady, X470 2026-10-11): a few sectors written
        # all the time, so the disk is never idle. W9X_VM_ANSWER_QUIET_MB
        # types the answer anyway; without it nothing is typed.
        if self.run_lib('command -v mkfifo')[0] != 0:
            self.skipTest('no mkfifo in this sh')
        counter = (self.tmp / 'sectors').as_posix()
        busy = (f'w9x_vm_written() {{ n=$(cat "{counter}" 2>/dev/null || echo 0); n=$((n + 8)); echo "$n" > "{counter}"; echo "$n"; }}\n'
                'w9x_vm_graphics_screen() { return 0; }\nw9x_phase1_run /dev/fake tcg; echo "rc=$?"')
        rc, out, err = self.run_lib(busy, W9X_FAKE_SLEEP='14', W9X_VM_STALL_ANY='1', W9X_VM_ANSWER='shift-a ret',
                                    W9X_VM_ANSWER_IDLE='1', W9X_VM_ANSWER_TRIES='1', W9X_VM_ANSWER_QUIET_MB='1')
        self.assertIn('rc=0', out, err)
        command = (self.tmp / 'run/command.txt').read_text()
        self.assertIn('answer typed: shift-a ret attempt 1', command)
        self.assertNotIn('attempt 2', command)
        (self.tmp / 'sectors').unlink()
        rc, out, err = self.run_lib(busy, W9X_FAKE_SLEEP='10', W9X_VM_STALL_ANY='1', W9X_VM_ANSWER='shift-a ret',
                                    W9X_VM_ANSWER_IDLE='1', W9X_VM_ANSWER_TRIES='1')
        self.assertIn('rc=0', out, err)
        self.assertNotIn('answer typed', (self.tmp / 'run/command.txt').read_text())

    def test_answer_lists_per_attempt(self):
        # "keys;keys": attempt N types list N (NT 3.1 Advanced Server: Domain
        # Settings, then the Date/Time applet), later attempts the last list.
        if self.run_lib('command -v mkfifo')[0] != 0:
            self.skipTest('no mkfifo in this sh')
        rc, out, err = self.run_lib('w9x_vm_graphics_screen() { return 0; }\nw9x_phase1_run /dev/fake tcg; echo "rc=$?"', W9X_FAKE_SLEEP='20',
                                    W9X_VM_STALL_ANY='1', W9X_VM_ANSWER='alt-c tab shift-u ret;ret', W9X_VM_ANSWER_IDLE='1',
                                    W9X_VM_ANSWER_TRIES='3')
        self.assertIn('rc=0', out, err)
        command = (self.tmp / 'run/command.txt').read_text()
        self.assertIn('answer typed: alt-c tab shift-u ret attempt 1', command)
        self.assertIn('answer typed: ret attempt 2', command)

    def test_tcg_is_the_default_kvm_needs_flag_and_device(self):
        self.assertEqual(self.run_lib('w9x_vm_accel')[1].strip(), 'tcg')
        (self.tmp / 'flags/phase1-kvm.flag').write_bytes(b'')
        # Flag present, no /dev/kvm: still TCG.
        self.assertEqual(self.run_lib('w9x_vm_accel')[1].strip(), 'tcg')

    def test_qemu_arguments_follow_the_hard_rules(self):
        rc, out, err = self.run_lib('w9x_vm_args /dev/sdb tcg')
        self.assertEqual(rc, 0, err)
        args = out.splitlines()
        joined = ' '.join(args)
        self.assertIn('pc,acpi=off', args)
        self.assertIn('-no-reboot', args)
        self.assertEqual(args[args.index('-nic') + 1], 'none')
        self.assertIn('-nodefaults', args)
        self.assertEqual(args[args.index('-m') + 1], '512')
        self.assertEqual(args[args.index('-accel') + 1], 'tcg,tb-size=128')
        drives = [a for a in args if a.startswith('file=')]
        self.assertEqual(drives, ['file=/dev/sdb,format=raw,if=ide,index=0,media=disk,cache=none,file.locking=off'])
        self.assertNotIn('-no-shutdown', args)
        self.assertNotIn('-netdev', joined)
        self.assertEqual(self.run_lib('w9x_vm_args /dev/sdb kvm')[1].splitlines()[8], 'kvm')

    def test_run_reports_the_guest_restart_qemu_errors_and_timeouts(self):
        if self.run_lib('command -v mkfifo')[0] != 0:
            self.skipTest('no mkfifo in this sh')
        rc, out, err = self.run_lib('w9x_phase1_progress() { echo "P $1 $2"; }\nw9x_phase1_run /dev/fake tcg; echo "rc=$?"')
        self.assertIn('rc=0', out, err)
        self.assertIn('/dev/fake', (self.tmp / 'args.txt').read_text())
        self.assertIn('rc=0 elapsed=', (self.tmp / 'run/command.txt').read_text())
        rc, out, _ = self.run_lib('w9x_phase1_run /dev/fake tcg; echo "rc=$?"', W9X_FAKE_RC='1')
        self.assertIn('rc=2', out)
        rc, out, _ = self.run_lib('w9x_phase1_run /dev/fake tcg; echo "rc=$?"', W9X_FAKE_SLEEP='30', W9X_VM_TIMEOUT='1')
        self.assertIn('rc=3', out)

    def test_phase1_tree_check(self):
        c = self.tmp / 'c'
        (c / 'WINDOWS/SYSTEM').mkdir(parents=True)
        self.assertNotEqual(self.run_lib(f'w9x_phase1_tree_ok "{c.as_posix()}"')[0], 0)
        for name in ('WINDOWS/WIN.COM', 'WINDOWS/SYSTEM.INI', 'SETUPLOG.TXT'):
            (c / name).write_bytes(b'x')
        rc, out, _ = self.run_lib(f'w9x_phase1_tree_ok "{c.as_posix()}"')
        self.assertEqual(rc, 0, out)
        (c / 'WINDOWS/WIN.COM').unlink()
        rc, out, _ = self.run_lib(f'w9x_phase1_tree_ok "{c.as_posix()}"')
        self.assertIn('WIN.COM', out)

    def test_patch_drops_the_vm_mouse_line_and_the_second_himem(self):
        # The files of the BIOSTAR/X470 98 SE disk after phase 1 (shortened).
        c = self.tmp / 'c'
        (c / 'WINDOWS').mkdir(parents=True)
        (self.tmp / 'run').mkdir()
        ini = (b'[boot]\r\nmouse.drv=mouse.drv\r\n[386Enh]\r\nebios=*ebios\r\nmouse=*vmouse, msmouse.vxd\r\n'
               b'woafont=dosapp.fon\r\n[mci]\r\nmouse=keep\r\n')
        config = (b'DEVICE=C:\\WINDOWS\\HIMEM.SYS /TESTMEM:OFF /M:2\r\nDEVICE=C:\\WINDOWS\\HIMEM.SYS /TESTMEM:OFF /M:2\r\n'
                  b'DEVICE=C:\\WINDOWS\\setver.exe\r\nCountry=048,852,C:\\WINDOWS\\COMMAND\\country.sys\r\n')
        (c / 'WINDOWS/SYSTEM.INI').write_bytes(ini)
        (c / 'CONFIG.SYS').write_bytes(config)
        rc, out, err = self.run_lib(f'w9x_phase1_patch_c "{c.as_posix()}"')
        self.assertEqual(rc, 0, err)
        self.assertEqual(out.splitlines(), ['SYSTEM.INI: removed mouse=*vmouse, msmouse.vxd',
                                            'CONFIG.SYS: removed DEVICE=C:\\WINDOWS\\HIMEM.SYS /TESTMEM:OFF /M:2'])
        self.assertEqual((c / 'WINDOWS/SYSTEM.INI').read_bytes(),
                         b'[boot]\r\nmouse.drv=mouse.drv\r\n[386Enh]\r\nebios=*ebios\r\nwoafont=dosapp.fon\r\n[mci]\r\nmouse=keep\r\n')
        self.assertEqual((c / 'CONFIG.SYS').read_bytes(),
                         b'DEVICE=C:\\WINDOWS\\HIMEM.SYS /TESTMEM:OFF /M:2\r\nDEVICE=C:\\WINDOWS\\setver.exe\r\n'
                         b'Country=048,852,C:\\WINDOWS\\COMMAND\\country.sys\r\n')
        # Nothing left to change: no output, files and folder as they are.
        rc, out, err = self.run_lib(f'w9x_phase1_patch_c "{c.as_posix()}"')
        self.assertEqual((rc, out), (0, ''), err)
        self.assertEqual(sorted(p.name for p in c.rglob('*')), ['CONFIG.SYS', 'SYSTEM.INI', 'WINDOWS'])

    def test_patch_adds_logo_off_to_the_me_msdos_sys_once(self):
        # Me's Setup writes its own MSDOS.SYS in the VM (no Logo= line).
        c = self.tmp / 'c'
        c.mkdir()
        (self.tmp / 'run').mkdir()
        msdos = (b'[Paths]\r\nWinDir=C:\\WINDOWS\r\n\r\n[Options]\r\nBootMulti=1\r\nBootGUI=1\r\n'
                 b'WinVer=4.90.3000\r\n;\r\n;xxxxxxxxxxa\r\n')
        (c / 'MSDOS.SYS').write_bytes(msdos)
        rc, out, err = self.run_lib(f'w9x_phase1_patch_c "{c.as_posix()}"')
        self.assertEqual((rc, out.splitlines()), (0, ['MSDOS.SYS: added Logo=0']), err)
        self.assertEqual((c / 'MSDOS.SYS').read_bytes(),
                         msdos.replace(b'[Options]\r\n', b'[Options]\r\nLogo=0\r\n'))
        rc, out, err = self.run_lib(f'w9x_phase1_patch_c "{c.as_posix()}"')
        self.assertEqual((rc, out), (0, ''), err)
        self.assertEqual(sorted(p.name for p in c.rglob('*')), ['MSDOS.SYS'])
        # 98 / 98 SE: INSTALL.BAT already wrote Logo=0; a user's Logo=1 stays.
        (c / 'MSDOS.SYS').write_bytes(b'[Options]\r\nlogo=1\r\n')
        self.assertEqual(self.run_lib(f'w9x_phase1_patch_c "{c.as_posix()}"')[:2], (0, ''))
        self.assertEqual((c / 'MSDOS.SYS').read_bytes(), b'[Options]\r\nlogo=1\r\n')

    def test_fsck_is_read_only_and_its_errors_fail(self):
        bin_dir = self.tmp / 'bin'
        bin_dir.mkdir()
        fake = bin_dir / 'fsck.fat'
        fake.write_text('#!/bin/sh\necho "args: $*"\nexit "${W9X_FAKE_FSCK:-0}"\n', newline='\n')
        fake.chmod(0o755)
        log = (self.tmp / 'fsck.txt').as_posix()
        # A POSIX PATH entry (Git sh on Windows: no drive colon).
        bin_path = bin_dir.as_posix()
        if bin_path[1:2] == ':':
            bin_path = '/' + bin_path[0].lower() + bin_path[2:]
        rc, _, err = sh(f'. "{LIB}"\nPATH="{bin_path}:$PATH"\nw9x_phase1_fsck /dev/loop7 "{log}" "C: test"', self.env())
        self.assertEqual(rc, 0, err)
        text = Path(log).read_text()
        self.assertIn('== fsck.fat -n: C: test', text)
        self.assertIn('args: -n /dev/loop7', text)
        rc, _, _ = sh(f'. "{LIB}"\nPATH="{bin_path}:$PATH"\nw9x_phase1_fsck /dev/loop7 "{log}" again', self.env(W9X_FAKE_FSCK='1'))
        self.assertEqual(rc, 1)
        self.assertIn('== rc=1', Path(log).read_text())

    def test_verify_checks_the_disk_before_and_after_and_flushes(self):
        text = Path(LIB).read_text(encoding='utf-8')
        body = text[text.index('w9x_phase1_verify() {'):]
        first_fsck = body.index('w9x_phase1_fsck "$loop"')
        self.assertLess(body.index('blockdev --flushbufs "$target"'), first_fsck)
        self.assertLess(first_fsck, body.index('mount -t vfat'))
        self.assertLess(body.index('w9x_phase1_patch_c'), body.index('PHASE1.OK'))
        second_fsck = body.index('w9x_phase1_fsck "$loop"', first_fsck + 1)
        self.assertLess(body.index('umount "$W9X_VM_RUN/c"'), second_fsck)
        run = text[text.index('w9x_phase1_run() {'):text.index('w9x_phase1_tree_ok() {')]
        self.assertLess(run.index('blockdev --flushbufs "$target"'), run.index('"$W9X_VM_QEMU" "$@"'))


class TargetVmParts(unittest.TestCase):
    def helpers(self):
        text = TARGET.read_text(encoding='utf-8')
        start = text.index('w9x_display_ids() {')
        return text[start:text.index('\nfor tool in dd od', start)]

    def test_real_display_controllers_go_into_usosvesa_inf(self):
        tmp = scratch('usos-w9x-pci-')
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        for name, (vendor, device, klass) in {'0000_00_01.0': ('0x1022', '0x1480', '0x060000'),
                                              '0000_0a_00.0': ('0x1002', '0x67FF', '0x030000'),
                                              '0000_0b_00.0': ('0x10de', '0x1c82', '0x030200')}.items():
            (tmp / name).mkdir()
            for field, value in (('vendor', vendor), ('device', device), ('class', klass)):
                (tmp / name / field).write_text(value + '\n', newline='\n')
        inf = tmp / 'USOSVESA.INF'
        inf.write_bytes(b'[Manufacturer]\r\n%Mfg%=Mfg.VM\r\n\r\n[Mfg.VM]\r\n'
                        b'"vesa (vmdisp9x) 10de:1c82"=VESA, PCI\\VEN_10de&DEV_1c82\r\n'
                        b'%VESAPCI.DeviceDesc%=VESA, PCI\\CC_0300\r\n')
        script = self.helpers() + f'\nids=$(w9x_display_ids "{tmp.as_posix()}")\nprintf "%s\\n" "$ids"\nw9x_add_display_ids "$ids" < "{inf.as_posix()}" > "{(tmp / "out.inf").as_posix()}"\n'
        rc, out, err = sh(script)
        self.assertEqual(rc, 0, err)
        self.assertEqual(out.split(), ['1002:67ff', '10de:1c82'])
        self.assertEqual((tmp / 'out.inf').read_bytes(),
                         b'[Manufacturer]\r\n%Mfg%=Mfg.VM\r\n\r\n[Mfg.VM]\r\n'
                         b'"AMD Radeon RX 550/560 (VESA)"=VESA, PCI\\VEN_1002&DEV_67ff\r\n'
                         b'"vesa (vmdisp9x) 10de:1c82"=VESA, PCI\\VEN_10de&DEV_1c82\r\n'
                         b'%VESAPCI.DeviceDesc%=VESA, PCI\\CC_0300\r\n')

    def test_display_names_are_readable_without_pci_ids(self):
        cases = [('1002:67ef', 'PL', 'AMD Radeon RX 460/560 (VESA)'), ('10de:1c82', 'EN', 'NVIDIA GeForce GTX 1050 Ti (VESA)'),
                 ('1234:1111', 'PL', 'Karta graficzna VESA'), ('1234:1111', 'EN', 'VESA Display Adapter'),
                 ('1234:1111', '', 'VESA Display Adapter'), ('1234:1111', 'XX', 'VESA Display Adapter')]
        for ident, lang, want in cases:
            rc, out, err = sh(self.helpers() + f'\nw9x_display_name {ident} "{lang}"')
            self.assertEqual((rc, out), (0, want), err)
        tmp = scratch('usos-w9x-name-')
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        inf = tmp / 'USOSVESA.INF'
        inf.write_bytes(b'[Mfg.VM]\r\n%VESAPCI.DeviceDesc%=VESA, PCI\\CC_0300\r\n')
        out_inf = tmp / 'out.inf'
        rc, out, err = sh(self.helpers() + f'\nids=$(printf "1002:67ef\\n1234:1111")\n'
                          f'w9x_add_display_ids "$ids" PL < "{inf.as_posix()}" > "{out_inf.as_posix()}"')
        self.assertEqual(rc, 0, err)
        self.assertEqual(out_inf.read_bytes(), b'[Mfg.VM]\r\n"AMD Radeon RX 460/560 (VESA)"=VESA, PCI\\VEN_1002&DEV_67ef\r\n'
                         b'"Karta graficzna VESA"=VESA, PCI\\VEN_1234&DEV_1111\r\n%VESAPCI.DeviceDesc%=VESA, PCI\\CC_0300\r\n')
        self.assertNotIn(b'vmdisp9x', out_inf.read_bytes())
        text = TARGET.read_text(encoding='utf-8')
        call = 'w9x_add_display_ids "$ids" "${addon_lang:-}"'
        self.assertIn(call, text)
        self.assertLess(text.index('addon_lang=XX'), text.index(call))

    def test_target_writer_sets_u9vm_only_in_vm_mode(self):
        text = TARGET.read_text(encoding='utf-8')
        self.assertIn("VM_PHASE1=${W9X_VM_PHASE1:-0}", text)
        self.assertIn("printf 'SET U9VM=1\\r\\n' >> \"$work/c/USOS9X/U9ENV.BAT\"", text)

    def run_usb_block(self, tag, flag, diag=False):
        """The 98 SE USB stack block of the target writer + the U9ENV.BAT
        lines, with a fake cabinet carver; returns (files in USB, U9ENV.BAT)."""
        text = TARGET.read_text(encoding='utf-8')
        block = text[text.index('# 98 SE: the user'):text.index("if [ \"$VM_PHASE1\" = 1 ]")]
        tmp = scratch('usos-w9x-usb-')
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        (tmp / 'usb').mkdir()
        (tmp / 'usb/NUSB33E.EXE').write_bytes(b'MSCF usbport.sys usbhub20.sys')
        (tmp / 'work/c/USOS9X').mkdir(parents=True)
        (tmp / 'esp/win9x').mkdir(parents=True)
        if flag:
            (tmp / 'esp/win9x/xhci98.flag').write_bytes(b'')
        if diag:
            (tmp / 'esp/win9x/diag.flag').write_bytes(b'')
        script = (f'set -eu\nlog() {{ :; }}\nw9x_carve_cab() {{ cp "$1" "$2"; }}\n'
                  f'work="{(tmp / "work").as_posix()}"\nUSB_DIR="{(tmp / "usb").as_posix()}"\n'
                  f'SYSTEM_TAG={tag}\nSETUP_FOLDER=WIN98\nANSWER_KIND=USOS\n'
                  f'XHCI98_FLAG="{(tmp / "esp/win9x/xhci98.flag").as_posix()}"\n'
                  f'DIAG_FLAG="{(tmp / "esp/win9x/diag.flag").as_posix()}"\n' + block)
        rc, _, err = sh(script)
        self.assertEqual(rc, 0, err)
        usb = tmp / 'work/c/USOS9X/USB'
        files = sorted(p.name for p in usb.iterdir()) if usb.exists() else []
        return files, (tmp / 'work/c/USOS9X/U9ENV.BAT').read_bytes()

    def test_xhci98_is_opt_in_through_the_flag_file(self):
        text = TARGET.read_text(encoding='utf-8')
        self.assertIn('XHCI98_FLAG=${W9X_XHCI98_FLAG:-$ESP_DIR/win9x/xhci98.flag}', text)
        files, env = self.run_usb_block('98SE', flag=False)
        self.assertEqual(files, [])
        self.assertNotIn(b'U9USB', env)
        self.assertNotIn(b'U9DIAG', env)
        files, env = self.run_usb_block('98SE', flag=True)
        self.assertEqual(files, ['STACK.CAB'])
        self.assertIn(b'SET U9USB=1\r\n', env)
        files, env = self.run_usb_block('98', flag=True)
        self.assertEqual(files, [])
        self.assertNotIn(b'U9USB', env)

    def test_usosdiag_boot_is_opt_in(self):
        text = TARGET.read_text(encoding='utf-8')
        self.assertIn('DIAG_FLAG=${W9X_DIAG_FLAG:-$ESP_DIR/win9x/diag.flag}', text)
        _, env = self.run_usb_block('98SE', flag=False, diag=True)
        self.assertIn(b'SET U9DIAG=1\r\n', env)
        lines = (ROOT / 'src/platform/bios/dos_startup.cmd').read_text(encoding='ascii').splitlines()
        guard = lines.index('IF NOT "%U9DIAG%"=="1" GOTO DIAGDONE')
        self.assertEqual(lines[guard + 1], r'ECHO @IF EXIST C:\USOS9X\USOSDIAG.COM C:\USOS9X\USOSDIAG.COM BOOT>>C:\AUTOEXEC.BAT')
        self.assertEqual(lines[guard + 2], ':DIAGDONE')
        self.assertEqual(sum('USOSDIAG' in l for l in lines if not l.startswith('REM')), 1)
        import sys
        sys.path.insert(0, str(ROOT / 'tools'))
        import build_win9x_support
        self.assertIn('USOSDIAG.COM', build_win9x_support.STAGED)
        self.assertIn('USOSDBG.EXE', build_win9x_support.STAGED)
        self.assertNotIn('USOSDIAG.COM', build_win9x_support.FILES)

    def test_install_bat_copies_xhci98_only_with_u9usb(self):
        lines = (ROOT / 'src/platform/bios/dos_startup.cmd').read_text(encoding='ascii').splitlines()
        guard = lines.index('IF NOT "%U9USB%"=="1" GOTO USBDONE')
        copy = next(i for i, l in enumerate(lines) if 'XHCI98.SYS XHCI98.INF USB\\STACK.CAB' in l)
        self.assertLess(guard, copy)
        self.assertLess(copy, lines.index(':USBDONE'))
        self.assertFalse(any('XHCI98' in l and 'COPY' in l for l in lines[:guard]))

    def test_install_bat_adds_p_i_under_csmwrap(self):
        # 98 / 98 SE / Me: /P I with the VM phase 1 (U9VM=1) and with the
        # native one (U9CSM=1 alone): the target script writes U9CSM=1 on
        # both paths, so the switches are the same.
        lines = (ROOT / 'src/platform/bios/dos_startup.cmd').read_text(encoding='ascii').splitlines()
        self.assertNotIn('IF "%U9VM%"=="1" SET U9SW=%U9SW% /P I', lines)
        vm = lines.index('IF "%U9CSM%"=="1" SET U9SW=%U9SW% /P I')
        target = (ROOT / 'tools/w9x_csmwrap_target.sh').read_text(encoding='utf-8')
        self.assertIn(r"SET U9CSM=1\r\n", target)
        self.assertGreater(vm, lines.index('IF "%U9SYS%"=="95" SET U9SW=/IS /IW'))
        # 95 has no ACPI (and its Setup knows no /P I): skipped.
        self.assertEqual(lines[vm - 1], 'IF "%U9SYS%"=="95" GOTO VMSWOK')
        self.assertEqual(lines[vm + 1], ':VMSWOK')
        self.assertLess(vm, next(i for i, l in enumerate(lines) if l.startswith('ECHO C:\\%U9SRC%\\SETUP.EXE')))

    def test_install_bat_caps_windows_95_memory_through_u9fix(self):
        lines = (ROOT / 'src/platform/bios/dos_startup.cmd').read_text(encoding='ascii').splitlines()
        fixes = [l for l in lines if 'U9FIX.COM' in l and 'AUTOEXEC.BAT' in l]
        self.assertEqual(fixes, ['ECHO @C:\\USOS9X\\U9FIX.COM C:\\WINDOWS\\SYSTEM.INI>C:\\AUTOEXEC.BAT',
                                 'ECHO @C:\\USOS9X\\U9FIX.COM /95 C:\\WINDOWS\\SYSTEM.INI>C:\\AUTOEXEC.BAT',
                                 'ECHO @C:\\USOS9X\\U9FIX.COM /CSM C:\\WINDOWS\\SYSTEM.INI>>C:\\AUTOEXEC.BAT',
                                 'ECHO @C:\\USOS9X\\U9FIX.COM /95 /CSM C:\\WINDOWS\\SYSTEM.INI>>C:\\AUTOEXEC.BAT'])
        self.assertEqual(lines[lines.index(fixes[1]) - 1], ':FIX95')
        self.assertEqual(lines[lines.index(fixes[3]) - 1], ':CSMFIX95')

    def test_install_bat_config_sys_under_csmwrap(self):
        """CREGFIX first (it creates C:\\CONFIG.SYS), one HIMEM line in the VM
        path, the C:\\USOS9X fallback only for the native Setup start."""
        lines = (ROOT / 'src/platform/bios/dos_startup.cmd').read_text(encoding='ascii').splitlines()
        cregfix = lines.index('ECHO DEVICE=C:\\USOS9X\\CREGFIX.SYS>C:\\CONFIG.SYS')
        himem = lines.index('ECHO DEVICE=C:\\WINDOWS\\HIMEM.SYS /TESTMEM:OFF /M:2>>C:\\CONFIG.SYS')
        skip = lines.index('IF "%U9VM%"=="1" GOTO NOCSM')
        fallback = lines.index('ECHO DEVICE=C:\\USOS9X\\HIMEM.SYS /TESTMEM:OFF /M:2>>C:\\CONFIG.SYS')
        self.assertLess(lines.index('IF NOT EXIST C:\\USOS9X\\CREGFIX.SYS GOTO FAILED'), cregfix)
        self.assertLess(cregfix, himem)
        self.assertLess(himem, skip)
        self.assertLess(skip, fallback)
        self.assertEqual(sum('>C:\\CONFIG.SYS' in l.replace('>>', '') for l in lines), 1)
        self.assertTrue(any('CREGFIX.SYS) DO COPY /Y A:\\%%F C:\\USOS9X' in l for l in lines))

    def test_boot_floppy_config_sys_loads_cregfix_first(self):
        text = TARGET.read_text(encoding='utf-8')
        block = text[text.index(': > "$work/CONFIG.SYS"'):text.index('for name in AUTOEXEC.BAT CONFIG.SYS')]
        self.assertLess(block.index('CREGFIX.SYS'), block.index('HIMEM.SYS'))
        self.assertLess(block.index('HIMEM.SYS'), block.index('FILES=40'))


class PrepareWiring(unittest.TestCase):
    def test_prepare_runs_the_vm_after_the_target_and_stops_on_failure(self):
        text = (ROOT / 'tools/w9x_csmwrap_prepare.sh').read_text(encoding='utf-8')
        target = text.index('sh /usr/lib/usos/w9x_csmwrap_target.sh')
        run = text.index('w9x_phase1_run "$TARGET_DEVICE"')
        verify = text.index('w9x_phase1_verify "$TARGET_DEVICE"')
        # The restart goes through stick_release.sh since 752a81f (stick mounts
        # released first), no longer a bare reboot -f.
        reboot = text.index('sh /usr/lib/usos/stick_release.sh reboot')
        self.assertLess(target, run)
        self.assertLess(run, verify)
        self.assertLess(verify, reboot)
        self.assertIn("stop 'Windows Setup stage 1 did not finish.", text[verify:reboot])

    def test_event_controller_only_for_setup_950_from_the_target_result(self):
        text = (ROOT / 'tools/w9x_csmwrap_prepare.sh').read_text(encoding='utf-8')
        clear = text.index('rm -f /run/w9x-target.result')
        target = text.index('"$@" >> "$W9X_LOG/prepare.log"')
        flag = text.index("grep -qx 'setup_version=4 0 0 950' /run/w9x-target.result")
        run = text.index('w9x_phase1_run "$TARGET_DEVICE"')
        self.assertLess(clear, target)
        self.assertLess(target, flag)
        self.assertLess(flag, run)
        self.assertIn('W9X_VM_95_SETUP950=0', text[target:flag])
        self.assertIn('[ "$tag" = 95 ]', text[flag - 200:flag])
        writer = TARGET.read_text(encoding='utf-8')
        self.assertIn("printf 'setup_version=%s\\n' \"$setup_version\" > \"${W9X_TARGET_RESULT:-/run/w9x-target.result}\"", writer)
        self.assertLess(writer.index('usos_w9x_fs_select "$SYSTEM_TAG"'), writer.index("printf 'setup_version="))
        lib = (ROOT / 'tools/w9x_phase1_qemu.sh').read_text(encoding='utf-8')
        self.assertIn('if [ -n "${W9X_VM_KEY:-}" ] && [ "${W9X_VM_95_SETUP950:-0}" = 1 ]; then', lib)
        # The same condition on result files: only an exact 950 line.
        folder = scratch('usos-w9x-result-')
        self.addCleanup(shutil.rmtree, folder, ignore_errors=True)
        for line, expected in (('setup_version=4 0 0 950', '1'), ('setup_version=4 0 0 1111', '0'),
                               ('setup_version=4 0 0 1212', '0'), ('setup_version=', '0'),
                               ('setup_version=4 0 0 9500', '0')):
            result = folder / 'r'
            result.write_text(line + '\n', newline='\n')
            rc, out, err = sh(f"f=0; if [ 95 = 95 ] && grep -qx 'setup_version=4 0 0 950' '{result.as_posix()}'; then f=1; fi; echo $f")
            self.assertEqual(out.strip(), expected, line)

    def test_the_script_is_in_the_initramfs(self):
        self.assertIn('("tools/w9x_phase1_qemu.sh", "usr/lib/usos/w9x_phase1_qemu.sh")',
                      (ROOT / 'tools/build_micro_linux.py').read_text(encoding='utf-8'))


if __name__ == '__main__':
    unittest.main()
