#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Real BIOS execution of own templates and a synthetic ABI-checking payload."""
import argparse, json, os, stat, struct, subprocess, time
from pathlib import Path
import logged_run, wim_oracle as oracle, wim_pool as pool

REPO=Path(__file__).resolve().parents[2]

def run(a):
    for path in (a.out,a.plan):oracle.owned(path)
    for path in (a.templates,a.qemu,a.zig):oracle.local(path)
    head,dirty=logged_run.tree(REPO)
    if dirty or a.out.exists():raise ValueError('Clean tree and a new owned case required')
    capacity=pool.enforce(a.plan,a.out);a.out.mkdir(parents=True)
    env=oracle.environment(a.out)
    # Tiny assembly output is private to this owned test case.
    linker=a.out/'stub.ld';linker.write_text('SECTIONS { . = 0; .text : { *(.text) } /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) } }\n')
    commands=([a.zig,'cc','-target','x86-freestanding-none','-mcpu=i486','-nostdlib','-nodefaultlibs','-Wl,-T,'+str(linker),'-Wl,--entry=minios_test_start',REPO/'tools/minios/bootcode/handoff_test.S','-o',a.out/'stub.elf'],
              [a.zig,'objcopy','-O','binary','-j','.text',a.out/'stub.elf',a.out/'stub.bin'])
    for n,command in enumerate(commands):
        with (a.out/f'assemble-{n}.log').open('x') as log:
            log.write(f'HEAD {head}\nWORKTREE_DIRTY 0\n');log.flush()
            result=subprocess.run(list(map(str,command)),stdout=log,stderr=subprocess.STDOUT,timeout=60,env=env)
            if result.returncode:raise ValueError('Own stub assembly failed')
    mbr=bytearray((a.templates/'mbr.bin').read_bytes());pbr=bytearray((a.templates/'pbr.bin').read_bytes());stub=(a.out/'stub.bin').read_bytes()
    if len(mbr)!=512 or len(pbr)!=512 or len(stub)!=1024 or mbr[432:440]!=b'USOSMB1\0' or pbr[492:500]!=b'USOSPB1\0':raise ValueError('Unexpected own template ABI')
    mbr[446]=0x80;mbr[450]=7;struct.pack_into('<II',mbr,454,2048,32768)
    struct.pack_into('<H',pbr,11,512);pbr[13]=8;struct.pack_into('<I',pbr,28,2048);pbr[36]=0x80
    struct.pack_into('<QH',pbr,480,4096,2)
    image=a.out/'own-abi.raw'
    with image.open('xb') as file:
        file.truncate(32*1024**2);file.seek(0);file.write(mbr);file.seek(2048*512);file.write(pbr);file.seek(4096*512);file.write(stub)
        file.flush();os.fsync(file.fileno())
    image.chmod(stat.S_IREAD);pin=oracle.digest(image);results=[]
    with oracle.readonly(image):
        for cpu in ('486','pentium'):
            overlay=a.out/(cpu+'.qcow2')
            with (a.out/(cpu+'-overlay.log')).open('x') as log:
                log.write(f'HEAD {head}\nWORKTREE_DIRTY 0\n');log.flush()
                subprocess.run([str(a.qemu/'qemu-img.exe'),'create','-f','qcow2','-F','raw','-b',str(image),str(overlay)],
                               stdout=log,stderr=subprocess.STDOUT,check=True,timeout=30,env=env)
            command=[a.qemu/'qemu-system-i386.exe','-machine','pc','-accel','tcg,thread=single','-cpu',cpu,'-smp','1','-m','32','-nodefaults','-display','none','-monitor','none','-serial','none','-no-reboot','-nic','none',
                     '-bios',a.qemu/'share/bios-256k.bin','-drive',f'if=ide,format=qcow2,file={overlay}','-device','VGA','-device','isa-debug-exit,iobase=0xf4,iosize=0x04']
            start=time.monotonic()
            with (a.out/(cpu+'.log')).open('x') as log:
                log.write(f'HEAD {head}\nWORKTREE_DIRTY 0\nCOMMAND {json.dumps(list(map(str,command)))}\n');log.flush()
                result=subprocess.run(list(map(str,command)),stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT,timeout=30,env=env)
            results.append(dict(cpu=cpu,returncode=result.returncode,seconds=time.monotonic()-start,passed=result.returncode==33,
                                overlay=overlay.name,overlay_sha256=oracle.digest(overlay)))
            if result.returncode!=33:break
    passed=all(row['passed'] for row in results) and len(results)==2 and oracle.digest(image)==pin and logged_run.tree(REPO)==(head,0)
    receipt=dict(schema='minios-own-bios-handoff-v1',head=head,dirty=0,passed=passed,results=results,
                 image_sha256=pin,image_bytes=image.stat().st_size,templates={name:oracle.digest(a.templates/(name+'.bin')) for name in ('mbr','pbr')},
                 microsoft_payload=False,windows_boot_test=False,physical_disks=False,deleted=False,capacity=capacity)
    oracle.save(a.out/'result.json',receipt)
    return receipt

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('out','plan','templates','qemu','zig'):p.add_argument('--'+name,type=Path,required=True)
    a=p.parse_args();r=run(a);print(json.dumps(r));raise SystemExit(0 if r['passed'] else 1)
