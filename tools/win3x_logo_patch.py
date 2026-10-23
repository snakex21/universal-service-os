#!/usr/bin/env python3
"""Patch the Windows 3.x VGA startup logo code (VGALOGO.LGO, or the copy
linked into WIN.COM) so that it never uses a locked read-modify-write on
video memory.

Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.

Why: on the X470 (RX 560 legacy VBIOS under CSMWrap) USOSVGAR 3 showed
"RMW RESULT LOCKED-ONLY": XCHG with video memory loads the VGA latches from
byte (address | 3); unlocked RMW and plain moves are fine. The logo code
draws through two small helpers that do "load latches + write" with
`xchg es:[di],reg8`, so the logo shown while WIN.COM starts is corrupted.

What (layout as in the Windows 3.1 VGALOGO.LGO; the logo code is raw
16-bit code, no relocations). The two helpers sit next to each other and
are reached only through near pointers that the code stores with
`mov ax,imm16 / mov [bp-36h],ax` and `mov ax,imm16 / mov [bp-38h],ax`:

  helper A (17 bytes for both, A first): send AH to port DX, then write AL
           to es:[di] with a latch load; AX and flags preserved.
  helper B: write AL to es:[di] with a latch load; AX and flags preserved.

They are rewritten in their own 17 bytes, with only plain accesses:

  A:  push ax / mov al,ah / out dx,al / pop ax         (falls into B)
  B:  push ax / mov ah,es:[di] / mov es:[di],al / pop ax / ret / nop x3

and the second pointer immediate is moved to the new start of B. Same
registers, flags, port writes and video memory result as the original
(Unicorn tests with a planar VGA model); interrupt atomicity of the single
XCHG is irrelevant for video memory.

The patch is applied only when the exact original bytes are found once
(helpers + both pointer loads); anything else is refused. WIN.COM is the
plain concatenation WIN.CNF + VGALOGO.LGO + VGALOGO.RLE (verified on the
3.1 PL install); patching it in place gives the same file as rebuilding it
from the patched VGALOGO.LGO.

This is our own tool. Patched Microsoft files are made locally on the
user's own copy and never go into git.
"""
from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path

# helper A (03CB in VGALOGO.LGO 3.1) followed directly by helper B (03D6)
ORIG_HELPERS = bytes.fromhex('5086e0ee268625b0ff58c3' '5026860558c3')
A_LEN = 11
# mov ax,A / mov [bp-36h],ax / mov ax,B / mov [bp-38h],ax
PTR_RE = re.compile(rb'\xb8(..)\x89\x46\xca\xb8(..)\x89\x46\xc8', re.S)

NEW_A = bytes.fromhex('50' '8ac4' 'ee' '58')                  # push ax/mov al,ah/out dx,al/pop ax
NEW_B = bytes.fromhex('50' '268a25' '268805' '58' 'c3')       # push/mov ah,es:[di]/mov es:[di],al/pop/ret


class PatchError(Exception):
    pass


def _find_once(data: bytes, pat: bytes) -> list:
    out, i = [], data.find(pat)
    while i >= 0:
        out.append(i)
        i = data.find(pat, i + 1)
    return out


def patch(raw: bytes):
    """Returns (patched bytes, list of (offset, description)). The offsets
    are file offsets; the logo code base is derived from the helper position
    and the pointer immediates (which are offsets within the logo code)."""
    hits = _find_once(raw, ORIG_HELPERS)
    if len(hits) != 1:
        if len(_find_once(raw, NEW_A + NEW_B)) == 1:
            raise PatchError('already patched')
        raise PatchError(f'logo helpers found {len(hits)} times (expected once)')
    pos = hits[0]
    found = []
    for m in PTR_RE.finditer(raw, 0, pos):
        a, b = (int.from_bytes(m.group(k), 'little') for k in (1, 2))
        base = pos - a
        if b == a + A_LEN and 0 <= base <= m.start():
            found.append((base, m.start() - base))
    if len(found) != 1:
        raise PatchError('pointer loads for the logo helpers not found exactly once')
    base, ld = found[0]
    a_off = pos - base
    out = bytearray(raw)
    out[pos:pos + len(ORIG_HELPERS)] = NEW_A + NEW_B + b'\x90' * (len(ORIG_HELPERS) - len(NEW_A) - len(NEW_B))
    imm_b = base + ld + 7                        # second mov ax,imm16 immediate
    out[imm_b:imm_b + 2] = (a_off + len(NEW_A)).to_bytes(2, 'little')
    sites = [(pos + 4, 'helper A xchg es:[di],ah -> mov al,es:[di] / mov es:[di],ah (via B)'),
             (pos + A_LEN + 1, 'helper B xchg es:[di],al -> mov ah,es:[di] / mov es:[di],al'),
             (imm_b, f'helper B pointer {a_off + A_LEN:04X} -> {a_off + len(NEW_A):04X}')]
    return bytes(out), sites, base


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('input', type=Path, help='VGALOGO.LGO or WIN.COM')
    ap.add_argument('output', type=Path, nargs='?')
    ap.add_argument('--report-only', action='store_true')
    a = ap.parse_args(argv)
    raw = a.input.read_bytes()
    try:
        out, sites, base = patch(raw)
    except PatchError as e:
        print(f'{a.input.name}: {e}', file=sys.stderr)
        return 1
    print(f'logo code at file offset {base:04X}')
    for off, text in sites:
        print(f'{off:04X} (logo {off - base:04X}) {text}')
    if not a.report_only:
        if not a.output:
            ap.error('output file required')
        a.output.write_bytes(out)
        print(f'{a.input.name} sha256 {hashlib.sha256(raw).hexdigest()} -> '
              f'{a.output.name} sha256 {hashlib.sha256(out).hexdigest()}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
