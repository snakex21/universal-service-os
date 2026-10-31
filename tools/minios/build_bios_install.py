#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build isolated BIOS installation firmware; legacy sources remain unchanged."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import subprocess

import audit_ia32

INSTALL_BOOTSTRAP_BYTES=16*1024
INSTALL_PAYLOAD_BYTES=256*1024
INSTALL_SLOT_BYTES=INSTALL_BOOTSTRAP_BYTES+INSTALL_PAYLOAD_BYTES
INSTALL_LOAD_ADDRESS=0x20000
INSTALL_STACK_BASE=0x60000
INSTALL_SLOT_LBA=64
INSTALL_CONFIG_LBA=1024

READ_WRITE_THUNKS=r'''
.section .text.early,"ax",@progbits
.code32
.global bios_install_read_blocks
.global bios_install_write_blocks
.equ THUNK_INSTALL_BYTES, THUNK_STATE + 156

/* Isolated ABI: drive, u64 LBA, count, bytes-per-sector, destination/source.
 * EDD destinations stay below64KiB. Other disks use explicit DL, never the
 * context boot drive. The ordinary legacy entry points are unchanged. */
bios_install_read_blocks:
    mov ecx, dword ptr [esp + 16]
    test ecx, ecx
    jz .install_invalid
    cmp ecx, 127
    ja .install_invalid
    mov eax, dword ptr [esp + 20]
    cmp eax, 512
    je .install_read_sector_ok
    cmp eax, 4096
    jne .install_invalid
.install_read_sector_ok:
    imul eax, ecx
    cmp eax, 65535
    ja .install_invalid
    mov dword ptr [THUNK_INSTALL_BYTES], eax
    mov word ptr [THUNK_DAP_COUNT], cx
    mov eax, dword ptr [esp + 4]
    mov byte ptr [THUNK_BIOS_DRIVE], al
    mov eax, dword ptr [esp + 8]
    mov dword ptr [THUNK_DAP_LBA], eax
    mov eax, dword ptr [esp + 12]
    mov dword ptr [THUNK_DAP_LBA_HI], eax
    mov eax, dword ptr [esp + 24]
    mov dword ptr [THUNK_DEST], eax
    push ebp
    push ebx
    push esi
    push edi
    mov dword ptr [THUNK_SAVED_ESP], esp
    mov byte ptr [THUNK_DAP], 0x10
    mov byte ptr [THUNK_DAP + 1], 0
    mov word ptr [THUNK_DAP_OFFSET], 0
    mov word ptr [THUNK_DAP_SEGMENT], BOUNCE_SEGMENT
    mov byte ptr [THUNK_STATUS], 1
    mov byte ptr [THUNK_OP], 17
    jmp enter_bios

bios_install_write_blocks:
    mov ecx, dword ptr [esp + 16]
    test ecx, ecx
    jz .install_invalid
    cmp ecx, 127
    ja .install_invalid
    mov eax, dword ptr [esp + 20]
    cmp eax, 512
    je .install_write_sector_ok
    cmp eax, 4096
    jne .install_invalid
.install_write_sector_ok:
    imul eax, ecx
    cmp eax, 65535
    ja .install_invalid
    mov dword ptr [THUNK_INSTALL_BYTES], eax
    mov word ptr [THUNK_DAP_COUNT], cx
    mov eax, dword ptr [esp + 4]
    mov byte ptr [THUNK_BIOS_DRIVE], al
    mov eax, dword ptr [esp + 8]
    mov dword ptr [THUNK_DAP_LBA], eax
    mov eax, dword ptr [esp + 12]
    mov dword ptr [THUNK_DAP_LBA_HI], eax
    mov eax, dword ptr [esp + 24]
    push ebp
    push ebx
    push esi
    push edi
    mov dword ptr [THUNK_SAVED_ESP], esp
    mov esi, eax
    mov edi, BOUNCE_PHYS
    mov ecx, dword ptr [THUNK_INSTALL_BYTES]
    shr ecx, 2
    cld
    rep movsd
    mov byte ptr [THUNK_DAP], 0x10
    mov byte ptr [THUNK_DAP + 1], 0
    mov word ptr [THUNK_DAP_OFFSET], 0
    mov word ptr [THUNK_DAP_SEGMENT], BOUNCE_SEGMENT
    mov byte ptr [THUNK_STATUS], 1
    mov byte ptr [THUNK_OP], 18
    jmp enter_bios
.install_invalid:
    mov eax, 1
    ret

.section .data.install,"aw",@progbits
.balign 4
.global bios_install_stack_top
bios_install_stack_top:
    .long 0
'''


