"""Host test: CSMWrap 3.1.2-usos10 patch 0011 (read-only KeTickCount watcher on
the BIOS helper core, Windows 2000 ACPI flow only).

    python tools/tests/csmwrap/test_csmwrap_watcher.py [path-to-zig.exe]

Takes src/usos_watcher.c and .h out of the patch itself (new-file hunks), so
the tested code is the shipped code, builds them with watcher_host_test.c
(zig cc, host target, UBSan) and runs the cases: FADT ports, E820 reserved
check, mailbox validation, 80-column line, InterruptTime read, PA above
4 GiB. Also checks the wiring: everything gated on csmwrap.ini
acpi_legacy_fadt = true, no port writes in the helper code, BDA publication
limited to 0x4FC-0x4FF, CSMPPrxy served before every sample, and the pins
(manifest, lock, xp_csmwrap_esp.sh) on 3.1.2-usos10.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_csmwrap_acpi10 import ROOT, find_zig  # noqa: E402

VENDOR = ROOT / "tools/vendor/csmwrap/3.1.2-usos10"
PATCH = VENDOR / "patches/0011-w2k-acpi-tick-watcher.patch"
HARNESS = Path(__file__).with_name("watcher_host_test.c")


def new_files(patch: str) -> dict[str, str]:
    """New-file hunks of a git diff (--- /dev/null)."""
    files: dict[str, str] = {}
    pat = r"^--- /dev/null\n\+\+\+ b/(\S+)\n@@ -0,0 \+1,(\d+) @@\n"
    for m in re.finditer(pat, patch, re.M):
        lines = patch[m.end():].split("\n")[: int(m.group(2))]
        assert all(l.startswith("+") for l in lines), m.group(1)
        files[m.group(1)] = "\n".join(l[1:] for l in lines) + "\n"
    return files


def sha(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def main() -> int:
    text = PATCH.read_text(encoding="utf-8")
    files = new_files(text)
    assert set(files) == {"src/usos_watcher.c", "src/usos_watcher.h", "src/usos_watcher_efi.c",
                          "src/usos_watcher_efi.h", "seabios/src/usos_watch.c"}, sorted(files)
    # gate: the 2000 ACPI flow only; without it the trampoline argument is 0
    for call in ("usos_watcher_prepare(rsdp_copy);", "usos_watcher_verify_e820(&priv);", "usos_watcher_publish();"):
        assert f"+    if (gConfig.acpi_legacy_fadt)\n+        {call}" in text, call
    assert "gConfig.acpi_legacy_fadt ? usos_watcher_helper_pa() : 0;" in text
    # helper: watcher mode only for a page address (> 1), pending checked first
    loop = text[text.index("diff --git a/seabios/src/romlayout.S"):text.index("diff --git a/seabios/src/usos_watch.c")]
    assert loop.index(" cmpl $0, 8(%ebp)\n         jne .Lhelper_handle_request\n \n+        cmpl $1, %esi\n+        ja .Lusw_tick") > 0
    # read-only: no port writes anywhere in the new code
    for name, body in files.items():
        assert not re.search(r"\bout[bwl]?\b|outb\(|outw\(|outl\(", body), name
    # no CMOS index port, no IOAPIC (IOREGSEL) or LAPIC window in the new code
    for name, body in files.items():
        assert not re.search(r"0x70|0xFEC0|0xFEE0", body, re.I), name
    # BDA: only 0x4FC-0x4FF (0x4F4-0x4FB = patch 0007 record)
    assert "if (phys != 0x4FCu || n != 4u) return false;" in text
    assert "#define USW_BDA 0x4FCu" in files["src/usos_watcher.h"]
    # usosvid 1.3 carries the same ABI header
    assert (ROOT / "tools/w2k/usosvid/src/usos_watcher.h").read_text(encoding="utf-8") == files["src/usos_watcher.h"]
    # pins
    manifest = json.loads((VENDOR / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["version"] == "3.1.2-usos10"
    for name, digest in manifest["patches"].items():
        assert sha(VENDOR / "patches" / name) == digest, name
    assert len(manifest["patches"]) == 11
    for name, digest in manifest["files"].items():
        assert sha(VENDOR / name) == digest, name
    lock = json.loads((ROOT / "tools/csmwrap_build/lock.json").read_text(encoding="utf-8"))
    assert lock["usos_version"] == "3.1.2-usos10"
    esp = (ROOT / "tools/xp_csmwrap_esp.sh").read_text(encoding="utf-8")
    assert f"PINNED={manifest['files']['csmwrapx64.efi']}" in esp
    gate = esp.index('if [ "${USOS_W2K_ACPI:-}" = on ]; then')
    assert esp.count("acpi_legacy_fadt = true") == 1 and gate < esp.index("acpi_legacy_fadt = true") < esp.index("fi", gate)
    efi = (VENDOR / "csmwrapx64.efi").read_bytes()
    assert b"USOS WATCH" in efi and b"3.1.2-usos10" in efi

    with tempfile.TemporaryDirectory() as tmp:
        t = Path(tmp)
        for name in ("src/usos_watcher.c", "src/usos_watcher.h"):
            (t / Path(name).name).write_text(files[name], encoding="utf-8", newline="\n")
        exe = t / ("watcher_test.exe" if os.name == "nt" else "watcher_test")
        env = dict(os.environ)
        env.setdefault("ZIG_GLOBAL_CACHE_DIR", str(t / "zig-cache"))
        cc = [find_zig(), "cc", "-std=c11", "-O1", "-Wall", "-Wextra", "-Werror", "-fsanitize=undefined",
              "-fno-sanitize-recover=all", "-I", str(t), str(HARNESS), str(t / "usos_watcher.c"), "-o", str(exe)]
        r = subprocess.run(cc, capture_output=True, text=True, env=env)
        if r.returncode != 0:
            print(r.stdout, r.stderr)
            return 1
        r = subprocess.run([str(exe)], capture_output=True, text=True)
        print(r.stdout, end="")
        if r.returncode != 0 or "WATCHER-HOST-PASS" not in r.stdout:
            print(r.stderr)
            return 1
    print("test_csmwrap_watcher: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
