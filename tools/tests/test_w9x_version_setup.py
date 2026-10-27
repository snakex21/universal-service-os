"""Host regression for Win9x version APIs and durable USOSRES /setup exits.

Compiles the actual production C with fake OS/registry/display APIs. No VM,
display change, child installer or host registry access is performed.
"""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'tools/tests'))
import depguard

OUT = ROOT/'artifacts/w9x-version-setup'


class VersionAndLogging(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        zig = depguard.require_zig()
        OUT.mkdir(parents=True, exist_ok=True)
        cls.env = dict(os.environ, TEMP=str(OUT), TMP=str(OUT),
                       ZIG_GLOBAL_CACHE_DIR=str(ROOT/'tools/cache/zig-global'),
                       ZIG_LOCAL_CACHE_DIR=str(OUT/'zig-cache'))
        cls.exe = OUT/'display_setup_test.exe'
        subprocess.run([str(zig), 'cc', '-target', 'x86_64-windows-gnu', '-Os', '-nostdlib',
                        '-fno-builtin', '-fno-stack-protector',
                        '-isystem', str(zig.parent/'lib/libc/include/any-windows-any'),
                        str(ROOT/'tools/tests/display_setup_test.c'), '-Wl,--entry,entry',
                        '-lkernel32', '-ladvapi32', '-o', str(cls.exe)], env=cls.env, check=True)

    def run_case(self, case, expected_code, message, profile=None):
        folder = OUT/('case-'+str(case))
        folder.mkdir(exist_ok=True)
        exe = folder/'display_setup_test.exe'
        shutil.copyfile(self.exe, exe)
        if profile is not None:
            (folder/'DISPLAY.TXT').write_bytes(profile)
        log = folder/'USOSRES.LOG'
        # Append to existing evidence on repeat runs, never discard old logs.
        start = log.stat().st_size if log.exists() else 0
        result = subprocess.run([str(exe), str(case)], env=self.env, timeout=15)
        self.assertEqual(result.returncode, expected_code, case)
        self.assertTrue(log.is_file(), case)
        data = log.read_bytes()[start:]
        self.assertTrue(data.startswith(b'DISPLAY /setup begin\r\n'), data)
        self.assertIn(message.encode(), data)
        self.assertTrue(data.endswith(f'DISPLAY /setup exit={expected_code}\r\n'.encode()), data)
        return data

    def test_six_systems_use_extended_build_not_legacy_high_word(self):
        for case, name, build in ((0, '95 RTM', 950), (1, '95 OSR1', 950),
                                  (2, '95 OSR2', 1111), (3, '98 FE', 1998),
                                  (4, '98 SE', 2222), (5, 'ME', 3000)):
            with self.subTest(system=name):
                data = self.run_case(case, 0 if case<5 else 2,
                                     'already completed' if case<5 else 'requires 95 (950 / OSR2) or 98 (1998 / 2222)')
                self.assertIn(f'build={build}\r\n'.encode(), data)

    def test_refused_os_and_missing_markers_always_log_exit_two(self):
        for case, reason in ((6, 'GetVersionExA failed'), (7, 'requires 95 (950 / OSR2)'),
                             (8, 'requires 95 (950 / OSR2)'), (9, 'requires 95 (950 / OSR2)'),
                             (10, 'PHASE1.OK absent'), (11, 'VLATE.OK absent'),
                             (12, 'FIRSTBT.ON absent')):
            with self.subTest(case=case):
                self.run_case(case, 2, reason)

    def test_osr2_display_boundary_without_vesalate(self):
        # OSR2 stages no VESALATE.BAT: VESA95.BAT's one attempt (OK or BAD).
        for case, code, reason, build in ((19, 2, 'VESA95 display boundary absent', 1111),
                                          (20, 0, 'already completed', 1212),
                                          (21, 0, 'already completed', 1214)):
            with self.subTest(case=case):
                data = self.run_case(case, code, reason)
                self.assertIn(f'build={build}\r\n'.encode(), data)
                self.assertNotIn(b'VLATE.OK absent', data)

    def test_98_setup_mode_under_the_coordinator(self):
        # 98 FE / 98 SE: no VESALATE / VESA95 (Setup binds the VESA driver),
        # PHASE1.OK and FIRSTBT.ON still required; 4.10 only with 98 builds.
        for case, code, reason, build in ((22, 0, 'already completed', 1998),
                                          (23, 0, 'already completed', 2222),
                                          (24, 2, 'FIRSTBT.ON absent', 1998),
                                          (25, 2, 'requires 95 (950 / OSR2) or 98 (1998 / 2222)', 1111)):
            with self.subTest(case=case):
                data = self.run_case(case, code, reason)
                self.assertIn(f'version=4.10 build={build}\r\n'.encode(), data)
                self.assertNotIn(b'VESA95 display boundary absent', data)

    def test_other_early_exits_and_vbe_failure_are_logged(self):
        for case, code, reason, profile in (
                (13, 0, 'request absent or unreadable', None),
                (14, 1, 'request read failed or invalid length', b''),
                (15, 0, 'Windows Setup still running', b'autoxauto\r\n'),
                (16, 1, 'request read failed or invalid length', b'x'*64),
                (17, 1, 'invalid request', b'bad\r\n'),
                (18, 1, 'no fresh VBE/INF memory evidence', b'autoxauto\r\n')):
            with self.subTest(case=case):
                self.run_case(case, code, reason, profile)


if __name__ == '__main__':
    unittest.main(verbosity=2)
