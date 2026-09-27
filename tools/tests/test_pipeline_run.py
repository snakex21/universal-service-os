"""M3: tools/pipeline/run.sh (the micro-Linux pipeline) on the host.

Runs the real run.sh with a POSIX sh (Git sh on Windows):
  - profile resolution from the legacy action and the usos.plan_profile token,
  - step dispatch (with stand-in step files, so no script touches a disk),
  - the WORK plan check on byte-exact install-state.ini files,
  - agreement of the shell tables with src/catalog/os_profiles.zig (through
    the profile_def and route rows of src/flow/testdata/routing_golden.tsv),
  - the real step files define exactly their usos_step_<id>_run function.
No VM, no disk.
"""
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
RUN = ROOT / 'tools' / 'pipeline' / 'run.sh'
STEPS = ROOT / 'tools' / 'pipeline' / 'steps'
GOLDEN = ROOT / 'src' / 'flow' / 'testdata' / 'routing_golden.tsv'


def shell():
    for candidate in ('C:/Program Files/Git/bin/sh.exe', 'C:/Program Files/Git/bin/bash.exe'):
        if os.path.exists(candidate):
            return candidate
    found = shutil.which('sh')
    if not found:
        raise unittest.SkipTest('no POSIX sh available')
    return found


def sh(script, env=None, check=True):
    full = dict(os.environ, **(env or {}))
    result = subprocess.run([shell(), '-c', script], capture_output=True, text=True, env=full)
    if check and result.returncode != 0:
        raise AssertionError(f'rc={result.returncode}\n{result.stdout}\n{result.stderr}')
    return result


def golden_rows(kind):
    return [line.split('\t') for line in GOLDEN.read_text(encoding='utf-8').splitlines() if line.startswith(kind + '\t')]


