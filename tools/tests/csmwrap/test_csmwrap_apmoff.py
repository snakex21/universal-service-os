"""Host test: CSMWrap 3.1.2-usos8 patches 0008 + 0009 (APM power-off: helper-core
ResetSystem, then a direct ACPI S5 write with SLP_TYP from \\_S5; SeaBIOS
debug output on the serial port with csmwrap.ini serial = true).

    python tools/tests/csmwrap/test_csmwrap_apmoff.py [path-to-zig.exe] [DSDT.bin=typ ...]

Takes seabios/src/fw/usos_s5.h out of the patch itself (new-file hunk), so
the tested parser is the shipped one, builds it with apmoff_host_test.c (zig
cc, host target, UBSan + exact-size buffers for every truncation) and runs
the cases: QEMU pc/q35 _S5 {0,0,0,0} -> SLP_TYP 0, the X470 _S5 {5,0,0,0} ->
5 (PM1a_CNT write 0x3400). Extra DSDT/SSDT dumps can be checked with
path=expected-SLP_TYPa. Also checks the wiring in the patch: the
protected-mode entries never reach bios_proxy_reset()/call32(), the
INT 15h path asks the helper first, and a failed power-off returns AH=60h.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_csmwrap_acpi10 import ROOT, new_files  # noqa: E402
import test_csmwrap_acpi10  # noqa: E402

PATCH = ROOT / "tools/vendor/csmwrap/3.1.2-usos8/patches/0008-apm-poweroff.patch"
PATCH_0009 = ROOT / "tools/vendor/csmwrap/3.1.2-usos8/patches/0009-apm-poweroff-acpi-first-cmos-breadcrumbs.patch"
HARNESS = Path(__file__).with_name("apmoff_host_test.c")


def check_0009() -> None:
    """Patch 0009 (usos8) wiring: ACPI mode -> quiesce -> S5 before the helper,
    bounded waits, CMOS breadcrumbs written as valid alarm values with own
    port I/O (hw/rtc.c is not linked into the 32-bit segmented code)."""
    text = PATCH_0009.read_text(encoding="utf-8")
    apm = text[text.index("--- a/seabios/src/apm.c"):text.index("--- a/seabios/src/fw/biostables.c")]
    added = "\n".join(l[1:] for l in apm.splitlines() if l.startswith("+"))
    new = "\n".join(l[1:] for l in apm.splitlines() if l[:1] in ("+", " ") and not l.startswith("+++"))
    assert "rtc_read" not in added and "rtc_write" not in added
    assert "bios_proxy_reset" not in added and "call32" not in added
    body = new[new.index("usos_apmoff(u8 path)\n{"):]
    body = body[:body.index("\n}")]
    assert body.index("usos_apmoff_s5(path)") < body.index("usos_apmoff_helper(path, flags)")
    assert "if (path != USOS_APMOFF_PM16)" in body  # no mailbox from 16-bit PM
    s5 = new[new.index("usos_apmoff_s5(u8 path)\n{"):]
    s5 = s5[:s5.index("\n}")]
    order = [s5.index(k) for k in ("outb(en, smi);", "usos_s5_quiesce();", "usos_s5_write();", "usos_apmoff_wait(2000);")]
    assert order == sorted(order), order
    assert "i < 20 && !(inw(a) & 1)" in s5  # ACPI enable poll: 20 x 50 ms
    assert "while (waited < limit && spins++ < spin_limit)" in added  # spin bound
    # valid alarm encoding (edk2 PcRtcInit resets invalid alarm bytes)
    assert "usos_crumb_put(USOS_CRUMB_STEP, 40 + (step & 0x0f));" in added
    assert "usos_crumb_put(USOS_CRUMB_CALLS, (path & 3) * 15 + n);" in added
    assert "usos_crumb_put(USOS_CRUMB_FNS, 1 + (v | bit));" in added
    assert "if (n < 14)" in added
    for v in [40 + s for s in range(16)] + [p * 15 + n for p in range(4) for n in range(15)]:
        assert 0 <= v <= 59
    assert all(1 <= 1 + b <= 8 for b in range(8))
    # interrupts off around each CMOS index/data pair
    rd = new[new.index("usos_cmos_rd(u8 index)\n{"):]
    rd = rd[:rd.index("\n}")]
    assert rd.index("irq_disable();") < rd.index("outb(index | NMI_DISABLE_BIT, PORT_CMOS_INDEX);") < rd.index("restore_flags(flags);")
    csm = text[text.index("--- a/seabios/src/fw/csm.c"):]
    assert "+        usos_apm_crumb_arm();" in csm
    print("0009 wiring: PASS")


def main() -> int:
    args = sys.argv[1:]
    zig_arg = [a for a in args if "=" not in a]
    dumps = [a for a in args if "=" in a]
    sys.argv = sys.argv[:1] + zig_arg[:1]
    zig = test_csmwrap_acpi10.find_zig()

    text = PATCH.read_text(encoding="utf-8")
    files = new_files(text)
    assert set(files) == {"seabios/src/fw/usos_s5.h"}, sorted(files)
    hdr = files["seabios/src/fw/usos_s5.h"]
    # own code only: the parser has no includes at all
    assert not re.findall(r"#include", hdr)

    # wiring (added lines of apm.c)
    apm = text[text.index("--- a/seabios/src/apm.c"):text.index("--- a/seabios/src/fw/biostables.c")]
    added = "\n".join(l[1:] for l in apm.splitlines() if l.startswith("+"))
    assert "bios_proxy_reset" not in added and "call32" not in added
    assert "-    bios_proxy_reset(3);" in apm, "apm_shutdown must stop calling bios_proxy_reset (real-mode segments)"
    shut = added[added.index("apm_shutdown(void)"):]
    assert shut.index("usos_apmoff_helper(USOS_APMOFF_INT15)") < shut.index("usos_apmoff_s5(USOS_APMOFF_INT15")
    hook = added[added.index("if (regs->ax == 0x5307 && regs->bx == 1 && regs->cx == 3)"):]
    hook = hook[:hook.index("return;") + len("return;")]
    assert "if (!MODE16)\n            flags = usos_apmoff_helper(path);" in hook  # 16-bit PM: no mailbox
    assert "set_code_invalid_silent(regs, 0x60);" in hook
    assert "+        set_code_invalid_silent(regs, 0x60);\n+        return;" in apm  # INT 15h 5307h CX=3
    # the timed mailbox call writes through %es=F000h (real/V86) or %gs (32-bit PM) only
    stacks = text[text.index("--- a/seabios/src/stacks.c"):text.index("--- a/seabios/src/std/LegacyBios.h")]
    assert "SET_FARVAR(SEG_BIOS, bios_proxy.field" in stacks and "SET_VAR(GS," in stacks
    assert "find_bios_proxy" not in "\n".join(l for l in stacks.splitlines() if l.startswith("+"))
    # serial debug output only when CSMWrap asks for it (csmwrap.ini serial = true)
    assert "+    if (gConfig.serial_debug) {\n+        priv.csm_efi_table->CsmwrapFlags |= CSMWRAP_FLAG_SERIAL;" in text
    assert "+    if (csm_compat_table.CsmwrapFlags & CSMWRAP_FLAG_SERIAL)\n+        UsosDebugSerialPort = csm_compat_table.CsmwrapSerialPort;" in text
    # both copies of LegacyBios.h get the same field
    assert text.count("+  UINT16                            CsmwrapSerialPort;") == 2

    check_0009()

    with tempfile.TemporaryDirectory() as tmp:
        t = Path(tmp)
        (t / "usos_s5.h").write_text(hdr, encoding="utf-8", newline="\n")
        exe = t / ("apmoff_test.exe" if os.name == "nt" else "apmoff_test")
        env = dict(os.environ)
        env.setdefault("ZIG_GLOBAL_CACHE_DIR", str(t / "zig-cache"))
        cc = [zig, "cc", "-std=c11", "-O1", "-Wall", "-Wextra", "-Werror", "-fsanitize=undefined",
              "-fno-sanitize-recover=all", "-I", str(t), str(HARNESS), "-o", str(exe)]
        r = subprocess.run(cc, capture_output=True, text=True, env=env)
        if r.returncode != 0:
            print(r.stdout, r.stderr)
            return 1
        r = subprocess.run([str(exe), *dumps], capture_output=True, text=True)
        print(r.stdout, end="")
        if r.returncode != 0 or "APMOFF-HOST-PASS" not in r.stdout:
            print(r.stderr)
            return 1
    print("test_csmwrap_apmoff: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
