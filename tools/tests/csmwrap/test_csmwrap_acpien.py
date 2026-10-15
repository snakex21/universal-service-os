"""Host test: CSMWrap 3.1.2-usos8 patch 0007 (ACPI mode enabled before the
legacy boot, Windows 2000 ACPI flow only; RTC A/B recorded around it).

    python tools/tests/csmwrap/test_csmwrap_acpien.py [path-to-zig.exe]

Takes src/usos_acpien.c and .h out of the patch itself (new-file hunks), so
the tested code is the shipped code, builds them with acpien_host_test.c
(zig cc, host target) and runs the cases. Also checks the wiring: the FADT
is read only when csmwrap.ini acpi_legacy_fadt = true (written only for
Windows 2000 with ACPI), and the transition runs after Legacy16PrepareToBoot
and right before Legacy16Boot.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_csmwrap_acpi10 import ROOT, find_zig, new_files  # noqa: E402

PATCH = ROOT / "tools/vendor/csmwrap/3.1.2-usos8/patches/0007-acpi-enable-before-legacy-boot.patch"
HARNESS = Path(__file__).with_name("acpien_host_test.c")


def main() -> int:
    text = PATCH.read_text(encoding="utf-8")
    files = new_files(text)
    assert set(files) == {"src/usos_acpien.c", "src/usos_acpien.h", "src/usos_acpien_efi.c"}, sorted(files)
    # wiring: armed only for the 2000 ACPI flow, run as the last step before Legacy16Boot
    prep = "+    if (gConfig.acpi_legacy_fadt)\n+        usos_acpien_efi_prepare(rsdp_copy);"
    assert prep in text, "prepare must be gated on acpi_legacy_fadt"
    run = text.index("+    usos_acpien_efi_run();")
    ctx = text[run:run + 400]
    assert " Regs.X.AX = Legacy16Boot;" in ctx and "Legacy16PrepareToBoot" not in ctx
    glue = files["src/usos_acpien_efi.c"]
    assert "if (!g_armed)\n        return;" in glue
    # result area: BDA inter-application communication area, after the MBR's 0x4F0-0x4F3
    hdr = files["src/usos_acpien.h"]
    assert "#define USOS_ACPIEN_RESULT_PHYS 0x4F4u" in hdr and "#define USOS_ACPIEN_RESULT_LEN 8u" in hdr
    # register C (read-to-clear) is never touched
    assert "0x0Cu" not in files["src/usos_acpien.c"]
    # own code only: no foreign headers in the portable part
    assert re.findall(r'#include [<"]([^>"]+)[>"]', files["src/usos_acpien.c"]) == ["usos_acpien.h"]
    # the staging writes the option for Windows 2000 with ACPI only
    esp = (ROOT / "tools/xp_csmwrap_esp.sh").read_text(encoding="utf-8")
    gate = esp.index('if [ "${USOS_W2K_ACPI:-}" = on ]; then')
    assert esp.count("acpi_legacy_fadt = true") == 1 and gate < esp.index("acpi_legacy_fadt = true") < esp.index("fi", gate)

    with tempfile.TemporaryDirectory() as tmp:
        t = Path(tmp)
        for name in ("src/usos_acpien.c", "src/usos_acpien.h"):
            (t / Path(name).name).write_text(files[name], encoding="utf-8", newline="\n")
        exe = t / ("acpien_test.exe" if os.name == "nt" else "acpien_test")
        env = dict(os.environ)
        env.setdefault("ZIG_GLOBAL_CACHE_DIR", str(t / "zig-cache"))
        cc = [find_zig(), "cc", "-std=c11", "-O1", "-Wall", "-Wextra", "-Werror", "-fsanitize=undefined",
              "-fno-sanitize-recover=all", "-I", str(t), str(HARNESS), str(t / "usos_acpien.c"), "-o", str(exe)]
        r = subprocess.run(cc, capture_output=True, text=True, env=env)
        if r.returncode != 0:
            print(r.stdout, r.stderr)
            return 1
        r = subprocess.run([str(exe)], capture_output=True, text=True)
        print(r.stdout, end="")
        if r.returncode != 0 or "ACPIEN-HOST-PASS" not in r.stdout:
            print(r.stderr)
            return 1
    print("test_csmwrap_acpien: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
