#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""One fresh own-data WIM QEMU case; immutable bases, completion waits, no cleanup.

The guest is never polled. Export and the optional Windows read-only gate run
only after its process handle has signalled completion. No physical devices.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import stat
import struct
import subprocess
import time

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location("wim_fw_" + name, HERE / (name + ".py"))
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


oracle, api, preflight, pool = load("wim_oracle"), load("uefi_case"), load("preflight_case"), load("wim_pool")
TARGET_BYTES = 128 * 1024**2


class SmallEsp(api.FatBuilder):
    total = 131072  # 64MiB FAT32 partition, plus the existing1MiB alignment.
    spc = 1
    cluster_bytes = spc * 512
    data_sector = api.FatBuilder.start + api.FatBuilder.reserved + 2 * api.FatBuilder.fat_sectors
    capacity = (total - api.FatBuilder.reserved - 2 * api.FatBuilder.fat_sectors) // spc


def target_bounds(size: int, kind: str) -> None:
    if type(size) is not int or not TARGET_BYTES <= size <= 512 * 1024**2 or size % 512 or kind not in ("gpt", "mbr"):
        raise ValueError("Explicit128..512MiB aligned target and GPT/MBR required")


def case_path(workspace: Path, name: str, qemu: Path) -> Path:
    oracle.owned(workspace); oracle.local(qemu)
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", name):
        raise ValueError("Explicit safe owned case name required")
    api.configure(workspace, qemu)
    return api.checked(workspace / name)


