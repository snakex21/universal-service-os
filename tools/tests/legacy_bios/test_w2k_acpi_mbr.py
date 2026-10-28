#!/usr/bin/env python3
"""Run the Windows 2000 ACPI MBR (w2k-acpi-mbr-440.bin) in x86 emulation.

The exact 440-byte artifact boots with synthetic firmware state modelled on
the X470 behind CSMWrap: HPET at FED00000h with LegacyReplacement set, an
RSDP in the F segment, an RSDT listing FACP (-> DSDT), an SSDT and an APIC
table.  The DSDT holds namespace-level Name(xxxx, QWordConst) objects like
the X470's \\_SB.PCI0 MAB/MAL/MAM.  PASS means:
  - HPET general configuration bit 1 cleared, bit 0 kept;
  - every Name(NNNN, QWordConst) became Name(NNNN, DWordConst) + 4 NoopOps,
    values above 4 GiB became 0;
  - byte patterns that are not a NameSeg are left alone;
  - the DSDT and SSDT checksums are valid, the APIC table is untouched;
  - the MBR still reaches the VBR handoff once, with DL = boot drive.
A second run without RSDP/HPET checks the fail-safe path.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import struct
import sys

try:
    from unicorn import Uc, UC_ARCH_X86, UC_MODE_16, UC_HOOK_CODE, UC_HOOK_INTR
    from unicorn.x86_const import (
        UC_X86_REG_AH, UC_X86_REG_CS, UC_X86_REG_DL, UC_X86_REG_DS,
        UC_X86_REG_EFLAGS, UC_X86_REG_IP,
    )
except ImportError as exc:  # pragma: no cover
    raise SystemExit("unicorn Python package is required: python -m pip install unicorn") from exc

BOOT = 0x7C00
HPET = 0xFED00000
RSDP = 0xF6A40
RSDT = 0x00200000
FACP = 0x00201000
DSDT = 0x00202000
SSDT = 0x00204000
APIC = 0x00205000


def table(sig: bytes, body: bytes, rev: int = 2) -> bytes:
    raw = bytearray(sig + struct.pack("<IB", 36 + len(body), rev) + b"\0" + b"ALASKA" + b"A M I   " + struct.pack("<I", 1) + b"USOS" + struct.pack("<I", 1) + body)
    raw[9] = (-sum(raw)) & 0xFF
    return bytes(raw)


def name_q(seg: bytes, value: int) -> bytes:
    return b"\x08" + seg + b"\x0E" + struct.pack("<Q", value)


def name_d(seg: bytes, value: int) -> bytes:
    return b"\x08" + seg + b"\x0C" + struct.pack("<I", value) + b"\xA3" * 4


# Scope(\_SB.PCI0)-like content: three QWord names, a DWord name, and a
# Buffer whose bytes look like NameOp/QWordPrefix but with a non-ASCII seg.
DSDT_BODY = (
    name_q(b"MAB_", 0) + name_q(b"MAL_", 0x1_0000_0000) + name_q(b"M4N1", 0xFEDC_BA98)
    + b"\x08HPTB\x0C\x00\x00\xD0\xFE"
    + b"\x11\x0F\x0A\x0D" + b"\x08\x81\x82\x83\x84\x0E" + b"\x11" * 7
    + b"\x08" + b"1BAD" + b"\x0E" + b"\x22" * 8
)
DSDT_WANT = (
    name_d(b"MAB_", 0) + name_d(b"MAL_", 0) + name_d(b"M4N1", 0xFEDC_BA98)
    + b"\x08HPTB\x0C\x00\x00\xD0\xFE"
    + b"\x11\x0F\x0A\x0D" + b"\x08\x81\x82\x83\x84\x0E" + b"\x11" * 7
    + b"\x08" + b"1BAD" + b"\x0E" + b"\x22" * 8
)
SSDT_BODY = name_q(b"SQW_", 0x1234)
SSDT_WANT = name_d(b"SQW_", 0x1234)
APIC_BODY = name_q(b"NOPE", 7)  # not a DSDT/SSDT: must stay as is


def sector0(code440: bytes) -> bytes:
    s = bytearray(512)
    s[:440] = code440
    s[446] = 0x80
    s[450] = 0x07
    s[454:458] = (2048).to_bytes(4, "little")
    s[458:462] = (4194304).to_bytes(4, "little")
    s[510:512] = b"\x55\xaa"
    return bytes(s)


def run(code440: bytes, firmware: bool) -> Uc:
    uc = Uc(UC_ARCH_X86, UC_MODE_16)
    uc.mem_map(0, 0x300000)
    uc.mem_map(HPET, 0x1000)
    if firmware:
        uc.mem_write(HPET, struct.pack("<I", 0x8086A201))
        uc.mem_write(HPET + 0x10, struct.pack("<I", 3))
        rsdp = bytearray(b"RSD PTR " + b"\0" + b"ALASKA" + b"\x02" + struct.pack("<I", RSDT))
        rsdp[8] = (-sum(rsdp)) & 0xFF
        uc.mem_write(RSDP, bytes(rsdp))
        uc.mem_write(RSDT, table(b"RSDT", struct.pack("<III", FACP, SSDT, APIC), 1))
        uc.mem_write(FACP, table(b"FACP", b"\0" * 4 + struct.pack("<I", DSDT) + b"\0" * 76, 6))
        uc.mem_write(DSDT, table(b"DSDT", DSDT_BODY))
        uc.mem_write(SSDT, table(b"SSDT", SSDT_BODY))
        uc.mem_write(APIC, table(b"APIC", APIC_BODY))
    else:
        uc.mem_write(HPET, b"\xff" * 0x20)
    uc.mem_write(BOOT, sector0(code440))
    vbr = bytearray(512)
    vbr[0x18:0x1A] = (63).to_bytes(2, "little")
    vbr[0x1A:0x1C] = (255).to_bytes(2, "little")
    vbr[510:] = b"\x55\xaa"
    state = {"boot": 0, "handoff": False, "dl": None, "ds": None}

    def on_code(emu: Uc, address: int, _size: int, _user: object) -> None:
        if address == BOOT:
            state["boot"] += 1
            if state["boot"] == 2:
                state["handoff"] = True
                state["dl"] = emu.reg_read(UC_X86_REG_DL)
                state["ds"] = emu.reg_read(UC_X86_REG_DS)
                emu.emu_stop()

    def on_intr(emu: Uc, intno: int, _user: object) -> None:
        if intno != 0x13:
            raise RuntimeError(f"unexpected interrupt 0x{intno:02X}")
        ah = emu.reg_read(UC_X86_REG_AH)
        flags = emu.reg_read(UC_X86_REG_EFLAGS)
        if ah == 0x42:
            emu.mem_write(BOOT, bytes(vbr))
        elif ah != 0x08:
            raise RuntimeError(f"unexpected INT 13h AH=0x{ah:02X}")
        emu.reg_write(UC_X86_REG_EFLAGS, flags | 1 if ah == 0x08 else flags & ~1)
        emu.reg_write(UC_X86_REG_AH, 1 if ah == 0x08 else 0)

    uc.hook_add(UC_HOOK_CODE, on_code)
    uc.hook_add(UC_HOOK_INTR, on_intr)
    uc.reg_write(UC_X86_REG_CS, 0)
    uc.reg_write(UC_X86_REG_IP, BOOT)
    uc.reg_write(UC_X86_REG_DL, 0x80)
    uc.reg_write(UC_X86_REG_EFLAGS, 0x202)
    uc.emu_start(BOOT, 0xFFFFFFFF, count=2_000_000)
    if not state["handoff"]:
        raise AssertionError("VBR handoff not reached")
    if state["dl"] != 0x80 or state["ds"] != 0:
        raise AssertionError(f"handoff registers DL={state['dl']:#x} DS={state['ds']:#x}")
    return uc


def check_table(uc: Uc, addr: int, sig: bytes, want_body: bytes) -> None:
    length = struct.unpack("<I", bytes(uc.mem_read(addr + 4, 4)))[0]
    raw = bytes(uc.mem_read(addr, length))
    if raw[:4] != sig:
        raise AssertionError(f"{sig!r}: signature lost")
    if sum(raw) & 0xFF:
        raise AssertionError(f"{sig!r}: checksum invalid")
    if raw[36:] != want_body:
        raise AssertionError(f"{sig!r}: body\n  got  {raw[36:].hex()}\n  want {want_body.hex()}")


def check_wiring(root: Path) -> None:
    """The artifact is built, packaged, selected for 2000 with ACPI and resumable."""
    def text(rel: str) -> str:
        return (root / rel).read_text(encoding="utf-8")
    checks = (
        ("tools/build_xp_geometry_fix_mbr.ps1", "-DUSOS_W2K_ACPI"),
        ("tools/build_xp_geometry_fix_mbr.ps1", "w2k-acpi-mbr-440.bin"),
        ("tools/build_micro_linux.py", "usr/lib/usos/w2k-acpi-mbr-440.bin"),
        ("tools/legacy_xp_staging.sh", "USOS_XP_MBR_CODE=/usr/lib/usos/w2k-acpi-mbr-440.bin"),
        ("tools/prepare_xp_target.sh", 'XP_MBR_CODE=${USOS_XP_MBR_CODE:-$SCRIPT_DIR/xp-geometry-fix-mbr-440.bin}'),
        ("tools/prepare_xp_ntfs_target.sh", '${XP_MBR_CODE:-$SCRIPT_DIR/xp-geometry-fix-mbr-440.bin}'),
        ("tools/legacy_xp_resume.sh", '"$SCRIPT_DIR/w2k-acpi-mbr-440.bin"'),
    )
    for rel, needle in checks:
        if needle not in text(rel):
            raise AssertionError(f"{rel}: missing {needle}")
    staging = text("tools/legacy_xp_staging.sh")
    sel = staging.index("USOS_XP_MBR_CODE=/usr/lib/usos/w2k-acpi-mbr-440.bin")
    if 'if [ "$USOS_W2K_ACPI" = on ]; then' not in staging[sel - 400:sel]:
        raise AssertionError("legacy_xp_staging.sh: the W2K ACPI MBR must only follow ACPI on")
    print("[PASS] W2K ACPI MBR wiring: build, package, staging (ACPI on only), prepare, resume")


def main() -> int:
    parser = argparse.ArgumentParser()
    root = Path(__file__).resolve().parents[3]
    parser.add_argument("--mbr", default=str(root / "zig-out/xp-geometry-fix-mbr/w2k-acpi-mbr-440.bin"))
    args = parser.parse_args()
    check_wiring(root)
    code = Path(args.mbr).read_bytes()
    if len(code) != 440:
        raise SystemExit(f"W2K ACPI MBR must be 440 bytes, got {len(code)}")

    uc = run(code, firmware=True)
    cfg = struct.unpack("<I", bytes(uc.mem_read(HPET + 0x10, 4)))[0]
    if cfg != 1:
        raise AssertionError(f"HPET general configuration {cfg:#x}, want 0x1")
    check_table(uc, DSDT, b"DSDT", DSDT_WANT)
    check_table(uc, SSDT, b"SSDT", SSDT_WANT)
    check_table(uc, APIC, b"APIC", APIC_BODY)
    print("[PASS] W2K ACPI MBR: HPET LegacyReplacement cleared, QWord names rewritten in DSDT+SSDT, checksums valid, handoff")

    uc = run(code, firmware=False)
    if bytes(uc.mem_read(HPET + 0x10, 4)) != b"\xff" * 4:
        raise AssertionError("absent HPET was written")
    print("[PASS] W2K ACPI MBR: no RSDP / no HPET -> nothing written, handoff")
    return 0


if __name__ == "__main__":
    sys.exit(main())
