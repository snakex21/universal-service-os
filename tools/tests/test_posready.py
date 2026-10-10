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
        cmd = self.root.find("RunOnce/RunOnceCommand").get("FilePath")
        self.assertIn(r"\USOS\POSR\FIRST.CMD", cmd)

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

    def test_first_cmd_is_crlf_and_checks_acpi(self) -> None:
        data = (ROOT / "tools" / "posready_first.cmd").read_bytes()
        self.assertNotIn(b"\n", data.replace(b"\r\n", b""))
        self.assertIn(b"dllcache", data)
        self.assertIn(b"ACPI MISMATCH", data)
        self.assertIn(b"shutdown -s", data)

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
        for name in ("posready_csmwrap_target.sh", "posready_qemu_install.sh", "posready_unattended.xml", "posready/FIRST.CMD"):
            self.assertIn(name, build)

    def test_install_vm_is_uniprocessor(self) -> None:
        # With 2 CPUs Setup set up halmacpi; one CPU keeps HAL and kernel simple.
        self.assertIn("-smp 1", (ROOT / "tools" / "posready_qemu_install.sh").read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
