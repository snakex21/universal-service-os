"""NT 5.2 (Server 2003 x86, XP x64) staging pieces, host-only, no Microsoft files:

- tools/nt5_storage_stage.sh usos_nt5_storage_sif: the GenAHCI rows go
  into the first block of each section, CRLF kept, a second run is refused;
  genahci.inf (package copy, GUI-mode source folder), HIVESYS.INF
  CriticalDeviceDatabase and DOSNET rows, apply on a stand-in target.
- tools/xp_dosnet_aliases.awk: aliases relative to the Setup source directory
  (I386 unchanged, AMD64 for XP x64, other directories refused).
- tools/nt5_profile.sh: one row per system (source dir, install dir, setup dir).
- tools/nt52_usb_stage.sh: xhci98 rows (TXTSETUP, INF source directory,
  DOSNET), the forced USB/HID stack, apply on a stand-in target, the pinned
  package files.
"""
from pathlib import Path
import os, shutil, struct, subprocess, sys, tempfile, unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
SH = next((p for p in (r'C:\msys64\usr\bin\sh.exe', r'C:\Program Files\Git\usr\bin\sh.exe', shutil.which('sh') or '') if p and Path(p).exists()), None)
# The shell's own coreutils (awk) first: PowerShell runs lack them on PATH.
if SH:
    os.environ['PATH'] = str(Path(SH).parent) + os.pathsep + os.environ.get('PATH', '')


def posix(path: Path) -> str:
    s = str(path.resolve()).replace('\\', '/')
    return '/' + s[0].lower() + s[2:] if s[1:2] == ':' else s


def sh(command: str, stdin: bytes = b'') -> subprocess.CompletedProcess:
    return subprocess.run([SH, '-c', command], input=stdin, capture_output=True)


TXTSETUP = (b'[SetupData]\r\nMajorVersion = 5\r\n[SourceDisksFiles]\r\nstorport.sys = 1,,,,,,3_,4,0,0,,1,4\r\n'
            b'[SourceDisksFiles.x86]\r\n[SourceDisksFiles]\r\nfoo.sys = 1\r\n[HardwareIdsDatabase]\r\nPCI\\VEN_8086&DEV_2922 = "iastor"\r\n'
            b'[SCSI.Load]\r\natapi = atapi.sys,4\r\n[SCSI]\r\natapi = "IDE"\r\n')
DOSNET = (b'[Directories]\r\nd1 = \\{top}\r\nd2 = \\I386\r\n[Files]\r\nd1,usetup.exe,system32\\smss.exe\r\n'
          b'd1,ntdll.dll,system32\\ntdll.dll\r\nd2,wntdll.dll\r\n')


