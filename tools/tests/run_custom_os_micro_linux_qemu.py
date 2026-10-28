#!/usr/bin/env python3
"""Custom OS image-to-disk through the REAL micro-Linux, then the X470-like boot.

Step 620 for Haiku / FreeBSD / ReactOS / KolibriOS / FreeDOS / OpenBSD /
NetBSD / 9front / Redox / own images
(profile custom-image-uefi, docs/custom-os-2026-10-11.md) runs
tools/image_disk_target.sh on the confirmed target disk. This test runs that
script (and xp_csmwrap_esp.sh, which it calls for BIOS-only images) in the
built micro-Linux, nested:

  host QEMU: zig-out/micro-linux kernel + initramfs-usos + an overlay cpio
  (guest script, this checkout's image_disk_target.sh / xp_csmwrap_esp.sh,
  the CSMWrap folder from zig-out/usb), rdinit=/bin/sh, serial console;
  target = a scratch raw disk on AHCI (/dev/sda), the image = a read-only
  virtio disk (/dev/vda).

Then --boot starts the written disk like the X470 without CSM: q35, OVMF
(no CSM), ich9-ahci, qemu-xhci keyboard + mouse (no PS/2 devices are used:
keys are sent to the USB keyboard), screenshots OUT/boot-*.png; --keys sends
HMP sendkey lists at given seconds ("40:ret;60:tab,ret") to check the USB
keyboard; an item starting with "!" is raw HMP, "|"-separated
("70:!mouse_move 200 100|mouse_button 1|mouse_button 0") for the USB mouse.

    python tools/tests/run_custom_os_micro_linux_qemu.py --image X.iso --system haiku --out DIR [--boot 150]

--root: the checkout with zig-out (build.bat's) and tools/qemu. Scratch images
only (OUT); no physical disk is opened. Delete OUT afterwards. QEMU runs as a
renamed copy (qemu-cos-e2e.exe) and only its own PID is stopped.
USB-only input check: the boot machine has no i8042 (q35,i8042=off).
"""
from __future__ import annotations

import argparse
import io
import os
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "tests" / "uefi_drivers"))
from run_stage_drivers_qemu import Console  # noqa: E402

SCRIPTS = ("image_disk_target.sh", "xp_csmwrap_esp.sh", "uefi_boot_entry.sh",
           "xp_disk_overview.sh", "target_disk_identity.sh", "xp_detect_system.sh")

GUEST = r'''#!/bin/sh
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
for m in ahci sd_mod virtio_pci virtio_blk loop vfat fat nls_cp437 nls_iso8859_1 nls_utf8; do modprobe "$m" 2>/dev/null; done
sleep 2; mdev -s 2>/dev/null
[ -b /dev/sda ] && [ -b /dev/vda ] || { echo "E2E: no sda/vda"; lsblk; echo E2E-RESULT=FAIL; exit 1; }
# UEFI prepare (OVMF): efivarfs for uefi_boot_entry.sh; a micro-Linux built
# before efivarfs.ko was added gets it from the overlay (--efivarfs-ko).
if [ -d /sys/firmware/efi ]; then
    modprobe efivarfs 2>/dev/null || { [ -f /usos-e2e/efivarfs.ko ] && insmod /usos-e2e/efivarfs.ko; }
    echo "E2E: UEFI prepare, efivarfs registered: $(grep -c efivarfs /proc/filesystems)"
fi
up() { cut -d' ' -f1 /proc/uptime; }
IMG=/dev/vda
# --image-file: the image as a file (copied to tmpfs; on the X470 it is a
# file on the stick's DATA partition), so the write takes a file path as in
# step 620; times BusyBox wc -c (reads the file) against stat.
if [ "${IMGFILE:-0}" = 1 ]; then
    mkdir -p /mnt/img
    mount -t tmpfs -o size=3g img /mnt/img
    dd if=/dev/vda of=/mnt/img/image.bin bs=4M 2>/dev/null || { echo "E2E: cannot copy the image"; echo E2E-RESULT=FAIL; exit 1; }
    IMG=/mnt/img/image.bin
    a=$(up); n=$(wc -c < "$IMG"); b=$(up); echo "E2E-TIME wc-c bytes=$n $a -> $b"
    a=$(up); n=$(stat -L -c %s "$IMG"); b=$(up); echo "E2E-TIME stat bytes=$n $a -> $b"
fi
# --overview: the step-620 "Reading partitions, free space and system files"
# screen (xp_disk_overview.sh) on what the disk holds now (--keep-disk).
if [ "${OVERVIEW:-0}" = 1 ]; then
    a=$(up); TARGET_DEVICE=/dev/sda sh /usr/lib/usos/xp_disk_overview.sh > /tmp/overview.txt 2>&1; b=$(up)
    sed 's/^/E2E-OV /' /tmp/overview.txt; echo "E2E-TIME overview $a -> $b"
fi
a=$(up)
if env TARGET_DEVICE=/dev/sda IMAGE_SOURCE="$IMG" IMAGE_SYSTEM="$SYSTEM" IMAGE_TITLE="$TITLE" USOS_CSMWRAP_DIR=/usos-e2e/csmwrap USOS_DOS_NET_DIR=/usos-e2e/dosnet \
    sh /usr/lib/usos/image_disk_target.sh > /tmp/prepare.log 2>&1 < /dev/null; then
    echo "E2E-TIME write $a -> $(up)"
    cat /tmp/prepare.log; cat /run/image-disk.result
    sfdisk -l /dev/sda 2>&1 | tail -n 6
    sync; echo E2E-RESULT=PASS
else
    cat /tmp/prepare.log; cat /run/image-disk.result 2>/dev/null; echo E2E-RESULT=FAIL
fi
'''


