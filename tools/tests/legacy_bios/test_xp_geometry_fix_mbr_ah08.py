#!/usr/bin/env python3
"""Exercise the production XP geometry-fix MBR against hostile AH=08 results.

The exact 440-byte production artifact is executed in 16-bit x86 emulation.
Only BIOS INT 13h is modeled: AH=42 supplies a synthetic FAT32 VBR and AH=08
returns the selected test geometry.  PASS means the MBR reaches the VBR handoff
without fault and either patches BPB heads for a valid result or leaves the BPB
unchanged for an unusable result.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import sys

try:
    from unicorn import Uc, UC_ARCH_X86, UC_MODE_16, UC_HOOK_CODE, UC_HOOK_INTR
    from unicorn.x86_const import (
        UC_X86_REG_AH,
        UC_X86_REG_CL,
        UC_X86_REG_CS,
        UC_X86_REG_DH,
        UC_X86_REG_DL,
        UC_X86_REG_EFLAGS,
        UC_X86_REG_IP,
    )
except ImportError as exc:  # pragma: no cover - explicit dependency failure
    raise SystemExit("unicorn Python package is required: python -m pip install unicorn") from exc


BOOT = 0x7C00
MBR_SIZE = 512
BPB_SPT = 0x18
BPB_HEADS = 0x1A


@dataclass(frozen=True)
class Case:
    name: str
    carry: bool
    dh: int
    cl: int
    expected_heads: int


CASES = (
    Case("valid-240x63", False, 239, 63, 240),
    Case("ah08-carry-error", True, 239, 63, 255),
    Case("zero-head-value", False, 0, 63, 255),
    Case("head-out-of-range", False, 255, 63, 255),
    Case("zero-sectors-per-track", False, 239, 0, 255),
    Case("spt-mismatch", False, 239, 32, 255),
)


def set_cf(uc: Uc, enabled: bool) -> None:
    flags = uc.reg_read(UC_X86_REG_EFLAGS)
    if enabled:
        flags |= 1
    else:
        flags &= ~1
    uc.reg_write(UC_X86_REG_EFLAGS, flags)


def make_sector0(code440: bytes) -> bytes:
    if len(code440) != 440:
        raise ValueError(f"production MBR artifact must be 440 bytes, got {len(code440)}")
    sector = bytearray(MBR_SIZE)
    sector[:440] = code440
    # One active FAT32-LBA primary partition starting at LBA 2048.
    off = 446
    sector[off + 0] = 0x80
    sector[off + 4] = 0x0C
    sector[off + 8 : off + 12] = (2048).to_bytes(4, "little")
    sector[off + 12 : off + 16] = (4194304).to_bytes(4, "little")
    sector[510:512] = b"\x55\xaa"
    return bytes(sector)


def make_vbr() -> bytes:
    vbr = bytearray(MBR_SIZE)
    vbr[BPB_SPT : BPB_SPT + 2] = (63).to_bytes(2, "little")
    vbr[BPB_HEADS : BPB_HEADS + 2] = (255).to_bytes(2, "little")
    vbr[510:512] = b"\x55\xaa"
    return bytes(vbr)


def run_case(code440: bytes, case: Case) -> tuple[int, int]:
    uc = Uc(UC_ARCH_X86, UC_MODE_16)
    uc.mem_map(0, 1024 * 1024)
    uc.mem_write(BOOT, make_sector0(code440))
    vbr = make_vbr()

    visits_to_boot = 0
    ah42_calls = 0
    ah08_calls = 0
    reached_handoff = False

    def on_code(emu: Uc, address: int, _size: int, _user: object) -> None:
        nonlocal visits_to_boot, reached_handoff
        if address == BOOT:
            visits_to_boot += 1
            if visits_to_boot == 2:
                reached_handoff = True
                emu.emu_stop()

    def on_intr(emu: Uc, intno: int, _user: object) -> None:
        nonlocal ah42_calls, ah08_calls
        if intno != 0x13:
            raise RuntimeError(f"unexpected interrupt 0x{intno:02X}")
        ah = emu.reg_read(UC_X86_REG_AH)
        if ah == 0x42:
            ah42_calls += 1
            emu.mem_write(BOOT, vbr)
            set_cf(emu, False)
            emu.reg_write(UC_X86_REG_AH, 0)
            return
        if ah == 0x08:
            ah08_calls += 1
            emu.reg_write(UC_X86_REG_DH, case.dh)
            emu.reg_write(UC_X86_REG_CL, case.cl)
            set_cf(emu, case.carry)
            emu.reg_write(UC_X86_REG_AH, 1 if case.carry else 0)
            return
        raise RuntimeError(f"unexpected INT 13h AH=0x{ah:02X}")

    uc.hook_add(UC_HOOK_CODE, on_code)
    uc.hook_add(UC_HOOK_INTR, on_intr)
    uc.reg_write(UC_X86_REG_CS, 0)
    uc.reg_write(UC_X86_REG_IP, BOOT)
    uc.reg_write(UC_X86_REG_DL, 0x80)
    uc.reg_write(UC_X86_REG_EFLAGS, 0x202)

    try:
        uc.emu_start(BOOT, 0x100000, count=20000)
    except Exception as exc:
        raise AssertionError(f"{case.name}: MBR crashed before VBR handoff: {exc}") from exc

    if not reached_handoff:
        raise AssertionError(f"{case.name}: VBR handoff was not reached")
    if ah42_calls != 1:
        raise AssertionError(f"{case.name}: expected one AH=42 call, got {ah42_calls}")
    if ah08_calls != 1:
        raise AssertionError(f"{case.name}: expected one AH=08 call, got {ah08_calls}")

    final_vbr = bytes(uc.mem_read(BOOT, MBR_SIZE))
    heads = int.from_bytes(final_vbr[BPB_HEADS : BPB_HEADS + 2], "little")
    spt = int.from_bytes(final_vbr[BPB_SPT : BPB_SPT + 2], "little")
    if heads != case.expected_heads:
        raise AssertionError(
            f"{case.name}: BPB heads={heads}, expected {case.expected_heads}"
        )
    if spt != 63:
        raise AssertionError(f"{case.name}: MBR unexpectedly changed BPB SPT to {spt}")
    return heads, spt


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--mbr",
        default="zig-out/xp-geometry-fix-mbr/xp-geometry-fix-mbr-440.bin",
        help="path to the exact 440-byte production MBR artifact",
    )
    args = parser.parse_args()
    mbr_path = Path(args.mbr)
    if not mbr_path.is_file():
        raise SystemExit(f"MBR artifact missing: {mbr_path}")
    code440 = mbr_path.read_bytes()

    for case in CASES:
        heads, spt = run_case(code440, case)
        behavior = "runtime-patch" if heads != 255 else "fallback-bpb"
        print(
            f"[PASS] {case.name}: handoff=yes behavior={behavior} "
            f"heads={heads} spt={spt}"
        )
    print(f"[PASS] AH=08 hardening: {len(CASES)}/{len(CASES)} cases")
    return 0


if __name__ == "__main__":
    sys.exit(main())
