#!/usr/bin/env python3
"""Stick ESP clean after a hard power-off in the POSReady VM loop (nested QEMU).

X470 2026-10-11 (B261011-151241): a POSReady install the user ended with a
power-off after 1 h (micro-Linux still in the VM loop) left the USOS stick
ESP's FAT32 dirty flag set: micro-Linux kept /mnt/esp mounted read-write for
the whole loop. tools/stick_write.sh now keeps it read-only there and the
logs reach it in short read-write windows (usos_stick_flush).

This runs the REAL micro-Linux (zig-out kernel + initramfs-usos + qemu9x.cpio
+ an overlay with this checkout's scripts) in a host QEMU: a scratch FAT32
"stick ESP" (raw, virtio /dev/vda) is mounted read-write at /mnt/esp exactly
as micro_linux_init.sh does, then the guest does what w9x_csmwrap_prepare.sh
does for POSReady: usos_stick_ro, logs in tmpfs (W9X_LOG), posready_vm_install
on a blank scratch target (/dev/sda; the nested QEMU finds no system and just
runs), live screen every POSR_VM_LIVE_EVERY seconds flushed onto the ESP.
After a few live flushes the host kills ITS OWN outer QEMU process (no clean
shutdown, like the power button) and reads the FAT32 boot sector of the
stick image: byte 0x41 bit 0 (Linux vfat's dirty flag) must be 0, and
EFI/USOS/win9x/posready/live/ must be on the image.

--control skips usos_stick_ro (the old behaviour): the flag must then be 1,
which shows the check can see the problem.

    python tools/tests/run_stick_esp_kill_qemu.py --root <checkout with zig-out> --qemu <renamed qemu copy> --out DIR [--control]

Scratch images only (OUT); no physical disk is opened. Delete OUT afterwards.
"""
from __future__ import annotations

import argparse
import struct
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "tests"))
sys.path.insert(0, str(ROOT / "tools" / "tests" / "uefi_drivers"))
from run_nt3_micro_linux_qemu import cpio_newc, free_port  # noqa: E402
from run_stage_drivers_qemu import Console  # noqa: E402

SCRIPTS = ("stick_write.sh", "w9x_phase1_qemu.sh", "posready_qemu_install.sh", "w9x_csmwrap_prepare.sh")

GUEST = r'''#!/bin/sh
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
log() { echo "E2E: $*"; }
for m in ahci sd_mod virtio_pci virtio_blk loop vfat fat nls_cp437 nls_iso8859_1 nls_utf8; do modprobe "$m" 2>/dev/null; done
sleep 2; mdev -s 2>/dev/null
[ -b /dev/sda ] && [ -b /dev/vda ] || { log "no /dev/sda or /dev/vda"; echo E2E-RESULT=FAIL; exit 1; }
mkfs.fat -F 32 -n USOS /dev/vda > /dev/null 2>&1 || { log 'mkfs.fat failed'; echo E2E-RESULT=FAIL; exit 1; }
mkdir -p /mnt/esp
# As micro_linux_init.sh.
mount -t vfat -o rw,noatime /dev/vda /mnt/esp || { echo E2E-RESULT=FAIL; exit 1; }
mkdir -p /mnt/esp/EFI/USOS/win9x
echo 'system=windows-embedded-posready-2009' > /mnt/esp/EFI/USOS/win9x/request.ini
sync
# As w9x_csmwrap_prepare.sh (its log helpers, unchanged).
sed -n '/^w9x_logs_to_esp()/,/^}/p; /^usos_stick_flush()/,/^}/p' /usr/lib/usos/w9x_csmwrap_prepare.sh > /tmp/flush.sh
. /tmp/flush.sh
. /usr/lib/usos/stick_write.sh
W9X_DIR=/mnt/esp/EFI/USOS/win9x
W9X_LOG=/run/usos-stick-log/win9x
rm -rf "$W9X_LOG"; mkdir -p "$W9X_LOG"
if [ "${CONTROL:-0}" = 1 ]; then
    log 'control: the ESP stays read-write (old behaviour)'
    usos_stick_flush() { mkdir -p "$W9X_DIR" && cp -rf "$W9X_LOG/." "$W9X_DIR/" && sync; }
else
    usos_stick_ro || log 'remount ro failed'
fi
log "stick mode=$(usos_stick_mode)"
. /usr/lib/usos/w9x_phase1_qemu.sh
. /usr/lib/usos/posready_qemu_install.sh
posready_vm_progress() {
    log "progress run=$1 elapsed=$2 mode=$(usos_stick_mode) live=$(ls /mnt/esp/EFI/USOS/win9x/posready/live 2>/dev/null | tr '\n' ' ')"
}
log 'VM loop start'
posready_vm_install /dev/sda "$W9X_LOG/posready" tcg
log "VM loop returned rc=$?"
echo E2E-RESULT=RETURNED
'''


