#!/usr/bin/env python3
"""Reduced end-to-end proof of the user Storage-driver path (docs/drivers.md):
Windows 11 Setup, started from a WORK prepared like USOS does it, sees a
virtio-blk disk only because of the user's viostor/vioscsi packages that the
real micro-Linux stager put into $WinPEDriver$.

1. stage   The release micro-Linux (QEMU, rdinit=/bin/sh) runs
           `usos-fb-ui --stage-drivers` on DATA\\Drivers\\Windows 11\\Storage
           holding viostor + vioscsi (w11/amd64) from the virtio-win ISO; the
           result is tarred to a scratch disk and read back on the host.
2. disk    A GPT VHD: FAT32 ESP with USOS (manual-usb build) in install-state
           phase=prepared, so USOS does its real Windows handoff (NTFS driver,
           WORK by .usos-work, EFI\\USOS-WORK\\BOOTX64.EFI), and NTFS USOS_WORK = the extracted Win11 ISO (EFI\\BOOT moved to
           EFI\\USOS-WORK, .usos-work) + $WinPEDriver$ + an Autounattend.xml
           whose only action (windowsPE RunSynchronous) starts usos-proof.cmd:
           diskpart `list disk` a few times, logs to WORK\\usos-proof, then
           `wpeutil shutdown`. Nothing is installed.
3. run     QEMU/TCG + OVMF, WORK on AHCI, an empty 20 GiB target on
           virtio-blk-pci: positive run (driver staged) must list the 20 GB
           disk, the negative control (same disk, $WinPEDriver$ renamed) must
           not.

--full-install installs Windows 11 onto a 64 GiB virtio-blk disk (WORK as
a removable USB disk) and boots the installed system from it; slow under
TCG (well over an hour). Results and caveats: tools/tests/virtio_e2e/README.md.

Needs: an elevated shell, 7-Zip, the Win11 x64 ISO, virtio-win extracted to
%LOCALAPPDATA%\\USOS\\test-assets\\virtio-win-0.1.302 (see TESTING.md),
zig-out/micro-linux and zig-out/test-assets/ntfs_x64.efi.

    python tools/tests/virtio_e2e/run_setup_virtio_qemu.py --iso <Win11 x64 ISO>
"""
from __future__ import annotations

import argparse
import gzip
import io
import os
import re
import shutil
import socket
import stat
import subprocess
import sys
import tarfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools"))
sys.path.insert(0, str(ROOT / "tools" / "tests" / "uefi_drivers"))
from build_micro_linux import Entry, newc, put  # noqa: E402
from run_stage_drivers_qemu import Console, fake_wim  # noqa: E402

QEMU = ROOT / "tools" / "qemu" / "qemu-system-x86_64.exe"
QEMU_IMG = ROOT / "tools" / "qemu" / "qemu-img.exe"
OVMF_CODE = ROOT / "tools" / "qemu" / "share" / "edk2-x86_64-code.fd"
OVMF_VARS = ROOT / "tools" / "qemu" / "share" / "edk2-i386-vars.fd"
KERNEL = ROOT / "zig-out" / "micro-linux" / "vmlinuz-virt"
INITRAMFS = ROOT / "zig-out" / "micro-linux" / "initramfs-usos"
NTFS_DRIVER = ROOT / "zig-out" / "test-assets" / "ntfs_x64.efi"
USOS_EFI = ROOT / "zig-out" / "manual-usb" / "EFI" / "BOOT" / "BOOTX64.EFI"
USOS_UI = ROOT / "zig-out" / "manual-usb" / "UI"
WORK = ROOT / "tools" / "tests" / "artifacts" / "virtio-e2e"
HERE = Path(__file__).resolve().parent
VIRTIO = Path(os.environ.get("LOCALAPPDATA", "")) / "USOS" / "test-assets" / "virtio-win-0.1.302"
TARGET_GIB = 20

AUTOUNATTEND = """<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Path>cmd.exe /c for %d in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do @if exist %d:\\usos-proof.cmd start "" cmd.exe /c %d:\\usos-proof.cmd %d</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>
</unattend>
"""

# Started in the background, so Setup continues (and loads $WinPEDriver$)
# while this samples the disk list.
PROOF_CMD = r"""@echo off
set "D=%~1:"
md "%D%\usos-proof" 2>nul
echo started %date% %time%>"%D%\usos-proof\status.txt"
for /l %%N in (1,1,10) do (
  diskpart /s "%D%\usos-list.txt" >"%D%\usos-proof\disks-%%N.txt" 2>&1
  ping -n 21 127.0.0.1 >nul
)
copy /y "X:\Windows\Panther\setupact.log" "%D%\usos-proof\setupact-x.log" >nul 2>&1
copy /y "X:\$WINDOWS.~BT\Sources\Panther\setupact.log" "%D%\usos-proof\setupact-bt.log" >nul 2>&1
pnputil /enum-drivers >"%D%\usos-proof\pnputil.txt" 2>&1
echo done %date% %time%>>"%D%\usos-proof\status.txt"
wpeutil shutdown
"""




