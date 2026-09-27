#!/usr/bin/env python3
"""Linux ISO boot without the menu: QEMU -kernel/-initrd with the USOS helper.

Validates the Linux side of docs/design/linux-iso-boot.md per distro: the
kernel and initrd(s) come from the ISO, usos-linux.cpio and a per-boot cpio
(/usos/iso.map with the ISO's disk extents on the test VHD) are appended, and
the test VHD (tools/tests/linux_iso/new_linux_test_disk.ps1) is attached as a
USB disk with snapshot=on. Success = the serial log shows the helper attached
the ISO, then a screenshot of the live desktop / installer is saved for review.

    python tools/tests/linux_iso/run_linux_iso_direct.py gparted [--uefi] [--seconds 240] [--tcg]

Needs zig-out/linux-iso/usos-init (or --init) and the test disk.
"""
from __future__ import annotations

import argparse
import json
import os
import struct
import subprocess
import sys
import time
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT / "tools"))
sys.path.insert(0, str(HERE))
from boot_ui_screens import QEMU, OVMF_CODE, OVMF_VARS, Monitor, free_port  # noqa: E402
from iso9660_rr import Iso  # noqa: E402
import build_linux_iso_helper as packer  # noqa: E402

ASSETS = Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "USOS" / "test-assets" / "linux"
VHD = ROOT / "tools" / "tests" / "artifacts" / "linux-iso" / "usos-linux-test.vhd"
OUT = ROOT / "tools" / "tests" / "artifacts" / "linux-iso"

# name: kernel, initrds, cmdline (what the USOS recipe produces for this ISO)
RECIPES = {
    "ubuntu-server": ("casper/vmlinuz", ["casper/initrd"], "live-media=/dev/usos-iso ---"),
    "ubuntu-desktop": ("casper/vmlinuz", ["casper/initrd"], "live-media=/dev/usos-iso quiet splash ---"),
    "mint": ("casper/vmlinuz", ["casper/initrd.lz"], "boot=casper live-media=/dev/usos-iso username=mint hostname=mint quiet splash --"),
    "debian13-live": ("live/vmlinuz", ["live/initrd.img"], "boot=live components live-media=/dev/usos-iso quiet splash"),
    "gparted": ("live/vmlinuz", ["live/initrd.img"], "boot=live union=overlay username=user config components loglevel=3 noswap net.ifnames=0 nosplash live-media=/dev/usos-iso"),
    "clonezilla": ("live/vmlinuz", ["live/initrd.img"], "boot=live union=overlay username=user config components loglevel=3 noswap edd=on nomodeset enforcing=0 locales= keyboard-layouts= ocs_live_run=\"ocs-live-general\" ocs_live_extra_param=\"\" ocs_live_batch=\"no\" vga=788 net.ifnames=0 quiet nosplash live-media=/dev/usos-iso"),
    "systemrescue": ("sysresccd/boot/x86_64/vmlinuz", ["sysresccd/boot/intel_ucode.img", "sysresccd/boot/amd_ucode.img", "sysresccd/boot/x86_64/sysresccd.img"], "archisobasedir=sysresccd archisolabel={label} iomem=relaxed"),
    "fedora": ("boot/x86_64/loader/linux", ["boot/x86_64/loader/initrd"], "quiet rhgb root=live:CDLABEL={label} rd.live.image"),
    "debian13-netinst": ("install.amd/vmlinuz", ["install.amd/gtk/initrd.gz"], "vga=788 --- quiet"),
    "debian12-netinst": ("install.amd/vmlinuz", ["install.amd/gtk/initrd.gz"], "vga=788 --- quiet"),
}