def cpio_newc(entries):
    out = io.BytesIO()
    ino = 1

    def add(name, mode, data):
        nonlocal ino
        nb = name.encode() + b"\0"
        head = "070701" + "".join(f"{v:08X}" for v in (ino, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(nb), 0))
        out.write(head.encode() + nb)
        out.write(b"\0" * (-(110 + len(nb)) % 4))
        out.write(data)
        out.write(b"\0" * (-len(data) % 4))
        ino += 1

    for name, mode, data in entries:
        add(name, mode, data)
    add("TRAILER!!!", 0, b"")
    blob = out.getvalue()
    return blob + b"\0" * (-len(blob) % 512)


BLOBS = ("elcr-mbr-440.bin",)


def overlay(csmwrap: Path, root: Path, efivarfs_ko: Path | None = None) -> bytes:
    entries = []
    dirs = set()

    def add(path, data, mode=0o100644):
        parts = path.split("/")[:-1]
        for i in range(1, len(parts) + 1):
            d = "/".join(parts[:i])
            if d not in dirs:
                dirs.add(d)
                entries.append((d, 0o040755, b""))
        entries.append((path, mode, data))

    add("usos-e2e/guest.sh", GUEST.encode(), 0o100755)
    if efivarfs_ko is not None:
        add("usos-e2e/efivarfs.ko", efivarfs_ko.read_bytes())
    for f in sorted(csmwrap.rglob("*")):
        if f.is_file():
            add("usos-e2e/csmwrap/" + f.relative_to(csmwrap).as_posix(), f.read_bytes())
    # FreeDOS network and mouse (image_disk_target.sh freedos_net,
    # freedos_mouse): the C:/NET and C:/USOS files of the stick's
    # EFI/USOS/dos-native/msdos, from the --root build.
    sys.path.insert(0, str(ROOT / "tools"))
    from build_dos_network import NET_FILES
    for name in (*NET_FILES, "VBMOUSE.EXE", "VBADOS.TXT"):
        f = root / "zig-out" / "dos-native" / "msdos" / name
        if f.is_file():
            add("usos-e2e/dosnet/" + name, f.read_bytes())
    for name in SCRIPTS:
        add("usr/lib/usos/" + name, (ROOT / "tools" / name).read_bytes().replace(b"\r\n", b"\n"), 0o100755)
    # MBR blobs (build_xp_geometry_fix_mbr.ps1): this checkout's zig-out first.
    for name in BLOBS:
        for base in (ROOT, root):
            blob = base / "zig-out" / "xp-geometry-fix-mbr" / name
            if blob.is_file():
                add("usr/lib/usos/" + name, blob.read_bytes())
                break
    return cpio_newc(entries)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def qemu_copy(root: Path) -> Path:
    # USOS_QEMU_EXE: a renamed copy elsewhere (own temp folder); its DLLs and
    # data still come from tools/qemu (PATH and -L, see qemu_env/qemu_data).
    own = os.environ.get("USOS_QEMU_EXE")
    if own:
        return Path(own)
    exe = root / "tools" / "qemu" / "qemu-cos-e2e.exe"
    if not exe.exists():
        shutil.copyfile(root / "tools" / "qemu" / "qemu-system-x86_64.exe", exe)
    return exe