@unittest.skipIf(SH is None, 'sh not found')
class Nt52Staging(unittest.TestCase):
    def test_storage_rows(self):
        lib = posix(ROOT / 'tools' / 'nt5_storage_stage.sh')
        r = sh(f". '{lib}'; usos_nt5_storage_sif", TXTSETUP)
        self.assertEqual(r.returncode, 0, r.stderr)
        out = r.stdout.decode()
        # BusyBox awk keeps the CR of the input lines, MSYS awk drops it: compare
        # the text; the inserted rows always end in CRLF.
        lines = [l.rstrip('\r') for l in out.split('\n')]
        self.assertTrue(all(l.endswith('\r') for l in out.split('\n') if l.startswith('genahci') or l.startswith('PCI\\CC_010601')))
        self.assertEqual(lines[lines.index('[SourceDisksFiles]') + 1:lines.index('[SourceDisksFiles]') + 3],
                         ['genahci.sys = 1,,,,,,4_,4,1,,,1,4', 'genahci.inf = 1,,,,,,,20,0,0'])
        self.assertEqual(out.count('genahci.sys = 1'), 1)
        self.assertEqual(lines[lines.index('[HardwareIdsDatabase]') + 1], 'PCI\\CC_010601 = "genahci"')
        self.assertEqual(lines[lines.index('[SCSI.Load]') + 1], 'genahci = genahci.sys,4')
        self.assertTrue(lines[lines.index('[SCSI]') + 1].startswith('genahci = "'))
        self.assertEqual(sh(f". '{lib}'; usos_nt5_storage_sif", r.stdout).returncode, 3)
        self.assertEqual(sh(f". '{lib}'; usos_nt5_storage_sif", b'[SetupData]\r\n').returncode, 3)

    def test_aliases_follow_the_source_directory(self):
        awk = posix(ROOT / 'tools' / 'xp_dosnet_aliases.awk')
        want = 'USETUP.EXE|SYSTEM32/SMSS.EXE\nNTDLL.DLL|SYSTEM32/NTDLL.DLL\n'
        for top, src in (('I386', ''), ('I386', 'I386'), ('amd64', 'AMD64')):
            r = sh(f"awk -v src_dir='{src}' -f '{awk}'", DOSNET.replace(b'{top}', top.encode()))
            self.assertEqual((r.returncode, r.stdout.decode()), (0, want), (top, src, r.stderr))
        self.assertEqual(sh(f"awk -v src_dir=I386 -f '{awk}'", DOSNET.replace(b'{top}', b'amd64')).returncode, 1)

    def test_profile_rows(self):
        lib = posix(ROOT / 'tools' / 'nt5_profile.sh')
        rows = {'windows-xp': 'I386 WINDOWS XP', 'windows-2000': 'I386 WINNT W2K',
                'windows-server-2003': 'I386 WINDOWS W2K3', 'windows-xp-x64': 'AMD64 WINDOWS XP64'}
        for system, want in rows.items():
            r = sh(f"NT5_SYSTEM={system}; . '{lib}'; usos_nt5_profile && printf '%s %s %s' \"$NT5_SOURCE_DIR\" \"$NT5_INSTALL_DIR\" \"$NT5_SETUP_DIR\"")
            self.assertEqual(r.stdout.decode(), want, system)
        for profile, generic in (('xp-x86-sp3-uefi-csm', 1), ('w2k3-x86-sp2-uefi-csm', 0), ('xp-x64-sp2-uefi-csm', 0), ('nt5-staging', 1)):
            r = sh(f"USOS_PLAN_PROFILE={profile}; . '{lib}'; usos_nt5_uefi_generic_profile")
            self.assertEqual(r.returncode, generic, profile)


HIVESYS = (b'\r\n[Version]\r\nSignature = "$Windows NT$"\r\n\r\n[AddReg]\r\n'
           b'HKLM,"SYSTEM\\CurrentControlSet\\Control\\CriticalDeviceDatabase\\gendisk",Service,0x00000000,disk\r\n'
           b'[AddReg.Fresh]\r\nHKLM,"SYSTEM\\Setup","SystemSetupInProgress",0x00010001,1\r\n[AddReg]\r\nHKLM,"SYSTEM\\Other",x,0x00000000,y\r\n')
CDDB = 'HKLM,"SYSTEM\\CurrentControlSet\\Control\\CriticalDeviceDatabase\\'
STORAGE_DOSNET = b'[Files]\r\nd1,storport.sys\r\n[FloppyFiles.1]\r\nd1,storport.sys\r\n[FloppyFiles.1]\r\nd1,hal.dll\r\n'


