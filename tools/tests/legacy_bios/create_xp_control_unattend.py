#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
from pathlib import Path


def main() -> int:
    ap = argparse.ArgumentParser(description="Create a disposable XP CD-boot WINNT.SIF from the ISO's own sample answer file without printing its product key.")
    ap.add_argument("--sample", required=True, type=Path)
    ap.add_argument("--output", required=True, type=Path)
    ap.add_argument(
        "--preserve-partitions",
        action="store_true",
        help="Keep XP Text Mode partition selection manual while supplying GUI-unattended fields and the ISO sample ProductKey.",
    )
    args = ap.parse_args()

    text = args.sample.read_text(encoding="cp1250", errors="replace")
    match = re.search(r"(?im)^\s*Product(?:Key|ID)\s*=\s*(.+?)\s*$", text)
    if not match:
        raise SystemExit("sample answer file contains no ProductKey/ProductID")
    product_line = match.group(1).strip()

    # Keep the key opaque: this helper deliberately never prints it.
    if args.preserve_partitions:
        data_section = '''[Data]\nAutoPartition = 0\nMsDosInitiated = 1\nUnattendedInstall = Yes\n'''
        unattended_section = '''[Unattended]\nUnattendMode = FullUnattended\nOemPreinstall = No\nOemSkipEula = Yes\nRepartition = No\nTargetPath = \\WINDOWS\nUnattendSwitch = Yes\nWaitForReboot = No\n'''
    else:
        data_section = '''[Data]\nAutoPartition = 1\nMsDosInitiated = 0\nUnattendedInstall = Yes\n'''
        unattended_section = '''[Unattended]\nUnattendMode = FullUnattended\nOemPreinstall = No\nOemSkipEula = Yes\nRepartition = Yes\nFileSystem = NTFS\nTargetPath = \\WINDOWS\nUnattendSwitch = Yes\nWaitForReboot = No\n'''

    sif = f'''{data_section}\n{unattended_section}\n[GuiUnattended]\nAdminPassword = *\nEncryptedAdminPassword = No\nOEMSkipRegional = 1\nOemSkipWelcome = 1\nTimeZone = 100\n\n[UserData]\nFullName = "USOS XP Control"\nOrgName = "USOS"\nComputerName = XPCTRL\nProductKey = {product_line}\n\n[Identification]\nJoinWorkgroup = WORKGROUP\n\n[Networking]\nInstallDefaultComponents = Yes\n'''
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(sif, encoding="cp1250", newline="\r\n")
    print(f"[PASS] control WINNT.SIF written: {args.output}")
    print("[PASS] ProductKey copied opaquely from ISO sample (not displayed)")
    if args.preserve_partitions:
        print("[PASS] partition policy: AutoPartition=0 Repartition=No")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
