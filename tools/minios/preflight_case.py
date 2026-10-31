"""One explicitly selected pre-WIM firmware gate; blocking waits, never retries.

Targets are newly generated COWs. Existing1a/1b1 images are never reopened.
The final report must precede any cleanup. This script performs no cleanup.
"""
from __future__ import annotations
import argparse
import contextlib
import ctypes
import importlib.util
import json
from pathlib import Path
import re
import stat

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("preflight_fw", HERE / "scale_firmware_case.py")
firmware = importlib.util.module_from_spec(spec)
spec.loader.exec_module(firmware)
api, verification = firmware.api, firmware.verification


def ram_reserve(memory_mib: int):
    class Status(ctypes.Structure):
        _fields_ = [("length",ctypes.c_uint32),("load",ctypes.c_uint32)] + [(name,ctypes.c_uint64) for name in
            ("total","available","total_page","available_page","total_virtual","available_virtual","extended")]
    status=Status();status.length=ctypes.sizeof(status)
    if not ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status)):
        raise OSError("Cannot verify host RAM reserve")
    if status.available < 8*1024**3 + (memory_mib+128)*1024**2:
        raise ValueError("QEMU would violate the8GiB host RAM reserve")


@contextlib.contextmanager
def host_oracle_mutex():
    """Block on a kernel completion object; never query another verifier."""
    kernel=ctypes.WinDLL("kernel32",use_last_error=True)
    kernel.CreateMutexW.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_wchar_p]
    kernel.CreateMutexW.restype=ctypes.c_void_p
    kernel.WaitForSingleObject.argtypes=[ctypes.c_void_p,ctypes.c_uint32]
    kernel.ReleaseMutex.argtypes=[ctypes.c_void_p]
    kernel.CloseHandle.argtypes=[ctypes.c_void_p]
    handle=kernel.CreateMutexW(None,False,"Local\\USOSMiniOSPreflightReadonlyOracle")
    if not handle: raise ctypes.WinError(ctypes.get_last_error())
    acquired=False
    try:
        result=kernel.WaitForSingleObject(handle,0xffffffff)
        if result not in (0,0x80): raise OSError("Host oracle mutex wait failed")
        acquired=True
        yield
    finally:
        if acquired: kernel.ReleaseMutex(handle)
        kernel.CloseHandle(handle)


def own_memory(log: str, footprint: dict) -> dict:
    peaks = [int(n) for n in re.findall(r"(?:alloc_peak|\bpeak)=(\d+)", log)]
    if not peaks: raise ValueError("Missing actual core allocator peak")
    measured = max(peaks)
    heap = None
    if footprint["own_stack_already_in_allocator_peak"]:
        own = measured + footprint["loaded_image_bytes"] + footprint["untracked_entry_stack_budget_bytes"]
    else:
        rows = re.findall(r"HEAP physical_current=(\d+) physical_peak=(\d+) extent_peak=(\d+) reserved=(\d+)", log)
        if len(rows) != 1: raise ValueError("Missing physical BIOS heap accounting")
        current, peak, extent, reserved = map(int, rows[0])
        if current != 0 or not measured <= peak <= extent <= reserved: raise ValueError("Invalid physical heap metrics")
        heap = dict(current=current, peak=peak, extent_peak=extent, reserved=reserved)
        own = reserved + footprint["loaded_image_bytes"] + footprint["own_stack_reserved_bytes"] + footprint["thunk_and_bootstrap_low_memory_budget_bytes"]
    if own > 16 * 1024**2: raise ValueError("Own-program memory exceeds16MiB")
    return dict(allocator_peak=measured, physical_heap=heap, conservative_own_bytes=own, firmware_excluded=True)


