#!/usr/bin/env python3
"""MS-DOS 6.22, Windows 3.x and Windows 98 SE through the REAL micro-Linux
(nested QEMU, dev PC only), optionally on an NVMe-only target.

Step 620 (tools/w9x_csmwrap_prepare.sh) in micro-Linux, minus the disk picker
and the screens, like run_nt3_micro_linux_qemu.py does for NT 3.x:

  dos    dos_csmwrap_target.sh with the MS-DOS 6.22 ISO
  w3     dos_csmwrap_target.sh with the MS-DOS 6.22 ISO + a Windows 3.x ISO
         (--win3; e.g. Windows for Workgroups 3.11)
  98se   w9x_csmwrap_target.sh (W9X_VM_PHASE1=1) + w9x_phase1_run +
         w9x_phase1_verify (Setup phase 1 in the inner QEMU, raw target on
         IDE there) with the USOS default MSBATCH.INF (+ TimeZone, as
         step 620 adds it); xp_csmwrap_esp.sh is called by the target script

Host QEMU (whpx, else TCG) boots zig-out/micro-linux (kernel +
initramfs-usos + qemu9x.cpio + an overlay cpio: guest script, CSMWrap folder,
zig-out/dos-native as the ESP's EFI/USOS/dos-native and, with --scripts, this
checkout's step-620 scripts). The target is a scratch qcow2 on `-device nvme`
(--nvme: /dev/nvme0n1, the X470's M.2) or IDE (/dev/sda); the ISOs are
read-only virtio disks (/dev/vda, /dev/vdb).

--boot then starts the prepared disk like the X470 without CSM: q35, OVMF ->
the disk's CSMWrap ESP -> SeaBIOS (INT 13h NVMe) -> the USOS MBR; the NVMe
controller is the ONLY disk controller and sits behind a pcie-root-port;
qemu-xhci keyboard + mouse, no NIC. Screenshots (OUT/boot-NN.png) and the VGA
text page (OUT/boot-NN.txt) every --shot-seconds; the DOS / Windows 3.x path
runs INSTALL.BAT, restarts and Windows Setup by itself.

    python tools/tests/run_w9x_micro_linux_qemu.py dos  --dos-iso DOS622.iso --out DIR --root BUILD --nvme [--boot]
    python tools/tests/run_w9x_micro_linux_qemu.py w3   --dos-iso DOS622.iso --win3 WFW.iso --out DIR --root BUILD --nvme [--boot]
    python tools/tests/run_w9x_micro_linux_qemu.py w3   --dos-iso DOS622.iso --win3-floppies "DIR/WfW 3.11 PL" --out DIR --root BUILD --scripts [--boot]
    python tools/tests/run_w9x_micro_linux_qemu.py 98se --iso 98SE.iso --out DIR --root BUILD --nvme [--boot]

--qemu: a renamed copy of qemu-system-x86_64.exe inside ROOT/tools/qemu (so
only this run's processes can be stopped by PID). Scratch images only (OUT);
no physical disk is opened. Delete OUT afterwards.
"""
from __future__ import annotations

import argparse
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE / "uefi_drivers"))
import run_nt3_micro_linux_qemu as nt3  # noqa: E402
from run_stage_drivers_qemu import Console  # noqa: E402

SCRIPTS = ("w9x_csmwrap_prepare.sh", "w9x_phase1_qemu.sh", "w9x_csmwrap_target.sh", "dos_csmwrap_target.sh",
           "xp_csmwrap_esp.sh", "w9x_nvme.sh", "floppy_set.sh")

