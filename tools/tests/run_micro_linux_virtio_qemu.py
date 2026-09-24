#!/usr/bin/env python3
"""micro-Linux sees QEMU virtio disks (virtio-blk and virtio-scsi).

Boots the release micro-Linux kernel + initramfs (zig-out/micro-linux) in
QEMU with rdinit=/bin/sh, then runs the storage module lines of the real
/usos-init (load_pci_storage_modules plus its explicit `modprobe sd_mod /
virtio_*` lines, taken from the initramfs copy, not re-typed here) and checks
that a virtio-blk disk (/dev/vdX) and a virtio-scsi disk (/dev/sdX) appear
with the expected size and serial. Scratch raw disks only; no physical disk.

    python tools/tests/run_micro_linux_virtio_qemu.py
"""
from __future__ import annotations

import socket
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "tests" / "uefi_drivers"))
from run_stage_drivers_qemu import Console  # noqa: E402

QEMU = ROOT / "tools" / "qemu" / "qemu-system-x86_64.exe"
KERNEL = ROOT / "zig-out" / "micro-linux" / "vmlinuz-virt"
INITRAMFS = ROOT / "zig-out" / "micro-linux" / "initramfs-usos"
WORK = ROOT / "tools" / "tests" / "artifacts" / "micro-linux-virtio"
BLK_MIB, SCSI_MIB = 64, 96


def raw_disk(path: Path, mib: int) -> None:
    with path.open("wb") as stream:
        stream.truncate(mib * 1024 * 1024)


def main() -> int:
    for required in (QEMU, KERNEL, INITRAMFS):
        if not required.exists():
            raise SystemExit(f"missing {required}")
    WORK.mkdir(parents=True, exist_ok=True)
    blk, scsi = WORK / "virtio-blk.raw", WORK / "virtio-scsi.raw"
    raw_disk(blk, BLK_MIB)
    raw_disk(scsi, SCSI_MIB)
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
    listener.close()
    args = [str(QEMU), "-machine", "q35", "-accel", "tcg", "-cpu", "max", "-m", "768", "-smp", "2",
            "-display", "none", "-nic", "none",
            "-kernel", str(KERNEL), "-initrd", str(INITRAMFS),
            "-append", "console=ttyS0,115200 rdinit=/bin/sh loglevel=3",
            "-chardev", f"socket,id=s0,host=127.0.0.1,port={port},server=on,wait=off", "-serial", "chardev:s0",
            "-drive", f"if=none,id=vb,file={blk.as_posix()},format=raw",
            "-device", "virtio-blk-pci,drive=vb,serial=USOSVBLK",
            "-device", "virtio-scsi-pci,id=vs",
            "-drive", f"if=none,id=vsd,file={scsi.as_posix()},format=raw",
            "-device", "scsi-hd,bus=vs.0,drive=vsd,serial=USOSVSCSI"]
    stderr = open(WORK / "qemu.stderr.log", "wb")
    qemu = subprocess.Popen(args, stderr=stderr)
    failures: list[str] = []

    def expect(condition: bool, label: str) -> None:
        print(("[PASS] " if condition else "[FAIL] ") + label)
        if not condition:
            failures.append(label)

    try:
        console = Console(port)
        time.sleep(8)
        setup = ("export PATH=/usr/sbin:/usr/bin:/sbin:/bin; /bin/busybox --install -s; "
                 "mount -t proc proc /proc; mount -t sysfs sys /sys; mount -t devtmpfs dev /dev 2>/dev/null; mkdir -p /tmp; mount -t tmpfs tmp /tmp; "
                 # The real init's storage stage: its PCI modalias loop and its
                 # explicit sd_mod/virtio modprobe lines.
                 "usos_hw_boot_progress() { :; }; "
                 "sed -n '/^load_pci_storage_modules()/,/^}/p' /usos-init > /tmp/pci.sh; . /tmp/pci.sh; "
                 "grep -E '^modprobe (sd_mod|virtio_[a-z]+) ' /usos-init > /tmp/mods.sh; cat /tmp/mods.sh; "
                 "modprobe sd_mod 2>/dev/null; load_pci_storage_modules; . /tmp/mods.sh; sleep 3; mdev -s 2>/dev/null; "
                 "echo MODULES=$(cut -d' ' -f1 /proc/modules | grep -E '^virtio|^sd_mod' | sort | tr '\\n' ,); "
                 "for d in /sys/block/vd* /sys/block/sd*; do [ -e \"$d\" ] || continue; n=${d##*/}; "
                 "s=$(cat $d/serial 2>/dev/null || cat $d/device/vpd_pg80 2>/dev/null | tr -cd '[:print:]'); "
                 "echo DISK=$n size=$(cat $d/size) serial=$s via=$(readlink -f $d/device | grep -o 'virtio[0-9]*' | head -n 1) dev=$([ -b /dev/$n ] && echo yes || echo no); done")
        try:
            out = console.run(setup, "VIRTIO-DONE", 240)
        finally:
            (WORK / "console.log").write_text(console.text, encoding="utf-8")
        disks = [line.strip() for line in out.splitlines() if line.strip().startswith("DISK=")]
        print("\n".join(disks) or "(no disks)")
        modules = next((line for line in out.splitlines() if line.startswith("MODULES=")), "MODULES=")
        print(modules)
        expect("modprobe virtio_pci" in out, "/usos-init loads virtio_pci explicitly")
        expect("virtio_pci," in modules, "virtio_pci (the PCI transport) is loaded")
        blk_sectors = BLK_MIB * 2048
        scsi_sectors = SCSI_MIB * 2048
        expect(any(d.startswith("DISK=vd") and f"size={blk_sectors} " in d and "serial=USOSVBLK" in d and d.endswith("dev=yes") for d in disks),
               f"virtio-blk disk visible as /dev/vdX ({BLK_MIB} MiB, serial USOSVBLK)")
        expect(any(d.startswith("DISK=sd") and f"size={scsi_sectors} " in d and "via=virtio" in d and d.endswith("dev=yes") for d in disks),
               f"virtio-scsi disk visible as /dev/sdX ({SCSI_MIB} MiB, behind the virtio-scsi HBA)")
    finally:
        qemu.kill()
        qemu.wait()
        stderr.close()
    print("[PASS] micro-Linux virtio disks" if not failures else f"[FAIL] {len(failures)} check(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
