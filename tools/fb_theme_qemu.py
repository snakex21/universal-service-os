#!/usr/bin/env python3
"""The menu theme across the UEFI -> micro-Linux handover, in QEMU/OVMF.

Called by tools/tests/run_fb_theme_qemu.ps1 with a copy of the boot-ui test
disk whose ESP has theme=<name> in usos-settings.ini (a user theme in
EFI/USOS/themes), the production micro-Linux as the XP kernel and
initramfs, and an XP image placeholder on DATA. The disk runs with
-snapshot, next to a blank target disk.

The menu goes Home -> Windows XP -> image -> answer screen (manual) ->
summary -> Start. Screenshots: the UEFI preparation page (step 1/5) right
after [XP_CMDLINE], then the first usos-fb-ui screens (micro-Linux). The
check: the command line carries usos.theme= (not for "default"), and the
dominant colour of both screens is the theme's background (compared as
pixels, so a default-look micro-Linux screen fails).

    python tools/fb_theme_qemu.py --disk X.vhd --theme retro --background 0000aa --out DIR
"""
from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import time
from collections import Counter
from pathlib import Path

from PIL import Image

from boot_ui_screens import OVMF_CODE, OVMF_VARS, QEMU, WORK, Monitor, free_port, wait_serial

WIDTH, HEIGHT = 1280, 800
XP_TITLE = "Windows XP"
DEFAULT_BACKGROUND = (0x08, 0x0D, 0x14)
failures: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    print(("PASS " if condition else "FAIL ") + name + ("" if condition else f"  {detail}"))
    if not condition:
        failures.append(name)


