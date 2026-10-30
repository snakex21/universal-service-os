#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Prepare an explicitly supplied NT31 source COPY, never an original CD.

SZDD A/LZSS mechanics cross-checked with doors NT5
base/win32/lz32/{winlza/lzexp.c,lzcommon.c}; original NT31 CDs independently
verified. Own implementation; no Microsoft data in this module.
The patch functions themselves are the existing USOS nt31_*_inf functions.
The native route itself is tools/nt4_csmwrap_target.sh nt31_native (2026-10-30).
"""
from pathlib import Path
import argparse
import os
import subprocess

MAGIC = b'SZDD\x88\xf0\x27\x33A'
MAX_SIZE = 16 * 1024 * 1024
ROOT = Path(__file__).resolve().parents[1]

def hook_for_nt31(data):
    """Prepare a NEW sector-1 copy as the native NT 3.1 route writes it
    (tools/nt4_csmwrap_target.sh): RAM cap 64 MiB (byte 508 = 4), options
    byte 509 = NIC bus-master quiesce + shutdown log (bit 1, sector 3) and
    the text-mode key answerer (bit 2, sector 5); bit 0 stays clear, so the
    PCI BIOS stays hidden. No disk I/O."""
    if len(data)!=512 or data[510:]!=b'U3':raise ValueError('Expected an identified USOS hook sector')
    result=bytearray(data);result[508]=4;result[509]=2|4
    return bytes(result)

def unpack(data):
    if len(data) < 14 or data[:9] != MAGIC:
        raise ValueError('Unsupported NT31 compression (expected SZDD A)')
    size = int.from_bytes(data[10:14], 'little')
    if size > MAX_SIZE: raise ValueError('SZDD output bound exceeded')
    window = bytearray(b' ' * 4096)
    pos, cursor = 4096 - 16, 14
    out = bytearray()
    while len(out) < size:
        if cursor >= len(data): raise ValueError('Truncated SZDD flags')
        flags = data[cursor]; cursor += 1
        for bit in range(8):
            if len(out) == size: break
            if flags & (1 << bit):
                if cursor >= len(data): raise ValueError('Truncated SZDD literal')
                value = data[cursor]; cursor += 1
                out.append(value); window[pos] = value; pos = (pos+1) & 4095
            else:
                if cursor + 2 > len(data): raise ValueError('Truncated SZDD match')
                a,b = data[cursor:cursor+2]; cursor += 2
                offset = a | ((b & 0xf0) << 4); length = (b & 15) + 3
                if len(out) + length > size: raise ValueError('SZDD match exceeds declared size')
                for _ in range(length):
                    value = window[offset]; offset = (offset+1) & 4095
                    out.append(value); window[pos] = value; pos = (pos+1) & 4095
    if cursor != len(data): raise ValueError('Trailing SZDD data')
    return bytes(out)

def pack(data, last=b'F'):
    """Literal-only SZDD, accepted by the original decoder; no CAB writer."""
    if len(data) > MAX_SIZE or len(last) != 1: raise ValueError('SZDD bound')
    result = bytearray(MAGIC + last + len(data).to_bytes(4,'little'))
    for offset in range(0, len(data), 8):
        group = data[offset:offset+8]
        result.append((1 << len(group))-1); result.extend(group)
    return bytes(result)

def patch(data, kind, *, owner='USOS', org='USOS', computer='USOS-NT31', advanced=False, nvme=False, shell=None, gui_answerer=False):
    """Use measured USOS INF rules; return only after all anchors passed."""
    compressed = data.startswith(b'SZDD')
    plain = unpack(data) if compressed else data
    if len(plain) > MAX_SIZE or b'\0' in plain: raise ValueError('Invalid INF text')
    if kind=='initial':
        import re
        original_as=bool(re.search(rb'(?im)^[ \t]*STF_PRODUCT[ \t]*=[ \t]*LanmanNT[ \t]*\r?$',plain))
        if original_as!=advanced:raise ValueError('Advanced Server mode must match original INITIAL.INF')
    for value in (owner,org,computer):
        if not value or len(value)>64 or any(c in value for c in '\r\n"\\$`'):
            raise ValueError('Unsafe profile text')
    names = {'initial':'nt31_initial_inf','hardware':'nt31_hardware_inf',
             'ntlanman':'nt31_ntlanman_inf','oemnadlb':'nt31_oemnadlb_inf'}
    if kind not in names: raise ValueError('Unknown source file')
    source = (ROOT/'tools/nt4_qemu_install.sh').read_text(encoding='utf-8')
    fn = names[kind]
    lines = source.splitlines(); start = next(i for i,s in enumerate(lines) if s.startswith(fn+'() {'))
    end = next(i for i in range(start,len(lines)) if lines[i] == '}')
    function = '\n'.join(lines[start:end+1])
    command = function+'\n'+fn+' "$1" "$2" "$3" "$4" "$5"\n'
    shell = shell or os.environ.get('USOS_POSIX_SH')
    if not shell: raise ValueError('Explicit POSIX shell required')
    env=dict(os.environ,PATH=str(Path(shell).parent)+os.pathsep+os.environ.get('PATH',''))
    r = subprocess.run([str(shell),'-c',command,'nt31-source',owner,org,computer,
        'net' if advanced else '', 'nvme' if nvme else ''],input=plain,capture_output=True,timeout=15,env=env)
    if r.returncode: raise ValueError('NT31 INF anchors did not match')
    result=r.stdout
    if gui_answerer and kind=='initial':
        import re
        anchor=rb'(?im)^([ \t]*install[ \t]+LoadSetupLibrary[ \t]*\r?\n)'
        if len(re.findall(anchor,result))!=1:raise ValueError('Ambiguous GUI answerer startup anchor')
        result=re.sub(anchor,lambda m:m[0]+b'    StartDetachedProcess STATUS "" "" "C:\\USOS\\NT3\\USOSANS31.EXE"\r\n',result)
    if not result or len(result)>MAX_SIZE: raise ValueError('Invalid patched INF')
    return pack(result,data[9:10]) if compressed else result

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--input',type=Path,required=True); p.add_argument('--output',type=Path,required=True)
    p.add_argument('--kind',choices=('initial','hardware','ntlanman','oemnadlb'),required=True)
    p.add_argument('--owner',default='USOS');p.add_argument('--org',default='USOS')
    p.add_argument('--computer',default='USOS-NT31');p.add_argument('--advanced',action='store_true')
    p.add_argument('--nvme',action='store_true');p.add_argument('--shell',required=True)
    p.add_argument('--gui-answerer',action='store_true',help='Opt-in; separately stage USOSANS31.EXE in C:\\USOS\\NT3')
    a=p.parse_args()
    if a.input.resolve()==a.output.resolve() or a.output.exists(): raise ValueError('New separate output required; original left intact')
    result=patch(a.input.read_bytes(),a.kind,owner=a.owner,org=a.org,computer=a.computer,advanced=a.advanced,nvme=a.nvme,shell=a.shell,gui_answerer=a.gui_answerer)
    with a.output.open('xb') as out: out.write(result)
    print('NT31 source copy prepared; native boot remains unqualified')

if __name__=='__main__': main()
