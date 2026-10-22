"""Host test: NT5 start from the UEFI menu on a stick without the XP package.

    python tools/tests/test_xp_package_missing.py

X470 2026-10-22 (Kingston, build B261022-171004-34CE3CB4): Windows XP SP3
without an answer profile stopped right after Start with
"Przygotowanie XP nie powiodlo sie / Blad: NotFound / ... sprawdz log
szeregowy". The stick had no EFI\\USOS-XP (the optional "Windows XP package"
installer component was never installed), so xp_preparation.start() failed
on root.open("\\EFI\\USOS-XP\\initramfs-xp") before micro-Linux; no
uefi-start.txt and no legacy-xp-*.log were written. The answer choice was
not involved (the same happens with a profile).

Checks:
1. xp_preparation.packagePresent() looks for initramfs-xp and vmlinuz.efi,
   and start() refuses with error.XpPackageMissing before any ESP write.
2. The summary blocks Start with the localized note (no bare NotFound), and
   showError maps XpPackageMissing to the same note.
3. boot.xp_prep.package_missing exists in every locale, is UEFI-only
   (xp_prep. prefix: no Legacy Core bytes) and is in boot_strings.zig.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
KEY = "boot.xp_prep.package_missing"


def function_body(text: str, header: str) -> str:
    start = text.index(header)
    depth = 0
    for i in range(text.index("{", start), len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    raise AssertionError("unterminated " + header)


def preparation() -> None:
    text = (ROOT / "src/platform/uefi/xp_preparation.zig").read_text(encoding="utf-8")
    present = function_body(text, "pub fn packagePresent(")
    assert '\\\\EFI\\\\USOS-XP\\\\initramfs-xp' in present and '\\\\EFI\\\\USOS-XP\\\\vmlinuz.efi' in present, present
    assert "catch return false" in present
    start = function_body(text, "pub fn start(")
    gate = start.index("if (!packagePresent(root)) return error.XpPackageMissing;")
    # Nothing is written to the ESP (uefi-start.txt) before the check.
    assert gate < start.index('mark(root, "uefi-entry"'), "package check must precede the first ESP write"
    assert 'root.open(wide("\\\\EFI\\\\USOS-XP\\\\initramfs-xp"), .read, .{});\n    try initrd.close();' not in start
    print("[prep] start() refuses with XpPackageMissing before uefi-start.txt")


def summary() -> None:
    text = (ROOT / "src/platform/uefi/manual_summary.zig").read_text(encoding="utf-8")
    show = function_body(text, "pub fn show(")
    block = show[show.index("if (backend == .xp_uefi_staging) {\n        // No CSM"):]
    check = block.index('if (!@import("xp_preparation.zig").packagePresent(root)) {')
    tail = block[check:check + 300]
    assert "can_start = false;" in tail and "view.t(.xp_prep_package_missing)" in tail, tail
    # can_start is declared before the XP block uses it.
    assert show.index("var can_start = true;") < show.index("packagePresent(root)")
    err = function_body(text, "fn showError(")
    assert "error.XpPackageMissing => view.t(.xp_prep_package_missing)," in err
    print("[summary] Start blocked with the localized note; showError names the package")


def strings() -> None:
    locales = sorted((ROOT / "installer/internal/i18n/locales").glob("*.json"))
    assert len(locales) >= 27, len(locales)
    for path in locales:
        data = json.loads(path.read_text(encoding="utf-8"))
        value = data.get(KEY)
        assert value and "EFI\\USOS-XP" in value, (path.name, value)
        assert value.startswith(data["installer.components.xp.name"][:4]) or path.stem in ("pl", "lt", "lv", "hr", "sr-Latn", "sl"), (path.name, value)
    english = json.loads((ROOT / "installer/internal/i18n/locales/en.json").read_text(encoding="utf-8"))[KEY]
    zig = (ROOT / "src/i18n/boot_strings.zig").read_text(encoding="utf-8")
    assert re.search(r"^\s+xp_prep_package_missing,$", zig, re.M)
    assert "// xp_prep.package_missing" in zig
    assert json.dumps(english)[1:-1] in zig, "boot_strings.zig not regenerated"
    generate = (ROOT / "installer/internal/i18n/generate.go").read_text(encoding="utf-8")
    assert '"xp_prep."' in generate, "xp_prep. keys must stay UEFI-only"
    print("[i18n] %d locales; UEFI-only key in boot_strings.zig" % len(locales))


def main() -> int:
    preparation()
    summary()
    strings()
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
