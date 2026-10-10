#!/usr/bin/env python3
"""NT 3.x install through the REAL micro-Linux (nested QEMU, dev PC only).

The X470 runs the NT 3.x install inside micro-Linux (step 620,
tools/w9x_csmwrap_prepare.sh): nt4_csmwrap_target.sh writes the target, then
nt4_vm_install (tools/nt4_qemu_install.sh) runs qemu-system-i386 from
qemu9x.cpio on the target disk and answers Setup through the HMP monitor
pipes, nt4_vm_finish checks C: and xp_csmwrap_esp.sh adds the CSMWrap ESP.
Host-side harnesses drive Setup themselves and never ran those monitor
commands through micro-Linux's QEMU and BusyBox: the NT 3.1 X470 run of
2026-10-10 sat on the Welcome page at 0 MB because micro-Linux's HMP refused
the unquoted pmemsave file name. This test runs the same shell functions with
the same tools, nested:

  host QEMU (whpx, else TCG): zig-out/micro-linux kernel + initramfs-usos +
  qemu9x.cpio (+ an overlay cpio, below), rdinit=/bin/sh, serial console;
  the target is a scratch qcow2 on AHCI (/dev/sda), the CD a read-only
  virtio disk (/dev/vda). The guest script (written into the overlay) calls
  w9x_nt3_default_sif (from w9x_csmwrap_prepare.sh), nt4_csmwrap_target.sh,
  nt4_vm_install, nt4_vm_finish and xp_csmwrap_esp.sh exactly as step 620
  does, minus the disk picker and the screens.

The overlay cpio holds the guest script and the CSMWrap folder
(zig-out/usb/EFI/USOS/csmwrap). --scripts also puts this checkout's
tools/*.sh of the NT path into it (test a fix before build.bat); without it
the built initramfs' own copies run.

Then --boot starts the finished disk like the X470: q35, OVMF (no CSM) ->
the disk's CSMWrap ESP, EPYC-Rome, 2 CPUs, 2 GiB, ich9-ahci, qemu-xhci
keyboard + mouse, 12 pcie-root-ports, no NIC; screenshots in OUT/boot-*.png
(logon: Ctrl+Alt+Del, Administrator, blank password).

    python tools/tests/run_nt3_micro_linux_qemu.py --iso NT31.iso --out DIR [--scripts] [--boot]

NT 4.0 (--tag NT4 / NT4S / NT4T, Terminal Server Edition: NT4T) runs the same
way with NT_MAJOR=4: --answer is the WINNT.SIF the UEFI menu would stage
(NT4.SIF / NT4S.SIF / NT4T.SIF, rendered by src/flow/answer/nt4.zig; it holds
the product key, so keep it in OUT or outside the checkout), --sp the user's
SP6I386.EXE (optional: without it the finish step skips the service pack
check, the finished disk then has the RTM kernel). --boot-cpu picks the CPU
model of the --boot run (an RTM NT 4.0 kernel needs ",level=3").

Scratch images only (OUT); no physical disk is opened. Delete OUT afterwards.
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

# --root: the checkout with the build output (zig-out) and tools/qemu
# (build.bat's checkout; a worktree has neither).
QEMU = QEMU_IMG = OVMF_CODE = OVMF_VARS = ML = CSMWRAP = Path()


def set_root(root: Path) -> None:
    global QEMU, QEMU_IMG, OVMF_CODE, OVMF_VARS, ML, CSMWRAP
    QEMU = root / "tools" / "qemu" / "qemu-system-x86_64.exe"
    QEMU_IMG = root / "tools" / "qemu" / "qemu-img.exe"
    OVMF_CODE = root / "tools" / "qemu" / "share" / "edk2-x86_64-code.fd"
    OVMF_VARS = root / "tools" / "qemu" / "share" / "edk2-i386-vars.fd"
    ML = root / "zig-out" / "micro-linux"
    CSMWRAP = root / "zig-out" / "usb" / "EFI" / "USOS" / "csmwrap"
# The NT path's scripts (build_micro_linux.py puts them in /usr/lib/usos).
SCRIPTS = ("w9x_csmwrap_prepare.sh", "w9x_phase1_qemu.sh", "nt4_csmwrap_target.sh",
           "nt4_qemu_install.sh", "xp_csmwrap_esp.sh")

GUEST = r'''#!/bin/sh
# run_nt3_micro_linux_qemu.py guest part: step 620's NT calls, no screens.
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
TARGET=/dev/sda
SRC=/dev/vda
LOGS=/tmp/w9x/nt4
log() { echo "E2E: $*"; }
for m in ahci sd_mod virtio_pci virtio_blk loop isofs vfat fat nls_cp437 nls_iso8859_1 nls_utf8; do modprobe "$m" 2>/dev/null; done
sleep 2; mdev -s 2>/dev/null
[ -b "$TARGET" ] && [ -b "$SRC" ] || { log "no $TARGET or $SRC"; lsblk; echo E2E-RESULT=FAIL; exit 1; }
mkdir -p /mnt/data "$LOGS" /run
dd if="$SRC" of=/mnt/data/source.iso bs=1M 2>/dev/null || { echo E2E-RESULT=FAIL; exit 1; }
log "iso $(wc -c < /mnt/data/source.iso) bytes; scripts $(md5sum /usr/lib/usos/nt4_qemu_install.sh | cut -c1-12)"
if [ "$NT_MAJOR" = 4 ]; then
    # NT 4.0: the menu-rendered answer from the overlay; the key stays in RAM.
    cp /usos-e2e/winnt.sif /run/nt4-winnt.sif
    SP=''
    [ ! -f /usos-e2e/SP6I386.EXE ] || SP=/usos-e2e/SP6I386.EXE
    KIND=PROFILE
else
sed -n '/^w9x_nt3_default_sif()/,/^}/p' /usr/lib/usos/w9x_csmwrap_prepare.sh > /tmp/sif.sh
. /tmp/sif.sh
w9x_nt3_default_sif 'Central European' > /run/nt4-winnt.sif
SP=''
KIND=USOS
fi
if ! env TARGET_DEVICE="$TARGET" NT4_SOURCE_ISO=/mnt/data/source.iso NT4_ANSWER_SIF=/run/nt4-winnt.sif \
    NT4_ANSWER_KIND="$KIND" NT4_SP_EXE="$SP" NT_MAJOR="$NT_MAJOR" NT_MINOR="$NT_MINOR" NT4_EDITION="${NT4_EDITION:-}" \
    sh /usr/lib/usos/nt4_csmwrap_target.sh > /tmp/prepare.log 2>&1 < /dev/null; then
    cat /tmp/prepare.log; echo E2E-RESULT=FAIL; exit 1
fi
cat /tmp/prepare.log
. /usr/lib/usos/w9x_phase1_qemu.sh
. /usr/lib/usos/nt4_qemu_install.sh
# The same gate as step 620 (w9x_csmwrap_prepare.sh stops when it fails).
vm_reason=$(w9x_vm_available "$TAG") || { log "VM not available: $vm_reason"; echo E2E-RESULT=FAIL; exit 1; }
log "$vm_reason"
accel=$(w9x_vm_accel)
NT4_PROGRESS_AT=0
nt4_vm_progress() {
    [ "$2" -ge "$NT4_PROGRESS_AT" ] || [ "$2" -lt 10 ] || return 0
    NT4_PROGRESS_AT=$(( $2 + 60 ))
    [ "$2" -ge 10 ] || NT4_PROGRESS_AT=60
    log "progress start=$1 elapsed=$2 written=$3MB"
}
nt4_vm_install "$TARGET" "$LOGS" "$accel"
vm_rc=$?
log "vm rc=$vm_rc elapsed=${NT4_VM_ELAPSED:-?}"
cat "$LOGS/runs.txt"
for d in "$LOGS"/run-*; do echo "== $d"; grep -v '^/usr/bin/qemu' "$d/command.txt"; done
if [ "$vm_rc" != 0 ]; then
    for d in "$LOGS"/run-*; do echo "== $d monitor errors"; tr '\r' '\n' < "$d/monitor.log" 2>/dev/null | grep -i -e invalid -e error -e 'try "help' | sort | uniq -c | head; done
    echo E2E-RESULT=FAIL; exit 1
fi
if ! check=$(nt4_vm_finish "$TARGET" "$LOGS"); then log "finish FAIL $check"; cat "$LOGS/fsck.txt"; echo E2E-RESULT=FAIL; exit 1; fi
log "finish PASS $check"
cat "$LOGS/BOOT.INI"
if ! TARGET_DEVICE="$TARGET" USOS_XP_ESP_TAIL_SECTORS=133120 USOS_CSMWRAP_DIR=/usos-e2e/csmwrap sh /usr/lib/usos/xp_csmwrap_esp.sh > /tmp/esp.log 2>&1; then
    cat /tmp/esp.log; echo E2E-RESULT=FAIL; exit 1
fi
tail -n 3 /tmp/esp.log
sync
echo E2E-RESULT=PASS
'''


def cpio_newc(entries: list[tuple[str, int, bytes]]) -> bytes:
    """newc archive of (path, mode, data); directories have mode 0o040755 and no data."""
    out = io.BytesIO()
    ino = 1

    def add(name: str, mode: int, data: bytes) -> None:
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


def overlay(scripts: bool, answer: Path | None = None, sp: Path | None = None) -> bytes:
    entries: list[tuple[str, int, bytes]] = []
    dirs = set()

    def mkdirs(path: str) -> None:
        parts = path.split("/")[:-1]
        for i in range(1, len(parts) + 1):
            d = "/".join(parts[:i])
            if d not in dirs:
                dirs.add(d)
                entries.append((d, 0o040755, b""))

    def add(path: str, data: bytes, mode: int = 0o100644) -> None:
        mkdirs(path)
        entries.append((path, mode, data))

    add("usos-e2e/nt3.sh", GUEST.replace("\r\n", "\n").encode(), 0o100755)
    for f in sorted(CSMWRAP.rglob("*")):
        if f.is_file():
            add("usos-e2e/csmwrap/" + f.relative_to(CSMWRAP).as_posix(), f.read_bytes())
    if answer is not None:
        add("usos-e2e/winnt.sif", answer.read_bytes())
    if sp is not None:
        add("usos-e2e/SP6I386.EXE", sp.read_bytes())
    if scripts:
        for name in SCRIPTS:
            add("usr/lib/usos/" + name, (ROOT / "tools" / name).read_bytes(), 0o100755)
    return cpio_newc(entries)


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def install(args, out: Path, target: Path) -> bool:
    initrd = out / "initrd.cpio"
    with initrd.open("wb") as f:
        for part in ((ML / "initramfs-usos").read_bytes(), (ML / "qemu9x.cpio").read_bytes(),
                     overlay(args.scripts, args.answer, args.sp)):
            f.write(part)
            f.write(b"\0" * (-f.tell() % 4))
    port = free_port()
    accel = ["-accel", "whpx", "-accel", "tcg"] if args.accel == "whpx" else ["-accel", "tcg", "-cpu", "max"]
    cmd = [str(QEMU), "-machine", "q35", *accel, "-m", "3072", "-smp", "2", "-display", "none", "-nic", "none",
           "-kernel", str(ML / "vmlinuz-virt"), "-initrd", str(initrd),
           "-append", "console=ttyS0,115200 rdinit=/bin/sh loglevel=3",
           "-chardev", f"socket,id=s0,host=127.0.0.1,port={port},server=on,wait=off", "-serial", "chardev:s0",
           "-drive", f"file={target.as_posix()},format=qcow2,if=none,id=t,cache=writeback", "-device", "ide-hd,drive=t,bus=ide.0",
           "-drive", f"file={Path(args.iso).as_posix()},format=raw,if=none,id=cd,readonly=on", "-device", "virtio-blk-pci,drive=cd"]
    stderr = (out / "outer-qemu.log").open("wb")
    q = subprocess.Popen(cmd, stderr=stderr)
    console = None
    try:
        console = Console(port)
        time.sleep(10)
        console.run("export PATH=/usr/sbin:/usr/bin:/sbin:/bin; /bin/busybox --install -s 2>/dev/null; "
                    "mount -t proc proc /proc; mount -t sysfs sys /sys; mount -t devtmpfs dev /dev 2>/dev/null; "
                    "mkdir -p /tmp /run; mount -t tmpfs tmp /tmp; mount -t tmpfs run /run", "SETUP-DONE", 120)
        minor = {"NT31": "10", "NT31S": "10", "NT35": "50", "NT35S": "50", "NT351": "51", "NT351S": "51",
                 "NT4": "", "NT4S": "", "NT4T": ""}[args.tag]
        major = "4" if args.tag.startswith("NT4") else "3"
        edition = "tse" if args.tag == "NT4T" else ""
        start = len(console.text)
        env = " ".join(args.env)
        console.sock.sendall(f"{env} TAG={args.tag} NT_MAJOR={major} NT_MINOR={minor} NT4_EDITION={edition} "
                             f"sh /usos-e2e/nt3.sh 2>&1; echo E2E-EXIT\n".encode())
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
                    if line.startswith(("E2E", "[NT4_CSMWRAP]", "run ", "nt31 ", "answer ", "text answer", "stalled", "rc=")):
                        print(line.rstrip(), flush=True)
                shown += cut
        console.run("sync", "SYNC-DONE", 120)
        return "E2E-RESULT=PASS" in console.text[start:]
    finally:
        if console is not None:
            (out / "console.log").write_text(console.text, encoding="utf-8")
            # cache=unsafe ignored the guest's flushes and q.kill() then lost
            # the last target writes (POSReady run, 2026-10-10): writeback
            # honours sync, and the guest powers off so QEMU closes the qcow2
            # itself; kill only as a fallback.
            try:
                console.sock.sendall(b"sync; poweroff -f\n")
                q.wait(timeout=60)
            except Exception:
                pass
        if q.poll() is None:
            q.kill()
        q.wait()
        stderr.close()


def boot(out: Path, target: Path, seconds: int, cpu: str = "EPYC-Rome") -> None:
    """X470-like boot of the finished disk; screenshots only (the user logs on by hand there)."""
    vars_ = out / "vars.fd"
    shutil.copyfile(OVMF_VARS, vars_)
    port = free_port()
    cmd = [str(QEMU), "-machine", "q35", "-accel", "tcg", "-cpu", cpu, "-smp", "2", "-m", "2048",
           "-drive", f"if=pflash,unit=0,format=raw,readonly=on,file={OVMF_CODE.as_posix()}",
           "-drive", f"if=pflash,unit=1,format=raw,file={vars_.as_posix()}",
           "-drive", f"file={target.as_posix()},format=qcow2,if=none,id=t,snapshot=on", "-device", "ide-hd,drive=t,bus=ide.0",
           "-display", "none", "-nic", "none", "-vga", "std",
           "-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0", "-device", "usb-mouse,bus=xhci.0",
           "-monitor", f"tcp:127.0.0.1:{port},server=on,wait=off"]
    for i in range(12):
        cmd += ["-device", f"pcie-root-port,id=rp{i},chassis={i + 1},slot={i + 1}"]
    q = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=(out / "boot-qemu.log").open("wb"))
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
            hmp(f'screendump "{ppm.as_posix()}"', 2)
            try:
                from PIL import Image
                Image.open(ppm).save(out / f"{name}.png")
                ppm.unlink()
            except Exception:  # noqa: BLE001 - keep the ppm
                pass

        t0 = time.time()
        n = 0
        while time.time() - t0 < seconds and q.poll() is None:
            time.sleep(30)
            n += 1
            shot(f"boot-{n:02d}")
            print(f"boot screenshot {n} at {int(time.time() - t0)} s", flush=True)
        hmp("sendkey ctrl-alt-delete", 5)
        shot("boot-cad")
        hmp("sendkey ret", 60)
        shot("boot-logon")
    finally:
        q.kill()
        q.wait()


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--iso", required=True)
    p.add_argument("--tag", default="NT31", choices=["NT31", "NT31S", "NT35", "NT35S", "NT351", "NT351S", "NT4", "NT4S", "NT4T"])
    p.add_argument("--answer", type=Path, help="NT 4.0: the WINNT.SIF the menu would stage (holds the key)")
    p.add_argument("--sp", type=Path, help="NT 4.0: the service pack SP6I386.EXE (optional)")
    p.add_argument("--boot-cpu", default="EPYC-Rome", help="CPU model of the --boot run")
    p.add_argument("--out", required=True, type=Path)
    p.add_argument("--scripts", action="store_true", help="overlay this checkout's NT path scripts")
    p.add_argument("--accel", default="whpx", choices=["whpx", "tcg"])
    p.add_argument("--timeout", type=int, default=7200)
    p.add_argument("--root", type=Path, default=ROOT, help="checkout with zig-out and tools/qemu (default: this one)")
    p.add_argument("--env", action="append", default=[], help="K=V for the guest script (e.g. NT4_VM_STALL=120)")
    p.add_argument("--boot", action="store_true", help="boot the finished disk under OVMF + CSMWrap")
    p.add_argument("--boot-only", action="store_true")
    p.add_argument("--boot-seconds", type=int, default=420)
    p.add_argument("--qemu", type=Path, help="host qemu-system-x86_64 to use (default: ROOT/tools/qemu)")
    args = p.parse_args()
    set_root(args.root)
    if args.qemu is not None:
        global QEMU
        QEMU = args.qemu
    for required in (QEMU, QEMU_IMG, ML / "vmlinuz-virt", ML / "initramfs-usos", ML / "qemu9x.cpio", CSMWRAP / "csmwrapx64.efi"):
        if not required.exists():
            raise SystemExit(f"missing {required}")
    if args.tag.startswith("NT4") and args.answer is None and not args.boot_only:
        raise SystemExit("NT 4.0 needs --answer (the WINNT.SIF with the key)")
    args.out.mkdir(parents=True, exist_ok=True)
    target = args.out / "target.qcow2"
    if not args.boot_only:
        target.unlink(missing_ok=True)
        subprocess.run([str(QEMU_IMG), "create", "-q", "-f", "qcow2", str(target), "8G"], check=True)
        ok = install(args, args.out, target)
        what = "NT 4.0" if args.tag.startswith("NT4") else "NT 3.x"
        print(f"[PASS] {what} install through micro-Linux" if ok else f"[FAIL] {what} install through micro-Linux (console.log)")
        if not ok:
            return 1
    if args.boot or args.boot_only:
        boot(args.out, target, args.boot_seconds, args.boot_cpu)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
