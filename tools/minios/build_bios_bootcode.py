#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build own tiny BIOS chain-loader templates; no Microsoft payload is input."""
import argparse, hashlib, json, subprocess
from pathlib import Path

REPO=Path(__file__).resolve().parents[2]

def build(zig,out):
    out=out.absolute()
    if not out.is_relative_to(REPO/'zig-out') or out==REPO/'zig-out':raise ValueError('Owned isolated zig-out output required')
    for part in (out,*out.parents):
        if part.is_symlink() or (part.exists() and getattr(part.stat(),'st_file_attributes',0)&0x400):raise ValueError('Reparse path refused')
    out.mkdir(parents=True,exist_ok=True)
    records={}
    for name,address in (('mbr',0x600),('pbr',0x7c00)):
        source=REPO/'tools/minios/bootcode'/(name+'.S')
        script=out/(name+'.ld')
        script.write_text('SECTIONS { . = '+hex(address)+'; .text : { *(.text) } /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) } }\n')
        elf=out/(name+'.elf'); binary=out/(name+'.bin')
        commands=([str(zig),'cc','-target','x86-freestanding-none','-mcpu=i486','-nostdlib','-nodefaultlibs','-Wl,-T,'+str(script),'-Wl,--entry=minios_'+name+'_start',str(source),'-o',str(elf)],
                  [str(zig),'objcopy','-O','binary','-j','.text',str(elf),str(binary)])
        for command in commands:subprocess.run(command,cwd=REPO,check=True)
        data=binary.read_bytes()
        if len(data)!=512 or data[510:]!=b'\x55\xaa':raise ValueError('Exact 512-byte signed template required')
        if name=='mbr' and (data[432:440]!=b'USOSMB1\0' or any(data[440:510])):raise ValueError('MBR reserved area/layout differs')
        if name=='pbr' and (data[492:500]!=b'USOSPB1\0' or any(data[480:492])):raise ValueError('PBR patch area/layout differs')
        records[name]=dict(bytes=512,sha256=hashlib.sha256(data).hexdigest(),source_sha256=hashlib.sha256(source.read_bytes()).hexdigest())
    (out/'boot_code.zig').write_text('// SPDX-License-Identifier: GPL-3.0-or-later\n// Generated from own assembly; never a Microsoft bootsector.\npub const mbr: [512]u8 = @embedFile("mbr.bin")[0..512].*;\npub const pbr: [512]u8 = @embedFile("pbr.bin")[0..512].*;\n')
    receipt=dict(schema='minios-own-bios-bootcode-v1',cpu='i486',templates=records,microsoft_payload=False,
                 handoff_source='https://chromium.googlesource.com/chromiumos/third_party/grub2/+/11508780425a8cd9a8d40370e2d2d4f458917a73/grub-core/loader/i386/pc/ntldr.c',
                 experimental_contiguous_bootmgr_run=True)
    (out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    return receipt

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--zig',type=Path,required=True);p.add_argument('--out',type=Path,required=True)
    a=p.parse_args();print(json.dumps(build(a.zig,a.out)))
