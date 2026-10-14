"""Windows 2000 SP4 staging pieces (UEFI profile w2k-x86-sp4-uefi-csm), host-only,
no Microsoft files:

- tools/w2k_stage.sh: the AHCINT rows (TXTSETUP.SIF, INF source directory,
  DOSNET), [ACPIOptions] ACPIEnable = 0, apply on a stand-in target (ACPI
  off by default, on on request), refusals, the pinned package files;
  the WINNT.SIF hardware answers ([KeyboardDrivers], ComputerType for the
  MPS / Standard PC HAL) from the source's own TXTSETUP.SIF descriptions;
- usosrst.sys (own helper): its TXTSETUP/registry/DOSNET rows, the pinned
  binary and its source;
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
W2K_TXTSETUP = (b'[SetupData]\r\nMajorVersion = 5\r\nMinorVersion = 0\r\nOsLoadOptions = "/fastdetect /noguiboot /nodebug"\r\n[SourceDisksFiles]\r\natapi.sys    = 2,,,,,,3_,4,0,0\r\n'
                b'[SourceDisksFiles]\r\nusbport.sys  = 2,,,,,,,4,1,3\r\nusbhub.sys   = 2,,,,,,2_,4,1,3     \r\n'
                b'usbhub20.sys = 2,,,,,,,4,1,3\r\nusbd.sys     = 2,,,,,,2_,4,1,3     \r\nhidclass.sys = 2,,,,,,2_,4,1,3        \r\n'
                b'hidparse.sys = 2,,,,,,2_,4,1,3        \r\nhidusb.sys   = 1,,,,,,2_,4,1,3        \r\nkbdhid.sys   = 1,,,,,,2_,4,1,3   \r\n'
                b'mouhid.sys   = 2,,,,,,,4,1,3   \r\n[HardwareIdsDatabase]\r\nPCI\\CC_0C0310 = "openhci"\r\n'
                b'[SCSI.Load]\r\natapi = atapi.sys,4\r\n[InputDevicesSupport.Load]\r\nopenhci  = openhci.sys\r\n'
                b'[InputDevicesSupport]\r\nopenhci  = "Open HCI",files.openhci,openhci\r\n'
                b'[HiveInfs.Fresh]\r\nAddReg = hivesys.inf,AddReg\r\n[ACPIOptions]\r\nACPIEnable = 2\r\nACPIBiosDate = 01,01,1999\r\n\r\n[NWACL]\r\n[SCSI]\r\natapi = "IDE"\r\n'
                b'[BootBusExtenders.Load]\r\npci      = pci.sys\r\n[BootBusExtenders]\r\npci      = "PCI",files.pci,pci                \r\n'
                # The hardware lists text-mode Setup confirms (Polish media: ANSI, CP1250).
                b'[Computer]\r\nacpiapic_mp = "ACPI Multiprocessor PC",files.none\r\nmps_mp      = "MPS Multiprocessor PC",files.none\r\n'
                + 'e_isa_up    = "Standardowy komputer PC",files.none\r\n'.encode('cp1250')
                + b'[Map.Keyboard]\r\nSTANDARD = PCAT_ENHANCED\r\n[Keyboard]\r\n'
                + 'STANDARD    = "Klawiatura XT, AT lub rozszerzona (83-104 klawiszy)",files.i8042,i8042prt\r\n'.encode('cp1250')
                + b'USB      = "Klawiatura USB",files.kbdhid,kbdhid\r\n')
# The answer file text mode reads ($WIN_NT$.~BT\WINNT.SIF), as the w2k template writes it.
W2K_WINNT = (b'[Data]\r\nmsdosinitiated="1"\r\nfloppyless="1"\r\n[Unattended]\r\nUnattendMode=ProvideDefault\r\n'
             b'TargetPath=\\WINNT\r\n[SetupParams]\r\nUserExecute="C:\\USOS\\W2K\\usos-setup.cmd"\r\n')
KBD = 'Klawiatura XT, AT lub rozszerzona (83-104 klawiszy)'.encode('cp1250')
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
        self.assertEqual(out[first + 1:first + 5], ['ahcint.sys = 1,,,,,,4_,4,1,,,1,4', 'ahcint.inf = 1,,,,,,,20,0,0',
                                                    'usosw2k.inf = 1,,,,,,_x,20,3,3', 'usosrst.sys = 1,,,,,,4_,4,1,,,1,4'])
        self.assertEqual(sum(l.startswith('ahcint.sys =') for l in out), 1)
        hw = out.index('[HardwareIdsDatabase]')
        self.assertEqual(out[hw + 1:hw + 5], ['PCI\\CC_010601 = "ahcint"', 'PCI\\VEN_1022&DEV_7901 = "ahcint"',
                                             'PCI\\VEN_1022&DEV_43C8 = "ahcint"', 'PCI\\VEN_1022&DEV_43EB = "ahcint"'])
        self.assertEqual(out[out.index('[SCSI.Load]') + 1], 'ahcint = ahcint.sys,4')
        self.assertTrue(out[out.index('[SCSI]') + 1].startswith('ahcint = "AHCI SATA Controller (AHCINT'))
        self.assertEqual(out[out.index('[HiveInfs.Fresh]') + 1], 'AddReg = usosw2k.inf,AddReg')
        self.assertIn('ACPIEnable = 2', out)
        # usosrst: loaded by SETUPLDR before the storage drivers, own files section at the end.
        self.assertEqual(out[out.index('[BootBusExtenders.Load]') + 1], 'usosrst  = usosrst.sys')
        self.assertEqual(out[out.index('[BootBusExtenders]') + 1], 'usosrst  = "USOS STOP screen and restart helper",files.usosrst,usosrst')
        self.assertEqual(out[-4:], ['', '[files.usosrst]', 'usosrst.sys,4', ''])
        self.assertEqual(len(out), len(rows(W2K_TXTSETUP)) + 4 + 4 + 1 + 1 + 1 + 1 + 1 + 3)
        off = run_fn('USOS_W2K_USOSRST=off usos_w2k_storage_sif', W2K_TXTSETUP)
        self.assertEqual(off.returncode, 0, off.stderr)
        self.assertNotIn(b'usosrst', off.stdout)
        self.assertEqual(rows(off.stdout), [l for l in out[:-4] if 'usosrst' not in l] + [''])
        self.assertEqual(run_fn('usos_w2k_storage_sif', W2K_TXTSETUP.replace(b'[BootBusExtenders]', b'[Other]')).returncode, 3)
        self.assertEqual(run_fn('usos_w2k_storage_sif', r.stdout).returncode, 3)
        self.assertEqual(run_fn('usos_w2k_storage_sif', W2K_TXTSETUP.replace(b'[SCSI.Load]', b'[Other]')).returncode, 3)

    def test_acpi_off(self):
        r = run_fn('usos_w2k_acpi_off_sif', W2K_TXTSETUP)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(rows(r.stdout), rows(W2K_TXTSETUP.replace(b'ACPIEnable = 2', b'ACPIEnable = 0')))
        self.assertEqual(run_fn('usos_w2k_acpi_off_sif', W2K_TXTSETUP.replace(b'ACPIEnable = 2\r\n', b'')).returncode, 3)
        # Only inside [ACPIOptions].
        self.assertEqual(run_fn('usos_w2k_acpi_off_sif', W2K_TXTSETUP.replace(b'[ACPIOptions]', b'[Other]')).returncode, 3)

    def test_hpet_legacy_off(self):
        # DATA hpet-legacy-off.txt: /USOSHPETLEGOFF in the text-mode load options and
        # the usosrst Parameters value for later boots (usosrst 1.3 clears HPET
        # LegacyReplacement); the default leaves both alone.
        sif = W2K_TXTSETUP
        r = run_fn('usos_w2k_hpet_sif', sif)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(rows(r.stdout), rows(sif.replace(b'/nodebug"', b'/nodebug /USOSHPETLEGOFF"')))
        self.assertEqual(run_fn('usos_w2k_hpet_sif', r.stdout).stdout, r.stdout)          # idempotent
        noopt = W2K_TXTSETUP.replace(b'OsLoadOptions = "/fastdetect /noguiboot /nodebug"\r\n', b'')
        self.assertEqual(run_fn('usos_w2k_hpet_sif', noopt).returncode, 3)              # no OsLoadOptions row
        # Both clock options (the default with usosrst), each only once.
        both = run_fn('usos_w2k_hpet_sif "$(USOS_W2K_HPET=legacy-off USOS_W2K_RTC=fix usos_w2k_load_options)"', r.stdout)
        self.assertEqual(rows(both.stdout), rows(sif.replace(b'/nodebug"', b'/nodebug /USOSHPETLEGOFF /USOSRTCFIX"')))
        self.assertEqual(run_fn('usos_w2k_load_options', b'').stdout, b'')
        self.assertEqual(run_fn('USOS_W2K_RTC=fix usos_w2k_load_options', b'').stdout, b'/USOSRTCFIX')
        self.assertEqual(run_fn('USOS_W2K_BOOTVID=text usos_w2k_load_options', b'').stdout, b'/SOS')
        rtc = 'HKLM,"SYSTEM\\CurrentControlSet\\Services\\usosrst\\Parameters","RtcFix",0x00010001,1'
        self.assertIn(rtc, rows(run_fn('USOS_W2K_RTC=fix usos_w2k_hive_inf', b'').stdout))
        self.assertNotIn(rtc, rows(run_fn('usos_w2k_hive_inf', b'').stdout))
        row = 'HKLM,"SYSTEM\\CurrentControlSet\\Services\\usosrst\\Parameters","HpetLegacyOff",0x00010001,1'
        self.assertIn(row, rows(run_fn('USOS_W2K_HPET=legacy-off usos_w2k_hive_inf', b'').stdout))
        self.assertNotIn(row, rows(run_fn('usos_w2k_hive_inf', b'').stdout))
        self.assertNotIn(b'HpetLegacyOff', run_fn('USOS_W2K_HPET=legacy-off USOS_W2K_USOSRST=off usos_w2k_hive_inf', b'').stdout)
        stage = (ROOT / 'tools/legacy_xp_staging.sh').read_text()
        # The clock fixes are the default since the X470 run of 2026-10-05.
        self.assertIn('Unattended/hpet-keep.txt" ]; then USOS_W2K_HPET=keep; else USOS_W2K_HPET=legacy-off; fi', stage)
        self.assertIn('Unattended/rtc-keep.txt" ]; then USOS_W2K_RTC=keep; else USOS_W2K_RTC=fix; fi', stage)
        self.assertIn('export USOS_W2K_ACPI USOS_W2K_STORAGE USOS_W2K_HAL USOS_W2K_HPET USOS_W2K_RTC', stage)
        c = (ROOT / 'tools/w2k/usosrst/src/usosrst.c').read_text()
        for want in ('L"USOSHPETLEGOFF"', 'L"HpetLegacyOff"', 'SystemStartOptions', 'g_HpetCfg & ~2UL',
                     'L"USOSRTCFIX"', 'L"RtcFix"', 'UsosSetRtc', 'ZwSetSystemTime'):
            self.assertIn(want, c)

    def test_usb_preinstall(self):
        # USOS_W2K_USB=on: the keyboard path starts from the CriticalDeviceDatabase
        # on the first GUI-mode boot (no PS/2 on xHCI-only boards without CSM).
        out = rows(run_fn('USOS_W2K_USB=on usos_w2k_hive_inf', b'').stdout)
        base = 'HKLM,"SYSTEM\\CurrentControlSet\\'
        for svc, group, err, image in (('xhci98', 'Base', 1, 'xhci98.sys'), ('usbhub20', 'Base', 1, 'usbhub20.sys'),
                                       ('HidUsb', 'extended base', 0, 'hidusb.sys'), ('kbdhid', 'Keyboard Port', 0, 'kbdhid.sys')):
            k = base + 'Services\\' + svc + '",'
            for row in ('"Type",0x00010001,1', '"Start",0x00010001,3', '"ErrorControl",0x00010001,%d' % err,
                        '"Group",0x00000000,"%s"' % group, '"ImagePath",0x00020000,"System32\\DRIVERS\\%s"' % image):
                self.assertIn(k + row, out)
        usb = '{36FC9E60-C465-11CF-8056-444553540000}'
        for key, svc, cls in (('pci#cc_0c0330', 'xhci98', usb), ('usb#root_hub20', 'usbhub20', usb), ('usb#hubclass', 'usbhub20', usb),
                              ('usb#class_03', 'HidUsb', '{745a17a0-74d3-11d0-b6fe-00a0c90f57da}'),
                              ('hid_device_system_keyboard', 'kbdhid', '{4D36E96B-E325-11CE-BFC1-08002BE10318}')):
            k = base + 'Control\\CriticalDeviceDatabase\\' + key + '",'
            self.assertIn(k + '"Service",0x00000000,"' + svc + '"', out)
            self.assertIn(k + '"ClassGUID",0x00000000,"' + cls + '"', out)
        self.assertNotIn(b'cc_0c0330', run_fn('usos_w2k_hive_inf', b'').stdout)
        self.assertNotIn(b'mouhid', run_fn('USOS_W2K_USB=on usos_w2k_hive_inf', b'').stdout)   # DRIVER.CAB only
        # MPS HAL (ACPI off): no interrupt resource for the xHCI functions, so xhci98 usos3 polls.
        poll = base + 'Services\\xhci98\\Parameters","PollMode",0x00010001,1'
        self.assertIn(poll, rows(run_fn('USOS_W2K_USB=on USOS_W2K_ACPI=off usos_w2k_hive_inf', b'').stdout))
        self.assertNotIn(poll, out)

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
        # usosrst: a boot driver that never stops the boot.
        svc = 'HKLM,"SYSTEM\\CurrentControlSet\\Services\\usosrst",'
        self.assertEqual(out[5:10], [svc + '"Type",0x00010001,1', svc + '"Start",0x00010001,0', svc + '"ErrorControl",0x00010001,0',
                                     svc + '"Group",0x00000000,"Boot Bus Extender"',
                                     svc + '"ImagePath",0x00020000,"System32\\DRIVERS\\usosrst.sys"'])
        self.assertNotIn(b'usosrst', run_fn('USOS_W2K_USOSRST=off usos_w2k_hive_inf', b'').stdout)

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
        self.assertEqual(r.stdout, b'[Files]\r\nd1,ahcint.sys\r\nd1,ahcint.inf\r\nd1,usosw2k.inf\r\nd1,usosrst.sys\r\nd1,atapi.sys\r\n[FloppyFiles.1]\r\n'
                                   b'd1,ahcint.sys\r\nd1,ahcint.inf\r\nd1,usosw2k.inf\r\nd1,usosrst.sys\r\nd1,atapi.sys\r\n[Files]\r\nd1,other.sys\r\n[FloppyFiles.1]\r\nd1,hal.dll\r\n')
        self.assertEqual(run_fn('usos_w2k_dosnet', r.stdout).returncode, 3)
        self.assertEqual(run_fn('USOS_W2K_USOSRST=off usos_w2k_dosnet', W2K_DOSNET).stdout, r.stdout.replace(b'd1,usosrst.sys\r\n', b''))

    def test_package_files(self):
        import build_xp_uefi_csm_trial as builder
        files = builder.w2k_driver_files()
        self.assertEqual(sorted(files), ['LICENSE', 'MODIFIED.txt', 'SOURCE.txt', 'ahcint.inf', 'ahcint.sys',
                                         'uniata/COPYING-GPL-2.0.txt', 'uniata/SOURCES.txt', 'uniata/uniata.sys', 'usosnvme/usosnvme.inf',
                                         'usosnvme/usosnvme.sys', 'usosrst.sys', 'usosvid/bootvid.dll'])
        # usosnvme: the NT4 build (legacy, scans PCI itself), the tracked INF.
        self.assertEqual(files['usosnvme/usosnvme.sys'], (ROOT / 'tools/nt/usosnvme/bin/NT4/i386/usosnvme.sys').read_bytes())
        self.assertIn(b'usosnvme/: USOS', files['SOURCE.txt'])
        self.assertEqual(struct.unpack_from('<H', files['usosrst.sys'], struct.unpack_from('<I', files['usosrst.sys'], 60)[0] + 4)[0], 0x14c)
        self.assertIn(b'usosrst.sys: USOS', files['SOURCE.txt'])
        # usosrst: own source next to the pinned binary, every file pinned.
        rst = ROOT / 'tools/w2k/usosrst'
        pins = json.loads((rst / 'manifest.json').read_text())
        for rel, digest in pins['files'].items():
            self.assertEqual(hashlib.sha256((rst / rel).read_bytes()).hexdigest(), digest, rel)
        c = (rst / 'src/usosrst.c').read_bytes()
        self.assertIn(b'SPDX-License-Identifier: GPL-3.0-or-later', c)
        for want in (b'IoRegisterLastChanceShutdownNotification', b'KeRegisterBugCheckCallback', b'SystemSetupInProgress',
                     b'0xCF9', b'(PUCHAR)0x64, 0xFE', b'FindModule("setupdd.sys")', b'HalReturnToFirmware',
                     b'MmBuildMdlForNonPagedPool', b'KeSetTimerEx', b'KeSetTargetProcessorDpc', b'HalGetBusData',
                     b'"RS STALL "', b'HB_STALL_TICKS'):
            self.assertIn(want, c)
        self.assertIn(b'MODIFIED version of AHCINT 1.3.0.0', files['MODIFIED.txt'])
        self.assertIn(b'usos2', files['MODIFIED.txt'])
        self.assertIn(b'usos3', files['MODIFIED.txt'])
        self.assertIn(b'1.3.0.0-usos4', files['SOURCE.txt'])
        self.assertEqual(struct.unpack_from('<H', files['uniata/uniata.sys'], struct.unpack_from('<I', files['uniata/uniata.sys'], 60)[0] + 4)[0], 0x14c)
        self.assertIn(b'Version 2, June 1991', files['uniata/COPYING-GPL-2.0.txt'])
        self.assertEqual(struct.unpack_from('<H', files['ahcint.sys'], struct.unpack_from('<I', files['ahcint.sys'], 60)[0] + 4)[0], 0x14c)
        self.assertIn(b'DriverVer=09/29/2026,1.3.0.0', files['ahcint.inf'])
        self.assertIn(b'GNU GENERAL PUBLIC LICENSE', files['LICENSE'])
        self.assertIn(b'Version 3, 29 June 2007', files['LICENSE'])
        self.assertIn('usr/lib/usos/w2k-drivers/', builder.PACKAGE_PREFIXES)
        # The corresponding source is tracked next to the binary, every file pinned.
        for folder in ('1.3.0.0', '1.3.0.0-usos4'):
            pins = json.loads((ROOT / 'tools/vendor/ahcint' / folder / 'manifest.json').read_text())
            for rel, digest in pins['files'].items():
                self.assertEqual(hashlib.sha256((ROOT / 'tools/vendor/ahcint' / folder / rel).read_bytes()).hexdigest(), digest, rel)
            self.assertIn('src/ahcimain.c', pins['files'])
        # The patched source carries the USOS markers.
        src = (ROOT / 'tools/vendor/ahcint/1.3.0.0-usos4/src/ahcisatl.c').read_bytes()
        self.assertIn(b'MODIFIED (USOS 1.3.0.0-usos1)', src)
        self.assertIn(b'MODIFIED (USOS 1.3.0.0-usos3)', src)
        self.assertIn(b'MODIFIED (USOS 1.3.0.0-usos4)', src)
        # usos4: the stall watchdog, timer and counters (X470 4 % stop).
        for want in (b'AhciUsosStallSnapshot', b'RequestTimerCall', b'"idle20s"', b'"busreset"', b'USOS_STALL_USEC'):
            self.assertIn(want, src + (ROOT / 'tools/vendor/ahcint/1.3.0.0-usos4/src/ahcint.h').read_bytes()
                          + (ROOT / 'tools/vendor/ahcint/1.3.0.0-usos4/src/ahcimain.c').read_bytes())
        self.assertIn(b'USOSW2KTRACE'[:4], (ROOT / 'tools/vendor/ahcint/1.3.0.0-usos4/src/ahcisatl.c').read_bytes())
        # usos3: the STOP code and the stages the X470 diagnosis relies on.
        h = (ROOT / 'tools/vendor/ahcint/1.3.0.0-usos4/src/ahcint.h').read_bytes()
        for want in (b'#define USOS_BUGCHECK_CODE              0x55534F53', b'USOS_STAGE_LBA0', b'USOS_STAGE_FLUSH', b'USOS_STAGE_BUGCHECK'):
            self.assertIn(want, h)
        for want in (b'AhciUsosBugCheckCallback', b'AhciUsosAfterWrite', b'"MARKER-READ-FAIL"', b'0xB8000'):
            self.assertIn(want, src)
        # usos5: a read-back mismatch is traced, never a STOP (the compared
        # buffer is the caller's live pages; X470 2000 Server SP4 STOP
        # 0x55534F53 (3, 43C81022, 2, 01E69238) at component registration).
        self.assertIn(b'MODIFIED (USOS 1.3.0.0-usos5)', src)
        self.assertIn(b'"rb-mismatch"', src)
        self.assertNotIn(b'"RB-FAIL"', src)
        self.assertNotIn(b'AhciUsosFail(HwInit, 3,', src)
        for sysfile in ('bin/2KXP/i386/ahcint.sys', 'bin/NT4/i386/ahcint.sys', 'bin/NT351/i386/ahcint.sys'):
            binary = (ROOT / 'tools/vendor/ahcint/1.3.0.0-usos4' / sysfile).read_bytes()
            self.assertIn(b'rb-mismatch', binary, sysfile)
            self.assertNotIn(b'RB-FAIL', binary, sysfile)
        pins = json.loads((ROOT / 'tools/vendor/uniata/0.47b/manifest.json').read_text())
        for rel, digest in pins['files'].items():
            self.assertEqual(hashlib.sha256((ROOT / 'tools/vendor/uniata/0.47b' / rel).read_bytes()).hexdigest(), digest, rel)

    def test_usosvid(self):
        # usosvid: own source next to the pinned binary, every file pinned; the
        # export names of the Windows 2000 BOOTVID.DLL and only kernel imports
        # the 2000 SP4 ntoskrnl exports.
        vid = ROOT / 'tools/w2k/usosvid'
        pins = json.loads((vid / 'manifest.json').read_text())
        for rel, digest in pins['files'].items():
            self.assertEqual(hashlib.sha256((vid / rel).read_bytes()).hexdigest(), digest, rel)
        c = (vid / 'src/usosvid.c').read_bytes()
        self.assertIn(b'SPDX-License-Identifier: GPL-3.0-or-later', c)
        exports = ('VidBitBlt', 'VidBufferToScreenBlt', 'VidCleanUp', 'VidDisplayString', 'VidDisplayStringXY', 'VidInitialize',
                   'VidResetDisplay', 'VidScreenToBufferBlt', 'VidSetScrollRegion', 'VidSetTextColor', 'VidSolidColorFill')
        for name, size in zip(exports, (12, 24, 0, 4, 16, 4, 4, 24, 16, 4, 20)):
            self.assertIn(f'{name}@{size}'.encode(), pins['exports'].encode())
        dll = (vid / 'bin/i386/bootvid.dll').read_bytes()
        pe = struct.unpack_from('<I', dll, 60)[0]
        self.assertEqual(struct.unpack_from('<H', dll, pe + 4)[0], 0x14c)
        self.assertTrue(struct.unpack_from('<H', dll, pe + 22)[0] & 0x2000)        # IMAGE_FILE_DLL
        for name in exports:
            self.assertIn(name.encode() + b'\0', dll)
        self.assertIn(b'BOOTVID.DLL\0', dll)
        self.assertIn(b'ntoskrnl.exe\0', dll)
        self.assertNotIn(b'HAL.dll', dll)
        for name in (b'MmMapIoSpace', b'MmUnmapIoSpace'):
            self.assertIn(name, dll)
        # 1.1 heartbeat: a periodic kernel timer DPC (all exported by the 2000
        # SP4 ntoskrnl), rows 16-21 while text-mode Setup runs with /NOGUIBOOT.
        for name in (b'MmIsAddressValid', b'KeTickCount', b'KeInitializeDpc', b'KeInitializeTimerEx', b'KeSetTimerEx', b'KeCancelTimer'):
            self.assertIn(name, dll)
        self.assertIn(b'usosvid 1.2', dll)
        # 1.2: the CSMWrap usos6 ACPI-enable record (BDA 4F4h) on row 12
        self.assertIn(b' en=', dll)

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
            (folder / 'BOOTVID.DL_').write_bytes(b'ms')
        (t / 'root/TXTSETUP.SIF').write_bytes(W2K_TXTSETUP)
        (bt / 'WINNT.SIF').write_bytes(W2K_WINNT)
        (ls / 'DOSNET.INF').write_bytes(W2K_DOSNET)
        (ls / 'HIVESYS.INF').write_bytes('ď»ż[AddReg]\r\n'.encode('utf-16-le'))
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
                self.assertIn(b'[W2K_STAGE] APPLIED PASS AHCINT 1.3.0.0-usos4', r.stdout)
                sif = run_fn('usos_w2k_storage_sif', W2K_TXTSETUP).stdout
                # the clock default; with ACPI kept also /SOS for the text boot video (8.)
                sif = run_fn('usos_w2k_hpet_sif "/USOSHPETLEGOFF /USOSRTCFIX' + ('' if acpi == 'off' else ' /SOS') + '"', sif).stdout
                if acpi == 'off':  # default (empty) keeps ACPI since 2026-10-03
                    sif = run_fn('usos_w2k_acpi_off_sif', sif).stdout
                    self.assertIn(b'ACPI off', r.stdout)
                inf = run_fn('usos_w2k_ahcint_inf', pkg['ahcint.inf']).stdout
                for folder in (bt, ls):
                    self.assertEqual((folder / 'ahcint.sys').read_bytes(), pkg['ahcint.sys'])
                    self.assertEqual((folder / 'usosrst.sys').read_bytes(), pkg['usosrst.sys'])
                    self.assertEqual((folder / 'ahcint.inf').read_bytes(), inf)
                    self.assertFalse((folder / 'AHCINT.SY_').exists())
                    self.assertEqual((folder / 'usosw2k.inf').read_bytes(),
                                     run_fn(f'USOS_W2K_HPET=legacy-off USOS_W2K_RTC=fix USOS_W2K_ACPI={acpi or "on"} usos_w2k_hive_inf', b'').stdout)
                    self.assertEqual(b'"PagedPoolSize",0x00010001,0xFFFFFFFF' in (folder / 'usosw2k.inf').read_bytes(), acpi == 'off')
                    self.assertEqual((folder / 'TXTSETUP.SIF').read_bytes(), sif)
                self.assertEqual((t / 'root/TXTSETUP.SIF').read_bytes(), sif)
                self.assertIn(b'ACPIEnable = ' + (b'0' if acpi == 'off' else b'2') + b'\r\n', sif)
                # The GUI-mode source copy (text mode moves the one above).
                self.assertEqual((ls / 'AHCINT/ahcint.sys').read_bytes(), pkg['ahcint.sys'])
                self.assertIn(b'd1,ahcint.inf', (ls / 'DOSNET.INF').read_bytes())
                self.assertIn(b'd1,usosrst.sys', (ls / 'DOSNET.INF').read_bytes())
                self.assertIn(b'usosrst on', r.stdout)
                # Text boot video (8.): ~BT only, ACPI kept only; ~LS keeps Microsoft's file.
                self.assertEqual((ls / 'BOOTVID.DL_').read_bytes(), b'ms')
                if acpi == 'off':
                    self.assertEqual((bt / 'BOOTVID.DL_').read_bytes(), b'ms')
                    self.assertFalse((bt / 'BOOTVID.DLL').exists())
                    self.assertNotIn(b'text boot video', r.stdout)
                else:
                    self.assertEqual((bt / 'BOOTVID.DLL').read_bytes(), pkg['usosvid/bootvid.dll'])
                    self.assertFalse((bt / 'BOOTVID.DL_').exists())
                    self.assertIn(b'text boot video usosvid + /SOS (~BT)', r.stdout)
                # WINNT.SIF is written later (prepare_xp_windows_partition.sh); apply only checks.
                self.assertEqual((bt / 'WINNT.SIF').read_bytes(), W2K_WINNT)
                self.assertIn(b'HAL MPS Multiprocessor' if acpi == 'off' else b'HAL chosen by Setup', r.stdout)
                # The answers: the standard keyboard always; the MPS HAL pinned with ACPI off.
                computer = b'ComputerType = "MPS Multiprocessor PC","Retail"\r\n' if acpi == 'off' else b''
                a = sh(f"{'USOS_W2K_ACPI=' + acpi if acpi else ':'}; export USOS_W2K_ACPI USOS_W2K_HAL; . '{LIB}'; usos_w2k_answer_sif '{posix(ls / 'TXTSETUP.SIF')}'", W2K_WINNT)
                self.assertEqual(a.returncode, 0, a.stderr)
                self.assertEqual(a.stdout, W2K_WINNT.replace(b'[Unattended]\r\n', b'[Unattended]\r\nOemPreinstall=Yes\r\n' + computer) +
                                 b'[GuiUnattended]\r\nOemSkipWelcome=1\r\n' + b'[KeyboardDrivers]\r\n"' + KBD + b'" = "Retail"\r\n')
                # HIVESYS.INF (UTF-16 on 2000) is left alone.
                self.assertEqual((ls / 'HIVESYS.INF').read_bytes(), hivesys)
                self.assertNotEqual(self.apply(t).returncode, 0)
                self.assertEqual((ls / 'TXTSETUP.SIF').read_bytes(), sif)

    def test_nvme_rows(self):
        # NVMe target (w2k_stage.sh 9.): usosnvme rows after AHCINT's, once.
        base = run_fn('usos_w2k_storage_sif', W2K_TXTSETUP).stdout
        r = run_fn('usos_w2k_nvme_sif', base)
        self.assertEqual(r.returncode, 0, r.stderr)
        out = rows(r.stdout)
        first = out.index('[SourceDisksFiles]')
        self.assertEqual(out[first + 1:first + 3], ['usosnvme.sys = 1,,,,,,4_,4,1,,,1,4', 'usosnvme.inf = 1,,,,,,,20,0,0'])
        self.assertEqual(out[out.index('[HardwareIdsDatabase]') + 1], 'PCI\\CC_010802 = "usosnvme"')
        self.assertEqual(out[out.index('[SCSI.Load]') + 1], 'usosnvme = usosnvme.sys,4')
        self.assertEqual(out[out.index('[SCSI]') + 1], 'usosnvme = "NVM Express Controller (usosnvme 1.0, USOS)"')
        self.assertEqual(len(out), len(rows(base)) + 5)
        self.assertEqual(run_fn('usos_w2k_nvme_sif', r.stdout).returncode, 3)                       # twice
        self.assertEqual(run_fn('usos_w2k_nvme_sif', base.replace(b'[SCSI.Load]', b'[Other]')).returncode, 3)
        # The INF: GUI-mode source \i386\usosnvme, legacy mode (no PnpInterface).
        inf = (ROOT / 'tools/nt/usosnvme/usosnvme.inf').read_bytes()
        r = run_fn('usos_w2k_nvme_inf', inf)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.count(b'\r\n'), r.stdout.count(b'\n'))
        out = rows(r.stdout)
        self.assertIn('1 = %DiskName%,,,\\i386\\usosnvme', out)
        self.assertIn('; USOS legacy mode (Windows 2000): HKR, "Parameters\\PnpInterface", "5", 0x00010001, 0x00000001', out)
        self.assertEqual(run_fn('usos_w2k_nvme_inf', r.stdout).returncode, 3)
        # usosw2k.inf: the class code -> usosnvme only for an NVMe target.
        row = 'HKLM,"SYSTEM\\CurrentControlSet\\Control\\CriticalDeviceDatabase\\pci#cc_010802","Service",0x00000000,"usosnvme"'
        self.assertIn(row, rows(run_fn('USOS_W2K_NVME=on usos_w2k_hive_inf', b'').stdout))
        self.assertNotIn(b'usosnvme', run_fn('usos_w2k_hive_inf', b'').stdout)
        d = run_fn('USOS_W2K_NVME=on usos_w2k_dosnet', W2K_DOSNET).stdout
        self.assertEqual(d.count(b'd1,usosnvme.sys\r\n'), 2)
        self.assertEqual(d.count(b'd1,usosnvme.inf\r\n'), 2)
        self.assertEqual(run_fn('USOS_W2K_NVME=on usos_w2k_dosnet', d).returncode, 3)
        self.assertNotIn(b'usosnvme', run_fn('usos_w2k_dosnet', W2K_DOSNET).stdout)
        # The NVMe gate: XP / 2003 pass; 2000 (both editions share NT5_SYSTEM
        # windows-2000) only with DATA's nvme-experimental.txt (no QEMU desktop
        # pass yet, docs/nvme-nt-2026-10-11.md section 8).
        stage = (ROOT / 'tools/legacy_xp_staging.sh').read_text()
        self.assertIn('windows-xp|windows-server-2003) ;;', stage)
        self.assertIn('windows-2000) [ -f "/mnt/data/Systems/Windows/$NT5_NAME/Unattended/nvme-experimental.txt" ] || stop', stage)

    def test_apply_nvme(self):
        import build_xp_uefi_csm_trial as builder
        pkg = builder.w2k_driver_files()
        for acpi in ('off', 'on'):
            with tempfile.TemporaryDirectory() as tmp:
                t = Path(tmp)
                bt, ls = self.stand_in(t)
                sata = self.apply(t, f'TARGET_DEVICE=/dev/sda USOS_W2K_ACPI={acpi}')
                self.assertEqual(sata.returncode, 0, sata.stdout + sata.stderr)
                self.assertNotIn(b'usosnvme', sata.stdout)
                self.assertNotIn(b'usosnvme', (ls / 'TXTSETUP.SIF').read_bytes())
                self.assertFalse((ls / 'USOSNVME').exists())
            with tempfile.TemporaryDirectory() as tmp:
                t = Path(tmp)
                bt, ls = self.stand_in(t)
                (bt / 'USOSNVME.SY_').write_bytes(b'stale')
                r = self.apply(t, f'TARGET_DEVICE=/dev/nvme0n1 USOS_W2K_ACPI={acpi}')
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                self.assertIn(b'NVMe target: usosnvme 1.0 (legacy mode, PCI\\CC_010802)', r.stdout)
                inf = run_fn('usos_w2k_nvme_inf', pkg['usosnvme/usosnvme.inf']).stdout
                for folder in (bt, ls):
                    self.assertEqual((folder / 'usosnvme.sys').read_bytes(), pkg['usosnvme/usosnvme.sys'])
                    self.assertEqual((folder / 'usosnvme.inf').read_bytes(), inf)
                    self.assertFalse((folder / 'USOSNVME.SY_').exists())
                    self.assertEqual((folder / 'ahcint.sys').read_bytes(), pkg['ahcint.sys'])           # AHCINT stays
                    self.assertIn(b'pci#cc_010802","Service",0x00000000,"usosnvme"', (folder / 'usosw2k.inf').read_bytes())
                    sif = rows((folder / 'TXTSETUP.SIF').read_bytes())
                    self.assertIn('usosnvme = usosnvme.sys,4', sif)
                    self.assertIn('ahcint = ahcint.sys,4', sif)
                    self.assertIn('ACPIEnable = ' + ('0' if acpi == 'off' else '2'), sif)
                self.assertIn('PCI\\CC_010802 = "usosnvme"', rows((t / 'root/TXTSETUP.SIF').read_bytes()))
                self.assertEqual((ls / 'USOSNVME/usosnvme.sys').read_bytes(), pkg['usosnvme/usosnvme.sys'])
                self.assertIn(b'd1,usosnvme.inf', (ls / 'DOSNET.INF').read_bytes())
            with tempfile.TemporaryDirectory() as tmp:
                t = Path(tmp)
                bt, ls = self.stand_in(t)
                (t / 'pkg/usosnvme/usosnvme.sys').unlink()
                r = self.apply(t, f'TARGET_DEVICE=/dev/nvme0n1 USOS_W2K_ACPI={acpi}')
                self.assertNotEqual(r.returncode, 0)
                self.assertIn(b'the target is NVMe but', r.stdout)
                self.assertEqual((ls / 'TXTSETUP.SIF').read_bytes(), W2K_TXTSETUP)                # nothing written
                self.assertEqual(self.apply(t, 'USOS_W2K_NVME=maybe').returncode, 1)
                # SATA targets do not need it.
                self.assertEqual(self.apply(t, f'USOS_W2K_ACPI={acpi}').returncode, 0)

    def test_user_acpi_package(self):
        # DATA Unattended\acpi\ (w2k_stage.sh 5.): a new .sys is an extra boot driver
        # (usosrst-style rows after usosrst), a name the source has replaces that file
        # (compressed copy removed), sources/READMEs are ignored; ACPI stays on.
        import build_xp_uefi_csm_trial as builder
        pkg = builder.w2k_driver_files()
        with tempfile.TemporaryDirectory() as tmp:
            t = Path(tmp)
            bt, ls = self.stand_in(t)
            for folder in (bt, ls):
                (folder / 'ACPI.SY_').write_bytes(b'stock')
            acpi = t / 'acpi'
            (acpi / 'TestX470').mkdir(parents=True)
            (acpi / 'TestX470/acpi_w2k.sys').write_bytes(b'MZ user driver')
            (acpi / 'acpi.sys').write_bytes(b'MZ user acpi')
            (acpi / 'README.txt').write_bytes(b'readme')
            (acpi / 'acpi_w2k_main.c').write_bytes(b'int x;')
            env = f"USOS_W2K_ACPI_PKG='{posix(acpi)}'"
            r = self.apply(t, env)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn(b'; user ACPI package: boot driver acpi_w2k.sys, replaces acpi.sys', r.stdout)
            self.assertIn(b'ACPI kept', r.stdout)
            extra = 'USOS_W2K_ACPI_EXTRA=acpi_w2k'
            sif = run_fn(f'{extra} usos_w2k_storage_sif', W2K_TXTSETUP).stdout
            sif = run_fn('usos_w2k_hpet_sif "/USOSHPETLEGOFF /USOSRTCFIX /SOS"', sif).stdout
            for folder in (bt, ls):
                self.assertEqual((folder / 'acpi_w2k.sys').read_bytes(), b'MZ user driver')
                self.assertEqual((folder / 'acpi.sys').read_bytes(), b'MZ user acpi')
                self.assertFalse((folder / 'ACPI.SY_').exists())
                self.assertFalse((folder / 'README.txt').exists())
                self.assertEqual((folder / 'TXTSETUP.SIF').read_bytes(), sif)
                self.assertEqual((folder / 'usosw2k.inf').read_bytes(), run_fn(f'USOS_W2K_HPET=legacy-off USOS_W2K_RTC=fix {extra} usos_w2k_hive_inf', b'').stdout)
            out = rows(sif)
            self.assertIn('acpi_w2k.sys = 1,,,,,,4_,4,1,,,1,4', out)
            load = out.index('[BootBusExtenders.Load]')
            self.assertEqual(out[load + 1:load + 3], ['usosrst  = usosrst.sys', 'acpi_w2k = acpi_w2k.sys'])
            bb = out.index('[BootBusExtenders]')
            self.assertEqual(out[bb + 2], 'acpi_w2k = "User ACPI package driver acpi_w2k.sys (DATA, USOS)",files.acpi_w2k,acpi_w2k')
            self.assertEqual(out[-7:], ['', '[files.usosrst]', 'usosrst.sys,4', '', '[files.acpi_w2k]', 'acpi_w2k.sys,4', ''])
            self.assertIn('ACPIEnable = 2', out)
            self.assertEqual(run_fn(f'{extra} usos_w2k_storage_sif', sif).returncode, 3)
            # Without usosrst the extra driver still gets its rows.
            alone = rows(run_fn(f'{extra} USOS_W2K_USOSRST=off usos_w2k_storage_sif', W2K_TXTSETUP).stdout)
            self.assertEqual(alone[alone.index('[BootBusExtenders.Load]') + 1], 'acpi_w2k = acpi_w2k.sys')
            svc = 'HKLM,"SYSTEM\\CurrentControlSet\\Services\\acpi_w2k",'
            hive = rows((ls / 'usosw2k.inf').read_bytes())
            for row in ('"Type",0x00010001,1', '"Start",0x00010001,0', '"ErrorControl",0x00010001,0',
                        '"Group",0x00000000,"Boot Bus Extender"', '"ImagePath",0x00020000,"System32\\DRIVERS\\acpi_w2k.sys"'):
                self.assertIn(svc + row, hive)
            dosnet = (ls / 'DOSNET.INF').read_bytes()
            self.assertEqual(dosnet.count(b'd1,acpi_w2k.sys\r\n'), 2)
            self.assertEqual(run_fn(f'{extra} usos_w2k_dosnet', dosnet).returncode, 3)
            # The default (no package) is unchanged by the new code.
            self.assertNotIn(b'acpi_w2k', run_fn('usos_w2k_storage_sif', W2K_TXTSETUP).stdout)
            self.assertEqual((bt / 'ahcint.sys').read_bytes(), pkg['ahcint.sys'])
        # Refusals, before anything is written.
        for setup, env2, msg in (
                (lambda a: None, 'USOS_W2K_ACPI=off', b'needs ACPI on'),
                (lambda a: (a / 'x.txt').write_bytes(b'x'), '', b'has no .sys or .dll file'),
                (lambda a: (a / 'newhal.dll').write_bytes(b'MZ'), '', b'newhal.dll is not a file of this source'),
                (lambda a: (a / 'usosrst.sys').write_bytes(b'MZ'), '', b'usosrst.sys is a USOS driver name'),
                (lambda a: (a / 'bad-name.sys').write_bytes(b'MZ'), '', b'is not a valid service name'),
                (lambda a: ((a / 'd').mkdir(), (a / 'd/one.sys').write_bytes(b'MZ'), (a / 'ONE.SYS').write_bytes(b'MZ')), '', b'has one.sys twice')):
            with tempfile.TemporaryDirectory() as tmp:
                t = Path(tmp)
                bt, ls = self.stand_in(t)
                acpi = t / 'acpi'
                acpi.mkdir()
                (acpi / 'ok.sys').write_bytes(b'MZ') if msg == b'needs ACPI on' else setup(acpi)
                r = self.apply(t, f"{env2} USOS_W2K_ACPI_PKG='{posix(acpi)}'")
                self.assertNotEqual(r.returncode, 0)
                self.assertIn(msg, r.stdout)
                self.assertEqual((ls / 'TXTSETUP.SIF').read_bytes(), W2K_TXTSETUP)
                self.assertFalse((bt / 'ahcint.sys').exists())
        stage = (ROOT / 'tools/legacy_xp_staging.sh').read_text()
        self.assertIn('USOS_W2K_ACPI_PKG="/mnt/data/Systems/Windows/$NT5_NAME/Unattended/acpi"', stage)
        self.assertIn("acpi-off.txt and the user ACPI package (Unattended\\acpi) exclude each other", stage)
        self.assertIn('export USOS_W2K_ACPI USOS_W2K_STORAGE USOS_W2K_HAL USOS_W2K_HPET USOS_W2K_RTC USOS_W2K_ACPI_PKG', stage)

    def test_acpi_off_isapnp(self):
        # ACPI off: isapnp stays a text-mode boot bus extender (text mode needs it
        # for the keyboard); only the installed system's Start = 4 comes from usosw2k.inf.
        sif = (b'[BootBusExtenders.Load]\r\npci      = pci.sys\r\nisapnp   = isapnp.sys\r\n[BootBusExtenders]\r\n'
               b'isapnp   = "ISA PnP",files.isapnp,isapnp \r\n[ACPIOptions]\r\nACPIEnable = 2\r\n')
        r = run_fn('usos_w2k_acpi_off_sif', sif)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, sif.replace(b'ACPIEnable = 2', b'ACPIEnable = 0'))
        # ACPI off: paged pool and registry quota rows (QEMU: no more 1450), nothing with ACPI kept.
        on, off = run_fn('usos_w2k_hive_inf', b'').stdout, run_fn('USOS_W2K_ACPI=off usos_w2k_hive_inf', b'').stdout
        rows_off = [b'HKLM,"SYSTEM\\CurrentControlSet\\Control","RegistrySizeLimit",0x00010001,0x08000000\r\n',
                    b'HKLM,"SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Memory Management","PagedPoolSize",0x00010001,0xFFFFFFFF\r\n']
        for row in rows_off:
            self.assertIn(row, off)
            self.assertNotIn(row, on)
        self.assertEqual(off.replace(b''.join(rows_off), b''), on)
        self.assertNotIn(b'isapnp', off)

    def test_answer_rows(self):
        # The descriptions exactly as the source spells them (localized, ANSI).
        r = run_fn('usos_w2k_sif_desc keyboard standard', W2K_TXTSETUP)
        self.assertEqual((r.returncode, r.stdout), (0, KBD))
        self.assertEqual(run_fn('usos_w2k_sif_desc Computer E_ISA_UP', W2K_TXTSETUP).stdout, 'Standardowy komputer PC'.encode('cp1250'))
        self.assertEqual(run_fn('usos_w2k_sif_desc computer mps_mp', W2K_TXTSETUP).stdout, b'MPS Multiprocessor PC')
        self.assertEqual(run_fn('usos_w2k_sif_desc computer mps_up', W2K_TXTSETUP).returncode, 3)
        self.assertEqual(run_fn('usos_w2k_sif_desc map.keyboard standard', W2K_TXTSETUP).returncode, 3)  # no quoted text
        # ANSI (CP1250) bytes pass through unchanged, into WINNT.SIF as well.
        mouse = 'Brak myszy lub innego urządzenia wskazującego'.encode('cp1250')
        self.assertEqual(run_fn('usos_w2k_sif_desc mouse none', b'[Mouse]\r\nnone     = "' + mouse + b'",files.none,""\r\n').stdout, mouse)
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / 'desc').write_bytes(mouse)
            r = run_fn(f'usos_w2k_hw_sif "$(cat \'{posix(Path(tmp) / "desc")}\')" "$(cat \'{posix(Path(tmp) / "desc")}\')"', W2K_WINNT)
        self.assertIn(b'ComputerType = "' + mouse + b'","Retail"\r\n', r.stdout)
        self.assertTrue(r.stdout.endswith(b'[GuiUnattended]\r\nOemSkipWelcome=1\r\n' + b'[KeyboardDrivers]\r\n"' + mouse + b'" = "Retail"\r\n'))
        # WINNT.SIF: rows added once (preinstall mode: setupdd.sys reads the component
        # answers only then), an older OemPreinstall / ComputerType / [KeyboardDrivers] replaced.
        r = run_fn('usos_w2k_hw_sif "Standard PC" "Std kbd"', W2K_WINNT)
        self.assertEqual(r.returncode, 0, r.stderr)
        want = W2K_WINNT.replace(b'[Unattended]\r\n', b'[Unattended]\r\nOemPreinstall=Yes\r\nComputerType = "Standard PC","Retail"\r\n') + \
            b'[GuiUnattended]\r\nOemSkipWelcome=1\r\n' + b'[KeyboardDrivers]\r\n"Std kbd" = "Retail"\r\n'
        self.assertEqual(r.stdout, want)
        self.assertEqual(run_fn('usos_w2k_hw_sif "Standard PC" "Std kbd"', r.stdout).stdout, want)
        old = W2K_WINNT.replace(b'[Unattended]\r\n', b'[Unattended]\r\nComputerType="Other",OEM\r\nOemPreinstall=No\r\n') + \
            b'[KeyboardDrivers]\r\n"X" = "OEM"\r\n[Display]\r\nBitsPerPel=16\r\n'
        self.assertEqual(run_fn('usos_w2k_hw_sif "" "Std kbd"', old).stdout,
                         W2K_WINNT.replace(b'[Unattended]\r\n', b'[Unattended]\r\nOemPreinstall=Yes\r\n') +
                         b'[Display]\r\nBitsPerPel=16\r\n' + b'[GuiUnattended]\r\nOemSkipWelcome=1\r\n' + b'[KeyboardDrivers]\r\n"Std kbd" = "Retail"\r\n')
        # An answer file that already decides the Welcome page keeps its choice.
        own = W2K_WINNT + b'[GuiUnattended]\r\nOemSkipWelcome=0\r\n'
        self.assertEqual(run_fn('usos_w2k_hw_sif "" "k"', own).stdout.count(b'OemSkipWelcome'), 1)
        self.assertEqual(run_fn('usos_w2k_hw_sif "" "k"', b'[Data]\r\nx=1\r\n').returncode, 3)

    def test_apply_hal(self):
        with tempfile.TemporaryDirectory() as tmp:
            t = Path(tmp)
            bt, ls = self.stand_in(t)
            self.assertIn(b'USOS_W2K_HAL needs ACPI off', self.apply(t, 'USOS_W2K_HAL=standard').stdout)
            self.assertIn(b'USOS_W2K_HAL must be', self.apply(t, 'USOS_W2K_ACPI=off USOS_W2K_HAL=acpi').stdout)
            self.assertFalse((bt / 'ahcint.sys').exists())
            r = self.apply(t, 'USOS_W2K_ACPI=off USOS_W2K_HAL=standard')
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn(b'HAL Standard PC (ComputerType)', r.stdout)
            a = sh(f"USOS_W2K_ACPI=off USOS_W2K_HAL=standard; export USOS_W2K_ACPI USOS_W2K_HAL; . '{LIB}'; usos_w2k_answer_sif '{posix(ls / 'TXTSETUP.SIF')}'", W2K_WINNT)
            self.assertIn(b'ComputerType = "Standardowy komputer PC","Retail"\r\n', a.stdout)
            bad = sh(f"USOS_W2K_HAL=mps; export USOS_W2K_ACPI USOS_W2K_HAL; . '{LIB}'; usos_w2k_answer_sif '{posix(ls / 'TXTSETUP.SIF')}'", W2K_WINNT)
            self.assertEqual((bad.returncode, bad.stdout), (1, b''))
            self.assertIn(b'USOS_W2K_HAL needs ACPI off', bad.stderr)
            bad = sh(f":; export USOS_W2K_ACPI USOS_W2K_HAL; . '{LIB}'; usos_w2k_answer_sif '{posix(ls / 'TXTSETUP.SIF')}'", b'[Data]\r\n')
            self.assertIn(b'no [Unattended] section', bad.stderr)
        # Without the keyboard row (or a pinned HAL's row) nothing is written.
        for env, edit, msg in (('USOS_W2K_ACPI=off', (b'STANDARD    =', b'OTHER    ='), b'no [Keyboard] STANDARD row'),
                               ('USOS_W2K_ACPI=off', (b'mps_mp      =', b'other_mp    ='), b'no [Computer] mps_mp row'),
                               ('USOS_W2K_ACPI=off USOS_W2K_HAL=standard', (b'e_isa_up    =', b'other_up    ='), b'no [Computer] e_isa_up row')):
            with tempfile.TemporaryDirectory() as tmp:
                t = Path(tmp)
                bt, ls = self.stand_in(t)
                (ls / 'TXTSETUP.SIF').write_bytes(W2K_TXTSETUP.replace(*edit))
                before = (ls / 'TXTSETUP.SIF').read_bytes()
                r = self.apply(t, env)
                self.assertNotEqual(r.returncode, 0)
                self.assertIn(msg, r.stdout)
                self.assertEqual((ls / 'TXTSETUP.SIF').read_bytes(), before)
                self.assertFalse((bt / 'ahcint.sys').exists())
        # The answer file is written where every NT5 UEFI answer is assembled.
        part = (ROOT / 'tools/prepare_xp_windows_partition.sh').read_text()
        self.assertIn('usos_w2k_answer_sif "${XP_TARGET_ROOT:?}/\\$WIN_NT\\$.~LS/I386/TXTSETUP.SIF"', part)
        self.assertLess(part.index('usos_w2k_answer_sif'), part.index('put_verified "$work/winnt.sif" WINNT.SIF'))
        stage = (ROOT / 'tools/legacy_xp_staging.sh').read_text()
        self.assertIn('Unattended/hal-standard.txt" ]; then USOS_W2K_HAL=standard; else USOS_W2K_HAL=auto; fi', stage)
        self.assertIn('export USOS_W2K_ACPI USOS_W2K_STORAGE USOS_W2K_HAL', stage)

    def test_gap_marker(self):
        r = run_fn('usos_w2k_gap_marker edc187d4', b'')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(r.stdout), 512)
        self.assertEqual(r.stdout[:12], b'USOSW2KTRACE')
        self.assertEqual(r.stdout[12:32], bytes(20))       # boot counter 0 at 16
        self.assertEqual(r.stdout[32:40], b'edc187d4')
        self.assertEqual(r.stdout[40:], bytes(472))
        # The driver uses the same magic and LBAs.
        h = (ROOT / 'tools/vendor/ahcint/1.3.0.0-usos4/src/ahcint.h').read_bytes()
        for want in (b'USOS_GAP_MARKER_LBA             2046', b'USOS_GAP_TEST_LBA               2045', b'USOS_GAP_TRACE_LBA              2040'):
            self.assertIn(want, h)
        c = (ROOT / 'tools/vendor/ahcint/1.3.0.0-usos4/src/ahcisatl.c').read_bytes()
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
            self.assertIn(b'USOS_W2K_USOSRST must be', self.apply(t, 'USOS_W2K_USOSRST=maybe').stdout)
            (t / 'pkg/usosrst.sys').rename(t / 'pkg/usosrst.bak')
            self.assertIn(b'usosrst.sys missing', self.apply(t).stdout)
            (t / 'pkg/usosrst.bak').rename(t / 'pkg/usosrst.sys')
            self.assertIn(b'STOP', self.apply(t, source_dir='AMD64').stdout)
            (t / 'pkg/ahcint.inf').unlink()
            self.assertIn(b'ahcint.inf missing', self.apply(t).stdout)
            self.assertEqual((ls / 'TXTSETUP.SIF').read_bytes(), W2K_TXTSETUP)


@unittest.skipIf(SH is None, 'sh not found')
class W2kServer(unittest.TestCase):
    """Windows 2000 Server (catalog windows-2000-server): the Server answers
    follow the CD's ProductType, the srvwiz.reg of the first logon, the
    edition switch in nt5_profile.sh and the probe's Professional refusal."""

    def source(self, text: bytes):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        path = Path(tmp.name) / 'TXTSETUP.SIF'
        path.write_bytes(text)
        return run_fn(f"usos_w2k_server_source '{posix(path)}'", b'').returncode

    def test_server_source(self):
        self.assertEqual(self.source(b'[SetupData]\r\nMajorVersion = 5\r\nProductType = 1\r\n'), 0)
        self.assertEqual(self.source(b'[SetupData]\r\nProductType=0\r\n'), 1)
        self.assertEqual(self.source(W2K_TXTSETUP), 1)  # no ProductType row
        # A ProductType in another section or a comment does not count.
        self.assertEqual(self.source(b'[Other]\r\nProductType = 1\r\n[SetupData]\r\n;ProductType = 1\r\n'), 1)

    def test_server_answers(self):
        # The unattended answer (usos-xp.ini / profile merged): every page answered.
        sif = W2K_WINNT + b'[GuiUnattended]\r\nAdminPassword=*\r\nOemSkipWelcome=1\r\n[UserData]\r\nComputerName=USOS\r\n'
        r = run_fn('usos_w2k_server_sif', sif)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.count(b'\r\n'), r.stdout.count(b'\n'))
        out = rows(r.stdout)
        self.assertEqual(out[out.index('[GuiUnattended]'):out.index('[UserData]')],
                         ['[GuiUnattended]', 'AdminPassword=*', 'OemSkipWelcome=1', 'AutoLogon=Yes', 'AutoLogonCount=1'])
        self.assertEqual(out[out.index('[LicenseFilePrintData]'):out.index('[LicenseFilePrintData]') + 3],
                         ['[LicenseFilePrintData]', 'AutoMode=PerServer', 'AutoUsers=5'])
        for key in ('iis_common', 'iis_www', 'iis_ftp', 'iis_smtp', 'iis_inetmgr', 'fp_extensions'):
            self.assertIn(f'{key}=Off', out)
        self.assertIn('[GuiRunOnce]', out)
        self.assertEqual(out[out.index('[GuiRunOnce]') + 1], 'Command0="regedit /s C:\\USOS\\W2K\\srvwiz.reg"')
        self.assertNotIn('dcpromo', r.stdout.decode().lower())
        # The answer file's own choices win; GuiRunOnce appends after its commands.
        own = sif + b'[LicenseFilePrintData]\r\nAutoMode=PerSeat\r\n[Components]\r\niis_www=On\r\n[GuiRunOnce]\r\nCommand0="notepad"\r\n'
        out = rows(run_fn('usos_w2k_server_sif', own).stdout)
        self.assertIn('AutoMode=PerSeat', out)
        self.assertNotIn('AutoMode=PerServer', out)
        self.assertIn('AutoUsers=5', out)
        self.assertIn('iis_www=On', out)
        self.assertNotIn('iis_www=Off', out)
        self.assertEqual(out.count('[LicenseFilePrintData]'), 1)
        self.assertEqual(out[out.index('[GuiRunOnce]'):out.index('[GuiRunOnce]') + 3],
                         ['[GuiRunOnce]', 'Command0="notepad"', 'Command1="regedit /s C:\\USOS\\W2K\\srvwiz.reg"'])
        # The interactive answer (no password answered): no automatic logon.
        out = rows(run_fn('usos_w2k_server_sif', W2K_WINNT).stdout)
        self.assertNotIn('AutoLogon=Yes', out)
        self.assertIn('AutoMode=PerServer', out)

    def test_server_reg(self):
        r = run_fn('usos_w2k_server_reg', b'')
        self.assertEqual(r.stdout, b'REGEDIT4\r\n\r\n[HKEY_CURRENT_USER\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Setup\\Welcome]\r\n'
                                   b'"srvwiz"=dword:00000000\r\n\r\n')

    def test_profile_edition(self):
        prof = posix(ROOT / 'tools' / 'nt5_profile.sh')
        show = 'usos_nt5_profile; printf "%s|%s|%s|%s" "$NT5_NAME" "$NT5_TITLE" "$NT5_SETUP_DIR" "$USOS_W2K_EDITION"'
        r = sh(f"NT5_SYSTEM=windows-2000 USOS_W2K_EDITION=server; . '{prof}'; {show}")
        self.assertEqual(r.stdout.decode(), 'Windows 2000 Server|WINDOWS 2000 SERVER|W2K|server')
        r = sh(f"NT5_SYSTEM=windows-2000 USOS_W2K_EDITION=; . '{prof}'; {show}")
        self.assertEqual(r.stdout.decode(), 'Windows 2000|WINDOWS 2000|W2K|')

    def test_probe_refuses_professional_in_server_entry(self):
        probe = posix(ROOT / 'tools' / 'probe_nt5_source.sh')
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'I386').mkdir()
            for marker in ('CDROM_NT.5', 'CDROM_IP.5', 'CDROMSP4.TST'):
                (root / marker).write_bytes(b'')
            for name in ('DOSNET.INF', 'SETUPLDR.BIN', 'NTLDR', 'NTDETECT.COM', 'USETUP.EXE', 'SETUPDD.SY_', 'NTOSKRNL.EX_', 'NTKRNLMP.EX_', 'BOOTVID.DL_', 'SP4.CAB'):
                (root / 'I386' / name).write_bytes(b'x')
            (root / 'I386' / 'TXTSETUP.SIF').write_bytes(b'[SetupData]\r\nMajorVersion = 5\r\nMinorVersion = 0\r\nProductType = 0\r\n')
            base = f"SOURCE_ROOT='{posix(root)}' NT5_SYSTEM=windows-2000"
            self.assertEqual(sh(f"{base} sh '{probe}'").returncode, 0)
            r = sh(f"{base} USOS_W2K_EDITION=server sh '{probe}'")
            self.assertNotEqual(r.returncode, 0)
            self.assertIn(b'Professional CD', r.stdout + r.stderr)


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
            self.assertEqual((ls / 'XHCI98/xhci98.sys').read_bytes(), pkg['x86-w2k/xhci98.sys'])   # usos3 (polling), 2000 only
            self.assertIn(b'1=%DiskName%,,,\\i386\\xhci98\r\n', (ls / 'xhci98.inf').read_bytes())


if __name__ == '__main__':
    unittest.main()
