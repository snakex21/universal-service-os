"""Collect closed pre-1b2 receipts; never query a running VM or mount a disk."""
from __future__ import annotations
import argparse
import importlib.util
import json
from pathlib import Path
import re

spec = importlib.util.spec_from_file_location("preflight_scale_evidence", Path(__file__).with_name("scale_evidence.py"))
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
runtime = base.runtime
CASES = {"bios-2m-01": ("bios", 2, "scale-firmware", 10257, 104),
         "bios-tree150k-01": ("bios", 64, "scale-tree150k", 150000, 301),
         "uefi-tree150k-01": ("x86_64", 64, "scale-tree150k", 150000, 301)}


def validate_windows(value: dict, expected: dict, image_bytes: int, source_sha: str, returncode: int):
    if returncode != 0 or value.get("kind") != "windows-readonly-chkdsk" or value.get("chkdsk_issued") is not True:
        raise ValueError("The actual Windows verifier and CHKDSK invocation must complete")
    checks = ("passed", "readonly_chkdsk_pass", "readonly_file_tree_pass", "disk_is_readonly",
              "source_ntfs_boot_signature", "temporary_dos_alias_removed", "dismounted")
    if any(value.get(key) is not True for key in checks):
        raise ValueError("Windows verification/cleanup did not pass")
    if (value.get("access") != "ReadOnly" or value.get("chkdsk_flags") != []
        or value.get("repair_flags_used") is not False or value.get("chkdsk_exit") != 0
        or value.get("chkdsk_timeout") is not False or value.get("image_bytes") != image_bytes
        or value.get("source_sha256_before") != source_sha or value.get("source_sha256_after") != source_sha
        or value.get("vhd_sha256_before") != value.get("vhd_sha256_after")
        or value.get("manifest_sha256_before") != value.get("manifest_sha256_after")):
        raise ValueError("Windows source/readonly/CHKDSK receipt differs")
    guard = value.get("chkdsk_target_guard", {})
    if (guard.get("passed") is not True or guard.get("boot") is not False or guard.get("system") is not False
        or guard.get("readonly") is not True or guard.get("bus_type") != "File Backed Virtual"
        or guard.get("actual_disk_bytes") != image_bytes or guard.get("expected_image_bytes") != image_bytes):
        raise ValueError("Windows physical/readonly/exact-size guard differs")
    tree = value.get("file_tree", {})
    if (tree.get("passed") is not True or tree.get("extra") != [] or tree.get("different") != [] or tree.get("missing") != []
        or tree.get("file_count") != len(expected["files"])
        or tree.get("directory_count") != len(expected["directories"])
        or tree.get("writes_to_volume") is not False):
        raise ValueError("Windows exact file tree differs")
    actual = {row["path"]: {"size": row["size"], "sha256": row["sha256"]} for row in tree.get("files", [])}
    if len(actual) != len(tree.get("files", [])) or actual != expected["files"]:
        raise ValueError("Windows file sizes or SHA differ from the independent manifest")
    if sorted(tree.get("directories", [])) != sorted(expected["directories"]):
        raise ValueError("Windows exact directory paths differ")


def accepted(root: Path, name: str) -> dict:
    arch, memory, profile, files, directories = CASES[name]
    case = root / "cases" / name
    value = runtime.read(root, case / "preflight-completed.json")
    prepared = runtime.read(root, case / "prepared.json")
    run = case / f"run-{memory}m"
    done = runtime.read(root, run / "completed.json")
    if (value.get("passed") is not True or value.get("qemu_only") is not True
        or value.get("wim_started") is not False or prepared.get("arch") != arch
        or prepared.get("profile") != profile or done.get("returncode") != 33
        or done.get("application_pass") is not True or done.get("timed_out") is not False):
        raise ValueError("A required fresh firmware case did not finish successfully")
    command = done["command"]
    if int(command[command.index("-m") + 1]) != memory or command[command.index("-cpu") + 1] != ("486" if arch == "bios" else "max"):
        raise ValueError("Actual QEMU CPU/RAM does not match the required case")
    source = root / "oracle/inputs" / name
    exported = runtime.read(root, source / "export.json")
    if exported["chain_before"] != exported["chain_after"] or exported.get("raw_readonly") is not True:
        raise ValueError("Source COW/base changed during independent export")
    manifest_path = source / "manifest.json"
    manifest = runtime.read(root, manifest_path)
    if len(manifest["files"]) != files or len(manifest["directories"]) != directories:
        raise ValueError("Required workload counts differ")
    verification=value.get("verification",{})
    windows_path=runtime.guarded(root,Path(verification["windows_result"]))
    allowed={root/"oracle"/(name+f"-windows{n:02d}")/"result.json" for n in (1,2)}
    if windows_path not in allowed:raise ValueError("Unexpected Windows attempt receipt path")
    windows = runtime.read(root, windows_path)
    invocation_path=runtime.guarded(root,Path(verification.get("windows_invocation",str(source/"windows-invocation.json"))))
    allowed_invocations={source/"windows-invocation.json",source/"windows-invocation02.json"}
    if invocation_path not in allowed_invocations:raise ValueError("Unexpected Windows invocation path")
    invocation = runtime.read(root, invocation_path)
    validate_windows(windows, manifest, prepared["size"], exported["raw_sha256"], invocation.get("returncode"))
    if windows["manifest_sha256_before"] != runtime.sha(manifest_path):
        raise ValueError("Host manifest changed after acceptance")
    structure_path = source / "metadata-inspection.json"
    structure = runtime.read(root, structure_path)
    runtime.validate_structure(structure, "firmware" if profile == "scale-firmware" else "tree150k", manifest)
    if value.get("memory", {}).get("conservative_own_bytes", 2**64) > 16 * 1024**2:
        raise ValueError("Own memory exceeds16MiB")
    return {"name":name, "arch":arch, "cpu":"486" if arch == "bios" else "max", "ram_mib":memory,
        "files":files, "directories":directories, "data_bytes":sum(row["size"] for row in manifest["files"].values()),
        "memory":value["memory"], "entropy":value["entropy_log"], "tested_program_sha256":prepared["hashes"],
        "image_sha256":exported["raw_sha256"], "windows_file_sha_pass":True, "readonly_chkdsk_exit":0,
        "mft_records":structure["mft_records"], "mft_physical_extents":structure["mft_physical_extent_count"],
        "mft_mirror_equal":True, "receipt":runtime.artifact(root,case / "preflight-completed.json"),
        "qemu_receipt":runtime.artifact(root,run / "completed.json"),
        "application_log":runtime.artifact(root,run / "USOSPREP.LOG"),
        "windows_receipt":runtime.artifact(root,windows_path), "windows_invocation":runtime.artifact(root,invocation_path),
        "structure_receipt":runtime.artifact(root,structure_path),
        "export_receipt":runtime.artifact(root,source / "export.json"), "manifest":runtime.artifact(root,manifest_path)}


