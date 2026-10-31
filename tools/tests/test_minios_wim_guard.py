#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Actual negative PowerShell guards. Never convert/mount; retain own evidence."""
import argparse
import copy
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("wim_oracle_guard", REPO / "tools/minios/wim_oracle.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--pwsh", type=Path, required=True)
    args = parser.parse_args()
    folder = m.owned(args.workspace)
    m.local(args.pwsh)
    if folder.exists():
        raise FileExistsError("Keep prior evidence; select a new own folder")
    m.storage_guard(128 * 1024**2)
    folder.mkdir(parents=True)
    temp = folder / "host-runtime"
    temp.mkdir()
    environment = os.environ.copy()
    environment.update(APPDATA=str(temp), LOCALAPPDATA=str(temp), TEMP=str(temp), TMP=str(temp))
    source = folder / "own-guard-source.raw"
    with source.open("xb") as out:
        out.truncate(64 * 1024**2)
    source.chmod(stat.S_IREAD)
    original = m.digest(source)
    script = REPO / "tools/tests/minios_chkdsk_readonly.ps1"
    row = dict(path="", directory=True, attributes=16, creation_filetime=1, modified_filetime=2,
               accessed_filetime=3, hardlink_group_id=0, link_count=1, reparse_tag=0,
               security_sha256="1" * 64, streams=[dict(name=None, size=0, sha1="0" * 40)])
    cases = []

    def bad(name, update, error):
        value = copy.deepcopy(row)
        update(value)
        cases.append((name, [value], error))

    bad("unsafe-parent-path", lambda r: r.update(path="../escape"), "Unsafe WIM path component")
    bad("unsafe-ADS-path", lambda r: r.update(path="file:escape"), "Unsafe WIM tree path")
    bad("bad-filetime", lambda r: r.update(creation_filetime=-1), "Invalid WIM integer")
    bad("missing-security", lambda r: r.pop("security_sha256"), "security descriptor SHA256 required")
    bad("bad-stream-SHA1", lambda r: r["streams"][0].update(sha1="bad"), "Invalid/bounded WIM stream")
    bad("bad-stream-size", lambda r: r["streams"][0].update(size=100 * 1024**3 + 1), "Invalid/bounded WIM stream")
    bad("ADS-traversal", lambda r: r["streams"].append(dict(name="../outside", size=0, sha1="0" * 40)), "Invalid or duplicated WIM ADS")
    bad("missing-root", lambda r: r.update(path="a"), "must include the root")
    cases.append(("duplicate-root", [row, row], "Duplicate WIM manifest path"))
    cases.append(("missing-SD-sidecar", [row], "requires -ExpectedWimSecurityJsonl"))
    cases.append(("corrupt-SD-sidecar", [row], "Expected raw SD SHA256 differs"))
    results = []
    for name, values, error in cases:
        manifest = folder / (name + ".jsonl")
        manifest.write_text("".join(json.dumps(v) + "\n" for v in values), encoding="utf-8")
        results.append((name, str(source), 64 * 1024**2, original, manifest, error))
    results.extend([
        ("physical-device", r"\\.\PhysicalDrive0", 64 * 1024**2, original, None, "Only a file below"),
        ("wrong-size", str(source), 65 * 1024**2, original, None, "Exact expected image size differs"),
        ("wrong-sha", str(source), 64 * 1024**2, "0" * 64, None, "Raw copy SHA-256 differs"),
        ("writable-source", str(source), 64 * 1024**2, original, None, "read-only attribute"),
    ])
    reuse_cases = {
        "prepared-missing-pin": (None, "requires both immutable prior result"),
        "prepared-bad-proof-pin": ({}, "result path/hash/size differs"),
        "prepared-open-closure": ({"dismounted": False}, "exact closed source/closure"),
        "prepared-wrong-source": ({"source": str(folder / "other.raw")}, "exact closed source/closure"),
        "prepared-wrong-size": ({"image_bytes": 64 * 1024**2 + 512}, "exact closed source/closure"),
        "prepared-unsafe-vhd": ({"vhd": r"\\.\PhysicalDrive0"}, "Only a file below"),
        "prepared-wrong-vhd-kind": ({}, "pin does not match completed conversion/copy"),
    }
    results.extend((name,str(source),64 * 1024**2,original,None,error) for name,(_,error) in reuse_cases.items())
    receipt = {"passed": False, "source_sha256": original, "source_bytes": source.stat().st_size,
               "conversion_or_mount_reached": False, "physical_device_opened": False, "tests": []}
    try:
        for name, raw, size, expected, manifest, message in results:
            if name in reuse_cases:
                source.chmod(stat.S_IREAD)
            if name == "writable-source":
                source.chmod(stat.S_IREAD | stat.S_IWRITE)
            out = folder / (name + "-MUST-NOT-EXIST")
            command = [str(args.pwsh), "-NoLogo", "-NoProfile", "-NonInteractive", "-File", str(script),
                       "-Workspace", str(folder), "-RawCopy", raw, "-ExpectedImageBytes", str(size),
                       "-ExpectedSha256", expected, "-QemuImg", str(folder / "MUST-NOT-RUN.exe"), "-Out", str(out)]
            if manifest:
                command += ["-ExpectedWimTreeJsonl", str(manifest)]
            if name == "corrupt-SD-sidecar":
                security = folder / "corrupt-security.jsonl"
                security.write_text(json.dumps(dict(sha256="1" * 64, bytes=20, hex="01" + "00" * 19)) + "\n", encoding="utf-8")
                command += ["-ExpectedWimSecurityJsonl", str(security)]
            if name in reuse_cases:
                changes,_=reuse_cases[name]
                value=dict(source=str(source),image_bytes=64 * 1024**2,source_sha256_before=original,
                           source_sha256_after=original,convert_exit=0,dismounted=True,
                           drive_letter_assigned=True,temporary_dos_alias_removed=True,vhd=str(source),
                           vhd_sha256_before=original,vhd_sha256_after=original,intermediate_sha256=original)
                if changes is not None:
                    value.update(changes)
                prior=folder / (name + "-prior.json")
                m.save(prior,value)
                command += ["-PreparedVhdResult",str(prior)]
                if changes is not None:
                    command += ["-PreparedVhdResultSha256", "0" * 64 if name=="prepared-bad-proof-pin" else m.digest(prior)]
            child = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True, env=environment,
                                   timeout=60, check=False, encoding="utf-8", errors="strict")
            (folder / (name + "-stdout.txt")).write_text(child.stdout, encoding="utf-8")
            (folder / (name + "-stderr.txt")).write_text(child.stderr, encoding="utf-8")
            passed = child.returncode != 0 and message in child.stdout + child.stderr and not out.exists()
            receipt["tests"].append(dict(name=name, passed=passed, exit=child.returncode, out_created=out.exists()))
            if not passed:
                raise AssertionError("Guard failed: " + name)
        receipt["source_sha256_after"] = m.digest(source)
        if receipt["source_sha256_after"] != original:
            raise AssertionError("Own raw bytes changed")
        receipt["passed"] = True
    finally:
        source.chmod(stat.S_IREAD)
        m.save(folder / "result.json", receipt)
    print(json.dumps(receipt))


if __name__ == "__main__":
    main()
