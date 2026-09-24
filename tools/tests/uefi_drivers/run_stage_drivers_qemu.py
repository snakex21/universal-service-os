#!/usr/bin/env python3
"""The micro-Linux driver stager (usos-fb-ui --stage-drivers, used by
tools/extract.sh for Windows 7/8/10/11 WORK preparation) on a real NTFS
DATA/WORK test disk, in QEMU with the release micro-Linux kernel and
initramfs.

The VM runs the initramfs with rdinit=/bin/sh; the test types the same
mounts extract.sh has (DATA ntfs3 read-only, WORK ntfs3 read-write) and runs
the stager three times:

  amd64   install image with <ARCH>9</ARCH>: signed x64 packages are staged
          into $WinPEDriver$\\<Class>-NN, unsigned/x86-only/incomplete/
          malformed/duplicate packages and loose junk are not;
  x86     <ARCH>0</ARCH>: only the x86 package is staged;
  space   destination on a 70 MiB tmpfs (64 MiB reserve): the 8 MiB package
          is skipped for space, the small ones are staged.

Needs an elevated shell (the GPT test disk is built with Mount-DiskImage,
tools/tests/uefi_drivers/new_test_disk.ps1) and zig-out/micro-linux from
`zig build micro-linux`. No physical disk is used.

    python tools/tests/uefi_drivers/run_stage_drivers_qemu.py
"""
from __future__ import annotations

import shutil
import socket
import struct
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
QEMU = ROOT / "tools" / "qemu" / "qemu-system-x86_64.exe"
KERNEL = ROOT / "zig-out" / "micro-linux" / "vmlinuz-virt"
INITRAMFS = ROOT / "zig-out" / "micro-linux" / "initramfs-usos"
WORK = ROOT / "tools" / "tests" / "artifacts" / "stage-drivers"
NEW_TEST_DISK = ROOT / "tools" / "tests" / "uefi_drivers" / "new_test_disk.ps1"
UNICODE = "Zażółć ünïcode"


def inf(models: str, catalog: str | None, files: list[str], extra: str = "") -> str:
    lines = ["[Version]", 'Signature="$Windows NT$"', "Class=SCSIAdapter", "Provider=%P%", "DriverVer=01/02/2024,1.2.3.4"]
    if catalog:
        lines.append(f"CatalogFile.NTamd64={catalog}" if "NTamd64" in models else f"CatalogFile={catalog}")
    lines += ["", "[Manufacturer]", f"%P% = {models}", "", "[SourceDisksNames]", "1 = %Disk%,,,", extra, "[SourceDisksFiles]"]
    lines += [f"{name} = 1" for name in files]
    lines += ["", "[Strings]", 'P="Test Provider"', 'Disk="Test disk"', ""]
    return "\r\n".join(lines)


def write(path: Path, data: bytes | str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data.encode("utf-8") if isinstance(data, str) else data)


def fake_wim(arch: int) -> bytes:
    xml = f'<WIM><IMAGE INDEX="1"><WINDOWS><ARCH>{arch}</ARCH><VERSION><MAJOR>10</MAJOR><MINOR>0</MINOR></VERSION></WINDOWS></IMAGE></WIM>'
    xml_bytes = b"\xff\xfe" + xml.encode("utf-16-le")
    header = bytearray(208)
    header[0:8] = b"MSWIM\x00\x00\x00"
    struct.pack_into("<I", header, 8, 208)
    struct.pack_into("<I", header, 44, 1)
    struct.pack_into("<QQQ", header, 72, len(xml_bytes), 208, len(xml_bytes))
    return bytes(header) + xml_bytes


