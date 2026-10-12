"""Windows Embedded POSReady 2009 entry (docs/posready-2009-2026-10-10.md)."""
from __future__ import annotations

import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
KEY = re.compile(r"[A-Z0-9]{5}(-[A-Z0-9]{5}){4}")
SH = shutil.which("sh")


class AnswerTemplate(unittest.TestCase):
    def setUp(self) -> None:
        self.text = (ROOT / "tools" / "posready_unattended.xml").read_text(encoding="utf-8")
        self.root = ET.fromstring(self.text)

    def test_no_key_in_repo(self) -> None:
        self.assertIsNone(KEY.search(self.text))
        self.assertEqual(self.root.find("UserData/ProductKey").get("Value"), "@PRODUCT_KEY@")

    def test_installs_on_partition_2_and_keeps_no_copy(self) -> None:
        # Partition 1 is the PE (posready_csmwrap_target.sh).
        part = self.root.find("DiskConfig/Disk/ModifyPartition")
        self.assertEqual(part.get("ID"), "2")
        self.assertEqual(part.get("FileSystem"), "NTFS")
        self.assertEqual(self.root.find("DiskConfig/Disk").get("WipeDisk"), "No")
        # The answer (with the key) is not copied to the installed system.
        self.assertEqual(self.root.find("LoggingData/UnattendedFile").get("Copy"), "No")
        self.assertEqual(self.root.find("SetupData/Preinstall").get("AcceptEula"), "Yes")

    def test_first_logon_runs_first_cmd(self) -> None:
        cmd = self.root.find("RunOnce/RunOnceCommand")
        # Batch files need cmd.exe with /c in Attributes (POSReady docs).
        self.assertEqual(cmd.get("FilePath"), r"C:\WINDOWS\system32\cmd.exe")
        self.assertNotIn("%", cmd.get("Attributes"))  # FBA mangles every %
        # Inside FBA the FAT16 Setup partition has no drive letter (QEMU
        # 2026-10-10): the fixed path on C:, where posready_after_setup put it.
        self.assertEqual(cmd.get("Attributes"), r"/c C:\USOS\POSR\FIRST.CMD")

    @unittest.skipUnless(SH, "no sh")
    def test_answer_xml_from_sif(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            sif = Path(tmp) / "POSR.SIF"
            sif.write_bytes(b"; x\r\n[UserData]\r\nFullName=Jan K\r\nOrganization=\r\nComputerName=KASA1\r\n"
                            b"AdminPassword=\r\nProductKey=AAAAA-BBBBB-CCCCC-DDDDD-EEEEE\r\n")
            out = subprocess.run([SH, "-c", '. tools/posready_qemu_install.sh; posready_answer_xml tools/posready_unattended.xml "$1"', "x",
                                  sif.as_posix()], cwd=ROOT, capture_output=True, check=True).stdout.decode()
            root = ET.fromstring(out)
            self.assertEqual(root.find("UserData/ProductKey").get("Value"), "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE")
            self.assertEqual(root.find("UserData/FullName").get("Value"), "Jan K")
            self.assertEqual(root.find("UserData/ComputerName").get("Value"), "KASA1")
            self.assertNotIn("@", out.split("-->", 1)[1])
            sif.write_bytes(b"[UserData]\r\nFullName=x\r\n")
            rc = subprocess.run([SH, "-c", '. tools/posready_qemu_install.sh; posready_answer_xml tools/posready_unattended.xml "$1"', "x",
                                 sif.as_posix()], cwd=ROOT, capture_output=True).returncode
            self.assertNotEqual(rc, 0)


class Payload(unittest.TestCase):
    def test_reg_matches_the_xp_overlay(self) -> None:
        import posready_reg
        self.assertEqual((ROOT / "tools" / "posready_x470.reg").read_bytes(), posready_reg.render())

    def test_reg_maps_pci_bridges_for_the_first_real_boot(self) -> None:
        # The FBA CriticalDeviceDatabase only knows the i440FX VM. Without
        # PCI\CC_0604 -> pci the X470 SATA controllers (behind PCI-to-PCI
        # bridges) never reach GenAHCI: 0x7B on the first X470 boot (2026-10-12).
        reg = (ROOT / "tools" / "posready_x470.reg").read_bytes().decode("latin1")
        cdd = "[HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Control\\CriticalDeviceDatabase\\"
        self.assertIn(cdd + 'pci#cc_0604]\r\n"Service"="pci"\r\n'
                      '"ClassGUID"="{4D36E97D-E325-11CE-BFC1-08002BE10318}"\r\n', reg)
        self.assertIn(cdd + 'pci#cc_010601]\r\n"Service"="genahci"\r\n', reg)
        self.assertIn('"Start"=dword:00000000', reg.split("Services\\genahci]", 1)[1].split("[", 1)[0])
        # The XP overlay rows stay untouched (XP bundle ids must not move).
        import xp_driver_overlay
        self.assertNotIn("pci#cc_0604", repr(xp_driver_overlay.registry_rows()))

    def test_scripts_are_crlf(self) -> None:
        for name in ("posready_first.cmd", "posready_logon.cmd", "posready_logon.reg", "posready_x470.reg"):
            data = (ROOT / "tools" / name).read_bytes()
            self.assertNotIn(b"\n", data.replace(b"\r\n", b""), name)

    def test_fba_runonce_then_logon_check(self) -> None:
        first = (ROOT / "tools" / "posready_first.cmd").read_bytes()
        logon = (ROOT / "tools" / "posready_logon.cmd").read_bytes()
        # Inside FBA: drivers (dllcache first) and the RunOnce for the logon; no shutdown.
        self.assertIn(b"dllcache", first)
        self.assertIn(b"LOGON.REG", first)
        self.assertNotIn(b"shutdown -s", first)
        # First logon: the ACPI check after FBA's PnP, DONE.TXT, shutdown.
        self.assertIn(b"fc /b", logon)
        self.assertIn(b"DONE.TXT", logon)
        self.assertIn(b"shutdown -s", logon)
        reg = (ROOT / "tools" / "posready_logon.reg").read_bytes()
        self.assertIn(b'"cmd.exe /c C:\\\\USOS\\\\POSR\\\\LOGON.CMD"', reg)
        # One automatic logon (X470 2026-10-11: the typed logon never came,
        # XP keeps the disk busy behind the dialog); LOGON.CMD switches it off
        # before DONE.TXT.
        self.assertIn(b"CurrentVersion\\Winlogon]", reg)
        for value in (b'"AutoAdminLogon"="1"', b'"DefaultUserName"="Administrator"', b'"DefaultPassword"=""',
                      b'"AutoLogonCount"=dword:00000001'):
            self.assertIn(value, reg)
        self.assertLess(logon.index(b"/v AutoAdminLogon /t REG_SZ /d 0"), logon.index(b"DONE.TXT\"\r\n"))
        self.assertIn(b"/v DefaultPassword /f", logon)
        vm = (ROOT / "tools" / "posready_qemu_install.sh").read_text(encoding="utf-8")
        # Typed logon only as a fallback, also while the guest writes a little;
        # the running VM's screen reaches the ESP (logs/live).
        self.assertIn("W9X_VM_ANSWER_QUIET_MB=${POSR_VM_ANSWER_QUIET_MB:-16}", vm)
        self.assertIn('"$logs/live/screen.ppm"', vm)

    def test_posr_folder_on_the_windows_partition(self) -> None:
        # posready_after_setup copies \USOS\POSR from partition 1 onto
        # partition 2 (ntfs3 rw) and checks the copy; the marker and the
        # finish step read C:\USOS\POSR on partition 2 (MBR entry 2, byte 470).
        text = (ROOT / "tools" / "posready_qemu_install.sh").read_text(encoding="utf-8")
        after = text[text.index("posready_after_setup() {"):text.index("posready_answer_xml() {")]
        self.assertIn('cp -r "$w/pe/USOS/POSR" "$w/win/USOS/POSR"', after)
        self.assertIn('mount -t ntfs3 "$l2" "$w/win"', after)
        self.assertNotIn("losetup -r -o $((p2", after)
        mount = text[text.index("posready_mount_windows() {"):text.index("posready_vm_marker() {")]
        self.assertIn("-j 470", mount)
        self.assertIn("-o ro", mount)
        for fn in ("posready_vm_marker() {", "posready_vm_finish() {"):
            body = text[text.index(fn):]
            body = body[:body.index("\n}\n")]
            self.assertIn("posready_mount_windows", body, fn)
            self.assertNotIn("::/USOS/POSR", body, fn)

    def test_driver_set_is_the_xp_selection(self) -> None:
        from build_micro_linux import POSREADY_DRIVERS
        overlay = (ROOT / "tools" / "xp_driver_overlay.py").read_text(encoding="utf-8")
        for name in POSREADY_DRIVERS:
            self.assertIn(name.split("/")[1], overlay)
        self.assertIn("ACPI/acpi.sys", POSREADY_DRIVERS)
        self.assertIn("SATA/genahci.sys", POSREADY_DRIVERS)


class Scripts(unittest.TestCase):
    @unittest.skipUnless(SH, "no sh")
    def test_syntax(self) -> None:
        for name in ("posready_csmwrap_target.sh", "posready_qemu_install.sh", "w9x_csmwrap_prepare.sh"):
            subprocess.run([SH, "-n", str(ROOT / "tools" / name)], check=True)

    def test_target_layout(self) -> None:
        text = (ROOT / "tools" / "posready_csmwrap_target.sh").read_text(encoding="utf-8")
        self.assertIn('"$work/pe/MININT"', text)  # SETUPLDR starts \MININT
        self.assertIn('"$work/pe/I386"', text)  # Setup's DriversFolder ..\i386
        self.assertIn("SETUPLDR.BIN", text)
        self.assertIn('"$work/pe/Setup/unattended.xml"', text)
        self.assertIn("133120", text)  # room for the CSMWrap ESP

    def test_step_620_routes_posready(self) -> None:
        text = (ROOT / "tools" / "w9x_csmwrap_prepare.sh").read_text(encoding="utf-8")
        self.assertIn("windows-embedded-posready-2009) tag=POSR", text)
        self.assertIn("posready_vm_install", text)
        self.assertIn("posready_vm_finish", text)
        vm = (ROOT / "tools" / "w9x_phase1_qemu.sh").read_text(encoding="utf-8")
        self.assertRegex(vm, r"NT31\|NT31S\|POSR\)")
        build = (ROOT / "tools" / "build_micro_linux.py").read_text(encoding="utf-8")
        for name in ("posready_csmwrap_target.sh", "posready_qemu_install.sh", "posready_unattended.xml", "posready/FIRST.CMD", "posready/LOGON.CMD", "posready/LOGON.REG"):
            self.assertIn(name, build)

    def test_install_vm_is_uniprocessor(self) -> None:
        # With 2 CPUs Setup set up halmacpi; one CPU keeps HAL and kernel simple.
        self.assertIn("-smp 1", (ROOT / "tools" / "posready_qemu_install.sh").read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
