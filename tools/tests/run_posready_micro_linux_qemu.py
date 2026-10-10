#!/usr/bin/env python3
"""Windows Embedded POSReady 2009 through the REAL micro-Linux (dev PC only).

Stage 1 (always): nested QEMU like run_nt3_micro_linux_qemu.py; micro-Linux
(zig-out kernel + initramfs-usos + qemu9x.cpio + an overlay) runs
tools/posready_csmwrap_target.sh from this checkout on a scratch qcow2
(/dev/sda) with the ISO as a read-only virtio disk (/dev/vda).

Stage 2 (--vm host|nested): the POSReady install VM on that disk.
  host:   this PC's QEMU (pc, SeaBIOS, IDE, whpx else TCG) - fast check of
          the PE start, SetupLauncher + unattended.xml, Setup, FBA;
  nested: micro-Linux's qemu-system-i386 (posready_vm_install from
          tools/posready_qemu_install.sh), as on the X470.
Screenshots every --shot seconds in OUT/vm-*.png; the VM ends on its own
(-no-reboot) or after --vm-seconds.

    python tools/tests/run_posready_micro_linux_qemu.py --iso POSReady.iso --unattended U.xml --out DIR [--vm host]

Scratch images only (OUT); no physical disk is opened. Delete OUT afterwards.
The answer file may hold a product key: it is never printed or logged here.
"""
from __future__ import annotations

import argparse
import socket
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "tests"))
import run_nt3_micro_linux_qemu as nt3  # noqa: E402

GUEST = r'''#!/bin/sh
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
TARGET=/dev/sda
SRC=/dev/vda
log() { echo "E2E: $*"; }
for m in ahci sd_mod virtio_pci virtio_blk loop isofs vfat fat nls_cp437 nls_iso8859_1 nls_utf8; do modprobe "$m" 2>/dev/null; done
sleep 2; mdev -s 2>/dev/null
[ -b "$TARGET" ] && [ -b "$SRC" ] || { log "no $TARGET or $SRC"; echo E2E-RESULT=FAIL; exit 1; }
mkdir -p /mnt/data /run
if [ "${POSR_STAGE:-}" = after ]; then
    modprobe ntfs3 2>/dev/null
    . /usr/lib/usos/posready_qemu_install.sh
    mkdir -p /tmp/posr
    posready_after_setup "$TARGET" /tmp/posr; rc=$?
    cat /tmp/posr/runs.txt 2>/dev/null; cat /tmp/posr/setup-boot.ini 2>/dev/null
    sync
    [ "$rc" = 0 ] && echo E2E-RESULT=PASS || echo E2E-RESULT=FAIL
    exit 0
fi
if [ "${POSR_STAGE:-}" = finish ]; then
    modprobe ntfs3 2>/dev/null
    . /usr/lib/usos/posready_qemu_install.sh
    mkdir -p /tmp/posr
    if check=$(posready_vm_finish "$TARGET" /tmp/posr); then log "finish PASS $check"; else log "finish FAIL $check"; echo E2E-RESULT=FAIL; exit 0; fi
    cat /tmp/posr/FIRST.LOG; cat /tmp/posr/BOOT.INI
    TARGET_DEVICE="$TARGET" USOS_XP_ESP_TAIL_SECTORS=133120 USOS_CSMWRAP_DIR=/usos-e2e/csmwrap sh /usr/lib/usos/xp_csmwrap_esp.sh > /tmp/esp.log 2>&1 || { cat /tmp/esp.log; echo E2E-RESULT=FAIL; exit 0; }
    tail -n 2 /tmp/esp.log
    sync
    echo E2E-RESULT=PASS
    exit 0
fi
dd if="$SRC" of=/mnt/data/source.iso bs=1M 2>/dev/null || { echo E2E-RESULT=FAIL; exit 1; }
log "iso $(wc -c < /mnt/data/source.iso) bytes"
if ! env TARGET_DEVICE="$TARGET" POSR_SOURCE_ISO=/mnt/data/source.iso POSR_UNATTENDED=/usos-e2e/unattended.xml \
    POSR_PRESETUP=$([ -f /usos-e2e/presetup.cmd ] && echo /usos-e2e/presetup.cmd) \
    POSR_POSTSETUP=$([ -f /usos-e2e/postsetup.cmd ] && echo /usos-e2e/postsetup.cmd) \
    ${POSR_EXTRA_ENV:-} sh /usr/lib/usos/posready_csmwrap_target.sh > /tmp/prepare.log 2>&1 < /dev/null; then
    cat /tmp/prepare.log; echo E2E-RESULT=FAIL; exit 1
fi
cat /tmp/prepare.log
sync; echo 3 > /proc/sys/vm/drop_caches
mkdir -p /tmp/chk; l=$(losetup -f); losetup -r -o 32256 "$l" "$TARGET" && mount -t vfat -o ro "$l" /tmp/chk &&
    log "readback: Setup=$(ls /tmp/chk/Setup | wc -l) I386=$(ls /tmp/chk/I386 | wc -l) MININT=$(ls /tmp/chk/MININT | wc -l) unattended=$(wc -c < /tmp/chk/Setup/unattended.xml)"
umount /tmp/chk 2>/dev/null; losetup -d "$l" 2>/dev/null
if [ "${POSR_NESTED_VM:-0}" = 1 ]; then
    . /usr/lib/usos/w9x_phase1_qemu.sh
    . /usr/lib/usos/posready_qemu_install.sh
    accel=$(w9x_vm_accel)
    mkdir -p /tmp/posr
    posready_vm_install "$TARGET" /tmp/posr "$accel"; rc=$?
    log "vm rc=$rc"
    cat /tmp/posr/runs.txt 2>/dev/null
    [ "$rc" = 0 ] || { echo E2E-RESULT=FAIL; exit 1; }
fi
sync
echo E2E-RESULT=PASS
'''

