#!/usr/bin/env python3
"""Measure USOS UEFI StartImage -> first Linux framebuffer frame in QEMU.

Uses only a temporary qcow2 overlay backed by the prepared E2E base. No
physical disks are attached. Enter is sent periodically to follow the default
Windows 11 / ISO / Automatic path until the micro-Linux handoff begins.
"""

from __future__ import annotations

import argparse
import re
import shutil
import socket
import subprocess
import tempfile
import time
from pathlib import Path


START_MARKER = b"MICRO-LINUX STARTIMAGE BEGIN"
FIRST_FRAME_MARKER = b"[USOS-FB-UI] FIRST_FRAME"
USERSPACE_MARKER = b"micro-Linux userspace before framebuffer init"


def require_file(path: Path) -> Path:
    if not path.is_file():
        raise FileNotFoundError(path)
    return path


def free_tcp_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def connect_monitor(port: int, deadline: float) -> socket.socket:
    last_error: OSError | None = None
    while time.perf_counter() < deadline:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(0.25)
        try:
            sock.connect(("127.0.0.1", port))
            try:
                sock.recv(4096)
            except socket.timeout:
                pass
            return sock
        except OSError as exc:
            last_error = exc
            sock.close()
            time.sleep(0.05)
    raise RuntimeError(f"QEMU monitor did not open: {last_error}")


def launch(
    qemu: Path,
    firmware_code: Path,
    firmware_vars: Path,
    overlay: Path,
    serial_log: Path,
    stderr_log: Path,
    monitor_port: int,
    accelerator: str,
) -> subprocess.Popen[bytes]:
    if accelerator == "whpx":
        accel_args = ["-accel", "whpx", "-cpu", "qemu64,-xsave"]
    else:
        accel_args = ["-accel", "tcg,thread=multi", "-cpu", "max"]

    command = [
        str(qemu),
        "-name", "USOS-fb-handoff-benchmark",
        "-machine", "q35",
        *accel_args,
        "-m", "2048",
        "-smp", "4",
        "-nic", "none",
        "-rtc", "base=localtime",
        "-display", "none",
        "-vga", "std",
        "-boot", "menu=off,strict=on",
        "-monitor", f"tcp:127.0.0.1:{monitor_port},server=on,wait=off",
        "-serial", f"file:{serial_log.as_posix()}",
        "-drive", f"if=pflash,format=raw,readonly=on,file={firmware_code.as_posix()}",
        "-drive", f"if=pflash,format=raw,file={firmware_vars.as_posix()}",
        "-drive", f"if=none,id=usos,file={overlay.as_posix()},format=qcow2,cache=writeback",
        "-device", "ide-hd,bus=ide.0,drive=usos,bootindex=1,serial=USOS-FB-BENCH",
        "-device", "qemu-xhci,id=input-xhci",
        "-device", "usb-kbd,bus=input-xhci.0",
        "-no-reboot",
    ]
    stderr = stderr_log.open("wb")
    try:
        process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=stderr)
    finally:
        stderr.close()
    return process