def qemu_env(root: Path) -> dict:
    return dict(os.environ, PATH=str(root / "tools" / "qemu") + os.pathsep + os.environ.get("PATH", ""))


def qemu_data(root: Path) -> list:
    return ["-L", str(root / "tools" / "qemu" / "share")] if os.environ.get("USOS_QEMU_EXE") else []


def stop(proc):
    if proc.poll() is None:
        proc.kill()
        proc.wait(10)


def prepare(args, root: Path, out: Path, disk: Path) -> bool:
    ml = root / "zig-out" / "micro-linux"
    initrd = out / "initrd.cpio"
    with initrd.open("wb") as f:
        efivarfs_ko = Path(args.efivarfs_ko) if args.efivarfs_ko else None
        for part in ((ml / "initramfs-usos").read_bytes(), overlay(root / "zig-out" / "usb" / "EFI" / "USOS" / "csmwrap", root, efivarfs_ko)):
            f.write(part)
            f.write(b"\0" * (-f.tell() % 4))
    port = free_port()
    firmware = []
    if not args.bios_prepare:
        # UEFI like the real step 620 (USOS starts micro-Linux from the
        # firmware): the boot entry lands in OUT/vars.fd, which --boot uses.
        share = root / "tools" / "qemu" / "share"
        vars_copy = out / "vars.fd"
        vars_copy.write_bytes(Path(args.vars_from).read_bytes() if args.vars_from else (share / "edk2-i386-vars.fd").read_bytes())
        firmware = ["-drive", f"if=pflash,format=raw,readonly=on,file={share / 'edk2-x86_64-code.fd'}",
                    "-drive", f"if=pflash,format=raw,file={vars_copy}"]
    cmd = [str(qemu_copy(root)), "-machine", "q35", "-accel", "whpx", "-accel", "tcg", "-m", "4096" if args.image_file else "2048", "-smp", "2", *qemu_data(root), *firmware,
           "-display", "none", "-nic", "none", "-kernel", str(ml / "vmlinuz-virt"), "-initrd", str(initrd),
           "-append", "console=ttyS0,115200 rdinit=/bin/sh loglevel=3",
           "-chardev", f"socket,id=s0,host=127.0.0.1,port={port},server=on,wait=off", "-serial", "chardev:s0",
           "-drive", f"file={disk.as_posix()},format=raw,if=none,id=t,cache=writeback", "-device", "ide-hd,drive=t,bus=ide.0",
           "-drive", f"file={Path(args.image).as_posix()},format=raw,if=none,id=img,readonly=on", "-device", "virtio-blk-pci,drive=img"]
    q = subprocess.Popen(cmd, stderr=(out / "prepare-qemu.log").open("wb"), env=qemu_env(root))
    print("prepare PID", q.pid, flush=True)
    console = None
    try:
        console = Console(port)
        time.sleep(8)
        console.run("export PATH=/usr/sbin:/usr/bin:/sbin:/bin; /bin/busybox --install -s 2>/dev/null; "
                    "mount -t proc proc /proc; mount -t sysfs sys /sys; mount -t devtmpfs dev /dev 2>/dev/null; "
                    "mkdir -p /tmp /run; mount -t tmpfs tmp /tmp; mount -t tmpfs run /run", "SETUP-DONE", 120)
        start = len(console.text)
        flags = f"IMGFILE={1 if args.image_file else 0} OVERVIEW={1 if args.overview else 0}"
        console.sock.sendall(f"{flags} SYSTEM={args.system} TITLE='{args.title or args.system}' sh /usos-e2e/guest.sh 2>&1; echo E2E-EXIT\n".encode())
        deadline = time.time() + args.timeout
        while "\nE2E-EXIT" not in console.text[start:] and time.time() < deadline and q.poll() is None:
            try:
                chunk = console.sock.recv(65536)
                if chunk:
                    console.text += chunk.decode("utf-8", errors="replace")
            except socket.timeout:
                pass
        console.run("sync", "SYNC-DONE", 120)
        for line in console.text[start:].splitlines():
            if line.startswith(("[IMAGE_DISK]", "[XP_CSMWRAP]", "[BOOT_ENTRY]", "E2E", "mode=", "stop=", "boot_entry=", "/dev/sda")):
                print(line.rstrip(), flush=True)
        return "E2E-RESULT=PASS" in console.text[start:]
    finally:
        if console is not None:
            (out / "prepare-console.log").write_text(console.text, encoding="utf-8")
            try:
                console.sock.sendall(b"poweroff -f\n")
                q.wait(20)
            except Exception:
                pass
        stop(q)