SCRIPTS = ("posready_csmwrap_target.sh", "posready_qemu_install.sh", "w9x_phase1_qemu.sh")


def overlay(unattended: bytes, extra: dict[str, bytes]) -> bytes:
    entries = [("usos-e2e", 0o040755, b""), ("usos-e2e/csmwrap", 0o040755, b""), *[("usos-e2e/" + k, 0o100644, v) for k, v in extra.items()], ("usos-e2e/posr.sh", 0o100755, GUEST.encode()),
               ("usos-e2e/unattended.xml", 0o100644, unattended),
               ("usr", 0o040755, b""), ("usr/lib", 0o040755, b""), ("usr/lib/usos", 0o040755, b"")]
    for name in SCRIPTS:
        f = ROOT / "tools" / name
        if f.exists():
            entries.append(("usr/lib/usos/" + name, 0o100755, f.read_bytes().replace(b"\r\n", b"\n")))
    # The payload build_micro_linux.py puts into initramfs-usos (this
    # checkout's copies, so a build before the test is not needed).
    entries += [("usr/lib/usos/posready", 0o040755, b""), ("usr/lib/usos/posready/DRV", 0o040755, b""),
                ("usr/lib/usos/posready_unattended.xml", 0o100644, (ROOT / "tools/posready_unattended.xml").read_bytes()),
                ("usr/lib/usos/posready/X470.REG", 0o100644, (ROOT / "tools/posready_x470.reg").read_bytes()),
                ("usr/lib/usos/posready/FIRST.CMD", 0o100644, (ROOT / "tools/posready_first.cmd").read_bytes())]
    for f in sorted(nt3.CSMWRAP.rglob("*")):
        rel = "usos-e2e/csmwrap/" + f.relative_to(nt3.CSMWRAP).as_posix()
        if f.is_dir():
            entries.append((rel, 0o040755, b""))
        else:
            entries.append((rel, 0o100644, f.read_bytes()))
    sys.path.insert(0, str(ROOT / "tools"))
    from build_micro_linux import POSREADY_DRIVERS  # noqa: E402
    drivers = ROOT / "media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x86"
    for name in POSREADY_DRIVERS:
        entries.append(("usr/lib/usos/posready/DRV/" + name.split("/")[1], 0o100644, (drivers / name).read_bytes()))
    return nt3.cpio_newc(entries)