def measure_once(root: Path, base: Path, accelerator: str, timeout: float) -> dict[str, float | str]:
    qemu = require_file(root / "tools/qemu/qemu-system-x86_64.exe")
    qemu_img = require_file(root / "tools/qemu/qemu-img.exe")
    firmware_code = require_file(root / "tools/qemu/share/edk2-x86_64-code.fd")
    firmware_vars_source = require_file(root / "tools/qemu/share/edk2-i386-vars.fd")
    base = require_file(base)

    with tempfile.TemporaryDirectory(prefix="usos-fb-handoff-") as temp_name:
        temp = Path(temp_name)
        overlay = temp / "benchmark.qcow2"
        firmware_vars = temp / "edk2-vars.fd"
        serial_log = temp / "serial.log"
        stderr_log = temp / "qemu.stderr.log"
        shutil.copyfile(firmware_vars_source, firmware_vars)
        subprocess.run(
            [
                str(qemu_img), "create", "-f", "qcow2", "-F", "qcow2",
                "-b", str(base), str(overlay),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
        )

        monitor_port = free_tcp_port()
        process = launch(
            qemu,
            firmware_code,
            firmware_vars,
            overlay,
            serial_log,
            stderr_log,
            monitor_port,
            accelerator,
        )
        run_start = time.perf_counter()
        monitor: socket.socket | None = None
        try:
            monitor = connect_monitor(monitor_port, run_start + 5.0)
            monitor.settimeout(0.25)
            next_enter = run_start + 1.5
            enter_interval = 0.45
            start_time: float | None = None
            userspace_time: float | None = None
            first_frame_time: float | None = None
            serial_offset = 0
            carry = b""
            deadline = run_start + timeout

            while time.perf_counter() < deadline:
                now = time.perf_counter()
                if process.poll() is not None:
                    break

                if start_time is None and now >= next_enter:
                    try:
                        monitor.sendall(b"sendkey ret\n")
                    except OSError:
                        pass
                    next_enter = now + enter_interval

                if serial_log.exists():
                    with serial_log.open("rb") as stream:
                        stream.seek(serial_offset)
                        chunk = stream.read()
                        serial_offset = stream.tell()
                    if chunk:
                        observed = carry + chunk
                        event_time = time.perf_counter()
                        if start_time is None and START_MARKER in observed:
                            start_time = event_time
                        if userspace_time is None and USERSPACE_MARKER in observed:
                            userspace_time = event_time
                        if first_frame_time is None and FIRST_FRAME_MARKER in observed:
                            first_frame_time = event_time
                            break
                        carry = observed[-256:]
                time.sleep(0.005)

            if start_time is None or first_frame_time is None:
                serial = serial_log.read_text(encoding="utf-8", errors="replace") if serial_log.exists() else ""
                stderr = stderr_log.read_text(encoding="utf-8", errors="replace") if stderr_log.exists() else ""
                raise RuntimeError(
                    "handoff markers were not observed\n"
                    f"accelerator={accelerator}\nserial tail:\n{serial[-5000:]}\n"
                    f"qemu stderr:\n{stderr[-2000:]}"
                )

            serial_bytes = serial_log.read_bytes() if serial_log.exists() else b""
            pre_fb_match = re.search(
                rb"\[USOS-PERF\] uptime=([0-9.]+)s micro-Linux userspace before framebuffer init",
                serial_bytes,
            )
            first_fb_match = re.search(
                rb"\[USOS-FB-UI\] FIRST_FRAME uptime=([0-9.]+)s",
                serial_bytes,
            )

            result: dict[str, float | str] = {
                "accelerator": accelerator,
                "start_to_first_frame_ms": (first_frame_time - start_time) * 1000.0,
            }
            if userspace_time is not None:
                result["start_to_userspace_ms"] = (userspace_time - start_time) * 1000.0
            if pre_fb_match is not None:
                result["kernel_to_pre_fb_ms"] = float(pre_fb_match.group(1)) * 1000.0
            if first_fb_match is not None:
                kernel_to_first = float(first_fb_match.group(1)) * 1000.0
                result["kernel_to_first_frame_ms"] = kernel_to_first
                if pre_fb_match is not None:
                    result["simpledrm_to_first_frame_ms"] = kernel_to_first - float(pre_fb_match.group(1)) * 1000.0
                result["pre_kernel_loader_ms"] = max(0.0, float(result["start_to_first_frame_ms"]) - kernel_to_first)
            return result
        finally:
            if monitor is not None:
                try:
                    monitor.sendall(b"quit\n")
                except OSError:
                    pass
                monitor.close()
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)


def whpx_available(root: Path) -> bool:
    qemu = require_file(root / "tools/qemu/qemu-system-x86_64.exe")
    with tempfile.TemporaryDirectory(prefix="usos-whpx-probe-") as temp_name:
        stderr_log = Path(temp_name) / "stderr.log"
        with stderr_log.open("wb") as stderr:
            process = subprocess.Popen(
                [
                    str(qemu), "-machine", "q35", "-accel", "whpx",
                    "-cpu", "qemu64,-xsave", "-m", "64M", "-nodefaults",
                    "-display", "none", "-monitor", "none", "-serial", "none", "-S",
                ],
                stdout=subprocess.DEVNULL,
                stderr=stderr,
            )
        time.sleep(0.8)
        alive = process.poll() is None
        if alive:
            process.kill()
        process.wait(timeout=5)
        return alive


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=Path, default=Path(__file__).resolve().parents[3])
    parser.add_argument("--accelerator", choices=("auto", "whpx", "tcg"), default="auto")
    parser.add_argument("--base", type=Path, default=None)
    parser.add_argument("--timeout", type=float, default=35.0)
    args = parser.parse_args()

    root = args.project_root.resolve()
    base = args.base.resolve() if args.base is not None else root / "tools/tests/artifacts/qemu/usos-e2e-base.qcow2"
    accelerator = args.accelerator
    if accelerator == "auto":
        accelerator = "whpx" if whpx_available(root) else "tcg"

    result = measure_once(root, base, accelerator, args.timeout)
    print(f"[USOS-FB-HANDOFF] accelerator={result['accelerator']}")
    print(f"[USOS-FB-HANDOFF] StartImage->first-frame={result['start_to_first_frame_ms']:.1f} ms")
    if "start_to_userspace_ms" in result:
        print(f"[USOS-FB-HANDOFF] StartImage->pre-fb-userspace={result['start_to_userspace_ms']:.1f} ms (host-observed)")
    if "kernel_to_pre_fb_ms" in result:
        print(f"[USOS-FB-HANDOFF] kernel-uptime-at-pre-fb={result['kernel_to_pre_fb_ms']:.1f} ms")
    if "kernel_to_first_frame_ms" in result:
        print(f"[USOS-FB-HANDOFF] kernel-uptime-at-first-frame={result['kernel_to_first_frame_ms']:.1f} ms")
    if "simpledrm_to_first_frame_ms" in result:
        print(f"[USOS-FB-HANDOFF] pre-fb-userspace->first-frame={result['simpledrm_to_first_frame_ms']:.1f} ms")
    if "pre_kernel_loader_ms" in result:
        print(f"[USOS-FB-HANDOFF] StartImage->kernel-clock-start~={result['pre_kernel_loader_ms']:.1f} ms")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