def boot(args, root: Path, out: Path, disk: Path) -> None:
    qd = root / "tools" / "qemu"
    vars_copy = out / "vars.fd"
    if not vars_copy.exists():
        vars_copy.write_bytes((qd / "share" / "edk2-i386-vars.fd").read_bytes())
    port = free_port()
    accel = ["-accel", "tcg"] if args.tcg else ["-accel", "whpx", "-accel", "tcg"]
    # No i8042: keys reach the guest only through the xHCI USB keyboard, as on
    # an X470 without a PS/2 keyboard.
    cmd = [str(qemu_copy(root)), "-machine", "q35,i8042=off", *accel, "-m", "4096", "-smp", "2", *qemu_data(root),
           "-drive", f"if=pflash,format=raw,readonly=on,file={qd / 'share' / 'edk2-x86_64-code.fd'}",
           "-drive", f"if=pflash,format=raw,file={vars_copy}",
           "-drive", f"file={disk.as_posix()},format=raw,if=none,id=t,cache=writeback", *(["-device", "nvme,drive=t,serial=USOSNVME01"] if args.nvme else ["-device", "ide-hd,drive=t,bus=ide.0"]),
           "-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0", "-device", "usb-mouse,bus=xhci.0",
           "-vga", "std", "-display", "none", "-nic", "none", "-monitor", f"tcp:127.0.0.1:{port},server,nowait"]
    if args.mmio32:
        # Asks OVMF for no 64-bit MMIO window (the X470 keeps the AMD xHCI
        # below 4 GiB). With the bundled OVMF (2026-10-12) the qemu-xhci BAR
        # still lands at 0xC0_0000_0000, so this changes nothing yet.
        cmd += ["-fw_cfg", "name=opt/ovmf/X-PciMmio64Mb,string=0"]
    if args.decoy:
        # A second bootable disk (UEFI Shell as its removable loader, prints
        # USOS-DECOY-SHELL). No bootindex: with a fw_cfg boot order OVMF
        # deletes every Boot#### it cannot match to it (Haiku's own entry
        # included, QEMU 2026-10-12). Put first in BootOrder by an earlier
        # run (--vars-from), it shows that BootNext, not the order, starts
        # the disk under test.
        decoy = out / "decoy"
        (decoy / "EFI" / "BOOT").mkdir(parents=True, exist_ok=True)
        shell = ROOT / "tools" / "vendor" / "uefi-shell" / "edk2-stable202002" / "Shell.efi"
        (decoy / "EFI" / "BOOT" / "BOOTX64.EFI").write_bytes(shell.read_bytes())
        (decoy / "startup.nsh").write_bytes(b"echo USOS-DECOY-SHELL\r\n")
        cmd += ["-drive", f"file=fat:{decoy.as_posix()},format=raw,if=none,id=decoy,readonly=on",
                "-device", "virtio-blk-pci,drive=decoy"]
    for extra in args.qemu_arg:
        cmd += extra.split(" ", 1) if extra.startswith("-") and " " in extra else [extra]
    if args.serial:
        cmd += ["-serial", f"file:{(out / 'boot-serial.log').as_posix()}"]
    q = subprocess.Popen(cmd, stderr=(out / "boot-qemu.log").open("wb"), env=qemu_env(root))
    print("boot PID", q.pid, flush=True)
    keys = {}
    for item in filter(None, (args.keys or "").split(";")):
        t, k = item.split(":", 1)
        keys[int(t)] = k
    shots = sorted({*range(args.shot_step, args.boot + 1, args.shot_step), *(t + 8 for t in keys)})
    try:
        time.sleep(2)
        mon = socket.create_connection(("127.0.0.1", port), timeout=10)
        mon.settimeout(1)

        def hmp(cmd):
            try:
                mon.sendall((cmd + "\n").encode())
                time.sleep(0.3)
                mon.recv(65536)
            except OSError:
                pass
        t0 = time.time()
        done = set()
        while time.time() - t0 < args.boot and q.poll() is None:
            el = int(time.time() - t0)
            for t, k in keys.items():
                if el >= t and ("k", t) not in done:
                    done.add(("k", t))
                    if k.startswith("!"):
                        # Raw HMP commands ("!mouse_move 40 30|mouse_button 1|mouse_button 0")
                        # for the USB mouse.
                        for one in k[1:].split("|"):
                            hmp(one)
                            time.sleep(0.3)
                        continue
                    for one in k.split(","):
                        hmp(f"sendkey {one}")
                        time.sleep(0.2)
            for t in shots:
                if el >= t and t not in done:
                    done.add(t)
                    ppm = out / f"boot-{t:04d}.ppm"
                    hmp(f'screendump "{ppm.as_posix()}"')
                    time.sleep(1)
                    try:
                        from PIL import Image
                        Image.open(ppm).save(ppm.with_suffix(".png"))
                        ppm.unlink()
                    except Exception:
                        pass
            time.sleep(0.5)
        hmp("system_powerdown")
        try:
            q.wait(20)
        except subprocess.TimeoutExpired:
            hmp("quit")
    finally:
        stop(q)


