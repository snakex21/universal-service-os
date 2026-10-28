"""Read-only receipts and exact path guards for the new1b-1 runtime only."""
from __future__ import annotations
import hashlib
import importlib.util
import json
import os
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("scale_runtime_firmware", HERE / "scale_firmware_case.py")
firmware = importlib.util.module_from_spec(spec)
spec.loader.exec_module(firmware)
PROFILES = {"tree150k", "single50k", "fragment5g"}
ARCHITECTURES = {"x86_64", "ia32", "bios"}


def guarded(root: Path, path: Path, allow_root: bool = False) -> Path:
    root = Path(os.path.abspath(root))
    if root == Path(root.anchor) or not root.is_absolute() or str(root).startswith("\\\\"):
        raise ValueError("Explicit local runtime directory required")
    if any(char in str(path) for char in ",\r\n\0") or not path.is_absolute() or ".." in path.parts:
        raise ValueError("Invalid owned runtime path")
    path = Path(os.path.abspath(path))
    if not path.is_relative_to(root) or (path == root and not allow_root):
        raise ValueError("Path escapes the exact1b-1 runtime")
    for node in (path, *path.parents):
        if node.exists():
            info = node.lstat()
            if node.is_symlink() or getattr(info, "st_file_attributes", 0) & 0x400:
                raise ValueError("Reparse/symlink path refused")
    return path


def read(root: Path, path: Path):
    return json.loads(guarded(root, path).read_text(encoding="utf-8-sig"))


def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while data := source.read(1024 * 1024): digest.update(data)
    return digest.hexdigest()


def artifact(root: Path, path: Path) -> dict:
    path = guarded(root, path)
    return {"path": path.relative_to(root).as_posix(), "bytes": path.stat().st_size, "sha256": sha(path)}


def validate_structure(value: dict, profile: str, expected: dict):
    if (value.get("kind") != "independent-readonly-NTFS-byte-inspection"
        or value.get("mft_mirror_equal") is not True or value.get("files") != len(expected["files"])
        or value.get("directories") != len(expected["directories"])):
        raise ValueError("Independent NTFS record counts/mirror differ")
    if profile in ("firmware", "tree150k", "single50k"):
        if (value.get("mft_records", 0) <= 8192 or value.get("mft_runs", 0) < 2
            or value.get("mft_physical_extent_count", 0) < 2):
            raise ValueError("Independent image lacks required grown/fragmented MFT")
    if profile in ("firmware", "fragment5g"):
        fragments = value.get("fragmented_files", [])
        if (len(fragments) != 1 or fragments[0].get("run_count", 0) < 100
            or fragments[0].get("physical_extent_count", 0) < 100
            or fragments[0].get("attribute_list") is not True or fragments[0].get("extension_records", 0) == 0
            or fragments[0].get("size") != expected["files"]["Frag/fragmented.bin"]["size"]):
            raise ValueError("Independent image lacks the real fragmented/ATTRIBUTE_LIST file")
        if profile == "fragment5g" and fragments[0]["size"] != 5 * 1024**3:
            raise ValueError("Independent large file is not exactly5GiB")


