#!/usr/bin/env python3
"""Boot the pinned USOS micro-Linux through OVMF and report Linux fb0 state.

This is a non-destructive runtime probe. It creates a temporary vvfat ESP and a
probe-only initramfs overlay in the host temp directory; project artifacts and
physical disks are never attached to QEMU.
"""

from __future__ import annotations

import argparse
import gzip
import io
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import time


def pad4(stream: io.BytesIO) -> None:
    missing = (-stream.tell()) % 4
    if missing:
        stream.write(b"\0" * missing)


def single_file_cpio(name: str, payload: bytes, mode: int = 0o755) -> bytes:
    stream = io.BytesIO()

    def add(entry_name: str, data: bytes, entry_mode: int, inode: int) -> None:
        encoded_name = entry_name.encode("utf-8") + b"\0"
        fields = (
            inode,
            stat.S_IFREG | entry_mode,
            0,
            0,
            1,
            0,
            len(data),
            0,
            0,
            0,
            0,
            len(encoded_name),
            0,
        )
        stream.write(b"070701" + b"".join(f"{value:08x}".encode("ascii") for value in fields))
        stream.write(encoded_name)
        pad4(stream)
        stream.write(data)
        pad4(stream)

    add(name.strip("/"), payload, mode, 1)
    trailer = b"TRAILER!!!\0"
    fields = (2, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, len(trailer), 0)
    stream.write(b"070701" + b"".join(f"{value:08x}".encode("ascii") for value in fields))
    stream.write(trailer)
    pad4(stream)
    return stream.getvalue()


PROBE_INIT = br'''#!/bin/sh
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
/bin/busybox --install -s
mkdir -p /proc /sys /dev /run /tmp
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
exec </dev/console >/dev/console 2>&1
printf '[USOS-FB-PROBE] kernel=%s\n' "$(uname -r)"
printf '[USOS-FB-PROBE] simpledrm_load=starting\n'
USOS_UI_TTY=/dev/null
export USOS_UI_TTY
if [ -r /usr/lib/usos/simpledrm.modules ]; then
    printf '[USOS-FB-PROBE] simpledrm_module_count=%s\n' "$(wc -l < /usr/lib/usos/simpledrm.modules)"
fi
if [ -r /usr/lib/usos/micro_linux_ui.sh ]; then
    . /usr/lib/usos/micro_linux_ui.sh
    if usos_ui_init; then
        printf '[USOS-FB-PROBE] simpledrm_load=ok\n'
    else
        printf '[USOS-FB-PROBE] simpledrm_load=failed\n'
    fi
else
    printf '[USOS-FB-PROBE] simpledrm_load=failed\n'
fi
for script in /usr/lib/usos/micro_linux_ui.sh /usr/lib/usos/extract.sh /usr/lib/usos/prepare_work.sh /usr/lib/usos/prepare_wimboot.sh /usr/lib/usos/prepare_vhdboot.sh /usos-init; do
    if /bin/sh -n "$script"; then
        printf '[USOS-FB-PROBE] shell_syntax=%s:ok\n' "$script"
    else
        printf '[USOS-FB-PROBE] shell_syntax=%s:failed\n' "$script"
    fi
done
sleep 1
if [ -e /sys/class/graphics/fb0 ]; then
    printf '[USOS-FB-PROBE] sysfs_fb0=present\n'
else
    printf '[USOS-FB-PROBE] sysfs_fb0=missing\n'
fi
if [ -e /dev/fb0 ]; then
    printf '[USOS-FB-PROBE] dev_fb0=present\n'
else
    printf '[USOS-FB-PROBE] dev_fb0=missing\n'
fi
for item in name virtual_size stride bits_per_pixel; do
    path="/sys/class/graphics/fb0/$item"
    if [ -r "$path" ]; then
        printf '[USOS-FB-PROBE] %s=%s\n' "$item" "$(cat "$path")"
    fi
done
if [ -e /dev/fb0 ] && [ "${USOS_FB_ACTIVE:-no}" = yes ]; then
    usos_ui_progress 4 5 42 420000000 1000000000 125000000 'Framebuffer runtime probe' 'Rendering through the production framebuffer UI path.' 'probe.iso'
    printf '[USOS-FB-PROBE] windows_units=%s\n' "$(usos_ui_format_bytes 1610612736)"
    usos_ui_stage 5 5 'Verifying file count' '20 of 40 files'
    sleep 0.6 &
    activity_pid=$!
    if usos_ui_wait_activity "$activity_pid" 'Flushing to disk' 'Runtime activity probe'; then
        printf '[USOS-FB-PROBE] activity=ok\n'
    else
        printf '[USOS-FB-PROBE] activity=failed\n'
    fi
    usos_ui_done 'PREPARATION COMPLETE - RESTARTING' 'Runtime completion screen probe.'
    if [ "${USOS_FB_ACTIVE:-no}" = yes ]; then
        printf '[USOS-FB-PROBE] renderer=ok\n'
    else
        printf '[USOS-FB-PROBE] renderer=failed\n'
    fi
else
    printf '[USOS-FB-PROBE] renderer=skipped\n'
fi
printf '[USOS-FB-PROBE] relevant_dmesg_begin\n'
dmesg 2>/dev/null | grep -Ei 'efifb|simpledrm|simple-framebuffer|framebuffer|fb0|sysfb' || true
printf '[USOS-FB-PROBE] relevant_dmesg_end\n'
printf '[USOS-FB-PROBE] DONE\n'
poweroff -f 2>/dev/null || halt -f 2>/dev/null || sleep 30
'''