def collect(root: Path) -> dict:
    cases = [accepted(root, name) for name in CASES]
    negative_path = root / "cases/entropy-refusal-01/preflight-completed.json"
    negative = runtime.read(root, negative_path)
    if any(negative.get(k) is not True for k in ("passed", "expected_entropy_refusal", "no_target_or_boot_image_write", "bases_unchanged")):
        raise ValueError("No-entropy refusal did not preserve both complete disk images")
    negative_run = runtime.read(root, negative_path.parent / "run-2m/completed.json")
    if negative_run.get("returncode") != 35 or negative_run.get("timed_out") is not False or "-fw_cfg" in negative_run["command"]:
        raise ValueError("Negative control did not run without the fw_cfg entropy input")
    builds = runtime.read(root, root / "validation/build-results.json")
    for build in builds["builds"]:
        path = root / build["transcript"]["path"]
        text = path.read_text(encoding="utf-8-sig")
        n = build["tests"]
        if build["returncode"] != 0 or not re.search(rf"\b{n}/{n} tests passed\b", text) or runtime.artifact(root,path) != build["transcript"]:
            raise ValueError("Build receipt does not match the real completed transcript")
        for artifact in build["artifacts"].values():
            if runtime.artifact(root, root / artifact["path"]) != artifact:
                raise ValueError("Preserved program artifact changed")
    result = {"schema":1,"stage":"pre1b2","complete":True,"qemu_only":True,"wim_started":False,
        "cases":cases,"entropy_refusal":runtime.artifact(root,negative_path),"builds":builds["builds"],
        "test_suites":base.test_evidence(root),
        "limits":{"physical_boards_tested":False,"mft_continuation_records":[16,23],
                  "mft_continuation_slots":8,"attribute_list_max_bytes":262144,
                  "journal_or_crash_recovery":False,"reuse_accounting_max_ranges":4096},
        "cleanup":None}
    compression=root/"validation/storage-compression01.json"
    if compression.exists():
        storage=runtime.read(root,compression)
        if storage.get("complete") is not True or storage.get("deletion_performed") is not False or any(row["sha256_before"]!=row["sha256_after"] for row in storage["files"]):
            raise ValueError("Storage compression did not preserve the complete image bytes")
        result["storage_compression"]=runtime.artifact(root,compression)
    failed=root/"oracle/inputs/bios-tree150k-01/windows-invocation.json"
    first=runtime.read(root,failed)
    if first.get("returncode") != 0:
        result["earlier_windows_storage_refusal"]=runtime.artifact(root,failed)
    cleanup = root / "cleanup-preflight-completed.json"
    if cleanup.exists():
        value = runtime.read(root, cleanup)
        if value.get("state") != "complete" or value.get("stage") != "pre1b2":
            raise ValueError("Cleanup did not complete")
        result["cleanup"] = {"receipt":runtime.artifact(root,cleanup),"deleted_files":value["files_count"],
            "plan":runtime.artifact(root,root/"cleanup-preflight-plan.json"),
            "logical_bytes":value["removed_bytes"],"report_before_cleanup":value["report_before_cleanup"]}
        preserved=root/"validation/preserved-evidence.json"
        inventory=runtime.read(root,preserved)
        if inventory.get("complete") is not True or inventory.get("vm_test_images_remaining") != 0:
            raise ValueError("Preserved evidence inventory and completed image cleanup are required")
        result["preserved_evidence"]=runtime.artifact(root,preserved)
    base.assert_portable(result)
    return result


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--workspace",type=Path,required=True)
    p.add_argument("--output",type=Path,required=True)
    a=p.parse_args()
    value=collect(a.workspace.resolve())
    a.output.write_text(json.dumps(value,indent=2)+"\n",encoding="utf-8")
    print(json.dumps({"complete":True,"cases":len(value["cases"]),"cleanup_recorded":value["cleanup"] is not None}))

if __name__=="__main__":main()
