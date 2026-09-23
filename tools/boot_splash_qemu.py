#!/usr/bin/env python3
"""Measure the USOS boot splash and loading time in QEMU.

Called by tools/render_boot_ui_screenshots.ps1 -Splash with the prepared test
disk (attached with -snapshot, so QEMU never writes to it). QEMU starts
paused; the serial console is read over a socket and every line gets a host
timestamp relative to the moment the VM is resumed, while the screen is
sampled with screendump as fast as QEMU answers. Each sample is classified
(black, firmware/text, USOS background) so the report shows exactly how long
the screen stayed black, when the splash appeared and when the menu did.

    python tools/boot_splash_qemu.py --firmware uefi --disk <vhd> --out artifacts/boot-ui/splash [--launch]

--launch continues from the menu into Windows 11 -> first image -> Start,
which enters the micro-Linux preparation (UEFI: systemd-boot + EFI stub,
BIOS: the Core's Linux loader), to measure the transition screens too.

Output: <out>/<firmware>-<label>-timeline.json, the serial log with
timestamps, and PNG samples (<firmware>-<label>-NNN-<ms>.png) of every
visually distinct frame.
"""
from __future__ import annotations

import argparse
import json
import shutil
import socket
import subprocess
import threading
import time
from pathlib import Path

from PIL import Image

from boot_ui_screens import OVMF_CODE, OVMF_VARS, QEMU, WORK, free_port
from boot_input_qemu import Qmp

# Theme.background (src/gui/theme.zig) and the header colour.
USOS_BACKGROUND = (0x08, 0x0D, 0x14)
USOS_HEADER = (0x0C, 0x14, 0x1E)
# Kernel options of the installer's systemd-boot entry (without
# usos.esp_partuuid), see installer/internal/winhost/loader_entry.go.
LINUX_OPTIONS = "console=tty0 console=ttyS0,115200 quiet loglevel=3 vt.global_cursor_default=0 rdinit=/usos-init"


class Serial:
    """Reads the guest serial console and timestamps every line."""

    def __init__(self, port: int, t0_ref: list[float]):
        deadline = time.time() + 20
        while True:
            try:
                self.sock = socket.create_connection(("127.0.0.1", port), timeout=5)
                break
            except OSError:
                if time.time() > deadline:
                    raise
                time.sleep(0.1)
        self.lines: list[tuple[float, str]] = []
        self.t0_ref = t0_ref
        self.lock = threading.Lock()
        self.partial = b""
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self) -> None:
        self.sock.settimeout(0.2)
        while True:
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                continue
            except OSError:
                return
            if not chunk:
                return
            now = time.perf_counter()
            self.partial += chunk
            while b"\n" in self.partial:
                line, self.partial = self.partial.split(b"\n", 1)
                text = line.decode(errors="replace").rstrip("\r")
                with self.lock:
                    self.lines.append((now - self.t0_ref[0], text))

    def find(self, needle: str) -> float | None:
        with self.lock:
            for stamp, text in self.lines:
                if needle in text:
                    return stamp
        return None

    def wait(self, needle: str, timeout: float) -> float:
        deadline = time.time() + timeout
        while time.time() < deadline:
            stamp = self.find(needle)
            if stamp is not None:
                return stamp
            time.sleep(0.05)
        raise RuntimeError(f"serial never showed {needle!r}")


def classify(image: Image.Image) -> str:
    small = image.convert("RGB").resize((64, 40))
    pixels = list(small.getdata())
    black = sum(1 for p in pixels if max(p) <= 6)
    usos = sum(1 for p in pixels if all(abs(p[i] - USOS_BACKGROUND[i]) <= 3 for i in range(3)) or all(abs(p[i] - USOS_HEADER[i]) <= 3 for i in range(3)))
    if black >= len(pixels) * 0.97:
        return "black"
    if usos >= len(pixels) * 0.5:
        return "usos"
    if black >= len(pixels) * 0.6:
        return "dark-text"
    return "other"


def signature(image: Image.Image) -> bytes:
    return image.convert("L").resize((320, 200)).tobytes()


def differs(a: bytes, b: bytes) -> bool:
    return sum(abs(x - y) for x, y in zip(a, b)) > 40


