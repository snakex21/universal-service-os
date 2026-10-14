"""Host test: CSMWrap 3.1.2-usos7 patch 0006 (ACPI 1.0 view: RSDT from the
XSDT, 32-bit FADT fields from the X_ fields).

    python tools/tests/csmwrap/test_csmwrap_acpi10.py [path-to-zig.exe]

Takes src/usos_acpi10.c and .h out of the patch itself (new-file hunks), so
the tested code is the shipped code, builds them with acpi10_host_test.c
(zig cc, host target) and runs the cases. Also checks that the patch wires
the fixup before bios_proxy_init and that create_patched_rsdt() starts from
the RSDP copy.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PATCH = ROOT / "tools/vendor/csmwrap/3.1.2-usos7/patches/0006-acpi10-view-rsdt-and-fadt-32bit-fields.patch"
HARNESS = Path(__file__).with_name("acpi10_host_test.c")


def find_zig() -> str:
    if len(sys.argv) > 1:
        return sys.argv[1]
    for cand in (ROOT / "tools/zig/zig.exe", ROOT.parent.parent / "Desktop/usos-x470-98se/tools/zig/zig.exe"):
        if cand.exists():
            return str(cand)
    z = shutil.which("zig")
    if z:
        return z
    raise SystemExit("zig not found (pass its path)")


def new_files(patch: str) -> dict[str, str]:
    files: dict[str, str] = {}
    for m in re.finditer(r"^--- a/(\S+)\n\+\+\+ b/\S+\n@@ -0,0 \+1,(\d+) @@\n", patch, re.M):
        lines = patch[m.end():].split("\n")[: int(m.group(2))]
        assert all(l.startswith("+") for l in lines), m.group(1)
        files[m.group(1)] = "\n".join(l[1:] for l in lines) + "\n"
    return files


def main() -> int:
    text = PATCH.read_text(encoding="utf-8")
    files = new_files(text)
    assert set(files) == {"src/usos_acpi10.c", "src/usos_acpi10.h", "src/usos_acpi10_efi.c"}, sorted(files)
    # wiring: the fixup runs on the RSDP copy before the helper-core MADT patch
    call = "+    usos_acpi10_efi_fixup(rsdp_copy, gConfig.acpi_legacy_fadt);"
    assert call in text and text.index(call) < text.index(" if (bios_proxy_init(")
    # the legacy FADT is opt-in through csmwrap.ini (Windows 2000 flow only)
    assert '+    } else if (streq_nocase(key, "acpi_legacy_fadt")) {' in text
    assert "+    bool acpi_legacy_fadt;" in text
    assert "+    struct acpi_rsdt *new_rsdt = create_patched_rsdt(copy_rsdp, (uintptr_t)new_madt);" in text
    # the staging turns it on for Windows 2000 with ACPI only
    esp = (ROOT / "tools/xp_csmwrap_esp.sh").read_text(encoding="utf-8")
    gate = esp.index('if [ "${USOS_W2K_ACPI:-}" = on ]; then')
    assert esp.count("acpi_legacy_fadt = true") == 1 and gate < esp.index("acpi_legacy_fadt = true") < esp.index("fi", gate)
    assert esp.index("acpi_legacy_fadt = true") < esp.index('mcopy -i "$image" "$ini"')
    # own code only: no foreign headers in the portable part
    assert re.findall(r'#include [<"]([^>"]+)[>"]', files["src/usos_acpi10.c"]) == ["usos_acpi10.h"]

    with tempfile.TemporaryDirectory() as tmp:
        t = Path(tmp)
        for name in ("src/usos_acpi10.c", "src/usos_acpi10.h"):
            (t / Path(name).name).write_text(files[name], encoding="utf-8", newline="\n")
        exe = t / ("acpi10_test.exe" if os.name == "nt" else "acpi10_test")
        env = dict(os.environ)
        env.setdefault("ZIG_GLOBAL_CACHE_DIR", str(t / "zig-cache"))
        cc = [find_zig(), "cc", "-std=c11", "-O1", "-Wall", "-Wextra", "-Werror", "-fsanitize=undefined",
              "-fno-sanitize-recover=all", "-I", str(t), str(HARNESS), str(t / "usos_acpi10.c"), "-o", str(exe)]
        r = subprocess.run(cc, capture_output=True, text=True, env=env)
        if r.returncode != 0:
            print(r.stdout, r.stderr)
            return 1
        r = subprocess.run([str(exe)], capture_output=True, text=True)
        print(r.stdout, end="")
        if r.returncode != 0 or "ACPI10-HOST-TEST PASS" not in r.stdout:
            print(r.stderr)
            return 1
    print("test_csmwrap_acpi10: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
