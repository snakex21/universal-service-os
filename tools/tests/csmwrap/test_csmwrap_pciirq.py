"""Host test: CSMWrap 3.1.2-usos12 patch 0015 (csmwrap.ini pci_irq_routing).

    python tools/tests/csmwrap/test_csmwrap_pciirq.py [path-to-zig.exe]
        [--e2e PATCHED_TREE DSDT.aml FACP.bin]

1. Unit: src/usos_pciirq_core.inc taken out of the patch (new-file hunk) is
   built with pciirq_host_test.c (zig cc, UBSan, -Werror): the X470 tree
   (Promontory switch without _PRT -> swizzle; I211 on LNKB, NVMe on LNKA,
   different IRQs), kept / replaced current IRQs, links without _SRS or
   _PRS, static GSIs, rows missing on a bus with a _PRT, tier 2 fallback,
   never 0/1/2/8/13, unused links untouched, $PIR records, loop guard.
2. Wiring: the key defaults to off and gates both the routing and the $PIR
   replacement; the routing runs before pir_init() (before ExitBootServices);
   only the 8259 side is written (Interrupt Line, ELCR, link _SRS); usos12 =
   usos11-int13x's series byte for byte + 0015; the 9x flow alone sets the
   key (w9x_csmwrap_target.sh -> xp_csmwrap_esp.sh).
3. --e2e (optional, needs a firmware dump that is not in the repository):
   the real src/usos_pciirq.c and uACPI from a CSMWrap tree with the usos12
   series applied run on the host against that DSDT/FADT with a simulated
   X470 PCI tree and FCH ports (pciirq_e2e_host.c): link _PRS/_CRS/_SRS
   through the firmware's own AML, Interrupt Line, ELCR, $PIR.
"""
from __future__ import annotations

import hashlib
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_csmwrap_acpi10 import ROOT, find_zig, new_files  # noqa: E402

V12 = ROOT / "tools/vendor/csmwrap/3.1.2-usos12/patches"
VX = ROOT / "tools/vendor/csmwrap/3.1.2-usos11-int13x/patches"
PATCH = V12 / "0015-pci-irq-routing.patch"
HERE = Path(__file__).resolve().parent


