"""SPDX-License-Identifier: GPL-3.0-or-later
Cold-boot an already completed trial with the final own files in an overlay.
Updates only C:\\USOS files. It never edits Windows files, hives or BCD.
The second probe is invoked once through Win+R after a bounded boot interval;
Startup must have launched the actual application before that measurement.
"""
from pathlib import Path
import argparse,hashlib,importlib.util,io,json,socket,subprocess,sys,threading,time
import pycdlib

HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('wm_trial',HERE/'run.py')
trial=importlib.util.module_from_spec(spec);spec.loader.exec_module(trial)

INIT=r'''#!/bin/sh
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
/bin/busybox --install -s
mount -t proc proc /proc;mount -t sysfs sys /sys;mount -t devtmpfs dev /dev 2>/dev/null
mkdir -p /run /w /patch;mount -t tmpfs run /run
finish(){ sync;poweroff -f; };trap finish EXIT
set -e
for m in virtio_pci virtio_blk ntfs3 isofs;do modprobe "$m" 2>/dev/null||true;done
mdev -s
mount -t ntfs3 /dev/vda1 /w
mount -t iso9660 -o ro /dev/vdb /patch
test -f /w/USOS/WMTEST/wmprobe.exe
test -f /w/USOS/usoswm/usoswm.exe
cd /patch/assets
sha256sum -c sha256.txt
for name in usoswm.exe usoswm-desktop.dll usoswm-register.exe;do
 cat "$name" >"/w/USOS/usoswm/$name"
 test "$(sha256sum "$name"|cut -d' ' -f1)" = "$(sha256sum "/w/USOS/usoswm/$name"|cut -d' ' -f1)"
done
cat wmprobe.exe >/w/USOS/WMTEST/wmprobe.exe
test "$(sha256sum wmprobe.exe|cut -d' ' -f1)" = "$(sha256sum /w/USOS/WMTEST/wmprobe.exe|cut -d' ' -f1)"
cd /
umount /patch;umount /w
echo USOSWM-OWN-UPDATE-PASS
'''

