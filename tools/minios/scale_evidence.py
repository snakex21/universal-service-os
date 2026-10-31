"""Collect portable1b-1 acceptance evidence from completed host/firmware runs.

All exact invocations stay in the runtime and are referenced by SHA. The
published JSON contains relative evidence paths and no machine profile paths,
images, operating-system payloads or external dependency binaries.
"""
from __future__ import annotations
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import struct

spec = importlib.util.spec_from_file_location("evidence_scale_runtime", Path(__file__).with_name("scale_runtime.py"))
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)
REPO = Path(__file__).resolve().parents[2]


def assert_portable(value):
    """Published evidence must never include an absolute host/device path."""
    if isinstance(value, str):
        if re.search(r"(?:(?<![A-Za-z])[A-Za-z]:[\\/]|\\\\|\\\?\\)", value):
            raise ValueError("Absolute host/device path in portable evidence")
    elif isinstance(value, dict):
        for key, item in value.items():
            assert_portable(key); assert_portable(item)
    elif isinstance(value, (list, tuple)):
        for item in value: assert_portable(item)


def test_evidence(root: Path) -> dict:
    """Pin completed transcripts; stated counts must occur in the real output."""
    summary_path = root / "validation" / "acceptance-tests.json"
    summary = runtime.read(root, summary_path)
    if summary.get("schema") != 1 or summary.get("complete") is not True:
        raise ValueError("Completed validation summary required")
    result, kinds = [], set()
    for row in summary.get("suites", []):
        kind, count = row.get("kind"), row.get("tests")
        if kind not in {"zig-build", "zig-standalone", "python-unittest"} or not isinstance(count, int) or count < 1 or row.get("returncode") != 0:
            raise ValueError("A real passing test suite is required")
        relative = row["transcript"]
        assert_portable(relative)
        path = runtime.guarded(root, root / relative)
        transcript = path.read_text(encoding="utf-8-sig", errors="strict")
        if kind == "zig-build":
            if not re.search(rf"\b{count}/{count} tests passed\b", transcript):
                raise ValueError("Zig build transcript does not confirm stated count")
        elif kind == "python-unittest":
            if not re.search(rf"\bRan {count} tests? in ", transcript) or not re.search(r"^OK\s*$", transcript, re.MULTILINE):
                raise ValueError("Python transcript does not confirm passing count")
        elif not re.search(rf"All {count} tests passed\.", transcript):
            raise ValueError("Standalone Zig transcript does not confirm stated count")
        kinds.add(kind)
        result.append({"kind": kind, "tests": count, "returncode": 0,
                       "scope": row.get("scope", ""), "transcript": runtime.artifact(root, path)})
    if not {"zig-build", "python-unittest"}.issubset(kinds):
        raise ValueError("Both actual global Zig and Python suite results are required")
    return {"summary": runtime.artifact(root, summary_path), "suites": result}


def cleanup_evidence(root: Path) -> list[dict]:
    """No PASS while any owned VM image remains after the explicit cleanup."""
    leftovers = []
    for path in root.rglob("*"):
        if path.suffix.lower() in {".raw", ".qcow2", ".vhd", ".vhdx", ".img", ".fd"}:
            runtime.guarded(root, path)
            leftovers.append(path.relative_to(root).as_posix())
    if leftovers:
        raise ValueError("Owned VM images remain: " + ", ".join(leftovers[:12]))
    result = []
    for path in root.iterdir():
        if path.name.startswith("cleanup-") and path.name.endswith("-completed.json"):
            value = runtime.read(root, path)
            if value.get("stage") == "1b-1" and value.get("state") == "complete":
                report = runtime.artifact(root, root / "validation/final-report-pre-cleanup.md")
                if value.get("report_before_cleanup") != report:
                    raise ValueError("Cleanup did not pin the preserved final report")
                result.append({"receipt": runtime.artifact(root, path), "removed_bytes": value["removed_bytes"],
                               "images_count": value["images_count"], "report_before_cleanup": report})
    if not result:
        raise ValueError("Image cleanup receipt is required")
    return result