def sha(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


FAKE = {
    "efi.h": "#pragma once\n",
    "printf.h": "#pragma once\n#include <stdio.h>\n",
    "csmwrap.h": "#pragma once\n#include <stdbool.h>\n#include <stdint.h>\n#include <string.h>\n",
    "io.h": ("#pragma once\n#include <stdint.h>\n"
             "uint8_t pciConfigReadByte(unsigned, unsigned, unsigned, unsigned);\n"
             "uint16_t pciConfigReadWord(unsigned, unsigned, unsigned, unsigned);\n"
             "void pciConfigWriteByte(unsigned, unsigned, unsigned, unsigned, uint8_t);\n"
             "uint8_t inb(uint16_t);\nvoid outb(uint16_t, uint8_t);\n"),
}


def e2e(zig: str, tree: Path, dsdt: Path, facp: Path) -> bool:
    with tempfile.TemporaryDirectory() as td:
        t = Path(td)
        for name, body in FAKE.items():
            (t / name).write_text(body, encoding="utf-8")
        for name in ("usos_pciirq.c", "usos_pciirq.h", "usos_pciirq_core.inc", "uacpi_config.h"):
            (t / name).write_bytes((tree / "src" / name).read_bytes())
        srcs = sorted(str(p) for p in (tree / "uACPI/source").glob("*.c"))
        exe = t / ("pciirq_e2e.exe" if os.name == "nt" else "pciirq_e2e")
        env = dict(os.environ)
        env.setdefault("ZIG_GLOBAL_CACHE_DIR", str(t / "zig-cache"))
        cc = [zig, "cc", "-std=gnu11", "-O1", "-w", "-fsanitize=undefined", "-fno-sanitize-recover=all",
              "-I", str(t), "-I", str(tree / "uACPI/include"), "-DUACPI_OVERRIDE_CONFIG",
              str(t / "usos_pciirq.c"), str(HERE / "pciirq_e2e_host.c"), *srcs, "-o", str(exe)]
        r = subprocess.run(cc, capture_output=True, text=True, env=env)
        if r.returncode:
            print(r.stdout + r.stderr)
            return False
        r = subprocess.run([str(exe), str(dsdt), str(facp)], capture_output=True, text=True)
        print(r.stdout.strip())
        return r.returncode == 0 and "pciirq e2e host test PASS" in r.stdout


def main() -> int:
    args = sys.argv[1:]
    e2e_args = None
    if "--e2e" in args:
        i = args.index("--e2e")
        e2e_args = [Path(x) for x in args[i + 1:i + 4]]
        del args[i:i + 4]
    sys.argv[1:] = args
    text = PATCH.read_text(encoding="utf-8")
    files = new_files(text)
    assert set(files) == {"src/usos_pciirq.c", "src/usos_pciirq.h", "src/usos_pciirq_core.inc"}, sorted(files)
    core = files["src/usos_pciirq_core.inc"]
    assert "efi.h" not in core and "EFI_" not in core and "gBS" not in core, "core must stay EFI-free"
    for bad in ("outb(", "inb(", "pciConfig", "uacpi_"):
        assert bad not in core, bad

    # wiring
    assert "+    bool pci_irq_routing;" in text
    assert '+    } else if (streq_nocase(key, "pci_irq_routing")) {' in text
    assert "+    if (gConfig.pci_irq_routing)\n+        usos_pciirq_init();\n+\n     /* Build $PIR table" in text
    assert "+    if (gConfig.pci_irq_routing) {\n+        slot_count = usos_pciirq_fill_pir(slots, MAX_PIR_SLOTS);" in text
    glue = files["src/usos_pciirq.c"]
    assert "pciConfigWriteByte(st.buses[f->bus_idx].bus, f->dev, f->func, 0x3C, q);" in glue
    assert glue.count("pciConfigWrite") == 1, "only Interrupt Line is written"
    assert "outb(ELCR1" in glue and "outb(ELCR2" in glue and glue.count("outb(") == 2
    assert "& 0xF8" in glue and "& 0xDE" in glue, "ELCR keeps IRQ 0/1/2/8/13 edge"
    assert "_PIC" not in glue, "PIC mode: _PIC is never evaluated"
    for f in ("seabios/", "src/mptable.c", "src/acpi.c"):
        assert f"--- a/{f}" not in text, f
    # series
    names = sorted(p.name for p in V12.glob("*.patch"))
    base = sorted(p.name for p in VX.glob("*.patch"))
    assert names == sorted(base + ["0015-pci-irq-routing.patch"]), names
    for n in base:
        assert sha(V12 / n) == sha(VX / n), n
    # pins: manifest, lock, xp_csmwrap_esp.sh, release vendor dir; the binary has the key
    import json
    vendor = V12.parent
    manifest = json.loads((vendor / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["version"] == "3.1.2-usos12"
    assert manifest["patches"] == {n: sha(V12 / n) for n in names}
    for name, digest in manifest["files"].items():
        assert sha(vendor / name) == digest, name
    # the release pins moved to 3.1.2-usos14 (same 0015 file, test_csmwrap_wheel_diag.py)
    assert (ROOT / "tools/vendor/csmwrap/3.1.2-usos14/patches" / PATCH.name).read_bytes() == PATCH.read_bytes()
    efi = (vendor / "csmwrapx64.efi").read_bytes()
    assert efi[:2] == b"MZ" and b"3.1.2-usos12" in efi and b"pci_irq_routing" in efi and b"int13_boot_disk_only" in efi
    # flow: only the 9x target script asks for the key
    esp = (ROOT / "tools/xp_csmwrap_esp.sh").read_text(encoding="utf-8")
    gate = esp.index('if [ "${USOS_PCI_IRQ_ROUTING:-}" = on ]; then')
    assert gate < esp.index("pci_irq_routing = true") < esp.index("fi", gate)
    assert esp.index("pci_irq_routing = true") < esp.index('mcopy -i "$image" "$ini"')
    w9x = (ROOT / "tools/w9x_csmwrap_target.sh").read_text(encoding="utf-8")
    assert "USOS_PCI_IRQ_ROUTING=on" in w9x
    for other in ROOT.glob("tools/*.sh"):
        if other.name not in ("w9x_csmwrap_target.sh", "xp_csmwrap_esp.sh"):
            assert "USOS_PCI_IRQ_ROUTING" not in other.read_text(encoding="utf-8", errors="replace"), other

    zig = find_zig()
    with tempfile.TemporaryDirectory() as td:
        t = Path(td)
        inc = t / "usos_pciirq_core.inc"
        inc.write_text(core, encoding="utf-8")
        exe = t / ("pciirq_unit.exe" if os.name == "nt" else "pciirq_unit")
        env = dict(os.environ)
        env.setdefault("ZIG_GLOBAL_CACHE_DIR", str(t / "zig-cache"))
        cc = [zig, "cc", "-std=c11", "-O1", "-Wall", "-Wextra", "-Werror", "-fsanitize=undefined",
              "-fno-sanitize-recover=all", "-include", str(inc), str(HERE / "pciirq_host_test.c"), "-o", str(exe)]
        r = subprocess.run(cc, capture_output=True, text=True, env=env)
        if r.returncode:
            print(r.stdout + r.stderr)
            return 1
        r = subprocess.run([str(exe)], capture_output=True, text=True)
        print(r.stdout.strip())
        if r.returncode or "pciirq host test PASS" not in r.stdout:
            print(r.stderr)
            return 1
    if e2e_args and not e2e(zig, *e2e_args):
        return 1
    print("CSMWRAP-PCIIRQ-TEST PASS" + (" (with e2e)" if e2e_args else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