def replace_once(text,before,after):
    if text.count(before)!=1:raise ValueError('Legacy thunk anchor changed; explicit review required')
    return text.replace(before,after,1)


def patched_core(text):
    text=replace_once(text,'core_start:\n    cld\n','''core_start:
    cld
    /* Only the isolated installer marks its reserved PM32 stack. */
    mov dword ptr [bios_install_stack_top], esp
    mov edi, 0x60000
    mov ecx, esp
    sub ecx, edi
    shr ecx, 2
    mov eax, 0xcccccccc
    rep stosd
''')
    text=replace_once(text,'    cmp byte ptr [THUNK_OP], 10\n    je .disk_read_explicit\n','''    cmp byte ptr [THUNK_OP], 17
    je .disk_read_explicit
    cmp byte ptr [THUNK_OP], 18
    je .disk_write_explicit
    cmp byte ptr [THUNK_OP], 10
    je .disk_read_explicit
''')
    text=replace_once(text,'    cmp byte ptr [THUNK_OP], 13\n    je .return_success\n    mov esi, BOUNCE_PHYS\n','''    cmp byte ptr [THUNK_OP], 13
    je .return_success
    cmp byte ptr [THUNK_OP], 18
    je .return_success
    cmp byte ptr [THUNK_OP], 17
    jne .install_legacy_read_return
    mov esi, BOUNCE_PHYS
    mov edi, dword ptr [THUNK_DEST]
    mov ecx, dword ptr [THUNK_INSTALL_BYTES]
    shr ecx, 2
    cld
    rep movsd
    xor eax, eax
    jmp .restore
.install_legacy_read_return:
    mov esi, BOUNCE_PHYS
''')
    return text+READ_WRITE_THUNKS


def patched_bootstrap(text):
    # Only this build's private copy admits the larger installation payload.
    # The stage1 ABI and the shared bootstrap source stay byte-identical.
    text=replace_once(text,'.equ SLOT_BYTES, 262144\n','.equ SLOT_BYTES, 278528\n')
    return replace_once(text,'.equ SLOT_SECTORS, 512\n','.equ SLOT_SECTORS, 544\n')


def install_packer(root):
    spec=importlib.util.spec_from_file_location('minios_private_install_packer',root/'tools/pack_legacy_core_slot.py')
    packer=importlib.util.module_from_spec(spec);spec.loader.exec_module(packer)
    if (packer.SLOT_BYTES!=256*1024 or packer.BOOTSTRAP_BYTES!=INSTALL_BOOTSTRAP_BYTES or
            packer.PAYLOAD_OFFSET!=INSTALL_BOOTSTRAP_BYTES or packer.LOAD_ADDRESS!=INSTALL_LOAD_ADDRESS or
            packer.ENTRY_OFFSET!=0 or packer.HEADER_BYTES!=64):
        raise ValueError('Legacy packer geometry changed; explicit review required')
    # Fresh module instance only; never mutate the global packer file/module.
    packer.SLOT_BYTES=INSTALL_SLOT_BYTES
    return packer


