"""Audit actual IA32 assembly; permit one locally guarded optional TSC helper."""
# SPDX-License-Identifier: GPL-3.0-or-later
import argparse
import hashlib
from pathlib import Path
import re


BEGIN = "USOS_TSC_GUARD_BEGIN readGuarded"
END = "USOS_TSC_GUARD_END readGuarded"


def _normalized(line):
    line = line.split("#", 1)[0].strip().lower()
    line = re.sub(r"\s+", " ", line)
    line = re.sub(r"\s*,\s*", ",", line)
    return line


def _guarded_region(lines, first, last):
    """Accept exactly one straight-line test with the zero branch after RDTSC.

    Both LLVM Intel output and AT&T output are understood. No arbitrary CFG
    analysis or marker-only exemption: any added instruction is a refusal.
    The constant-zero ECX reports failure without consuming EAX/EDX on skip.
    """
    owner = None
    for line in lines[:first]:
        match = re.fullmatch(r'\s*("?[^\s:"]+"?):\s*(?:#.*)?', line)
        if match:
            name = match.group(1).strip('"')
            if not re.match(r"(?:LBB|Ltmp|\.L(?:BB|tmp|func_|CPI|JTI)|[0-9])", name):
                owner = name
    if owner not in ('tsc_clock.readGuarded','L_tsc_clock.readGuarded','.Ltsc_clock.readGuarded'):
        raise ValueError("TSC marker is outside tsc_clock.readGuarded")
    region = [text for line in lines[first + 1:last] if (text := _normalized(line))]
    if len(region) != 6:
        raise ValueError("Optional TSC block has an unexpected instruction or label")
    intel = region[0] == "xor ecx,ecx" and region[1] == "test bl,bl" and region[4] == "mov ecx,1"
    att = region[0] == "xorl %ecx,%ecx" and region[1] == "testb %bl,%bl" and region[4] == "movl $1,%ecx"
    if not (intel or att) or region[3] != "rdtsc":
        raise ValueError("Optional TSC block lacks the exact cached-capability test")
    branch = re.fullmatch(r"j(?:e|z) ([a-z_.$][a-z0-9_.$]*)", region[2])
    if branch is None or region[5] != branch.group(1) + ":":
        raise ValueError("Unavailable TSC branch does not skip RDTSC")
    return first + 1 + next(i for i, line in enumerate(lines[first + 1:last]) if _normalized(line) == "rdtsc")


def audit(text: str):
    # All previous forbidden registers/instructions remain forbidden globally.
    if re.search(r"\b(?:xmm|ymm|zmm|mm)[0-9]+\b", text, re.I):
        raise ValueError("SIMD register appeared in the i486 IA32 application")
    if re.search(r"^\s*(?:cmov[a-z]*|cmpxchg8b|rdtscp|vzeroupper)(?:\s|$)", text, re.I | re.M):
        raise ValueError("Post-i486 instruction appeared in the IA32 application")
    lines = text.splitlines()
    starts = [i for i, line in enumerate(lines) if BEGIN in line]
    ends = [i for i, line in enumerate(lines) if END in line]
    rdtsc = [i for i, line in enumerate(lines) if re.fullmatch(r"rdtsc", _normalized(line))]
    # Reject alternate spellings/prefixes rather than interpreting new syntax.
    instruction_mentions = [i for i, line in enumerate(lines) if re.search(r"\brdtsc\b", line.split("#", 1)[0], re.I)]
    if not starts and not ends and not instruction_mentions:
        return
    if len(starts) != 1 or len(ends) != 1 or starts[0] >= ends[0] or len(rdtsc) != 1 or instruction_mentions != rdtsc:
        raise ValueError("RDTSC must appear once in its single guarded helper")
    # Markers must be comments; a similarly named label is not an exemption.
    if lines[starts[0]].strip() != "# " + BEGIN or lines[ends[0]].strip() != "# " + END:
        raise ValueError("Malformed optional TSC audit marker")
    if _guarded_region(lines, starts[0], ends[0]) != rdtsc[0]:
        raise ValueError("RDTSC outside the locally proven guard")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("assembly", type=Path)
    args = parser.parse_args()
    data = args.assembly.read_bytes()
    audit(data.decode("utf-8"))
    print("IA32 i486 assembly audit PASS; no SIMD/CMOV/unguarded newer clock or64bit-CAS instructions; sha256=" + hashlib.sha256(data).hexdigest())


if __name__ == "__main__":
    main()