def run(firmware: str, disk: Path, out: Path, label: str, width: int, height: int, launch: bool, timeout: float, iops: int = 0, bps: int = 0, keys: list[str] | None = None) -> dict:
    # Optional disk throttling models a slow USB stick (QEMU's disk is far
    # faster than a real pendrive, so the splash is gone before a sample).
    throttle = (f",throttling.iops-total={iops}" if iops else "") + (f",throttling.bps-total={bps}" if bps else "")
    WORK.mkdir(parents=True, exist_ok=True)
    out.mkdir(parents=True, exist_ok=True)
    frames_dir = WORK / f"splash-frames-{firmware}-{label}"
    if frames_dir.exists():
        shutil.rmtree(frames_dir)
    frames_dir.mkdir(parents=True)
    serial_port, qmp_port = free_port(), free_port()
    args = [
        str(QEMU), "-name", f"USOS-splash-{firmware}", "-machine", "q35", "-accel", "tcg,thread=multi",
        "-cpu", "max", "-m", "2048", "-smp", "2", "-nic", "none", "-rtc", "base=localtime",
        "-display", "none", "-device", f"VGA,edid=on,xres={width},yres={height}",
        "-qmp", f"tcp:127.0.0.1:{qmp_port},server=on,wait=off",
        "-chardev", f"socket,id=ser0,host=127.0.0.1,port={serial_port},server=on,wait=off",
        "-serial", "chardev:ser0",
        "-drive", f"if=none,id=usos,file={disk.as_posix()},format=vpc,snapshot=on{throttle}",
        "-device", "ide-hd,bus=ide.0,drive=usos,bootindex=1",
        "-S", "-no-shutdown",
    ]
    if firmware == "uefi":
        vars_copy = WORK / f"vars-splash-{label}.fd"
        shutil.copyfile(OVMF_VARS, vars_copy)
        args += ["-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE.as_posix()}",
                 "-drive", f"if=pflash,format=raw,file={vars_copy.as_posix()}"]
    stderr = open(WORK / f"qemu-splash-{firmware}-{label}.stderr.log", "wb")
    process = subprocess.Popen(args, stderr=stderr)
    t0 = [time.perf_counter()]
    samples: list[dict] = []
    try:
        qmp = Qmp(qmp_port)
        serial = Serial(serial_port, t0)
        t0[0] = time.perf_counter()
        qmp.execute("cont")
        menu_marker = "first frame presented" if firmware == "uefi" else "VESA-2 MENU ACTIVE"
        index = 0
        last_sig: bytes | None = None
        stop_at: float | None = None
        launched = False
        launch_marker_seen_at: float | None = None
        deadline = time.perf_counter() + timeout
        while time.perf_counter() < deadline:
            path = frames_dir / f"{index:04d}.png"
            started = time.perf_counter() - t0[0]
            try:
                qmp.execute("screendump", filename=str(path), format="png")
            except RuntimeError:
                time.sleep(0.05)
                continue
            stamp = (started + time.perf_counter() - t0[0]) / 2
            try:
                image = Image.open(path)
                image.load()
            except Exception:
                continue
            kind = classify(image)
            sig = signature(image)
            distinct = last_sig is None or differs(sig, last_sig)
            last_sig = sig
            samples.append({"index": index, "t": round(stamp, 3), "kind": kind, "distinct": distinct, "file": str(path)})
            index += 1
            now = time.perf_counter() - t0[0]
            menu_at = serial.find(menu_marker)
            if menu_at is not None and not launch and stop_at is None:
                stop_at = now + 1.5
            if launch and menu_at is not None and not launched and now > menu_at + 3.0:
                launched = True
                launch_at = now
                # Default: Windows (first card) -> Windows 11 -> first image ->
                # method -> summary -> Start. The last key starts the handover.
                sequence = keys or ["ret", "ret", "ret", "ret", "ret"]
                for key, pause in [(k, 3.0) for k in sequence[:-1]]:
                    qmp.execute("human-monitor-command", **{"command-line": f"sendkey {key}"})
                    end = time.perf_counter() + pause
                    while time.perf_counter() < end:
                        p = frames_dir / f"{index:04d}.png"
                        s0 = time.perf_counter() - t0[0]
                        qmp.execute("screendump", filename=str(p), format="png")
                        img = Image.open(p)
                        img.load()
                        nav_sig = signature(img)
                        nav_distinct = last_sig is None or differs(nav_sig, last_sig)
                        last_sig = nav_sig
                        samples.append({"index": index, "t": round(s0, 3), "kind": classify(img), "distinct": nav_distinct, "file": str(p), "phase": "menu-navigation"})
                        index += 1
                qmp.execute("human-monitor-command", **{"command-line": f"sendkey {sequence[-1]}"})
                launch_marker_seen_at = time.perf_counter() - t0[0]
                stop_at = launch_marker_seen_at + 40
            if stop_at is not None and now >= stop_at:
                break
            if launch and serial.find("FIRST_FRAME") is not None and stop_at is not None:
                first_frame = serial.find("FIRST_FRAME")
                stop_at = min(stop_at, (first_frame or now) + 3)
        try:
            qmp.execute("quit")
        except Exception:
            pass
    finally:
        try:
            process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            process.kill()

    serial_path = out / f"{firmware}-{label}-serial.log"
    with serial_path.open("w", encoding="utf-8") as handle:
        for stamp, text in serial.lines:
            handle.write(f"{stamp:9.3f}  {text}\n")

    # Keep every visually distinct sample (the animation frames) as PNG.
    kept = []
    for sample in samples:
        if sample.get("distinct"):
            name = f"{firmware}-{label}-{sample['index']:04d}-{int(sample['t'] * 1000):06d}ms-{sample['kind']}.png"
            shutil.copyfile(sample["file"], out / name)
            kept.append(name)

    def first(kind: str, after: float = 0.0) -> float | None:
        for sample in samples:
            if sample["t"] >= after and sample["kind"] == kind:
                return sample["t"]
        return None

    timeline = {
        "firmware": firmware,
        "label": label,
        "resolution": f"{width}x{height}",
        "samples": len(samples),
        "sample_interval_ms": round(1000 * (samples[-1]["t"] - samples[0]["t"]) / max(len(samples) - 1, 1), 1) if samples else None,
        "serial": {
            "efi_entry": serial.find("USOS MANUAL FLOW BOOT PASS") if firmware == "uefi" else None,
            "core_entry": serial.find("USOS LEGACY CORE PM32") if firmware == "bios" else None,
            "vbe_set": serial.find("[BIOS_UI]") if firmware == "bios" else None,
            "menu": serial.find("first frame presented" if firmware == "uefi" else "VESA-2 MENU ACTIVE"),
            "linux_first_frame": serial.find("FIRST_FRAME"),
        },
        "screen": {
            "first_usos_frame": first("usos"),
        },
        "boot_timing": [text for _, text in serial.lines if "[BOOT_TIMING]" in text or "[USOS-PERF]" in text or "[USOS-FB-UI]" in text or "[SPLASH]" in text],
        "timeline": [{k: v for k, v in s.items() if k != "file"} for s in samples],
        "kept": kept,
    }
    (out / f"{firmware}-{label}-timeline.json").write_text(json.dumps(timeline, indent=2), encoding="utf-8")
    print(json.dumps({k: v for k, v in timeline.items() if k not in ("timeline", "kept")}, indent=2))
    return timeline


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--print-linux-options", action="store_true")
    parser.add_argument("--firmware", choices=["uefi", "bios"])
    parser.add_argument("--disk", type=Path)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--label", default="boot")
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--height", type=int, default=800)
    parser.add_argument("--launch", action="store_true")
    parser.add_argument("--timeout", type=float, default=240)
    parser.add_argument("--throttle-iops", type=int, default=0, help="limit disk requests per second (slow USB stick model)")
    parser.add_argument("--throttle-bps", type=int, default=0, help="limit disk bytes per second")
    parser.add_argument("--keys", default="", help="comma-separated QEMU key names for --launch (last one starts the handover)")
    args = parser.parse_args()
    if args.print_linux_options:
        print(LINUX_OPTIONS)
        return 0
    keys = [k for k in args.keys.split(",") if k] or None
    run(args.firmware, args.disk, args.out, args.label, args.width, args.height, args.launch, args.timeout, args.throttle_iops, args.throttle_bps, keys)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
