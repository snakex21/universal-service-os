#!/usr/bin/env python3
"""Custom OS image-to-disk through the REAL micro-Linux, then the X470-like boot.

Step 620 for Haiku / FreeBSD / ReactOS / KolibriOS / FreeDOS / own images
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
keyboard.

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

SCRIPTS = ("image_disk_target.sh", "xp_csmwrap_esp.sh")

GUEST = r'''#!/bin/sh
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
for m in ahci sd_mod virtio_pci virtio_blk loop vfat fat nls_cp437 nls_iso8859_1; do modprobe "$m" 2>/dev/null; done
sleep 2; mdev -s 2>/dev/null
[ -b /dev/sda ] && [ -b /dev/vda ] || { echo "E2E: no sda/vda"; lsblk; echo E2E-RESULT=FAIL; exit 1; }
if env TARGET_DEVICE=/dev/sda IMAGE_SOURCE=/dev/vda IMAGE_SYSTEM="$SYSTEM" USOS_CSMWRAP_DIR=/usos-e2e/csmwrap \
    sh /usr/lib/usos/image_disk_target.sh > /tmp/prepare.log 2>&1 < /dev/null; then
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


def overlay(csmwrap: Path) -> bytes:
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
    for f in sorted(csmwrap.rglob("*")):
        if f.is_file():
            add("usos-e2e/csmwrap/" + f.relative_to(csmwrap).as_posix(), f.read_bytes())
    for name in SCRIPTS:
        add("usr/lib/usos/" + name, (ROOT / "tools" / name).read_bytes().replace(b"\r\n", b"\n"), 0o100755)
    return cpio_newc(entries)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def qemu_copy(root: Path) -> Path:
    exe = root / "tools" / "qemu" / "qemu-cos-e2e.exe"
    if not exe.exists():
        shutil.copyfile(root / "tools" / "qemu" / "qemu-system-x86_64.exe", exe)
    return exe


def stop(proc):
    if proc.poll() is None:
        proc.kill()
        proc.wait(10)


def prepare(args, root: Path, out: Path, disk: Path) -> bool:
    ml = root / "zig-out" / "micro-linux"
    initrd = out / "initrd.cpio"
    with initrd.open("wb") as f:
        for part in ((ml / "initramfs-usos").read_bytes(), overlay(root / "zig-out" / "usb" / "EFI" / "USOS" / "csmwrap")):
            f.write(part)
            f.write(b"\0" * (-f.tell() % 4))
    port = free_port()
    cmd = [str(qemu_copy(root)), "-machine", "q35", "-accel", "whpx", "-accel", "tcg", "-m", "2048", "-smp", "2",
           "-display", "none", "-nic", "none", "-kernel", str(ml / "vmlinuz-virt"), "-initrd", str(initrd),
           "-append", "console=ttyS0,115200 rdinit=/bin/sh loglevel=3",
           "-chardev", f"socket,id=s0,host=127.0.0.1,port={port},server=on,wait=off", "-serial", "chardev:s0",
           "-drive", f"file={disk.as_posix()},format=raw,if=none,id=t,cache=writeback", "-device", "ide-hd,drive=t,bus=ide.0",
           "-drive", f"file={Path(args.image).as_posix()},format=raw,if=none,id=img,readonly=on", "-device", "virtio-blk-pci,drive=img"]
    q = subprocess.Popen(cmd, stderr=(out / "prepare-qemu.log").open("wb"))
    print("prepare PID", q.pid, flush=True)
    console = None
    try:
        console = Console(port)
        time.sleep(8)
        console.run("export PATH=/usr/sbin:/usr/bin:/sbin:/bin; /bin/busybox --install -s 2>/dev/null; "
                    "mount -t proc proc /proc; mount -t sysfs sys /sys; mount -t devtmpfs dev /dev 2>/dev/null; "
                    "mkdir -p /tmp /run; mount -t tmpfs tmp /tmp; mount -t tmpfs run /run", "SETUP-DONE", 120)
        start = len(console.text)
        console.sock.sendall(f"SYSTEM={args.system} sh /usos-e2e/guest.sh 2>&1; echo E2E-EXIT\n".encode())
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
            if line.startswith(("[IMAGE_DISK]", "[XP_CSMWRAP]", "E2E", "mode=", "stop=", "/dev/sda")):
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
    vars_copy.write_bytes((qd / "share" / "edk2-i386-vars.fd").read_bytes())
    port = free_port()
    accel = ["-accel", "tcg"] if args.tcg else ["-accel", "whpx", "-accel", "tcg"]
    # No i8042: keys reach the guest only through the xHCI USB keyboard, as on
    # an X470 without a PS/2 keyboard.
    cmd = [str(qemu_copy(root)), "-machine", "q35,i8042=off", *accel, "-m", "4096", "-smp", "2",
           "-drive", f"if=pflash,format=raw,readonly=on,file={qd / 'share' / 'edk2-x86_64-code.fd'}",
           "-drive", f"if=pflash,format=raw,file={vars_copy}",
           "-drive", f"file={disk.as_posix()},format=raw,if=none,id=t,cache=writeback", "-device", "ide-hd,drive=t,bus=ide.0",
           "-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0", "-device", "usb-mouse,bus=xhci.0",
           "-vga", "std", "-display", "none", "-nic", "none", "-monitor", f"tcp:127.0.0.1:{port},server,nowait"]
    q = subprocess.Popen(cmd, stderr=(out / "boot-qemu.log").open("wb"))
    print("boot PID", q.pid, flush=True)
    keys = {}
    for item in filter(None, (args.keys or "").split(";")):
        t, k = item.split(":", 1)
        keys[int(t)] = k
    shots = sorted({*range(20, args.boot + 1, 20), *(t + 8 for t in keys)})
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
    args = p.parse_args()
    root = Path(args.root)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    disk = out / "target.raw"
    if args.boot_only:
        ok = disk.exists()
    else:
        with disk.open("wb") as f:
            f.truncate(args.disk_gib << 30)
        ok = prepare(args, root, out, disk)
    print("PREPARE", "PASS" if ok else "FAIL", flush=True)
    if ok and args.boot:
        boot(args, root, out, disk)
        print("BOOT screenshots in", out, flush=True)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
