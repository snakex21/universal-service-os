#!/usr/bin/env python3
"""Patch a Windows 3.x planar display driver (NE file) so that it never uses
a locked read-modify-write instruction on video memory.

Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.

Why: on the X470 (RX 560 legacy VBIOS under CSMWrap, A0000-BFFFF UC),
USOSVGAR showed that an XCHG with video memory (implicitly locked) loads
the VGA latches from byte (address | 3) instead of the addressed byte;
plain reads and writes are fine. VGA.DRV/EGA.DRV use `xchg es:[di],reg8`
as "load latches + write" in their text, line and bitmap output, so every
such drawing combines with the wrong latch byte -> broken redraws.

What: the code segments are walked with a 16-bit x86 disassembler
(capstone, recursive descent from the entry table and the relocation
targets, following direct jumps and calls; conditional and indirect
transfers end nothing but the indirect target is not followed). Every
reached XCHG reg,mem with an ES segment override (video memory in these
drivers) is replaced by a near CALL (E8 rel16, plus NOPs when the
instruction is longer) to a stub appended to the same code segment:

    push T            ; T = a 16-bit register not used by the instruction
    mov  T8, mem      ; same prefixes, addressing mode and displacement
    mov  mem, R8
    mov  R8, T8
    pop  T
    ret

which has the exact effect of `xchg mem, R8` (R <- old mem, mem <- old R,
no flag changes) with one plain read and one plain write. Interrupt
atomicity of the single instruction is not kept; for video memory that is
not used for synchronisation (the drivers' cursor code saves and restores
the latches around its own drawing). XCHG with other segments (CS/SS/DS
variables, possibly semaphores) is never patched by default.

Optional (`--unlocked-rmw`, default off; only if a probe ever shows that
unlocked RMW is broken too): ES-override ALU/NOT/NEG/INC/DEC/shift
instructions with a memory destination become `mov T,mem; op T,...;
mov mem,T` stubs with identical flags.

An instruction shorter than 3 bytes, or one whose window would overlap a
relocation fixup, a branch target or an unreached byte, is reported and left
alone. Sites found only by a byte scan outside the reached code (for
example BitBlt code templates that are copied before they run) are
reported, never patched: a near call would not survive the copy.

The grown segment (code + stubs + its relocation records) is written at the
end of the file and the segment table entry is updated (offset, length,
minimum allocation); everything else keeps its file position. The fast-load
(gang load) area is switched off because moved preload segments are no
longer inside it.

This is our own tool. Patched Microsoft files are made locally on the
user's own copy and never go into git.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import struct
import sys
from dataclasses import dataclass, field
from pathlib import Path

import capstone
from capstone import x86 as cx86

SEGPFX = {0x26: 'es', 0x2e: 'cs', 0x36: 'ss', 0x3e: 'ds', 0x64: 'fs', 0x65: 'gs'}
RMW_MNEMONICS = {'add', 'or', 'adc', 'sbb', 'and', 'sub', 'xor', 'not', 'neg',
                 'inc', 'dec', 'shl', 'shr', 'sal', 'sar', 'rol', 'ror', 'rcl', 'rcr'}
JUMPS = {'jmp', 'je', 'jne', 'jb', 'jae', 'jbe', 'ja', 'jl', 'jge', 'jle', 'jg', 'jo',
         'jno', 'js', 'jns', 'jp', 'jnp', 'jcxz', 'jecxz', 'loop', 'loope', 'loopne'}
ENDS = {'ret', 'retf', 'iret', 'iretd', 'hlt'}


class PatchError(Exception):
    pass


@dataclass
class Segment:
    index: int                      # 1-based
    file_off: int
    length: int
    flags: int
    minalloc: int
    data: bytes
    relocs: bytes                   # count word + records ('' if none)
    fixups: set = field(default_factory=set)   # byte offsets written by the loader
    targets: set = field(default_factory=set)  # internal far targets (offsets)

    @property
    def is_code(self):
        return not self.flags & 1


@dataclass
class NeFile:
    data: bytearray
    ne_off: int
    shift: int
    segtab: int
    segments: list
    entries: list                   # (segment, offset)


def parse_ne(raw: bytes) -> NeFile:
    data = bytearray(raw)
    if raw[:2] != b'MZ':
        raise PatchError('not an MZ/NE file')
    ne_off = struct.unpack_from('<I', raw, 0x3c)[0]
    if raw[ne_off:ne_off + 2] != b'NE':
        raise PatchError('no NE header')
    h = lambda o, f='<H': struct.unpack_from(f, raw, ne_off + o)[0]
    nseg, segtab, shift = h(0x1c), ne_off + h(0x22), h(0x32)
    segments = []
    for i in range(nseg):
        so, sl, fl, mn = struct.unpack_from('<HHHH', raw, segtab + 8 * i)
        fo, ln = so << shift, (sl or 0x10000) if so else 0
        body = bytes(raw[fo:fo + ln]) if so else b''
        rel = b''
        if so and fl & 0x100:
            n = struct.unpack_from('<H', raw, fo + ln)[0]
            rel = bytes(raw[fo + ln:fo + ln + 2 + 8 * n])
        segments.append(Segment(i + 1, fo, ln, fl, mn or 0x10000, body, rel))
    # entry table
    entries = []
    p, end = ne_off + h(0x04), ne_off + h(0x04) + h(0x06)
    while p < end:
        cnt, ind = raw[p], raw[p + 1]
        p += 2
        if cnt == 0:
            break
        if ind == 0:
            continue
        for _ in range(cnt):
            if ind == 0xff:
                seg, off = raw[p + 3], struct.unpack_from('<H', raw, p + 4)[0]
                p += 6
            else:
                seg, off = ind, struct.unpack_from('<H', raw, p + 1)[0]
                p += 3
            entries.append((seg, off))
    ne = NeFile(data, ne_off, shift, segtab, segments, entries)
    _scan_relocs(ne)
    return ne


def _scan_relocs(ne: NeFile):
    for seg in ne.segments:
        if not seg.relocs:
            continue
        n = struct.unpack_from('<H', seg.relocs, 0)[0]
        for k in range(n):
            atype, rtype, off, a, b = struct.unpack_from('<BBHHH', seg.relocs, 2 + 8 * k)
            size = {0: 1, 2: 2, 3: 4, 5: 2, 11: 6, 13: 4}.get(atype, 4)
            # follow the chain (not for additive records)
            seen = 0
            while True:
                for i in range(size):
                    seg.fixups.add(off + i)
                if rtype & 4 or off + 2 > len(seg.data) or seen > 0x4000:
                    break
                nxt = struct.unpack_from('<H', seg.data, off)[0]
                if nxt == 0xffff:
                    break
                off, seen = nxt, seen + 1
            if rtype & 3 == 0 and atype in (3, 5, 11, 13):
                tseg, toff = a & 0xff, b
                if tseg == 0xff:
                    if 0 < toff <= len(ne.entries):
                        tseg, toff = ne.entries[toff - 1]
                    else:
                        continue
                if 0 < tseg <= len(ne.segments):
                    ne.segments[tseg - 1].targets.add(toff)


def _md():
    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_16)
    md.detail = True
    return md


def _walk_from(code, start, known):
    """Trial walk from one start: (new insns, branch targets) or None when
    it decodes an invalid instruction, leaves the segment or runs into the
    middle of a known instruction."""
    md = _md()
    insns, targets, work = {}, {start}, [start]
    starts_known = set(known)
    inside = set()
    for o, i in known.items():
        inside.update(range(o + 1, o + i.size))
    while work:
        pc = work.pop()
        while True:
            if not 0 <= pc < len(code) or pc in inside:
                return None
            if pc in starts_known or pc in insns:
                break
            ins = next(md.disasm(code[pc:pc + 15], pc, 1), None)
            if ins is None or pc + ins.size > len(code):
                return None
            if any(o in starts_known or o in insns for o in range(pc + 1, pc + ins.size)):
                return None
            insns[pc] = ins
            m = ins.mnemonic
            imm = ins.operands[0].imm if ins.operands and                 ins.operands[0].type == cx86.X86_OP_IMM else None
            if m in JUMPS or m == 'call':
                if imm is not None and ins.bytes[0] not in (0x9a, 0xea):
                    t = imm & 0xffff
                    targets.add(t)
                    work.append(t)
                if m == 'jmp':
                    break
            elif m in ENDS or (m == 'int' and imm == 0x20):
                break
            pc += ins.size
    return insns, targets


def _pointer_candidates(code, insns):
    """Near code pointers referenced by reached code: 16-bit immediates of
    MOV r/m16,imm16 and PUSH imm16, and word tables addressed through CS
    with a base or index register or loaded with LEA reg,[table]
    (jump/call tables), and LEA reg,[routine] itself."""
    out = set()
    for o, ins in insns.items():
        if ins.mnemonic in ('mov', 'push') and ins.operands:
            op = ins.operands[-1]
            if op.type == cx86.X86_OP_IMM and op.size == 2 and 0 < (op.imm & 0xffff) < len(code):
                if ins.mnemonic == 'push' or ins.operands[0].size == 2:
                    out.add(op.imm & 0xffff)
        tables = []
        for op in ins.operands:
            if op.type == cx86.X86_OP_MEM and op.mem.segment == cx86.X86_REG_CS and                     (op.mem.base or op.mem.index) and 0 <= op.mem.disp < len(code) - 1:
                tables.append(op.mem.disp & 0xffff)
        if ins.mnemonic == 'lea' and len(ins.operands) == 2:
            m = ins.operands[1].mem
            if not m.base and not m.index and 0 <= m.disp < len(code) - 1:
                tables.append(m.disp & 0xffff)      # LEA SI,[table]
                if ins.operands[0].reg not in (cx86.X86_REG_SI, cx86.X86_REG_DI):
                    out.add(m.disp & 0xffff)        # LEA AX,[routine]
        for t in tables:
            if True:
                for k in range(64):
                    if t + 2 * k + 2 > len(code):
                        break
                    v = struct.unpack_from('<H', code, t + 2 * k)[0]
                    if not 0 < v < len(code):
                        break
                    out.add(v)
    return out


def walk(seg: Segment, starts, pointers=True) -> tuple[dict, set]:
    """Recursive descent from the given starts; then (pointers=True) from
    near code pointers found in the reached code, each accepted only if its
    own walk decodes cleanly and agrees with the instructions already
    reached. Returns {offset: insn} and the set of branch targets."""
    code = seg.data
    insns, targets = {}, set()
    pending = sorted({s for s in starts if 0 <= s < len(code)})
    tried = set()
    while True:
        for s in pending:
            tried.add(s)
            r = _walk_from(code, s, insns)
            if r is None:
                continue
            insns.update(r[0])
            targets |= r[1]
        if not pointers:
            break
        pending = sorted(_pointer_candidates(code, insns) - tried)
        if not pending:
            break
    return insns, targets


@dataclass
class Site:
    seg: int
    off: int
    size: int
    text: str
    kind: str                       # 'xchg' | 'rmw'
    action: str                     # 'patched' | 'in window ...' | why it was left alone
    stub: int = -1
    window: tuple = ()              # (start, end) of the replaced bytes


def _seg_of(ins) -> str:
    """'es', 'cs', 'ss', 'ds' for overrides; 'ds-reg' for DS by default with
    a base/index register ([si], [di], [bx+..]); 'ds-abs' for DS by default
    with an absolute address (driver variables such as busy flags);
    'ss-bp' for the BP-based stack default."""
    for b in ins.prefix:
        if b in SEGPFX:
            return SEGPFX[b]
    mem = [o for o in ins.operands if o.type == cx86.X86_OP_MEM][0].mem
    if mem.base == cx86.X86_REG_BP:
        return 'ss-bp'
    return 'ds-reg' if (mem.base or mem.index) else 'ds-abs'


def _decode(raw: bytes):
    """prefix bytes, opcode, modrm, rest (displacement/immediate) of a
    one-byte-opcode instruction with a ModRM byte."""
    i = 0
    while raw[i] in SEGPFX or raw[i] in (0x66, 0x67, 0xf0, 0xf2, 0xf3):
        i += 1
    return raw[:i], raw[i], raw[i + 1], raw[i + 2:]


ADDR_REGS = {0: {3, 6}, 1: {3, 7}, 2: {5, 6}, 3: {5, 7}, 4: {6}, 5: {7}, 6: {5}, 7: {3}}


def _addr_regs(modrm):
    mod, rm = modrm >> 6, modrm & 7
    if mod == 0 and rm == 6:
        return set()
    return ADDR_REGS[rm]


def xchg_seq(raw: bytes) -> bytes:
    """push T / mov T,mem / mov mem,R / mov R,T / pop T  ==  xchg mem,R"""
    pfx, op, modrm, rest = _decode(raw)
    if any(b in (0x66, 0x67, 0xf0, 0xf2, 0xf3) for b in pfx):
        raise PatchError('operand/address size or lock/rep prefix')
    if op not in (0x86, 0x87) or modrm >> 6 == 3:
        raise PatchError('not xchg reg,mem')
    word = op == 0x87
    r = (modrm >> 3) & 7
    used = _addr_regs(modrm)
    if word:
        if r == 4:
            raise PatchError('xchg with SP')
        cand = [t for t in (0, 1, 2, 3, 6, 7, 5) if t != r and t not in used]
    else:
        cand = [t for t in (0, 1, 2, 3) if t != (r & 3) and t not in used]
    t = cand[0]
    mem = lambda reg: bytes([modrm & 0xc7 | reg << 3]) + rest
    return (bytes([0x50 + t])
            + pfx + bytes([0x8b if word else 0x8a]) + mem(t)
            + pfx + bytes([0x89 if word else 0x88]) + mem(r)
            + bytes([0x8b if word else 0x8a, 0xc0 | r << 3 | t])
            + bytes([0x58 + t]))


def rmw_seq(raw: bytes) -> bytes:
    """push T / mov T,mem / op T,... / mov mem,T / pop T for an RMW
    instruction with a memory destination (same flags as the original)."""
    pfx, op, modrm, rest = _decode(raw)
    if any(b in (0x66, 0x67, 0xf0, 0xf2, 0xf3) for b in pfx) or modrm >> 6 == 3:
        raise PatchError('unsupported prefix or register form')
    mod, rm = modrm >> 6, modrm & 7
    disp_len = {0: 2 if rm == 6 else 0, 1: 1, 2: 2}[mod]
    disp, imm = rest[:disp_len], rest[disp_len:]
    word = bool(op & 1)
    if op < 0x40 and op & 7 in (0, 1):          # op r/m, reg
        src = {(modrm >> 3) & 7}
        newop = lambda t: bytes([op, 0xc0 | modrm & 0x38 | t]) + imm
    elif op in (0x80, 0x81, 0x83, 0xc0, 0xc1, 0xd0, 0xd1, 0xd2, 0xd3, 0xf6, 0xf7, 0xfe, 0xff):
        n = (modrm >> 3) & 7
        if (op in (0x80, 0x81, 0x83) and n == 7) or (op in (0xf6, 0xf7) and n not in (2, 3)) \
                or (op in (0xfe, 0xff) and n > 1):
            raise PatchError('not a read-modify-write form')
        src = {1} if op in (0xd2, 0xd3) else set()  # CL
        newop = lambda t: bytes([op, 0xc0 | n << 3 | t]) + imm
        if op in (0x80, 0xc0):
            word = False
    else:
        raise PatchError('not a read-modify-write form')
    used = _addr_regs(modrm)
    if word:
        cand = [t for t in (0, 1, 2, 3, 6, 7, 5) if t not in src and t not in used]
    else:
        cand = [t for t in (0, 1, 2, 3) if t not in {x & 3 for x in src} and t not in used]
    t = cand[0]
    mem = lambda reg: bytes([modrm & 0xc7 | reg << 3]) + disp
    return (bytes([0x50 + t])
            + pfx + bytes([0x8b if word else 0x8a]) + mem(t)
            + newop(t)
            + pfx + bytes([0x89 if word else 0x88]) + mem(t)
            + bytes([0x58 + t]))


def _is_xchg_mem(ins):
    return ins.mnemonic == 'xchg' and any(o.type == cx86.X86_OP_MEM for o in ins.operands)


def _is_rmw_mem(ins):
    return ins.mnemonic in RMW_MNEMONICS and bool(ins.operands) and \
        ins.operands[0].type == cx86.X86_OP_MEM


STACKY = {'push', 'pop', 'pushf', 'popf', 'pusha', 'popa', 'pushal', 'popal', 'pushfd',
          'popfd', 'enter', 'leave', 'call', 'lcall', 'ret', 'retf', 'iret', 'int', 'into',
          'int3', 'sti', 'cli', 'hlt', 'ljmp'}


def _movable(ins, seg, targets, first):
    """May this neighbour instruction run inside the stub instead of in
    place? No control transfer, no stack/SP use, no fixup, and (unless it
    becomes the window start) no branch target."""
    m = ins.mnemonic
    if m in STACKY or m in JUMPS or m.startswith('j') or m.startswith('loop'):
        return False
    regs_r, regs_w = ins.regs_access()
    if any(r in (cx86.X86_REG_SP, cx86.X86_REG_ESP) for r in list(regs_r) + list(regs_w)):
        return False
    if any(b in seg.fixups for b in range(ins.address, ins.address + ins.size)):
        return False
    if not first and ins.address in targets:
        return False
    return True


SITE_SEGMENTS = ('es', 'ds-reg')


def analyse(ne: NeFile, unlocked_rmw=False, segments=SITE_SEGMENTS):
    """Returns (sites, per-segment reached instruction maps). The window of
    a site is the run of whole instructions (the site plus movable
    neighbours, at least 3 bytes) replaced by CALL+NOPs."""
    sites, reach = [], {}
    starts = {}
    for s, o in ne.entries:
        starts.setdefault(s, set()).add(o)
    for seg in ne.segments:
        if not seg.is_code or not seg.data:
            continue
        insns, targets = walk(seg, starts.get(seg.index, set()) | seg.targets)
        reach[seg.index] = (insns, targets)
        prev = {o + i.size: o for o, i in insns.items()}
        covered = set()
        for o, ins in insns.items():
            covered.update(range(o, o + ins.size))
        segsites = {}
        for o in sorted(insns):
            ins = insns[o]
            if _is_xchg_mem(ins):
                kind = 'xchg'
            elif unlocked_rmw and _is_rmw_mem(ins) and \
                    capstone.x86.X86_PREFIX_LOCK not in ins.prefix:
                kind = 'rmw'
            else:
                continue
            site = Site(seg.index, o, ins.size, f'{ins.mnemonic} {ins.op_str}', kind, 'patched')
            sg = _seg_of(ins)
            if sg not in segments:
                site.action = f'left alone: segment {sg} (not video memory)'
            elif any(b in seg.fixups for b in range(o, o + ins.size)):
                site.action = 'left alone: overlaps a relocation fixup'
            else:
                try:
                    (xchg_seq if kind == 'xchg' else rmw_seq)(bytes(ins.bytes))
                except PatchError as e:
                    site.action = f'left alone: {e}'
            segsites[o] = site
            sites.append(site)
        # windows: grow forward, then backward, over movable instructions
        used = set()
        for o, site in sorted(segsites.items()):
            if site.action != 'patched' or o in used:
                continue
            lo, hi = o, o + site.size
            if any(b in targets for b in range(lo + 1, hi)):
                site.action = 'left alone: branch target inside'
                continue
            while hi - lo < 3 and hi in insns and hi not in used and \
                    _movable(insns[hi], seg, targets, False) and \
                    (hi not in segsites or segsites[hi].action == 'patched'):
                hi += insns[hi].size
            while hi - lo < 3 and lo in prev and prev[lo] not in used and \
                    lo not in targets and _movable(insns[prev[lo]], seg, targets, True) and \
                    (prev[lo] not in segsites or segsites[prev[lo]].action == 'patched'):
                lo = prev[lo]
            if hi - lo < 3:
                site.action = 'left alone: no 3-byte window for a near call'
                continue
            site.window = (lo, hi)
            used.update(range(lo, hi))
            for k in segsites:
                if lo <= k < hi and k != o:
                    segsites[k].action = f'in window of seg{site.seg}:{o:04X}'
                    segsites[k].window = (lo, hi)
        # byte scan for XCHG with ES outside the reached code
        md = _md()
        for o in range(len(seg.data) - 2):
            if o in covered or seg.data[o] != 0x26 or seg.data[o + 1] not in (0x86, 0x87):
                continue
            ins = next(md.disasm(seg.data[o:o + 15], o, 1), None)
            if ins is None or not _is_xchg_mem(ins):
                continue
            sites.append(Site(seg.index, o, ins.size, f'{ins.mnemonic} {ins.op_str}', 'xchg',
                              'left alone: not reached by the code walk (template/data?)'))
    sites.sort(key=lambda s: (s.seg, s.off))
    return sites, reach


def sp_users(reach):
    """Reached instructions that write SP other than as a stack pointer
    (stack ops, ADD/SUB/AND SP,imm, MOV SP,BP): a near CALL inside code that
    keeps data in SP would overwrite it."""
    out = []
    for segi, (insns, _) in sorted(reach.items()):
        for o, ins in sorted(insns.items()):
            _, w = ins.regs_access()
            if cx86.X86_REG_SP not in w or ins.mnemonic in STACKY:
                continue
            if ins.mnemonic in ('add', 'sub', 'and') and ins.operands[1].type == cx86.X86_OP_IMM:
                continue
            if ins.mnemonic == 'mov' and ins.op_str == 'sp, bp':
                continue
            out.append((segi, o, f'{ins.mnemonic} {ins.op_str}'))
    return out


def patch(raw: bytes, unlocked_rmw=False, segments=SITE_SEGMENTS):
    ne = parse_ne(raw)
    sites, reach = analyse(ne, unlocked_rmw, segments)
    out = bytearray(raw)
    for seg in ne.segments:
        todo = [s for s in sites if s.seg == seg.index and s.action == 'patched']
        if not todo:
            continue
        if seg.minalloc != seg.length:
            raise PatchError(f'segment {seg.index}: minimum allocation differs from length')
        insns = reach[seg.index][0]
        kinds = {s.off: s.kind for s in sites if s.seg == seg.index and s.window}
        code = bytearray(seg.data)
        stubs = {}
        for s in todo:
            lo, hi = s.window
            body, k = b'', lo
            while k < hi:
                raw_ins = bytes(seg.data[k:k + insns[k].size])
                if k in kinds:
                    body += xchg_seq(raw_ins) if kinds[k] == 'xchg' else rmw_seq(raw_ins)
                else:
                    body += raw_ins
                k += insns[k].size
            body += b'\xc3'
            if body not in stubs:
                stubs[body] = len(code)
                code += body
            s.stub = stubs[body]
            for t in sites:
                if t.seg == s.seg and t.window == s.window:
                    t.stub = s.stub
            rel = (s.stub - (lo + 3)) & 0xffff
            code[lo:hi] = bytes([0xe8]) + struct.pack('<H', rel) + b'\x90' * (hi - lo - 3)
        if len(code) > 0xffff:
            raise PatchError(f'segment {seg.index}: grows over 64 KiB')
        # new copy of the segment (+ its relocation records) at the file end
        align = 1 << ne.shift
        pos = (len(out) + align - 1) // align * align
        if pos >> ne.shift > 0xffff:
            raise PatchError('file too large for the sector shift')
        out += b'\0' * (pos - len(out)) + code + seg.relocs
        struct.pack_into('<HHHH', out, ne.segtab + 8 * (seg.index - 1),
                         pos >> ne.shift, len(code), seg.flags, len(code))
    if any(s.stub >= 0 for s in sites):
        # Moved preload segments are no longer inside the fast-load (gang
        # load) area: switch it off, KERNEL then reads every segment from
        # its segment table position.
        out[ne.ne_off + 0x37] &= ~0x08
        struct.pack_into('<HH', out, ne.ne_off + 0x38, 0, 0)
    return bytes(out), sites, reach


def replaced(sites):
    return [s for s in sites if s.action == 'patched' or s.action.startswith('in window')]


def report(sites, reach=None, f=sys.stdout):
    for s in sites:
        stub = f' stub {s.stub:04X}' if s.stub >= 0 else ''
        win = f' window {s.window[0]:04X}-{s.window[1]:04X}' if s.window else ''
        print(f'seg{s.seg}:{s.off:04X} {s.size} {s.kind:4} {s.text:32} {s.action}{win}{stub}',
              file=f)
    if reach:
        for segi, o, t in sp_users(reach):
            print(f'note: seg{segi}:{o:04X} {t} (SP not used as a stack pointer)', file=f)
    n = len(replaced(sites))
    print(f'replaced {n}, left alone {len(sites) - n}', file=f)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('input', type=Path)
    ap.add_argument('output', type=Path, nargs='?')
    ap.add_argument('--unlocked-rmw', action='store_true',
                    help='also replace unlocked RMW with video memory (default off)')
    ap.add_argument('--report-only', action='store_true')
    ap.add_argument('--json', type=Path, help='write the site list as JSON')
    a = ap.parse_args(argv)
    raw = a.input.read_bytes()
    out, sites, reach = patch(raw, a.unlocked_rmw)
    report(sites, reach)
    if a.json:
        a.json.write_text(json.dumps([s.__dict__ for s in sites], indent=1))
    if not a.report_only:
        if not a.output:
            ap.error('output file required')
        a.output.write_bytes(out)
        print(f'{a.input.name} sha256 {hashlib.sha256(raw).hexdigest()} -> '
              f'{a.output.name} sha256 {hashlib.sha256(out).hexdigest()}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
