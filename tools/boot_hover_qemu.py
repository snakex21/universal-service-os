#!/usr/bin/env python3
"""Pointer-over-buttons flicker check for the UEFI and Legacy BIOS menus.

Boots the prepared test disk (-snapshot, never written), parks the PS/2
pointer on the first home card and then on empty background (reference
frame), sweeps it across every card in small steps while sampling the
screen, and returns to the same two places. The final frame must equal the
reference pixel for pixel: stale save-under pixels, half-repainted cards or
a missing pointer would all show up as differences. The sampled frames of
the sweep are kept for inspection.

    python tools/boot_hover_qemu.py --disk <vhd> --out artifacts/boot-ui/hover [--firmware uefi,bios]
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import time
from pathlib import Path

from PIL import Image, ImageChops

from boot_ui_screens import OVMF_CODE, OVMF_VARS, QEMU, WORK, free_port, wait_serial
from boot_input_qemu import Qmp, point

WIDTH, HEIGHT = 1280, 800
CARD = (340, 206)       # centre of the first home card
BLANK = (1200, 650)     # empty background below the cards


def shot(qmp: Qmp, path: Path) -> Image.Image:
    qmp.execute("screendump", filename=str(path), format="png")
    image = Image.open(path)
    image.load()
    return image.convert("RGB")


def run(firmware: str, disk: Path, out: Path) -> dict:
    WORK.mkdir(parents=True, exist_ok=True)
    serial = WORK / f"serial-hover-{firmware}.log"
    if serial.exists():
        serial.unlink()
    qmp_port = free_port()
    args = [
        str(QEMU), "-name", f"USOS-hover-{firmware}", "-machine", "q35", "-accel", "tcg,thread=multi",
        "-cpu", "max", "-m", "2048", "-smp", "2", "-nic", "none", "-rtc", "base=localtime",
        "-display", "none", "-device", f"VGA,edid=on,xres={WIDTH},yres={HEIGHT}",
        "-qmp", f"tcp:127.0.0.1:{qmp_port},server=on,wait=off",
        "-serial", f"file:{serial.as_posix()}",
        "-drive", f"if=none,id=usos,file={disk.as_posix()},format=vpc,snapshot=on",
        "-device", "ide-hd,bus=ide.0,drive=usos,bootindex=1",
        "-no-shutdown",
    ]
    if firmware == "uefi":
        vars_copy = WORK / "vars-hover.fd"
        shutil.copyfile(OVMF_VARS, vars_copy)
        args += ["-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE.as_posix()}",
                 "-drive", f"if=pflash,format=raw,file={vars_copy.as_posix()}"]
    stderr = open(WORK / f"qemu-hover-{firmware}.stderr.log", "wb")
    process = subprocess.Popen(args, stderr=stderr)
    frames = out / f"{firmware}-frames"
    if frames.exists():
        shutil.rmtree(frames)
    frames.mkdir(parents=True)
    result: dict = {"firmware": firmware}
    try:
        qmp = Qmp(qmp_port)
        wait_serial(serial, "first frame presented" if firmware == "uefi" else "VESA-2 MENU ACTIVE", 240)
        time.sleep(8 if firmware == "bios" else 4)
        point(qmp, "ps2", WIDTH, HEIGHT, *CARD)
        point(qmp, "ps2", WIDTH, HEIGHT, *BLANK)
        time.sleep(1.5)
        reference = shot(qmp, out / f"{firmware}-hover-reference.png")
        # Sweep across both card columns and all rows in 20 px steps.
        samples = 0
        for y in (206, 322, 438):
            point(qmp, "ps2", WIDTH, HEIGHT, 60, y)
            for x in range(60, 1220, 20):
                if x > 60:
                    qmp.relative(20, 0, None)
                if x % 100 == 0:
                    shot(qmp, frames / f"{samples:03d}.png")
                    samples += 1
        point(qmp, "ps2", WIDTH, HEIGHT, *CARD)
        point(qmp, "ps2", WIDTH, HEIGHT, *BLANK)
        time.sleep(1.5)
        final = shot(qmp, out / f"{firmware}-hover-final.png")
        difference = ImageChops.difference(reference, final)
        box = difference.getbbox()
        changed = sum(1 for p in difference.getdata() if p != (0, 0, 0))
        # Clock minute may tick over during the run: ignore the header clock.
        header_only = box is not None and box[3] <= 64
        result.update({"samples": samples, "identical": box is None or header_only, "diff_bbox": box, "changed_pixels": changed})
        if box is not None:
            difference.point(lambda v: 255 if v else 0).save(out / f"{firmware}-hover-diff.png")
        try:
            qmp.execute("quit")
        except Exception:
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
    parser.add_argument("--firmware", default="uefi,bios")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    results = [run(f, args.disk, args.out) for f in args.firmware.split(",")]
    (args.out / "hover-results.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
    print(json.dumps(results, indent=2))
    return 0 if all(r.get("identical") for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