def data_tree() -> Path:
    data = WORK / "data"
    if data.exists():
        shutil.rmtree(data)
    base = data / "Drivers" / "Windows 10"
    x64 = "Models, NTamd64, NTamd64.10.0"
    write(base / "Storage" / "GoodX64" / "good.inf", inf(x64, "good.cat", ["good.sys"]))
    write(base / "Storage" / "GoodX64" / "good.sys", b"SYS")
    write(base / "Storage" / "GoodX64" / "good.cat", b"CAT")
    write(base / "Storage" / "Unsigned" / "unsigned.inf", inf(x64, None, ["unsigned.sys"]))
    write(base / "Storage" / "Unsigned" / "unsigned.sys", b"SYS")
    write(base / "Storage" / "Utf16" / "u16.inf", b"\xff\xfe" + inf(x64, "u16.cat", ["u16.sys"]).encode("utf-16-le"))
    write(base / "Storage" / "Utf16" / "u16.sys", b"SYS")
    write(base / "Storage" / "Utf16" / "u16.cat", b"CAT")
    write(base / "Storage" / "X86Only" / "x86.inf", inf("Models", "x86.cat", ["x86.sys"]))
    write(base / "Storage" / "X86Only" / "x86.sys", b"SYS")
    write(base / "Storage" / "X86Only" / "x86.cat", b"CAT")
    write(base / "USB" / "MissingFile" / "miss.inf", inf(x64, "miss.cat", ["present.sys", "missing.sys"]))
    write(base / "USB" / "MissingFile" / "present.sys", b"SYS")
    write(base / "USB" / "MissingFile" / "miss.cat", b"CAT")
    write(base / "USB" / "Nested" / "nested.inf", inf(x64, "nested.cat", ["nested.sys"]))
    write(base / "USB" / "Nested" / "nested.cat", b"CAT")
    write(base / "USB" / "Nested" / "amd64" / "nested.sys", b"SYS")
    for copy in ("Dup1", "Dup2"):
        write(base / "Other" / copy / "net.inf", inf(x64, "net.cat", ["net.sys"]))
        write(base / "Other" / copy / "net.sys", b"SYS")
        write(base / "Other" / copy / "net.cat", b"CAT")
    write(base / "Other" / UNICODE / "uni.inf", inf(x64, "uni.cat", ["uni.sys"]))
    write(base / "Other" / UNICODE / "uni.sys", b"SYS")
    write(base / "Other" / UNICODE / "uni.cat", b"CAT")
    write(base / "Other" / "junk" / "readme.txt", "not a driver")
    write(base / "Other" / "Malformed" / "bad.inf", "this is not an INF file")
    write(base / "Other" / "Big" / "big.inf", inf(x64, "big.cat", ["big.sys"]))
    write(base / "Other" / "Big" / "big.sys", b"\x00" * (8 * 1024 * 1024))
    write(base / "Other" / "Big" / "big.cat", b"CAT")
    deep = base / "Other" / "LongPkg" / ("a" * 70) / ("b" * 70) / ("c" * 70)
    write(base / "Other" / "LongPkg" / "long.inf", inf(x64, "long.cat", ["long.sys"]))
    write(base / "Other" / "LongPkg" / "long.cat", b"CAT")
    write(deep / "long.sys", b"SYS")
    write(base / "loose.inf", inf(x64, "loose.cat", ["loose.sys"]))
    write(base / "loose.sys", b"SYS")
    write(base / "loose.cat", b"CAT")
    write(data / "test" / "install-x64.wim", fake_wim(9))
    write(data / "test" / "install-x86.wim", fake_wim(0))
    return data


def build_disk() -> Path:
    esp = WORK / "esp"
    if esp.exists():
        shutil.rmtree(esp)
    write(esp / "EFI" / "USOS" / "placeholder.txt", "stage-drivers test")
    vhd = WORK / "stage-drivers.vhd"
    subprocess.run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(NEW_TEST_DISK),
                    "-Vhd", str(vhd), "-EspSource", str(esp), "-DataSource", str(data_tree())], check=True)
    return vhd


