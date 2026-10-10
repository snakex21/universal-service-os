"""Windows Embedded POSReady 2009 groundwork (docs/posready-2009-2026-10-10.md)."""
from __future__ import annotations

import re
import shutil
import subprocess
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
KEY = re.compile(r"[A-Z0-9]{5}(-[A-Z0-9]{5}){4}")


class AnswerTemplate(unittest.TestCase):
    def setUp(self) -> None:
        self.text = (ROOT / "tools" / "posready_unattended.xml").read_text(encoding="utf-8")
        self.root = ET.fromstring(self.text)

    def test_no_key_in_repo(self) -> None:
        self.assertIsNone(KEY.search(self.text))
        self.assertEqual(self.root.find("UserData/ProductKey").get("Value"), "@PRODUCT_KEY@")

    def test_installs_on_partition_2(self) -> None:
        # Partition 1 is the PE (posready_csmwrap_target.sh).
        part = self.root.find("DiskConfig/Disk/ModifyPartition")
        self.assertEqual(part.get("ID"), "2")
        self.assertEqual(part.get("FileSystem"), "NTFS")
        self.assertEqual(self.root.find("DiskConfig/Disk").get("WipeDisk"), "No")

    def test_eula_preaccepted(self) -> None:
        self.assertEqual(self.root.find("SetupData/Preinstall").get("AcceptEula"), "Yes")


class Scripts(unittest.TestCase):
    @unittest.skipUnless(shutil.which("sh"), "no sh")
    def test_syntax(self) -> None:
        for name in ("posready_csmwrap_target.sh", "posready_qemu_install.sh"):
            subprocess.run(["sh", "-n", str(ROOT / "tools" / name)], check=True)

    def test_target_layout(self) -> None:
        text = (ROOT / "tools" / "posready_csmwrap_target.sh").read_text(encoding="utf-8")
        self.assertIn('"$work/pe/MININT"', text)  # SETUPLDR starts \MININT
        self.assertIn('"$work/pe/I386"', text)  # Setup's DriversFolder ..\i386
        self.assertIn("SETUPLDR.BIN", text)
        self.assertIn('"$work/pe/Setup/unattended.xml"', text)


if __name__ == "__main__":
    unittest.main()