def cpu_evidence(root: Path, selected: list[dict]) -> dict:
    """CPU flags are not a run: pin completed QEMU command/exit evidence too."""
    path = root / "validation" / "cpu-ram.json"
    summary = runtime.read(root, path)
    if (summary.get("schema") != 1 or summary.get("kind") != "minios-1b1-cpu-ram"
            or summary.get("complete") is not True
            or set(summary.get("architectures", {})) != runtime.ARCHITECTURES):
        raise ValueError("Completed CPU/RAM evidence for all three versions required")
    accepted = {case["prepared"]["arch"]: case for case in selected if case["firmware"]}
    result = {}
    for arch, row in summary["architectures"].items():
        expected = accepted[arch]["prepared"]["hashes"]["bios_build" if arch == "bios" else "efi"]
        if row.get("artifact_sha256") != expected:
            raise ValueError("CPU/RAM evidence is not from the accepted firmware artifact")
        if arch in {"bios", "ia32"} and row.get("application_cpu_baseline") != "i486":
            raise ValueError("BIOS and IA32 must declare the explicit i486 application target")
        rows = []
        for run in row.get("qemu_cpu_runs", []):
            assert_portable(run["receipt"])
            receipt_path = runtime.guarded(root, root / run["receipt"])
            receipt = runtime.read(root, receipt_path)
            prepared = runtime.read(root, receipt_path.parent.parent / "prepared.json")
            if prepared.get("arch") != arch or prepared.get("hashes", {}).get("bios_build" if arch == "bios" else "efi") != expected:
                raise ValueError("CPU attempt used a different application artifact")
            command = receipt.get("command", [])
            try:
                cpu = command[command.index("-cpu") + 1]
                memory = int(command[command.index("-m") + 1])
            except (ValueError, IndexError, TypeError):
                raise ValueError("CPU/RAM receipt lacks actual QEMU -cpu/-m") from None
            passed = receipt.get("application_pass")
            if (cpu != run.get("cpu") or memory != run.get("memory_mib")
                    or passed is not run.get("application_pass")
                    or receipt.get("qemu_only") is not True
                    or not isinstance(receipt.get("returncode"), int)):
                raise ValueError("CPU/RAM summary differs from actual completed QEMU receipt")
            if passed and (receipt["returncode"] != 33 or receipt.get("timed_out") is not False):
                raise ValueError("CPU/RAM PASS requires actual successful guest completion")
            checked = {"cpu": cpu, "memory_mib": memory, "application_pass": passed,
                       "returncode": receipt["returncode"], "receipt": runtime.artifact(root, receipt_path)}
            if run.get("log"):
                assert_portable(run["log"])
                checked["log"] = runtime.artifact(root, root / run["log"])
            rows.append(checked)
        successes = [item["memory_mib"] for item in rows if item["application_pass"] is True]
        minimum = row.get("minimum_ram_mib")
        if not successes or minimum != min(successes):
            raise ValueError("RAM minimum is not the smallest actually passing workload")
        failed = row.get("preceding_failure_ram_mib")
        if failed is not None and (failed >= minimum or not any(item["memory_mib"] == failed and item["application_pass"] is False for item in rows)):
            raise ValueError("Stated lower RAM failure is not an actual completed attempt")
        if arch == "bios" and not all(any(item["cpu"] == cpu and item["memory_mib"] == 32 and item["application_pass"] is True for item in rows) for cpu in ("486", "pentium")):
            raise ValueError("BIOS requires both actual486 and Pentium32MiB PASS")
        result[arch] = {"application_cpu_baseline": row["application_cpu_baseline"],
                        "artifact_sha256": expected, "minimum_ram_mib": minimum,
                        "preceding_failure_ram_mib": failed,
                        "adjacent_lower_failure_proven": failed == minimum - 1,
                        "minimum_scope": row["minimum_scope"],
                        "firmware_cpu_requirements": row.get("firmware_cpu_requirements", ""),
                        "qemu_cpu_runs": rows}
    assert_portable(result)
    return {"summary": runtime.artifact(root, path), "architectures": result,
            "hardware_verified": False, "minimum_unit": "MiB; lowest passing completed attempt, not an untested universal minimum"}


def host_image_metrics(case: dict) -> dict:
    path = Path(case["completed"]["command"][0])
    if runtime.sha(path) != case["completed"]["writer_sha256"]:
        raise ValueError("Host writer artifact changed since its accepted run")
    data = path.read_bytes()
    if data[:2] != b"MZ": raise ValueError("Host writer is not the recorded PE executable")
    optional = struct.unpack_from("<I", data, 60)[0] + 24
    magic = struct.unpack_from("<H", data, optional)[0]
    if magic != 0x20b: raise ValueError("Expected the Windows x64 host-only writer")
    metrics = {"loaded_image_bytes": struct.unpack_from("<I", data, optional + 56)[0],
            "stack_reserve_bytes": struct.unpack_from("<Q", data, optional + 72)[0],
            "stack_commit_bytes": struct.unpack_from("<Q", data, optional + 80)[0],
            "stack_high_water_measured": False,
            "allocator_counter_scope": "explicit Zig core requests; entire reserved host stack and loaded PE image counted separately; OS/host IO runtime excluded"}
    if metrics["stack_reserve_bytes"] != 1024 * 1024:
        raise ValueError("Scaling host writer must use the explicit1MiB stack reserve")
    return metrics