GUEST = r'''#!/bin/sh
# run_w9x_micro_linux_qemu.py guest part: step 620's DOS / 9x calls, no screens.
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
TARGET=${E2E_TARGET:-/dev/sda}
log() { echo "E2E: $*"; }
for m in ahci sd_mod nvme virtio_pci virtio_blk loop isofs vfat fat nls_cp437 nls_iso8859_1 nls_utf8; do modprobe "$m" 2>/dev/null; done
sleep 2; mdev -s 2>/dev/null
[ -b "$TARGET" ] && [ -b /dev/vda ] || { log "no $TARGET or /dev/vda"; ls /dev; echo E2E-RESULT=FAIL; exit 1; }
log "target $TARGET $(cat /sys/class/block/${TARGET##*/}/queue/logical_block_size 2>/dev/null)-byte sectors, $(blockdev --getsize64 "$TARGET") bytes"
mkdir -p /mnt/data /tmp/w9x/phase1 /run
export USOS_CSMWRAP_DIR=/usos-e2e/csmwrap W9X_ESP_DIR=/usos-e2e/esp/EFI/USOS
dd if=/dev/vda of=/mnt/data/source.iso bs=1M 2>/tmp/dd.err || { cat /tmp/dd.err; df -h / /mnt/data; echo E2E-RESULT=FAIL; exit 1; }
if [ "$FAMILY" = 98se ]; then
    sed -n '/^w9x_msbatch_time_zone()/,/^}/p' /usr/lib/usos/w9x_csmwrap_prepare.sh > /tmp/tz.sh
    . /tmp/tz.sh
    cp /usos-e2e/esp/EFI/USOS/dos-native/win9x/MSBATCH.INF /run/w9x-msbatch.inf
    w9x_msbatch_time_zone 'Central European' /run/w9x-msbatch.inf
    . /usr/lib/usos/w9x_phase1_qemu.sh
    vm_reason=$(w9x_vm_available 98SE) || { log "VM not available: $vm_reason"; echo E2E-RESULT=FAIL; exit 1; }
    log "$vm_reason"
    if ! env TARGET_DEVICE="$TARGET" W9X_SOURCE_ISO=/mnt/data/source.iso W9X_SETUP_FOLDER=WIN98 W9X_TAG=98SE \
        W9X_ANSWER_INF=/run/w9x-msbatch.inf W9X_ANSWER_KIND=USOS W9X_BOOT_FLOPPY= W9X_SIZE_GIB=2 \
        W9X_USB_DIR=/mnt/data/Drivers/none/USB W9X_TIME_ZONE="Central European" W9X_VM_PHASE1=1 \
        sh /usr/lib/usos/w9x_csmwrap_target.sh > /tmp/prepare.log 2>&1 < /dev/null; then
        cat /tmp/prepare.log; echo E2E-RESULT=FAIL; exit 1
    fi
    cat /tmp/prepare.log
    accel=$(w9x_vm_accel)
    w9x_phase1_progress() { log "progress elapsed=$1 written=$2MB"; }
    w9x_phase1_run "$TARGET" "$accel"
    vm_rc=$?
    log "vm rc=$vm_rc elapsed=${W9X_VM_ELAPSED:-?}"
    w9x_phase1_keep_logs /tmp/w9x/phase1
    if [ "$vm_rc" != 0 ] || ! check=$(w9x_phase1_verify "$TARGET" /tmp/w9x/phase1); then
        log "phase1 FAIL ${check:-}"; ls -la /tmp/w9x/phase1; echo E2E-RESULT=FAIL; exit 1
    fi
    log "phase1 PASS $check"
    # --env W9X_NVME_DRIVER=1: step 620's nvme-experimental.txt path
    # (tools/w9x_nvme.sh): usosnvme into the installed Windows
    if [ "${W9X_NVME_DRIVER:-0}" = 1 ] && . /usr/lib/usos/w9x_nvme.sh && nl=$(losetup -f) && losetup -o 1048576 "$nl" "$TARGET"; then
        log "nvme inject: $(MTOOLS_SKIP_CHECK=1 w9x_nvme_inject "$nl" 2>&1)"
        MTOOLS_SKIP_CHECK=1 mtype -i "$nl" ::/WINDOWS/INF/USOSNVME.INF 2>/dev/null | grep -i 'PCI.VEN_\|CC_010802' | sed 's/^/E2E: inf /'
        MTOOLS_SKIP_CHECK=1 mdir -i "$nl" ::/WINDOWS/SYSTEM/IOSUBSYS/USOSNVME.MPD 2>/dev/null | grep -i usosnvme | sed 's/^/E2E: mpd /'
        losetup -d "$nl"
    fi
else
    WIN3=''
    if [ "$FAMILY" = w3 ] && [ -d /usos-e2e/floppies ]; then
        # --win3-floppies: the floppy disk set folder itself (no ISO)
        for d in /usos-e2e/floppies/*; do WIN3=$d; done
        log "floppy set: $WIN3 ($(ls "$WIN3" | wc -l) files)"
    elif [ "$FAMILY" = w3 ]; then
        dd if=/dev/vdb of=/mnt/data/win3.iso bs=1M 2>/dev/null || { echo E2E-RESULT=FAIL; exit 1; }
        WIN3=/mnt/data/win3.iso
    fi
    if ! env TARGET_DEVICE="$TARGET" W9X_SOURCE_ISO=/mnt/data/source.iso DOS_WIN3_ISO="$WIN3" DOS_WIN_EARLY= \
        DOS_PROGRAMS_DIR=/mnt/data/none sh /usr/lib/usos/dos_csmwrap_target.sh > /tmp/prepare.log 2>&1 < /dev/null; then
        cat /tmp/prepare.log; echo E2E-RESULT=FAIL; exit 1
    fi
    cat /tmp/prepare.log
fi
fdisk -l "$TARGET" 2>/dev/null | tail -n 4
sync
echo E2E-RESULT=PASS
'''


