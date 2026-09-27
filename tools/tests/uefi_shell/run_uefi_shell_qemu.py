#!/usr/bin/env python3
"""Built-in UEFI Shell (Utilities -> UEFI Shell) in QEMU/OVMF.

A GPT test disk laid out like a USOS stick (tools/tests/uefi_drivers/
new_test_disk.ps1: USOS_ESP FAT32 with the release zig-out/usb tree, USOS_DATA
NTFS, USOS_WORK NTFS) boots the release chain (shim -> MOK-signed USOS). The
test opens Utilities -> UEFI Shell with keystrokes and checks, from the
serial console and screenshots:

  * the Shell starts (MOK-signed Shell.efi through shim under Secure Boot),
  * startup.nsh finds DATA and changes to DATA\\Utilities\\UEFI Shell\\Tools,
  * `map -r` lists DATA (the efifs NTFS driver USOS connected stays resident),
  * EFI tools on DATA started from the Shell: with Secure Boot off an
    unsigned and a MOK-signed tool run; with Secure Boot on an unsigned tool
    is refused ("Verification failed"), and what happens to a MOK-signed and
    a Microsoft-signed (wimboot) tool is reported (shim 16's LoadImage leaves
    LoadedImage->ImageCodeType unset and the EDK2 Shell refuses such images
    as "The image is not an application", docs/uefi-shell.md),
  * `exit` returns to the USOS menu.

Scenarios: sb-on (Fedora OVMF with the Microsoft keys, MokList seeded with
the USOS certificate) and sb-off (plain OVMF, no keys).

    python tools/tests/uefi_shell/run_uefi_shell_qemu.py [--only sb-on|sb-off]

Needs an elevated shell (the test VHD is built with Mount-DiskImage), a
finished build.bat with the signing key, and writes its screenshots and
serial logs to artifacts/uefi-shell/.
"""
from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "tests" / "secure_boot"))
sys.path.insert(0, str(ROOT / "tools"))
import run_qemu_secure_boot as sb  # noqa: E402

OUT = ROOT / "artifacts" / "uefi-shell"
NEW_TEST_DISK = ROOT / "tools" / "tests" / "uefi_drivers" / "new_test_disk.ps1"
TOOL = ROOT / "zig-out" / "test-assets" / "direct-efi-validation.efi"
TOOL_PASS = "DIRECT EFI VALIDATION PASS"
SHELL_DIR = sb.USB / "EFI" / "USOS" / "shell"

KEYS = {" ": "spc", "-": "minus", ":": "shift-semicolon", "\\": "backslash", ".": "dot", "_": "shift-minus",
        '"': "shift-apostrophe", "/": "slash"}


def type_line(machine: sb.Machine, text: str) -> None:
    for char in text:
        if char.isupper():
            name = "shift-" + char.lower()
        else:
            name = KEYS.get(char, char)
        machine.monitor.command(f"sendkey {name}")
        time.sleep(0.08)
    machine.monitor.key("ret", 0.5)


def data_tree(name: str) -> Path:
    """DATA like a fresh install: Systems, Programs, Utilities\\FreeDOS and
    Utilities\\UEFI Shell\\Tools with a signed and an unsigned test tool and
    a dummy ROM."""
    data = sb.WORK / f"shell-data-{name}"
    if data.exists():
        shutil.rmtree(data)
    for folder in ("Systems/Windows/Windows 11/Images", "Programs/USOS", "Utilities/FreeDOS/Programs", "Utilities/UEFI Shell/Tools"):
        (data / folder).mkdir(parents=True, exist_ok=True)
    tools = data / "Utilities" / "UEFI Shell" / "Tools"
    sb.efisign("sign", "-in", str(TOOL), "-out", str(tools / "signed.efi"))
    shutil.copyfile(TOOL, tools / "unsigned.efi")
    shutil.copyfile(ROOT / "zig-out" / "windows-native" / "wimboot", tools / "mssigned.efi")
    (tools / "vbios.rom").write_bytes(bytes(range(256)) * 256)
    return data


