"""Windows 95 SETUP 4.00.950 event controller (tools/w9x_95_event_wait.sh):
progress ticks, stall detection and periodic logs. Host only: Git sh, a fake
QEMU and a fake RFB receiver, temp folders; no VM, no disk.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
LIB = (ROOT / 'tools/w9x_phase1_qemu.sh').as_posix()


def shell():
    for candidate in ('C:/Program Files/Git/bin/sh.exe', 'C:/Program Files/Git/bin/bash.exe'):
        if os.path.exists(candidate):
            return candidate
    found = shutil.which('sh')
    if not found:
        raise unittest.SkipTest('no POSIX sh available')
    return found


def script(path, text):
    path.write_text(text, newline='\n')
    path.chmod(0o755)
    return path.as_posix()


class Win95EventProgress(unittest.TestCase):
    def setUp(self):
        parent = (ROOT / 'zig-out/w9x-phase1-tests').resolve()
        parent.mkdir(parents=True, exist_ok=True)
        self.tmp = Path(tempfile.mkdtemp(prefix='usos-w95-progress-', dir=parent)).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        (self.tmp / 'share/keymaps').mkdir(parents=True)
        (self.tmp / 'share/keymaps/en-us').write_bytes(b'# fake QEMU test input only\n')
        self.calls = self.tmp / 'progress.txt'
        self.counter = self.tmp / 'sectors'
        self.counter.write_text('0\n', newline='\n')
        self.log = self.tmp / 'stick-log'

    def run_controller(self, writes, **extra):
        env = dict(os.environ, **{
            'W9X_VM_QEMU': script(self.tmp / 'qemu', '#!/bin/sh\nsleep "${W9X_FAKE_SLEEP:-12}"\nexit 0\n'),
            'W9X_VM_95_EVENTS': script(self.tmp / 'receiver', '#!/bin/sh\necho ready\nsleep 60\n'),
            'W9X_VM_95_LIB': (ROOT / 'tools/w9x_95_ui.sh').as_posix(),
            'W9X_VM_95_EVENT_LIB': (ROOT / 'tools/w9x_95_event_wait.sh').as_posix(),
            'W9X_VM_DATADIR': (self.tmp / 'share').as_posix(),
            'W9X_VM_RUN': (self.tmp / 'run').as_posix(),
            'W9X_VM_KEY': '98765001234554321', 'W9X_VM_95_SETUP950': '1',
            'W9X_LOG': self.log.as_posix(),
        }, **extra)
        grow = '$((n + 4096))' if writes else '$n'
        body = f'''. "{LIB}"
w9x_vm_args() {{ echo -nodefaults; }}
w9x_vm_written() {{ n=$(cat "{self.counter.as_posix()}"); n={grow}; echo "$n" > "{self.counter.as_posix()}"; echo "$n"; }}
w9x_phase1_progress() {{ echo "$1 $2" >> "{self.calls.as_posix()}"; }}
w9x_phase1_run /dev/fake tcg
echo "rc=$? stalled=$W9X_VM_STALLED"
'''
        result = subprocess.run([shell(), '-c', body], capture_output=True, text=True, env=env, timeout=90)
        calls = self.calls.read_text().splitlines() if self.calls.exists() else []
        return result.stdout, calls

    def test_progress_ticks_and_rc_0(self):
        out, calls = self.run_controller(True, W9X_VM_SCREEN_EVERY='4')
        self.assertIn('rc=0 stalled=0', out)
        self.assertGreaterEqual(len(calls), 2, calls)
        self.assertEqual(calls[0], '0 0')
        elapsed = [int(line.split()[0]) for line in calls]
        written = [int(line.split()[1]) for line in calls]
        self.assertEqual(elapsed, sorted(elapsed))
        self.assertGreater(written[-1], 0)
        # Periodic copy onto the (fake) stick log during the run.
        self.assertTrue((self.log / 'phase1/command.txt').exists())
        self.assertIn('controller=rfb-blocking-events', (self.tmp / 'run/command.txt').read_text())

    def test_no_writes_stalls_with_rc_3(self):
        out, calls = self.run_controller(False, W9X_VM_STALL='3', W9X_VM_95_TICK='1', W9X_FAKE_SLEEP='30')
        self.assertIn('rc=3', out)
        stalled = int(out.split('stalled=')[1].split()[0])
        self.assertGreaterEqual(stalled, 3)
        self.assertIn('stalled: no disk write', (self.tmp / 'run/command.txt').read_text())
        self.assertGreaterEqual(len(calls), 2, calls)

    def test_ticker_uses_portable_sh_only(self):
        text = (ROOT / 'tools/w9x_95_event_wait.sh').read_text()
        for bashism in ('[[', 'read -t', '$RANDOM', 'local ', 'function '):
            self.assertNotIn(bashism, text)


if __name__ == '__main__':
    unittest.main()