def overlay(args) -> bytes:
    entries: list[tuple[str, int, bytes]] = []
    dirs: set[str] = set()

    def add(path: str, data: bytes, mode: int = 0o100644) -> None:
        parts = path.split("/")[:-1]
        for i in range(1, len(parts) + 1):
            d = "/".join(parts[:i])
            if d not in dirs:
                dirs.add(d)
                entries.append((d, 0o040755, b""))
        entries.append((path, mode, data))

    add("usos-e2e/w9x.sh", GUEST.replace("\r\n", "\n").encode(), 0o100755)
    dos = args.root / "zig-out" / "dos-native"
    for f in sorted(dos.rglob("*")):
        if f.is_file() and f.name != "source.zip":
            add("usos-e2e/esp/EFI/USOS/dos-native/" + f.relative_to(dos).as_posix(), f.read_bytes())
    csmwrap = args.root / "zig-out" / "usb" / "EFI" / "USOS" / "csmwrap"
    for f in sorted(csmwrap.rglob("*")):
        if f.is_file():
            add("usos-e2e/csmwrap/" + f.relative_to(csmwrap).as_posix(), f.read_bytes())
    if args.win3_floppies:
        folder = Path(args.win3_floppies)
        for f in sorted(folder.iterdir()):
            if f.is_file():
                add(f"usos-e2e/floppies/{folder.name}/{f.name}", f.read_bytes())
    if args.scripts:
        for name in SCRIPTS:
            add("usr/lib/usos/" + name, (ROOT / "tools" / name).read_bytes(), 0o100755)
    return nt3.cpio_newc(entries)