def crlf(text: str) -> bytes:
    return text.replace("\r\n", "\n").replace("\n", "\r\n").encode("utf-8")


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def powershell(script: Path, *args: str) -> None:
    subprocess.run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script), *args], check=True)


def stage_drivers(out: Path) -> Path:
    """Runs the real stager in micro-Linux; returns the staged $WinPEDriver$ tree."""
    entries: dict[str, Entry] = {}
    for package in ("viostor", "vioscsi"):
        source = VIRTIO / package / "w11" / "amd64"
        files = sorted(p for p in source.iterdir() if p.is_file())
        if not files:
            raise SystemExit(f"missing virtio-win files in {source}")
        for file in files:
            put(entries, Entry(f"test/data/Drivers/Windows 11/Storage/{package}/{file.name}", stat.S_IFREG | 0o644, file.read_bytes()))
    put(entries, Entry("test/install.wim", stat.S_IFREG | 0o644, fake_wim(9)))
    initrd = out / "initramfs-stage"
    initrd.write_bytes(INITRAMFS.read_bytes() + gzip.compress(newc(entries), mtime=0))
    scratch = out / "stage-out.raw"
    with scratch.open("wb") as stream:
        stream.truncate(64 * 1024 * 1024)
    port = free_port()
    qemu = subprocess.Popen([str(QEMU), "-machine", "q35", "-accel", "tcg", "-cpu", "max", "-m", "1024", "-smp", "2",
                             "-display", "none", "-nic", "none", "-kernel", str(KERNEL), "-initrd", str(initrd),
                             "-append", "console=ttyS0,115200 rdinit=/bin/sh loglevel=3",
                             "-chardev", f"socket,id=s0,host=127.0.0.1,port={port},server=on,wait=off", "-serial", "chardev:s0",
                             "-drive", f"if=none,id=o,file={scratch.as_posix()},format=raw", "-device", "ide-hd,bus=ide.0,drive=o"],
                            stderr=subprocess.DEVNULL)
    try:
        console = Console(port)
        time.sleep(8)
        out_text = console.run(
            "export PATH=/usr/sbin:/usr/bin:/sbin:/bin; /bin/busybox --install -s; "
            "mount -t proc proc /proc; mount -t sysfs sys /sys; mount -t devtmpfs dev /dev 2>/dev/null; mkdir -p /tmp; mount -t tmpfs tmp /tmp; "
            "for a in /sys/bus/pci/devices/*/modalias; do modprobe \"$(cat $a)\" 2>/dev/null; done; modprobe sd_mod; sleep 3; mdev -s; "
            "mkdir -p /tmp/work; usos-fb-ui --stage-drivers '/test/data/Drivers/Windows 11' '/tmp/work/$WinPEDriver$' /test/install.wim /tmp/work/usos-drivers.log; echo RC=$?; "
            "cd /tmp/work && tar cf /dev/sda '$WinPEDriver$' usos-drivers.log && sync && echo TAR=OK; cd /", "STAGE-DONE", 300)
    finally:
        qemu.kill()
        qemu.wait()
    (out / "stage.log").write_text(out_text, encoding="utf-8")
    if "RC=0" not in out_text or "TAR=OK" not in out_text:
        raise SystemExit("stager run failed; see stage.log")
    staged = out / "staged"
    if staged.exists():
        shutil.rmtree(staged)
    staged.mkdir()
    with tarfile.open(scratch, "r:") as archive:
        archive.extractall(staged, filter="data")
    return staged