def invoke(argv, out: Path, env: dict, timeout=300):
    with out.open("xb") as log:
        result = subprocess.run([str(arg) for arg in argv], stdin=subprocess.DEVNULL, stdout=log,
                                stderr=subprocess.STDOUT, env=env, timeout=timeout, check=False,
                                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    if result.returncode:
        raise RuntimeError("Owned tool failed; retained log: " + str(out))


def selected_fixture(path: Path, index: int) -> tuple[dict, dict]:
    oracle.owned(path)
    fixture = json.loads(path.read_text(encoding="utf-8"))
    if fixture.get("own_generated_data") is not True or fixture.get("solid") is not False or type(index) is not int:
        raise ValueError("Only explicit positive-index own-data nonsolid fixtures")
    selected = [row for row in fixture.get("images", []) if row.get("index") == index]
    if len(selected) != 1 or index < 1:
        raise ValueError("Explicit selected image must exist exactly once")
    for key in ("tree", "security", "manifest"):
        oracle.owned(Path(selected[0][key]))
    source = oracle.owned(Path(fixture["wim"]))
    if not source.is_file() or oracle.digest(source) != fixture["sha256"]:
        raise ValueError("Immutable WIM SHA256 differs")
    receipt = json.loads(Path(selected[0]["manifest"]).read_text(encoding="utf-8"))
    if (receipt.get("wim_sha256") != fixture["sha256"] or receipt.get("index") != index
        or oracle.digest(Path(selected[0]["tree"])) != receipt.get("tree_sha256")
        or oracle.digest(Path(selected[0]["security"])) != receipt.get("security_sha256")):
        raise ValueError("Independent oracle manifest pins differ")
    return fixture, selected[0]


def prepare(case, arch, program, program_sha, bios_elf, fixture_path, index, pool_plan, *, target_bytes=TARGET_BYTES, kind="gpt"):
    oracle.local(program)
    target_bounds(target_bytes, kind)
    if arch not in ("x86_64", "ia32", "bios") or not re.fullmatch("[0-9a-f]{64}", program_sha):
        raise ValueError("Explicit architecture and final program SHA256 required")
    if case.exists() or not program.is_file() or oracle.digest(program) != program_sha:
        raise ValueError("Fresh case and exact final program pin required")
    if arch == "bios" and (bios_elf is None or not oracle.local(bios_elf).is_file()):
        raise ValueError("BIOS requires its explicit matching linked ELF")
    fixture, image = selected_fixture(fixture_path, index)
    footprint = preflight.firmware.program_footprint(program, arch, bios_elf)
    if footprint["artifact_sha256"] != program_sha:
        raise ValueError("Program changed before preparation")
    capacity = pool.enforce(pool_plan, case)
    oracle.storage_guard(4 * target_bytes)
    case.mkdir(parents=True)
    token = secrets.token_hex(32)
    archive = Path(fixture["wim"])
    boot = case / "esp-base.raw"
    with oracle.readonly(archive) as locked:
        if oracle.digest_stream(locked) != fixture["sha256"]:
            raise ValueError("WIM changed before embedding")
        if arch == "bios":
            if program.stat().st_size != 1024**2:
                raise ValueError("Expected isolated one-MiB WIM BIOS artifact")
            with program.open("rb") as source, boot.open("x+b") as target:
                shutil.copyfileobj(source, target, 65536)
                target.truncate(64 * 1024**2)
                cfg = bytearray(512); cfg[:16] = b"USOSPREP BIOS v1"
                struct.pack_into("<IIQ", cfg, 16, 0 if kind == "gpt" else 1, 512, target_bytes // 512)
                cfg[32:96] = token.encode("ascii")
                struct.pack_into("<QQ", cfg, 96, 1024**2, fixture["bytes"])
                cfg[128:130] = b"\x81\x80"
                struct.pack_into("<II", cfg, 132, 3, index)
                target.seek(1024 * 512); target.write(cfg)
                target.seek(1024**2); locked.seek(0)
                shutil.copyfileobj(locked, target, 65536)
                target.flush(); os.fsync(target.fileno())
        else:
            esp = SmallEsp(boot)
            esp.add(f"EFI/BOOT/{'BOOTX64' if arch == 'x86_64' else 'BOOTIA32'}.EFI", program.stat().st_size, api.blocks(program))
            config = (f"USOSPREP_QEMU_ONLY\nmode={kind}\ntarget_sectors={target_bytes // 512}\ntoken={token}\n"
                      f"profile=wim\nwim_index={index}\n").encode("ascii")
            esp.add("USOSPREP.CFG", len(config), [config])
            if esp.add("FIXTURES/INSTALL.WIM", fixture["bytes"], api.blocks(archive)) != fixture["sha256"]:
                raise ValueError("Embedded archive SHA differs")
            esp.finish()
        if oracle.digest_stream(locked) != fixture["sha256"]:
            raise ValueError("WIM changed during embedding")
    if oracle.digest(program) != program_sha:
        raise ValueError("Final firmware program changed during embedding")
    with (case / "target-base.raw").open("x+b") as target:
        target.truncate(target_bytes)
        target.write(b"USOSPREP TARGET v1\n" + token.encode("ascii") + b"\n")
        target.flush(); os.fsync(target.fileno())
    bases = {}
    for path in (boot, case / "target-base.raw"):
        path.chmod(stat.S_IREAD); bases[path.name] = oracle.digest(path)
    result = {"qemu_only": True, "arch": arch, "profile": "wim", "kind": kind, "target_bytes": target_bytes,
              "program": str(program), "program_sha256": program_sha, "program_footprint": footprint,
              "fixture": str(fixture_path), "wim_sha256": fixture["sha256"], "image": image, "index": index,
              "base_sha256": bases, "tree_sha256": oracle.digest(Path(image["tree"])),
              "security_sha256": oracle.digest(Path(image["security"]))}
    oracle.save(case / "prepared.json", result)
    oracle.save(case / "pool-before-prepare.json", capacity)
    return result


def guest_acceptance(status, timed_out, interrupted, log: bytes, bases_unchanged: bool) -> bool:
    return (type(status) is int and status == 33 and not timed_out and not interrupted
            and bases_unchanged and b"USOSPREP WIM PASS" in log and b"TERMINAL FAIL" not in log)


def run(case: Path, prepared: dict, qemu: Path, memory: int, cpu: str, timeout: int) -> dict:
    if not 16 <= memory <= 512 or not 60 <= timeout <= 3600 or cpu not in ("486", "pentium", "qemu32", "qemu64", "max"):
        raise ValueError("Bounded explicit memory/CPU/timeout required")
    preflight.ram_reserve(memory)
    run_dir = case / "guest"; run_dir.mkdir()
    env = oracle.environment(run_dir)
    entropy = secrets.token_bytes(64); (run_dir / "entropy.bin").write_bytes(entropy)
    for name in ("esp", "target"):
        invoke([qemu / "qemu-img.exe", "create", "-f", "qcow2", "-F", "raw", "-b", case / f"{name}-base.raw", run_dir / f"{name}.qcow2"], run_dir / f"overlay-{name}.log", env)
    bios = prepared["arch"] == "bios"
    firmware = qemu / "share" / ("bios-256k.bin" if bios else f"edk2-{'x86_64' if prepared['arch'] == 'x86_64' else 'i386'}-code.fd")
    qemu_exe = qemu / f"qemu-system-{'x86_64' if prepared['arch'] == 'x86_64' else 'i386'}.exe"
    args = [str(qemu_exe), "-machine", "pc" if bios else "q35", "-accel", "tcg,thread=multi", "-cpu", cpu,
            "-smp", "1", "-m", str(memory), "-nodefaults", "-display", "none", "-no-reboot", "-nic", "none"]
    if bios:
        args += ["-bios", str(firmware)]
    else:
        shutil.copyfile(qemu / "share/edk2-i386-vars.fd", run_dir / "vars.fd")
        args += ["-drive", f"if=pflash,format=raw,readonly=on,file={firmware}", "-drive", f"if=pflash,format=raw,file={run_dir / 'vars.fd'}"]
    args += ["-fw_cfg", f"name=opt/usosprep-entropy,file={run_dir / 'entropy.bin'}",
             "-drive", f"if=none,id=esp,format=qcow2,file={run_dir / 'esp.qcow2'}", "-device", "ide-hd,drive=esp,bus=ide.0,bootindex=1",
             "-drive", f"if=none,id=target,format=qcow2,file={run_dir / 'target.qcow2'}", "-device", "ide-hd,drive=target,bus=ide.1",
             "-device", "VGA", "-serial", f"file:{run_dir / 'serial.log'}", "-debugcon", f"file:{run_dir / 'debug.log'}",
             "-global", "isa-debugcon.iobase=0xe9", "-device", "isa-debug-exit,iobase=0xf4,iosize=0x04"]
    started = time.monotonic(); timed_out = interrupted = False; status = None
    with (run_dir / "qemu.stdout").open("xb") as stdout, (run_dir / "qemu.stderr").open("xb") as stderr:
        process = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr, env=env,
                                   creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        try:
            status = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
        except KeyboardInterrupt:
            interrupted = True
        finally:
            if status is None:
                try: process.kill()
                except ProcessLookupError: pass
                status = process.wait()
    # The owned guest handle has signalled completion before any image read.
    invoke([qemu / "qemu-img.exe", "convert", "-f", "qcow2", "-O", "raw", run_dir / "esp.qcow2", run_dir / "esp-closed.raw"], run_dir / "export-esp.log", env)
    invoke([qemu / "qemu-img.exe", "convert", "-f", "qcow2", "-O", "raw", run_dir / "target.qcow2", run_dir / "target.raw"], run_dir / "export-target.log", env)
    raw = run_dir / "target.raw"; raw.chmod(stat.S_IREAD)
    if bios:
        with (run_dir / "esp-closed.raw").open("rb") as source:
            source.seek(1025 * 512); log = source.read(1023 * 512).split(b"\0", 1)[0]
        (run_dir / "USOSPREP.LOG").write_bytes(log)
    else:
        found = api.extract_log(run_dir / "esp-closed.raw", run_dir / "USOSPREP.LOG")
        log = (run_dir / "USOSPREP.LOG").read_bytes() if found else b""
    unchanged = all(oracle.digest(case / name) == sha for name, sha in prepared["base_sha256"].items())
    passed = guest_acceptance(status, timed_out, interrupted, log, unchanged)
    result = {"qemu_only": True, "command": args, "returncode": status, "timed_out": timed_out,
              "interrupted": interrupted, "elapsed_seconds": time.monotonic() - started,
              "guest_completion_wait": True, "application_pass": passed, "bases_unchanged": unchanged,
              "target": str(raw), "target_bytes": raw.stat().st_size, "target_sha256": oracle.digest(raw),
              "entropy_sha256": hashlib.sha256(entropy).hexdigest(), "host_firmware_sha256": oracle.digest(firmware),
              "qemu_sha256": oracle.digest(qemu_exe), "program_sha256": prepared["program_sha256"],
              "memory_mib": memory, "cpu": cpu, "independent_windows_gate_not_yet_run": True,
              "cleanup_performed": False}
    if passed:
        try:
            result["memory"] = preflight.own_memory(log.decode("utf-8", "replace"), prepared["program_footprint"])
        except ValueError as error:
            result.update(application_pass=False, memory_error=str(error))
    oracle.save(case / "completed.json", result)
    return result


def windows_acceptance(record: dict, code: int, size: int) -> bool:
    guard = record.get("chkdsk_target_guard", {})
    return (type(code) is int and code == 0 and record.get("kind") == "windows-readonly-chkdsk"
            and all(record.get(key) is True for key in ("passed", "readonly_chkdsk_pass", "readonly_wim_tree_pass", "raw_security_pass", "chkdsk_issued", "dismounted", "temporary_dos_alias_removed"))
            and record.get("chkdsk_exit") == 0 and record.get("chkdsk_flags") == []
            and record.get("repair_flags_used") is False and record.get("access") == "ReadOnly"
            and guard.get("passed") is True and guard.get("readonly") is True
            and guard.get("expected_image_bytes") == size and guard.get("actual_disk_bytes") == size
            and guard.get("system") is False and guard.get("boot") is False)


def verify(case: Path, qemu: Path, pwsh: Path) -> dict:
    prepared = json.loads((case / "prepared.json").read_text())
    completed = json.loads((case / "completed.json").read_text())
    if (prepared.get("qemu_only") is not True or completed.get("qemu_only") is not True
        or completed.get("guest_completion_wait") is not True or completed.get("application_pass") is not True):
        raise ValueError("A completed, successful owned guest is required")
    expected_bytes = prepared["target_bytes"]
    target_bounds(expected_bytes, prepared["kind"])
    raw = oracle.owned(Path(completed["target"])); oracle.local(pwsh)
    if raw != case / "guest/target.raw" or oracle.digest(raw) != completed["target_sha256"] or raw.stat().st_size != expected_bytes:
        raise ValueError("Closed export size/path/SHA differs")
    for key in ("tree", "security"):
        if oracle.digest(Path(prepared["image"][key])) != prepared[key + "_sha256"]:
            raise ValueError("Independent WIM manifest changed")
    output = case / "windows-oracle"
    if any(path.exists() for path in (output, *(case / name for name in
               ("windows.stdout", "windows.stderr", "windows-invocation.json", "windows-completed.json")))):
        raise FileExistsError("Keep prior oracle evidence")
    env = os.environ.copy()
    temp = case / "guest/tmp"
    env.update(TEMP=str(temp), TMP=str(temp), APPDATA=str(temp), LOCALAPPDATA=str(temp), HOME=str(temp), USERPROFILE=str(temp))
    command = [str(pwsh), "-NoLogo", "-NoProfile", "-NonInteractive", "-File", str(REPO / "tools/tests/minios_chkdsk_readonly.ps1"),
               "-Workspace", str(case), "-RawCopy", str(raw), "-ExpectedImageBytes", str(expected_bytes),
               "-ExpectedSha256", completed["target_sha256"], "-QemuImg", str(qemu / "qemu-img.exe"), "-Out", str(output),
               "-ExpectedWimTreeJsonl", prepared["image"]["tree"], "-ExpectedWimSecurityJsonl", prepared["image"]["security"],
               "-CheckTimeoutSeconds", "900"]
    with oracle.readonly(raw), preflight.host_oracle_mutex():
        process = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True, timeout=1800, env=env,
                                 creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    with (case / "windows.stdout").open("xb") as out: out.write(process.stdout)
    with (case / "windows.stderr").open("xb") as out: out.write(process.stderr)
    oracle.save(case / "windows-invocation.json", {"command": command, "returncode": process.returncode})
    record = json.loads((output / "result.json").read_text(encoding="utf-8"))
    result = {"passed": windows_acceptance(record, process.returncode, expected_bytes),
              "result": str(output / "result.json"), "result_sha256": oracle.digest(output / "result.json"),
              "invocation": str(case / "windows-invocation.json"), "cleanup_performed": False}
    oracle.save(case / "windows-completed.json", result)
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", type=Path, required=True); parser.add_argument("--name", required=True)
    parser.add_argument("--qemu-dir", type=Path, required=True)
    commands = parser.add_subparsers(dest="action", required=True)
    run_parser = commands.add_parser("run")
    run_parser.add_argument("--arch", choices=("x86_64", "ia32", "bios"), required=True)
    run_parser.add_argument("--program", type=Path, required=True); run_parser.add_argument("--program-sha256", required=True)
    run_parser.add_argument("--bios-elf", type=Path)
    run_parser.add_argument("--fixture", type=Path, required=True); run_parser.add_argument("--index", type=int, required=True)
    run_parser.add_argument("--pool-plan", type=Path, required=True)
    run_parser.add_argument("--kind", choices=("gpt", "mbr"), default="gpt")
    run_parser.add_argument("--target-bytes", type=int, default=TARGET_BYTES)
    run_parser.add_argument("--memory", type=int, required=True); run_parser.add_argument("--cpu", required=True)
    run_parser.add_argument("--timeout", type=int, default=900)
    verify_parser = commands.add_parser("verify"); verify_parser.add_argument("--pwsh", type=Path, required=True)
    args = parser.parse_args()
    case = case_path(args.workspace, args.name, args.qemu_dir)
    if args.action == "run":
        selected = prepare(case, args.arch, args.program, args.program_sha256, args.bios_elf, args.fixture, args.index,
                           args.pool_plan, target_bytes=args.target_bytes, kind=args.kind)
        outcome = run(case, selected, args.qemu_dir, args.memory, args.cpu, args.timeout)
        passed = outcome["application_pass"]
    else:
        outcome = verify(case, args.qemu_dir, args.pwsh); passed = outcome["passed"]
    print(json.dumps(outcome)); raise SystemExit(0 if passed else 1)