class Console:
    def __init__(self, port: int):
        deadline = time.time() + 30
        while True:
            try:
                self.sock = socket.create_connection(("127.0.0.1", port), timeout=5)
                break
            except OSError:
                if time.time() > deadline:
                    raise
                time.sleep(0.5)
        self.sock.settimeout(1)
        self.text = ""

    def read_until(self, needle: str, timeout: float) -> str:
        deadline = time.time() + timeout
        while needle not in self.text and time.time() < deadline:
            try:
                chunk = self.sock.recv(65536)
                if chunk:
                    self.text += chunk.decode("utf-8", errors="replace")
            except socket.timeout:
                pass
        if needle not in self.text:
            raise TimeoutError(f"no {needle!r} on the serial console")
        return self.text

    def run(self, command: str, marker: str, timeout: float = 120) -> str:
        start = len(self.text)
        self.sock.sendall((command + f"; echo {marker}\n").encode())
        self.wait_marker(marker, start, timeout)
        return self.text[start:]

    def wait_marker(self, marker: str, start: int, timeout: float) -> None:
        import re
        pattern = re.compile(r"(^|\n)" + re.escape(marker) + r"\r?\n")
        deadline = time.time() + timeout
        while time.time() < deadline:
            # The typed command (echoed by the tty) has the marker after
            # "echo "; the output has it alone on a line.
            if pattern.search(self.text[start:]):
                return
            try:
                chunk = self.sock.recv(65536)
                if chunk:
                    self.text += chunk.decode("utf-8", errors="replace")
            except socket.timeout:
                pass
        raise TimeoutError(f"command marker {marker} not seen")