def fat32_dirty(image: Path) -> tuple[int, bytes]:
    with image.open("rb") as f:
        boot = f.read(512)
    if boot[82:90] != b"FAT32   ":
        raise SystemExit(f"{image} is not FAT32 (fs type {boot[82:90]!r})")
    return boot[0x41] & 1, boot


def fat32_has_path(image: Path, parts: list[str]) -> bool:
    """Walks short 8.3 / LFN-free names (mkdir by Linux vfat writes 8.3 aliases); upper-case match."""
    with image.open("rb") as f:
        b = f.read(512)
        bps, spc = struct.unpack_from("<H", b, 11)[0], b[13]
        reserved, nfats = struct.unpack_from("<H", b, 14)[0], b[16]
        fatsz, root = struct.unpack_from("<I", b, 36)[0], struct.unpack_from("<I", b, 44)[0]
        data = (reserved + nfats * fatsz) * bps
        csize = bps * spc

        def fat(c: int) -> int:
            f.seek(reserved * bps + c * 4)
            return struct.unpack("<I", f.read(4))[0] & 0x0FFFFFFF

        def read_dir(c: int) -> bytes:
            out = b""
            while 2 <= c < 0x0FFFFFF8:
                f.seek(data + (c - 2) * csize)
                out += f.read(csize)
                c = fat(c)
            return out

        cluster = root
        for name in parts:
            entries = read_dir(cluster)
            want = name.upper()
            found = None
            for i in range(0, len(entries), 32):
                e = entries[i:i + 32]
                if e[0] == 0:
                    break
                if e[0] == 0xE5 or e[11] == 0x0F:
                    continue
                short = e[0:8].decode("ascii", "replace").rstrip() + (
                    "." + e[8:11].decode("ascii", "replace").rstrip() if e[8:11].strip() else "")
                if short.upper() == want:
                    found = (struct.unpack_from("<H", e, 20)[0] << 16) | struct.unpack_from("<H", e, 26)[0]
                    break
            if found is None:
                return False
            cluster = found
        return True


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--root", type=Path, required=True, help="checkout with zig-out/micro-linux")
    p.add_argument("--qemu", type=Path, required=True, help="a renamed copy of qemu-system-x86_64.exe")
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--control", action="store_true")
    p.add_argument("--live-every", type=int, default=20)
    p.add_argument("--kill-after", type=int, default=75, help="seconds of VM loop before the hard kill")
    args = p.parse_args()
    ml = args.root / "zig-out" / "micro-linux"
    qemu_img = args.qemu.parent / "qemu-img.exe"
    for required in (args.qemu, qemu_img, ml / "vmlinuz-virt", ml / "initramfs-usos", ml / "qemu9x.cpio"):
        if not required.exists():
            raise SystemExit(f"missing {required}")
    out = args.out
    out.mkdir(parents=True, exist_ok=True)
    target = out / "target.qcow2"
    stick = out / "stick-esp.img"
    target.unlink(missing_ok=True)
    stick.unlink(missing_ok=True)
    subprocess.run([str(qemu_img), "create", "-q", "-f", "qcow2", str(target), "1G"], check=True)
    with stick.open("wb") as f:
        f.truncate(256 * 1024 * 1024)
    entries = [("usos-e2e", 0o040755, b""), ("usos-e2e/guest.sh", 0o100755, GUEST.encode()),
               ("usr", 0o040755, b""), ("usr/lib", 0o040755, b""), ("usr/lib/usos", 0o040755, b"")]
    for name in SCRIPTS:
        entries.append(("usr/lib/usos/" + name, 0o100755, (ROOT / "tools" / name).read_bytes().replace(b"\r\n", b"\n")))
    initrd = out / "initrd.cpio"
    with initrd.open("wb") as f:
        for part in ((ml / "initramfs-usos").read_bytes(), (ml / "qemu9x.cpio").read_bytes(), cpio_newc(entries)):
            f.write(part)
            f.write(b"\0" * (-f.tell() % 4))
    port = free_port()
    cmd = [str(args.qemu), "-machine", "q35", "-accel", "whpx", "-accel", "tcg", "-m", "3072", "-smp", "2",
           "-display", "none", "-nic", "none",
           "-kernel", str(ml / "vmlinuz-virt"), "-initrd", str(initrd),
           "-append", "console=ttyS0,115200 rdinit=/bin/sh loglevel=3",
           "-chardev", f"socket,id=s0,host=127.0.0.1,port={port},server=on,wait=off", "-serial", "chardev:s0",
           "-drive", f"file={target.as_posix()},format=qcow2,if=none,id=t,cache=writeback", "-device", "ide-hd,drive=t,bus=ide.0",
           # The stick: writethrough, so what the guest wrote is in the file
           # when the process dies (a real stick has no host cache either).
           "-drive", f"file={stick.as_posix()},format=raw,if=none,id=esp,cache=writethrough", "-device", "virtio-blk-pci,drive=esp"]
    q = subprocess.Popen(cmd, stderr=(out / "outer-qemu.log").open("wb"))
    print(f"outer QEMU pid {q.pid}", flush=True)
    console = None
    try:
        console = Console(port)
        time.sleep(10)
        console.run("export PATH=/usr/sbin:/usr/bin:/sbin:/bin; /bin/busybox --install -s 2>/dev/null; "
                    "mount -t proc proc /proc; mount -t sysfs sys /sys; mount -t devtmpfs dev /dev 2>/dev/null; "
                    "mkdir -p /tmp /run; mount -t tmpfs tmp /tmp; mount -t tmpfs run /run", "SETUP-DONE", 120)
        start = len(console.text)
        console.sock.sendall(f"CONTROL={1 if args.control else 0} POSR_VM_LIVE_EVERY={args.live_every} "
                             f"W9X_VM_SCREEN_EVERY=10 POSR_VM_STALL=3600 POSR_VM_ANSWER_IDLE=3600 "
                             f"sh /usos-e2e/guest.sh 2>&1; echo E2E-EXIT\n".encode())
        loop_at = None
        shown = start
        deadline = time.time() + 600
        while time.time() < deadline and q.poll() is None:
            try:
                chunk = console.sock.recv(65536)
                if chunk:
                    console.text += chunk.decode("utf-8", errors="replace")
            except Exception:  # noqa: BLE001 - socket timeout
                pass
            new = console.text[shown:]
            if "\n" in new:
                cut = new.rindex("\n") + 1
                for line in new[:cut].splitlines():
                    if line.startswith("E2E"):
                        print(line.rstrip(), flush=True)
                shown += cut
            if "E2E-RESULT=" in console.text[start:]:
                print("guest script ended before the kill", flush=True)
                return 1
            if loop_at is None and "E2E: VM loop start" in console.text[start:]:
                loop_at = time.time()
            if loop_at is not None and time.time() - loop_at >= args.kill_after:
                break
        if loop_at is None:
            print("VM loop never started", flush=True)
            return 1
    finally:
        if console is not None:
            (out / "console.log").write_text(console.text, encoding="utf-8")
        # The power button: our own outer QEMU process, no guest shutdown.
        if q.poll() is None:
            q.kill()
        q.wait()
        print(f"outer QEMU pid {q.pid} killed", flush=True)
    dirty, _ = fat32_dirty(stick)
    live = fat32_has_path(stick, ["EFI", "USOS", "WIN9X", "POSREADY", "LIVE", "SCREEN.PPM"])
    print(f"stick ESP FAT32 dirty bit = {dirty}; posready/live/screen.ppm on the image = {live}", flush=True)
    if args.control:
        ok = dirty == 1
        print("[PASS] control: the read-write ESP is dirty after the kill" if ok else "[FAIL] control: expected dirty")
    else:
        ok = dirty == 0 and live
        print("[PASS] stick ESP clean after the hard kill, live logs on it" if ok else "[FAIL] stick ESP check")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