def run(workspace: Path, name: str, arch: str, profile: str, memory: int,
        cpu: str, timeout: int, qemu: Path, source: Path, artifacts: Path, bios_elf: Path,
        expect_entropy_refusal: bool = False) -> dict:
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", name): raise ValueError("Invalid fresh case name")
    if profile not in ("scale-firmware", "scale-tree150k"): raise ValueError("Not a preflight workload")
    if not 1 <= memory <= 512 or not 60 <= timeout <= 7200: raise ValueError("Invalid explicit bounded run")
    if expect_entropy_refusal and (arch != "bios" or cpu != "486" or profile != "scale-firmware"):
        raise ValueError("Entropy refusal control requires BIOS486 without hardware RNG")
    ram_reserve(memory)
    cases, oracle = workspace.resolve() / "cases", workspace.resolve() / "oracle"
    api.configure(cases, qemu)
    verification.configure(cases, oracle, qemu, source)
    case = api.checked(cases / name)
    program = artifacts / ("usosprep-bios.img" if arch == "bios" else f"usosprep-{arch}.efi")
    footprint = firmware.program_footprint(program, arch, bios_elf)
    image_size = (16 if profile == "scale-tree150k" else 2) * 1024**3
    api.prepare(case, arch, "gpt", program, image_size, profile)
    api.save(case / "program-footprint.json", footprint)
    base_hashes = {name: api.hash_file(case / name) for name in ("esp-base.raw", "target-base.raw")}
    passed = api.execute(case, memory, timeout, cpu=cpu, entropy_input=not expect_entropy_refusal)
    result = {"stage":"pre1b2", "name":name, "arch":arch, "memory_mib":memory,
              "profile":profile, "application_pass":passed, "qemu_only":True,
              "wim_started":False, "cleanup_performed":False}
    if expect_entropy_refusal:
        run = case / f"run-{memory}m"
        closed = json.loads((run / "completed.json").read_text())
        debug = (run / "debug.log").read_bytes()
        raw = api.checked(run / "negative-target.raw")
        api.run_command([str(api.QEMU / "qemu-img.exe"), "convert", "-f", "qcow2", "-O", "raw", str(run / "target.qcow2"), str(raw)])
        raw.chmod(stat.S_IREAD)
        target_sha = api.hash_file(raw)
        esp_sha = api.hash_file(run / "esp-closed.raw")
        bases_unchanged = all(api.hash_file(case / name) == digest for name, digest in base_hashes.items())
        result.update(expected_entropy_refusal=True, target_sha256=target_sha, esp_sha256=esp_sha,
                      base_sha256=base_hashes, bases_unchanged=bases_unchanged,
                      no_target_or_boot_image_write=target_sha == base_hashes["target-base.raw"] and esp_sha == base_hashes["esp-base.raw"])
        result["passed"] = (not passed and closed["returncode"] == 35 and not closed["timed_out"]
            and b"USOSPREP TERMINAL FAIL EntropyUnavailable" in debug
            and result["no_target_or_boot_image_write"] and bases_unchanged)
    elif passed:
        with host_oracle_mutex():
            checked = firmware.verify_closed_windows(case, oracle, 3600, memory=memory)
        result["verification"] = checked
        log = (case / f"run-{memory}m/USOSPREP.LOG").read_text(errors="replace")
        result["memory"] = own_memory(log, footprint)
        result["entropy_log"] = [line for line in log.splitlines() if line.startswith("ENTROPY ")]
        result["passed"] = checked["windows_files_and_chkdsk_pass"] and checked["independent_structure_pass"]
    else:
        result["passed"] = False
    api.save(case / "preflight-completed.json", result)
    print(json.dumps(result), flush=True)
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--workspace",type=Path,required=True)
    p.add_argument("--name",required=True)
    p.add_argument("--arch",choices=("bios","ia32","x86_64"),required=True)
    p.add_argument("--profile",choices=("scale-firmware","scale-tree150k"),required=True)
    p.add_argument("--memory",type=int,required=True)
    p.add_argument("--cpu",choices=("486","pentium","qemu32","qemu64","max"),required=True)
    p.add_argument("--timeout",type=int,default=3600)
    p.add_argument("--qemu-dir",type=Path,required=True)
    p.add_argument("--source-root",type=Path,required=True)
    p.add_argument("--artifact-dir",type=Path,default=HERE.parents[1]/"zig-out/test-assets")
    p.add_argument("--bios-elf",type=Path,default=HERE.parents[1]/"zig-out/minios-bios/prep.elf")
    p.add_argument("--expect-entropy-refusal",action="store_true")
    p.add_argument("--resume-windows",action="store_true",help="Only retry the Windows oracle on a validated closed export; no VM or new image")
    a=p.parse_args()
    if a.resume_windows:
        if a.expect_entropy_refusal:raise ValueError("Cannot resume a negative-control oracle")
        cases,oracle=a.workspace.resolve()/"cases",a.workspace.resolve()/"oracle"
        api.configure(cases,a.qemu_dir)
        verification.configure(cases,oracle,a.qemu_dir,a.source_root)
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}",a.name):raise ValueError("Unsafe case name")
        case=api.checked(cases/a.name);run_dir=case/f"run-{a.memory}m"
        if (case/"preflight-completed.json").exists():raise ValueError("Never repeat an already completed case")
        prepared=json.loads((case/"prepared.json").read_text())
        done=json.loads((run_dir/"completed.json").read_text())
        if prepared.get("arch")!=a.arch or prepared.get("profile")!=a.profile or not done.get("application_pass") or done.get("returncode")!=33 or done.get("timed_out") is not False:
            raise ValueError("Only a successful, already closed application may resume its Windows oracle")
        with host_oracle_mutex():
            checked=firmware.verify_closed_windows(case,oracle,3600,memory=a.memory,attempt=2,reuse_export=True)
        log=(run_dir/"USOSPREP.LOG").read_text(errors="replace")
        result={"stage":"pre1b2","name":a.name,"arch":a.arch,"memory_mib":a.memory,"profile":a.profile,
            "application_pass":True,"qemu_only":True,"wim_started":False,"cleanup_performed":False,
            "resumed_only_windows":True,"verification":checked,
            "memory":own_memory(log,json.loads((case/"program-footprint.json").read_text())),
            "entropy_log":[line for line in log.splitlines() if line.startswith("ENTROPY ")],
            "passed":checked["windows_files_and_chkdsk_pass"] and checked["independent_structure_pass"]}
        api.save(case/"preflight-completed.json",result)
        print(json.dumps(result),flush=True)
    else:
        result=run(a.workspace,a.name,a.arch,a.profile,a.memory,a.cpu,a.timeout,a.qemu_dir,a.source_root,a.artifact_dir,a.bios_elf,a.expect_entropy_refusal)
    if not result["passed"]: raise SystemExit(1)

if __name__ == "__main__": main()
