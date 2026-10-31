"""MiniOS 1b-1: one closed-image scaling run on each firmware architecture.

Uses generated guest sources, fresh qcow2 overlays and the independent
Linux/Windows read-only oracles. No live status probes, QMP, physical disks,
reinstallation or automatic retries. Existing 1a cases are never reopened.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import struct


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
api = load("scale_firmware_api", HERE / "uefi_case.py")
verification = load("scale_firmware_verification", HERE / "verify_case.py")


def program_footprint(program: Path, architecture: str, bios_elf: Path) -> dict:
    if architecture != "bios":
        image = program.read_bytes()
        if len(image) < 64 or image[:2] != b"MZ":
            raise ValueError("Expected a real PE/COFF EFI artifact")
        pe = struct.unpack_from("<I", image, 60)[0]
        if pe + 84 > len(image) or image[pe:pe + 4] != b"PE\0\0":
            raise ValueError("Invalid EFI PE header")
        optional = pe + 24
        magic = struct.unpack_from("<H", image, optional)[0]
        if magic not in (0x10b, 0x20b):
            raise ValueError("Unsupported EFI optional header")
        size = struct.unpack_from("<I", image, optional + 56)[0]
        if size == 0:
            raise ValueError("Missing loaded EFI image size")
        return {"artifact_sha256": api.hash_file(program), "loaded_image_bytes": size,
                "image_format": "PE32+" if magic == 0x20b else "PE32",
                "own_stack_bytes": 1024 * 1024, "own_stack_already_in_allocator_peak": True,
                "untracked_entry_stack_budget_bytes": 4096,
                "firmware_allocations_included": False}
    image = bios_elf.read_bytes()
    if image[:6] != b"\x7fELF\x01\x01" or len(image) < 52:
        raise ValueError("Expected the actual linked ELF32 BIOS artifact")
    section_offset = struct.unpack_from("<I", image, 32)[0]
    section_size, section_count = struct.unpack_from("<HH", image, 46)
    if section_size < 40 or section_offset + section_size * section_count > len(image):
        raise ValueError("Invalid BIOS ELF section table")
    allocated = []
    boot_image = program.read_bytes()
    slot = 64 * 512
    if boot_image[slot:slot + 8] != b"USOSCORE":
        raise ValueError("Missing actual BIOS slot header")
    payload_offset, payload_bytes, load_address = struct.unpack_from("<III", boot_image, slot + 24)
    if load_address != 0x20000 or payload_offset != 16384 or payload_bytes == 0:
        raise ValueError("Unexpected BIOS payload layout")
    payload = boot_image[slot + payload_offset:slot + payload_offset + payload_bytes]
    if len(payload) != payload_bytes:
        raise ValueError("Short BIOS payload")
    for index in range(section_count):
        section = section_offset + index * section_size
        kind, flags, address, file_offset, size = struct.unpack_from("<IIIII", image, section + 4)
        if flags & 2 and size:
            if address < 0x20000 or address + size > 0x60000:
                raise ValueError("BIOS loaded section escapes its existing low-memory region")
            allocated.append({"type": kind, "address": address, "bytes": size})
            if kind != 8:
                payload_start = address - load_address
                if image[file_offset:file_offset + size] != payload[payload_start:payload_start + size]:
                    raise ValueError("Linked ELF does not match the BIOS payload used by QEMU")
    if not allocated:
        raise ValueError("BIOS ELF contains no allocated sections")
    return {"artifact_sha256": api.hash_file(program), "linked_elf_sha256": api.hash_file(bios_elf),
            "payload_sha256": hashlib.sha256(payload).hexdigest(), "linked_elf_matches_payload": True,
            "loaded_image_bytes": max(row["address"] + row["bytes"] for row in allocated) - 0x20000,
            "allocated_sections": allocated, "image_format": "ELF32 flat BIOS payload",
            "own_stack_reserved_bytes": 0x9e000 - 0x60000,
            "thunk_and_bootstrap_low_memory_budget_bytes": 128 * 1024,
            "own_stack_already_in_allocator_peak": False,
            "firmware_allocations_included": False}


def windows_acceptance(record: dict, returncode: int, image_bytes: int) -> bool:
    guard = record.get("chkdsk_target_guard", {})
    return (returncode == 0 and record.get("kind") == "windows-readonly-chkdsk"
            and record.get("passed") is True and record.get("readonly_chkdsk_pass") is True
            and record.get("readonly_file_tree_pass") is True and record.get("chkdsk_issued") is True
            and record.get("chkdsk_exit") == 0 and record.get("chkdsk_flags") == []
            and record.get("repair_flags_used") is False and record.get("access") == "ReadOnly"
            and guard.get("passed") is True and guard.get("readonly") is True
            and guard.get("expected_image_bytes") == image_bytes and guard.get("actual_disk_bytes") == image_bytes
            and guard.get("system") is False and guard.get("boot") is False)


def verify_closed_windows(case: Path, oracle: Path, timeout: int, memory: int = 64,
                          attempt: int = 1, reuse_export: bool = False) -> dict:
    """CHKDSK and exact tree/SHA through Windows; no extra TCG oracle boot."""
    if attempt < 1 or attempt > 9 or (reuse_export and attempt == 1):
        raise ValueError("An explicit new oracle attempt is required for a closed export")
    if reuse_export:
        source = verification.oracle_path(oracle / "inputs" / case.name)
        exported = json.loads((source / "export.json").read_text())
        raw, manifest, digest = source / "target.raw", source / "manifest.json", exported["raw_sha256"]
        if exported["chain_before"] != exported["chain_after"] or exported.get("raw_readonly") is not True:
            raise ValueError("Closed source export was not preserved")
        with verification.read_lock(raw):
            if api.hash_file(raw) != digest or api.hash_file(manifest) != exported["manifest_sha256"]:
                raise ValueError("Closed export or manifest changed before oracle-only resume")
    else:
        raw, digest, manifest = verification.export(case, memory)
    output = verification.oracle_path(oracle / (case.name + f"-windows{attempt:02d}"))
    shell = shutil.which("pwsh.exe")
    if shell is None:
        raise ValueError("The guarded Windows oracle requires PowerShell7")
    args = [shell, "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
            str(REPO / "tools/tests/minios_chkdsk_readonly.ps1"),
            "-Workspace", str(oracle), "-RawCopy", str(raw),
            "-ExpectedImageBytes", str(raw.stat().st_size), "-ExpectedSha256", digest,
            "-QemuImg", str(api.QEMU / "qemu-img.exe"), "-Out", str(output),
            "-ExpectedManifest", str(manifest), "-CheckTimeoutSeconds", str(timeout)]
    invocation = raw.parent / ("windows-invocation.json" if attempt == 1 else f"windows-invocation{attempt:02d}.json")
    if invocation.exists():
        raise ValueError("Never overwrite an earlier oracle invocation receipt")
    process = verification.wait_owned(args)
    verification.write_json(invocation, {
        "command": args, "returncode": process.returncode,
        "stdout": process.stdout, "stderr": process.stderr})
    result_path = output / "result.json"
    if not result_path.is_file():
        raise ValueError("Windows oracle stopped before producing its receipt; inspect the preserved invocation")
    checked = json.loads(result_path.read_text())
    result = {"case": case.name, "image_sha256": digest,
              "windows_result": str(output / "result.json"),
              "windows_invocation": str(invocation),
              "windows_files_and_chkdsk_pass": windows_acceptance(checked, process.returncode, raw.stat().st_size),
              "linux_full_tree_run": False,
              "linux_omission_reason": "Windows independently checks exact file bytes and read-only CHKDSK; no per-file TCG shell overhead"}
    result["independent_structure_pass"] = False
    if result["windows_files_and_chkdsk_pass"]:
        expected = json.loads(manifest.read_text())
        inspector = load("firmware_independent_ntfs", HERE / "inspect_ntfs.py")
        with verification.read_lock(raw):
            before = api.hash_file(raw)
            inspected = inspector.Image(raw)
            try: metadata = inspected.evidence()
            finally: inspected.file.close()
            if before != digest or api.hash_file(raw) != digest:
                raise ValueError("Accepted raw image changed during independent metadata inspection")
        verification.write_json(raw.parent / "metadata-inspection.json", metadata)
        fragments = metadata["fragmented_files"]
        base_structure = (
            metadata["mft_records"] > 8192 and metadata["mft_runs"] >= 2 and metadata["mft_physical_extent_count"] >= 2
            and metadata["mft_mirror_equal"] is True and metadata["files"] == len(expected["files"])
            and metadata["directories"] == len(expected["directories"]))
        prepared = json.loads((case / "prepared.json").read_text())
        result["independent_structure_pass"] = base_structure and (
            (prepared.get("profile") == "scale-tree150k" and metadata["files"] == 150000 and not fragments)
            or (prepared.get("profile") != "scale-tree150k"
            and len(fragments) == 1 and fragments[0]["run_count"] >= 100 and fragments[0]["physical_extent_count"] >= 100
            and fragments[0]["attribute_list"] is True and fragments[0]["extension_records"] > 0
            and fragments[0]["size"] == expected["files"]["Frag/fragmented.bin"]["size"]))
    verification.write_json(raw.parent / "verification.json", result)
    return result


def summarize(case: Path) -> dict:
    """Read only completed evidence; this function never examines a live guest."""
    prepared = json.loads((case / "prepared.json").read_text())
    receipt = json.loads((case / "run-64m" / "completed.json").read_text())
    expected = json.loads((case / "manifest.json").read_text())
    log = (case / "run-64m" / "USOSPREP.LOG").read_text(errors="replace")
    if prepared.get("profile") != "scale-firmware" or receipt.get("application_pass") is not True:
        raise ValueError("Only the new completed firmware scaling profile can be summarized")
    if "USOSPREP SCALE PASS" not in log:
        raise ValueError("Missing scaling workload completion marker")
    footprint = json.loads((case / "program-footprint.json").read_text())
    peaks = [int(value) for value in re.findall(r"(?:alloc_peak|\bpeak)=(\d+)", log)]
    if not peaks:
        raise ValueError("Completed workload did not report allocator peak")
    memory_upper_bound = max(peaks) + footprint["loaded_image_bytes"]
    heap = None
    if footprint["own_stack_already_in_allocator_peak"]:
        memory_upper_bound += footprint["untracked_entry_stack_budget_bytes"]
    else:
        backing = re.findall(r"HEAP physical_current=(\d+) physical_peak=(\d+) extent_peak=(\d+) reserved=(\d+)", log)
        if len(backing) != 1:
            raise ValueError("BIOS must report the real coalescing heap reserve and physical high-water metrics")
        current, peak, extent, reserved = map(int, backing[0])
        if current != 0 or not max(peaks) <= peak <= reserved or not peak <= extent <= reserved:
            raise ValueError("Inconsistent BIOS physical heap accounting")
        heap = {"physical_current_bytes": current, "physical_peak_bytes": peak,
                "extent_peak_bytes": extent, "reserved_bytes": reserved,
                "arbitrary_order_free": True}
        # Count the ENTIRE reserved BIOS arena, not just requested live bytes.
        memory_upper_bound = reserved + footprint["loaded_image_bytes"]
        memory_upper_bound += footprint["own_stack_reserved_bytes"] + footprint["thunk_and_bootstrap_low_memory_budget_bytes"]
    if memory_upper_bound > 16 * 1024 * 1024:
        raise ValueError("Conservative program RAM exceeds the16MiB scaling goal")
    return {
        "case": case.name, "architecture": prepared["arch"],
        "partition_kind": prepared["kind"], "memory_mib": 64,
        "profile": "firmware", "expected_files": len(expected["files"]),
        "expected_directories": len(expected["directories"]),
        "expected_bytes": sum(value["size"] for value in expected["files"].values()),
        "elapsed_seconds": receipt["elapsed_seconds"],
        "program_footprint": footprint, "allocator_peak_bytes": max(peaks),
        "program_ram_conservative_upper_bound_bytes": memory_upper_bound,
        "physical_heap": heap,
        "program_memory_evidence": [line for line in log.splitlines() if any(
            marker in line for marker in ("MEM ", "alloc_peak=", " peak=", "STACK "))],
        "qemu_only": True,
    }


def run_suite(workspace: Path, qemu: Path, source: Path, artifacts: Path,
              architectures: tuple[str, ...], kind: str, timeout: int,
              verify: bool, bios_elf: Path | None = None) -> dict:
    workspace = workspace.resolve()
    cases = workspace / "cases"
    oracle = workspace / "oracle"
    api.configure(cases, qemu)
    verification.configure(cases, oracle, qemu, source)
    workspace.mkdir(parents=True, exist_ok=True)
    if timeout < 60 or timeout > 1800:
        raise ValueError("Firmware scaling timeout must stay between60 and1800 seconds")
    results = []
    for arch in architectures:
        if arch not in ("x86_64", "ia32", "bios"):
            raise ValueError("Unknown firmware architecture")
        case = api.checked(cases / f"scale-{arch}-{kind}")
        program = artifacts / ("usosprep-bios.img" if arch == "bios" else f"usosprep-{arch}.efi")
        footprint = program_footprint(program, arch, bios_elf or REPO / "zig-out/minios-bios/prep.elf")
        api.prepare(case, arch, kind, program, 2 * 1024**3, profile="scale-firmware")
        api.save(case / "program-footprint.json", footprint)
        if not api.execute(case, 64, timeout):
            raise ValueError("Firmware scaling failed: " + case.name)
        result = summarize(case)
        if verify:
            checked = verify_closed_windows(case, oracle, 1800)
            result["verification"] = checked
            if not checked["windows_files_and_chkdsk_pass"] or not checked["independent_structure_pass"]:
                raise ValueError("Independent scaling verification failed: " + case.name)
        else:
            result["verification"] = None
            result["acceptance_pass"] = False
        results.append(result)
        print(json.dumps(result), flush=True)
    result = {
        "qemu_only": True, "profile": "firmware", "cases": results,
        "all_three_architectures": set(architectures) == {"x86_64", "ia32", "bios"},
        "acceptance_pass": verify and set(architectures) == {"x86_64", "ia32", "bios"} and len(results) == 3,
    }
    oracle.mkdir(parents=True, exist_ok=True)
    verification.write_json(oracle / "scale-firmware-completed.json", result)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--qemu-dir", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--artifact-dir", type=Path, default=REPO / "zig-out/test-assets")
    parser.add_argument("--bios-elf", type=Path, default=REPO / "zig-out/minios-bios/prep.elf")
    parser.add_argument("--arch", choices=("all", "x86_64", "ia32", "bios"), default="all")
    parser.add_argument("--kind", choices=("gpt", "mbr"), default="gpt")
    parser.add_argument("--timeout", type=int, default=1800)
    parser.add_argument("--firmware-only", action="store_true", help="Diagnostic run; cannot satisfy independent acceptance")
    args = parser.parse_args()
    architectures = ("x86_64", "ia32", "bios") if args.arch == "all" else (args.arch,)
    result = run_suite(args.workspace, args.qemu_dir, args.source_root, args.artifact_dir,
                       architectures, args.kind, args.timeout, not args.firmware_only, args.bios_elf)
    print(json.dumps({"cases": len(result["cases"]), "acceptance_pass": result["acceptance_pass"]}))


if __name__ == "__main__":
    main()