def test_disk(name: str) -> Path:
    # The installer adds the NTFS driver from zig-out/test-assets (payload
    # list), not from zig-out/usb.
    esp = sb.esp_tree(f"shell-{name}", sb.USB / "EFI" / "BOOT" / "grubx64.efi",
                      {"EFI/USOS/ntfs_x64.efi": ROOT / "zig-out" / "test-assets" / "ntfs_x64.efi"})
    shutil.copytree(sb.USB / "UI", esp / "UI", dirs_exist_ok=True)
    (esp / "EFI" / "USOS" / "usos-settings.ini").write_text("[ui]\r\nlanguage=en\r\n", newline="")
    vhd = sb.WORK / f"shell-{name}.vhd"
    subprocess.run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(NEW_TEST_DISK),
                    "-Vhd", str(vhd), "-EspSource", str(esp), "-DataSource", str(data_tree(name))], check=True)
    return vhd


def plain_text(text: str) -> str:
    return re.sub(r"\x1b\[[0-9;=?]*[A-Za-z]", "", text)


def shot(machine: sb.Machine, label: str) -> Path:
    path = OUT / f"{machine.name}-{label}.png"
    machine.monitor.shot(path)
    return path


def wait_text(machine: sb.Machine, needle: str, timeout: float, start: int = 0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if needle in plain_text(sb.serial_text(machine.serial))[start:]:
            return True
        time.sleep(0.5)
    return False


def run(name: str, vars_file: Path, secure_boot: bool, firmware: Path | None, failures: list[str]) -> None:
    disk = test_disk(name)
    machine = sb.Machine(f"shell-{name}", None, vars_file, True, disk=disk, firmware=firmware,
                         machine="q35,smm=on" if firmware is None else "q35")
    try:
        started = sb.wait_for(machine.serial, ["USOS MANUAL FLOW BOOT PASS", "Verification failed", "Security Violation"], 300)
        sb.expect(started == "USOS MANUAL FLOW BOOT PASS", f"{name}: USOS menu starts", failures)
        if started != "USOS MANUAL FLOW BOOT PASS":
            return
        time.sleep(5)
        text = plain_text(sb.serial_text(machine.serial))
        state = re.search(r"\[SECURE_BOOT\] state=(\w+)", text)
        sb.expect(state is not None and (state.group(1) == "on") == secure_boot, f"{name}: Secure Boot state={state.group(1) if state else '?'}", failures)
        # Home: Windows -> down, down = Utilities; rows: Secure Boot, Drivers,
        # Theme, UEFI Shell, then DATA utilities (FreeDOS).
        machine.keys("down", "down", "ret", pause=1.5)
        time.sleep(2)
        machine.keys("down", "down", "down", pause=1.0)
        time.sleep(1)
        shot(machine, "01-utilities")
        mark = len(plain_text(sb.serial_text(machine.serial)))
        machine.keys("ret", pause=1.0)
        found = wait_text(machine, "USOS DATA = ", 90, mark)
        time.sleep(3)
        shot(machine, "02-shell-start")
        text = plain_text(sb.serial_text(machine.serial))[mark:]
        sb.expect("[UEFI_SHELL] NTFS driver connected" in text, f"{name}: USOS starts and connects the NTFS driver before the Shell", failures)
        sb.expect("UEFI Interactive Shell" in text, f"{name}: the Shell starts from the Utilities menu", failures)
        sb.expect(found and "Tools\\>" in text, f"{name}: startup.nsh finds DATA and changes to Utilities\\UEFI Shell\\Tools", failures)
        warned = "Secure Boot is ON: the Shell cannot start .efi tools" in text
        sb.expect(warned == secure_boot, f"{name}: startup.nsh {'shows' if secure_boot else 'omits'} the Secure Boot tools warning (%usossecureboot%)", failures)
        data_fs = re.search(r"USOS DATA = (fs\d+):", text, re.IGNORECASE)

        mark = len(plain_text(sb.serial_text(machine.serial)))
        type_line(machine, "map -r")
        time.sleep(6)
        shot(machine, "03-map-r")
        map_text = plain_text(sb.serial_text(machine.serial))[mark:]
        fs_lines = re.findall(r"(FS\d+): Alias\(s\):[^\r\n]*\r?\n\s+([^\r\n]+)", map_text)
        print(f"[INFO] {name}: map -r file systems: " + "; ".join(f"{fs} {path.strip()}" for fs, path in fs_lines))
        sb.expect(len(fs_lines) >= 2 and data_fs is not None, f"{name}: map -r lists the ESP and DATA ({data_fs.group(1) if data_fs else '?'})", failures)

        mark = len(plain_text(sb.serial_text(machine.serial)))
        type_line(machine, "ls")
        time.sleep(4)
        shot(machine, "04-ls-tools")
        ls_text = plain_text(sb.serial_text(machine.serial))[mark:]
        sb.expect("vbios.rom" in ls_text and "signed.efi" in ls_text, f"{name}: ls shows the tools on DATA", failures)

        mark = len(plain_text(sb.serial_text(machine.serial)))
        type_line(machine, "signed.efi")
        signed_ok = wait_text(machine, TOOL_PASS, 40, mark)
        time.sleep(2)
        shot(machine, "05-signed-tool")
        signed_tail = plain_text(sb.serial_text(machine.serial))[mark:]
        if secure_boot:
            print(f"[INFO] {name}: MOK-signed tool from the Shell: " + ("runs" if signed_ok else
                  " | ".join(line.strip() for line in signed_tail.splitlines() if line.strip())[:200]))
            sb.expect("Verification failed" not in signed_tail, f"{name}: the MOK-signed tool passes signature verification", failures)
            mark = len(plain_text(sb.serial_text(machine.serial)))
            type_line(machine, "mssigned.efi")
            time.sleep(8)
            ms_tail = plain_text(sb.serial_text(machine.serial))[mark:]
            print(f"[INFO] {name}: Microsoft-signed wimboot from the Shell: " + " | ".join(line.strip() for line in ms_tail.splitlines() if line.strip())[:300])
        else:
            sb.expect(signed_ok, f"{name}: a MOK-signed EFI tool on DATA runs from the Shell", failures)

        mark = len(plain_text(sb.serial_text(machine.serial)))
        type_line(machine, "unsigned.efi")
        unsigned_ok = wait_text(machine, TOOL_PASS, 25, mark)
        time.sleep(2)
        shot(machine, "06-unsigned-tool")
        tail = plain_text(sb.serial_text(machine.serial))[mark:]
        if secure_boot:
            sb.expect(not unsigned_ok, f"{name}: an unsigned EFI tool is refused under Secure Boot", failures)
            print("[INFO] unsigned tool output: " + " | ".join(line.strip() for line in tail.splitlines() if line.strip())[:300])
        else:
            sb.expect(unsigned_ok, f"{name}: an unsigned EFI tool runs with Secure Boot off", failures)

        mark = len(plain_text(sb.serial_text(machine.serial)))
        type_line(machine, "exit")
        time.sleep(6)
        shot(machine, "07-back-in-menu")
        after = plain_text(sb.serial_text(machine.serial))[mark:]
        sb.expect("Shell>" not in after.split("exit", 1)[-1] and machine.process.poll() is None, f"{name}: exit returns to the USOS menu", failures)
    finally:
        machine.stop()
        shutil.copyfile(machine.serial, OUT / f"{machine.name}.serial.log")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", choices=["sb-on", "sb-off"], default=None)
    args = parser.parse_args()
    for required in (SHELL_DIR / "Shell.efi", SHELL_DIR / "startup.nsh", TOOL):
        if not required.exists():
            raise SystemExit(f"missing {required}: run build.bat first")
    subprocess.run([sys.executable, str(ROOT / "tools" / "tests" / "secure_boot" / "fetch_ovmf_secboot.py")], check=True)
    sb.WORK.mkdir(parents=True, exist_ok=True)
    OUT.mkdir(parents=True, exist_ok=True)
    failures: list[str] = []
    if args.only in (None, "sb-on"):
        der = (sb.USB / "EFI" / "USOS" / sb.CERT_NAME).read_bytes()
        mok = [{"name": "MokList", "guid": sb.SHIM_GUID, "attr": 3, "data": sb.x509_list(der).hex()}]
        run("sb-on", sb.seeded_vars("shell-sb-on", mok), True, None, failures)
    if args.only in (None, "sb-off"):
        vars_file = sb.WORK / "vars-shell-sb-off.fd"
        shutil.copyfile(ROOT / "tools" / "qemu" / "share" / "edk2-i386-vars.fd", vars_file)
        run("sb-off", vars_file, False, ROOT / "tools" / "qemu" / "share" / "edk2-x86_64-code.fd", failures)
    print(f"[RESULT] {len(failures)} failure(s)" + ("" if not failures else ": " + "; ".join(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
