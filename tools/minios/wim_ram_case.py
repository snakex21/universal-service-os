#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""One RAM probe on fresh COWs of a Windows-verified final WIM baseline.

The caller declares earlier RAM probes closed; run probes serially. Only the
ESP is exported after process completion. Target COWs and all evidence stay.
"""
from __future__ import annotations
import argparse
import contextlib
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import time

spec = importlib.util.spec_from_file_location("ram_wim_firmware", Path(__file__).with_name("wim_firmware_case.py"))
firmware = importlib.util.module_from_spec(spec); spec.loader.exec_module(firmware)
oracle, api, preflight, pool = firmware.oracle, firmware.api, firmware.preflight, firmware.pool
invoke, guest_acceptance, windows_acceptance = firmware.invoke, firmware.guest_acceptance, firmware.windows_acceptance

MiB = 1024**2
RAM_SCOPE_BYTES = 2560 * MiB
# Entire allowed virtual target256MiB + two ESP65MiB copies (COW/data and
# exportedraw) + explicitqcow2metadata8MiB + vars4MiB + logs16MiB =414MiB.
# Round upward; do not assume a particular WIM compresses or writes sparsely.
NEXT_CASE_BOUND = 416 * MiB


def probe_bounds(memory: int, timeout: int, closed_bytes: int) -> None:
    if (type(memory) is not int or not 16 <= memory <= 64
            or type(timeout) is not int or not 30 <= timeout <= 900
            or type(closed_bytes) is not int or closed_bytes < 0
            or closed_bytes + NEXT_CASE_BOUND > RAM_SCOPE_BYTES):
        raise ValueError("Bounded16..64MiB probe, timeout, and2.5GiB RAM-scope required")


def baseline_acceptance(prepared: dict, completed: dict, windows: dict, program_sha: str) -> bool:
    return (prepared.get("arch") in ("x86_64", "ia32")
            and prepared.get("qemu_only") is True and completed.get("qemu_only") is True
            and completed.get("guest_completion_wait") is True
            and completed.get("application_pass") is True and completed.get("bases_unchanged") is True
            and prepared.get("program_sha256") == program_sha == completed.get("program_sha256")
            and completed.get("memory_mib") == 64 and windows.get("passed") is True)


def native_baseline_matches(prepared: dict, completed: dict, native: dict) -> bool:
    """Bind the successful native gate to this exact output and oracle inputs."""
    try:
        return (Path(native["source"]) == Path(completed["target"])
                and native["source_sha256_before"] == native["source_sha256_after"] == completed["target_sha256"]
                and Path(native["wim_manifest"]) == Path(prepared["image"]["tree"])
                and native["wim_manifest_sha256_before"] == native["wim_manifest_sha256_after"] == prepared["tree_sha256"]
                and Path(native["wim_security_manifest"]) == Path(prepared["image"]["security"])
                and native["wim_security_manifest_sha256_before"] == native["wim_security_manifest_sha256_after"] == prepared["security_sha256"])
    except (KeyError, TypeError, ValueError):
        return False


def geometry_bounds(target_bytes: int, target_base_bytes: int, esp_base_bytes: int) -> None:
    if (type(target_bytes) is not int or not 128 * MiB <= target_bytes <= 256 * MiB
            or target_bytes % 512 or target_base_bytes != target_bytes
            or type(esp_base_bytes) is not int or not 0 < esp_base_bytes <= 65 * MiB
            or esp_base_bytes % 512):
        raise ValueError("RAM probes require an exact128..256MiB raw target and at most65MiB raw ESP")


def closed_footprint(scope: Path) -> int:
    """Accounting of explicitly declared CLOSED probes, never a progress scan."""
    if not scope.exists(): return 0
    total = 0
    for folder, dirs, files in os.walk(scope, followlinks=False):
        for name in dirs + files:
            path = Path(folder) / name
            info = path.lstat()
            if path.is_symlink() or getattr(info, "st_file_attributes", 0) & 0x400:
                raise ValueError("No RAM-scope reparse objects")
            if stat.S_ISREG(info.st_mode): total += info.st_size
    return total


def run(baseline: Path, program_sha: str, memory: int, timeout: int, plan: Path, qemu: Path,
        *, previous_probes_declared_closed: bool) -> dict:
    oracle.owned(baseline); oracle.local(qemu)
    if previous_probes_declared_closed is not True:
        raise ValueError("Earlier RAM probes must be explicitly declared closed")
    prepared = json.loads((baseline / "prepared.json").read_text())
    original = json.loads((baseline / "completed.json").read_text())
    windows = json.loads((baseline / "windows-completed.json").read_text())
    if not baseline_acceptance(prepared, original, windows, program_sha):
        raise ValueError("Windows-verified64MiB final UEFI baseline with exact program pin required")
    native = baseline / "windows-oracle/result.json"
    invocation = baseline / "windows-invocation.json"
    native_record = json.loads(native.read_text())
    if (Path(windows["result"]) != native or Path(windows["invocation"]) != invocation
            or oracle.digest(native) != windows["result_sha256"]
            or Path(original["target"]) != baseline / "guest/target.raw"
            or not native_baseline_matches(prepared, original, native_record)
            or not windows_acceptance(native_record, json.loads(invocation.read_text())["returncode"], prepared["target_bytes"])):
        raise ValueError("Independent Windows baseline receipt or invocation differs")
    scope = oracle.RUNTIME / "ram-final07"
    api.configure(scope, qemu)
    probe_bounds(memory, timeout, closed_footprint(scope))
    label = "x64" if prepared["arch"] == "x86_64" else "ia32"
    case = scope / f"{label}-m{memory:03d}"
    oracle.owned(case)
    if case.exists(): raise FileExistsError("Keep all earlier probe evidence")
    capacity = pool.enforce(plan, case)
    preflight.ram_reserve(memory)
    program = oracle.local(Path(prepared["program"]))
    if oracle.digest(program) != program_sha: raise ValueError("Final firmware program pin changed")
    bases = {name: oracle.owned(baseline / name) for name in ("esp-base.raw", "target-base.raw")}
    geometry_bounds(prepared["target_bytes"], bases["target-base.raw"].stat().st_size, bases["esp-base.raw"].stat().st_size)
    if any(oracle.digest(path) != prepared["base_sha256"][name] for name, path in bases.items()):
        raise ValueError("Immutable baseline changed")
    firmware = qemu / "share" / f"edk2-{'x86_64' if label == 'x64' else 'i386'}-code.fd"
    if oracle.digest(firmware) != original["host_firmware_sha256"]:
        raise ValueError("Host EDK2 firmware changed from full baseline gate")
    executable = qemu / f"qemu-system-{'x86_64' if label == 'x64' else 'i386'}.exe"
    if oracle.digest(executable) != original["qemu_sha256"]:
        raise ValueError("QEMU changed from full baseline gate")
    case.mkdir(parents=True)
    env = oracle.environment(case)
    entropy = os.urandom(64); (case / "entropy.bin").write_bytes(entropy)
    oracle.save(case / "inputs.json", {"baseline": str(baseline), "baseline_program_sha256": program_sha,
                "base_sha256": prepared["base_sha256"], "memory_mib": memory,
                "previous_probes_declared_closed": True, "capacity": capacity,
                "target_raw_export_planned": False, "new_windows_vhd_planned": False})
    with contextlib.ExitStack() as locks:
        for path in bases.values(): locks.enter_context(oracle.readonly(path))
        for name in ("esp", "target"):
            invoke([qemu / "qemu-img.exe", "create", "-f", "qcow2", "-F", "raw", "-b",
                    bases[f"{name}-base.raw"], "-o", "cluster_size=65536", case / f"{name}.qcow2"], case / f"overlay-{name}.log", env)
        shutil.copyfile(qemu / "share/edk2-i386-vars.fd", case / "vars.fd")
        args = [str(executable), "-machine", "q35", "-accel", "tcg,thread=multi", "-cpu", original["cpu"],
                "-smp", "1", "-m", str(memory), "-nodefaults", "-display", "none", "-no-reboot", "-nic", "none",
                "-drive", f"if=pflash,format=raw,readonly=on,file={firmware}",
                "-drive", f"if=pflash,format=raw,file={case / 'vars.fd'}",
                "-fw_cfg", f"name=opt/usosprep-entropy,file={case / 'entropy.bin'}",
                "-drive", f"if=none,id=esp,format=qcow2,file={case / 'esp.qcow2'}",
                "-device", "ide-hd,drive=esp,bus=ide.0,bootindex=1",
                "-drive", f"if=none,id=target,format=qcow2,file={case / 'target.qcow2'}",
                "-device", "ide-hd,drive=target,bus=ide.1", "-device", "VGA",
                "-serial", f"file:{case / 'serial.log'}", "-debugcon", f"file:{case / 'debug.log'}",
                "-global", "isa-debugcon.iobase=0xe9", "-device", "isa-debug-exit,iobase=0xf4,iosize=0x04"]
        started = time.monotonic(); timed_out = interrupted = False; status = None
        with (case / "qemu.stdout").open("xb") as out, (case / "qemu.stderr").open("xb") as err:
            child = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=out, stderr=err, env=env,
                                     creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            try: status = child.wait(timeout=timeout)
            except subprocess.TimeoutExpired: timed_out = True
            except KeyboardInterrupt: interrupted = True
            finally:
                if status is None:
                    try: child.kill()
                    except ProcessLookupError: pass
                    status = child.wait()
        # Only this ESP is exported, only after actual process completion.
        invoke([qemu / "qemu-img.exe", "convert", "-f", "qcow2", "-O", "raw",
                case / "esp.qcow2", case / "esp-closed.raw"], case / "export-esp.log", env)
        found = api.extract_log(case / "esp-closed.raw", case / "USOSPREP.LOG")
        log = (case / "USOSPREP.LOG").read_bytes() if found else b""
        unchanged = all(oracle.digest(path) == prepared["base_sha256"][name] for name, path in bases.items())
    passed = guest_acceptance(status, timed_out, interrupted, log, unchanged)
    result = {"kind": "wim-ram-probe-v1", "qemu_only": True, "baseline": str(baseline),
              "program_sha256": program_sha, "memory_mib": memory, "returncode": status,
              "timed_out": timed_out, "interrupted": interrupted, "guest_completion_wait": True,
              "application_pass": passed, "bases_unchanged": unchanged,
              "elapsed_seconds": time.monotonic() - started, "command": args,
              "entropy_sha256": hashlib.sha256(entropy).hexdigest(),
              "target_cow_retained": True, "target_raw_exported": False,
              "new_windows_vhd_created": False, "cleanup_performed": False}
    if passed:
        try: result["memory"] = preflight.own_memory(log.decode("utf-8", "replace"), prepared["program_footprint"])
        except ValueError as error: result.update(application_pass=False, memory_error=str(error))
    oracle.save(case / "completed.json", result)
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--program-sha256", required=True)
    parser.add_argument("--memory", type=int, required=True)
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--pool-plan", type=Path, required=True)
    parser.add_argument("--qemu-dir", type=Path, required=True)
    parser.add_argument("--previous-probes-declared-closed", action="store_true")
    args = parser.parse_args()
    result = run(args.baseline, args.program_sha256, args.memory, args.timeout, args.pool_plan,
                 args.qemu_dir, previous_probes_declared_closed=args.previous_probes_declared_closed)
    print(json.dumps(result)); raise SystemExit(0 if result["application_pass"] else 1)