@unittest.skipIf(SH is None, 'sh not found')
class Nt52Storage(unittest.TestCase):
    """tools/nt5_storage_stage.sh: GenAHCI for text mode AND GUI mode (X470
    2026-09-29: without genahci.inf GUI-mode PnP installed a NULL driver and
    every later boot stopped with 0x7B)."""
    LIB = posix(ROOT / 'tools' / 'nt5_storage_stage.sh')

    def run_fn(self, fn: str, data: bytes) -> subprocess.CompletedProcess:
        return sh(f". '{self.LIB}'; {fn}", data)

    def test_hivesys_rows(self):
        r = self.run_fn('usos_nt5_storage_hivesys', HIVESYS)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.count(b'\r\n'), r.stdout.count(b'\n'))
        out = rows(r.stdout)
        first = out.index('[AddReg]')
        guid = '{4D36E97B-E325-11CE-BFC1-08002BE10318}'
        self.assertEqual(out[first + 1:first + 5], [
            CDDB + 'pci#cc_010601",Service,0x00000000,genahci', CDDB + 'pci#cc_010601",ClassGUID,0x00000000,' + guid,
            CDDB + 'pci#ven_1022&dev_43c8",Service,0x00000000,genahci', CDDB + 'pci#ven_1022&dev_43c8",ClassGUID,0x00000000,' + guid])
        # Only the first [AddReg] block; everything else unchanged, in order.
        self.assertEqual(sum('genahci' in l for l in out), 2)
        self.assertEqual(out[:first + 1] + out[first + 5:], rows(HIVESYS))
        self.assertEqual(self.run_fn('usos_nt5_storage_hivesys', r.stdout).returncode, 3)
        self.assertEqual(self.run_fn('usos_nt5_storage_hivesys', HIVESYS.replace(b'[AddReg]', b'[Other]')).returncode, 3)

    def test_dosnet(self):
        r = self.run_fn('usos_nt5_storage_dosnet', STORAGE_DOSNET)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, b'[Files]\r\nd1,genahci.sys\r\nd1,genahci.inf\r\nd1,storport.sys\r\n[FloppyFiles.1]\r\n'
                                   b'd1,genahci.sys\r\nd1,genahci.inf\r\nd1,storport.sys\r\n[FloppyFiles.1]\r\nd1,hal.dll\r\n')
        self.assertEqual(self.run_fn('usos_nt5_storage_dosnet', r.stdout).returncode, 3)
        self.assertEqual(self.run_fn('usos_nt5_storage_dosnet', b'[Files]\r\n').returncode, 3)

    def test_package_files(self):
        import build_xp_uefi_csm_trial as builder
        files = builder.nt5_storage_files()
        self.assertEqual(sorted(files), ['SOURCE.txt', 'amd64/genahci.cat', 'amd64/genahci.inf', 'amd64/genahci.sys',
                                         'gpl.txt', 'x86/genahci.cat', 'x86/genahci.inf', 'x86/genahci.sys'])
        for arch, sub in (('x86', 'i386'), ('amd64', 'amd64')):
            inf = files[arch + '/genahci.inf']
            self.assertTrue(inf.startswith(b'\xff\xfe'))
            text = inf[2:].decode('utf-16-le')
            # One line differs from the archive's INF: the GUI-mode source folder.
            self.assertIn('\r\n1 = %SERVICEDESCRIPTION%,,,\\' + sub + '\\genahci\r\n', text)
            self.assertIn('[Models.NT' + ('x86' if arch == 'x86' else 'amd64') + ']', text)
            self.assertIn('CatalogFile = genahci.cat', text)
            self.assertIn('%ADAPTERNAME% = genahci, "PCI\\CC_010601"', text)
        self.assertNotEqual(files['x86/genahci.cat'], files['amd64/genahci.cat'])

    def stand_in(self, t: Path, source_dir: str, pkg: dict) -> tuple:
        for rel, data in pkg.items():
            (t / 'pkg' / rel).parent.mkdir(parents=True, exist_ok=True)
            (t / 'pkg' / rel).write_bytes(data)
        bt, ls = t / 'root/$WIN_NT$.~BT', t / 'root/$WIN_NT$.~LS' / source_dir
        for folder in (bt, ls):
            folder.mkdir(parents=True)
            (folder / 'TXTSETUP.SIF').write_bytes(TXTSETUP)
            (folder / 'GENAHCI.SY_').write_bytes(b'stale')
        (t / 'root/TXTSETUP.SIF').write_bytes(TXTSETUP)
        (ls / 'DOSNET.INF').write_bytes(STORAGE_DOSNET)
        (ls / 'HIVESYS.INF').write_bytes(HIVESYS)
        return bt, ls

    def apply(self, t: Path, source_dir: str) -> subprocess.CompletedProcess:
        return sh(f"XP_TARGET_ROOT='{posix(t / 'root')}' NT5_SOURCE_DIR={source_dir} USOS_NT5_STORAGE_DIR='{posix(t / 'pkg')}' "
                  f"sh '{self.LIB}' apply")

    def test_apply(self):
        import build_xp_uefi_csm_trial as builder
        pkg = builder.nt5_storage_files()
        for source_dir, arch in (('I386', 'x86'), ('AMD64', 'amd64')):
            with tempfile.TemporaryDirectory() as tmp:
                t = Path(tmp)
                bt, ls = self.stand_in(t, source_dir, pkg)
                r = self.apply(t, source_dir)
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                self.assertIn(b'[NT5_STORAGE] APPLIED PASS genahci.sys+inf (' + arch.encode() + b')', r.stdout)
                sif = self.run_fn('usos_nt5_storage_sif', TXTSETUP).stdout
                # genahci.inf must be in the staged tree AND in TXTSETUP/DOSNET, or
                # GUI-mode PnP gives the boot controller a NULL driver (STOP 0x7B).
                for folder in (bt, ls):
                    self.assertEqual((folder / 'genahci.sys').read_bytes(), pkg[arch + '/genahci.sys'])
                    self.assertEqual((folder / 'genahci.inf').read_bytes(), pkg[arch + '/genahci.inf'])
                    self.assertFalse((folder / 'GENAHCI.SY_').exists())
                    self.assertEqual((folder / 'TXTSETUP.SIF').read_bytes(), sif)
                    self.assertIn(b'\r\ngenahci.inf = 1,,,,,,,20,0,0\r\n', (folder / 'TXTSETUP.SIF').read_bytes())
                self.assertEqual((t / 'root/TXTSETUP.SIF').read_bytes(), sif)
                # The GUI-mode source copy (text mode moves the one above).
                self.assertEqual((ls / 'GENAHCI/genahci.sys').read_bytes(), pkg[arch + '/genahci.sys'])
                self.assertEqual((ls / 'GENAHCI/genahci.cat').read_bytes(), pkg[arch + '/genahci.cat'])
                dosnet = (ls / 'DOSNET.INF').read_bytes()
                self.assertIn(b'[Files]\r\nd1,genahci.sys\r\nd1,genahci.inf\r\n', dosnet)
                self.assertIn(b'[FloppyFiles.1]\r\nd1,genahci.sys\r\nd1,genahci.inf\r\n', dosnet)
                self.assertEqual((ls / 'HIVESYS.INF').read_bytes(), self.run_fn('usos_nt5_storage_hivesys', HIVESYS).stdout)
                # A second apply refuses (already integrated) and leaves the files.
                self.assertNotEqual(self.apply(t, source_dir).returncode, 0)
                self.assertEqual((ls / 'TXTSETUP.SIF').read_bytes(), sif)

    def test_apply_refusals(self):
        import build_xp_uefi_csm_trial as builder
        pkg = builder.nt5_storage_files()
        for missing in ('amd64/genahci.inf', 'amd64/genahci.cat', 'HIVESYS.INF'):
            with tempfile.TemporaryDirectory() as tmp:
                t = Path(tmp)
                bt, ls = self.stand_in(t, 'AMD64', {k: v for k, v in pkg.items() if k != missing})
                if missing == 'HIVESYS.INF':
                    (ls / 'HIVESYS.INF').unlink()
                r = self.apply(t, 'AMD64')
                self.assertNotEqual(r.returncode, 0, missing)
                self.assertIn(b'STOP', r.stdout, missing)
                self.assertEqual((ls / 'TXTSETUP.SIF').read_bytes(), TXTSETUP, missing)