def install(args, out: Path, target: Path) -> bool:
    ml = args.root / "zig-out" / "micro-linux"
    initrd = out / "initrd.cpio"
    with initrd.open("wb") as f:
        for part in ((ml / "initramfs-usos").read_bytes(), (ml / "qemu9x.cpio").read_bytes(), overlay(args)):
            f.write(part)
            f.write(b"\0" * (-f.tell() % 4))
    port = nt3.free_port()
    first = args.iso if args.family == "98se" else args.dos_iso
    disks = ["-drive", f"file={Path(first).as_posix()},format=raw,if=none,id=cd,readonly=on", "-device", "virtio-blk-pci,drive=cd"]
    if args.family == "w3" and not args.win3_floppies:
        disks += ["-drive", f"file={Path(args.win3).as_posix()},format=raw,if=none,id=w3,readonly=on", "-device", "virtio-blk-pci,drive=w3"]
    tgt = (["-device", "pcie-root-port,id=rpn,chassis=20,slot=20", "-device", "nvme,drive=t,serial=W9X-NVME-TARGET,bus=rpn"]
           if args.nvme else ["-device", "ide-hd,drive=t,bus=ide.0"])
    cmd = [str(args.qemu), "-machine", "q35", "-accel", "whpx", "-accel", "tcg", "-m", str(args.outer_mb), "-smp", "2",
           "-display", "none", "-nic", "none",
           "-kernel", str(ml / "vmlinuz-virt"), "-initrd", str(initrd),
           "-append", "console=ttyS0,115200 rdinit=/bin/sh loglevel=3",
           "-chardev", f"socket,id=s0,host=127.0.0.1,port={port},server=on,wait=off", "-serial", "chardev:s0",
           "-drive", f"file={target.as_posix()},format=qcow2,if=none,id=t,cache=writeback", *tgt, *disks]
    stderr = (out / "outer-qemu.log").open("wb")
    q = subprocess.Popen(cmd, stderr=stderr)
    (out / "outer-qemu.pid").write_text(str(q.pid))
    print(f"outer qemu pid {q.pid}", flush=True)
    console = None
    try:
        console = Console(port)
        time.sleep(10)
        console.run("export PATH=/usr/sbin:/usr/bin:/sbin:/bin; /bin/busybox --install -s 2>/dev/null; "
                    "mount -t proc proc /proc; mount -t sysfs sys /sys; mount -t devtmpfs dev /dev 2>/dev/null; "
                    "mkdir -p /tmp /run; mount -t tmpfs tmp /tmp; mount -t tmpfs run /run", "SETUP-DONE", 120)
        start = len(console.text)
        env = " ".join(args.env + (["E2E_TARGET=/dev/nvme0n1"] if args.nvme else []))
        console.sock.sendall(f"{env} FAMILY={args.family} sh /usos-e2e/w9x.sh 2>&1; echo E2E-EXIT\n".encode())
        deadline = time.time() + args.timeout
        shown = start
        while "E2E-RESULT=" not in console.text[start:] or "\nE2E-EXIT" not in console.text[start:]:
            if time.time() > deadline or q.poll() is not None:
                break
            try:
                chunk = console.sock.recv(65536)
                if chunk:
                    console.text += chunk.decode("utf-8", errors="replace")
            except socket.timeout:
                pass
            new = console.text[shown:]
            if "\n" in new:
                cut = new.rindex("\n") + 1
                for line in new[:cut].splitlines():
                    if line.startswith(("E2E", "[DOS_CSMWRAP]", "[W9X_CSMWRAP]", "[XP_CSMWRAP", "run ", "stalled", "rc=")):
                        print(line.rstrip(), flush=True)
                shown += cut
        ok = "E2E-RESULT=PASS" in console.text[start:]
        console.run("for f in /tmp/w9x/phase1/*.txt /tmp/w9x/phase1/*.log /tmp/w9x/phase1/*.LOG; do "
                    "[ -f \"$f\" ] && { echo \"=== $f\"; tr -d '\\r' < \"$f\" | tail -n 40; }; done", "LOGS-DONE", 60)
        console.run("sync", "SYNC-DONE", 120)
        return ok
    finally:
        if console is not None:
            (out / "console.log").write_text(console.text, encoding="utf-8")
            try:
                console.sock.sendall(b"sync; poweroff -f\n")
                q.wait(timeout=60)
            except Exception:
                pass
        if q.poll() is None:
            q.kill()
        q.wait()
        stderr.close()


def vga_text(raw: bytes) -> str:
    rows = []
    for r in range(25):
        line = raw[r * 160:(r + 1) * 160:2]
        rows.append(line.decode("cp437", errors="replace").rstrip())
    return "\n".join(rows).rstrip()


