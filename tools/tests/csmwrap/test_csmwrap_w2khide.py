"""Host test: CSMWrap 3.1.2-usos11 patch 0012 (HPET / AMD GPIO hidden from
Windows 2000 in the legacy DSDT/SSDT copies).

    python tools/tests/csmwrap/test_csmwrap_w2khide.py [path-to-zig.exe]

1. Unit: src/usos_w2k_hide.inc taken out of the patch (new-file hunk) is
   built with w2khide_host_test.c (zig cc, UBSan): AMDI0030 / AMD0030 /
   PNP0103 by _HID and by _CID (string, EISA ID, Package), method and Name
   _STA, no-match IDs, unsafe shapes, malformed AML, truncations and random
   corruptions (dry run never writes, apply = dry run).
2. Integration: usos_acpi10.c from patch 0006 with the 0012 hunks applied
   here (exact context, no fuzz) is built with the existing patch 0006
   harness (acpi10_host_test.c: all its cases must still pass) and with
   w2khide_acpi10_test.c (the fixup end to end: only with legacy_fadt, RSDT
   view only, checksums, original tables untouched, bad checksum skipped).
3. Wiring: the usos11 series is 0001-0010 + 0012 (no 0011 watcher), the
   0001-0010 files are the usos10 ones byte for byte, 0012 adds no
   csmwrap.ini option and touches no SeaBIOS file.
"""
from __future__ import annotations

import hashlib
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_csmwrap_acpi10 import ROOT, find_zig, new_files  # noqa: E402

V11 = ROOT / "tools/vendor/csmwrap/3.1.2-usos11/patches"
V10 = ROOT / "tools/vendor/csmwrap/3.1.2-usos10/patches"
PATCH = V11 / "0012-w2k-hide-hpet-amd-gpio.patch"
P0006 = V11 / "0006-acpi10-view-rsdt-and-fadt-32bit-fields.patch"
HERE = Path(__file__).resolve().parent


def apply_hunks(text: str, patch: str, path: str) -> str:
    """Apply the hunks of one file of a unified diff, exact context only."""
    m = re.search(r"^--- a/" + re.escape(path) + r"\n\+\+\+ b/\S+\n", patch, re.M)
    assert m, path
    body = patch[m.end():]
    end = re.search(r"^diff ", body, re.M)
    body = body[: end.start()] if end else body
    src = text.split("\n")
    out: list[str] = []
    pos = 0
    for h in re.finditer(r"^@@ -(\d+)(?:,(\d+))? \+\d+(?:,\d+)? @@.*\n((?:[ +\-].*\n?)*)", body, re.M):
        start = int(h.group(1)) - 1
        lines = h.group(3).rstrip("\n").split("\n")
        old = [l[1:] for l in lines if l[:1] in (" ", "-")]
        new = [l[1:] for l in lines if l[:1] in (" ", "+")]
        assert src[start:start + len(old)] == old, f"{path}: hunk at {start + 1} does not match"
        out += src[pos:start] + new
        pos = start + len(old)
    out += src[pos:]
    return "\n".join(out)


def build_run(zig: str, t: Path, sources: list[Path], exe: str, marker: str) -> bool:
    env = dict(os.environ)
    env.setdefault("ZIG_GLOBAL_CACHE_DIR", str(t / "zig-cache"))
    out = t / (exe + (".exe" if os.name == "nt" else ""))
    cc = [zig, "cc", "-std=c11", "-O1", "-Wall", "-Wextra", "-Werror", "-fsanitize=undefined",
          "-fno-sanitize-recover=all", "-I", str(t), *map(str, sources), "-o", str(out)]
    r = subprocess.run(cc, capture_output=True, text=True, env=env)
    if r.returncode != 0:
        print(r.stdout, r.stderr)
        return False
    r = subprocess.run([str(out)], capture_output=True, text=True)
    print(r.stdout, end="")
    if r.returncode != 0 or marker not in r.stdout:
        print(r.stderr)
        return False
    return True


