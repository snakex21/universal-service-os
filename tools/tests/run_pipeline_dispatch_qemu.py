#!/usr/bin/env python3
"""M3: the real /usos-init dispatches through tools/pipeline/run.sh (QEMU, TCG).

Boots a micro-Linux kernel + initramfs with rdinit=/usos-init and the
Windows-native test stick (tools/tests/artifacts/windows-native/stick.vhd,
built by tools/tests/windows_native/new_native_stick.ps1) attached with
snapshot=on: nothing the VM writes reaches the image. Each case passes a
Core-style command line and checks the serial log:

  xp-staging + usos.plan_profile=nt5-staging  -> step 100 runs the NT5 staging
                                                (stops: the ISO is not on DATA)
  xp-staging, no token (SeaBIOS: no EFI)      -> nt5-staging from the action table
  xp-resume + nt5-resume                      -> step 150 runs legacy_xp_resume.sh
                                                (refused: nothing to resume)
  windows7-iso + windows-pe-bios-iso          -> step 500 request, then step 200
                                                (the WORK body; stops: no Windows 7 ISO)
  xp-staging + windows-pe-bios-iso            -> refused before any step runs
  no legacy action (WORK)                     -> no pipeline line before the state
                                                check (stick state is phase=pending)

    python tools/tests/run_pipeline_dispatch_qemu.py [--micro-linux DIR]

DIR defaults to zig-out/micro-linux. SeaBIOS, AHCI; no physical disk.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
QEMU = ROOT / "tools" / "qemu" / "qemu-system-x86_64.exe"
STICK = ROOT / "tools" / "tests" / "artifacts" / "windows-native" / "stick.vhd"
OUT = ROOT / "tools" / "tests" / "artifacts" / "pipeline-dispatch"

CASES = [
    # label, command-line tail, expected serial fragments, forbidden fragments
    ("xp-token", "usos.legacy_action=xp-staging usos.legacy_image_hex=%s usos.bios_boot_drive=80 usos.plan_profile=nt5-staging",
     ["[PIPELINE] profile=nt5-staging steps=100 source=cmdline", "[PIPELINE] step 100 nt5_staging", "[MICRO-LINUX] STOP:"], ["[PIPELINE] step 200"]),
    ("xp-action", "usos.legacy_action=xp-staging usos.legacy_image_hex=%s usos.bios_boot_drive=80",
     ["[PIPELINE] profile=nt5-staging steps=100 source=action", "[PIPELINE] step 100 nt5_staging", "[MICRO-LINUX] STOP:"], []),
    ("xp-resume", "usos.legacy_action=xp-resume usos.plan_profile=nt5-resume",
     ["[PIPELINE] profile=nt5-resume steps=150 source=cmdline", "[PIPELINE] step 150 nt5_resume", "XP resume refused"], []),
    ("win7-bios", "kexec_load_disabled=0 usos.legacy_action=windows7-iso usos.legacy_image_hex=%s usos.bios_boot_drive=80 usos.plan_profile=windows-pe-bios-iso",
     ["[PIPELINE] profile=windows-pe-bios-iso steps=500 200 source=cmdline", "[PIPELINE] step 500 windows_pe_bios_request",
      "[WINDOWS_BIOS] REQUEST", "[PIPELINE] step 200 work_prepare", "[MICRO-LINUX] STOP:"], []),
    ("mismatch", "usos.legacy_action=xp-staging usos.legacy_image_hex=%s usos.plan_profile=windows-pe-bios-iso",
     ["profile token windows-pe-bios-iso does not match action xp-staging", "[MICRO-LINUX] STOP: unsupported Legacy action: xp-staging"], ["[PIPELINE] step"]),
    ("work", "",
     ["[MICRO-LINUX] STOP: refusing preparation from phase=pending"], ["[PIPELINE]"]),
]


def esp_partuuid() -> str:
    """ESP UniqueGUID from the read-only GPT snapshot refresh_stick.ps1 takes."""
    import json
    for snapshot in sorted((ROOT / "tools" / "tests" / "artifacts" / "windows-native").glob("baseline*/gpt.json")):
        data = json.loads(snapshot.read_text(encoding="utf-8-sig"))
        stack = [data]
        while stack:
            item = stack.pop()
            if isinstance(item, dict):
                if str(item.get("TypeGUID", "")).lower() == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b":
                    return str(item["UniqueGUID"]).lower()
                stack.extend(item.values())
            elif isinstance(item, list):
                stack.extend(item)
    raise SystemExit("ESP GUID unknown: run tools/tests/windows_native/refresh_stick.ps1 first")


def run_case(label: str, tail: str, micro: Path, uuid: str, timeout: float = 240) -> str:
    serial = OUT / f"{label}.serial.log"
    serial.unlink(missing_ok=True)
    append = f"console=tty0 console=ttyS0,115200 loglevel=3 rdinit=/usos-init usos.esp_partuuid={uuid}"
    if tail:
        append += " " + (tail % "58502e69736f" if "%s" in tail else tail)
    command = [str(QEMU), "-machine", "q35", "-accel", "tcg,thread=multi", "-cpu", "max", "-m", "1536", "-smp", "2",
               "-display", "none", "-nic", "none", "-serial", f"file:{serial.as_posix()}", "-monitor", "none",
               "-kernel", str(micro / "vmlinuz-virt"), "-initrd", str(micro / "initramfs-usos"), "-append", append,
               "-drive", f"if=none,id=stick,format=vpc,snapshot=on,file={STICK.as_posix()}",
               "-device", "ide-hd,drive=stick,bus=ide.0,serial=USOSSTICK"]
    process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=open(OUT / f"{label}.stderr.log", "wb"))
    deadline = time.time() + timeout
    text = ""
    try:
        while time.time() < deadline:
            time.sleep(3)
            text = serial.read_text(encoding="utf-8", errors="replace") if serial.exists() else ""
            if "[MICRO-LINUX] STOP:" in text or "emergency shell available" in text:
                time.sleep(3)
                text = serial.read_text(encoding="utf-8", errors="replace")
                break
    finally:
        process.kill()
        process.wait()
    return text


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--micro-linux", type=Path, default=ROOT / "zig-out" / "micro-linux")
    parser.add_argument("--only", nargs="*")
    args = parser.parse_args()
    micro = args.micro_linux.resolve()
    for required in (QEMU, STICK, micro / "vmlinuz-virt", micro / "initramfs-usos"):
        if not required.exists():
            raise SystemExit(f"missing {required}")
    OUT.mkdir(parents=True, exist_ok=True)
    uuid = esp_partuuid()
    failures = 0
    for label, tail, expected, forbidden in CASES:
        if args.only and label not in args.only:
            continue
        text = run_case(label, tail, micro, uuid)
        for fragment in expected:
            ok = fragment in text
            failures += not ok
            print(("[PASS] " if ok else "[FAIL] ") + f"{label}: {fragment}")
        for fragment in forbidden:
            ok = fragment not in text
            failures += not ok
            print(("[PASS] " if ok else "[FAIL] ") + f"{label}: no {fragment}")
        stops = [line for line in text.splitlines() if "STOP:" in line or "[PIPELINE]" in line]
        print("       " + " | ".join(stops[-4:]))
    print("[RESULT] %d failure(s)" % failures)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
