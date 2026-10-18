"""SPDX-License-Identifier: GPL-3.0-or-later
Retrieve only our GDI screenshots from a natively shut-down file-backed VM.
"""
from pathlib import Path
import argparse,json,subprocess,sys,tarfile

SCRIPT=r'''#!/bin/sh
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
/bin/busybox --install -s
mount -t proc proc /proc;mount -t sysfs sys /sys;mount -t devtmpfs dev /dev 2>/dev/null
mkdir -p /m
finish(){ sync;poweroff -f; };trap finish EXIT
set -e
for m in virtio_pci virtio_blk ntfs3;do modprobe "$m" 2>/dev/null||true;done
mdev -s
mount -t ntfs3 -o ro /dev/vda1 /m
app=$(find /m/USOS -maxdepth 1 -type d -iname usoswm)
logs=$(find "$app" -maxdepth 1 -type d -iname logs)
test -n "$logs"
tar -cf /dev/vdb -C "$logs" wm-rdp-desktop.bmp wm-rdp-winver.bmp
umount /m
echo USOSWM-REMOTE-GDI-READ-PASS
'''

def main():
    parser=argparse.ArgumentParser()
    for name in ('trial','tool-root','linux-root'):parser.add_argument('--'+name,type=Path,required=True)
    args=parser.parse_args();folder=args.trial.resolve();result=json.loads((folder/'result.json').read_text())
    if result.get('exit')!=0 or not result.get('native_shutdown') or not result.get('rdp'):raise ValueError('Requires a completed native RDP shutdown')
    tools=args.tool_root.resolve();sys.path.insert(0,str(tools/'tests'))
    from run_nt3_micro_linux_qemu import cpio_newc
    root=args.linux_root.resolve();raw=(root/'initramfs-usos').read_bytes();initrd=folder/'read-rdp-initrd'
    initrd.write_bytes(raw+b'\0'*(-len(raw)%4)+cpio_newc([('read-rdp',0o100755,SCRIPT.encode())]))
    evidence=folder/'own-rdp-evidence.tar'
    with evidence.open('wb') as stream:stream.truncate(32*1048576)
    command=[str(tools/'qemu/qemu-system-x86_64.exe'),'-machine','q35','-accel','whpx','-accel','tcg','-cpu','qemu64,-xsave','-m','1024','-display','none','-nic','none','-monitor','none','-serial','stdio','-no-reboot','-kernel',str(root/'vmlinuz-virt'),'-initrd',str(initrd),'-append','console=ttyS0,115200 rdinit=/read-rdp loglevel=3','-drive',f'if=virtio,format=qcow2,readonly=on,file={folder/"target.qcow2"}','-drive',f'if=virtio,format=raw,file={evidence}']
    with (folder/'read-rdp.log').open('wb') as log:subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=180)
    if b'USOSWM-REMOTE-GDI-READ-PASS' not in (folder/'read-rdp.log').read_bytes():raise RuntimeError('Remote screenshot read failed')
    from PIL import Image
    with tarfile.open(evidence) as archive:
        for name,stage in [('wm-rdp-desktop.bmp','wm_rdp_desktop.png'),('wm-rdp-winver.bmp','wm_rdp_winver.png')]:
            with archive.extractfile(name) as stream,Image.open(stream) as screen:
                image=screen.convert('RGB')
                if all(low==high for low,high in image.getextrema()):raise RuntimeError('Uniform capture; no GUI acceptance')
                image.save(folder/stage)
    print('Read own remote GDI images; inspect screenshots for visual acceptance',flush=True)

if __name__=='__main__':main()