class Pipeline(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.steps = self.tmp / 'pipeline' / 'steps'
        self.steps.mkdir(parents=True)
        for step, name in (('100', 'nt5_staging'), ('150', 'nt5_resume'), ('500', 'windows_pe_bios_request')):
            (self.steps / f'{step}_{name}.sh').write_text(
                f'usos_step_{step}_run() {{ printf "RAN {step} action=%s\\n" "$LEGACY_ACTION"; }}\n', encoding='utf-8')
        self.efi = self.tmp / 'efi'

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_pipeline(self, action, token='', uefi=False):
        efi = self.efi if uefi else self.tmp / 'no-efi'
        if uefi:
            self.efi.mkdir(exist_ok=True)
        script = (f'. "{RUN.as_posix()}"; LEGACY_ACTION="{action}"; '
                  f'usos_pipeline_resolve_action "$LEGACY_ACTION" "{token}" || {{ echo RESOLVE-FAIL; exit 3; }}; '
                  'usos_pipeline_run || { echo RUN-FAIL; exit 4; }; echo "CONTINUE profile=$USOS_PLAN_PROFILE steps=$USOS_PLAN_STEPS"')
        return sh(script, {'USOS_PIPELINE_DIR': (self.tmp / 'pipeline').as_posix(), 'USOS_PIPELINE_EFI_DIR': efi.as_posix()}, check=False)

    def test_actions_map_to_profiles_and_steps(self):
        cases = [
            ('xp-staging', '', False, 'profile=nt5-staging steps=100', 'RAN 100'),
            ('xp-staging', '', True, 'profile=xp-x86-sp3-uefi-csm steps=100', 'RAN 100'),
            ('windows2000-staging', '', False, 'profile=nt5-staging steps=100', 'RAN 100 action=windows2000-staging'),
            ('xp-resume', '', False, 'profile=nt5-resume steps=150', 'RAN 150'),
            ('windows7-iso', '', False, 'profile=windows-pe-bios-iso steps=500 200', 'RAN 500'),
            ('windows-vista-iso', '', False, 'profile=windows-pe-bios-iso steps=500 200', 'RAN 500'),
            ('xp-staging', 'nt5-staging', True, 'profile=nt5-staging steps=100', 'RAN 100'),
            ('xp-staging', 'xp-x86-sp3-uefi-csm', False, 'profile=xp-x86-sp3-uefi-csm steps=100', 'RAN 100'),
            ('windows7-iso', 'windows-pe-bios-iso', False, 'profile=windows-pe-bios-iso steps=500 200', 'RAN 500'),
        ]
        for action, token, uefi, resolved, ran in cases:
            with self.subTest(action=action, token=token, uefi=uefi):
                out = self.run_pipeline(action, token, uefi)
                self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
                self.assertIn('[PIPELINE] ' + resolved + ' source=' + ('cmdline' if token else 'action') + chr(10), out.stdout)
                self.assertIn(ran, out.stdout)
        # windows-pe-bios-iso continues into the WORK body after its request.
        out = self.run_pipeline('windows7-iso')
        self.assertIn('[PIPELINE] step 200 work_prepare', out.stdout)
        self.assertIn('CONTINUE profile=windows-pe-bios-iso', out.stdout)

    def test_unknown_actions_and_mismatched_tokens_are_refused(self):
        for action, token in (('hardware', ''), ('bogus', ''), ('xp-staging', 'windows-pe-bios-iso'),
                              ('windows7-iso', 'nt5-staging'), ('xp-resume', 'iso-work-chainload')):
            with self.subTest(action=action, token=token):
                out = self.run_pipeline(action, token)
                self.assertEqual(out.returncode, 3, out.stdout + out.stderr)
                self.assertNotIn('RAN', out.stdout)

    def test_a_missing_step_file_is_refused_before_anything_runs(self):
        (self.steps / '100_nt5_staging.sh').unlink()
        out = self.run_pipeline('xp-staging')
        self.assertEqual(out.returncode, 3)
        self.assertIn('step 100 missing', out.stdout)

    def check_state(self, lines, method):
        state = self.tmp / 'install-state.ini'
        text = ''.join(line + '\r\n' for line in lines).encode('utf-8')
        state.write_bytes(text + b'\n' * (2048 - len(text)))
        script = (f'usos_ui_declare_stages() {{ echo "DECLARED $1"; }}; . "{RUN.as_posix()}"; '
                  f'usos_pipeline_check_work_plan "{state.as_posix()}" "{method}" && echo "OK profile=$USOS_PLAN_PROFILE"')
        return sh(script, check=False)

    def plan_state(self, system, image):
        return [row[3] for row in golden_rows('plan_state') if row[1] == system and row[2] == image]

    def test_work_plan_from_the_menu_is_accepted(self):
        base = ['phase=prepare-requested', 'selected_iso=Systems/Windows/Windows 10/Images/a.iso', 'selected_unattend=none']
        out = self.check_state(base + ['selected_method=chainload', 'selected_system=windows-10'] + self.plan_state('windows-10', 'iso'), 'chainload')
        self.assertEqual(out.returncode, 0, out.stdout)
        self.assertIn('OK profile=iso-work-chainload', out.stdout)
        self.assertNotIn('DECLARED', out.stdout)  # default five stages: renderer keeps its own rows
        out = self.check_state(base + ['selected_method=wimboot'] + self.plan_state('ubuntu', 'wim'), 'wimboot')
        self.assertIn('OK profile=wim-wimboot', out.stdout)

    def test_older_requests_without_a_plan_are_accepted(self):
        out = self.check_state(['phase=prepare-requested', 'selected_method=iso'], 'iso')
        self.assertEqual(out.returncode, 0)
        self.assertIn('older menu', out.stdout)

    def test_inconsistent_plans_are_refused(self):
        plan = self.plan_state('windows-10', 'iso')
        for lines, method in ((plan, 'wimboot'),
                              (['plan_version=2', 'plan_profile=iso-work-chainload'], 'chainload'),
                              (['plan_version=1'], 'chainload'),
                              (['plan_version=1', 'plan_profile=nt5-staging'], 'chainload')):
            with self.subTest(lines=lines, method=method):
                out = self.check_state(['phase=prepare-requested'] + lines, method)
                self.assertNotEqual(out.returncode, 0, out.stdout)

    def test_custom_stage_rows_are_declared(self):
        out = self.check_state(['plan_version=1', 'plan_profile=vhd-vhdboot', 'plan_stages=One|Two'], 'vhdboot')
        self.assertIn('DECLARED One|Two', out.stdout)

    def test_shell_tables_agree_with_os_profiles(self):
        text = RUN.read_text(encoding='utf-8')
        defined = {row[1]: row for row in golden_rows('profile_def')}
        steps_block = text[text.index('usos_pipeline_steps() {'):text.index('usos_pipeline_step_name() {')]
        shell_profiles = set(re.findall(r'[a-z0-9]+(?:-[a-z0-9]+)+', steps_block))
        # Not menu profiles: the Core's XP resume and the Vista UEFI disk
        # preparation that runs before the vista wimboot profile.
        self.assertEqual(shell_profiles - set(defined), {'nt5-resume', 'vista-uefi-disk'})
        # Every micro-Linux WORK profile is in the step table, with the method
        # the menu persists for it (backend method from the route rows).
        work = {pid for pid, row in defined.items() if row[3] == 'micro_linux'}
        self.assertTrue(work <= shell_profiles, work - shell_profiles)
        backend_method = {row[5]: row[6] for row in golden_rows('route') if len(row) > 6}
        for pid in work:
            out = sh(f'. "{RUN.as_posix()}"; usos_pipeline_work_method {pid}')
            self.assertEqual(out.stdout, backend_method[defined[pid][2]], pid)

    def test_command_line_tokens_name_known_profiles(self):
        known = {row[1] for row in golden_rows('profile_def')} | {'nt5-resume'}
        for source in ('src/platform/bios/linux_boot_params.zig', 'src/platform/uefi/xp_preparation.zig'):
            text = (ROOT / source).read_text(encoding='utf-8')
            tokens = set(re.findall(r'plan_profile=([a-z0-9-]+)', text))
            tokens |= set(re.findall(r'=> "([a-z0-9]+(?:-[a-z0-9]+)+)"', text[text.find('pub fn planProfile'):]) if 'pub fn planProfile' in text else [])
            self.assertTrue(tokens, source)
            self.assertEqual(tokens - known, set(), source)
            for token in tokens:
                out = sh(f'. "{RUN.as_posix()}"; usos_pipeline_steps {token}', check=False)
                self.assertEqual(out.returncode, 0, token)

    def test_step_files_define_their_run_function(self):
        for path in sorted(STEPS.glob('*.sh')):
            step = path.name.split('_', 1)[0]
            name = path.stem.split('_', 1)[1]
            out = sh(f'. "{RUN.as_posix()}"; usos_pipeline_step_name {step}')
            self.assertEqual(out.stdout, name, path.name)
            self.assertEqual(re.findall(r'^(usos_step_\w+)\(\)', path.read_text(encoding='utf-8'), re.M), [f'usos_step_{step}_run'])
            sh(f'. "{path.as_posix()}"; command -v usos_step_{step}_run >/dev/null')


if __name__ == '__main__':
    unittest.main()