def main() -> int:
    text = PATCH.read_text(encoding="utf-8")
    files = new_files(text)
    assert set(files) == {"src/usos_w2k_hide.inc"}, sorted(files)
    inc = files["src/usos_w2k_hide.inc"]
    # own code: no includes, no I/O, no hardware access
    assert "#include" not in inc and "outb" not in inc and "inb(" not in inc
    # series: 0001-0010 unchanged from usos10, 0011 watcher dropped, 0012 added
    names = sorted(p.name for p in V11.glob("*.patch"))
    assert [n[:4] for n in names] == [f"{i:04d}" for i in range(1, 11)] + ["0012"], names
    for n in names[:-1]:
        assert hashlib.sha256((V11 / n).read_bytes()).digest() == hashlib.sha256((V10 / n).read_bytes()).digest(), n
    touched = re.findall(r"^diff --git a/(\S+)", text, re.M)
    assert touched == ["src/usos_acpi10.c", "src/usos_acpi10.h", "src/usos_w2k_hide.inc"], touched
    assert "config.c" not in text and "w2k_nmi" not in text and "INT34" not in text.split("diff --git", 1)[1]
    # gate: the hide runs inside aml_legacy_copy, which only the legacy_fadt paths call
    p6 = P0006.read_text(encoding="utf-8")
    acpi10 = new_files(p6)["src/usos_acpi10.c"]
    calls = [m.start() for m in re.finditer(r"aml_legacy_copy\(ops,", acpi10)]
    assert len(calls) == 2 and all("ops->legacy_fadt" in acpi10[c - 200:c] for c in calls)

    # pins: manifest, lock, xp_csmwrap_esp.sh; the binary has the hide, not the watcher
    import json
    vendor = V11.parent
    manifest = json.loads((vendor / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["version"] == "3.1.2-usos11"
    assert manifest["patches"] == {n: hashlib.sha256((V11 / n).read_bytes()).hexdigest() for n in names}
    for name, digest in manifest["files"].items():
        assert hashlib.sha256((vendor / name).read_bytes()).hexdigest() == digest, name
    lock = json.loads((ROOT / "tools/csmwrap_build/lock.json").read_text(encoding="utf-8"))
    assert lock["usos_version"] == "3.1.2-usos11"
    esp = (ROOT / "tools/xp_csmwrap_esp.sh").read_text(encoding="utf-8")
    assert f"PINNED={manifest['files']['csmwrapx64.efi']}" in esp
    efi = (vendor / "csmwrapx64.efi").read_bytes()
    assert b"USOS W2KHIDE" in efi and b"3.1.2-usos11" in efi and b"USOS WATCH" not in efi

    zig = find_zig()
    ok = True
    with tempfile.TemporaryDirectory() as tmp:
        t = Path(tmp)
        (t / "usos_w2k_hide.inc").write_text(inc, encoding="utf-8", newline="\n")
        ok &= build_run(zig, t, [HERE / "w2khide_host_test.c"], "w2khide_unit", "W2KHIDE-HOST-TEST PASS")
        h6 = new_files(p6)
        patched_c = apply_hunks(h6["src/usos_acpi10.c"], text, "src/usos_acpi10.c")
        patched_h = apply_hunks(h6["src/usos_acpi10.h"], text, "src/usos_acpi10.h")
        assert '#include "usos_w2k_hide.inc"' in patched_c and "usos_w2k_hide(copy, len, true" in patched_c
        (t / "usos_acpi10.c").write_text(patched_c, encoding="utf-8", newline="\n")
        (t / "usos_acpi10.h").write_text(patched_h, encoding="utf-8", newline="\n")
        ok &= build_run(zig, t, [HERE / "acpi10_host_test.c", t / "usos_acpi10.c"], "acpi10_regress", "ACPI10-HOST-TEST PASS")
        ok &= build_run(zig, t, [HERE / "w2khide_acpi10_test.c", t / "usos_acpi10.c"], "w2khide_acpi10", "W2KHIDE-ACPI10-TEST PASS")
    if not ok:
        return 1
    print("test_csmwrap_w2khide: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
