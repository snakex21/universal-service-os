"""Host tests for the Windows 10/11 native UEFI path helpers (no VM, no disks).

* modern_finalize_selftest.c: WinPE-less simulation of the ESP guard/finalizer
  (tools/windows_modern_uefi_finalize.c) on temporary directories.
* windows_modern_uefi_startup.cmd: the order the guard depends on.
"""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
ZIG = ROOT / 'tools' / 'zig' / 'zig.exe'


class ModernFinalizeSimulation(unittest.TestCase):
    def test_guard_restores_the_stick_and_finds_the_target(self):
        if os.name != 'nt':
            raise unittest.SkipTest('Win32 simulation')
        with tempfile.TemporaryDirectory(prefix='usos-finalize-') as temp:
            exe = Path(temp) / 'selftest.exe'
            env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(ROOT / 'tools/cache/zig-global'), ZIG_LOCAL_CACHE_DIR=str(Path(temp) / 'cache'))
            subprocess.run([str(ZIG), 'cc', '-target', 'x86_64-windows-gnu', '-O1', '-nostdlib', '-fno-stack-protector', '-fno-builtin',
                            '-I' + str(ROOT / 'tools/zig/lib/libc/include/any-windows-any'),
                            str(ROOT / 'tools/tests/windows_native/modern_finalize_selftest.c'),
                            '-Wl,--entry,test_entry', '-lkernel32', '-ladvapi32', '-o', str(exe)], check=True, env=env)
            work = Path(temp) / 'work'
            work.mkdir()
            result = subprocess.run([str(exe)], capture_output=True, text=True, env=dict(os.environ, USOS_FINALIZE_WORK=str(work)))
            print(result.stdout)
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            self.assertIn('[RESULT] PASS', result.stdout)
            self.assertNotIn('[FAIL]', result.stdout)


class ModernStartupOrder(unittest.TestCase):
    def test_setup_runs_between_the_guard_steps_with_noreboot(self):
        script = (ROOT / 'tools/windows_modern_uefi_startup.cmd').read_text()
        before = script.index('usos-modern-finalize.exe" before')
        run = script.index('usos-modern-finalize.exe" run-from "%USOS_SETUP%" /noreboot')
        after = script.index('usos-modern-finalize.exe" after')
        reboot = script.index('wpeutil reboot')
        self.assertLess(before, run)
        self.assertLess(run, after)
        self.assertLess(after, reboot)
        # A failed finalizer never reboots into a half-fixed disk.
        self.assertIn('if not "%USOS_FINALIZE_RESULT%"=="0" exit /b %USOS_FINALIZE_RESULT%', script)
        # User drivers reach WinPE (drvload) and the target (DriverPaths).
        self.assertIn('drvload "%%I"', script)
        self.assertIn('usos-unattend-drivers.exe" "%USOS_ANSWER%"', script)
        # No automation beyond the user's own answer file.
        for forbidden in ('/quiet', 'DiskConfiguration', '/imageindex'):
            self.assertNotIn(forbidden, script)

    def test_iso_startup_dispatches_the_modern_uefi_flag(self):
        script = (ROOT / 'tools/windows_iso_startup.cmd').read_text()
        self.assertIn('if exist "%~dp0usos-modern-uefi.flag" goto modern_uefi', script)
        self.assertIn('call "%~dp0usos-modern-uefi.cmd"', script)

    def test_finalizer_sets_the_system_store_away_from_the_stick(self):
        source = (ROOT / 'tools/windows_modern_uefi_finalize.c').read_text()
        self.assertIn('/sysstore', source)
        self.assertIn('internal_esps(before.disk)', source)
        # The stick is cleaned only after the target's boot files are verified.
        self.assertLess(source.index('target ESP has EFI\\\\Microsoft\\\\Boot\\\\bootmgfw.efi and BCD'), source.index('int clean = restore_stick'))
        # An ESP is created only in unallocated space; nothing is shrunk.
        self.assertIn('create partition efi size=260', source)
        self.assertNotIn('shrink', source.lower().replace('never by shrinking', ''))


if __name__ == '__main__':
    unittest.main()