def validated_case(root: Path, case: Path, firmware_case: bool) -> dict:
    case = guarded(root, case)
    prepared = read(root, case / "prepared.json")
    expected = read(root, case / "manifest.json")
    if set(expected) != {"files", "directories"}:
        raise ValueError("Unexpected exact-file manifest schema")
    if firmware_case:
        if prepared.get("profile") != "scale-firmware" or prepared.get("qemu_only") is not True:
            raise ValueError("Not an owned1b-1 firmware case")
        if prepared.get("arch") not in ARCHITECTURES or case.parent.name != "cases":
            raise ValueError("Unexpected firmware case layout")
        run = case / "run-64m"
        completed = read(root, run / "completed.json")
        if completed.get("application_pass") is not True or completed.get("returncode") != 33:
            raise ValueError("A closed passing firmware case is required")
        oracle = guarded(root, case.parent.parent / "oracle")
        windows = oracle / (case.name + "-windows01")
        windows_invocation = oracle / "inputs" / case.name / "windows-invocation.json"
        invocation = read(root, windows_invocation)
        image_bytes = prepared["size"]
        log = run / "USOSPREP.LOG"
        profile = "firmware"
        image = oracle / "inputs" / case.name / "target.raw"
        exported = read(root, image.parent / "export.json")
        if exported["chain_before"] != exported["chain_after"]:
            raise ValueError("Firmware source chain changed")
        raw_digest = exported["raw_sha256"]
        verified = read(root, image.parent / "verification.json")
        if verified.get("independent_structure_pass") is not True or verified.get("windows_files_and_chkdsk_pass") is not True:
            raise ValueError("Firmware independent verification did not complete")
        structure_path = image.parent / "metadata-inspection.json"
    else:
        if prepared.get("image_only") is not True or prepared.get("profile") not in PROFILES:
            raise ValueError("Not an owned1b-1 host case")
        completed = read(root, case / "completed.json")
        if completed.get("application_pass") is not True or completed.get("returncode") != 0:
            raise ValueError("A closed passing host writer is required")
        windows = case / "windows"
        windows_invocation = case / "windows-invocation.json"
        invocation = read(root, windows_invocation)
        image_bytes = prepared["image_bytes"]
        log = case / "writer.log"
        profile = prepared["profile"]
        image = case / "target.raw"
        raw_digest = completed["raw_sha256"]
        structure_path = case / "structure.json"
    win = read(root, windows / "result.json")
    if not firmware.windows_acceptance(win, invocation["returncode"], image_bytes):
        raise ValueError("CHKDSK/exact virtual-disk guard did not pass")
    if (win.get("dismounted") is not True or win.get("temporary_dos_alias_removed") is not True
        or win.get("source_sha256_before") != raw_digest or win.get("source_sha256_after") != raw_digest
        or win.get("vhd_sha256_before") != win.get("vhd_sha256_after")):
        raise ValueError("Windows source stability/detach/alias cleanup is unproven")
    tree = win["file_tree"]
    actual = {row["path"]: {"size": row["size"], "sha256": row["sha256"]} for row in tree["files"]}
    if len(actual) != len(tree["files"]) or actual != expected["files"]:
        raise ValueError("Exact file-byte manifest differs")
    if len(set(tree["directories"])) != len(tree["directories"]) or set(tree["directories"]) != set(expected["directories"]):
        raise ValueError("Exact directory manifest differs")
    text = guarded(root, log).read_text(encoding="utf-8", errors="strict")
    if "USOSPREP SCALE PASS" not in text:
        raise ValueError("Missing completed scaling workload marker")
    structure = read(root, structure_path)
    validate_structure(structure, profile, expected)
    return {"case": case, "firmware": firmware_case, "profile": profile, "prepared": prepared,
            "completed": completed, "windows": win, "windows_dir": windows,
            "windows_invocation": windows_invocation, "manifest": expected,
            "log": log, "image": image, "image_bytes": image_bytes, "image_sha256": raw_digest,
            "text": text, "structure": structure, "structure_path": structure_path}


def add_arguments(parser):
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--host-case", type=Path, action="append", default=[])
    parser.add_argument("--firmware-case", type=Path, action="append", default=[])


def cases(root: Path, host: list[Path], firmware_cases: list[Path]) -> list[dict]:
    guarded(root, root, allow_root=True)
    if not root.name.startswith("minios-1b1-"):
        raise ValueError("Only a separately named new1b-1 runtime can be collected or cleaned")
    paths = [str(path).casefold() for path in host + firmware_cases]
    if len(set(paths)) != len(paths):
        raise ValueError("Duplicate case selection")
    if not paths:
        raise ValueError("Explicit completed1b-1 case selections required")
    return ([validated_case(root, case, False) for case in host]
            + [validated_case(root, case, True) for case in firmware_cases])
