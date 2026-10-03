"""Windows 2000 SP4 staging pieces (UEFI profile w2k-x86-sp4-uefi-csm), host-only,
no Microsoft files:

- tools/w2k_stage.sh: the AHCINT rows (TXTSETUP.SIF, INF source directory,
  DOSNET), [ACPIOptions] ACPIEnable = 0, apply on a stand-in target (ACPI
  off by default, on on request), refusals, the pinned package files;
- tools/nt52_usb_stage.sh in the 2000 mode: usbhub20.sys forced as well, no
  text-mode load rows; the NT 5.2 default unchanged.

    python tools/tests/test_w2k_staging.py
"""
from pathlib import Path
import hashlib, json, struct, sys, tempfile, unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_nt52_staging import ROOT, SH, STACK, USB_DOSNET, USB_TXTSETUP, posix, rows, sh  # noqa: E402

# Windows 2000 rows in the 5.0 spelling (2000's own TXTSETUP.SIF: disk 2 for
# the SP4 cabinet, trailing blanks, [ACPIOptions] with the date rule).
W2K_TXTSETUP = (b'[SetupData]\r\nMajorVersion = 5\r\nMinorVersion = 0\r\n[SourceDisksFiles]\r\natapi.sys    = 2,,,,,,3_,4,0,0\r\n'
                b'[SourceDisksFiles]\r\nusbport.sys  = 2,,,,,,,4,1,3\r\nusbhub.sys   = 2,,,,,,2_,4,1,3     \r\n'
                b'usbhub20.sys = 2,,,,,,,4,1,3\r\nusbd.sys     = 2,,,,,,2_,4,1,3     \r\nhidclass.sys = 2,,,,,,2_,4,1,3        \r\n'
                b'hidparse.sys = 2,,,,,,2_,4,1,3        \r\nhidusb.sys   = 1,,,,,,2_,4,1,3        \r\nkbdhid.sys   = 1,,,,,,2_,4,1,3   \r\n'
                b'mouhid.sys   = 2,,,,,,,4,1,3   \r\n[HardwareIdsDatabase]\r\nPCI\\CC_0C0310 = "openhci"\r\n'
                b'[SCSI.Load]\r\natapi = atapi.sys,4\r\n[InputDevicesSupport.Load]\r\nopenhci  = openhci.sys\r\n'
                b'[InputDevicesSupport]\r\nopenhci  = "Open HCI",files.openhci,openhci\r\n'
                b'[HiveInfs.Fresh]\r\nAddReg = hivesys.inf,AddReg\r\n[ACPIOptions]\r\nACPIEnable = 2\r\nACPIBiosDate = 01,01,1999\r\n\r\n[NWACL]\r\n[SCSI]\r\natapi = "IDE"\r\n')
W2K_DOSNET = b'[Files]\r\nd1,atapi.sys\r\n[FloppyFiles.1]\r\nd1,atapi.sys\r\n[Files]\r\nd1,other.sys\r\n[FloppyFiles.1]\r\nd1,hal.dll\r\n'
LIB = posix(ROOT / 'tools' / 'w2k_stage.sh')
USB = posix(ROOT / 'tools' / 'nt52_usb_stage.sh')
W2K_USB = 'usos_nt52_usb_sif "$USOS_W2K_USB_STACK" no'


def run_fn(fn: str, data: bytes, lib: str = LIB):
    return sh(f". '{lib}'; {fn}", data)


