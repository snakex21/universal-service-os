#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Create only own-data WIM fixtures with the pinned, host-only wimlib oracle.

All output stays in a fresh synthetic runtime child, is retained, and never
contains Windows files. Processes use completion waits, not progress polling.
Capture options: https://wimlib.net/man1/wimcapture.html (wimlib 1.14.5).
"""
from __future__ import annotations

import argparse
import ctypes as C
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import random
import stat
import struct

_spec = importlib.util.spec_from_file_location("fixture_wim_oracle", Path(__file__).with_name("wim_oracle.py"))
oracle = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(oracle)
MiB = 1024**2


def output_guard(out: Path) -> Path:
    oracle.owned(out)
    root = oracle.RUNTIME / "synthetic"
    if out == root or not out.is_relative_to(root):
        raise ValueError("Select a fresh child of the synthetic runtime")
    if out.exists():
        raise FileExistsError("Never replace or clean previous fixture evidence")
    return out


def payload(size: int, mode: str, seed: int):
    """Streaming deterministic own bytes; the largest temporary block is 64KiB."""
    generator = random.Random(seed)
    pattern = hashlib.sha256(struct.pack("<Q", seed)).digest() * 2048
    while size:
        count = min(size, 65536)
        yield generator.randbytes(count) if mode == "random" else pattern[:count]
        size -= count


def set_times(path: Path, number: int) -> None:
    """Exact own creation/write/access times, including 100ns fractions."""
    if os.name != "nt":
        return  # Portable unit tests do not claim native NTFS timestamps.
    kernel = C.WinDLL("kernel32", use_last_error=True)
    kernel.CreateFileW.argtypes = [C.c_wchar_p, C.c_uint32, C.c_uint32, C.c_void_p, C.c_uint32, C.c_uint32, C.c_void_p]
    kernel.CreateFileW.restype = C.c_void_p
    kernel.SetFileTime.argtypes = [C.c_void_p, C.c_void_p, C.c_void_p, C.c_void_p]
    kernel.CloseHandle.argtypes = [C.c_void_p]
    handle = kernel.CreateFileW(str(path), 0x100, 7, None, 3, 0x02000000, None)
    if handle == C.c_void_p(-1).value:
        raise C.WinError(C.get_last_error())
    try:
        base = 133485408000000000 + number * 1111111
        creation, write, access = C.c_uint64(base + 11), C.c_uint64(base + 22), C.c_uint64(base + 33)
        if not kernel.SetFileTime(handle, C.byref(creation), C.byref(access), C.byref(write)):
            raise C.WinError(C.get_last_error())
    finally:
        kernel.CloseHandle(handle)


def source_specs(*, count: int = 384, large: bool = True, second: bool = False,
                 large_file_bytes: int = 0) -> list[tuple]:
    if type(count) is not int or not 1 <= count <= 4096:
        raise ValueError("Bounded explicit own-file count required")
    if type(large_file_bytes) is not int or (large_file_bytes != 0 and not 100 * MiB < large_file_bytes <= 192 * MiB):
        raise ValueError("Large gate must be greater than100MiB and at most192MiB")
    specs = [(f"Batch-{i % 16:02d}/item-{i:04d}.dat", 512 + (i * 37) % 4096,
              "random" if i % 3 == 0 else "repeat", 0x554F5300 + i) for i in range(count)]
    specs.extend([
        ("zero.bin", 0, "repeat", 0),
        ("Zażółć_日本語_Ω/Zażółć gęślą jaźń.txt", 4095, "repeat", 11),
        ("Zażółć_日本語_Ω/astral-🚀.txt", 4097, "random", 12),
        ("Zażółć_日本語_Ω/" + "ł" * 180 + ".dat", 16003, "repeat", 13),
    ])
    if large:
        specs.extend([("compressible-4MiB.bin", 4 * MiB + 123, "repeat", 21),
                      ("random-3MiB.bin", 3 * MiB + 17, "random", 22)])
    if large_file_bytes:
        specs.append(("compressible-128MiB.bin", large_file_bytes, "repeat", 0x128))
    marker = "image2-only.txt" if second else "image1-only.txt"
    specs.append((marker, 257 if second else 259, "repeat", 32 if second else 31))
    return specs


def write_ads(destination: Path) -> list[dict]:
    """Explicit NTFS named streams, only on our freshly generated regular file."""
    oracle.owned(destination)
    if os.name != "nt" or not destination.is_file() or destination.stat().st_nlink != 1:
        raise ValueError("ADS fixture requires one unshared own NTFS file on Windows")
    kernel = C.WinDLL("kernel32", use_last_error=True)
    filesystem = C.create_unicode_buffer(32)
    kernel.GetVolumeInformationW.argtypes = [C.c_wchar_p, C.c_wchar_p, C.c_uint32, C.c_void_p,
                                           C.c_void_p, C.c_void_p, C.c_wchar_p, C.c_uint32]
    if not kernel.GetVolumeInformationW(str(destination.anchor), None, 0, None, None, None, filesystem, len(filesystem)):
        raise C.WinError(C.get_last_error())
    if filesystem.value.upper() != "NTFS":
        raise ValueError("ADS fixture requires the host NTFS filesystem")
    result = []
    for name, size, seed in (("Zone.Identifier", 37, 0x51), ("large-世界", 196609, 0x52)):
        sha1, sha256 = hashlib.sha1(), hashlib.sha256()
        # The base path already passed owned/reparse/hardlink guards. Stream
        # names are fixed components, never caller-provided device/ADS paths.
        with open(str(destination) + ":" + name, "xb") as stream:
            for block in payload(size, "repeat", seed):
                stream.write(block); sha1.update(block); sha256.update(block)
        result.append({"name": name, "size": size, "sha1": sha1.hexdigest(), "sha256": sha256.hexdigest()})
    return result


def write_source(root: Path, *, count: int = 384, large: bool = True, second: bool = False,
                 large_file_bytes: int = 0, ads: bool = False) -> dict:
    specs = source_specs(count=count, large=large, second=second, large_file_bytes=large_file_bytes)
    root.mkdir()  # Never update an existing source tree.
    files = []
    for name, size, mode, seed in specs:
        destination = root / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        sha1, sha256 = hashlib.sha1(), hashlib.sha256()
        with destination.open("xb") as stream:
            for block in payload(size, mode, seed):
                stream.write(block); sha1.update(block); sha256.update(block)
        files.append({"path": name, "size": size, "sha1": sha1.hexdigest(), "sha256": sha256.hexdigest()})
    if ads:
        selected = next(row for row in files if row["path"].endswith("Zażółć gęślą jaźń.txt"))
        selected["named_streams"] = write_ads(root / selected["path"])
    (root / "Empty/Subempty").mkdir(parents=True)
    directories = [root, *(p for p in root.rglob("*") if p.is_dir())]
    for number, path in enumerate([*(root / r["path"] for r in files), *sorted(directories)]):
        set_times(path, number)
    return {"own_generated_data": True, "files": files, "file_count": len(files),
            "directory_count": len(directories), "logical_bytes": sum(row["size"] + sum(s["size"] for s in row.get("named_streams", [])) for row in files),
            "named_stream_count": sum(len(row.get("named_streams", [])) for row in files),
            "largest_file_bytes": max(row["size"] for row in files),
            "largest_buffer_bytes": 65536, "contains_windows_data": False}


def verify_source_tree(source: dict, tree: Path) -> None:
    """Compare capture names, zero files, lengths and SHA1 to independently made bytes."""
    rows = [json.loads(line) for line in tree.read_text(encoding="utf-8").splitlines()]
    found = {row["path"]: row for row in rows if not row["directory"]}
    expected = {row["path"]: row for row in source["files"]}
    if len(rows) != source["file_count"] + source["directory_count"] or set(found) != set(expected):
        raise ValueError("Captured own-data tree differs from generated names/counts")
    for name, own in expected.items():
        streams = found[name]["streams"]
        expected_streams = [{"name": None, "size": own["size"], "sha1": own["sha1"]}, *own.get("named_streams", [])]
        actual_streams = {stream["name"]: stream for stream in streams}
        if len(streams) != len(expected_streams) or set(actual_streams) != {s["name"] for s in expected_streams}:
            raise ValueError("Captured own-data length/stream differs: " + name)
        for stream in expected_streams:
            actual = actual_streams[stream["name"]]
            if actual["size"] != stream["size"]:
                raise ValueError("Captured own-data length/stream differs: " + name)
            # Empty WIM blobs conventionally use a zero hash, not SHA1(empty).
            if actual["sha1"] != (stream["sha1"] if stream["size"] else "0" * 40):
                raise ValueError("Captured own-data SHA1 differs: " + name)


def capture(case: Path, source: Path, kind: str, source_manifest: dict, *, solid=False, append=None) -> dict:
    case.mkdir()
    env = oracle.environment(case)
    wim = case / "install.wim"
    args = ["capture", str(source), str(wim), "USOS own image 1", "--threads=1", "--check",
            f"--compress={kind}:20", "--chunk-size=" + ("131072" if kind == "LZMS" else "32768")]
    if solid:
        args += ["--solid", "--solid-compress=LZMS:20", "--solid-chunk-size=131072"]
    oracle.run_cli(args, case, "capture", env)
    if append:
        oracle.run_cli(["append", str(append[0]), str(wim), "USOS own image 2", "--threads=1", "--check"], case, "append", env)
    wim.chmod(stat.S_IREAD)
    sha = oracle.digest(wim)
    with oracle.readonly(wim) as raw:
        header = oracle.read_header(raw)
    row = {"wim": str(wim), "bytes": wim.stat().st_size, "sha256": sha, "header": header,
           "own_generated_data": True, "solid": solid, "read_only_attribute": True}
    if solid:
        oracle.run_cli(["verify", str(wim)], case, "verify", env)
        row.update(expected="refuse_solid_before_target_writes", expected_images=[1])
    else:
        row["images"] = []
        for index, expected in [(1, source_manifest), *([(2, append[1])] if append else [])]:
            folder = case / f"oracle-image{index}"
            receipt = oracle.manifest(wim, index, sha, folder)
            verify_source_tree(expected, folder / "tree.jsonl")
            row["images"].append({"index": index, "tree": str(folder / "tree.jsonl"),
                                  "security": str(folder / "security.jsonl"), "manifest": str(folder / "manifest.json"),
                                  "counts": receipt["counts"], "own_bytes_vs_wimlib": "PASS"})
    oracle.save(case / "fixture.json", row)
    return row


def generate(out: Path, *, large_profile: bool = False, ads_profile: bool = False) -> dict:
    if type(large_profile) is not bool or type(ads_profile) is not bool or (large_profile and ads_profile):
        raise ValueError("Explicit large-profile flag required")
    output_guard(out)
    oracle.storage_guard((8 if ads_profile else 256) * MiB)
    oracle.tool_pins()
    out.mkdir(parents=True)
    source = write_source(out / "source-image1", count=1200 if large_profile else 3 if ads_profile else 384,
                          large=not ads_profile, ads=ads_profile,
                          large_file_bytes=128 * MiB + 123 if large_profile else 0)
    oracle.save(out / "source-image1.json", source)
    if ads_profile:
        cases = [capture(out / "xpress", out / "source-image1", "XPRESS", source)]
        result = {"schema": "usos-own-wim-fixtures-v1", "profile": "ads", "own_generated_data": True,
                  "source": str(out / "source-image1.json"), "source_file_count": source["file_count"],
                  "source_named_stream_count": source["named_stream_count"], "cases": cases,
                  "no_cleanup_performed": True, "physical_disks_or_mounts_used": False}
        oracle.save(out / "fixtures.json", result)
        return result
    if large_profile:
        cases = [capture(out / kind.lower(), out / "source-image1", kind, source) for kind in ("XPRESS", "LZX", "LZMS")]
        if source["file_count"] < 1000 or source["largest_file_bytes"] <= 100 * MiB:
            raise ValueError("Large workload requirement was not generated")
        if any(row["bytes"] > 64 * MiB for row in cases):
            raise ValueError("Own large-profile WIM exceeds bounded small-archive harness")
        result = {"schema": "usos-own-wim-fixtures-v1", "profile": "large",
                  "own_generated_data": True, "source": str(out / "source-image1.json"),
                  "source_file_count": source["file_count"], "source_largest_file_bytes": source["largest_file_bytes"],
                  "source_logical_bytes": source["logical_bytes"], "cases": cases,
                  "no_cleanup_performed": True, "physical_disks_or_mounts_used": False}
        oracle.save(out / "fixtures.json", result)
        return result
    second = write_source(out / "source-image2", count=7, large=False, second=True)
    oracle.save(out / "source-image2.json", second)
    cases = [capture(out / kind.lower(), out / "source-image1", kind, source) for kind in ("XPRESS", "LZX", "LZMS")]
    cases.append(capture(out / "multi-index", out / "source-image1", "XPRESS", source,
                         append=(out / "source-image2", second)))
    cases.append(capture(out / "solid-lzms-negative", out / "source-image1", "LZMS", source, solid=True))
    split = out / "split-negative"
    split.mkdir(); env = oracle.environment(split)
    oracle.run_cli(["split", cases[0]["wim"], str(split / "part.swm"), "1", "--check"], split, "split", env)
    parts = []
    for path in split.glob("*.swm"):
        with path.open("rb") as stream:
            header = stream.read(208)
        if len(header) != 208 or header[:8] != b"MSWIM\0\0\0":
            raise ValueError("Split oracle did not create complete WIM headers")
        number, total, images = struct.unpack_from("<HHI", header, 40)
        path.chmod(stat.S_IREAD)
        parts.append({"path": str(path), "sha256": oracle.digest(path), "bytes": path.stat().st_size,
                      "part": number, "total": total, "images": images})
    parts.sort(key=lambda row: row["part"])
    if len(parts) < 2 or any(row["part"] != i + 1 or row["total"] != len(parts) for i, row in enumerate(parts)):
        raise ValueError("Expected a genuine multi-part split negative fixture")
    result = {"schema": "usos-own-wim-fixtures-v1", "own_generated_data": True,
              "source": str(out / "source-image1.json"), "cases": cases,
              "split_negative": {"parts": parts, "expected": "refuse_split_before_target_writes"},
              "multi_index_negative": {"wim": cases[3]["wim"], "invalid_indices": [0, 3],
                                       "expected": "refuse_bad_index_before_target_writes"},
              "no_cleanup_performed": True, "physical_disks_or_mounts_used": False}
    oracle.save(out / "fixtures.json", result)
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    profiles = parser.add_mutually_exclusive_group()
    profiles.add_argument("--large", action="store_true", help="Three codecs, >=1200 own files and one128MiB file; no repeated header negatives")
    profiles.add_argument("--ads", action="store_true", help="Small XPRESS fixture with two real NTFS named streams")
    args = parser.parse_args()
    value = generate(args.out, large_profile=args.large, ads_profile=args.ads)
    print(json.dumps({"fixture_index": str(args.out / "fixtures.json"),
                      "cases": [{"wim": row["wim"], "bytes": row["bytes"], "sha256": row["sha256"]} for row in value["cases"]]}))