def show_vars(when: str, out: Path) -> None:
    vars_copy = out / "vars.fd"
    if not vars_copy.exists():
        return
    sys.path.insert(0, str(ROOT / "tools" / "tests"))
    from ovmf_vars import boot_summary
    summary = boot_summary(vars_copy)
    print(f"VARS {when}: BootOrder={','.join(summary.get('BootOrder', []))} BootNext={summary.get('BootNext', '-')}", flush=True)
    for number, (description, device_path) in summary["entries"].items():
        print(f"VARS   Boot{number} {description!r} {device_path[:140]}", flush=True)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--image", required=True)
    p.add_argument("--system", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--root", default=r"C:\Users\ASRock\Desktop\usos-x470-98se")
    p.add_argument("--disk-gib", type=int, default=8)
    p.add_argument("--timeout", type=int, default=900)
    p.add_argument("--boot", type=int, default=0, help="seconds to run the written disk (0: no boot)")
    p.add_argument("--keys", default="")
    p.add_argument("--boot-only", action="store_true", help="boot OUT/target.raw of an earlier run")
    p.add_argument("--tcg", action="store_true", help="boot under TCG (ReactOS stops under WHPX on this host)")
    p.add_argument("--nvme", action="store_true", help="boot: the target disk on NVMe (as the X470 Micron) instead of AHCI")
    p.add_argument("--mmio32", action="store_true", help="OVMF: no 64-bit PCI MMIO window (BARs below 4 GiB)")
    p.add_argument("--qemu-arg", action="append", default=[], help='boot: extra QEMU option ("-trace usb_xhci_*")')
    p.add_argument("--shot-step", type=int, default=20, help="boot: seconds between screenshots")
    p.add_argument("--serial", action="store_true", help="boot: COM1 to OUT/boot-serial.log")
    p.add_argument("--title", default="", help="prepare: the boot entry name (IMAGE_TITLE; default --system)")
    p.add_argument("--bios-prepare", action="store_true", help="prepare without OVMF (no UEFI variables, no boot entry)")
    p.add_argument("--efivarfs-ko", default="", help="prepare: efivarfs.ko for a micro-Linux built without it")
    p.add_argument("--vars-from", default="", help="prepare: start from this OVMF VARS file instead of a blank one")
    p.add_argument("--decoy", action="store_true", help="boot: a UEFI Shell disk first in the boot order (checks BootNext)")
    p.add_argument("--keep-disk", action="store_true", help="prepare: write over OUT/target.raw of an earlier run (e.g. Haiku over KolibriOS)")
    p.add_argument("--image-file", action="store_true", help="prepare: the image as a file (tmpfs copy) as on DATA, not the virtio disk; times wc -c vs stat")
    p.add_argument("--overview", action="store_true", help="prepare: run and time xp_disk_overview.sh first (the step-620 disk inspection)")
    args = p.parse_args()
    root = Path(args.root)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    disk = out / "target.raw"
    if args.boot_only:
        ok = disk.exists()
    else:
        if not (args.keep_disk and disk.exists()):
            with disk.open("wb") as f:
                f.truncate(args.disk_gib << 30)
        ok = prepare(args, root, out, disk)
    print("PREPARE", "PASS" if ok else "FAIL", flush=True)
    show_vars("after prepare", out)
    if ok and args.boot:
        boot(args, root, out, disk)
        print("BOOT screenshots in", out, flush=True)
        show_vars("after boot", out)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
