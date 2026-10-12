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

    def test_nt6_x86(self):
        # Windows Vista / Server 2008 (and 7) x86 run the 2KXP build
        # (docs/nvme-nt6-2026-10-12.md): Server 2008 SP2 x86 kernels, HALs
        # and its SCSIPORT.
        self.check('2KXP', 'nt60sp2_x86_exports.txt', (('ntoskrnl.exe', 'halmacpi.dll'), ('ntkrnlpa.exe', 'halacpi.dll')))

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


class Flow(unittest.TestCase):
    """Wiring: only an NVMe target loads usosnvme (XP / 2003 bundle NVME/ set,
    NT 4.0 DRIVERS.REG); 4Kn targets stop before any write."""

    def test_xp_bundle(self):
        sys.path.insert(0, str(ROOT / 'tools'))
        import xp_driver_overlay as o
        base = '[SourceDisksFiles.x86]\r\na.sys = 1\r\n[HardwareIdsDatabase]\r\n[SCSI.Load]\r\n[SCSI]\r\n[FileFlags]\r\n'
        t = o.nvme_txtsetup(base)
        for want in ('usosnvme.sys = 1,,,,,,4_,4,0,0,,1,4', 'PCI\\CC_010802 = "usosnvme"',
                     'usosnvme = usosnvme.sys,4', 'usosnvme.sys = 16'):
            self.assertIn(want, t)
        rows = {(p, n): v for p, n, _, v in o.nvme_registry_rows()}
        self.assertEqual(rows[('Control\\CriticalDeviceDatabase\\pci#cc_010802', 'Service')], 'usosnvme')
        self.assertEqual(rows[('Services\\usosnvme\\Parameters\\PnpInterface', '5')], 1)
        self.assertEqual(rows[('Services\\usosnvme', 'Start')], 0)

    def test_scripts(self):
        stage = (ROOT / 'tools/xp_driver_stage.sh').read_text(encoding='utf-8')
        self.assertIn('/dev/nvme*)', stage)
        self.assertIn('sha256sum -c nvme.sha256', stage)
        legacy = (ROOT / 'tools/legacy_xp_staging.sh').read_text(encoding='utf-8')
        self.assertIn('queue/logical_block_size', legacy)
        nt4 = (ROOT / 'tools/nt4_csmwrap_target.sh').read_text(encoding='utf-8')
        self.assertIn('case "$TARGET_DEVICE" in /dev/nvme*)', nt4)
        self.assertIn('Services\\usosnvme]', nt4)
        self.assertIn('if exist C:\\USOS\\NT4\\USOSNVME.SYS copy', nt4)
        build = (ROOT / 'tools/build_micro_linux.py').read_text(encoding='utf-8')
        self.assertIn('("tools/nt/usosnvme/bin/NT4/i386/usosnvme.sys", "usr/lib/usos/nt4/USOSNVME.SYS")', build)


class Nt6Flow(unittest.TestCase):
    """Windows 7 / Vista / Server 2008 x86 through CSMWrap (x86 PE10 donor):
    the NVMe gate in micro-Linux, target_bus in the target record and the
    WinPE nvme step (docs/nvme-nt6-2026-10-12.md)."""
    CMD = (ROOT / 'tools/windows_x86_csmwrap.cmd').read_text(encoding='utf-8')

    def step(self):
        return self.CMD[self.CMD.index('\n:nvme\n'):]

    def test_gate(self):
        prep = (ROOT / 'tools/vista_csmwrap_prepare.sh').read_text(encoding='utf-8')
        gate = prep[prep.index('usos_xp_choose_disk\n'):]
        self.assertLess(gate.index('case "$TARGET_DEVICE" in /dev/nvme*)'), gate.index('usos_xp_confirm '))
        self.assertIn('[ "$nvme_lbs" = 512 ] || stop', gate)
        self.assertIn('[ "$x86_self" = 1 ] || stop "No NVMe driver for 64-bit', gate)
        self.assertIn("'win-nt6-x86-uefi-csmwrap:Windows Vista'|'win-nt6-x86-uefi-csmwrap:Windows Server 2008')", gate)
        target = (ROOT / 'tools/vista_csmwrap_target.sh').read_text(encoding='utf-8')
        self.assertIn('/dev/nvme*) target_bus=nvme', target)
        self.assertIn(r'target_bus=%s\r\n', target)

    def test_other_flows_stop(self):
        nt4 = (ROOT / 'tools/nt4_csmwrap_target.sh').read_text(encoding='utf-8')
        self.assertLess(nt4.index('no NVMe driver for Windows NT 3.x'), nt4.index('of="$TARGET_DEVICE"'))
        pos = (ROOT / 'tools/posready_csmwrap_target.sh').read_text(encoding='utf-8')
        self.assertLess(pos.index('no NVMe driver for POSReady 2009'), pos.index('of="$TARGET_DEVICE"'))

    def test_step(self):
        self.assertIn('call :nt60_usb\ncall :nvme\n', self.CMD)
        s = self.step()
        self.assertLess(s.index('find "target_bus=nvme"'), s.index('copy /y'))
        self.assertIn('if not "%USOS_NT%"=="6.0" if not "%USOS_NT%"=="6.1"', s)
        self.assertIn(r'copy /y "%~dp0usosnvme-nt6.sys" "%USOS_T%\Windows\System32\drivers\usosnvme.sys"', s)
        for want in ('/v Start /t REG_DWORD /d 0 ', '/v Group /t REG_SZ /d "SCSI miniport"',
                     r'Services\usosnvme"', r'\Parameters\PnpInterface" /v 5 /t REG_DWORD /d 1',
                     r'CriticalDeviceDatabase\pci#cc_010802"', '/v Service /t REG_SZ /d usosnvme',
                     '{4D36E97B-E325-11CE-BFC1-08002BE10318}', '*kb2990941*x86*.msu', '*kb3087873*x86*.msu'):
            self.assertIn(want, s)
        self.assertNotRegex(s, r'exit /b [1-9]')

    def test_setup_sees_driver(self):
        # Vista / 7 Setup refuses the NVMe disk unless a driver for its
        # controller was loaded: DriverPaths before Setup, crash dump off.
        before = self.CMD[:self.CMD.index('usos-x86-csmwrap.exe" before')]
        self.assertIn('set "USOS_NVME_DRIVERS=%SystemDrive%\\USOS-nvme"', before)
        self.assertIn('usos-x86-csmwrap.exe" nodump', before)
        src = (ROOT / 'tools/windows_x86_csmwrap.c').read_text(encoding='utf-8')
        self.assertIn('Microsoft-Windows-PnpCustomizationsWinPE', src)
        self.assertIn('if (major == 6 && minor <= 1 && dn && dn < MAX_PATH)', src)
        self.assertIn('34 /* SystemCrashDumpStateInformation */', src)
        build = (ROOT / 'tools/build_windows_native_support.py').read_text(encoding='utf-8')
        self.assertIn("b'DriverVer=01/01/2001,1.0.0.0'", build)

    def test_packed(self):
        build = (ROOT / 'tools/build_windows_native_support.py').read_text(encoding='utf-8')
        self.assertIn("writer.add_file('usosnvme-nt6.sys', root / 'tools/nt/usosnvme/bin/2KXP/i386/usosnvme.sys')", build)


if __name__ == '__main__':
    unittest.main()
