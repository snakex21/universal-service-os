#!/usr/bin/env python3
"""Exercise the micro-Linux framebuffer menu (usos-fb-ui --menu) in QEMU.

Boots zig-out/micro-linux/vmlinuz-virt + initramfs-usos directly through
OVMF (EFI stub, GOP framebuffer) into the read-only Hardware & SMART
session (usos.legacy_action=hardware), which needs no disk. Wheel, drag and
tap events go in through QMP; the menu prints "[FB_MENU] action=..." on the
serial console. Screenshots go to --out.

    python tools/boot_input_linux_qemu.py --out artifacts/boot-input [--devices tablet,mouse,ps2]
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import time
from pathlib import Path

from boot_ui_screens import OVMF_CODE, OVMF_VARS, QEMU, ROOT, WORK, Monitor, free_port, wait_serial
from boot_input_qemu import Qmp, point

KERNEL = ROOT / "zig-out" / "micro-linux" / "vmlinuz-virt"
INITRD = ROOT / "zig-out" / "micro-linux" / "initramfs-usos"


def actions(log: Path) -> list[str]:
    text = log.read_text(errors="replace") if log.exists() else ""
    return re.findall(r"\[FB_MENU\] (action=\S+ selected=\d+ scroll=\d+)", text)


def ready_count(log: Path) -> int:
    text = log.read_text(errors="replace") if log.exists() else ""
    return text.count("[XP_MENU] READY")


def wait_ready(log: Path, count: int, timeout: float) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if ready_count(log) >= count:
            time.sleep(1.5)
            return
        time.sleep(0.5)
    raise RuntimeError(f"menu READY #{count} not seen; see {log}")


def run(device: str, out: Path, width: int, height: int) -> dict:
    WORK.mkdir(parents=True, exist_ok=True)
    serial = WORK / f"serial-linux-input-{device}.log"
    if serial.exists():
        serial.unlink()
    port, qmp_port = free_port(), free_port()
    vars_copy = WORK / f"vars-linux-input-{device}.fd"
    shutil.copyfile(OVMF_VARS, vars_copy)
    append = "rdinit=/usos-init usos.legacy_action=hardware console=tty0 console=ttyS0,115200n8 quiet loglevel=3 vt.global_cursor_default=0"
    args = [
        str(QEMU), "-name", f"USOS-linux-input-{device}", "-machine", "q35", "-accel", "tcg,thread=multi",
        "-cpu", "max", "-m", "2048", "-smp", "2", "-nic", "none",
        "-display", "none", "-device", f"VGA,edid=on,xres={width},yres={height}",
        "-monitor", f"tcp:127.0.0.1:{port},server=on,wait=off",
        "-qmp", f"tcp:127.0.0.1:{qmp_port},server=on,wait=off",
        "-serial", f"file:{serial.as_posix()}",
        "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE.as_posix()}",
        "-drive", f"if=pflash,format=raw,file={vars_copy.as_posix()}",
        "-kernel", str(KERNEL), "-initrd", str(INITRD), "-append", append,
        "-no-shutdown",
    ]
    if device == "tablet":
        args += ["-device", "qemu-xhci,id=xhci", "-device", "usb-tablet,id=tablet0,bus=xhci.0"]
    elif device == "mouse":
        args += ["-device", "qemu-xhci,id=xhci", "-device", "usb-mouse,id=mouse0,bus=xhci.0"]
    stderr = open(WORK / f"qemu-linux-input-{device}.stderr.log", "wb")
    process = subprocess.Popen(args, stderr=stderr)
    prefix = out / f"linux-{device}"
    result: dict = {"device": device}
    try:
        monitor = Monitor(port)
        qmp = Qmp(qmp_port)
        wait_ready(serial, 1, 300)
        # USB HID enumerates after the menu starts; it rescans every 250 ms.
        time.sleep(4)
        monitor.shot(Path(f"{prefix}-01-main.png"))
        qmp.click("wheel-down", None)
        time.sleep(1.5)
        qmp.click("wheel-up", None)
        time.sleep(1.5)
        result["wheel_main"] = actions(serial)
        monitor.key("ret", 1)
        wait_ready(serial, 2, 60)
        monitor.shot(Path(f"{prefix}-02-details.png"))
        mark = len(actions(serial))
        for _ in range(3):
            qmp.click("wheel-down", None)
            time.sleep(1.0)
        time.sleep(1)
        monitor.shot(Path(f"{prefix}-03-wheel.png"))
        result["wheel_details"] = actions(serial)[mark:]
        mark = len(actions(serial))
        # Drag the finger down over the details: the text follows it, so the
        # view scrolls back up (scroll decreases from the wheel's 3).
        if device == "tablet":
            x, y = width // 2, int(height * 0.4)
            point(qmp, device, width, height, x, y)
            qmp.button("left", None, True)
            for _ in range(10):
                y += 20
                qmp.absolute(x * 32767 // (width - 1), y * 32767 // (height - 1), None)
            qmp.button("left", None, False)
        else:
            point(qmp, device, width, height, width // 2, int(height * 0.4))
            qmp.button("left", None, True)
            for _ in range(10):
                qmp.relative(0, 20, None)
            qmp.button("left", None, False)
        time.sleep(2)
        monitor.shot(Path(f"{prefix}-04-drag.png"))
        result["drag"] = actions(serial)[mark:]
        # Tap the footer's Esc/B hint: back to the main menu.
        mark = ready_count(serial)
        point(qmp, device, width, height, int(width * 0.195), height - 22)
        qmp.click("left", None)
        try:
            wait_ready(serial, mark + 1, 30)
            result["hint_back"] = True
        except RuntimeError:
            result["hint_back"] = False
        monitor.shot(Path(f"{prefix}-05-hint-back.png"))
        try:
            monitor.command("quit")
        except ConnectionError:
            pass
    finally:
        try:
            process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            process.kill()
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--devices", default="tablet,mouse,ps2")
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--height", type=int, default=800)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    results = [run(device, args.out, args.width, args.height) for device in args.devices.split(",")]
    (args.out / "linux-input-results.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
    for result in results:
        print(f"[LINUX_INPUT] {json.dumps(result)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
