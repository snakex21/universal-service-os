#!/usr/bin/env python3
"""Linux ISO boot through the USOS UEFI menu in QEMU/OVMF (Secure Boot off).

The test VHD (new_linux_test_disk.ps1, ESP refreshed by
update_linux_test_esp.ps1) is attached as a USB disk with snapshot=on. A key
script drives the menu; "shot" saves a screenshot, "wait:N" sleeps.

    python tools/tests/linux_iso/run_linux_iso_menu.py --name ubuntu-menu \
        --script "wait:20,shot,down,ret,wait:2,shot" [--seconds 120]
"""
from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT / "tools"))
from boot_ui_screens import QEMU, OVMF_CODE, OVMF_VARS, Monitor, free_port  # noqa: E402

VHD = ROOT / "tools" / "tests" / "artifacts" / "linux-iso" / "usos-linux-test.vhd"
OUT = ROOT / "tools" / "tests" / "artifacts" / "linux-iso" / "menu"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", required=True)
    parser.add_argument("--script", required=True)
    parser.add_argument("--seconds", type=int, default=0, help="extra time with a shot every 30 s after the script")
    parser.add_argument("--tcg", action="store_true")
    parser.add_argument("--bios", action="store_true", help="SeaBIOS (Legacy BIOS Core menu) instead of OVMF")
    parser.add_argument("--secure-boot", action="store_true",
                        help="Fedora SMM OVMF with the Microsoft keys, Secure Boot on, MokList = USOS certificate (ESP must be the signed zig-out/usb layout)")
    args = parser.parse_args()
    work = OUT / args.name
    work.mkdir(parents=True, exist_ok=True)
    for old in work.glob("*.png"):
        old.unlink()
    vars_copy = work / "vars.fd"
    code = OVMF_CODE
    machine = "q35"
    if args.secure_boot:
        sys.path.insert(0, str(ROOT / "tools" / "tests" / "secure_boot"))
        import run_qemu_secure_boot as sb  # noqa: E402
        der = (ROOT / "assets" / "secure-boot" / "usos-secure-boot.cer").read_bytes()
        seeded = sb.seeded_vars(f"linux-{args.name}", [{"name": "MokList", "guid": sb.SHIM_GUID, "attr": 3, "data": sb.x509_list(der).hex()}])
        vars_copy.write_bytes(seeded.read_bytes())
        code = sb.CACHE / "OVMF_CODE.secboot.fd"
        machine = "q35,smm=on"
    else:
        vars_copy.write_bytes(OVMF_VARS.read_bytes())
    port = free_port()
    serial = work / "serial.log"
    cmd = [str(QEMU), "-machine", machine, "-m", "4096", "-smp", "2",
           *(["-global", "driver=cfi.pflash01,property=secure,value=on"] if args.secure_boot else []),
           "-accel", "tcg" if args.tcg else "whpx", "-accel", "tcg",
           "-display", "none", "-vga", "std", "-serial", f"file:{serial}",
           "-monitor", f"tcp:127.0.0.1:{port},server,nowait",
           *([] if args.bios else ["-drive", f"if=pflash,format=raw,readonly=on,file={code}",
                                   "-drive", f"if=pflash,format=raw,file={vars_copy}"]),
           "-drive", f"file={VHD},if=none,id=usos,format=raw,snapshot=on",
           "-device", "qemu-xhci,id=xhci", "-device", "usb-storage,bus=xhci.0,drive=usos,bootindex=1",
           # The BIOS Core reads the PS/2 controller: no USB keyboard there.
           *([] if args.bios else ["-device", "usb-kbd,bus=xhci.0"]), "-device", "usb-tablet,bus=xhci.0",
           "-netdev", "user,id=n0", "-device", "e1000,netdev=n0"]
    proc = subprocess.Popen(cmd)
    monitor = Monitor(port)
    shots = 0
    try:
        for step in [s for s in args.script.split(",") if s]:
            if step.startswith("wait:"):
                time.sleep(float(step[5:]))
            elif step == "shot":
                shots += 1
                monitor.shot(work / f"{shots:02d}.png")
            else:
                monitor.key(step, 0.6)
        end = time.time() + args.seconds
        while time.time() < end and proc.poll() is None:
            time.sleep(30)
            shots += 1
            monitor.shot(work / f"{shots:02d}.png")
    finally:
        try:
            monitor.command("quit")
        except OSError:
            pass
        proc.wait(timeout=30)
    log = serial.read_text(errors="replace") if serial.exists() else ""
    for line in log.splitlines():
        if "LINUX-ISO" in line or "usos-init" in line or "USOS:" in line:
            print("   ", line.strip()[:200])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
