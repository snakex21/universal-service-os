#!/usr/bin/env python3
"""Drive QEMU through the USOS boot menu and save PNG screenshots.

Called by tools/render_boot_ui_screenshots.ps1 with a prepared test disk.
The disk is attached with -snapshot, so QEMU never writes to it.
"""
from __future__ import annotations

import argparse
import shutil
import socket
import subprocess
import time
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
QEMU = ROOT / "tools" / "qemu" / "qemu-system-x86_64.exe"
OVMF_CODE = ROOT / "tools" / "qemu" / "share" / "edk2-x86_64-code.fd"
OVMF_VARS = ROOT / "tools" / "qemu" / "share" / "edk2-i386-vars.fd"
WORK = ROOT / "tools" / "tests" / "artifacts" / "qemu" / "boot-ui"


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class Monitor:
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
        self.read()

    def read(self) -> str:
        self.sock.settimeout(0.5)
        data = b""
        try:
            while True:
                chunk = self.sock.recv(65536)
                if not chunk:
                    break
                data += chunk
        except socket.timeout:
            pass
        return data.decode(errors="replace")

    def command(self, text: str) -> str:
        self.sock.sendall((text + "\n").encode())
        time.sleep(0.2)
        return self.read()

    def key(self, name: str, pause: float) -> None:
        self.command(f"sendkey {name}")
        time.sleep(pause)

    def shot(self, path: Path) -> None:
        ppm = path.with_suffix(".ppm")
        if ppm.exists():
            ppm.unlink()
        self.command(f"screendump {ppm.as_posix()}")
        deadline = time.time() + 10
        while not ppm.exists() or ppm.stat().st_size == 0:
            if time.time() > deadline:
                raise RuntimeError(f"screendump did not produce {ppm}")
            time.sleep(0.2)
        time.sleep(0.5)
        Image.open(ppm).save(path)
        ppm.unlink()
        print(f"[SHOT] {path}")


def wait_serial(log: Path, needle: str, timeout: float) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if log.exists() and needle in log.read_text(errors="replace"):
            return
        time.sleep(0.5)
    raise RuntimeError(f"serial log never showed {needle!r}; see {log}")


def run(firmware: str, disk: Path, language: str, out: Path, width: int, height: int) -> None:
    WORK.mkdir(parents=True, exist_ok=True)
    serial = WORK / f"serial-{firmware}-{language}.log"
    if serial.exists():
        serial.unlink()
    port = free_port()
    args = [
        str(QEMU), "-name", f"USOS-boot-ui-{firmware}", "-machine", "q35", "-accel", "tcg,thread=multi",
        "-cpu", "max", "-m", "2048", "-smp", "2", "-nic", "none", "-rtc", "base=localtime",
        "-display", "none", "-device", f"VGA,edid=on,xres={width},yres={height}",
        "-monitor", f"tcp:127.0.0.1:{port},server=on,wait=off",
        "-serial", f"file:{serial.as_posix()}",
        "-drive", f"if=none,id=usos,file={disk.as_posix()},format=vpc,snapshot=on",
        "-device", "ide-hd,bus=ide.0,drive=usos,bootindex=1",
        "-usb", "-device", "usb-tablet", "-no-shutdown",
    ]
    if firmware == "uefi":
        vars_copy = WORK / f"vars-{language}.fd"
        shutil.copyfile(OVMF_VARS, vars_copy)
        args += ["-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE.as_posix()}",
                 "-drive", f"if=pflash,format=raw,file={vars_copy.as_posix()}"]
    stderr = open(WORK / f"qemu-{firmware}-{language}.stderr.log", "wb")
    process = subprocess.Popen(args, stderr=stderr)
    try:
        monitor = Monitor(port)
        prefix = out / (f"{firmware}-{language}" if (width, height) == (1280, 800) else f"{firmware}-{language}-{width}x{height}")
        if firmware == "uefi":
            wait_serial(serial, "USOS MANUAL FLOW BOOT PASS", 240)
            time.sleep(6)
            monitor.shot(Path(f"{prefix}-01-home.png"))
            monitor.key("ret", 4)
            monitor.shot(Path(f"{prefix}-02-systems.png"))
            monitor.key("ret", 4)
            monitor.shot(Path(f"{prefix}-03-images.png"))
            monitor.key("ret", 4)
            monitor.shot(Path(f"{prefix}-04-methods.png"))
            monitor.key("ret", 5)
            monitor.shot(Path(f"{prefix}-05-summary.png"))
            for _ in range(4):
                monitor.key("esc", 2.5)
            monitor.key("esc", 2)
            monitor.key("ret", 4)
            monitor.shot(Path(f"{prefix}-06-power.png"))
        else:
            wait_serial(serial, "[BIOS_UI]", 240)
            time.sleep(12)
            monitor.shot(Path(f"{prefix}-01-home.png"))
            monitor.key("ret", 6)
            monitor.shot(Path(f"{prefix}-02-systems.png"))
            monitor.key("esc", 5)
            monitor.key("esc", 3)
            monitor.key("ret", 5)
            monitor.shot(Path(f"{prefix}-03-power.png"))
        try:
            monitor.command("quit")
        except ConnectionError:
            pass
    finally:
        try:
            process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            process.kill()


