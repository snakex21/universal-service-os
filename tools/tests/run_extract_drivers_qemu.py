#!/usr/bin/env python3
"""extract.sh stages the user drivers for every method that leaves Windows
Setup media on WORK, in QEMU with the release micro-Linux kernel/initramfs.

The fixtures (a fake Windows ISO tree, WORK, DATA\\Drivers, install-state.ini)
travel as a second newc archive appended to the initramfs; the VM runs
rdinit=/bin/sh and calls the real /usr/lib/usos/extract.sh on tmpfs:

  chainload  Windows 10 (UEFI chainload), install.esd  -> $WinPEDriver$ staged
             from Drivers\\Windows 10 (folder from selected_system=windows-10,
             although the image sits in the Windows 11 folder);
  iso        Windows 11, split install.swm              -> staged;
  chainload  no sources/setup.exe (not Setup media)     -> not staged.

No disk image, no admin rights.

    python tools/tests/run_extract_drivers_qemu.py
"""
from __future__ import annotations

import gzip
import os
import socket
import stat
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
sys.path.insert(0, str(ROOT / "tools" / "tests" / "uefi_drivers"))
from build_micro_linux import Entry, newc, put  # noqa: E402
from run_stage_drivers_qemu import Console, fake_wim, inf  # noqa: E402

QEMU = ROOT / "tools" / "qemu" / "qemu-system-x86_64.exe"
# USOS_MICRO_LINUX_DIR: test a micro-Linux build kept outside zig-out.
MICRO_LINUX = Path(os.environ.get("USOS_MICRO_LINUX_DIR", ROOT / "zig-out" / "micro-linux"))
KERNEL = MICRO_LINUX / "vmlinuz-virt"
INITRAMFS = MICRO_LINUX / "initramfs-usos"
WORK = ROOT / "tools" / "tests" / "artifacts" / "extract-drivers"


def fixtures() -> bytes:
    entries: dict[str, Entry] = {}

    def add(name: str, data: bytes | str) -> None:
        put(entries, Entry(name, stat.S_IFREG | 0o644, data.encode("utf-8") if isinstance(data, str) else data))

    x64 = "Models, NTamd64, NTamd64.10.0"
    for os_folder, tag in (("Windows 10", "w10"), ("Windows 11", "w11")):
        base = f"test/data/Drivers/{os_folder}/Storage/{tag}"
        add(f"{base}/{tag}.inf", inf(x64, f"{tag}.cat", [f"{tag}.sys"]))
        add(f"{base}/{tag}.sys", b"SYS")
        add(f"{base}/{tag}.cat", b"CAT")
    for case, image in (("esd", "sources/install.esd"), ("swm", "sources/install.swm"), ("nosetup", "sources/install.wim")):
        src = f"test/src-{case}"
        add(f"{src}/EFI/BOOT/BOOTX64.EFI", b"MZ-efi")
        add(f"{src}/bootmgr", b"bootmgr")
        add(f"{src}/{image}", fake_wim(9))
        if case != "nosetup":
            add(f"{src}/sources/setup.exe", b"MZ-setup")
    init = (ROOT / "tools" / "micro_linux_init.sh").read_text(encoding="utf-8").splitlines()
    start = init.index("ini_value() {")
    add("test/ini_value.sh", "\n".join(init[start:init.index("}", start) + 1]) + "\n")
    state = ("phase=prepare-requested\r\nselected_iso=\\Systems\\x.iso\r\nselected_unattend=none\r\n"
             "selected_method=chainload\r\nselected_system=windows-10\r\nplan_version=1\r\n"
             "plan_profile=iso-work-chainload\r\nplan_progress=micro_linux\r\n"
             "plan_stages=Starting environment|Verifying target device|Preparing workspace|Copying files|Verification and finalization\r\n")
    add("test/plan-state.ini", state.encode("ascii") + b"\n" * (2048 - len(state)))
    return newc(entries)


CASES = [
    # (label, source, method, system, selected iso, expected staged, expected driver)
    ("chainload-w10-esd", "esd", "chainload", "windows-10", "Systems/Windows/Windows 11/Images/w10.iso", "yes", "w10"),
    ("iso-w11-swm", "swm", "iso", "windows-11", "Systems/Windows/Windows 11/Images/w11.iso", "yes", "w11"),
    ("chainload-no-setup", "nosetup", "chainload", "windows-10", "Systems/Windows/Windows 10/Images/x.iso", "no", None),
]


