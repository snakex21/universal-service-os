"""Offline regressions: run only Setup path selection, NEVER Setup/finalizer/reboot."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'tools/windows7_modern_startup.cmd'


class StartupSelection(unittest.TestCase):
    def run_selector(self, external=False, check_exists=False, source_setup=False):
        script = SCRIPT.read_text()
        # Deliberately stop before any servicing helper, Setup, or finalizer.
        stop = '"%~dp0usos-win7-kmdf-repair.exe"' if check_exists else 'if not exist "%USOS_SETUP%" ('
        self.assertEqual(1, script.count(stop))
        prefix = script.split(stop, 1)[0]
        self.assertNotIn('run-from', prefix)
        self.assertNotIn('wpeutil', prefix)
        scratch = ROOT / 'zig-out/pe-selector-tests'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='usos-pe-selector-', dir=scratch) as temp:
            directory = Path(temp)
            harness = directory / 'select.cmd'
            harness.write_text(prefix + '\necho SELECTED=%USOS_SETUP%\necho INSTALL=%USOS_INSTALL%\nexit /b 0\n')
            if external:
                (directory / 'usos-external-pe10.flag').write_text('1\n')
            source = str(directory / 'selected Win7')
            if source_setup:
                setup = Path(source) / 'sources/setup.exe'
                setup.parent.mkdir(parents=True)
                setup.write_bytes(b'path-selection-only')
            install = source + r'\sources\install.wim'
            env = dict(os.environ, USOS_SOURCE=source, USOS_INSTALL=install,
                       USOS_SETUP='inherited-wrong-setup.exe')
            result = subprocess.run(['cmd', '/d', '/c', str(harness)],
                                    env=env, capture_output=True, text=True)
            return result, source, install

    def test_hybrid_keeps_selected_iso_setup_without_donor_flag(self):
        result, source, install = self.run_selector()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('SELECTED=' + source + r'\sources\setup.exe', result.stdout)
        self.assertIn('INSTALL=' + install, result.stdout)

    def test_external_pe10_keeps_setup_with_selected_iso_resources(self):
        result, source, install = self.run_selector(external=True, source_setup=True, check_exists=True)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('SELECTED=' + source + r'\sources\setup.exe', result.stdout)
        self.assertIn('INSTALL=' + install, result.stdout)

    def test_external_pe10_missing_source_setup_does_not_fall_back_to_donor(self):
        result, _, _ = self.run_selector(external=True, check_exists=True)
        self.assertEqual(1, result.returncode, result.stderr)
        self.assertNotIn('SELECTED=', result.stdout)

    def test_modern_pe_preserves_its_drivers_and_always_passes_target_driver_paths(self):
        script = SCRIPT.read_text()
        self.assertNotIn('drvload', script.lower())
        self.assertIn('set "USOS_NEED_UNATTEND=1"', script)
        self.assertNotIn('SHA-2 package queued', script)

    def test_package_answer_path_reaches_driver_merger_after_cmd_block(self):
        script=SCRIPT.read_text()
        start=script.index('set "USOS_ANSWER=-"')
        stop=script.index('copy /y "%~dp0usos-win7-wrapper.bin"')
        fragment=script[start:stop]
        fragment=fragment.replace('"%~dp0usos-win7-unattend.exe"', 'echo PACKAGE-MERGER')
        fragment=fragment.replace('"%~dp0usos-unattend-drivers.exe"', 'echo DRIVER-MERGER')
        scratch=ROOT/'zig-out/pe-selector-tests';scratch.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as temp:
            folder=Path(temp);(folder/'usos-nvme-packages.flag').write_text('1')
            harness=folder/'merge.cmd';harness.write_text('@echo off\n'+fragment+'\nexit /b 0\n')
            result=subprocess.run(['cmd','/d','/c',str(harness)],capture_output=True,text=True)
            self.assertEqual(0,result.returncode,result.stdout)
            merger=next(line for line in result.stdout.splitlines() if line.startswith('DRIVER-MERGER'))
            self.assertIn(str(folder/'usos-nvme-unattend.xml'),merger)

    def test_missing_setup_stops_before_any_helper(self):
        result, _, _ = self.run_selector(check_exists=True)
        self.assertEqual(1, result.returncode, result.stderr)
        self.assertIn('No fallback', result.stdout)
        self.assertNotIn('SELECTED=', result.stdout)

    def test_finalizer_and_user_choices_remain_guarded(self):
        script = SCRIPT.read_text()
        self.assertIn('run-from "%USOS_SETUP%" /noreboot /installfrom:"%USOS_INSTALL%"', script)
        self.assertLess(script.index('run-from'), script.index('after-modern'))
        self.assertIn('after-modern\nif errorlevel 1 exit /b 1', script)
        self.assertLess(script.index('after-modern'), script.index('wpeutil reboot'))
        for forbidden in ('/quiet', '/auto ', 'SkipMachineOOBE', 'SkipUserOOBE', 'DiskConfiguration', '/imageindex'):
            self.assertNotIn(forbidden, script)
        finalizer = (ROOT / 'tools/windows7_uefi_finalize.c').read_text()
        self.assertIn('version->dwFileVersionMS==0x00060001', finalizer)
        self.assertIn('if(modern){if(!win7_loader(a))continue;}', finalizer)
        self.assertIn('if(count!=1)', finalizer)

    def test_native_boot_and_install_sources_are_separate(self):
        native = (ROOT / 'src/platform/uefi/windows_native_iso.zig').read_text()
        self.assertIn('.file = if (external_pe10) &state.donor else source', native)
        # Boot files are read by addBootFiles from the chosen boot ISO.
        self.assertIn('try addBootFiles(&boot_iso, volume, &owned, progress)', native)
        self.assertIn('udf.openPath(boot_iso, boot_path', native)
        self.assertIn('udf.readNodeAt(boot_iso, &node', native)
        # usos-source.ini always describes the selected install ISO (never the
        # PE10 donor) in its own folder; Vista shares this path since the
        # Vista SP2 x64 -> external PE10 route was added.
        self.assertIn('source.size(), if (vista) "Windows Vista" else "Windows 7", name)', native)
        self.assertNotIn('donor.size()', native)
        self.assertIn('if (external_pe10) try volume.add("usos-external-pe10.flag"', native)
        self.assertNotIn('"usos-stock-win7.flag"', native)

    def test_native_reader_state_has_owned_aligned_stable_storage(self):
        native = (ROOT / 'src/platform/uefi/windows_native_iso.zig').read_text()
        # inspect, start, and the Windows 10/11 inspectModern/startModern.
        self.assertEqual(4, native.count('uefi.pool_allocator.create(BootState)'))
        self.assertEqual(4, native.count('defer uefi.pool_allocator.destroy(state)'))
        self.assertNotIn('allocatePool(.loader_data, @sizeOf(BootState))', native)
        self.assertIn('.catalog = &state.catalog, .file = &state.source', native)
        self.assertIn('.catalog = &self.state.catalog, .file = &self.state.donor', native)
        # The donor is reopened in the folder it was resolved from (managed or legacy).
        self.assertIn('context.probeDonor(inspection.donor_directory, inspection.donor_name.slice())', native)
        self.assertIn('error.Windows10PeDonorChanged', native)


if __name__ == '__main__':
    unittest.main()
