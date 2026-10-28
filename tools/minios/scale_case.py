"""File-only stage1b-1 fixtures and closed-image Windows acceptance.

The tested Zig writer has no host disk interface. Fresh host artifacts derive
from a new qcow2 COW of an immutable blank base. Windows checks a second, RO
VHD copy using the existing actual-alias/virtual-disk/size guard.
SPDX-License-Identifier: GPL-3.0-or-later
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import struct
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import uefi_case as api

REPO = Path(__file__).resolve().parents[2]
IMAGE_BYTES = {"tree150k": 16 * 1024**3, "single50k": 512 * 1024**2,
               "fragment5g": 8 * 1024**3, "firmware": 512 * 1024**2}
LARGE_BYTES = 5 * 1024**3
BLOCK = bytes((i * 37 + 11) & 255 for i in range(4096))


def generated_block(seed: int) -> bytes:
    return struct.pack("<Q", seed) + BLOCK[8:]


def generated_sha(size: int, seed: int) -> str:
    if not 0 <= size < 2**64 or not 0 <= seed < 2**64:
        raise ValueError("Fixture size and seed must be u64")
    block = generated_block(seed)
    if size <= 1024 * 1024:
        data = (block * ((size + 4095) // 4096))[:size]
        return hashlib.sha256(data).hexdigest()
    chunk = block * 256
    digest = hashlib.sha256()
    full, left = divmod(size, len(chunk))
    for _ in range(full):
        digest.update(chunk)
    digest.update(chunk[:left])
    return digest.hexdigest()


def manifest(profile: str) -> dict:
    if profile not in IMAGE_BYTES:
        raise ValueError("Unknown scale profile")
    files, directories = {}, []

    def add(name, size, seed):
        if name in files:
            raise ValueError("Duplicate fixture")
        files[name] = dict(size=size, sha256=generated_sha(size, seed))

    if profile in ("firmware", "single50k"):
        directories.append("Wide")
        for i in range(5000 if profile == "firmware" else 50000):
            add(f"Wide/file-{i:05}.bin", 64 if profile == "firmware" else 4096, i)
    if profile in ("firmware", "tree150k"):
        directories.append("Tree")
        count, each, size, first = ((100, 50, 64, 5000) if profile == "firmware"
                                    else (300, 500, 65536, 0))
        for d in range(count):
            directory = f"Tree/dir-{d:03}"
            directories.append(directory)
            for i in range(each):
                add(f"{directory}/file-{i:05}.bin", size, first + d * each + i)
    if profile in ("firmware", "fragment5g"):
        directories.append("Frag")
        pairs = 256 if profile == "firmware" else 1024
        for i in range(pairs):
            add(f"Frag/keep-{i:05}.bin", 65536, 0x20000000 + i)
        add("Frag/fragmented.bin", LARGE_BYTES if profile == "fragment5g" else pairs * 65536, 0x30000000)
    if profile == "firmware":
        directories.append("Scratch")
    return dict(files=files, directories=directories)


def save(path: Path, value):
    with api.checked(path).open("x", encoding="utf-8", newline="\n") as output:
        json.dump(value, output, ensure_ascii=False, separators=(",", ":"))
        output.write("\n")


def portable_environment(case: Path):
    runtime = api.checked(case / "host-runtime")
    runtime.mkdir(exist_ok=True)
    result = dict(os.environ)
    for name in ("APPDATA", "LOCALAPPDATA", "TMP", "TEMP"):
        result[name] = str(runtime)
    return result


def prepare(case: Path, profile: str):
    case = api.checked(case)
    if case.exists():
        raise FileExistsError("Never overwrite a previous scaling case")
    # The raw writer + two fixed VHDs must leave the independent100GiB reserve.
    size = IMAGE_BYTES[profile]
    if shutil.disk_usage(api.ROOT).free < 100 * 1024**3 + 3 * size:
        raise ValueError("Scale case would violate the100GiB reserve")
    case.mkdir(parents=True)
    environment = portable_environment(case)
    base = case / "blank-base.qcow2"
    cow = case / "fresh-test-cow.qcow2"
    image = case / "target.raw"
    commands = [
        [str(api.QEMU / "qemu-img.exe"), "create", "-f", "qcow2", str(base), str(size)],
        [str(api.QEMU / "qemu-img.exe"), "create", "-f", "qcow2", "-F", "qcow2", "-b", str(base), str(cow)],
        [str(api.QEMU / "qemu-img.exe"), "convert", "-f", "qcow2", "-O", "raw", str(cow), str(image)],
    ]
    for command in commands:
        subprocess.run(command, check=True, capture_output=True, env=environment)
    expected = manifest(profile)
    save(case / "manifest.json", expected)
    save(case / "prepared.json", dict(profile=profile, image_bytes=size,
         immutable_base_sha256=api.hash_file(base), fresh_cow_sha256=api.hash_file(cow),
         files=len(expected["files"]), directories=len(expected["directories"]),
         data_bytes=sum(row["size"] for row in expected["files"].values()),
         commands=commands, image_only=True, installer_not_executed=True))
    base.chmod(stat.S_IREAD)


def run(case: Path, writer: Path, timeout: int):
    case = api.checked(case)
    prepared = json.loads((case / "prepared.json").read_text("utf-8"))
    if (case / "completed.json").exists():
        raise FileExistsError("A completed test is immutable; create a fresh case")
    command = [str(writer), str(case / "target.raw"), "gpt", prepared["profile"],
               "--image-only", "--workspace", str(api.ROOT)]
    started = time.monotonic()
    with (case / "writer.log").open("xb") as output:
        try:
            result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT,
                    env=portable_environment(case), timeout=timeout,
                    creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            code, timed_out = result.returncode, False
        except subprocess.TimeoutExpired:
            code, timed_out = None, True
    text = (case / "writer.log").read_text("utf-8", errors="replace")
    peaks = re.findall(r"HOST SCALE complete profile=\w+ current=0 peak=(\d+)", text)
    passed = code == 0 and not timed_out and len(peaks) == 1 and "USOSPREP SCALE PASS" in text
    if api.hash_file(case / "blank-base.qcow2") != prepared["immutable_base_sha256"]:
        passed = False
    image = case / "target.raw"
    image.chmod(stat.S_IREAD)
    receipt = dict(application_pass=passed, returncode=code, timeout=timed_out,
                   elapsed_seconds=time.monotonic()-started, command=command,
                   allocator_peak=int(peaks[0]) if len(peaks)==1 else None,
                   image_bytes=image.stat().st_size, raw_sha256=api.hash_file(image),
                   writer_sha256=api.hash_file(writer), writer_log_sha256=api.hash_file(case / "writer.log"),
                   host_regular_file_backend=True, firmware_test=False)
    save(case / "completed.json", receipt)
    if not passed:
        raise RuntimeError("Scale workload failed; see closed writer.log")
    return receipt


def verify(case: Path, timeout: int):
    case = api.checked(case)
    prepared = json.loads((case / "prepared.json").read_text("utf-8"))
    completed = json.loads((case / "completed.json").read_text("utf-8"))
    if completed.get("application_pass") is not True:
        raise ValueError("A closed passing writer run is required")
    out = case / "windows"
    if out.exists():
        raise FileExistsError("Never overwrite an earlier Windows check")
    shell = shutil.which("pwsh.exe")
    if shell is None:
        raise ValueError("PowerShell7 is required")
    command = [shell, "-NoLogo", "-NoProfile", "-File",
        str(REPO / "tools/tests/minios_chkdsk_readonly.ps1"), "-Workspace", str(api.ROOT),
        "-RawCopy", str(case / "target.raw"), "-ExpectedImageBytes", str(prepared["image_bytes"]),
        "-ExpectedSha256", completed["raw_sha256"], "-QemuImg", str(api.QEMU / "qemu-img.exe"),
        "-Out", str(out), "-ExpectedManifest", str(case / "manifest.json"),
        "-CheckTimeoutSeconds", str(timeout)]
    started = time.monotonic()
    # No outer kill: the PS finally must remove its exact alias/dismount its VHD.
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env=portable_environment(case), creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    while True:
        try:
            stdout, stderr = process.communicate()
            break
        except KeyboardInterrupt:
            continue
    (case / "windows-stdout.txt").write_bytes(stdout)
    (case / "windows-stderr.txt").write_bytes(stderr)
    record = dict(returncode=process.returncode, elapsed_seconds=time.monotonic()-started,
                  command=command, result="windows/result.json")
    save(case / "windows-invocation.json", record)
    if process.returncode:
        raise RuntimeError("Read-only Windows acceptance failed")
    value = json.loads((out / "result.json").read_text("utf-8"))
    if not (value.get("passed") and value.get("readonly_chkdsk_pass") and value.get("readonly_file_tree_pass")
            and value.get("chkdsk_exit") == 0 and value.get("chkdsk_target_guard", {}).get("passed")
            and value.get("dismounted") and value.get("temporary_dos_alias_removed")):
        raise ValueError("Incomplete read-only/size/file-data acceptance")
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "run", "verify"))
    parser.add_argument("case", type=Path)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--qemu-dir", type=Path, required=True)
    parser.add_argument("--profile", choices=tuple(IMAGE_BYTES))
    parser.add_argument("--writer", type=Path)
    parser.add_argument("--timeout", type=int, default=3500)
    args = parser.parse_args()
    api.configure(args.workspace, args.qemu_dir)
    if not 60 <= args.timeout <= 3600:
        parser.error("timeout must be60..3600seconds")
    if args.action == "prepare":
        if args.profile is None:
            parser.error("prepare requires profile")
        prepare(args.case, args.profile)
    elif args.action == "run":
        if args.writer is None or not args.writer.is_file():
            parser.error("run requires a built regular-file writer")
        print(json.dumps(run(args.case, args.writer, args.timeout)))
    else:
        print(json.dumps(verify(args.case, args.timeout)))


if __name__ == "__main__":
    main()