def run_setup(vhd: Path, target: Path, label: str, out: Path, limit_s: int, bootindex: bool = True) -> str:
    vars_copy = out / f"vars-{label}.fd"
    shutil.copyfile(OVMF_VARS, vars_copy)
    monitor = free_port()
    args = [str(QEMU), "-name", f"USOS-virtio-{label}", "-machine", "q35", "-accel", "tcg,thread=multi", "-cpu", "max",
            "-m", "4096", "-smp", "4", "-nic", "none", "-display", "none", "-device", "VGA,xres=1024,yres=768",
            "-monitor", f"tcp:127.0.0.1:{monitor},server=on,wait=off",
            "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE.as_posix()}",
            "-drive", f"if=pflash,format=raw,file={vars_copy.as_posix()}",
            "-drive", f"if=none,id=work,file={vhd.as_posix()},format=vpc",
            # A fixed disk (AHCI) for the probe runs; for the full install the
            # WORK disk is a removable USB stick, as on real hardware: Setup
            # never puts the system partition on removable media, while on a
            # fixed WORK disk it tries to (and fails: "no viable region").
            *(["-device", "qemu-xhci,id=xhci", "-device", "usb-storage,bus=xhci.0,drive=work,removable=on"] if not bootindex
              else ["-device", "ide-hd,bus=ide.0,drive=work,bootindex=1"]),
            "-drive", f"if=none,id=target,file={target.as_posix()},format=qcow2", "-device", "virtio-blk-pci,drive=target,serial=USOSVIRTIO"]
    stderr = open(out / f"qemu-{label}.stderr.log", "wb")
    started = time.time()
    qemu = subprocess.Popen(args, stderr=stderr)
    shots = out / f"screens-{label}"
    shots.mkdir(exist_ok=True)
    result = "timeout"
    try:
        sock = None
        next_shot = started + 60
        while time.time() - started < limit_s:
            if qemu.poll() is not None:
                result = "shutdown"
                break
            # Operator hook: monitor commands dropped into monitor.txt (one per
            # line, e.g. "sendkey ret" or "screendump x.ppm") are sent once.
            commands = out / "monitor.txt"
            pending = []
            if time.time() >= next_shot:
                next_shot += 180
                pending.append(f"screendump {(shots / f'{int(time.time() - started):05d}s.ppm').as_posix()}")
            if commands.exists():
                pending += [line.strip() for line in commands.read_text(encoding="utf-8").splitlines() if line.strip()]
                commands.unlink()
            for command in pending:
                try:
                    if sock is None:
                        sock = socket.create_connection(("127.0.0.1", monitor), timeout=5)
                    sock.sendall((command + "\n").encode())
                    time.sleep(0.5)
                except OSError:
                    sock = None
            time.sleep(5)
    finally:
        if qemu.poll() is None:
            qemu.kill()
        qemu.wait()
        stderr.close()
    print(f"[{label}] {result} after {int(time.time() - started)} s")
    return result


def disks_seen(proof: Path) -> list[str]:
    lines: list[str] = []
    for file in sorted(proof.glob("disks-*.txt"), key=lambda p: int(re.sub(r"\D", "", p.stem) or 0)):
        text = file.read_bytes().decode("utf-8", errors="replace")
        lines = [line.strip() for line in text.splitlines() if re.match(r"\s*\*?\s*(Disk|Dysk)\s+\d+", line)]
    return lines


