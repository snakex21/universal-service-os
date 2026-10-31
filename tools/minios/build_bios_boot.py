#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build separate QEMU-only BIOS boot provisioning; installer image unchanged."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import audit_ia32
from build_bios_install import patched_core
import build_bios_bootcode


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
    core=work/'boot-core.S';core.write_text(patched_core((source/'core.S').read_text()),encoding='utf8',newline='\n')
    def run(*words):subprocess.run([args.zig,*map(str,words)],check=True,cwd=root)
    def assembly(name,linker,entry):
        elf=work/(name+'.elf');binary=work/(name+'.bin')
        run('cc','-target','x86-freestanding-none','-mcpu=i486','-nostdlib','-nodefaultlibs',
            '-Wl,-T,'+str(source/linker),'-Wl,--entry='+entry,source/(name+'.S'),'-o',elf)
        run('objcopy','-O','binary','-j','.text',elf,binary)
        return binary.read_bytes()
    stage=assembly('stage1','boot_sector.ld','stage1_start')
    bootstrap=assembly('bootstrap','bootstrap.ld','bootstrap_start')
    own=build_bios_bootcode.build(Path(args.zig),work/'own-bootcode')
    obj=work/'boot.o';audit=work/'boot.audit.s';elf=work/'boot.elf';binary=work/'boot.bin'
    run('build-obj','-target','x86-freestanding-none','-mcpu=i486','-O','ReleaseSmall',
        '-fcompiler-rt','-ffunction-sections','-fdata-sections','--dep','ntfs_ro','--dep','bios_boot_code','-Mroot='+str(root/'src/prep/bios_boot_main.zig'),
        '-target','x86-freestanding-none','-mcpu=i486','-O','ReleaseSmall','-Mntfs_ro='+str(root/'src/prep/ntfs_reader.zig'),
        '-target','x86-freestanding-none','-mcpu=i486','-O','ReleaseSmall','-Mbios_boot_code='+str(work/'own-bootcode/boot_code.zig'),
        '-femit-bin='+str(obj),'-femit-asm='+str(audit))
    assembly_text=audit.read_text()
    audit_ia32.audit(assembly_text)
    if '.Lwim.' in assembly_text or '.Lwim_app.' in assembly_text:
        raise ValueError('Separate boot client must not link the WIM installer')
    run('cc','-target','x86-freestanding-none','-mcpu=i486','-nostdlib','-nodefaultlibs','-I',source,
        '-Wl,-T,'+str(root/'src/prep/prep_bios.ld'),'-Wl,--entry=core_start','-Wl,--gc-sections',core,obj,'-o',elf)
    run('objcopy','-O','binary',elf,binary)
    spec=importlib.util.spec_from_file_location('install_packer',root/'tools/pack_legacy_core_slot.py')
    packer=importlib.util.module_from_spec(spec);spec.loader.exec_module(packer)
    slot,metadata=packer.build_slot(bootstrap,binary.read_bytes())
    if len(stage)>440:raise ValueError('Unchanged stage1 exceeds440bytes')
    if pins!={name:digest(source/name) for name in pins}:raise ValueError('A legacy source changed during isolated build')
    with output.open('wb') as image:
        image.truncate(4*1024*1024);image.write(stage.ljust(440,b'\0'));image.seek(510);image.write(b'\x55\xaa');image.seek(64*512);image.write(slot)
    receipt=dict(schema='minios-isolated-bios-boot-build-v1',cpu='i486',legacy_source_sha256=pins,
                 stage_sha256=hashlib.sha256(stage).hexdigest(),bootstrap_sha256=hashlib.sha256(bootstrap).hexdigest(),
                 artifact_sha256=digest(output),payload_sha256=digest(binary),metadata=metadata,
                 private_core_only=True,sector_bytes=[512],stack_sentinel=True,own_boot_code=own,
                 target_role='0x81',utility_bytes=4*1024*1024,wim_installer_linked=False,
                 output=str(output.relative_to(root)),work_dir=str(work.relative_to(root)))
    (work/'build-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf8')
    print(json.dumps(receipt))


if __name__=='__main__':main()
