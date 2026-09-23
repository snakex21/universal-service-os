#!/usr/bin/env python3
"""Exercise the USOS UEFI boot menu with pointer input in QEMU.

Called by tools/render_boot_ui_screenshots.ps1 -InputTest with the prepared
test disk (attached with -snapshot, so QEMU never writes to it). For each
pointer device QEMU offers it boots OVMF, opens a list and sends wheel,
drag and tap events through QMP input-send-event, then checks the list
state the menu traces on the serial port ([UI_LIST] first=/selected=) and
saves screenshots. The input-devices report ([INPUT_REPORT ...]) the menu
writes at boot is copied next to the screenshots.

Devices: tablet (usb-tablet: EFI_ABSOLUTE_POINTER_PROTOCOL if the firmware
drives it), mouse (usb-mouse: EFI_SIMPLE_POINTER_PROTOCOL) and ps2 (the
i8042 PS/2 mouse, polled directly with the IntelliMouse wheel enabled).
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import socket
import subprocess
import time
from pathlib import Path

from boot_ui_screens import OVMF_CODE, OVMF_VARS, QEMU, WORK, Monitor, free_port, wait_serial


class Qmp:
    def __init__(self, port: int):
        deadline = time.time() + 20
        while True:
            try:
                self.sock = socket.create_connection(("127.0.0.1", port), timeout=5)
                break
            except OSError:
                if time.time() > deadline:
                    raise
                time.sleep(0.2)
        self.file = self.sock.makefile("rwb")
        json.loads(self.file.readline())
        self.execute("qmp_capabilities")

    def execute(self, command: str, **arguments) -> dict:
        message = {"execute": command}
        if arguments:
            message["arguments"] = arguments
        self.file.write((json.dumps(message) + "\n").encode())
        self.file.flush()
        while True:
            reply = json.loads(self.file.readline())
            if "return" in reply or "error" in reply:
                if "error" in reply:
                    raise RuntimeError(f"QMP {command}: {reply['error']}")
                return reply

    def send(self, events: list[dict], device: str | None) -> None:
        # Naming the target device ("device": "tablet0") crashes QEMU 10 with
        # -display none (qemu-fixed-text-console.device); events go to the
        # active pointer device, which is the only USB pointer attached.
        self.execute("input-send-event", events=events)
        time.sleep(0.15)

    def button(self, name: str, device: str | None, down: bool) -> None:
        self.send([{"type": "btn", "data": {"down": down, "button": name}}], device)

    def click(self, name: str, device: str | None) -> None:
        self.button(name, device, True)
        self.button(name, device, False)

    def absolute(self, x: int, y: int, device: str | None) -> None:
        self.send([
            {"type": "abs", "data": {"axis": "x", "value": x}},
            {"type": "abs", "data": {"axis": "y", "value": y}},
        ], device)

    def relative(self, dx: int, dy: int, device: str | None) -> None:
        self.send([
            {"type": "rel", "data": {"axis": "x", "value": dx}},
            {"type": "rel", "data": {"axis": "y", "value": dy}},
        ], device)


def point(qmp: Qmp, device: str, width: int, height: int, x: int, y: int) -> None:
    """Puts the pointer at screen pixel (x, y)."""
    if device == "tablet":
        qmp.absolute(x * 32767 // (width - 1), y * 32767 // (height - 1), None)
    else:
        # Relative devices: park in the top-left corner, then move exactly.
        for _ in range(6):
            qmp.relative(-500, -500, None)
        qmp.relative(x, y, None)
    time.sleep(0.6)


def list_states(log: Path) -> list[tuple[int, int, int, int]]:
    text = log.read_text(errors="replace") if log.exists() else ""
    return [tuple(int(v) for v in m) for m in re.findall(r"\[UI_LIST\] first=(\d+) selected=(\d+) visible=(\d+) rows=(\d+)", text)]


def report(log: Path) -> str:
    text = log.read_text(errors="replace") if log.exists() else ""
    match = re.search(r"\[INPUT_REPORT BEGIN\]\r?\n(.*?)\[INPUT_REPORT END\]", text, re.S)
    return match.group(1) if match else ""


def run(device: str, disk: Path, out: Path, width: int, height: int) -> dict:
    WORK.mkdir(parents=True, exist_ok=True)
    serial = WORK / f"serial-input-{device}.log"
    if serial.exists():
        serial.unlink()
    port, qmp_port = free_port(), free_port()
    vars_copy = WORK / f"vars-input-{device}.fd"
    shutil.copyfile(OVMF_VARS, vars_copy)
    args = [
        str(QEMU), "-name", f"USOS-input-{device}", "-machine", "q35", "-accel", "tcg,thread=multi",
        "-cpu", "max", "-m", "2048", "-smp", "2", "-nic", "none", "-rtc", "base=localtime",
        "-display", "none", "-device", f"VGA,edid=on,xres={width},yres={height}",
        "-monitor", f"tcp:127.0.0.1:{port},server=on,wait=off",
        "-qmp", f"tcp:127.0.0.1:{qmp_port},server=on,wait=off",
        "-serial", f"file:{serial.as_posix()}",
        "-drive", f"if=none,id=usos,file={disk.as_posix()},format=vpc,snapshot=on",
        "-device", "ide-hd,bus=ide.0,drive=usos,bootindex=1",
        "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE.as_posix()}",
        "-drive", f"if=pflash,format=raw,file={vars_copy.as_posix()}",
        "-no-shutdown",
    ]
    target = None
    if device == "tablet":
        args += ["-device", "qemu-xhci,id=xhci", "-device", "usb-tablet,id=tablet0,bus=xhci.0"]
        target = "tablet0"
    elif device == "mouse":
        args += ["-device", "qemu-xhci,id=xhci", "-device", "usb-mouse,id=mouse0,bus=xhci.0"]
        target = "mouse0"
    stderr = open(WORK / f"qemu-input-{device}.stderr.log", "wb")
    process = subprocess.Popen(args, stderr=stderr)
    prefix = out / f"input-{device}"
    result: dict = {"device": device}
    try:
        monitor = Monitor(port)
        qmp = Qmp(qmp_port)
        wait_serial(serial, "USOS MANUAL FLOW BOOT PASS", 240)
        time.sleep(6)
        (out / f"input-{device}-report.txt").write_text(report(serial), encoding="utf-8")
        monitor.key("ret", 4)
        monitor.shot(Path(f"{prefix}-01-list.png"))
        start = len(list_states(serial))
        for _ in range(3):
            qmp.click("wheel-down", target)
            time.sleep(0.6)
        time.sleep(1.5)
        monitor.shot(Path(f"{prefix}-02-wheel-down.png"))
        after_down = list_states(serial)[start:]
        qmp.click("wheel-up", target)
        time.sleep(2)
        monitor.shot(Path(f"{prefix}-03-wheel-up.png"))
        after_up = list_states(serial)[start + len(after_down):]
        result["wheel_down"] = after_down
        result["wheel_up"] = after_up
        mark = len(list_states(serial))
        if device == "tablet":
            # Drag the list up with the "finger": content follows it.
            x, y = 16383, int(32767 * 0.72)
            qmp.absolute(x, y, target)
            qmp.button("left", target, True)
            for _ in range(12):
                y -= int(32767 * 0.025)
                qmp.absolute(x, y, target)
            qmp.button("left", target, False)
        else:
            qmp.button("left", target, True)
            for _ in range(12):
                qmp.relative(0, -20, target)
            qmp.button("left", target, False)
        time.sleep(2)
        monitor.shot(Path(f"{prefix}-04-drag.png"))
        result["drag"] = list_states(serial)[mark:]
        # A tap/click (no movement) on the second visible row opens it, and a
        # tap on the footer's Esc hint goes back (touch-only navigation).
        mark = len(list_states(serial))
        point(qmp, device, width, height, width // 2, int(height * 0.42))
        qmp.click("left", target)
        time.sleep(4)
        monitor.shot(Path(f"{prefix}-05-tap.png"))
        result["tap"] = list_states(serial)[mark:]
        mark = len(list_states(serial))
        point(qmp, device, width, height, int(width * 0.195), height - 22)
        qmp.click("left", target)
        time.sleep(4)
        monitor.shot(Path(f"{prefix}-06-hint-back.png"))
        result["hint_back"] = list_states(serial)[mark:]
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


def run_bios(disk: Path, out: Path) -> dict:
    """Legacy BIOS (SeaBIOS) with the i8042 PS/2 mouse: the Core enables the
    IntelliMouse wheel and turns notches into arrow keys."""
    WORK.mkdir(parents=True, exist_ok=True)
    serial = WORK / "serial-input-bios.log"
    if serial.exists():
        serial.unlink()
    port, qmp_port = free_port(), free_port()
    args = [
        str(QEMU), "-name", "USOS-input-bios", "-machine", "q35", "-accel", "tcg,thread=multi",
        "-cpu", "max", "-m", "2048", "-smp", "2", "-nic", "none", "-rtc", "base=localtime",
        "-display", "none", "-device", "VGA,edid=on,xres=1280,yres=800",
        "-monitor", f"tcp:127.0.0.1:{port},server=on,wait=off",
        "-qmp", f"tcp:127.0.0.1:{qmp_port},server=on,wait=off",
        "-serial", f"file:{serial.as_posix()}",
        "-drive", f"if=none,id=usos,file={disk.as_posix()},format=vpc,snapshot=on",
        "-device", "ide-hd,bus=ide.0,drive=usos,bootindex=1", "-no-shutdown",
    ]
    stderr = open(WORK / "qemu-input-bios.stderr.log", "wb")
    process = subprocess.Popen(args, stderr=stderr)
    result: dict = {"device": "bios-ps2"}
    try:
        monitor = Monitor(port)
        qmp = Qmp(qmp_port)
        wait_serial(serial, "[BIOS_UI]", 240)
        time.sleep(12)
        monitor.key("ret", 6)
        monitor.shot(out / "input-bios-01-list.png")
        for _ in range(2):
            qmp.click("wheel-down", None)
            time.sleep(1.5)
        time.sleep(2)
        monitor.shot(out / "input-bios-02-wheel-down.png")
        text = serial.read_text(errors="replace")
        result["mouse_line"] = next((line.strip() for line in text.splitlines() if "[BIOS_MOUSE]" in line), "")
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
    parser.add_argument("--disk", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--devices", default="ps2,mouse,tablet,bios")
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--height", type=int, default=800)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    results = [run_bios(args.disk, args.out) if device == "bios" else run(device, args.disk, args.out, args.width, args.height) for device in args.devices.split(",")]
    (args.out / "input-results.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
    for result in results:
        print(f"[INPUT] {result['device']}: bios_mouse={result.get('mouse_line')} wheel_down={result.get('wheel_down')} wheel_up={result.get('wheel_up')} drag={result.get('drag')} tap={result.get('tap')} hint_back={result.get('hint_back')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