def main() -> int:
    for required in (QEMU, KERNEL, INITRAMFS):
        if not required.exists():
            raise SystemExit(f"missing {required}")
    WORK.mkdir(parents=True, exist_ok=True)
    initrd = WORK / "initramfs-with-fixtures"
    initrd.write_bytes(INITRAMFS.read_bytes() + gzip.compress(fixtures(), mtime=0))
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
    listener.close()
    args = [str(QEMU), "-machine", "q35", "-accel", "tcg", "-cpu", "max", "-m", "1024", "-smp", "2",
            "-display", "none", "-nic", "none",
            "-kernel", str(KERNEL), "-initrd", str(initrd),
            "-append", "console=ttyS0,115200 rdinit=/bin/sh loglevel=3",
            "-chardev", f"socket,id=s0,host=127.0.0.1,port={port},server=on,wait=off", "-serial", "chardev:s0"]
    stderr = open(WORK / "qemu.stderr.log", "wb")
    qemu = subprocess.Popen(args, stderr=stderr)
    failures: list[str] = []

    def expect(condition: bool, label: str) -> None:
        print(("[PASS] " if condition else "[FAIL] ") + label)
        if not condition:
            failures.append(label)

    try:
        console = Console(port)
        time.sleep(8)
        console.run("export PATH=/usr/sbin:/usr/bin:/sbin:/bin; /bin/busybox --install -s; "
                    "mount -t proc proc /proc; mount -t sysfs sys /sys; mount -t devtmpfs dev /dev 2>/dev/null; "
                    "mkdir -p /tmp; mount -t tmpfs tmp /tmp", "SETUP-DONE", 60)
        # M2: install-state.ini with the plan_* keys (fixture test/plan-state.ini),
        # read by the real micro_linux_init.sh ini_value (fixture
        # test/ini_value.sh) under the initramfs' busybox awk.
        out = console.run(". /test/ini_value.sh; for k in phase selected_method selected_system plan_profile; do "
                          "printf 'KV %s=[%s]\n' $k \"$(ini_value $k /test/plan-state.ini)\"; done", "DONE-plan-state", 60)
        (WORK / "plan-state.log").write_text(out, encoding="utf-8")
        for expected in ("KV phase=[prepare-requested]", "KV selected_method=[chainload]", "KV selected_system=[windows-10]", "KV plan_profile=[iso-work-chainload]"):
            expect(expected in out, f"plan keys: {expected}")
        for label, source, method, system, iso, staged, driver in CASES:
            command = (f"rm -rf /test/work /test/state; mkdir -p /test/work /test/state; echo nonce=t > /test/work/.usos-work; "
                       f"SOURCE_ROOT=/test/src-{source} WORK_ROOT=/test/work STATE_FILE=/test/state/install-state.ini "
                       f"SELECTED_METHOD={method} SELECTED_SYSTEM={system} SELECTED_ISO='{iso}' DATA_ROOT=/test/data "
                       "USOS_UI_TTY=/dev/null sh /usr/lib/usos/extract.sh > /tmp/extract.log 2>&1; echo RC=$?; "
                       "grep -E '^\\[EXTRACT\\] (windows setup media|user drivers)|STOP' /tmp/extract.log; "
                       "cd '/test/work/$WinPEDriver$' 2>/dev/null && find . -type f | sort; cd /")
            out = console.run(command, f"DONE-{label}", 240)
            (WORK / f"{label}.log").write_text(out, encoding="utf-8")
            files = [line.strip() for line in out.splitlines() if line.strip().startswith("./")]
            expect("RC=0" in out, f"{label}: extract.sh exits 0")
            expect(f"user drivers staged={staged}" in out, f"{label}: user drivers staged={staged}")
            if driver:
                expect(any(f.endswith(f"/{driver}.inf") for f in files), f"{label}: Drivers\\{'Windows 10' if driver == 'w10' else 'Windows 11'} package in $WinPEDriver$")
                expect(not any(f.endswith("/w11.inf" if driver == "w10" else "/w10.inf") for f in files), f"{label}: no package from another Windows folder")
            else:
                expect(not files and "windows setup media=no" in out, f"{label}: nothing staged without sources/setup.exe")
    finally:
        qemu.kill()
        qemu.wait()
        stderr.close()
    print("[PASS] extract.sh driver staging" if not failures else f"[FAIL] {len(failures)} check(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
