"""Completed-workload CPU and adjacent-RAM evidence; fresh COW per trial.

No status polling. Each guest has a bounded blocking completion wait. Below
the firmware boot threshold a timeout is an observed failure, not a claim
about the theoretical RAM/ISA needs of every firmware implementation.
"""
from __future__ import annotations
import argparse
import importlib.util
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("cpu_ram_firmware", HERE / "scale_firmware_case.py")
firmware = importlib.util.module_from_spec(spec)
spec.loader.exec_module(firmware)
api, verification = firmware.api, firmware.verification


class Suite:
    def __init__(self, runtime: Path, workspace: Path, primary: Path, qemu: Path, source: Path):
        self.runtime, self.workspace, self.primary = runtime.resolve(), workspace.resolve(), primary.resolve()
        self.cases, self.oracle = self.workspace / "cases", self.workspace / "oracle"
        api.configure(self.cases, qemu)
        verification.configure(self.cases, self.oracle, qemu, source)
        self.workspace.mkdir(parents=True, exist_ok=False)
        self.attempts = {arch: [] for arch in ("bios", "ia32", "x86_64")}
        self.targets = {}
        for arch in self.attempts:
            base = self.primary / "cases" / f"scale-{arch}-gpt"
            prepared = json.loads((base / "prepared.json").read_text())
            closed = json.loads((base / "run-64m/completed.json").read_text())
            if closed.get("application_pass") is not True or closed.get("returncode") != 33:
                raise ValueError("A passing closed primary64MiB workload is required")
            program = Path(prepared["efi"])
            digest = prepared["hashes"]["bios_build" if arch == "bios" else "efi"]
            if api.hash_file(program) != digest: raise ValueError("Primary application artifact changed")
            self.targets[arch] = {"program": program, "sha256": digest,
                                  "baseline_seconds": closed["elapsed_seconds"], "primary_case": base}
            self.record(arch, base, 64)

    def record(self, arch: str, case: Path, memory: int) -> dict:
        run = case / f"run-{memory}m"
        receipt = json.loads((run / "completed.json").read_text())
        command = receipt["command"]
        value = {"cpu": command[command.index("-cpu") + 1], "memory_mib": memory,
                 "application_pass": receipt["application_pass"],
                 "receipt": (run / "completed.json").relative_to(self.runtime).as_posix(),
                 "timeout_seconds": receipt.get("timeout_seconds"),
                 "elapsed_seconds": receipt["elapsed_seconds"]}
        if (run / "USOSPREP.LOG").exists():
            value["log"] = (run / "USOSPREP.LOG").relative_to(self.runtime).as_posix()
        self.attempts[arch].append(value)
        return value

    def trial(self, arch: str, cpu: str, memory: int) -> dict:
        case = api.checked(self.cases / (arch + "-" + cpu))
        target = self.targets[arch]
        if not case.exists():
            if api.hash_file(target["program"]) != target["sha256"]:
                raise ValueError("CPU/RAM test artifact changed after its primary gate")
            api.prepare(case, arch, "gpt", target["program"], 2 * 1024**3, profile="scale-firmware")
        if (case / f"run-{memory}m").exists():
            raise ValueError("A trial cannot be rerun/overwritten")
        timeout = min(1800, max(180, int(target["baseline_seconds"] * 6)))
        api.execute(case, memory, timeout, cpu=cpu)
        result = self.record(arch, case, memory)
        print(json.dumps({"completed_trial": result}), flush=True)
        return result

    def minimum(self, arch: str, cpu: str, passing_memory: int) -> tuple[int, int]:
        high = passing_memory
        while high > 1:
            proposed = max(1, high // 2)
            trial = self.trial(arch, cpu, proposed)
            if trial["application_pass"]:
                high = proposed
            else:
                low = proposed
                break
        else:
            raise ValueError("RAM1MiB passed; no supported adjacent lower machine size exists")
        while high - low > 1:
            middle = (high + low) // 2
            trial = self.trial(arch, cpu, middle)
            if trial["application_pass"]: high = middle
            else: low = middle
        return high, low

    def bios32_windows(self, cpu: str) -> dict:
        case = self.cases / ("bios-" + cpu)
        result = firmware.verify_closed_windows(case, self.oracle, 1800, memory=32)
        if not result["windows_files_and_chkdsk_pass"] or not result["independent_structure_pass"]:
            raise ValueError("Mandatory BIOS32MiB independent Windows/structure gate failed: " + cpu)
        return {"cpu": cpu, "memory_mib": 32, "passed": True,
                "verification": (self.oracle / "inputs" / case.name / "verification.json").relative_to(self.runtime).as_posix()}

    def run(self):
        architectures = {}
        for cpu in ("486", "pentium"):
            if not self.trial("bios", cpu, 32)["application_pass"]:
                raise ValueError("Mandatory BIOS " + cpu + "32MiB workload failed")
        bios_windows = [self.bios32_windows(cpu) for cpu in ("486", "pentium")]
        minimum, lower = self.minimum("bios", "486", 32)
        architectures["bios"] = {"artifact_sha256": self.targets["bios"]["sha256"],
            "application_cpu_baseline": "i486", "minimum_ram_mib": minimum,
            "preceding_failure_ram_mib": lower, "qemu_cpu_runs": self.attempts["bios"],
            "minimum_scope": "Completed scaling workload with SeaBIOS and QEMU486; adjacent lower attempted; independent Windows gates also passed for486/Pentium32MiB",
            "firmware_cpu_requirements": "Both QEMU486 and Pentium complete the workload at32MiB; BDA clock and fw_cfg PIO entropy use no post486 clock/RNG instructions",
            "mandatory32mib_windows": bios_windows}
        selected = None
        for cpu in ("486", "pentium", "pentium2", "pentium3", "qemu32"):
            trial = self.trial("ia32", cpu, 64)
            if trial["application_pass"]:
                selected = cpu
                break
        selected = selected or "max"
        minimum, lower = self.minimum("ia32", selected, 64)
        architectures["ia32"] = {"artifact_sha256": self.targets["ia32"]["sha256"],
            "application_cpu_baseline": "i486",
            "application_isa_audit": "Generated assembly audited without SIMD/CMOV",
            "minimum_ram_mib": minimum, "preceding_failure_ram_mib": lower,
            "qemu_cpu_runs": self.attempts["ia32"],
            "minimum_scope": "Completed scaling workload plus bundled IA32 OVMF on " + selected + "; adjacent lower attempted; lower firmware CPU probes recorded separately",
            "firmware_cpu_requirements": "Lowest passing tested model at64MiB: " + selected + "; this firmware result is separate from the application's compiled i486 ISA baseline"}
        trial = self.trial("x86_64", "qemu64", 64)
        selected = "qemu64" if trial["application_pass"] else "max"
        minimum, lower = self.minimum("x86_64", selected, 64)
        architectures["x86_64"] = {"artifact_sha256": self.targets["x86_64"]["sha256"],
            "application_cpu_baseline": "x86_64",
            "application_isa_audit": "SSE2 is part of the x86_64 baseline ISA",
            "minimum_ram_mib": minimum, "preceding_failure_ram_mib": lower,
            "qemu_cpu_runs": self.attempts["x86_64"],
            "minimum_scope": "Completed scaling workload plus bundled x64 OVMF on " + selected + "; adjacent lower attempted",
            "firmware_cpu_requirements": "Lowest tested passing64bit model: " + selected + "; not a claim about every physical x86_64 implementation"}
        result = {"schema": 1, "kind": "minios-1b1-cpu-ram", "complete": True,
                  "architectures": architectures, "hardware_verified": False,
                  "timeout_scope": "Each attempt waits for completion; observed failures include bounded firmware timeouts; no progress polling"}
        path = self.runtime / "validation/cpu-ram.json"
        with path.open("x", encoding="utf-8", newline="\n") as output:
            json.dump(result, output, ensure_ascii=False, indent=2); output.write("\n")
        print(json.dumps({"complete": True, "summary": str(path)}), flush=True)
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--primary", type=Path, required=True)
    parser.add_argument("--qemu-dir", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, required=True)
    args = parser.parse_args()
    Suite(args.runtime, args.workspace, args.primary, args.qemu_dir, args.source_root).run()


if __name__ == "__main__": main()
