"""NT 4.0 driver builds (AHCINT AHCI_NT4, usosrst NT4), host-only, no
Microsoft files: the pinned binaries are checked against the export-name
lists of the NT 4.0 RTM (1381.1) and SP6a (1381.335) kernels, HALs and
ScsiPort in tools/tests/data (check_nt4_driver_imports.py --dump-exports).
"""
from __future__ import annotations
from pathlib import Path
import hashlib, json, struct, sys, unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT / 'tools' / 'nt4'))
import check_nt4_driver_imports as nt4  # noqa: E402
from pe_nt4_version import pe_checksum, set_nt4  # noqa: E402

AHCINT = ROOT / 'tools/vendor/ahcint/1.3.0.0-usos4'
USOSRST = ROOT / 'tools/w2k/usosrst'
NT4_BINARIES = [AHCINT / 'bin/NT4/i386/ahcint.sys', USOSRST / 'bin/nt4/i386/usosrst.sys']
FIXTURES = [HERE / 'data/nt4rtm_exports.txt', HERE / 'data/nt4sp6a_exports.txt']


def tables(path: Path) -> dict:
    return nt4.parse(path.read_text())


class Fixtures(unittest.TestCase):
    def test_export_lists(self):
        for f in FIXTURES:
            t = tables(f)
            self.assertEqual(sorted(t), sorted(nt4.FILES), f.name)
            # Names only: no binary bytes, every line printable ASCII.
            self.assertTrue(f.read_bytes().isascii())
            for want in ('ScsiPortInitialize', 'ScsiPortGetDeviceBase'):
                self.assertIn(want, t['scsiport.sys'])
            for want in ('KeRegisterBugCheckCallback', 'MmMapIoSpace', 'KeNumberProcessors', 'KiBugCheckData'):
                self.assertIn(want, t['ntoskrnl.exe'])
                self.assertIn(want, t['ntkrnlmp.exe'])
            # The routines usosrst 1.4 got from Windows 2000 are not there.
            for absent in ('KeQueryInterruptTime', 'KeQueryActiveProcessors', 'IoRegisterLastChanceShutdownNotification'):
                self.assertNotIn(absent, t['ntoskrnl.exe'])
            for hal in nt4.HALS:
                for want in ('HalReturnToFirmware', 'HalQueryRealTimeClock', 'HalSetRealTimeClock', 'HalGetBusData'):
                    self.assertIn(want, t[hal], (f.name, hal))


class Binaries(unittest.TestCase):
    def test_imports_resolve_on_rtm_and_sp6a(self):
        for f in FIXTURES:
            report = nt4.check(tables(f), NT4_BINARIES)
            for name, r in report.items():
                self.assertEqual(r['missing'], [], (f.name, name))
                self.assertEqual(r['subsystem'], '4.00', name)
            self.assertEqual(report['ahcint.sys']['modules'], ['ntoskrnl.exe', 'scsiport.sys'])
            self.assertEqual(report['usosrst.sys']['modules'], ['hal.dll', 'ntoskrnl.exe'])

    def test_checker_catches_2000_only_imports(self):
        # The pinned Windows 2000 usosrst imports three 2000-only routines.
        r = nt4.check(tables(FIXTURES[1]), [USOSRST / 'bin/i386/usosrst.sys'])['usosrst.sys']
        self.assertEqual(r['missing'], [['ntoskrnl.exe', 'IoRegisterLastChanceShutdownNotification'],
                                        ['ntoskrnl.exe', 'KeQueryActiveProcessors'],
                                        ['ntoskrnl.exe', 'KeQueryInterruptTime']])

    def test_pe_header(self):
        for path in NT4_BINARIES:
            b = path.read_bytes()
            p = struct.unpack_from('<I', b, 60)[0]
            self.assertEqual(struct.unpack_from('<H', b, p + 4)[0], 0x14c)
            self.assertEqual(struct.unpack_from('<HH', b, p + 24 + 40), (4, 0))   # OS version
            self.assertEqual(struct.unpack_from('<HH', b, p + 24 + 48), (4, 0))   # subsystem version
            self.assertEqual(struct.unpack_from('<H', b, p + 24 + 68)[0], 1)       # native
            self.assertEqual(struct.unpack_from('<I', b, p + 24 + 64)[0], pe_checksum(b, p + 24 + 64))
            self.assertEqual(set_nt4(b), b)                                         # idempotent
        self.assertIn(b'usosrst 1.4-nt4', NT4_BINARIES[1].read_bytes())

    def test_pins_and_sources(self):
        for folder, add in ((AHCINT, ['build-nt4.cmd', 'src/NT4WDK/sources', 'src/NT4WDK/makefile', 'bin/NT4/i386/ahcint.sys',
                                      'patches/0005-nt4-wdk-build.patch']),
                            (USOSRST, ['build-nt4.cmd', 'bin/nt4/i386/usosrst.sys'])):
            pins = json.loads((folder / 'manifest.json').read_text())
            for rel in add:
                self.assertIn(rel, pins['files'])
            for rel, digest in pins['files'].items():
                self.assertEqual(hashlib.sha256((folder / rel).read_bytes()).hexdigest(), digest, rel)
        sources = (AHCINT / 'src/NT4WDK/sources').read_text()
        self.assertIn('-DAHCI_NT4 -DAHCI_NT4_WDK', sources)
        self.assertIn('SUBSYSTEM_VERSION=4.00', sources)
        main = (AHCINT / 'src/ahcimain.c').read_text()
        # NT 4.0 ScsiPortInitialize refuses a HwInitializationDataSize above 0x4C.
        self.assertIn('#ifdef AHCI_NT4_WDK', main)
        self.assertIn('FIELD_OFFSET(HW_INITIALIZATION_DATA, HwAdapterControl)', main)
        rst = (USOSRST / 'src/usosrst.c').read_text()
        for want in ('#ifdef USOSRST_NT4', 'RedirectKernelRestart', 'SharedUserData->InterruptTime', 'KeNumberProcessors'):
            self.assertIn(want, rst)
        for cmd in (AHCINT / 'build-nt4.cmd', USOSRST / 'build-nt4.cmd'):
            self.assertIn('pe_nt4_version.py', cmd.read_text())
        self.assertIn('-DUSOSRST_NT4', (USOSRST / 'build-nt4.cmd').read_text())


if __name__ == '__main__':
    unittest.main()
