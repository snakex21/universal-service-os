"""usosnvme (tools/nt/usosnvme): the USOS NVMe SCSI miniport for NT 3.1 to
Server 2003 x86. Every committed binary's imports resolve on its NT version
(export-name fixtures, no Microsoft file needed), the PE versions match, and
the source keeps the per-version ScsiPort rules."""
from pathlib import Path
import sys, unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_nt52_driver_imports import pe  # noqa: E402
from check_nt4_driver_imports import parse  # noqa: E402

DRV = ROOT / 'tools/nt/usosnvme'
SRC = (DRV / 'src/usosnvme.c').read_text(encoding='latin-1')
DATA = ROOT / 'tools/tests/data'


def imports(variant):
    return pe(DRV / f'bin/{variant}/i386/usosnvme.sys')[1]


def pe_version(variant):
    b = (DRV / f'bin/{variant}/i386/usosnvme.sys').read_bytes()
    off = int.from_bytes(b[0x3C:0x40], 'little') + 24
    return (int.from_bytes(b[off + 48:off + 50], 'little'), int.from_bytes(b[off + 50:off + 52], 'little'))


class Imports(unittest.TestCase):
    def check(self, variant, fixture, pairs):
        tables = parse((DATA / fixture).read_text(encoding='utf-8'))
        for kernel, hal in pairs:
            view = {'ntoskrnl.exe': tables[kernel], 'hal.dll': tables[hal], 'scsiport.sys': tables['scsiport.sys']}
            missing = [f'{m}!{n}' for m, n in imports(variant) if n not in view[m.lower()]]
            self.assertEqual(missing, [], f'{variant} on {fixture} {kernel}')

    def test_nt4(self):
        for fx in ('nt4rtm_exports.txt', 'nt4sp6a_exports.txt'):
            self.check('NT4', fx, (('ntoskrnl.exe', 'hal.dll'), ('ntkrnlmp.exe', 'halmps.dll')))

    def test_nt35x(self):
        for fx in ('nt351_exports.txt', 'nt35_exports.txt'):
            self.check('NT351', fx, (('ntoskrnl.exe', 'hal.dll'), ('ntkrnlmp.exe', 'halmps.dll')))

    def test_nt31(self):
        self.check('NT31', 'nt31_exports.txt', (('ntoskrnl.exe', 'hal.dll'), ('ntkrnlmp.exe', 'hal.dll')))

    def test_no_crt(self):
        # NT 3.1 exports neither memset nor memcpy; no build may import them.
        for v in ('2KXP', 'NT4', 'NT351', 'NT31'):
            names = {n for _, n in imports(v)}
            self.assertFalse(names & {'memset', 'memcpy', 'memmove'}, v)
            self.assertLessEqual({m.lower() for m, _ in imports(v)}, {'ntoskrnl.exe', 'scsiport.sys'}, v)

    def test_pe_versions(self):
        self.assertEqual(pe_version('NT4'), (4, 0))
        self.assertEqual(pe_version('NT351'), (3, 51))
        self.assertEqual(pe_version('NT31'), (3, 10))


class Source(unittest.TestCase):
    def test_scsiport_rules(self):
        for want in ('init.HwInitializationDataSize = FIELD_OFFSET(HW_INITIALIZATION_DATA, HwAdapterControl);',
                     'init.HwInitializationDataSize = 0x40;', 'init.AdapterInterfaceType = Isa;',
                     'ConfigInfo->AdapterInterfaceType = Eisa;', 'ConfigInfo->BusInterruptLevel = 0;',
                     'NvmeWr(Ext, NVME_REG_INTMS, 0xFFFFFFFF);', 'c.Cdw11 = 1;                         /* physically contiguous, IEN = 0 */',
                     'if (lbads != 9 || ms != 0) {', 'only 512-byte sectors are supported',
                     'SPDX-License-Identifier: GPL-3.0-or-later'):
            self.assertIn(want, SRC)
        # the class code the driver and the setup integration match
        self.assertIn('Cfg->BaseClass == 0x01 && Cfg->SubClass == 0x08 && Cfg->ProgIf == 0x02', SRC)
        self.assertIn('PCI\CC_010802', (DRV / 'usosnvme.inf').read_text(encoding='latin-1'))


if __name__ == '__main__':
    unittest.main()