def main() -> int:
    for required in (QEMU, KERNEL, INITRAMFS):
        if not required.exists():
            raise SystemExit(f"missing {required}")
    WORK.mkdir(parents=True, exist_ok=True)
    vhd = build_disk()
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
    listener.close()
    args = [str(QEMU), "-machine", "q35", "-accel", "tcg", "-cpu", "max", "-m", "1024", "-smp", "2",
            "-display", "none", "-nic", "none",
            "-kernel", str(KERNEL), "-initrd", str(INITRAMFS),
            "-append", "console=ttyS0,115200 rdinit=/bin/sh loglevel=3",
            "-chardev", f"socket,id=s0,host=127.0.0.1,port={port},server=on,wait=off", "-serial", "chardev:s0",
            "-drive", f"if=none,id=d0,file={vhd.as_posix()},format=vpc", "-device", "ide-hd,bus=ide.0,drive=d0"]
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
        # usos-init installs the busybox applets and loads modules by path;
        # do the same by hand (modprobe first, insmod of the file as fallback).
        setup = ("export PATH=/usr/sbin:/usr/bin:/sbin:/bin; /bin/busybox --install -s; "
                 "mount -t proc proc /proc; mount -t sysfs sys /sys; mount -t devtmpfs dev /dev 2>/dev/null; "
                 "for a in /sys/bus/pci/devices/*/modalias; do modprobe \"$(cat $a)\" 2>/dev/null; done; "
                 "for m in ahci sd_mod ntfs3; do modprobe $m 2>/dev/null || { p=$(find /usr/lib/modules -name \"$m.ko*\" | head -n 1); [ -n \"$p\" ] && insmod \"$p\"; }; done; "
                 "sleep 3; mdev -s 2>/dev/null; ls /dev/sda*; "
                 "mkdir -p /mnt/data /mnt/work /mnt/small; mount -t ntfs3 -o ro $(findfs LABEL=USOS_DATA) /mnt/data && mount -t ntfs3 -o rw $(findfs LABEL=USOS_WORK) /mnt/work && echo MOUNTS=OK")
        out = console.run(setup, "SETUP-DONE", 180)
        (WORK / "setup.log").write_text(out, encoding="utf-8")
        mounted = any(line.strip() == "MOUNTS=OK" for line in out.splitlines())
        expect(mounted, "DATA (ntfs3 read-only) and WORK (ntfs3) are mounted like extract.sh does")
        if not mounted:
            raise RuntimeError("mounts failed; see setup.log")
        src = '"/mnt/data/Drivers/Windows 10"'

        out = console.run(f"usos-fb-ui --stage-drivers {src} '/mnt/work/$WinPEDriver$' /mnt/data/test/install-x64.wim /mnt/work/usos-drivers.log; echo RC=$?; "
                          "cd '/mnt/work/$WinPEDriver$' && find . -type f | sort; cd /", "X64-DONE", 300)
        (WORK / "amd64.log").write_text(out, encoding="utf-8")
        files = [line.strip() for line in out.splitlines() if line.strip().startswith("./")]
        has = lambda pattern: any(Path(f).match(pattern) for f in files)  # noqa: E731
        expect("RC=0" in out, "amd64: the stager exits 0")
        expect("targets=amd64" in out and "+x86" not in out.split("targets=")[1][:20], "amd64: <ARCH>9</ARCH> -> amd64 only")
        expect(has("Storage-*/good.inf") and has("Storage-*/good.sys") and has("Storage-*/good.cat"), "amd64: a signed x64 storage package is staged")
        expect(has("Storage-*/u16.inf"), "amd64: a UTF-16LE INF is read")
        expect(has("USB-*/amd64/nested.sys") and has("USB-*/nested.inf"), "amd64: an INF-less sub-folder belongs to its package")
        expect(not has("*/unsigned.sys") and "unsigned (no catalog)" in out, "amd64: an unsigned x64 package is skipped (never bypassed)")
        expect(not has("*/x86.inf") and "no models for the target architecture" in out, "amd64: an x86-only INF is skipped")
        expect(not has("*/present.sys") and "missing.sys" in out, "amd64: an INF with a missing [SourceDisksFiles] file is skipped")
        expect(sum(1 for f in files if f.endswith("/net.inf")) == 1 and "duplicate of an INF already used" in out, "amd64: a duplicate INF is used once")
        expect(has("Other-*/uni.inf"), "amd64: a non-ASCII folder name works")
        expect(not has("*/readme.txt"), "amd64: a folder without an INF is not copied")
        expect(not has("*/bad.inf") and "not a driver INF" in out, "amd64: a malformed INF is skipped")
        expect(has("Other-*/loose.inf") and not has("Other-*/junk/*"), "amd64: a loose INF in Drivers\\<OS> is its own package and owns no sub-folders")
        expect("path too long for Windows Setup" in out, "amd64: a path longer than Windows Setup's limit is skipped")
        expect(has("Other-*/big.sys"), "amd64: an 8 MiB package fits on WORK")
        out = console.run("cat /mnt/work/usos-drivers.log | tail -3", "LOG-DONE", 60)
        expect("done: packages=" in out, "amd64: the log file on WORK is written")

        out = console.run(f"usos-fb-ui --stage-drivers {src} '/mnt/work/x86$' /mnt/data/test/install-x86.wim /mnt/work/usos-drivers-x86.log; "
                          "cd '/mnt/work/x86$' && find . -type f | sort; cd /", "X86-DONE", 300)
        (WORK / "x86.log").write_text(out, encoding="utf-8")
        files = [line.strip() for line in out.splitlines() if line.strip().startswith("./")]
        expect("targets=x86" in out and any(f.endswith("/x86.inf") for f in files) and not any(f.endswith("/good.inf") for f in files),
               "x86: <ARCH>0</ARCH> -> only the x86 package is staged")

        out = console.run("mount -t tmpfs -o size=70m tmpfs /mnt/small; "
                          f"usos-fb-ui --stage-drivers {src} '/mnt/small/$WinPEDriver$' /mnt/data/test/install-x64.wim /mnt/small/log; "
                          "cd '/mnt/small/$WinPEDriver$' && find . -type f | sort; cd /", "SPACE-DONE", 300)
        (WORK / "space.log").write_text(out, encoding="utf-8")
        files = [line.strip() for line in out.splitlines() if line.strip().startswith("./")]
        expect("not enough free space" in out and not any(f.endswith("/big.sys") for f in files) and any(f.endswith("/good.sys") for f in files),
               "space: a package that does not fit (64 MiB reserve) is skipped, the small ones are staged")
        console.run("sync; umount /mnt/work; umount /mnt/data", "UMOUNT-DONE", 120)
        console.sock.sendall(b"poweroff -f\n")
        time.sleep(3)
    finally:
        if qemu.poll() is None:
            qemu.kill()
        stderr.close()
    print(f"[RESULT] {len(failures)} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