def dominant(path: Path) -> tuple[tuple[int, int, int], float]:
    image = Image.open(path).convert("RGB").resize((WIDTH // 4, HEIGHT // 4), Image.NEAREST)
    counts = Counter(image.getdata())
    colour, count = counts.most_common(1)[0]
    return colour, count / (image.width * image.height)


def near(a: tuple[int, int, int], b: tuple[int, int, int]) -> bool:
    return all(abs(x - y) <= 2 for x, y in zip(a, b))


def screens(chunk: str) -> list[str]:
    return [m.strip() for m in re.findall(r"\[UI_SCREEN\] ([^\r\n]*)", chunk)]


def run(disk: Path, target: Path, theme: str, background: tuple[int, int, int], out: Path) -> None:
    WORK.mkdir(parents=True, exist_ok=True)
    serial_path = WORK / f"serial-fb-theme-{theme}.log"
    if serial_path.exists():
        serial_path.unlink()
    port = free_port()
    vars_copy = WORK / f"vars-fb-theme-{theme}.fd"
    shutil.copyfile(OVMF_VARS, vars_copy)
    args = [
        str(QEMU), "-name", f"USOS-fb-theme-{theme}", "-machine", "q35", "-accel", "tcg,thread=multi",
        "-cpu", "max", "-m", "2048", "-smp", "2", "-nic", "none", "-rtc", "base=localtime",
        "-display", "none", "-device", f"VGA,edid=on,xres={WIDTH},yres={HEIGHT}",
        "-monitor", f"tcp:127.0.0.1:{port},server=on,wait=off",
        "-serial", f"file:{serial_path.as_posix()}",
        "-drive", f"if=none,id=usos,file={disk.as_posix()},format=vpc,snapshot=on",
        "-device", "ide-hd,bus=ide.0,drive=usos,bootindex=1",
        "-drive", f"if=none,id=target,file={target.as_posix()},format=qcow2,snapshot=on",
        "-device", "ide-hd,bus=ide.1,drive=target",
        "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE.as_posix()}",
        "-drive", f"if=pflash,format=raw,file={vars_copy.as_posix()}",
        "-no-shutdown",
    ]
    stderr = open(WORK / f"qemu-fb-theme-{theme}.stderr.log", "wb")
    process = subprocess.Popen(args, stderr=stderr)
    mark = 0

    def text() -> str:
        return serial_path.read_text(encoding="utf-8", errors="replace") if serial_path.exists() else ""

    def key(name: str, expect: str | None = None, timeout: float = 20) -> str:
        nonlocal mark
        mark = len(text())
        monitor.key(name, 0.3)
        if not expect:
            time.sleep(3)
            return text()[mark:]
        deadline = time.time() + timeout
        while time.time() < deadline:
            if re.search(expect, text()[mark:]):
                time.sleep(0.8)
                break
            time.sleep(0.3)
        return text()[mark:]

    try:
        monitor = Monitor(port)
        wait_serial(serial_path, "USOS MANUAL FLOW BOOT PASS", 300)
        time.sleep(6)
        home = out / f"{theme}-00-uefi-home.png"
        monitor.shot(home)
        key("ret", r"\[UI_SCREEN\] list")
        found = False
        for downs in range(0, 12):
            key("home")
            for _ in range(downs):
                monitor.key("down", 0.4)
            seen = screens(key("ret", r"\[UI_SCREEN\] list", 8))
            if seen and seen[-1] == f"list {XP_TITLE}":
                found = True
                break
            key("esc")
        check(f"{theme}: Windows XP image list reached", found)
        if not found:
            return
        key("ret", r"\[UI_ROW\]")          # image -> answer screen
        key("home", r"\[UI_ROW_SELECTED\]", 8)  # manual installation (first row)
        key("ret", r"\[UI_SCREEN\] summary")
        chunk = key("ret", r"\[XP_CMDLINE\]", 40)
        uefi = out / f"{theme}-01-uefi-step1of5.png"
        monitor.shot(uefi)
        line = (re.findall(r"\[XP_CMDLINE\] ([^\r\n]*)", chunk) or [""])[-1]
        check(f"{theme}: XP start command line traced", bool(line), chunk[-300:])
        has_theme = "usos.theme=" in line
        check(f"{theme}: command line {'has' if theme != 'default' else 'lacks'} usos.theme=", has_theme == (theme != "default"), line)
        # micro-Linux: the first usos-fb-ui frames (stage / notice), then
        # the target disk menu, which follows the storage driver binding
        # (usos-fb-ui's own trace does not reach the quiet serial console).
        linux_shots: list[Path] = []
        deadline = time.time() + 300
        index = 0
        bound_at = 0.0
        while time.time() < deadline:
            time.sleep(6)
            index += 1
            path = out / f"{theme}-02-linux-{index:02d}.png"
            monitor.shot(path)
            linux_shots.append(path)
            if not bound_at and "storage PCI bound" in text():
                bound_at = time.time()
            if bound_at and time.time() - bound_at > 25:
                menu = out / f"{theme}-03-linux-disk-menu.png"
                monitor.shot(menu)
                linux_shots.append(menu)
                break
        colour, share = dominant(uefi)
        check(f"{theme}: UEFI step 1/5 background is the theme's", near(colour, background) and share > 0.3, f"{colour} {share:.2f}")
        # Linux frames: keep those that are not the UEFI page (after handover);
        # each must be dominated by the theme background.
        linux_ok = [p for p in linux_shots if near(dominant(p)[0], background)]
        linux_bad = [p for p in linux_shots if not near(dominant(p)[0], background) and (theme == "default" or near(dominant(p)[0], DEFAULT_BACKGROUND))]
        check(f"{theme}: micro-Linux screens use the theme background", bool(linux_ok) and not linux_bad, f"bad={[p.name for p in linux_bad]} {[(p.name, dominant(p)[0]) for p in linux_shots]}")
        check(f"{theme}: micro-Linux reached the target disk step", bool(bound_at) and "STOP:" not in text(), text()[-600:])
        try:
            monitor.command("quit")
        except ConnectionError:
            pass
    finally:
        try:
            process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            process.kill()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--disk", type=Path, required=True)
    parser.add_argument("--target", type=Path, required=True)
    parser.add_argument("--theme", required=True)
    parser.add_argument("--background", required=True, help="rrggbb of the theme background")
    parser.add_argument("--out", type=Path, required=True)
    options = parser.parse_args()
    options.out.mkdir(parents=True, exist_ok=True)
    value = options.background.lstrip("#")
    background = (int(value[0:2], 16), int(value[2:4], 16), int(value[4:6], 16))
    run(options.disk.resolve(), options.target.resolve(), options.theme, background, options.out.resolve())
    print(f"[RESULT] {options.theme}: {'PASS' if not failures else 'FAIL ' + ', '.join(failures)}")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