def boot(args, out: Path, target: Path) -> None:
    """X470-like boot without CSM: OVMF -> CSMWrap on the disk's ESP; NVMe behind a root port."""
    vars_ = out / "vars.fd"
    if not vars_.exists():
        shutil.copyfile(nt3.OVMF_VARS, vars_)
    port = nt3.free_port()
    disk = (["-device", "pcie-root-port,id=rpn,chassis=20,slot=20", "-device", "nvme,drive=t,serial=W9X-NVME-TARGET,bus=rpn"]
            if args.nvme else ["-device", "ide-hd,drive=t,bus=ide.0"])
    cmd = [str(args.qemu), "-machine", "q35", "-accel", "tcg", "-cpu", args.boot_cpu, "-smp", "2", "-m", str(args.boot_mb),
           "-drive", f"if=pflash,unit=0,format=raw,readonly=on,file={nt3.OVMF_CODE.as_posix()}",
           "-drive", f"if=pflash,unit=1,format=raw,file={vars_.as_posix()}",
           "-drive", f"file={target.as_posix()},format=qcow2,if=none,id=t,cache=writeback", *disk,
           "-display", "none", "-nic", "none", "-vga", "std", "-rtc", "base=localtime",
           "-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0", "-device", "usb-mouse,bus=xhci.0",
           "-monitor", f"tcp:127.0.0.1:{port},server=on,wait=off"]
    for i in range(4):
        cmd += ["-device", f"pcie-root-port,id=rp{i},chassis={i + 1},slot={i + 1}"]
    q = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=(out / "boot-qemu.log").open("wb"))
    (out / "boot-qemu.pid").write_text(str(q.pid))
    print(f"boot qemu pid {q.pid}", flush=True)
    try:
        for _ in range(100):
            try:
                mon = socket.create_connection(("127.0.0.1", port), timeout=5)
                break
            except OSError:
                time.sleep(0.2)
        mon.settimeout(0.5)

        def hmp(text: str, wait: float = 0.5) -> None:
            mon.sendall(text.encode() + b"\n")
            time.sleep(wait)
            try:
                while mon.recv(65536):
                    pass
            except OSError:
                pass

        def shot(name: str) -> None:
            ppm = out / f"{name}.ppm"
            vga = out / f"{name}.vga"
            hmp(f'screendump "{ppm.as_posix()}"', 2)
            hmp(f'pmemsave 0xb8000 4000 "{vga.as_posix()}"', 1)
            try:
                (out / f"{name}.txt").write_text(vga_text(vga.read_bytes()), encoding="utf-8")
                vga.unlink()
            except Exception:  # noqa: BLE001
                pass
            try:
                from PIL import Image
                Image.open(ppm).save(out / f"{name}.png")
                ppm.unlink()
            except Exception:  # noqa: BLE001 - keep the ppm
                pass

        t0 = time.time()
        n = args.shot_start
        while time.time() - t0 < args.boot_seconds and q.poll() is None:
            time.sleep(args.shot_seconds)
            n += 1
            shot(f"boot-{n:02d}")
            print(f"boot screenshot {n} at {int(time.time() - t0)} s", flush=True)
            if (out / "STOP").exists():
                break
        try:
            hmp("quit", 3)
        except OSError:
            pass
    finally:
        if q.poll() is None:
            try:
                q.wait(timeout=20)
            except subprocess.TimeoutExpired:
                q.kill()
        q.wait()


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("family", choices=["dos", "w3", "98se"])
    p.add_argument("--iso", help="98se: the Windows 98 SE ISO")
    p.add_argument("--dos-iso", help="dos / w3: the MS-DOS 6.22 ISO")
    p.add_argument("--win3", help="w3: the Windows 3.x ISO")
    p.add_argument("--win3-floppies", help="w3: a floppy disk set folder (diskette images) instead of --win3")
    p.add_argument("--out", required=True, type=Path)
    p.add_argument("--root", type=Path, default=ROOT, help="checkout with zig-out and tools/qemu")
    p.add_argument("--qemu", type=Path, help="renamed qemu-system-x86_64.exe copy (in ROOT/tools/qemu)")
    p.add_argument("--scripts", action="store_true", help="overlay this checkout's step-620 scripts")
    p.add_argument("--nvme", action="store_true", help="target on NVMe behind a pcie-root-port (install and boot)")
    p.add_argument("--outer-mb", type=int, default=1536)
    p.add_argument("--timeout", type=int, default=7200)
    p.add_argument("--env", action="append", default=[])
    p.add_argument("--boot", action="store_true")
    p.add_argument("--boot-only", action="store_true")
    p.add_argument("--boot-seconds", type=int, default=900)
    p.add_argument("--shot-seconds", type=int, default=30)
    p.add_argument("--shot-start", type=int, default=0, help="first screenshot number - 1 (continue a series)")
    p.add_argument("--boot-cpu", default="EPYC-Rome")
    p.add_argument("--boot-mb", type=int, default=1024)
    args = p.parse_args()
    nt3.set_root(args.root)
    args.qemu = args.qemu or nt3.QEMU
    args.out.mkdir(parents=True, exist_ok=True)
    target = args.out / "target.qcow2"
    if not args.boot_only:
        need = [args.iso] if args.family == "98se" else [args.dos_iso] + ([args.win3 or args.win3_floppies] if args.family == "w3" else [])
        if not all(need):
            raise SystemExit("missing ISO argument(s)")
        target.unlink(missing_ok=True)
        (args.out / "vars.fd").unlink(missing_ok=True)
        subprocess.run([str(nt3.QEMU_IMG), "create", "-q", "-f", "qcow2", str(target), "4G"], check=True)
        ok = install(args, args.out, target)
        print(f"[{'PASS' if ok else 'FAIL'}] {args.family} prepare through micro-Linux (console.log)")
        if not ok:
            return 1
    if args.boot or args.boot_only:
        boot(args, args.out, target)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