def payload_geometry(size):
    if type(size) is not int or not 0<size<=INSTALL_PAYLOAD_BYTES:
        raise ValueError('Isolated BIOS payload must fit256KiB')
    sectors=(size+511)//512
    load_end=INSTALL_LOAD_ADDRESS+sectors*512
    slot_end=INSTALL_SLOT_LBA+INSTALL_SLOT_BYTES//512
    if load_end>INSTALL_STACK_BASE or slot_end>INSTALL_CONFIG_LBA:
        raise ValueError('Installation payload overlaps stack or configuration')
    return dict(load_address=INSTALL_LOAD_ADDRESS,payload_bytes=size,payload_sectors=sectors,
                rounded_load_end=load_end,stack_base=INSTALL_STACK_BASE,slot_bytes=INSTALL_SLOT_BYTES,
                slot_lba=INSTALL_SLOT_LBA,slot_end_lba_exclusive=slot_end,
                config_lba=INSTALL_CONFIG_LBA,log_start_lba=INSTALL_CONFIG_LBA+1)


def linked_memory_bounds(blob,payload_size):
    """Check actual linked ELF32 memory, including rounded sector loads/BSS."""
    result=payload_geometry(payload_size)
    if (len(blob)<52 or blob[:6]!=b'\x7fELF\x01\x01' or
            struct.unpack_from('<HH',blob,16)!=(2,3) or
            struct.unpack_from('<I',blob,24)[0]!=INSTALL_LOAD_ADDRESS):
        raise ValueError('Linked i386 ELF32 with exact installer entry required')
    table=struct.unpack_from('<I',blob,32)[0]
    width,count=struct.unpack_from('<HH',blob,46)
    if width!=40 or not 1<count<=4096 or table>len(blob) or count*width>len(blob)-table:
        raise ValueError('Bounded linked ELF32 section table required')
    initialized=[];uninitialized=[]
    for index in range(count):
        row=struct.unpack_from('<10I',blob,table+index*width)
        _,kind,flags,address,offset,size,*_=row
        if not flags&2 or not size:continue
        if address<INSTALL_LOAD_ADDRESS or address>INSTALL_STACK_BASE or size>INSTALL_STACK_BASE-address:
            raise ValueError('Linked BIOS section overlaps low-memory stack')
        if kind==8:
            uninitialized.append((address,address+size))
        else:
            if offset>len(blob) or size>len(blob)-offset or address+size>INSTALL_LOAD_ADDRESS+payload_size:
                raise ValueError('Linked initialized section outside packed payload')
            initialized.append((address,address+size))
    if not initialized or min(row[0] for row in initialized)!=INSTALL_LOAD_ADDRESS:
        raise ValueError('Linked installer load address differs')
    bss_start=min((row[0] for row in uninitialized),default=INSTALL_LOAD_ADDRESS+payload_size)
    bss_end=max((row[1] for row in uninitialized),default=bss_start)
    if bss_start<INSTALL_LOAD_ADDRESS+payload_size or bss_end-bss_start>=0x10000:
        raise ValueError('Linked BIOS BSS overlaps payload or exceeds64KiB')
    result.update(bss_start=bss_start,bss_end=bss_end,linked_section_count=count)
    return result


def build_install_slot(root,bootstrap,payload):
    payload_geometry(len(payload))
    return install_packer(root).build_slot(bootstrap,payload)


