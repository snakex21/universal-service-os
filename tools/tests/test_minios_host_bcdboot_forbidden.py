# SPDX-License-Identifier: GPL-3.0-or-later
"""Negative entry-point tests; no image, registry hive or disk API is opened."""
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/minios'))
import bcdboot_reference as reference
from test_minios_host_dism_executor import powershell


class Tests(unittest.TestCase):
    def test_python_entry_refuses_before_inputs_outputs_or_process(self):
        with patch.object(reference, 'accepted', side_effect=AssertionError('input opened')), \
             patch.object(reference.native, 'execute', side_effect=AssertionError('process started')):
            for args in (None, SimpleNamespace(), SimpleNamespace(library_only=True)):
                with self.assertRaisesRegex(ValueError, 'HOST_BCDBOOT_FORBIDDEN'):
                    reference.run(args)

    def test_retired_powershell_entry_and_dot_sourcing_always_refuse(self):
        script = str(ROOT / 'tools/tests/minios_bcdboot_reference.ps1').replace("'", "''")
        for prefix, suffix in (('&', ''), ('.', ''), ('&', " -Workspace 'absent' -ReferenceJob 'absent' -ReferenceJobSha256 'invalid'")):
            powershell("$blocked=$false; try { " + prefix + " '" + script + "'" + suffix +
                       " } catch { if($_.Exception.Message -notmatch 'HOST_BCDBOOT_FORBIDDEN'){throw}; $blocked=$true }; "
                       "if(-not $blocked){throw 'entry was reachable'}")

    def test_permanent_dispatch_guard_survives_temporary_gate_removal(self):
        script = str(ROOT / 'tools/minios/host_dism_executor.ps1').replace("'", "''")
        powershell(". '" + script + "' -LibraryOnly\n"
                   "function Assert-HostDismMutationAvailable {}\n"
                   "$blocked=$false; try {Invoke-HostDismMutation -Operation Bcdboot} catch {"
                   "if($_.Exception.Message -notmatch 'HOST_BCDBOOT_FORBIDDEN'){throw};$blocked=$true};"
                   "if(-not $blocked){throw 'permanent guard bypassed'}")

    def test_native_process_refuses_before_log_creation_or_process_launch(self):
        native = str(ROOT / 'tools/minios/host_dism_bounded_process.cs').replace("'", "''")
        powershell("Add-Type -Path '" + native + "'\n" + r'''
        foreach($exe in @('bcdboot','BCDBOOT.EXE','C:\absent\bcdboot.exe')) {
            $blocked=$false
            try {[MiniOsHostDismProcess]::Run($exe,@('/s','S:'),'absent\out','absent\err','',1024,1,'absent')}
            catch {if($_.Exception.Message -notmatch 'HOST_BCDBOOT_FORBIDDEN'){throw};$blocked=$true}
            if(-not $blocked){throw 'native process reached'}
        }
        ''')

    def test_runner_has_no_host_bcdboot_invocation(self):
        source = (ROOT / 'tools/minios/host_dism_run.ps1').read_text()
        self.assertNotIn('$bcdboot', source)
        self.assertNotIn('bcdboot.exe', source.lower())
        self.assertIn("$result.bcdboot_status='permanently_forbidden'", source)


if __name__ == '__main__':
    unittest.main()