@unittest.skipIf(SH is None, 'sh not found')
class W2kStorage(unittest.TestCase):
    def test_storage_rows(self):
        r = run_fn('usos_w2k_storage_sif', W2K_TXTSETUP)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.count(b'\r\n'), r.stdout.count(b'\n'))
        out = rows(r.stdout)
        first = out.index('[SourceDisksFiles]')
        # usosw2k.inf needs a row too (text mode refuses a hive INF without one;
        # QEMU 2026-09-30), boot-media only, never copied (as hivedef.inf).
        self.assertEqual(out[first + 1:first + 4], ['ahcint.sys = 1,,,,,,4_,4,1,,,1,4', 'ahcint.inf = 1,,,,,,,20,0,0',
                                                    'usosw2k.inf = 1,,,,,,_x,20,3,3'])
        self.assertEqual(sum(l.startswith('ahcint.sys =') for l in out), 1)
        hw = out.index('[HardwareIdsDatabase]')
        self.assertEqual(out[hw + 1:hw + 5], ['PCI\\CC_010601 = "ahcint"', 'PCI\\VEN_1022&DEV_7901 = "ahcint"',
                                             'PCI\\VEN_1022&DEV_43C8 = "ahcint"', 'PCI\\VEN_1022&DEV_43EB = "ahcint"'])
        self.assertEqual(out[out.index('[SCSI.Load]') + 1], 'ahcint = ahcint.sys,4')
        self.assertTrue(out[out.index('[SCSI]') + 1].startswith('ahcint = "AHCI SATA Controller (AHCINT'))
        self.assertEqual(out[out.index('[HiveInfs.Fresh]') + 1], 'AddReg = usosw2k.inf,AddReg')
        self.assertIn('ACPIEnable = 2', out)
        self.assertEqual(run_fn('usos_w2k_storage_sif', r.stdout).returncode, 3)
        self.assertEqual(run_fn('usos_w2k_storage_sif', W2K_TXTSETUP.replace(b'[SCSI.Load]', b'[Other]')).returncode, 3)

    def test_acpi_off(self):
        r = run_fn('usos_w2k_acpi_off_sif', W2K_TXTSETUP)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(rows(r.stdout), rows(W2K_TXTSETUP.replace(b'ACPIEnable = 2', b'ACPIEnable = 0')))
        self.assertEqual(run_fn('usos_w2k_acpi_off_sif', W2K_TXTSETUP.replace(b'ACPIEnable = 2\r\n', b'')).returncode, 3)
        # Only inside [ACPIOptions].
        self.assertEqual(run_fn('usos_w2k_acpi_off_sif', W2K_TXTSETUP.replace(b'[ACPIOptions]', b'[Other]')).returncode, 3)

    def test_hive_inf(self):
        r = run_fn('usos_w2k_hive_inf', b'')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.count(b'\r\n'), r.stdout.count(b'\n'))
        out = rows(r.stdout)
        pnp = 'HKLM,"SYSTEM\\CurrentControlSet\\Services\\ahcint\\Parameters\\PnpInterface","5",0x00010001,1'
        # Default legacy mode: no PnpInterface (a PnP-mode AHCINT ran the GUI-mode
        # device install into ERROR_NO_SYSTEM_RESOURCES in QEMU, 2026-09-30).
        self.assertEqual(out[1:5], ['[Version]', 'Signature = "$Windows NT$"', '', '[AddReg]'])
        self.assertNotIn(pnp, out)
        self.assertIn(pnp, rows(run_fn('usos_w2k_hive_inf pnp', b'').stdout))
        cddb = 'HKLM,"SYSTEM\\CurrentControlSet\\Control\\CriticalDeviceDatabase\\pci#'
        for key in ('cc_010601', 'ven_1022&dev_7901', 'ven_1022&dev_43c8', 'ven_1022&dev_43eb'):
            self.assertIn(cddb + key + '","Service",0x00000000,"ahcint"', out)
            self.assertIn(cddb + key + '","ClassGUID",0x00000000,"{4D36E97B-E325-11CE-BFC1-08002BE10318}"', out)
        # The same PnpInterface value the INF sets (GUI-mode PnP then keeps one instance).
        inf = (ROOT / 'tools/vendor/ahcint/1.3.0.0/bin/2KXP/ahcint.inf').read_text()
        self.assertIn('HKR, "Parameters\\PnpInterface", "5", %REG_DWORD%, 0x00000001', inf)

    def test_inf_source_directory(self):
        # Upstream ships the INF with LF line ends; the staged one is CRLF.
        raw = (ROOT / 'tools/vendor/ahcint/1.3.0.0/bin/2KXP/ahcint.inf').read_bytes()
        src = raw.replace(b'\r\n', b'\n').replace(b'\n', b'\r\n')
        r = run_fn('usos_w2k_ahcint_inf pnp', raw)
        self.assertEqual(r.returncode, 0, r.stderr)
        want = (src.replace(b'[SourceDisksNames]\r\n1 = %DiskName%,,,\r\n', b'[SourceDisksNames]\r\n1 = %DiskName%,,,\\i386\\ahcint\r\n')
                .replace(b'[SourceDisksNames.x86]\r\n1 = %DiskName%,,,\\i386\r\n', b'[SourceDisksNames.x86]\r\n1 = %DiskName%,,,\\i386\\ahcint\r\n'))
        self.assertNotEqual(want, src)
        self.assertEqual(r.stdout, want)
        self.assertIn(b'[SourceDisksNames.amd64]\r\n1 = %DiskName%,,,\\amd64\r\n', r.stdout)
        self.assertEqual(run_fn('usos_w2k_ahcint_inf', b'[Version]\r\n').returncode, 3)
        # Legacy mode (default): the PnpInterface row is commented out, nothing else differs.
        legacy = run_fn('usos_w2k_ahcint_inf', raw)
        self.assertEqual(legacy.returncode, 0, legacy.stderr)
        row = b'HKR, "Parameters\\PnpInterface", "5", %REG_DWORD%, 0x00000001\r\n'
        self.assertEqual(legacy.stdout, want.replace(row, b'; USOS legacy mode: ' + row))

    def test_dosnet(self):
        r = run_fn('usos_w2k_dosnet', W2K_DOSNET)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, b'[Files]\r\nd1,ahcint.sys\r\nd1,ahcint.inf\r\nd1,usosw2k.inf\r\nd1,atapi.sys\r\n[FloppyFiles.1]\r\n'
                                   b'd1,ahcint.sys\r\nd1,ahcint.inf\r\nd1,usosw2k.inf\r\nd1,atapi.sys\r\n[Files]\r\nd1,other.sys\r\n[FloppyFiles.1]\r\nd1,hal.dll\r\n')
        self.assertEqual(run_fn('usos_w2k_dosnet', r.stdout).returncode, 3)

    def test_package_files(self):
        import build_xp_uefi_csm_trial as builder
        files = builder.w2k_driver_files()
        self.assertEqual(sorted(files), ['LICENSE', 'MODIFIED.txt', 'SOURCE.txt', 'ahcint.inf', 'ahcint.sys',
                                         'uniata/COPYING-GPL-2.0.txt', 'uniata/SOURCES.txt', 'uniata/uniata.sys'])
        self.assertIn(b'MODIFIED version of AHCINT 1.3.0.0', files['MODIFIED.txt'])
        self.assertIn(b'usos2', files['MODIFIED.txt'])
        self.assertIn(b'1.3.0.0-usos2', files['SOURCE.txt'])
        self.assertEqual(struct.unpack_from('<H', files['uniata/uniata.sys'], struct.unpack_from('<I', files['uniata/uniata.sys'], 60)[0] + 4)[0], 0x14c)
        self.assertIn(b'Version 2, June 1991', files['uniata/COPYING-GPL-2.0.txt'])
        self.assertEqual(struct.unpack_from('<H', files['ahcint.sys'], struct.unpack_from('<I', files['ahcint.sys'], 60)[0] + 4)[0], 0x14c)
        self.assertIn(b'DriverVer=09/29/2026,1.3.0.0', files['ahcint.inf'])
        self.assertIn(b'GNU GENERAL PUBLIC LICENSE', files['LICENSE'])
        self.assertIn(b'Version 3, 29 June 2007', files['LICENSE'])
        self.assertIn('usr/lib/usos/w2k-drivers/', builder.PACKAGE_PREFIXES)
        # The corresponding source is tracked next to the binary, every file pinned.
        for folder in ('1.3.0.0', '1.3.0.0-usos2'):
            pins = json.loads((ROOT / 'tools/vendor/ahcint' / folder / 'manifest.json').read_text())
            for rel, digest in pins['files'].items():
                self.assertEqual(hashlib.sha256((ROOT / 'tools/vendor/ahcint' / folder / rel).read_bytes()).hexdigest(), digest, rel)
            self.assertIn('src/ahcimain.c', pins['files'])
        # The patched source carries the USOS markers.
        src = (ROOT / 'tools/vendor/ahcint/1.3.0.0-usos2/src/ahcisatl.c').read_bytes()
        self.assertIn(b'MODIFIED (USOS 1.3.0.0-usos1)', src)
        self.assertIn(b'MODIFIED (USOS 1.3.0.0-usos2)', src)
        self.assertIn(b'USOSW2KTRACE'[:4], (ROOT / 'tools/vendor/ahcint/1.3.0.0-usos2/src/ahcisatl.c').read_bytes())
        pins = json.loads((ROOT / 'tools/vendor/uniata/0.47b/manifest.json').read_text())
        for rel, digest in pins['files'].items():
            self.assertEqual(hashlib.sha256((ROOT / 'tools/vendor/uniata/0.47b' / rel).read_bytes()).hexdigest(), digest, rel)

    def stand_in(self, t: Path) -> tuple:
        import build_xp_uefi_csm_trial as builder
        for rel, data in builder.w2k_driver_files().items():
            (t / 'pkg' / rel).parent.mkdir(parents=True, exist_ok=True)
            (t / 'pkg' / rel).write_bytes(data)
        bt, ls = t / 'root/$WIN_NT$.~BT', t / 'root/$WIN_NT$.~LS/I386'
        for folder in (bt, ls):
            folder.mkdir(parents=True)
            (folder / 'TXTSETUP.SIF').write_bytes(W2K_TXTSETUP)
            (folder / 'AHCINT.SY_').write_bytes(b'stale')
        (t / 'root/TXTSETUP.SIF').write_bytes(W2K_TXTSETUP)
        (ls / 'DOSNET.INF').write_bytes(W2K_DOSNET)
        (ls / 'HIVESYS.INF').write_bytes('﻿[AddReg]\r\n'.encode('utf-16-le'))
        return bt, ls

    def apply(self, t: Path, env: str = '', source_dir: str = 'I386'):
        return sh(f"{env} XP_TARGET_ROOT='{posix(t / 'root')}' NT5_SOURCE_DIR={source_dir} USOS_W2K_DIR='{posix(t / 'pkg')}' sh '{LIB}' apply")

    def test_apply(self):
        import build_xp_uefi_csm_trial as builder
        pkg = builder.w2k_driver_files()
        for acpi in ('', 'off', 'on'):
            with tempfile.TemporaryDirectory() as tmp:
                t = Path(tmp)
                bt, ls = self.stand_in(t)
                hivesys = (ls / 'HIVESYS.INF').read_bytes()
                r = self.apply(t, f'USOS_W2K_ACPI={acpi}' if acpi else '')
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                self.assertIn(b'[W2K_STAGE] APPLIED PASS AHCINT 1.3.0.0-usos2', r.stdout)
                sif = run_fn('usos_w2k_storage_sif', W2K_TXTSETUP).stdout
                if acpi == 'off':  # default (empty) keeps ACPI since 2026-10-03
                    sif = run_fn('usos_w2k_acpi_off_sif', sif).stdout
                    self.assertIn(b'ACPI off', r.stdout)
                inf = run_fn('usos_w2k_ahcint_inf', pkg['ahcint.inf']).stdout
                for folder in (bt, ls):
                    self.assertEqual((folder / 'ahcint.sys').read_bytes(), pkg['ahcint.sys'])
                    self.assertEqual((folder / 'ahcint.inf').read_bytes(), inf)
                    self.assertFalse((folder / 'AHCINT.SY_').exists())
                    self.assertEqual((folder / 'usosw2k.inf').read_bytes(), run_fn('usos_w2k_hive_inf', b'').stdout)
                    self.assertEqual((folder / 'TXTSETUP.SIF').read_bytes(), sif)
                self.assertEqual((t / 'root/TXTSETUP.SIF').read_bytes(), sif)
                self.assertIn(b'ACPIEnable = ' + (b'0' if acpi == 'off' else b'2') + b'\r\n', sif)
                # The GUI-mode source copy (text mode moves the one above).
                self.assertEqual((ls / 'AHCINT/ahcint.sys').read_bytes(), pkg['ahcint.sys'])
                self.assertIn(b'd1,ahcint.inf', (ls / 'DOSNET.INF').read_bytes())
                # HIVESYS.INF (UTF-16 on 2000) is left alone.
                self.assertEqual((ls / 'HIVESYS.INF').read_bytes(), hivesys)
                self.assertNotEqual(self.apply(t).returncode, 0)
                self.assertEqual((ls / 'TXTSETUP.SIF').read_bytes(), sif)

    def test_gap_marker(self):
        r = run_fn('usos_w2k_gap_marker edc187d4', b'')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(r.stdout), 512)
        self.assertEqual(r.stdout[:12], b'USOSW2KTRACE')
        self.assertEqual(r.stdout[12:32], bytes(20))       # boot counter 0 at 16
        self.assertEqual(r.stdout[32:40], b'edc187d4')
        self.assertEqual(r.stdout[40:], bytes(472))
        # The driver uses the same magic and LBAs.
        h = (ROOT / 'tools/vendor/ahcint/1.3.0.0-usos2/src/ahcint.h').read_bytes()
        for want in (b'USOS_GAP_MARKER_LBA             2046', b'USOS_GAP_TEST_LBA               2045', b'USOS_GAP_TRACE_LBA              2040'):
            self.assertIn(want, h)
        c = (ROOT / 'tools/vendor/ahcint/1.3.0.0-usos2/src/ahcisatl.c').read_bytes()
        self.assertIn(b"'U','S','O','S','W','2','K','T','R','A','C','E'", c)

    def test_uniata(self):
        import build_xp_uefi_csm_trial as builder
        env = 'USOS_W2K_STORAGE=uniata'
        with tempfile.TemporaryDirectory() as tmp:
            t = Path(tmp)
            bt, ls = self.stand_in(t)
            r = self.apply(t, env)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn(b'APPLIED PASS UniATA 0.47b', r.stdout)
            pkg = builder.w2k_driver_files()
            for folder in (bt, ls):
                self.assertEqual((folder / 'uniata.sys').read_bytes(), pkg['uniata/uniata.sys'])
                self.assertFalse((folder / 'ahcint.sys').exists())
                inf = rows((folder / 'uniata.inf').read_bytes())
                self.assertIn('1 = %DiskName%,,,\\i386\\uniata', inf)
                self.assertIn('%Desc% = UniATA_Inst, PCI\\VEN_1022&DEV_43C8', inf)
                self.assertIn('AddService = uniata, 0x00000002, UniATA_Service', inf)
                sif = rows((folder / 'TXTSETUP.SIF').read_bytes())
                self.assertIn('uniata.sys = 1,,,,,,4_,4,1,,,1,4', sif)
                self.assertIn('PCI\\CC_010601 = "uniata"', sif)
                self.assertIn('uniata = uniata.sys,4', sif)
                hive = (folder / 'usosw2k.inf').read_bytes()
                self.assertIn(b'"Service",0x00000000,"uniata"', hive)
                self.assertNotIn(b'ahcint', hive)
            self.assertEqual((ls / 'UNIATA/uniata.sys').read_bytes(), pkg['uniata/uniata.sys'])
            self.assertIn(b'd1,uniata.sys', (ls / 'DOSNET.INF').read_bytes())
            self.assertIn(b'USOS_W2K_STORAGE must be', self.apply(t, 'USOS_W2K_STORAGE=other').stdout)

    def test_apply_refusals(self):
        with tempfile.TemporaryDirectory() as tmp:
            t = Path(tmp)
            bt, ls = self.stand_in(t)
            self.assertIn(b'USOS_W2K_ACPI must be', self.apply(t, 'USOS_W2K_ACPI=maybe').stdout)
            self.assertIn(b'STOP', self.apply(t, source_dir='AMD64').stdout)
            (t / 'pkg/ahcint.inf').unlink()
            self.assertIn(b'ahcint.inf missing', self.apply(t).stdout)
            self.assertEqual((ls / 'TXTSETUP.SIF').read_bytes(), W2K_TXTSETUP)