# The USB/HID rows as Microsoft's 5.2 media carry them (",4,1,3": do not
# copy at text-mode Setup), split over two [SourceDisksFiles] blocks.
USB_TXTSETUP = (b'[SetupData]\r\nMajorVersion = 5\r\n[SourceDisksFiles]\r\nfoo.sys = 1\r\n'
                b'usbport.sys   = 1,,,,,,4_,4,1,3,,1,4\r\nusbhub.sys    = 1,,,,,,4_,4,1,3,,1,4\r\n'
                b'usbd.sys        = 1,,,,,,4_,4,1,3,,1,4\r\nmouhid.sys   = 1,,,,,,,4,1,3,,1,4\r\n'
                b'[SourceDisksFiles.x86]\r\n[SourceDisksFiles]\r\nhidclass.sys = 1,,,,,,4_,4,1,3,,1,4\r\n'
                b'hidparse.sys = 1,,,,,,4_,4,1,3,,1,4\r\nhidusb.sys   = 1,,,,,,4_,4,1,3,,1,4\r\n'
                b'kbdhid.sys   = 1,,,,,,4_,4,1,3,,1,4\r\n'
                b'[HardwareIdsDatabase]\r\nPCI\\CC_0C0320 = "usbehci"\r\n[InputDevicesSupport.Load]\r\nusbehci  = usbehci.sys\r\n'
                b'[InputDevicesSupport]\r\nusbehci  = "Enhanced Host Controller",files.usbehci,usbehci\r\n[Strings]\r\ncdname = "CD"\r\n')