def per_boot_cpio(iso_map: str, extra: dict[str, bytes]) -> bytes:
    out = packer.entry("usos", 0o040755, b"", 0x55540001)
    out += packer.entry("usos/iso.map", 0o100644, iso_map.encode(), 0x55540002)
    ino = 0x55540003
    for path, data in extra.items():
        out += packer.entry(path, 0o100644, data, ino)
        ino += 1
    out += packer.entry("TRAILER!!!", 0, b"", 0)
    return out + b"\0" * (-len(out) % 4)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("name", choices=sorted(RECIPES))
    parser.add_argument("--uefi", action="store_true")
    parser.add_argument("--tcg", action="store_true")
    parser.add_argument("--seconds", type=int, default=240)
    parser.add_argument("--init", default=str(ROOT / "zig-out" / "linux-iso" / "usos-init"))
    parser.add_argument("--memory", default="4096")
    parser.add_argument("--append", default="")
    args = parser.parse_args()

    extents = json.loads((str(VHD) + ".extents.json") and Path(str(VHD) + ".extents.json").read_text(encoding="utf-8-sig"))
    info = extents[args.name]
    iso = Iso(str(ASSETS / info["file"]))
    kernel_path, initrds, cmdline = RECIPES[args.name]
    cmdline = cmdline.replace("{label}", iso.label)
    work = OUT / args.name
    work.mkdir(parents=True, exist_ok=True)
    (work / "vmlinuz").write_bytes(iso.cat(kernel_path))
    combined = b""
    for path in initrds:
        data = iso.cat(path)
        combined += data + b"\0" * (-len(data) % 4)
    combined += packer.build(Path(args.init).read_bytes(), (ROOT / "assets" / "linux-iso" / "init-bottom").read_bytes().replace(b"\r\n", b"\n"))
    pvd = iso.read(16 * 2048, 2048)
    lines = ["usos-iso-map 1", f"size {info['size']}", f"crc {zlib.crc32(pvd) & 0xffffffff:08x}"]
    lines += [f"extent {int(e[0])} {int(e[1])}" for e in info["extents"]]
    extra = {}
    if args.name.endswith("netinst"):
        # d-i: the ISO shows up as a USB partition (BLKPG fallback of /usos/init).
        extra["preseed.cfg"] = b"d-i cdrom-detect/try-usb boolean true\n"
    combined += per_boot_cpio("\n".join(lines) + "\n", extra)
    (work / "initrd").write_bytes(combined)
    full = f"{cmdline} rdinit=/usos/init console=tty0 console=ttyS0,115200 ignore_loglevel {args.append}".strip()
    print(f"[INFO] {args.name}: {len(info['extents'])} extent(s), cmdline: {full}")

    port = free_port()
    serial = work / ("serial-uefi.log" if args.uefi else "serial-bios.log")
    cmd = [str(QEMU), "-machine", "q35", "-m", args.memory, "-smp", "2",
           "-accel", "tcg" if args.tcg else "whpx", "-accel", "tcg",
           "-display", "none", "-vga", "std", "-serial", f"file:{serial}",
           "-monitor", f"tcp:127.0.0.1:{port},server,nowait",
           "-kernel", str(work / "vmlinuz"), "-initrd", str(work / "initrd"), "-append", full,
           "-drive", f"file={VHD},if=none,id=usos,format=raw,snapshot=on",
           "-device", "qemu-xhci,id=xhci", "-device", "usb-storage,bus=xhci.0,drive=usos",
           "-device", "usb-tablet,bus=xhci.0", "-netdev", "user,id=n0", "-device", "e1000,netdev=n0"]
    if args.uefi:
        vars_copy = work / "vars.fd"
        vars_copy.write_bytes(OVMF_VARS.read_bytes())
        cmd += ["-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE}",
                "-drive", f"if=pflash,format=raw,file={vars_copy}"]
    proc = subprocess.Popen(cmd)
    monitor = Monitor(port)
    try:
        deadline = time.time() + args.seconds
        shots = 0
        while time.time() < deadline and proc.poll() is None:
            time.sleep(30)
            shots += 1
            monitor.shot(work / f"{'uefi' if args.uefi else 'bios'}-{shots:02d}.png")
    finally:
        try:
            monitor.command("quit")
        except OSError:
            pass
        proc.wait(timeout=30)
    log = serial.read_text(errors="replace") if serial.exists() else ""
    attached = "usos-init: iso attached" in log
    print(("[PASS]" if attached else "[FAIL]") + f" helper attached the ISO ({serial})")
    for line in log.splitlines():
        if "usos-init" in line or "USOS:" in line:
            print("   ", line.strip()[:200])
    return 0 if attached else 1


if __name__ == "__main__":
    raise SystemExit(main())