def type_run(stream,command):
    trial.qmp_call(stream,'human-monitor-command',{'command-line':'sendkey meta_l-r'})
    threading.Event().wait(1)
    punctuation={':':'shift-semicolon','\\':'backslash','.':'dot',' ':'spc','-':'minus'}
    for char in command:
        key=char if char.isalnum() else punctuation[char]
        trial.qmp_call(stream,'human-monitor-command',{'command-line':'sendkey '+key+' 40'})
        threading.Event().wait(.06)
    trial.qmp_call(stream,'human-monitor-command',{'command-line':'sendkey ret'})

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--previous',type=Path,required=True)
    parser.add_argument('--component',type=Path,required=True)
    parser.add_argument('--tool-root',type=Path,required=True)
    parser.add_argument('--linux-root',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--accel',choices=['tcg','whpx'],default='tcg')
    parser.add_argument('--limit-seconds',type=int,default=900)
    args=parser.parse_args()
    previous=args.previous.resolve();result=json.loads((previous/'result.json').read_text())
    if result.get('exit')!=0 or 'WM_BASELINE_COMPLETE' not in (previous/'serial.log').read_text():raise ValueError('Use a completed successful trial, not an active or failed image')
    out=args.out.resolve();out.mkdir(parents=True,exist_ok=False)
    tools=args.tool_root.resolve();trial.WORK=out;trial.TOOLS=tools;trial.ARCH='amd64'
    probe=trial.build()
    files={name:(args.component/name).read_bytes() for name in ('usoswm.exe','usoswm-desktop.dll','usoswm-register.exe')}
    files['wmprobe.exe']=probe.read_bytes()
    manifest={name:hashlib.sha256(raw).hexdigest() for name,raw in files.items()}
    files['sha256.txt']=''.join(digest+'  '+name+'\n' for name,digest in manifest.items()).encode()
    (out/'own-manifest.json').write_text(json.dumps(manifest,indent=2))
    iso=pycdlib.PyCdlib();iso.new(interchange_level=3,joliet=3,vol_ident='USOSWMOWN')
    iso.add_directory('/ASSETS',joliet_path='/assets')
    for name,raw in files.items():iso.add_fp(io.BytesIO(raw),len(raw),iso_path='/ASSETS/'+name.upper().replace('-','_')+';1',joliet_path='/assets/'+name)
    support=out/'own-update.iso';iso.write(str(support));iso.close()
    image=out/'target.qcow2'
    subprocess.run([str(tools/'qemu/qemu-img.exe'),'create','-q','-f','qcow2','-F','qcow2','-b',str(previous/'target.qcow2'),str(image)],check=True)
    sys.path.insert(0,str(tools/'tests'))
    from run_nt3_micro_linux_qemu import cpio_newc
    raw=(args.linux_root/'initramfs-usos').read_bytes();initrd=out/'update-initrd'
    initrd.write_bytes(raw+b'\0'*(-len(raw)%4)+cpio_newc([('update-init',0o100755,INIT.encode())]))
    command=[str(tools/'qemu/qemu-system-x86_64.exe'),'-machine','q35','-accel','whpx','-accel','tcg','-cpu','qemu64,-xsave','-m','1024','-display','none','-nic','none','-monitor','none','-serial','stdio','-no-reboot','-kernel',str(args.linux_root/'vmlinuz-virt'),'-initrd',str(initrd),'-append','console=ttyS0,115200 rdinit=/update-init loglevel=3','-drive',f'if=virtio,format=qcow2,file={image}','-drive',f'if=virtio,format=raw,readonly=on,file={support}']
    with (out/'update.log').open('wb') as log:subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=180,check=True)
    if b'USOSWM-OWN-UPDATE-PASS' not in (out/'update.log').read_bytes():raise RuntimeError('Own-file stage failed')
    serial=socket.socket();serial.bind(('127.0.0.1',0));serial.listen();serial.settimeout(60)
    qmp=socket.socket();qmp.bind(('127.0.0.1',0));qmp.listen();qmp.settimeout(60)
    command=[str(tools/'qemu/qemu-system-x86_64.exe'),'-machine','pc','-accel',args.accel,'-cpu','max' if args.accel=='tcg' else 'qemu64,-xsave','-smp','2','-m','3072','-vga','std','-display','none','-nic','none','-boot','order=c,menu=off','-drive',f'if=ide,index=0,format=qcow2,file={image}','-serial',f'tcp:127.0.0.1:{serial.getsockname()[1]},server=off','-qmp',f'tcp:127.0.0.1:{qmp.getsockname()[1]},server=off','-monitor','none','-rtc','base=2009-07-01T12:00:00,clock=host']
    (out/'command.json').write_text(json.dumps(command,indent=2))
    with (out/'qemu.log').open('wb') as log:
        process=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT);stream=None
        try:
            connection,_=serial.accept();connection.settimeout(args.limit_seconds);q,_=qmp.accept();q.settimeout(60)
            stream=q.makefile('rwb',buffering=0);json.loads(stream.readline());trial.qmp_call(stream,'qmp_capabilities')
            print('Owned cold boot: one scheduled probe invocation, no progress queries',flush=True)
            threading.Event().wait(120)
            type_run(stream,r'c:\usos\wmtest\wmprobe.exe --post')
            with (out/'serial.log').open('wb') as evidence:
                incoming=connection.makefile('rb')
                while True:
                    line=incoming.readline()
                    if not line:raise RuntimeError('Guest closed before completion')
                    evidence.write(line);evidence.flush();text=line.decode(errors='replace').strip();print(text,flush=True)
                    if text.startswith(('WM_BASELINE_','WM_FILTERED_','WM_OPT_OUT_')) and text!='WM_BASELINE_COMPLETE':
                        shot=out/(text.lower()+'.ppm');trial.qmp_call(stream,'screendump',{'filename':str(shot)})
                        from PIL import Image
                        with Image.open(shot) as screen:screen.save(shot.with_suffix('.png'))
                        connection.sendall(b'A')
                    if text=='WM_BASELINE_COMPLETE':break
            code=process.wait(timeout=60);(out/'result.json').write_text(json.dumps({'exit':code,'cold_boot':True}))
        except (TimeoutError,subprocess.TimeoutExpired):
            if stream:
                shot=out/'timeout.ppm';trial.qmp_call(stream,'screendump',{'filename':str(shot)})
                from PIL import Image
                with Image.open(shot) as screen:screen.save(shot.with_suffix('.png'))
            raise
        finally:
            if process.returncode is None:process.terminate();process.wait(timeout=60)
            serial.close();qmp.close()

if __name__=='__main__':main()
