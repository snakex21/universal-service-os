"""Run fixture creation from initramfs; serial output is evidence, not input.

The low-RAM harness is read-only infrastructure. Its historical PASS check
matches echoed commands, so verify our independent completion line as well.
"""
from pathlib import Path
import re


def archive(entries):
    result=bytearray()
    for inode,(name,mode,data) in enumerate([*entries,('TRAILER!!!',0,b'')],1):
        encoded=name.encode()+b'\0'
        fields=(inode,mode,0,0,1,0,len(data),0,0,0,0,len(encoded),0)
        result.extend(b'070701'+b''.join(f'{x:08x}'.encode() for x in fields))
        result.extend(encoded);result.extend(b'\0'*(-len(result)%4))
        result.extend(data);result.extend(b'\0'*(-len(result)%4))
    return bytes(result)


def completion(result,text,marker):
    return (result.get('result')=='PASS' and result.get('exit_code')==0
        and result.get('timed_out') is False
        and marker in text.replace('\r\n','\n').splitlines()
        and 'Kernel panic' not in text)


def require_verified(metadata):
    proof=metadata.get('fixture_verification',{})
    if metadata.get('result',{}).get('result')!='PASS' or proof.get('complete') is not True or proof.get('transport')!='initrd-script':
        raise ValueError('Fixture preparation lacks verified completion; no coverage VM may start')


def reject_firmware_shell(line):
    if 'UEFI Interactive Shell' in line:
        raise RuntimeError('OVMF entered the firmware shell before USOS; no installation was started')


async def run(bootstrap,qemu,kernel,initrd,work,ram,disks,commands,nonce):
    if not re.fullmatch('[a-f0-9]{32}',nonce):raise ValueError('Invalid fixture nonce')
    marker='USOS-FIXTURE-COMPLETE-'+nonce
    script=("#!/bin/sh\nset -eu\n"
        "trap 'rc=$?; echo USOS-FIXTURE-FAILED=$rc; /bin/busybox poweroff -f' EXIT\n"
        +commands+"\nprintf '\\n%s\\n' '"+marker+"'\n"
        "echo LOWRAM-RESULT=PASS\ntrap - EXIT\n/bin/busybox poweroff -f\n").encode()
    packed=Path(work)/'fixture-initramfs'
    base=Path(initrd).read_bytes()
    packed.write_bytes(base+b'\0'*(-len(base)%4)+archive([('coverage-fixture-init',0o100755,script)]))
    result=await bootstrap.run_case(qemu,kernel,packed,work,ram,'qemu64',900,disks,
        commands='',suffix='-fixture',
        boot_append='console=ttyS0,115200 rdinit=/coverage-fixture-init panic=-1')
    text=(Path(result['directory'])/'serial.log').read_text(encoding='utf-8',errors='replace')
    verified=completion(result,text,marker)
    proof={'transport':'initrd-script','complete':verified,'marker':marker,
        'readback':'EFI boot application and initramfs, complete source ISO and prerequisite media; sync and unmount'}
    result=dict(result,bootstrap_result=result.get('result'),
        result='PASS' if verified else 'FAIL',stage='fixture readback, sync and unmount' if verified else 'fixture completion verification failed')
    return result,proof
