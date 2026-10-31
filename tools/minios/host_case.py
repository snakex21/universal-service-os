"""Prepare an owned regular-file unit-test case, never a physical disk.

The immutable qcow2 base and a fresh COW precede every raw test artifact.
Actual firmware acceptance is performed separately by uefi_case.py.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import uefi_case as api
from uefi_case import checked, LARGE_SIZE, PATTERN, hash_file


def manifest(small_hash, large_hash):
    files = {f"Fixtures/item-{n:04}.txt": {"size": 64, "sha256": small_hash} for n in range(1000)}
    files["Fixtures/Nested/Zażółć-世界/Zażółć-gęślą-世界.txt"] = {"size": 64, "sha256": small_hash}
    files["Fixtures/Nested/" + "L" * 251 + ".txt"] = {"size": 64, "sha256": small_hash}
    files["Fixtures/Nested/empty.bin"] = {"size": 0, "sha256": hashlib.sha256(b"").hexdigest()}
    files["Fixtures/Nested/large.bin"] = {"size": LARGE_SIZE, "sha256": large_hash}
    files["Fixtures/Nested/supplied-security.bin"] = {"size": 64, "sha256": small_hash}
    return {"files": files, "directories": ["Fixtures", "Fixtures/Nested", "Fixtures/Nested/Zażółć-世界"]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("case", type=Path)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--qemu-dir", type=Path, required=True)
    args = parser.parse_args()
    api.configure(args.workspace, args.qemu_dir)
    case = checked(args.case)
    case.mkdir(parents=True, exist_ok=False)
    small = case / "small.bin"
    small.write_bytes(PATTERN[:64])
    large = case / "large.bin"
    with large.open("xb") as f:
        left = LARGE_SIZE
        while left:
            chunk = PATTERN[:min(left, len(PATTERN))]
            f.write(chunk)
            left -= len(chunk)
    qemu_img = str(api.QEMU / "qemu-img.exe")
    base = case / "blank-base.qcow2"
    subprocess.run([qemu_img, "create", "-f", "qcow2", str(base), "2G"], check=True)
    overlay = case / "host-cow.qcow2"
    subprocess.run([qemu_img, "create", "-f", "qcow2", "-F", "qcow2", "-b", str(base), str(overlay)], check=True)
    subprocess.run([qemu_img, "convert", "-f", "qcow2", "-O", "raw", str(overlay), str(case / "target.raw")], check=True)
    with (case / "manifest.json").open("x", encoding="utf-8", newline="\n") as f:
        json.dump(manifest(hash_file(small), hash_file(large)), f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(case)


if __name__ == "__main__":
    main()