STACK = ('usbport.sys', 'usbd.sys', 'usbhub.sys', 'hidclass.sys', 'hidparse.sys', 'hidusb.sys', 'kbdhid.sys')
USB_DOSNET = b'[Files]\r\nd1,usbport.sys\r\n[FloppyFiles.1]\r\nd1,usbport.sys\r\n[FloppyFiles.1]\r\nd1,hal.dll\r\n'


def rows(out: bytes) -> list[str]:
    return [l.rstrip('\r') for l in out.decode().split('\n')]


@unittest.skipIf(SH is None, 'sh not found')
class Nt52Usb(unittest.TestCase):
    """tools/nt52_usb_stage.sh: xhci98 for Server 2003 x86 and XP x64."""
    LIB = posix(ROOT / 'tools' / 'nt52_usb_stage.sh')

    def run_fn(self, fn: str, data: bytes) -> subprocess.CompletedProcess:
        return sh(f". '{self.LIB}'; {fn}", data)

    def test_txtsetup_rows(self):
        r = self.run_fn('usos_nt52_usb_sif', USB_TXTSETUP)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn(b'\r\r', r.stdout)
        self.assertEqual(r.stdout.count(b'\r\n'), r.stdout.count(b'\n'))
        out = rows(r.stdout)
        first = out.index('[SourceDisksFiles]')
        self.assertEqual(out[first + 1:first + 3], ['xhci98.sys = 1,,,,,,4_,4,1,,,1,4', 'xhci98.inf = 1,,,,,,,20,0,0'])
        self.assertEqual(sum(l.startswith('xhci98.sys =') for l in out), 1)
        # The stack is forced to copy (0,0) in whichever block it sits; spacing kept.
        for name in STACK:
            row = next(l for l in out if l.startswith(name))
            self.assertTrue(row.endswith('= 1,,,,,,4_,4,0,0,,1,4'), row)
        self.assertIn('usbport.sys   = 1,,,,,,4_,4,0,0,,1,4', out)
        # mouhid.sys (not on the media outside DRIVER.CAB) keeps Microsoft's row.
        self.assertIn('mouhid.sys   = 1,,,,,,,4,1,3,,1,4', out)
        self.assertEqual(out[out.index('[HardwareIdsDatabase]') + 1], 'PCI\\CC_0C0330 = "xhci98"')
        self.assertEqual(out[out.index('[InputDevicesSupport.Load]') + 1], 'xhci98 = xhci98.sys')
        self.assertEqual(out[out.index('[InputDevicesSupport]') + 1],
                         'xhci98 = "USB 2.0 xHCI Host Controller (xhci98)",files.xhci98,xhci98')
        files = out.index('[files.xhci98]')
        self.assertEqual(out[files + 1:files + 6], ['xhci98.sys,4', 'usbport.sys,4', 'usbd.sys,4', 'hidclass.sys,4', 'hidparse.sys,4'])
        self.assertEqual(out[files - 1], '')
        # Everything else is unchanged, in order.
        changed = {'xhci98.sys = 1,,,,,,4_,4,1,,,1,4', 'xhci98.inf = 1,,,,,,,20,0,0', 'PCI\\CC_0C0330 = "xhci98"', 'xhci98 = xhci98.sys'}
        kept = [l for l in out[:-8] if l not in changed and not l.startswith(STACK) and not l.startswith('xhci98 = "')]
        want = [l for l in rows(USB_TXTSETUP) if not l.startswith(STACK)]
        self.assertEqual(kept, want[:-1])

    def test_txtsetup_refusals(self):
        once = self.run_fn('usos_nt52_usb_sif', USB_TXTSETUP).stdout
        self.assertEqual(self.run_fn('usos_nt52_usb_sif', once).returncode, 3)  # second run
        self.assertEqual(self.run_fn('usos_nt52_usb_sif', USB_TXTSETUP.replace(b'kbdhid.sys   = 1,,,,,,4_,4,1,3,,1,4\r\n', b'')).returncode, 3)
        self.assertEqual(self.run_fn('usos_nt52_usb_sif', USB_TXTSETUP.replace(b'usbd.sys        = 1,,,,,,4_,4,1,3,,1,4', b'usbd.sys = 1,,,,,,4_,2,1,3')).returncode, 3)
        self.assertEqual(self.run_fn('usos_nt52_usb_sif', USB_TXTSETUP.replace(b'[InputDevicesSupport]\r\n', b'[Other]\r\n')).returncode, 3)
        self.assertEqual(self.run_fn('usos_nt52_usb_sif', USB_TXTSETUP.replace(b'PCI\\CC_0C0320 = "usbehci"', b'PCI\\CC_0C0330 = "usbxhci"')).returncode, 3)

    def test_inf_source_directory(self):
        for build, sub in (('release-x86', 'i386'), ('release-x64', 'amd64')):
            src = (ROOT / 'tools/vendor/xhci98/1.1.1.0' / build / 'xhci98.inf').read_bytes()
            r = self.run_fn(f'usos_nt52_usb_inf {sub}', src)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(r.stdout, src.replace(b'1=%DiskName%,xhci98.sys,,\r\n', b'1=%DiskName%,,,\\' + sub.encode() + b'\\xhci98\r\n'))
            self.assertNotEqual(r.stdout, src)
            self.assertEqual(self.run_fn(f'usos_nt52_usb_inf {sub}', r.stdout).returncode, 3)
        self.assertEqual(self.run_fn('usos_nt52_usb_inf amd64', b'[Version]\r\n').returncode, 3)

    def test_dosnet(self):
        r = self.run_fn('usos_nt52_usb_dosnet', USB_DOSNET)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, b'[Files]\r\nd1,xhci98.sys\r\nd1,xhci98.inf\r\nd1,usbport.sys\r\n[FloppyFiles.1]\r\nd1,xhci98.sys\r\n'
                                   b'd1,usbport.sys\r\n[FloppyFiles.1]\r\nd1,hal.dll\r\n')
        self.assertEqual(self.run_fn('usos_nt52_usb_dosnet', r.stdout).returncode, 3)
        self.assertEqual(self.run_fn('usos_nt52_usb_dosnet', b'[Files]\r\n').returncode, 3)

    def test_apply(self):
        import build_xp_uefi_csm_trial as builder
        pkg = builder.nt52_usb_files()
        for source_dir, arch, sub in (('I386', 'x86', 'i386'), ('AMD64', 'amd64', 'amd64')):
            with tempfile.TemporaryDirectory() as tmp:
                t = Path(tmp)
                for rel, data in pkg.items():
                    (t / 'pkg' / rel).parent.mkdir(parents=True, exist_ok=True)
                    (t / 'pkg' / rel).write_bytes(data)
                bt, ls = t / 'root/$WIN_NT$.~BT', t / 'root/$WIN_NT$.~LS' / source_dir
                for folder in (bt, ls):
                    folder.mkdir(parents=True)
                    (folder / 'TXTSETUP.SIF').write_bytes(USB_TXTSETUP)
                    (folder / 'XHCI98.SY_').write_bytes(b'stale')
                (t / 'root/TXTSETUP.SIF').write_bytes(USB_TXTSETUP)
                (ls / 'DOSNET.INF').write_bytes(USB_DOSNET)
                r = sh(f"XP_TARGET_ROOT='{posix(t / 'root')}' NT5_SOURCE_DIR={source_dir} USOS_NT52_USB_DIR='{posix(t / 'pkg')}' "
                       f"sh '{self.LIB}' apply")
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                self.assertIn(b'[NT52_USB] APPLIED PASS xhci98 1.1.1.0 (' + arch.encode() + b')', r.stdout)
                sif = self.run_fn('usos_nt52_usb_sif', USB_TXTSETUP).stdout
                for folder in (bt, ls):
                    self.assertEqual((folder / 'xhci98.sys').read_bytes(), pkg[arch + '/xhci98.sys'])
                    self.assertFalse((folder / 'XHCI98.SY_').exists())
                    self.assertEqual((folder / 'TXTSETUP.SIF').read_bytes(), sif)
                self.assertEqual((t / 'root/TXTSETUP.SIF').read_bytes(), sif)
                self.assertFalse((bt / 'xhci98.inf').exists())
                self.assertIn(b'1=%DiskName%,,,\\' + sub.encode() + b'\\xhci98\r\n', (ls / 'xhci98.inf').read_bytes())
                # The GUI-mode source copy (text mode moves the one above).
                self.assertEqual((ls / 'XHCI98/xhci98.sys').read_bytes(), pkg[arch + '/xhci98.sys'])
                self.assertIn(b'd1,xhci98.inf', (ls / 'DOSNET.INF').read_bytes())
                # A second apply refuses (already integrated) and leaves the files.
                r = sh(f"XP_TARGET_ROOT='{posix(t / 'root')}' NT5_SOURCE_DIR={source_dir} USOS_NT52_USB_DIR='{posix(t / 'pkg')}' "
                       f"sh '{self.LIB}' apply")
                self.assertNotEqual(r.returncode, 0)
                self.assertEqual((ls / 'TXTSETUP.SIF').read_bytes(), sif)

    def test_package_files(self):
        import build_xp_uefi_csm_trial as builder
        files = builder.nt52_usb_files()
        self.assertEqual(sorted(files), ['LICENSE', 'SOURCE.txt', 'amd64/xhci98.inf', 'amd64/xhci98.sys', 'x86/xhci98.inf', 'x86/xhci98.sys'])
        machine = lambda b: struct.unpack_from('<H', b, struct.unpack_from('<I', b, 60)[0] + 4)[0]
        self.assertEqual(machine(files['x86/xhci98.sys']), 0x14c)
        self.assertEqual(machine(files['amd64/xhci98.sys']), 0x8664)
        self.assertIn(b'DriverVer=09/24/2026,1.1.1.0', files['amd64/xhci98.inf'])
        self.assertIn(b'[XhciModels.NTamd64]', files['amd64/xhci98.inf'])
        self.assertIn(b'[Xhci.Dev.NTx86]', files['x86/xhci98.inf'])
        self.assertIn(b'SPDX-License-Identifier: GPL-2.0-only', files['LICENSE'])
        self.assertIn('usr/lib/usos/nt52-usb/', builder.PACKAGE_PREFIXES)


if __name__ == '__main__':
    unittest.main()
