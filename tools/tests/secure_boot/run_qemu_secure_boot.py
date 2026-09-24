#!/usr/bin/env python3
"""USOS Secure Boot chain in QEMU with Microsoft keys enrolled.

Uses Fedora's SMM OVMF (fetch_ovmf_secboot.py) and a read-only QEMU vvfat
ESP built from the release layout in zig-out/usb. No physical disk is used.

Scenarios (each prints [PASS]/[FAIL]):

  unsigned     shim + an UNSIGNED grubx64.efi: shim must refuse it and open
               MokManager ("Verification failed").
  enroll       signed USOS, empty MOK: MokManager opens; the USOS
               certificate is enrolled with keystrokes ("Enroll key from
               disk"), the machine reboots and USOS starts under Secure Boot.
  unsigned-mok the same enrolled NVRAM, unsigned grubx64.efi: still refused.
  probe        the enrolled NVRAM, grubx64.efi = the signed Secure Boot
               probe (secure_boot_probe_main.zig): signed child starts,
               unsigned child is rejected, the signed NTFS driver starts, the
               signed kernel loads, and systemd-boot boots micro-Linux.

    python tools/tests/secure_boot/run_qemu_secure_boot.py [--keep-screens]

Needs the signing key (%APPDATA%\\USOS\\signing) for the probe and child
fixtures; the release layout must come from build.bat.
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools"))
from boot_ui_screens import QEMU, Monitor, free_port  # noqa: E402

CACHE = ROOT / "tools" / "cache" / "secure-boot"
WORK = ROOT / "tools" / "tests" / "artifacts" / "secure-boot"
USB = ROOT / "zig-out" / "usb"
INSTALLER = ROOT / "installer"
SBAT = ROOT / "assets" / "secure-boot" / "usos.sbat.csv"
CERT_NAME = "ENROLL_THIS_KEY_IN_MOKMANAGER.cer"


def efisign(*args: str) -> None:
    subprocess.run(["go", "run", "./cmd/usos-efisign", *args], cwd=INSTALLER, check=True)


def serial_text(path: Path) -> str:
    return path.read_text(errors="replace") if path.exists() else ""


def wait_for(path: Path, needles: list[str], timeout: float) -> str | None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        text = serial_text(path)
        for needle in needles:
            if needle in text:
                return needle
        time.sleep(0.5)
    return None


class Machine:
    def __init__(self, name: str, esp: Path, vars_file: Path, keep_screens: bool):
        self.name = name
        self.serial = WORK / f"{name}.serial.log"
        self.keep_screens = keep_screens
        self.shots = 0
        if self.serial.exists():
            self.serial.unlink()
        port = free_port()
        args = [
            str(QEMU), "-name", f"USOS-SB-{name}",
            "-machine", "q35,smm=on", "-accel", "tcg,thread=multi", "-cpu", "max", "-m", "2048", "-smp", "2",
            "-global", "driver=cfi.pflash01,property=secure,value=on",
            "-drive", f"if=pflash,format=raw,unit=0,readonly=on,file={(CACHE / 'OVMF_CODE.secboot.fd').as_posix()}",
            "-drive", f"if=pflash,format=raw,unit=1,file={vars_file.as_posix()}",
            "-nic", "none", "-display", "none", "-vga", "std",
            "-monitor", f"tcp:127.0.0.1:{port},server=on,wait=off",
            "-serial", f"file:{self.serial.as_posix()}",
            "-drive", f"if=none,id=esp,format=raw,snapshot=on,file=fat:{esp.as_posix()}",
            "-device", "ide-hd,bus=ide.0,drive=esp,bootindex=1",
        ]
        self.stderr = open(WORK / f"{name}.qemu.stderr.log", "wb")
        self.process = subprocess.Popen(args, stderr=self.stderr)
        self.monitor = Monitor(port)

    def shot(self, label: str) -> None:
        if not self.keep_screens or self.process.poll() is not None:
            return
        self.shots += 1
        try:
            self.monitor.shot(WORK / f"{self.name}-{self.shots:02d}-{label}.png")
        except (OSError, RuntimeError) as error:
            print(f"[INFO] screenshot {label} skipped: {error}")

    def keys(self, *names: str, pause: float = 1.5) -> None:
        for name in names:
            self.monitor.key(name, pause)

    def stop(self) -> None:
        if self.process.poll() is None:
            try:
                self.monitor.command("quit")
            except OSError:
                pass
        try:
            self.process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            self.process.kill()
        self.stderr.close()


def esp_tree(name: str, second_stage: Path, extra: dict[str, Path] | None = None) -> Path:
    """Copy the release ESP (without DATA) and replace the second stage."""
    target = WORK / f"esp-{name}"
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(USB / "EFI", target / "EFI")
    shutil.copyfile(second_stage, target / "EFI" / "BOOT" / "grubx64.efi")
    for relative, source in (extra or {}).items():
        path = target / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, path)
    return target


def unsigned_usos() -> Path:
    """Prepare() output: USOS with .sbat and padding, no signature."""
    source = ROOT / "zig-out" / "manual-usb" / "EFI" / "BOOT" / "BOOTX64.EFI"
    out = WORK / "grubx64-unsigned.efi"
    img = subprocess.run(["go", "run", "./cmd/usos-efisign", "derive-check", "-unsigned", str(source), "-signed", str(USB / "EFI" / "BOOT" / "grubx64.efi"), "-sbat", str(SBAT)], cwd=INSTALLER, capture_output=True, text=True)
    if img.returncode != 0:
        raise SystemExit("release grubx64.efi does not derive from manual-usb BOOTX64.EFI: " + img.stderr)
    # A byte copy of the unsigned build output is refused by shim both for the
    # missing signature and the missing .sbat; derive-check proved the signed
    # file is that output plus .sbat, so strip only the certificate table.
    data = bytearray((USB / "EFI" / "BOOT" / "grubx64.efi").read_bytes())
    pe = int.from_bytes(data[0x3C:0x40], "little")
    opt = pe + 24
    directory = opt + (112 if int.from_bytes(data[opt:opt + 2], "little") == 0x20B else 96) + 4 * 8
    offset = int.from_bytes(data[directory:directory + 4], "little")
    if offset:
        del data[offset:]
        data[directory:directory + 8] = bytes(8)
    out.write_bytes(bytes(data))
    return out


def fresh_vars(name: str) -> Path:
    path = WORK / f"vars-{name}.fd"
    shutil.copyfile(CACHE / "OVMF_VARS.secboot.fd", path)
    return path


def expect(result: bool, label: str, failures: list[str]) -> None:
    print(("[PASS] " if result else "[FAIL] ") + label, flush=True)
    if not result:
        failures.append(label)


def scenario_unsigned(args, failures: list[str]) -> None:
    esp = esp_tree("unsigned", unsigned_usos())
    machine = Machine("unsigned", esp, fresh_vars("unsigned"), args.keep_screens)
    try:
        hit = wait_for(machine.serial, ["USOS MANUAL FLOW BOOT PASS", "Verification failed", "Security Violation"], 180)
        time.sleep(3)
        machine.shot("shim-refuses")
        expect(hit in ("Verification failed", "Security Violation"), "shim refuses an unsigned grubx64.efi under Secure Boot", failures)
        expect("USOS MANUAL FLOW BOOT PASS" not in serial_text(machine.serial), "unsigned USOS never started", failures)
    finally:
        machine.stop()


# MokManager (shim 16.1), verified with screenshots on 2026-09-24:
#   "Verification failed: (0x1A) Security Violation" [OK]    -> Enter
#   10 s countdown "Press any key to perform MOK management"  -> Space
#   Continue boot / Enroll key from disk / Enroll hash ...   -> Down, Enter
#   volume list: one vvfat volume                            -> Enter
#   /: EFI/                                                  -> Enter
#   EFI/: ../ BOOT/ USOS/                                    -> Down x2, Enter
#   EFI/USOS/: ../ build-info.ini ENROLL-README.txt
#              ENROLL_THIS_KEY_IN_MOKMANAGER.cer licenses/ ... -> Down x3, Enter
#   [Enroll MOK] View key 0 / Continue                       -> Down, Enter
#   Enroll the key(s)? No / Yes                              -> Down, Enter
#   Perform MOK management: Reboot / ...                     -> Enter
ENROLL_KEYS = [
    ["ret"], ["spc"], ["down", "ret"], ["ret"], ["ret"], ["down", "down", "ret"],
    ["down", "down", "down", "ret"], ["down", "ret"], ["down", "ret"], ["ret"],
]
ENROLL_LABELS = ["dismissed", "mok-management", "select-volume", "root", "efi", "usos",
                 "enroll-mok", "enroll-question", "enrolled", "reboot"]


def scenario_enroll(args, failures: list[str]) -> Path:
    vars_file = fresh_vars("enroll")
    esp = esp_tree("enroll", USB / "EFI" / "BOOT" / "grubx64.efi")
    machine = Machine("enroll", esp, vars_file, args.keep_screens)
    try:
        hit = wait_for(machine.serial, ["Verification failed", "Security Violation", "USOS MANUAL FLOW BOOT PASS"], 180)
        expect(hit in ("Verification failed", "Security Violation"), "signed USOS with an empty MOK list opens MokManager", failures)
        time.sleep(2)
        machine.shot("verification-failed")
        for keys, label in zip(ENROLL_KEYS, ENROLL_LABELS):
            machine.keys(*keys, pause=1.0)
            time.sleep(1.5)
            if label != "reboot":
                machine.shot(label)
        started = wait_for(machine.serial, ["[SECURE_BOOT] state="], 240)
        time.sleep(4)
        machine.shot("usos-after-enroll")
        text = serial_text(machine.serial)
        expect(started is not None and "USOS MANUAL FLOW BOOT PASS" in text, "after enrollment shim starts the MOK-signed USOS", failures)
        expect("[SECURE_BOOT] state=on shim_lock=yes shim_loader=yes" in text, "USOS reports Secure Boot on with shim 16 protocols", failures)
    finally:
        machine.stop()
    return vars_file


def scenario_unsigned_after_mok(args, vars_file: Path, failures: list[str]) -> None:
    copy = WORK / "vars-unsigned-mok.fd"
    shutil.copyfile(vars_file, copy)
    esp = esp_tree("unsigned-mok", unsigned_usos())
    machine = Machine("unsigned-mok", esp, copy, args.keep_screens)
    try:
        hit = wait_for(machine.serial, ["USOS MANUAL FLOW BOOT PASS", "Verification failed", "Security Violation"], 180)
        machine.shot("refused")
        expect(hit in ("Verification failed", "Security Violation"), "unsigned grubx64.efi is still refused with the USOS key enrolled", failures)
    finally:
        machine.stop()


def scenario_probe(args, vars_file: Path, failures: list[str]) -> None:
    copy = WORK / "vars-probe.fd"
    shutil.copyfile(vars_file, copy)
    probe_src = ROOT / "zig-out" / "test-assets" / "secure-boot-probe-x86_64.efi"
    child_src = ROOT / "zig-out" / "test-assets" / "direct-efi-validation.efi"
    probe = WORK / "grubx64-probe.efi"
    signed_child = WORK / "signed-child.efi"
    efisign("sign", "-in", str(probe_src), "-out", str(probe), "-sbat", str(SBAT))
    efisign("sign", "-in", str(child_src), "-out", str(signed_child))
    esp = esp_tree("probe", probe, {
        "EFI/USOS/probe/signed-child.efi": signed_child,
        "EFI/USOS/probe/unsigned-child.efi": child_src,
        "EFI/USOS/micro-linux/vmlinuz-virt": ROOT / "zig-out" / "micro-linux" / "vmlinuz-virt",
        "EFI/USOS/micro-linux/initramfs-usos": ROOT / "zig-out" / "micro-linux" / "initramfs-usos",
        "EFI/USOS/systemd-bootx64.efi": ROOT / "zig-out" / "micro-linux" / "systemd-bootx64.efi",
        "EFI/USOS/ntfs_x64.efi": ROOT / "zig-out" / "test-assets" / "ntfs_x64.efi",
        "EFI/USOS/windows-native/wimboot": ROOT / "zig-out" / "windows-native" / "wimboot",
    })
    (esp / "loader" / "entries").mkdir(parents=True, exist_ok=True)
    (esp / "loader" / "loader.conf").write_text("default usos-micro-linux.conf\r\ntimeout 0\r\neditor no\r\n")
    (esp / "loader" / "entries" / "usos-micro-linux.conf").write_text(
        "title USOS micro-Linux preparation\r\nlinux /EFI/USOS/micro-linux/vmlinuz-virt\r\n"
        "initrd /EFI/USOS/micro-linux/initramfs-usos\r\n"
        "options console=ttyS0,115200 loglevel=6 rdinit=/usos-init usos.legacy_action=hardware\r\n")
    machine = Machine("probe", esp, copy, args.keep_screens)
    try:
        wait_for(machine.serial, ["[HARDWARE] READ-ONLY SESSION READY", "Kernel panic", "[SB_PROBE] end"], 600)
        time.sleep(8)
        machine.shot("probe")
        text = serial_text(machine.serial)
        expect("[SB_PROBE] begin state=on shim_lock=yes shim_loader=yes" in text, "probe runs under Secure Boot with shim 16", failures)
        expect("DIRECT EFI VALIDATION PASS" in text, "MOK-signed child EFI starts through the verified loader", failures)
        # shim prints "Verification failed: ..." between the probe's two writes.
        unsigned = text[text.find("[SB_PROBE] unsigned-child"):] if "[SB_PROBE] unsigned-child" in text else ""
        expect("LOAD REJECTED error=SecureBootRejected" in unsigned[:400] and "unsigned-child LOAD PASS" not in text,
               "unsigned child EFI is rejected with SecureBootRejected", failures)
        expect("[SB_PROBE] START PASS" in text, "a started child that returns hands control back safely (shim 16 StartImage)", failures)
        expect("[SB_PROBE] ntfs-driver START PASS" in text, "MOK-signed NTFS driver starts (verified + USOS PE loader)", failures)
        expect("[SB_PROBE] wimboot LOAD PASS" in text, "Microsoft-signed wimboot loads (db via shim's loader)", failures)
        expect("[SB_PROBE] kernel LOAD PASS" in text, "MOK-signed micro-Linux kernel loads", failures)
        expect("[SB_PROBE] systemd-boot LOAD PASS" in text, "MOK-signed systemd-boot loads", failures)
        expect("Linux version" in text, "systemd-boot started the MOK-signed kernel under Secure Boot", failures)
        expect("[HARDWARE] READ-ONLY SESSION READY" in text, "micro-Linux userland (initramfs, modules, framebuffer UI) runs under Secure Boot", failures)
    finally:
        machine.stop()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--keep-screens", action="store_true")
    parser.add_argument("--only", choices=["unsigned", "enroll", "probe"], default=None)
    args = parser.parse_args()
    subprocess.run([sys.executable, str(Path(__file__).with_name("fetch_ovmf_secboot.py"))], check=True)
    WORK.mkdir(parents=True, exist_ok=True)
    if not (USB / "EFI" / "USOS" / CERT_NAME).exists():
        raise SystemExit("zig-out/usb has no USOS certificate: build.bat ran without the signing key")
    failures: list[str] = []
    if args.only in (None, "unsigned"):
        scenario_unsigned(args, failures)
    if args.only in (None, "enroll", "probe"):
        enrolled = scenario_enroll(args, failures)
        if args.only is None:
            scenario_unsigned_after_mok(args, enrolled, failures)
        scenario_probe(args, enrolled, failures)
    print(f"[RESULT] {len(failures)} failure(s)" + ("" if not failures else ": " + "; ".join(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