@unittest.skipIf(SH is None, 'sh not found')
class W2kUsb(unittest.TestCase):
    def test_rows(self):
        r = run_fn(W2K_USB, W2K_TXTSETUP, USB)
        self.assertEqual(r.returncode, 0, r.stderr)
        out = rows(r.stdout)
        first = out.index('[SourceDisksFiles]')
        self.assertEqual(out[first + 1:first + 3], ['xhci98.sys = 1,,,,,,4_,4,1,,,1,4', 'xhci98.inf = 1,,,,,,,20,0,0'])
        for name in (*STACK, 'usbhub20.sys'):
            row = next(l for l in out if l.startswith(name))
            self.assertTrue(row.endswith(',4,0,0'), row)
        self.assertIn('usbhub20.sys = 2,,,,,,,4,0,0', out)
        self.assertIn('mouhid.sys   = 2,,,,,,,4,1,3   ', out)
        # No text-mode load on 2000: nothing else is added.
        self.assertNotIn('[files.xhci98]', out)
        self.assertFalse(any('CC_0C0330' in l or l.startswith('xhci98 =') for l in out))
        self.assertEqual(len(out), len(rows(W2K_TXTSETUP)) + 2)
        self.assertEqual(run_fn(W2K_USB, r.stdout, USB).returncode, 3)
        # usbhub20.sys is required on 2000.
        self.assertEqual(run_fn(W2K_USB, W2K_TXTSETUP.replace(b'usbhub20.sys = 2,,,,,,,4,1,3\r\n', b''), USB).returncode, 3)
        # The NT 5.2 default is the same as its explicit parameters.
        self.assertEqual(run_fn('usos_nt52_usb_sif', USB_TXTSETUP, USB).stdout,
                         run_fn('usos_nt52_usb_sif "$USOS_NT52_USB_STACK" yes', USB_TXTSETUP, USB).stdout)

    def test_apply(self):
        import build_xp_uefi_csm_trial as builder
        pkg = builder.nt52_usb_files()
        with tempfile.TemporaryDirectory() as tmp:
            t = Path(tmp)
            for rel, data in pkg.items():
                (t / 'pkg' / rel).parent.mkdir(parents=True, exist_ok=True)
                (t / 'pkg' / rel).write_bytes(data)
            bt, ls = t / 'root/$WIN_NT$.~BT', t / 'root/$WIN_NT$.~LS/I386'
            for folder in (bt, ls):
                folder.mkdir(parents=True)
                (folder / 'TXTSETUP.SIF').write_bytes(W2K_TXTSETUP)
            (ls / 'DOSNET.INF').write_bytes(USB_DOSNET)
            r = sh(f"NT5_SYSTEM=windows-2000 XP_TARGET_ROOT='{posix(t / 'root')}' NT5_SOURCE_DIR=I386 "
                   f"USOS_NT52_USB_DIR='{posix(t / 'pkg')}' sh '{USB}' apply")
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn(b'GUI-mode PnP only (no text-mode load)', r.stdout)
            self.assertEqual((ls / 'TXTSETUP.SIF').read_bytes(), run_fn(W2K_USB, W2K_TXTSETUP, USB).stdout)
            self.assertEqual((ls / 'XHCI98/xhci98.sys').read_bytes(), pkg['x86/xhci98.sys'])
            self.assertIn(b'1=%DiskName%,,,\\i386\\xhci98\r\n', (ls / 'xhci98.inf').read_bytes())


if __name__ == '__main__':
    unittest.main()