def case_evidence(root: Path, case: dict) -> dict:
    directory = case["case"]
    windows = case["windows"]
    expected = case["manifest"]
    log_text = case["text"]
    peaks = [int(value) for value in re.findall(r"(?:alloc_peak|\bpeak)=(\d+)", log_text)]
    if not peaks or max(peaks) > 16 * 1024 * 1024:
        raise ValueError("Missing or over-budget core allocator evidence")
    metadata = re.findall(r"^(?:MFT |FRAGMENT |FRAGMENT READBACK |EMPTY-INDEX |WIDE |TREE ).*$", log_text, re.MULTILINE)
    files = [directory / "prepared.json", directory / "manifest.json", case["log"],
             case["windows_dir"] / "result.json", case["windows_dir"] / "chkdsk-stdout.txt",
             case["windows_invocation"]]
    if case["firmware"]:
        summary = runtime.firmware.summarize(directory)
        memory = {key: summary[key] for key in ("program_footprint", "allocator_peak_bytes", "program_ram_conservative_upper_bound_bytes")}
        memory["physical_heap"] = summary["physical_heap"]
        files += [directory / "program-footprint.json", directory / "run-64m/completed.json",
                  case["image"].parent / "export.json", case["image"].parent / "identifiers.json"]
    else:
        host_image = host_image_metrics(case)
        total = max(peaks) + host_image["loaded_image_bytes"] + host_image["stack_reserve_bytes"]
        if total > 16 * 1024 * 1024:
            raise ValueError("Host client/core conservative own-program RAM exceeds16MiB")
        memory = {"allocator_peak_bytes": max(peaks), "host_image": host_image,
                  "program_ram_conservative_upper_bound_bytes": total}
        files.append(directory / "completed.json")
    files.append(case["structure_path"])
    image_bytes = case["image_bytes"]
    return {"case": directory.relative_to(root).as_posix(), "profile": case["profile"],
            "backend": "QEMU64MiB firmware" if case["firmware"] else "host regular-file writer",
            "architecture": case["prepared"].get("arch", "host-x86_64"),
            "files": len(expected["files"]), "directories": len(expected["directories"]),
            "data_bytes": sum(row["size"] for row in expected["files"].values()),
            "image_bytes": image_bytes, "image_sha256": case["image_sha256"],
            "elapsed_writer_seconds": case["completed"]["elapsed_seconds"],
            "memory": memory, "metadata_workload_evidence": metadata,
            "independent_structure": case["structure"],
            "windows": {"passed": True, "exact_file_bytes_and_paths": True,
                "readonly_chkdsk_pass": True, "chkdsk_exit": windows["chkdsk_exit"],
                "chkdsk_flags": [], "actual_virtual_disk_bytes": windows["chkdsk_target_guard"]["actual_disk_bytes"],
                "source_image_unchanged": True, "vhd_unchanged": True,
                "temporary_alias_removed": True, "vhd_detached": True},
            "receipts": [runtime.artifact(root, path) for path in files]}


def collect(root: Path, host: list[Path], firmware: list[Path]) -> dict:
    selected = runtime.cases(root, host, firmware)
    host_profiles = [case["profile"] for case in selected if not case["firmware"]]
    architectures = [case["prepared"]["arch"] for case in selected if case["firmware"]]
    if len(host_profiles) != 3 or set(host_profiles) != runtime.PROFILES:
        raise ValueError("Exactly the three accepted large host profiles are required")
    if len(architectures) != 3 or set(architectures) != runtime.ARCHITECTURES:
        raise ValueError("Exactly one accepted64MiB run per firmware architecture is required")
    cases = [case_evidence(root, case) for case in selected]
    cleanup = cleanup_evidence(root)
    result = {"schema": 2, "stage": "1b-1 NTFS scaling, no WIM", "overall": "PASS",
            "qemu_platforms_only": True, "host_cases": 3, "firmware_cases": 3,
            "evidence_root": "caller-selected new1b-1 runtime; paths below are relative",
            "cases": cases, "cleanup": cleanup, "owned_images_remaining": 0,
            "validation": test_evidence(root),
            "cpu_and_machine_ram": cpu_evidence(root, selected),
            "scope": {"wim_started": False, "physical_devices_used": False,
                "merge_deploy_push_performed": False,
                "memory_note": "Conservative own-program upper bounds include loaded code/static and entire reserved stack; firmware and OS/host IO runtime excluded; no stack high-water claim"}}
    assert_portable(result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    runtime.add_arguments(parser)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = Path(os.path.abspath(args.workspace))
    result = collect(root, args.host_case, args.firmware_case)
    output = Path(os.path.abspath(args.output))
    runtime.guarded(REPO / "docs", output)
    with output.open("x", encoding="utf-8", newline="\n") as file:
        json.dump(result, file, ensure_ascii=False, indent=2); file.write("\n")
    print(json.dumps({"output": str(output), "sha256": runtime.sha(output), "overall": "PASS"}))


if __name__ == "__main__": main()