def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zig',required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--work-dir',type=Path,required=True)
    args=parser.parse_args();root=Path(__file__).resolve().parents[2]
    work=args.work_dir.absolute();output=args.output.absolute()
    for path in (work,output):
        if not path.is_relative_to(root/'zig-out') or path==root/'zig-out':raise ValueError('Isolated zig-out path required')
        for node in (path,*path.parents):
            if node.is_symlink() or (node.exists() and getattr(node.stat(),'st_file_attributes',0)&0x400):raise ValueError('Reparse path forbidden')
    work.mkdir(parents=True,exist_ok=True);output.parent.mkdir(parents=True,exist_ok=True)
    source=root/'src/platform/bios'
    pins={name:digest(source/name) for name in ('stage1.S','bootstrap.S','core.S','windows_disk_order.S')}
    packer_pin=digest(root/'tools/pack_legacy_core_slot.py')
    core=work/'install-core.S';core.write_text(patched_core((source/'core.S').read_text()),encoding='utf8',newline='\n')
    private_bootstrap=work/'install-bootstrap.S'
    private_bootstrap.write_text(patched_bootstrap((source/'bootstrap.S').read_text()),encoding='utf8',newline='\n')
    def run(*words):subprocess.run([args.zig,*map(str,words)],check=True,cwd=root)
    def assembly(name,linker,entry,assembly_source=None):
        elf=work/(name+'.elf');binary=work/(name+'.bin')
        run('cc','-target','x86-freestanding-none','-mcpu=i486','-nostdlib','-nodefaultlibs',
            '-Wl,-T,'+str(source/linker),'-Wl,--entry='+entry,assembly_source or source/(name+'.S'),'-o',elf)
        run('objcopy','-O','binary','-j','.text',elf,binary)
        return binary.read_bytes()
    stage=assembly('stage1','boot_sector.ld','stage1_start')
    bootstrap=assembly('bootstrap','bootstrap.ld','bootstrap_start',private_bootstrap)
    obj=work/'install.o';audit=work/'install.audit.s';elf=work/'install.elf';binary=work/'install.bin'
    run('build-obj','-target','x86-freestanding-none','-mcpu=i486','-O','ReleaseSmall',
        '-fcompiler-rt','-ffunction-sections','-fdata-sections','--dep','ntfs_ro','-Mroot='+str(root/'src/prep/bios_install_main.zig'),
        '-target','x86-freestanding-none','-mcpu=i486','-O','ReleaseSmall','-Mntfs_ro='+str(root/'src/prep/ntfs_reader.zig'),
        '-femit-bin='+str(obj),'-femit-asm='+str(audit))
    audit_ia32.audit(audit.read_text())
    run('cc','-target','x86-freestanding-none','-mcpu=i486','-nostdlib','-nodefaultlibs','-I',source,
        '-Wl,-T,'+str(root/'src/prep/prep_bios.ld'),'-Wl,--entry=core_start','-Wl,--gc-sections',core,obj,'-o',elf)
    run('objcopy','-O','binary',elf,binary)
    payload=binary.read_bytes()
    memory=linked_memory_bounds(elf.read_bytes(),len(payload))
    slot,metadata=build_install_slot(root,bootstrap,payload)
    if len(stage)>440:raise ValueError('Unchanged stage1 exceeds440bytes')
    if pins!={name:digest(source/name) for name in pins} or digest(root/'tools/pack_legacy_core_slot.py')!=packer_pin:
        raise ValueError('A legacy source or packer changed during isolated build')
    with output.open('wb') as image:
        image.truncate(1024*1024);image.write(stage.ljust(440,b'\0'));image.seek(510);image.write(b'\x55\xaa');image.seek(64*512);image.write(slot)
    receipt=dict(schema='minios-isolated-bios-install-build-v1',cpu='i486',legacy_source_sha256=pins,
                 stage_sha256=hashlib.sha256(stage).hexdigest(),bootstrap_sha256=hashlib.sha256(bootstrap).hexdigest(),
                 artifact_sha256=digest(output),payload_sha256=digest(binary),metadata=metadata,
                 private_core_only=False,private_core_and_bootstrap=True,sector_bytes=[512,4096],stack_sentinel=True,
                 private_bootstrap_source_sha256=digest(private_bootstrap),legacy_packer_sha256=packer_pin,linked_memory=memory,
                 output=str(output.relative_to(root)),work_dir=str(work.relative_to(root)))
    (work/'build-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf8')
    print(json.dumps(receipt))


if __name__=='__main__':main()
