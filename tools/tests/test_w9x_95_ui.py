"""Regression cases for page-gated input; fake keys only, no running VM."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class Win95Input(unittest.TestCase):
    def setUp(self):
        scratch = ROOT / 'zig-out/win95-ui-tests'
        scratch.mkdir(parents=True, exist_ok=True)
        self.temp = Path(tempfile.mkdtemp(dir=scratch))
        assert self.temp.resolve().is_relative_to(scratch.resolve())
        self.addCleanup(shutil.rmtree, self.temp)
        self.shell = next((p for p in ('C:/Program Files/Git/bin/sh.exe', 'C:/Program Files/Git/bin/bash.exe') if Path(p).is_file()), shutil.which('sh'))
        if not self.shell:
            self.skipTest('POSIX shell unavailable')

    def run_policy(self, body):
        script = ('. "' + (ROOT / 'tools/w9x_95_ui.sh').as_posix() + '"\n'
                  'key=98765001234554321\nkey_tries=0\nkey_on_screen=0\nwritten=0\n'
                  'W9X_VM_KEY_MAX_MB=64\nw95_last_page=\n'
                  'W9X_VM_RUN="' + self.temp.as_posix() + '"\n'
                  'w9x_vm_private_key() { printf "%s\\n" "$1" >> "$W9X_VM_RUN/input"; }\n' + body)
        return subprocess.run([self.shell, '-c', script], capture_output=True, text=True, encoding='utf-8',
                              env=dict(os.environ, TMP=str(self.temp), TEMP=str(self.temp)))

    def test_unknown_and_busy_never_receive_input(self):
        for role in ('unknown', 'busy', 'not-a-page'):
            r = self.run_policy(f'W9X_VM_PAGE={role}; w9x_vm_95_page_ready; echo ready=$?; w9x_vm_95_input; echo input=$?')
            self.assertIn('ready=1', r.stdout)
            self.assertIn('input=1', r.stdout)
            self.assertFalse((self.temp / 'input').exists())

    def test_coa_is_filled_once_and_kept_out_of_logs(self):
        r = self.run_policy('W9X_VM_PAGE=coa; w9x_vm_95_page_ready && w9x_vm_95_input; echo "$key_tries $key_on_screen"; w9x_vm_95_page_ready; echo again=$?')
        self.assertIn('1 1', r.stdout)
        self.assertIn('again=1', r.stdout)
        inputs = (self.temp / 'input').read_text(encoding='utf-8').splitlines()
        self.assertEqual(len(inputs), 27)
        self.assertEqual(''.join(x for x in inputs if x.isdigit()), '98765001234554321')
        self.assertEqual(inputs.count('home'), 3)
        log = (self.temp / 'command.txt').read_text(encoding='utf-8')
        self.assertNotIn('98765', log)
        self.assertIn('95 input: coa', log)

    def test_copy_limit_applies_to_key_not_finish(self):
        r = self.run_policy('written=128; W9X_VM_PAGE=coa; w9x_vm_95_page_ready; echo coa=$?; W9X_VM_PAGE=restart; w9x_vm_95_page_ready && w9x_vm_95_input')
        self.assertIn('coa=1', r.stdout)
        self.assertEqual((self.temp / 'input').read_text(encoding='utf-8').strip(), 'ret')

    def test_single_edit_uses_complete_oem_form_without_tabs(self):
        r=self.run_policy('W9X_VM_PAGE=coa-single; w9x_vm_95_page_ready && w9x_vm_95_input; echo "$key_tries $key_on_screen"')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertIn('1 1',r.stdout)
        inputs=(self.temp/'input').read_text().splitlines()
        self.assertEqual(inputs[:3],['home','shift-end','backspace'])
        self.assertNotIn('tab',inputs)
        text=''.join({'minus':'-','shift-o':'O','shift-e':'E','shift-m':'M'}.get(x,x) for x in inputs[3:-1])
        self.assertEqual(text,'98765-OEM-0012345-54321')
        self.assertEqual(inputs[-1],'ret')
        self.assertNotIn('98765',(self.temp/'command.txt').read_text())

    def test_single_edit_shares_one_attempt_with_three_field_form(self):
        r=self.run_policy('W9X_VM_PAGE=coa-single; w9x_vm_95_page_ready && w9x_vm_95_input; w95_last_page=; W9X_VM_PAGE=coa; w9x_vm_95_page_ready; echo again=$?')
        self.assertIn('again=1',r.stdout)

    def test_single_edit_requires_oem_shape_and_copy_guard(self):
        for change in ('written=64','key=1234567890'):
            r=self.run_policy(change+'; W9X_VM_PAGE=coa-single; w9x_vm_95_page_ready; echo ready=$?')
            self.assertIn('ready=1',r.stdout)
            self.assertFalse((self.temp/'input').exists())

    def test_owner_uses_separate_fields_and_never_the_key(self):
        r = self.run_policy('W9X_VM_OWNER=Retro; W9X_VM_ORG=USOS; W9X_VM_PAGE=owner; w9x_vm_95_page_ready && w9x_vm_95_input; echo "$key_tries $key_on_screen"')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('0 0', r.stdout)
        inputs = (self.temp / 'input').read_text(encoding='utf-8').splitlines()
        self.assertIn('shift-r', inputs)
        self.assertIn('tab', inputs)
        self.assertFalse(any(x.isdigit() for x in inputs))
        self.assertNotIn('Retro', (self.temp / 'command.txt').read_text(encoding='utf-8'))

    def test_invalid_or_key_as_owner_is_rejected_before_typing(self):
        for assignment in ('W9X_VM_OWNER=$key', "W9X_VM_OWNER='Łukasz'", "W9X_VM_OWNER='Bad;name'"):
            r = self.run_policy(assignment + '; W9X_VM_PAGE=owner; w9x_vm_95_page_ready; echo ready=$?; w9x_vm_95_input; echo input=$?')
            self.assertIn('ready=1', r.stdout)
            self.assertIn('input=1', r.stdout)
            self.assertFalse((self.temp / 'input').exists())

    def test_navigation_is_not_limited_to_five_key_attempts(self):
        r = self.run_policy('for W9X_VM_PAGE in welcome directory setup-type hardware-list communication components computer-options startup-disk copy-ready restart reboot-confirm; do w9x_vm_95_page_ready && w9x_vm_95_input || exit 2; done; echo "keytries=$key_tries"')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('keytries=0', r.stdout)
        self.assertEqual((self.temp / 'input').read_text(encoding='utf-8').splitlines().count('ret'), 11)

    def test_owner_parser_reads_only_the_name_section(self):
        inf = self.temp / 'answer.inf'
        inf.write_bytes(b'[Setup]\r\nName=Wrong\r\n[NameAndOrg]\r\nName="Retro"\r\nOrg="USOS"\r\n[Other]\r\nName=AlsoWrong\r\n')
        r = self.run_policy('w9x_vm_owner_value "' + inf.as_posix() + '" Name; w9x_vm_owner_value "' + inf.as_posix() + '" Org')
        self.assertEqual(r.stdout.splitlines(), ['Retro', 'USOS'])

    def test_owner_preflight_does_not_need_the_vm_local_key_variable(self):
        r = self.run_policy('unset key; W9X_VM_OWNER=Retro; W9X_VM_ORG=USOS; w9x_vm_owner_valid 98765001234554321; echo valid=$?; W9X_VM_OWNER=98765001234554321; w9x_vm_owner_valid 98765001234554321; echo rejected=$?')
        self.assertIn('valid=0', r.stdout)
        self.assertIn('rejected=1', r.stdout)


if __name__ == '__main__':
    unittest.main()