def prepare(args, out: Path, target: Path) -> bool:
    initrd = out / "initrd.cpio"
    with initrd.open("wb") as f:
        for part in ((nt3.ML / "initramfs-usos").read_bytes(), (nt3.ML / "qemu9x.cpio").read_bytes(),
                     overlay(Path(args.unattended).read_bytes(),
                             {k: Path(v).read_bytes() for k, v in (("presetup.cmd", args.presetup), ("postsetup.cmd", args.postsetup)) if v})):
            f.write(part)
            f.write(b"\0" * (-f.tell() % 4))
    port = nt3.free_port()
    accel = ["-accel", "whpx", "-accel", "tcg"] if args.accel == "whpx" else ["-accel", "tcg", "-cpu", "max"]
    cmd = [str(nt3.QEMU), "-machine", "q35", *accel, "-m", "3072", "-smp", "2", "-display", "none", "-nic", "none",
           "-kernel", str(nt3.ML / "vmlinuz-virt"), "-initrd", str(initrd),
           "-append", "console=ttyS0,115200 rdinit=/bin/sh loglevel=3",
           "-chardev", f"socket,id=s0,host=127.0.0.1,port={port},server=on,wait=off", "-serial", "chardev:s0",
           "-drive", f"file={target.as_posix()},format=qcow2,if=none,id=t,cache=writeback", "-device", "ide-hd,drive=t,bus=ide.0",
           "-drive", f"file={Path(args.iso).as_posix()},format=raw,if=none,id=cd,readonly=on", "-device", "virtio-blk-pci,drive=cd"]
    q = subprocess.Popen(cmd, stderr=(out / "outer-qemu.log").open("wb"))
    console = None
    try:
        console = nt3.Console(port)
        time.sleep(10)
        console.run("export PATH=/usr/sbin:/usr/bin:/sbin:/bin; /bin/busybox --install -s 2>/dev/null; "
                    "mount -t proc proc /proc; mount -t sysfs sys /sys; mount -t devtmpfs dev /dev 2>/dev/null; "
                    "mkdir -p /tmp /run; mount -t tmpfs tmp /tmp; mount -t tmpfs run /run", "SETUP-DONE", 120)
        start = len(console.text)
        env = " ".join(args.env + (["POSR_NESTED_VM=1"] if args.vm == "nested" else []))
        console.sock.sendall(f"{env} sh /usos-e2e/posr.sh 2>&1; echo E2E-EXIT\n".encode())
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
                    if line.startswith(("E2E", "[POSREADY", "run ", "stalled", "rc=")):
                        print(line.rstrip(), flush=True)
                shown += cut
        console.run("sync", "SYNC-DONE", 120)
        return "E2E-RESULT=PASS" in console.text[start:]
    finally:
        if console is not None:
            (out / "console.log").write_text(console.text, encoding="utf-8")
        q.kill()
        q.wait()


def host_vm(args, out: Path, target: Path) -> int:
    """POSReady Setup on this PC's QEMU: one run per guest restart (-no-reboot)."""
    rc = 0
    if args.start_run > 1 and args.after_first:
        saved = list(args.env)
        args.env = saved + ["POSR_STAGE=after"]
        ok = prepare(args, out, target)
        args.env = saved
        print(f"after-setup step {'PASS' if ok else 'FAIL'}", flush=True)
        if not ok:
            return 1
    for run in range(args.start_run, args.vm_runs + 1):
        port = nt3.free_port()
        accel = ["-accel", "whpx", "-accel", "tcg"] if args.accel == "whpx" else ["-accel", "tcg"]
        cmd = [str(nt3.QEMU), "-machine", "pc", *accel, "-cpu", "qemu32" if args.accel != "whpx" else "max",
               "-smp", str(args.smp), "-m", "1024", "-no-reboot", "-nic", "none", "-display", "none", "-vga", "std",
               "-drive", f"file={target.as_posix()},format=qcow2,if=ide,index=0,media=disk,cache=writeback",
               "-rtc", "base=localtime", "-monitor", f"tcp:127.0.0.1:{port},server=on,wait=off"]
        q = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=(out / f"vm-{run}-qemu.log").open("wb"))
        mon = None
        for _ in range(100):
            try:
                mon = socket.create_connection(("127.0.0.1", port), timeout=5)
                break
            except OSError:
                time.sleep(0.2)
        assert mon is not None
        mon.settimeout(0.5)

        def hmp(text: str, wait: float = 0.5) -> None:
            try:  # the guest may end QEMU at any moment (-no-reboot)
                mon.sendall(text.encode() + b"\n")
            except OSError:
                return
            time.sleep(wait)
            try:
                while mon.recv(65536):
                    pass
            except OSError:
                pass

        t0 = time.time()
        n = 0
        typed = False
        try:
            while q.poll() is None and time.time() - t0 < args.vm_seconds:
                time.sleep(args.shot)
                n += 1
                ppm = out / f"vm-{run}-{n:03d}.ppm"
                try:
                    hmp(f"screendump \"{ppm.as_posix()}\"", 0.3)
                    from PIL import Image
                    Image.open(ppm).save(out / f"vm-{run}-{n:03d}.png")
                    ppm.unlink()
                except Exception:  # noqa: BLE001
                    pass
                print(f"vm run {run} shot {n} at {int(time.time() - t0)} s", flush=True)
                if args.type and not typed and run >= args.type_from_run and time.time() - t0 >= args.type_after:
                    typed = True
                    for k in keys_for(args.type):
                        hmp(f"sendkey {k}", 0.15)
            ended = q.poll() is not None
        finally:
            q.kill()
            q.wait()
        print(f"vm run {run} {'ended by the guest' if ended else 'timed out'} after {int(time.time() - t0)} s", flush=True)
        if run == 1 and ended:
            saved = list(args.env)
            args.env = saved + ["POSR_STAGE=after"]
            ok = prepare(args, out, target)
            args.env = saved
            print(f"after-setup step {'PASS' if ok else 'FAIL'}", flush=True)
            if not ok:
                return 1
        if not ended:
            rc = 1
            break
    return rc


