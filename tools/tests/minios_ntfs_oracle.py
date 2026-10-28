#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Host-only NTFS-3G oracle. No library or binary is linked into usosprep.

Prepare a small Alpine environment from the pinned cache, then boot it with
only a read-only raw COPY of a closed test image. All runtime files stay in
the explicitly selected Kioxia workspace. Completion is process/serial based;
there are no status, screenshot, QMP or progress polling loops.
"""
from __future__ import annotations

import argparse
import ctypes
import gzip
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys

WORKSPACE = Path(__file__).resolve().parents[2] / "zig-out/minios-oracle"
PACKAGES = ("ntfs-3g", "ntfs-3g-libs", "ntfs-3g-progs", "libuuid")


def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def no_links(path: Path) -> Path:
    if not path.is_absolute() or str(path).startswith("\\\\") or any(c in str(path) for c in ",\r\n\0"):
        raise ValueError("An absolute local file path is required")
    for component in (path, *path.parents):
        if component.exists() and (component.is_symlink() or getattr(component.lstat(), "st_file_attributes", 0) & 0x400):
            raise ValueError("Reparse points are forbidden: " + str(component))
    return path


def owned(path: Path) -> Path:
    path = no_links(path)
    if path != WORKSPACE and WORKSPACE not in path.parents:
        raise ValueError("Output/input copy must be inside the owned oracle folder")
    return path


def guard() -> None:
    if os.name != "nt":
        raise ValueError("This host harness requires Windows and an explicit local workspace")
    api = ctypes.WinDLL("kernel32", use_last_error=True)
    no_links(WORKSPACE)
    if WORKSPACE == Path(WORKSPACE.anchor): raise ValueError("A volume root is not an application workspace")
    if shutil.disk_usage(WORKSPACE).free < 100 * 1024**3:
        raise ValueError("Workspace volume reserve would fall below 100 GiB")
    class Memory(ctypes.Structure):
        _fields_ = [("length", ctypes.c_uint32), ("load", ctypes.c_uint32),
            *[(field, ctypes.c_uint64) for field in ("total", "available", "page_total", "page_available",
                "virtual_total", "virtual_available", "extended")]]
    memory = Memory()
    memory.length = ctypes.sizeof(memory)
    if not api.GlobalMemoryStatusEx(ctypes.byref(memory)) or memory.available < 8 * 1024**3 + 512 * 1024**2:
        raise ValueError("Oracle VM would violate the 8 GiB host RAM reserve")


def import_builder(root: Path):
    path = no_links(root / "tools/build_micro_linux.py")
    spec = importlib.util.spec_from_file_location("minios_oracle_cpio", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def prepare(root: Path, out: Path) -> None:
    guard()
    out = owned(out)
    if out.exists():
        raise FileExistsError("Never overwrite oracle preparation")
    lock_path = no_links(root / "tools/micro_linux.lock.json")
    lock = json.loads(lock_path.read_text("utf-8"))
    m = import_builder(root)
    pins = {}

    def pinned(path: Path, expected: str) -> bytes:
        no_links(path)
        data = path.read_bytes()
        actual = hashlib.sha256(data).hexdigest()
        if actual != expected:
            raise ValueError("Pinned cache artifact changed: " + path.name)
        pins[path.name] = {"source": str(path), "bytes": len(data), "sha256": actual}
        return data

    kernel_record = lock["alpine_lts"]["kernel"]
    initrd_record = lock["alpine_lts"]["initramfs"]
    kernel = pinned(root / kernel_record["file"], kernel_record["sha256"])
    entries = m.parse_newc(gzip.decompress(pinned(root / initrd_record["file"], initrd_record["sha256"])))
    # Reuse only kernel modules/metadata from the existing build; no USOS
    # installer scripts, Windows binaries, overlays or flows are copied.
    module_source = no_links(root / "zig-out/micro-linux/initramfs-usos")
    module_data = module_source.read_bytes()
    pins["module-source"] = {"source": str(module_source), "sha256": hashlib.sha256(module_data).hexdigest()}
    compiled = m.parse_newc(gzip.decompress(module_data))
    kernel_versions = {n.split("/")[3] for n in compiled if n.startswith("usr/lib/modules/") and len(n.split("/")) > 4}
    if len(kernel_versions) != 1:
        raise ValueError("Expected one kernel module version")
    for name, entry in compiled.items():
        if name.startswith("usr/lib/modules/"):
            m.put(entries, entry)
    for package in PACKAGES:
        found = [r for r in lock["packages"] if re.fullmatch(re.escape(package) + r"-[0-9].*\.apk", r["file"])]
        if len(found) != 1:
            raise ValueError("Ambiguous/missing pinned APK: " + package)
        record = found[0]
        path = root / "tools/cache/alpine/packages" / record["file"]
        pinned(path, record["sha256"])
        for entry in m.archive_entries(path):
            normalized = m.merged_usr_entry(entry)
            if normalized is not None:
                m.put(entries, normalized)
    for command in ("ntfsfix", "ntfsinfo", "ntfsls", "ntfs-3g", "mkntfs"):
        if not any(n.endswith("/" + command) for n in entries):
            raise ValueError("Missing oracle tool: " + command)
    out.mkdir(parents=True, exist_ok=False)
    (out / "vmlinuz").write_bytes(kernel)
    base = m.pad_initrd(gzip.compress(m.newc(entries), compresslevel=6, mtime=0))
    (out / "oracle-base.gz").write_bytes(base)
    (out / "prepared.json").write_text(json.dumps({"kind": "host-only-ntfs-oracle", "pins": pins,
        "kernel_versions": sorted(kernel_versions), "kernel_sha256": sha(out / "vmlinuz"),
        "base_sha256": sha(out / "oracle-base.gz"), "no_windows_payload": True}, indent=2) + "\n", encoding="utf-8")


GUEST_PREFIX = r'''#!/bin/busybox sh
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
/bin/busybox --install -s
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
exec </dev/console >/dev/console 2>&1
mkdir -p /tmp /mnt/target
mount -t tmpfs tmpfs /tmp
finish() {
  echo "USOS_ORACLE_COMPLETE=$1"
  sync
  poweroff -f
  exit "$1"
}
trap 'finish 90' HUP INT TERM
modprobe virtio_pci || finish 10
modprobe virtio_blk || finish 11
modprobe fuse || finish 12
mdev -s
check() {
  tag="$1"; shift
  echo "ORACLE_BEGIN=$tag"
  "$@"
  rc=$?
  echo "ORACLE_END=$tag exit=$rc"
  [ "$rc" = 0 ] || finish "$rc"
}
'''

GUEST_TARGET = r'''
[ -b /dev/vda1 ] || finish 20
[ "$(cat /sys/block/vda/ro)" = 1 ] || finish 21
[ "$(cat /sys/block/vda/serial)" = USOSORACLE ] || finish 22
echo "ORACLE_TARGET=/dev/vda1 readonly=1 serial=USOSORACLE"
check ntfsfix ntfsfix --no-action /dev/vda1
check ntfsinfo ntfsinfo -m /dev/vda1
check ntfsls ntfsls -a -l -p / /dev/vda1
ntfscat /dev/vda1 '/$UpCase' >/tmp/upcase.bin || finish 26
[ "$(stat -c %s /tmp/upcase.bin)" = 131072 ] || finish 27
echo "ORACLE_UPCASE_SHA256=$(sha256sum /tmp/upcase.bin | cut -d ' ' -f 1)"
check mount ntfs-3g -o ro /dev/vda1 /mnt/target
awk '$2=="/mnt/target" {print "ORACLE_MOUNT_RECORD=" $0; if (($3=="fuseblk" || $3=="fuse" || $3=="fuse.ntfs-3g") && $4 ~ /^ro(,|$)/) ok=1} END {exit !ok}' /proc/mounts || finish 23
echo ORACLE_MANIFEST_BEGIN
(cd /mnt/target && find . -type f -print0 | sort -z | while IFS= read -r -d '' p; do
  bytes="$(stat -c %s "$p")" || exit 1
  digest="$(sha256sum "$p")" || exit 1
  printf '%s\t%s\t%s\n' "${digest%% *}" "$bytes" "$p"
done)
rc=$?
echo ORACLE_MANIFEST_END
[ "$rc" = 0 ] || finish 24
echo ORACLE_DIRECTORIES_BEGIN
(cd /mnt/target && find . -type d | sort)
rc=$?
echo ORACLE_DIRECTORIES_END
[ "$rc" = 0 ] || finish 25
check unmount umount /mnt/target
finish 0
'''

GUEST_SELFTEST = r'''
# This file exists only in the disposable Linux host's RAM filesystem.
# It validates the oracle runtime, never the usosprep implementation.
truncate -s 64M /tmp/oracle-selftest.ntfs || finish 30
check reference-format mkntfs -F -Q -s 512 -c 4096 /tmp/oracle-selftest.ntfs
check ntfsfix ntfsfix --no-action /tmp/oracle-selftest.ntfs
check ntfsinfo ntfsinfo -m /tmp/oracle-selftest.ntfs
check ntfsls ntfsls -a -l -p / /tmp/oracle-selftest.ntfs
check mount ntfs-3g -o ro /tmp/oracle-selftest.ntfs /mnt/target
awk '$2=="/mnt/target" {print "ORACLE_MOUNT_RECORD=" $0; if (($3=="fuseblk" || $3=="fuse" || $3=="fuse.ntfs-3g") && $4 ~ /^ro(,|$)/) ok=1} END {exit !ok}' /proc/mounts || finish 31
check unmount umount /mnt/target
echo ORACLE_SELFTEST_ONLY_NOT_USOSPREP_PASS
finish 0
'''


def relative_name(name: str) -> str:
    if not isinstance(name, str) or not name or any(c in name for c in "\\\r\n\t\0"):
        raise ValueError("Manifest needs relative slash-separated paths without control characters")
    if any(part in ("", ".", "..") for part in name.split("/")):
        raise ValueError("Ambiguous or absolute manifest path")
    return name


def expected_tree(path: Path) -> dict:
    item = json.loads(owned(path).read_text("utf-8"))
    if set(item) != {"files", "directories"} or not isinstance(item["files"], dict) or not isinstance(item["directories"], list):
        raise ValueError("Manifest requires files mapping and directories list")
    for name, data in item["files"].items():
        relative_name(name)
        if set(data) != {"size", "sha256"} or type(data["size"]) is not int or not 0 <= data["size"] < 2**64 or not re.fullmatch("[0-9a-f]{64}", data["sha256"]):
            raise ValueError("Invalid file metadata")
    if len(set(item["directories"])) != len(item["directories"]):
        raise ValueError("Duplicate directories")
    for name in item["directories"]:
        relative_name(name)
    return item


def actual_tree(serial: str) -> dict:
    def section(begin: str, end: str) -> list[str]:
        lines = serial.splitlines()
        if lines.count(begin) != 1 or lines.count(end) != 1 or lines.index(begin) >= lines.index(end):
            raise ValueError("Missing/ambiguous native manifest section")
        return lines[lines.index(begin) + 1:lines.index(end)]
    files = {}
    for line in section("ORACLE_MANIFEST_BEGIN", "ORACLE_MANIFEST_END"):
        digest, size, name = line.split("\t", 2)
        if not re.fullmatch("[0-9a-f]{64}", digest) or not size.isascii() or not size.isdecimal() or not name.startswith("./"):
            raise ValueError("Malformed native file manifest")
        name = relative_name(name[2:])
        if name in files:
            raise ValueError("Duplicate native file")
        files[name] = dict(size=int(size), sha256=digest)
    directories = []
    for name in section("ORACLE_DIRECTORIES_BEGIN", "ORACLE_DIRECTORIES_END"):
        if name == ".":
            continue
        if not name.startswith("./"):
            raise ValueError("Malformed native directory manifest")
        directories.append(relative_name(name[2:]))
    return dict(files=files, directories=sorted(directories))


def run(root: Path, pack: Path, qemu: Path, out: Path, image: Path | None, expected: str | None, manifest: Path | None) -> int:
    guard()
    pack, out = owned(pack), owned(out)
    no_links(qemu)
    prepared = json.loads((pack / "prepared.json").read_text("utf-8"))
    if sha(pack / "vmlinuz") != prepared["kernel_sha256"] or sha(pack / "oracle-base.gz") != prepared["base_sha256"]:
        raise ValueError("Oracle preparation changed")
    if out.exists():
        raise FileExistsError("A fresh oracle run folder is required")
    before = None
    tree = expected_tree(manifest) if manifest is not None else None
    if image is not None:
        image = owned(image)
        if image.suffix != ".raw" or not image.is_file() or not re.fullmatch("[0-9a-f]{64}", expected or ""):
            raise ValueError("Only an explicitly hashed raw test copy is accepted")
        if not image.stat().st_file_attributes & stat.FILE_ATTRIBUTE_READONLY:
            raise ValueError("Host raw copy must also carry its read-only attribute")
        before = sha(image)
        if before != expected:
            raise ValueError("Raw copy SHA-256 differs")
    out.mkdir(parents=True, exist_ok=False)
    m = import_builder(root)
    script = GUEST_PREFIX + (GUEST_TARGET if image is not None else GUEST_SELFTEST)
    overlay = m.newc({"oracle-init": m.Entry("oracle-init", stat.S_IFREG | 0o755, script.encode())})
    initrd = (pack / "oracle-base.gz").read_bytes() + overlay
    (out / "oracle-initramfs").write_bytes(initrd)
    env = dict(os.environ)
    runtime = out / "host-runtime"
    runtime.mkdir()
    for key in ("APPDATA", "LOCALAPPDATA", "TMP", "TEMP"):
        env[key] = str(runtime)
    command = [str(qemu), "-machine", "q35", "-accel", "tcg", "-cpu", "max", "-m", "512", "-smp", "1",
        "-display", "none", "-monitor", "none", "-nic", "none", "-no-reboot", "-kernel", str(pack / "vmlinuz"),
        "-initrd", str(out / "oracle-initramfs"), "-append", "console=ttyS0,115200 rdinit=/oracle-init loglevel=3 panic=-1",
        "-serial", "file:" + str(out / "serial.txt")]
    if image is not None:
        command += ["-drive", f"if=none,id=target,file={image},format=raw,readonly=on",
            "-device", "virtio-blk-pci,drive=target,serial=USOSORACLE"]
    (out / "command.json").write_text(json.dumps(command, indent=2), encoding="utf-8")
    with (out / "qemu-stderr.txt").open("xb") as err:
        process = subprocess.Popen(command, cwd=out, env=env, stdin=subprocess.DEVNULL,
            stdout=err, stderr=err, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        try:
            code = process.wait(timeout=300)
            timed_out = False
        except subprocess.TimeoutExpired:
            process.terminate()
            code = process.wait(timeout=20)
            timed_out = True
    serial = (out / "serial.txt").read_text("utf-8", errors="replace")
    after = sha(image) if image is not None else None
    completion = re.findall(r"^USOS_ORACLE_COMPLETE=([0-9]+)\r?$", serial, re.MULTILINE)
    passed = code == 0 and not timed_out and completion == ["0"] and before == after
    tree_passed, tree_error, differences = None, None, None
    if tree is not None:
        try:
            actual = actual_tree(serial)
            (out / "actual-tree.json").write_text(json.dumps(actual, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            tree_passed = actual["files"] == tree["files"] and actual["directories"] == sorted(tree["directories"])
            differences = dict(missing=sorted(set(tree["files"]) - set(actual["files"]))[:20],
                extra=sorted(set(actual["files"]) - set(tree["files"]))[:20],
                content=sorted(n for n in set(actual["files"]) & set(tree["files"]) if actual["files"][n] != tree["files"][n])[:20],
                directories_equal=actual["directories"] == sorted(tree["directories"]))
        except (ValueError, TypeError) as error:
            tree_passed, tree_error = False, str(error)
        passed = passed and tree_passed
    result = {"kind": "host-ntfs-oracle" if image is not None else "oracle-runtime-selftest-only",
        "passed": passed, "qemu_exit": code, "timeout": timed_out, "target": str(image) if image else None,
        "target_sha256_before": before, "target_sha256_after": after, "target_readonly": image is not None,
        "tree_passed": tree_passed, "tree_error": tree_error, "tree_differences": differences,
        "oracle_host_ram_mib": 512, "usosprep_64mib_acceptance": False, "serial_sha256": sha(out / "serial.txt")}
    upcase = re.findall(r"^ORACLE_UPCASE_SHA256=([0-9a-f]{64})\r?$", serial, re.MULTILINE)
    result["upcase_sha256"] = upcase[0] if len(upcase) == 1 else None
    (out / "result.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result), flush=True)
    return int(not passed)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "selftest", "check"))
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--pack", type=Path, required=True)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--qemu", type=Path)
    parser.add_argument("--image", type=Path)
    parser.add_argument("--sha256")
    parser.add_argument("--manifest", type=Path)
    args = parser.parse_args()
    global WORKSPACE
    WORKSPACE = no_links(Path(os.path.abspath(args.workspace)))
    if args.action == "prepare":
        prepare(args.source_root, args.pack)
        print("ORACLE_PREPARED " + str(args.pack), flush=True)
        return 0
    if args.out is None or args.qemu is None or (args.action == "check") != (args.image is not None) or (args.action == "check") != (args.manifest is not None):
        parser.error("run needs --out/--qemu; check alone needs --image/--sha256/--manifest")
    return run(args.source_root, args.pack, args.qemu, args.out, args.image, args.sha256, args.manifest)


if __name__ == "__main__":
    raise SystemExit(main())