def name_gpt_partitions(disk: Path, names: list[str]) -> None:
    """Sets the GPT partition names USOS looks for (Windows cannot) in both
    GPT copies of a fixed VHD (raw disk followed by a 512-byte footer)."""
    import struct
    import zlib
    with open(disk, "r+b") as f:
        size = f.seek(0, 2) - 512
        for header_lba in (1, size // 512 - 1):
            f.seek(header_lba * 512)
            header = bytearray(f.read(512))
            if header[:8] != b"EFI PART":
                raise RuntimeError(f"no GPT header at LBA {header_lba}")
            header_size = struct.unpack_from("<I", header, 12)[0]
            entries_lba, count, entry_size = struct.unpack_from("<QII", header, 72)
            f.seek(entries_lba * 512)
            entries = bytearray(f.read(count * entry_size))
            esp_type = bytes.fromhex("28732ac11ff8d211ba4b00a0c93ec93b")
            data_type = bytes.fromhex("a2a0d0ebe5b9334487c068b6b72699c7")
            data_names = iter(names[1:])
            for index in range(count):
                entry = index * entry_size
                kind = bytes(entries[entry:entry + 16])
                if kind == esp_type:
                    name = names[0]
                elif kind == data_type:
                    name = next(data_names, None)
                else:
                    continue
                if name is None:
                    continue
                encoded = name.encode("utf-16-le")
                entries[entry + 56:entry + 128] = encoded + bytes(72 - len(encoded))
            f.seek(entries_lba * 512)
            f.write(entries)
            struct.pack_into("<I", header, 88, zlib.crc32(entries) & 0xFFFFFFFF)
            struct.pack_into("<I", header, 16, 0)
            struct.pack_into("<I", header, 16, zlib.crc32(bytes(header[:header_size])) & 0xFFFFFFFF)
            f.seek(header_lba * 512)
            f.write(header)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--name-gpt", action="store_true", help="only set the USOS GPT partition names on --disk")
    parser.add_argument("--firmware", choices=["uefi", "bios"])
    parser.add_argument("--disk", type=Path, required=True)
    parser.add_argument("--language")
    parser.add_argument("--out", type=Path)
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--height", type=int, default=800)
    args = parser.parse_args()
    if args.name_gpt:
        name_gpt_partitions(args.disk, ["USOS_ESP", "USOS_DATA", "USOS_WORK"])
        print(f"[PASS] GPT names set on {args.disk}")
        return 0
    args.out.mkdir(parents=True, exist_ok=True)
    run(args.firmware, args.disk, args.language, args.out, args.width, args.height)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