def require_file(path: Path) -> Path:
    if not path.is_file():
        raise FileNotFoundError(path)
    return path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=Path, default=Path(__file__).resolve().parents[3])
    parser.add_argument("--timeout", type=float, default=12.0)
    args = parser.parse_args()

    root = args.project_root.resolve()
    qemu = require_file(root / "tools/qemu/qemu-system-x86_64.exe")
    firmware_code = require_file(root / "tools/qemu/share/edk2-x86_64-code.fd")
    firmware_vars_source = require_file(root / "tools/qemu/share/edk2-i386-vars.fd")
    micro = root / "zig-out/micro-linux"
    kernel = require_file(micro / "vmlinuz-virt")
    initramfs = require_file(micro / "initramfs-usos")
    loader = require_file(micro / "systemd-bootx64.efi")

    with tempfile.TemporaryDirectory(prefix="usos-fb-probe-") as temp_name:
        temp = Path(temp_name)
        esp = temp / "esp"
        (esp / "EFI/BOOT").mkdir(parents=True)
        (esp / "EFI/USOS/micro-linux").mkdir(parents=True)
        (esp / "loader/entries").mkdir(parents=True)

        shutil.copyfile(loader, esp / "EFI/BOOT/BOOTX64.EFI")
        shutil.copyfile(kernel, esp / "EFI/USOS/micro-linux/vmlinuz-virt")

        base_cpio = gzip.decompress(initramfs.read_bytes())
        probe_cpio = single_file_cpio("usos-fb-probe", PROBE_INIT)
        probe_initramfs = gzip.compress(base_cpio + probe_cpio, compresslevel=9, mtime=0)
        (esp / "EFI/USOS/micro-linux/initramfs-probe").write_bytes(probe_initramfs)

        (esp / "loader/loader.conf").write_text("default usos-fb-probe.conf\ntimeout 0\neditor no\n", encoding="ascii")
        (esp / "loader/entries/usos-fb-probe.conf").write_text(
            "title USOS framebuffer runtime probe\n"
            "linux /EFI/USOS/micro-linux/vmlinuz-virt\n"
            "initrd /EFI/USOS/micro-linux/initramfs-probe\n"
            "options console=ttyS0,115200 quiet loglevel=3 vt.global_cursor_default=0 rdinit=/usos-fb-probe\n",
            encoding="ascii",
        )

        firmware_vars = temp / "edk2-vars.fd"
        shutil.copyfile(firmware_vars_source, firmware_vars)
        serial_log = temp / "serial.log"
        qemu_err = temp / "qemu.stderr.log"
        fat_path = esp.resolve().as_posix()

        command = [
            str(qemu),
            "-name", "USOS-framebuffer-runtime-probe",
            "-machine", "q35",
            "-accel", "tcg,thread=multi",
            "-cpu", "max",
            "-m", "512",
            "-smp", "2",
            "-nic", "none",
            "-display", "none",
            "-vga", "std",
            "-monitor", "none",
            "-serial", f"file:{serial_log.as_posix()}",
            "-drive", f"if=pflash,format=raw,readonly=on,file={firmware_code.as_posix()}",
            "-drive", f"if=pflash,format=raw,file={firmware_vars.as_posix()}",
            "-drive", f"if=none,id=esp,format=raw,file=fat:rw:{fat_path}",
            "-device", "ide-hd,bus=ide.0,drive=esp,bootindex=1,serial=USOS-FB-PROBE",
            "-no-reboot",
        ]

        with qemu_err.open("wb") as stderr:
            process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=stderr)
        deadline = time.monotonic() + args.timeout
        while process.poll() is None and time.monotonic() < deadline:
            if serial_log.exists() and "[USOS-FB-PROBE] DONE" in serial_log.read_text(encoding="utf-8", errors="replace"):
                break
            time.sleep(0.1)
        if process.poll() is None:
            process.kill()
        process.wait(timeout=5)

        serial = serial_log.read_text(encoding="utf-8", errors="replace") if serial_log.exists() else ""
        probe_lines = [line.strip() for line in serial.splitlines() if "[USOS-FB-PROBE]" in line]
        for line in probe_lines:
            print(line)

        if not any("DONE" in line for line in probe_lines):
            error_text = qemu_err.read_text(encoding="utf-8", errors="replace") if qemu_err.exists() else ""
            raise RuntimeError(f"framebuffer probe did not complete; QEMU stderr:\n{error_text}\nserial:\n{serial}")

        present = any("dev_fb0=present" in line for line in probe_lines)
        renderer_ok = any("renderer=ok" in line for line in probe_lines)
        activity_ok = any("activity=ok" in line for line in probe_lines)
        windows_units_ok = any("windows_units=1.5 GB" in line for line in probe_lines)
        shell_syntax = [line for line in probe_lines if "shell_syntax=" in line]
        shell_syntax_ok = len(shell_syntax) == 6 and all(line.endswith(":ok") for line in shell_syntax)
        resolution = next((line.split("virtual_size=", 1)[1] for line in probe_lines if "virtual_size=" in line), "")
        try:
            width_text, height_text = resolution.split(",", 1)
            resolution_ok = int(width_text) > 0 and int(height_text) > 0
        except (ValueError, TypeError):
            resolution_ok = False
        print(
            f"[RESULT] /dev/fb0 {'present' if present else 'missing'} "
            f"resolution={resolution or 'unknown'} renderer={'ok' if renderer_ok else 'failed'} "
            f"activity={'ok' if activity_ok else 'failed'} windows_units={'ok' if windows_units_ok else 'failed'} "
            f"shell_syntax={'ok' if shell_syntax_ok else 'failed'}"
        )
        return 0 if present and resolution_ok and renderer_ok and activity_ok and windows_units_ok and shell_syntax_ok else 2


if __name__ == "__main__":
    raise SystemExit(main())
