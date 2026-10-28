"""Integer-MiB RAM bisection of one immutable, explicitly marked QEMU case.

Each new attempt uses uefi_case's fresh overlays and blocking completion wait.
Existing *completed* attempts may be reused, never a running guest's files.
The result is specific to this firmware, CPU and fixture workload.
"""
from __future__ import annotations
import argparse
import importlib.util
import json
from pathlib import Path

spec = importlib.util.spec_from_file_location("prep_case", Path(__file__).with_name("uefi_case.py"))
case_api = importlib.util.module_from_spec(spec)
spec.loader.exec_module(case_api)

def bisect(case: Path, timeout: int) -> dict:
    case = case_api.checked(case)
    if (case / "ram-result.json").exists():
        raise ValueError("Refusing to overwrite a RAM result")
    attempts = []
    def attempt(memory: int) -> bool:
        run = case / f"run-{memory}m"
        if run.exists():
            receipt = json.loads((run / "completed.json").read_text())
            if receipt.get("qemu_only") is not True:
                raise ValueError("Unverified existing result")
        else:
            case_api.execute(case, memory, timeout)
            receipt = json.loads((run / "completed.json").read_text())
        passed = receipt["application_pass"] is True
        attempts.append({"memory_mib": memory, "pass": passed, "receipt": str(run / "completed.json")})
        return passed
    if not attempt(64):
        raise ValueError("64 MiB acceptance must pass before minimum-RAM measurement")
    high, low = 64, 0
    for memory in (48, 40, 32, 24, 16, 8, 4, 2, 1):
        if attempt(memory):
            high = memory
        else:
            low = memory
            break
    while high - low > 1:
        memory = (high + low) // 2
        if attempt(memory): high = memory
        else: low = memory
    result = {"qemu_only": True, "minimum_mib": high, "adjacent_failure_mib": low or None, "attempts": attempts, "assumption": "monotonic capacity for this exact firmware and workload; not a physical-machine minimum"}
    case_api.save(case / "ram-result.json", result)
    return result

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("case", type=Path)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--qemu-dir", type=Path, required=True)
    parser.add_argument("--timeout", type=int, default=420)
    args = parser.parse_args()
    case_api.configure(args.workspace, args.qemu_dir)
    print(json.dumps(bisect(args.case, args.timeout)))

if __name__ == "__main__": main()