def keys_for(text: str) -> list[str]:
    """QEMU sendkey names for TEXT (US layout); a newline is ret."""
    special = {" ": "spc", "\n": "ret", ".": "dot", "\\": "backslash", ":": "shift-semicolon", "/": "slash",
               "-": "minus", ">": "shift-dot", "_": "shift-minus", "*": "shift-8", "=": "equal", "%": "shift-5", "|": "shift-backslash"}
    if text.startswith("keys:"):  # raw sendkey names, e.g. keys:alt-d
        return text[5:].split()
    out = []
    for ch in text.replace("\\n", "\n"):
        if ch in special:
            out.append(special[ch])
        elif ch.isupper():
            out.append("shift-" + ch.lower())
        else:
            out.append(ch)
    return out


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--iso", required=True)
    p.add_argument("--unattended", required=True)
    p.add_argument("--out", required=True, type=Path)
    p.add_argument("--presetup")
    p.add_argument("--type", help="text typed into the VM once (\n = Enter)")
    p.add_argument("--type-after", type=int, default=120)
    p.add_argument("--type-from-run", type=int, default=1, help="type only in this run and later (each run once)")
    p.add_argument("--postsetup")
    p.add_argument("--accel", default="whpx", choices=["whpx", "tcg"])
    p.add_argument("--timeout", type=int, default=7200)
    p.add_argument("--root", type=Path, default=Path("C:/Users/ASRock/Desktop/usos-x470-98se"))
    p.add_argument("--env", action="append", default=[])
    p.add_argument("--vm", choices=["none", "host", "nested"], default="none")
    p.add_argument("--vm-only", action="store_true", help="skip stage 1 (reuse OUT/target.qcow2)")
    p.add_argument("--vm-runs", type=int, default=3)
    p.add_argument("--smp", type=int, default=1, help="install VM CPUs (1 like posready_qemu_install.sh)")
    p.add_argument("--start-run", type=int, default=1, help="with --vm-only: continue at this run")
    p.add_argument("--after-first", action="store_true", help="with --start-run > 1: run the after-setup step first")
    p.add_argument("--vm-seconds", type=int, default=3600)
    p.add_argument("--shot", type=int, default=30)
    p.add_argument("--size", default="16G")
    p.add_argument("--finish", action="store_true", help="after the VM runs: posready_vm_finish + xp_csmwrap_esp.sh in micro-Linux")
    p.add_argument("--finish-only", action="store_true")
    p.add_argument("--boot", action="store_true", help="then boot the disk like the X470 (OVMF + CSMWrap, run_nt3 boot())")
    p.add_argument("--boot-seconds", type=int, default=420)
    args = p.parse_args()
    nt3.set_root(args.root)
    args.out.mkdir(parents=True, exist_ok=True)
    target = args.out / "target.qcow2"
    if not args.vm_only:
        target.unlink(missing_ok=True)
        subprocess.run([str(nt3.QEMU_IMG), "create", "-q", "-f", "qcow2", str(target), args.size], check=True)
        ok = prepare(args, args.out, target)
        print("[PASS] POSReady target through micro-Linux" if ok else "[FAIL] POSReady target (console.log)", flush=True)
        if not ok:
            return 1
    if args.vm == "host" and not args.finish_only:
        rc = host_vm(args, args.out, target)
        if rc:
            return rc
    if args.finish or args.finish_only:
        saved = list(args.env)
        args.env = saved + ["POSR_STAGE=finish"]
        ok = prepare(args, args.out, target)
        args.env = saved
        print(f"finish + CSMWrap ESP {'PASS' if ok else 'FAIL'}", flush=True)
        if not ok:
            return 1
    if args.boot:
        nt3.boot(args.out, target, args.boot_seconds)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
