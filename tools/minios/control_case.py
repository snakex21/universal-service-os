"""Independent mkntfs control: disposable guest-only COW, Windows RO chkdsk.

No host block-device paths are accepted. The reference generator sees just
one explicitly serial-tagged virtual disk and checks its exact sector size.
"""
from __future__ import annotations
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import stat
import struct
import subprocess
import sys

def load(name, path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--workspace',type=Path,required=True)
    p.add_argument('--source-root',type=Path,required=True)
    p.add_argument('--qemu-dir',type=Path,required=True)
    p.add_argument('--name',default='control-mkntfs')
    a=p.parse_args()
    repo=Path(__file__).resolve().parents[2]
    v=load('control_verify',Path(__file__).with_name('verify_case.py'))
    v.ORACLE=a.workspace.resolve()
    if not re.fullmatch('[a-z0-9-]+',a.name): raise ValueError('Invalid control case name')
    root=v.oracle_path(v.ORACLE/a.name)
    root.mkdir(exist_ok=False)
    oracle=load('control_oracle',repo/'tools/tests/minios_ntfs_oracle.py')
    oracle.WORKSPACE=v.ORACLE
    oracle.guard()
    pack=v.oracle_path(v.ORACLE/'pack01')
    pin=json.loads((pack/'prepared.json').read_text('utf-8'))
    if oracle.sha(pack/'vmlinuz')!=pin['kernel_sha256'] or oracle.sha(pack/'oracle-base.gz')!=pin['base_sha256']:
        raise ValueError('Pinned reference runtime changed')
    size=65*1024**2
    base=root/'base.raw'
    with base.open('xb') as f:
        f.truncate(size)
        mbr=bytearray(512)
        mbr[440:444]=secrets.token_bytes(4)
        struct.pack_into('<B3sB3sII',mbr,446,0,b'\xfe\xff\xff',7,b'\xfe\xff\xff',2048,64*2048)
        mbr[510:]=b'\x55\xaa'; f.seek(0); f.write(mbr); f.flush(); os.fsync(f.fileno())
    qimg=a.qemu_dir/'qemu-img.exe'
    cow=root/'reference.qcow2'
    subprocess.run([str(qimg),'create','-f','qcow2','-F','raw','-b',str(base),str(cow)],check=True,capture_output=True)
    script=oracle.GUEST_PREFIX+r'''
[ -b /dev/vda1 ] || finish 40
[ "$(cat /sys/block/vda/serial)" = USOSMKNTFS ] || finish 41
[ "$(cat /sys/block/vda/size)" = 133120 ] || finish 42
[ "$(cat /sys/block/vda/vda1/start)" = 2048 ] || finish 43
[ "$(cat /sys/block/vda/vda1/size)" = 131072 ] || finish 44
check reference-format mkntfs -F -Q -s 512 -c 4096 -p 2048 /dev/vda1
check ntfsfix ntfsfix --no-action /dev/vda1
check ntfsinfo ntfsinfo -m /dev/vda1
ntfscat /dev/vda1 '/$UpCase' >/tmp/upcase.bin || finish 45
[ "$(stat -c %s /tmp/upcase.bin)" = 131072 ] || finish 46
echo "ORACLE_UPCASE_SHA256=$(sha256sum /tmp/upcase.bin | cut -d ' ' -f 1)"
finish 0
'''
    builder=oracle.import_builder(a.source_root)
    overlay=builder.newc({'oracle-init':builder.Entry('oracle-init',stat.S_IFREG|0o755,script.encode())})
    initrd=root/'oracle-initramfs'
    initrd.write_bytes((pack/'oracle-base.gz').read_bytes()+overlay)
    runtime=root/'host-runtime'; runtime.mkdir()
    env=dict(os.environ)
    for key in ('APPDATA','LOCALAPPDATA','TMP','TEMP'): env[key]=str(runtime)
    command=[str(a.qemu_dir/'qemu-system-x86_64.exe'),'-machine','q35','-accel','tcg','-cpu','max','-m','512','-smp','1','-display','none','-monitor','none','-nic','none','-no-reboot','-kernel',str(pack/'vmlinuz'),'-initrd',str(initrd),'-append','console=ttyS0,115200 rdinit=/oracle-init loglevel=3 panic=-1','-serial',f'file:{root / "serial.txt"}','-drive',f'if=none,id=reference,file={cow},format=qcow2','-device','virtio-blk-pci,drive=reference,serial=USOSMKNTFS']
    v.write_json(root/'command.json',command)
    with (root/'qemu-stderr.txt').open('xb') as err:
        proc=subprocess.Popen(command,stdout=err,stderr=err,env=env,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        try: code=proc.wait(timeout=300)
        except BaseException:
            proc.kill(); proc.wait(); raise
    serial=(root/'serial.txt').read_text('utf-8',errors='replace')
    if code!=0 or re.findall(r'^USOS_ORACLE_COMPLETE=(\d+)\r?$',serial,re.M)!=['0']:
        raise ValueError('Independent mkntfs guest failed; see closed serial log')
    upcase=re.findall(r'^ORACLE_UPCASE_SHA256=([0-9a-f]{64})\r?$',serial,re.M)
    if len(upcase)!=1: raise ValueError('Missing reference UpCase SHA256')
    export=v.oracle_path(v.ORACLE/'inputs'/a.name); export.mkdir(parents=True,exist_ok=False)
    raw=export/'target.raw'
    subprocess.run([str(qimg),'convert','-f','qcow2','-O','raw',str(cow),str(raw)],check=True,capture_output=True)
    raw.chmod(stat.S_IREAD)
    shell=shutil.which('pwsh.exe')
    if shell is None: raise ValueError('PowerShell7 required')
    out=v.oracle_path(v.ORACLE/(a.name+'-windows01'))
    args=[shell,'-NoLogo','-NoProfile','-File',str(repo/'tools/tests/minios_chkdsk_readonly.ps1'),'-Workspace',str(v.ORACLE),'-RawCopy',str(raw),'-ExpectedImageBytes',str(size),'-ExpectedSha256',oracle.sha(raw),'-QemuImg',str(qimg),'-Out',str(out)]
    completed=v.wait_owned(args)
    result={'qemu_only':True,'mkntfs_exit':0,'qemu_exit':code,'upcase_sha256':upcase[0],'raw_sha256':oracle.sha(raw),'windows_returncode':completed.returncode,'windows_result':str(out/'result.json'),'stdout':completed.stdout,'stderr':completed.stderr}
    v.write_json(root/'result.json',result)
    print(json.dumps(result))
    if completed.returncode!=0: raise SystemExit(1)

if __name__=='__main__': main()
