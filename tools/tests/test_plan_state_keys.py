"""M2: the plan_* keys the UEFI menu appends to install-state.ini do not
change what micro-Linux reads from it.

Builds install-state.ini byte for byte like
src/platform/uefi/persistent_state_file.zig (CRLF lines, padded with LF to
2048 bytes), with the plan lines the Zig plan renders (taken from the
plan_state rows of src/flow/testdata/routing_golden.tsv), and runs the real
`ini_value` function of tools/micro_linux_init.sh on it with a POSIX sh.
No VM, no disk.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
INIT = ROOT / 'tools' / 'micro_linux_init.sh'
GOLDEN = ROOT / 'src' / 'flow' / 'testdata' / 'routing_golden.tsv'
MAX_STATE_BYTES = 2048


def shell():
    for candidate in ('C:/Program Files/Git/bin/sh.exe', 'C:/Program Files/Git/bin/bash.exe'):
        if os.path.exists(candidate):
            return candidate
    found = shutil.which('sh')
    if not found:
        raise unittest.SkipTest('no POSIX sh available')
    return found


def ini_value_function():
    lines = INIT.read_text(encoding='utf-8').splitlines()
    start = lines.index('ini_value() {')
    end = lines.index('}', start)
    return '\n'.join(lines[start:end + 1]) + '\n'


def plan_lines(system, image):
    rows = []
    for line in GOLDEN.read_text(encoding='utf-8').splitlines():
        parts = line.split('\t')
        if parts[0] == 'plan_state' and parts[1] == system and parts[2] == image:
            rows.append(parts[3])
    return rows


def state_bytes(fields, plan):
    text = ''.join(f'{key}={value}\r\n' for key, value in fields) + ''.join(line + '\r\n' for line in plan)
    data = text.encode('utf-8')
    assert len(data) <= MAX_STATE_BYTES
    return data + b'\n' * (MAX_STATE_BYTES - len(data))


class PlanStateKeys(unittest.TestCase):
    FIELDS = [
        ('phase', 'prepare-requested'),
        ('selected_iso', r'\Systems\Windows\Windows 10\Images\Win10_22H2_x64.iso'),
        ('selected_unattend', r'\Systems\Windows\Windows 10\Unattended\a.xml'),
        ('selected_method', 'chainload'),
        ('selected_system', 'windows-10'),
    ]

    def read(self, state, keys):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'install-state.ini'
            path.write_bytes(state)
            script = ini_value_function() + ''.join(
                f'printf "%s=[%s]\\n" {k} "$(ini_value {k} "$1" 2>/dev/null || echo MISSING)"\n' for k in keys)
            result = subprocess.run([shell(), '-c', script, 'sh', path.as_posix()], capture_output=True, text=True, check=True)
        return dict(line.split('=', 1) for line in result.stdout.splitlines())

    def test_golden_has_plan_rows(self):
        plan = plan_lines('windows-10', 'iso')
        self.assertEqual(plan[0], 'plan_version=1')
        self.assertIn('plan_profile=iso-work-chainload', plan)

    def test_existing_keys_read_the_same_with_and_without_plan(self):
        keys = [k for k, _ in self.FIELDS] + ['plan_profile', 'plan_stages']
        without = self.read(state_bytes(self.FIELDS, []), keys)
        with_plan = self.read(state_bytes(self.FIELDS, plan_lines('windows-10', 'iso')), keys)
        for key, value in self.FIELDS:
            self.assertEqual(without[key], f'[{value}]')
            self.assertEqual(with_plan[key], f'[{value}]')
        self.assertEqual(without['plan_profile'], '[MISSING]')
        self.assertEqual(with_plan['plan_profile'], '[iso-work-chainload]')
        self.assertTrue(with_plan['plan_stages'].startswith('[Starting environment|'))

    def test_longest_paths_still_fit(self):
        long = [(k, v if not k.startswith('selected_i') and not k.startswith('selected_u') else '\\' + 'x' * 511) for k, v in self.FIELDS]
        state_bytes(long, plan_lines('windows-10', 'wim'))


if __name__ == '__main__':
    unittest.main()