def full_install(vhd: Path, limit_s: int) -> int:
    """Setup installs onto the virtio-blk disk (Disk 1) with the staged viostor,
    reboots into the installed Windows from that disk, logs on once, writes
    C:\\usos-e2e-desktop.txt (marker + pnputil list) and shuts down. The marker
    is found in the target image (small files live in the MFT, uncompressed)."""
    answer = HERE / "usos-e2e-virtio.xml"
    powershell(HERE / "work_disk_io.ps1", "-Vhd", str(vhd), "-Reset", "-Drivers", "on", "-Autounattend", str(answer))
    target = WORK / "target-install.qcow2"
    target.unlink(missing_ok=True)
    subprocess.run([str(QEMU_IMG), "create", "-f", "qcow2", str(target), "64G"], check=True, stdout=subprocess.DEVNULL)
    try:
        # No bootindex: after Setup the NVRAM BootOrder (Windows Boot Manager on
        # the virtio disk first) must win over the WORK disk.
        outcome = run_setup(vhd, target, "install", WORK, limit_s, bootindex=False)
    finally:
        # Back to the diskpart probe answer file for the reduced proof.
        powershell(HERE / "work_disk_io.ps1", "-Vhd", str(vhd), "-Autounattend", str(WORK / "work-extra" / "Autounattend.xml"))
    marker = re.compile(rb"USOS-E2E-DESKTOP [^%\r\n]{4,40}")
    found = b""
    with target.open("rb") as stream:
        tail = b""
        while chunk := stream.read(64 * 1024 * 1024):
            hit = marker.search(tail + chunk)
            if hit:
                found = hit.group(0)
                break
            tail = chunk[-64:]
    print(f"[install] {outcome}; marker={found.decode(errors='replace') or 'none'}")
    ok = outcome == "shutdown" and bool(found)
    print(("[PASS] " if ok else "[FAIL] ") + "Windows 11 installed onto the virtio-blk disk with the user's viostor and reached the first logon from it")
    return 0 if ok else 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--iso", type=Path, required=True)
    parser.add_argument("--limit-minutes", type=int, default=150)
    parser.add_argument("--reuse-disk", action="store_true")
    parser.add_argument("--full-install", action="store_true",
                        help="install Windows 11 onto a 64 GiB virtio-blk disk (usos-e2e-virtio.xml) and boot it to the first logon")
    args = parser.parse_args()
    for required in (QEMU, QEMU_IMG, OVMF_CODE, KERNEL, INITRAMFS, NTFS_DRIVER, args.iso):
        if not required.exists():
            raise SystemExit(f"missing {required}")
    WORK.mkdir(parents=True, exist_ok=True)
    vhd = WORK / "work-setup.vhd"
    if not (args.reuse_disk and vhd.exists()):
        staged = stage_drivers(WORK)
        esp = WORK / "esp"
        extra = WORK / "work-extra"
        for folder in (esp, extra):
            if folder.exists():
                shutil.rmtree(folder)
            folder.mkdir()
        # USOS itself on the ESP, resuming phase=prepared (work_disk_io.ps1
        # -Reset writes it): the real handoff (NTFS driver, WORK by marker,
        # EFI\USOS-WORK\BOOTX64.EFI).
        (esp / "EFI" / "BOOT").mkdir(parents=True)
        (esp / "EFI" / "USOS").mkdir(parents=True)
        shutil.copyfile(USOS_EFI, esp / "EFI" / "BOOT" / "BOOTX64.EFI")
        shutil.copyfile(NTFS_DRIVER, esp / "EFI" / "USOS" / "ntfs_x64.efi")
        shutil.copytree(USOS_UI, esp / "UI")
        shutil.copytree(staged / "$WinPEDriver$", extra / "$WinPEDriver$")
        shutil.copyfile(staged / "usos-drivers.log", extra / "usos-drivers.log")
        (extra / "Autounattend.xml").write_bytes(crlf(AUTOUNATTEND))
        (extra / "usos-proof.cmd").write_bytes(crlf(PROOF_CMD))
        (extra / "usos-list.txt").write_bytes(crlf("list disk\n"))
        powershell(HERE / "new_setup_disk.ps1", "-Vhd", str(vhd), "-Iso", str(args.iso), "-EspSource", str(esp), "-WorkExtra", str(extra))
    staged_files = sorted(str(p.relative_to(WORK / "staged")) for p in (WORK / "staged").rglob("*") if p.is_file()) if (WORK / "staged").exists() else []
    print("[STAGED]", ", ".join(staged_files))
    if args.full_install:
        return full_install(vhd, args.limit_minutes * 60)
    failures: list[str] = []
    results: dict[str, list[str]] = {}
    for label, drivers in (("positive", "on"), ("negative", "off")):
        powershell(HERE / "work_disk_io.ps1", "-Vhd", str(vhd), "-Reset", "-Drivers", drivers)
        target = WORK / f"target-{label}.qcow2"
        target.unlink(missing_ok=True)
        subprocess.run([str(QEMU_IMG), "create", "-f", "qcow2", str(target), f"{TARGET_GIB}G"], check=True, stdout=subprocess.DEVNULL)
        outcome = run_setup(vhd, target, label, WORK, args.limit_minutes * 60)
        proof = WORK / f"proof-{label}"
        if proof.exists():
            shutil.rmtree(proof)
        powershell(HERE / "work_disk_io.ps1", "-Vhd", str(vhd), "-CopyOut", str(proof))
        results[label] = disks_seen(proof)
        print(f"[{label}] diskpart: " + " | ".join(results[label]))
        if outcome != "shutdown" or not results[label]:
            failures.append(f"{label}: Setup/probe did not finish ({outcome}); see {proof}")
    powershell(HERE / "work_disk_io.ps1", "-Vhd", str(vhd), "-Drivers", "on")

    def has_target(lines: list[str]) -> bool:
        return any(re.search(rf"\b{TARGET_GIB}\s*GB\b", line) for line in lines)

    for label, want in (("positive", True), ("negative", False)):
        ok = label in results and results[label] and has_target(results[label]) == want
        print(("[PASS] " if ok else "[FAIL] ") + f"{label}: the {TARGET_GIB} GB virtio-blk disk is {'listed' if want else 'not listed'} by diskpart in Setup")
        if not ok:
            failures.append(label)
    print("[PASS] user Storage driver reaches Windows Setup" if not failures else f"[FAIL] {failures}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
