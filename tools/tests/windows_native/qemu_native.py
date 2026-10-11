#!/usr/bin/env python3
"""QEMU/OVMF driver for the Windows 10/11 native UEFI path (TCG, no WHPX).

    python qemu_native.py start  --stick S.vhd --target T.qcow2 [--no-reboot]
    python qemu_native.py send   "sendkey ret" "sendkey down" ...
    python qemu_native.py shot   NAME            (PNG under the run folder)
    python qemu_native.py wait                   (until QEMU exits; prints the exit)
    python qemu_native.py target --target T.qcow2  (boot the target ALONE, same NVRAM)

The USOS stick is a removable USB disk on xHCI (as on real hardware), the
target an empty NVMe disk. The OVMF variable store is kept per run folder,
so the firmware boot entries written by Windows/bcdboot survive the second
start without the stick. Everything stays under tools/tests/artifacts.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
# USOS_QEMU_EXE: another executable name in tools/qemu (a copy of
# qemu-system-x86_64.exe), so parallel runs that stop QEMU by image name
# leave this run alone.
QEMU = ROOT / "tools" / "qemu" / os.environ.get("USOS_QEMU_EXE", "qemu-system-x86_64.exe")
QEMU_IMG = ROOT / "tools" / "qemu" / "qemu-img.exe"
OVMF_CODE = ROOT / "tools" / "qemu" / "share" / "edk2-x86_64-code.fd"
OVMF_VARS = ROOT / "tools" / "qemu" / "share" / "edk2-i386-vars.fd"
# USOS_NATIVE_RUN: another run folder (e.g. windows-native-vista) so runs do not share NVRAM/state.
RUN = ROOT / "tools" / "tests" / "artifacts" / os.environ.get("USOS_NATIVE_RUN", "windows-native")
# USOS_NATIVE_TARGET_BUS=ahci: a SATA target (Vista has no inbox NVMe driver).
TARGET_BUS = os.environ.get("USOS_NATIVE_TARGET_BUS", "nvme")
STATE = RUN / "qemu-state.json"
# USOS_NATIVE_TARGET_FIRST=1: the target disk boots before the stick (as if the
# user picked the disk's UEFI entry in the firmware boot menu). A blank target
# falls through to the stick; once a CSMWrap path (Vista, 32-bit 8.1/10)
# prepared it, the disk starts while the stick stays connected for the ISO.
TARGET_FIRST = os.environ.get("USOS_NATIVE_TARGET_FIRST") == "1"
# USOS_NATIVE_MACHINE=pc: i440FX. The CSMWrap paths (Vista / Server 2008
# without CSM) need it: on q35 PE10 in BIOS mode under CSMWrap gets no USB
# keyboard (Setup's first page never reacts); the CSMWrap Vista harness
# (tools/tests/legacy_bios/run_csmwrap_vista_prepared.py) uses pc as well.
MACHINE = os.environ.get("USOS_NATIVE_MACHINE", "q35")
# USOS_NATIVE_ACCEL=whpx: Windows Hypervisor Platform (much faster than TCG).
ACCEL = (["-accel", "whpx,kernel-irqchip=off", "-cpu", "qemu64,+ssse3,+sse4.1,+sse4.2,+popcnt"]
         if os.environ.get("USOS_NATIVE_ACCEL") == "whpx" else ["-accel", "tcg,thread=multi", "-cpu", "max"])


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def monitor(commands: list[str]) -> str:
    state = json.loads(STATE.read_text())
    out = []
    with socket.create_connection(("127.0.0.1", state["port"]), timeout=10) as sock:
        sock.settimeout(2)
        try:
            out.append(sock.recv(65536).decode(errors="replace"))
        except OSError:
            pass
        for command in commands:
            sock.sendall((command + "\n").encode())
            time.sleep(0.4 if command.startswith("sendkey") else 1.5)
            try:
                out.append(sock.recv(65536).decode(errors="replace"))
            except OSError:
                pass
    return "".join(out)


def launch(args: list[str], label: str, no_reboot: bool) -> None:
    port = free_port()
    full = [str(QEMU), "-name", f"USOS-native-{label}", "-machine", MACHINE, *ACCEL,
            *(["-m", "4096", "-smp", "2", "-vga", "std"] if MACHINE == "pc" else ["-m", "6144", "-smp", "4", "-device", "VGA,xres=1280,yres=800"]),
            "-nic", "none", "-display", "none",
            "-monitor", f"tcp:127.0.0.1:{port},server=on,wait=off",
            "-serial", f"file:{(RUN / f'serial-{label}.log').as_posix()}",
            "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE.as_posix()}",
            "-drive", f"if=pflash,format=raw,file={(RUN / 'vars.fd').as_posix()}",
            "-device", "qemu-xhci,id=xhci",
            # USOS_NATIVE_PS2_INPUT=1: no USB keyboard/tablet, sendkey goes to
            # the PS/2 keyboard (installed systems without an xHCI driver:
            # Server 2008 R2 / Home Server 2011 first logon).
            *([] if os.environ.get("USOS_NATIVE_PS2_INPUT") == "1" else ["-device", "usb-kbd,bus=xhci.0", "-device", "usb-tablet,bus=xhci.0"]),
            *args]
    if no_reboot:
        full.append("-no-reboot")
    stderr = open(RUN / f"qemu-{label}.stderr.log", "wb")
    process = subprocess.Popen(full, stderr=stderr, stdout=subprocess.DEVNULL, creationflags=getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0))
    STATE.write_text(json.dumps({"pid": process.pid, "port": port, "label": label, "started": time.time()}))
    print(f"[QEMU] {label} pid={process.pid} monitor=127.0.0.1:{port}")


def disk_args(stick: Path | None, target: Path) -> list[str]:
    args = []
    if stick is not None:
        fmt = "vpc" if stick.suffix.lower() == ".vhd" else "qcow2"
        args += ["-drive", f"if=none,id=stick,file={stick.as_posix()},format={fmt}",
                 "-device", "usb-storage,bus=xhci.0,drive=stick,removable=on,serial=USOSSTICK" + (",bootindex=1" if TARGET_FIRST else "")]
    target_fmt = "vpc" if target.suffix.lower() == ".vhd" else "qcow2"
    if TARGET_BUS == "ahci":
        # USOS_NATIVE_DECOY=<qcow2>: a second internal disk on the first SATA
        # port (the guest's disk 0 / sda; the target moves to port 1). The
        # one-disk-question checks pick the target and prove the decoy is
        # never written (compare its contents before and after).
        decoy = os.environ.get("USOS_NATIVE_DECOY")
        port = 1 if decoy else 0
        args += ["-device", "ahci,id=sata"]
        if decoy:
            args += ["-drive", f"if=none,id=decoy,file={Path(decoy).resolve().as_posix()},format=qcow2,cache=writeback",
                     "-device", "ide-hd,bus=sata.0,drive=decoy,serial=USOSDECOY"]
        args += ["-drive", f"if=none,id=target,file={target.as_posix()},format={target_fmt},cache=writeback",
                 "-device", f"ide-hd,bus=sata.{port},drive=target,serial=USOSTARGET" + (",bootindex=0" if TARGET_FIRST else "")]
    else:
        args += ["-drive", f"if=none,id=target,file={target.as_posix()},format=qcow2", "-device", "nvme,drive=target,serial=USOSTARGET"]
    return args


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("start"); p.add_argument("--stick", required=True); p.add_argument("--target", required=True)
    p.add_argument("--no-reboot", action="store_true"); p.add_argument("--fresh-vars", action="store_true"); p.add_argument("--target-size", default="64G")
    p = sub.add_parser("target"); p.add_argument("--target", required=True); p.add_argument("--no-reboot", action="store_true")
    p = sub.add_parser("send"); p.add_argument("commands", nargs="+")
    p = sub.add_parser("shot"); p.add_argument("name")
    p = sub.add_parser("type"); p.add_argument("text"); p.add_argument("--enter", action="store_true")
    sub.add_parser("wait")
    sub.add_parser("kill")
    a = parser.parse_args()
    RUN.mkdir(parents=True, exist_ok=True)
    if a.cmd == "start":
        target = Path(a.target).resolve()
        if not target.exists():
            subprocess.run([str(QEMU_IMG), "create", "-f", "qcow2", str(target), a.target_size], check=True, stdout=subprocess.DEVNULL)
        if a.fresh_vars or not (RUN / "vars.fd").exists():
            shutil.copyfile(OVMF_VARS, RUN / "vars.fd")
        launch(disk_args(Path(a.stick).resolve(), target), "stick", a.no_reboot)
    elif a.cmd == "target":
        launch(disk_args(None, Path(a.target).resolve()), "target", a.no_reboot)
    elif a.cmd == "send":
        print(monitor(a.commands)[-400:])
    elif a.cmd == "type":
        # US keyboard layout names for QEMU sendkey (the guest uses pl-PL
        # programmer layout, identical for these characters).
        special = {" ": "spc", "\\": "backslash", ":": "shift-semicolon", ".": "dot", "-": "minus", "_": "shift-minus",
                   "/": "slash", "*": "shift-8", ">": "shift-dot", "<": "shift-comma", "|": "shift-backslash", "\"": "shift-apostrophe",
                   "=": "equal", "~": "shift-grave_accent", "&": "shift-7", "%": "shift-5", "$": "shift-4", ",": "comma", "'": "apostrophe",
                   "(": "shift-9", ")": "shift-0", "?": "shift-slash", "!": "shift-1", "{": "shift-bracket_left", "}": "shift-bracket_right"}
        keys = []
        for ch in a.text:
            if ch in special:
                keys.append(special[ch])
            elif ch.isupper():
                keys.append("shift-" + ch.lower())
            else:
                keys.append(ch)
        if a.enter:
            keys.append("ret")
        monitor([f"sendkey {k}" for k in keys])
    elif a.cmd == "shot":
        ppm = RUN / "shots" / f"{a.name}.ppm"
        ppm.parent.mkdir(exist_ok=True)
        monitor([f"screendump {ppm.as_posix()}"])
        for _ in range(20):
            if ppm.exists() and ppm.stat().st_size > 0:
                break
            time.sleep(0.5)
        from PIL import Image
        png = ppm.with_suffix(".png")
        Image.open(ppm).save(png)
        ppm.unlink()
        print(png)
    elif a.cmd == "wait":
        state = json.loads(STATE.read_text())
        while True:
            alive = subprocess.run(["tasklist", "/FI", f"PID eq {state['pid']}"], capture_output=True, text=True).stdout
            if str(state["pid"]) not in alive:
                print(f"[QEMU] exited after {int(time.time() - state['started'])} s")
                return 0
            time.sleep(10)
    elif a.cmd == "kill":
        state = json.loads(STATE.read_text())
        subprocess.run(["taskkill", "/F", "/PID", str(state["pid"])], capture_output=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
