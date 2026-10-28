"""SPDX-License-Identifier: GPL-3.0-or-later
Cold-boot an already completed trial with the final own files in an overlay.
Updates only C:\\USOS files. It never edits Windows files, hives or BCD.
The second probe is invoked once through Win+R after a bounded boot interval;
Startup must have launched the actual application before that measurement.
"""
from pathlib import Path
import argparse,hashlib,importlib.util,io,json,os,socket,subprocess,sys,threading,time
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
# The source is a completed disposable VM, sometimes ended by host teardown.
# Replay its NTFS log in this overlay; no physical device is ever exposed.
mount -t ntfs3 -o force /dev/vda1 /w
mount -t iso9660 -o ro /dev/vdb /patch
app=$(find /w/USOS -maxdepth 1 -type d -iname usoswm)
test -n "$app"
probe=$(find /w/USOS/WMTEST -maxdepth 1 -type f -iname wmprobe.exe)
test -n "$probe"
sha256sum /w/Windows/System32/ntoskrnl.exe /w/Windows/System32/win32k.sys /w/Windows/System32/shell32.dll /w/Windows/System32/user32.dll /w/Windows/System32/winload.exe /w/bootmgr >/run/windows-before.sha256
cd /patch/assets
sha256sum -c sha256.txt
for name in usoswm.exe usoswm-desktop.dll usoswm-register.exe;do
 target=$(find "$app" -maxdepth 1 -type f -iname "$name")
 test -n "$target"
 cat "$name" >"$target"
 test "$(sha256sum "$name"|cut -d' ' -f1)" = "$(sha256sum "$target"|cut -d' ' -f1)"
done
cat wmprobe.exe >/w/USOS/WMTEST/wm-full.exe
cat wmready.exe >"$probe"
test "$(sha256sum wmprobe.exe|cut -d' ' -f1)" = "$(sha256sum /w/USOS/WMTEST/wm-full.exe|cut -d' ' -f1)"
test "$(sha256sum wmready.exe|cut -d' ' -f1)" = "$(sha256sum "$probe"|cut -d' ' -f1)"
@BASELINE_FLAG@
sha256sum -c /run/windows-before.sha256
cd /
umount /patch;umount /w
echo USOSWM-OWN-UPDATE-PASS
'''



def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--previous',type=Path,required=True)
    parser.add_argument('--component',type=Path,required=True)
    parser.add_argument('--tool-root',type=Path,required=True)
    parser.add_argument('--linux-root',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--accel',choices=['tcg','whpx'],default='tcg')
    parser.add_argument('--consent-action',help='Explicit action for the previously inspected fixed-size lab UAC dialog')
    parser.add_argument('--native-rdp',type=Path,help='Own native ActiveX lab client; enables isolated RDP trial')
    parser.add_argument('--baseline',action='store_true',help='Native desktop first, then manual filter and opt-out')
    parser.add_argument('--limit-seconds',type=int,default=900)
    parser.add_argument('--boot-delay',type=int,default=120,help='One scheduled probe invocation after this cold-boot interval, without progress queries')
    args=parser.parse_args()
    if not 30<=args.boot_delay<=600 or args.limit_seconds<=args.boot_delay:parser.error('Boot delay must be 30..600 seconds and below the diagnostic deadline')
    previous=args.previous.resolve();result=json.loads((previous/'result.json').read_text())
    if result.get('exit')!=0 or 'WM_BASELINE_COMPLETE' not in (previous/'serial.log').read_text():raise ValueError('Use a completed measurement, not an active image; GUI acceptance must be assessed separately')
    out=args.out.resolve();out.mkdir(parents=True,exist_ok=False)
    (out/'trial-mode.json').write_text(json.dumps({'baseline':args.baseline,'rdp':bool(args.native_rdp),'boot_delay':args.boot_delay,'limit_seconds':args.limit_seconds},indent=2))
    tools=args.tool_root.resolve();trial.WORK=out;trial.TOOLS=tools;trial.ARCH='amd64'
    probe=trial.build()
    ready=out/'wmready.exe'
    files={name:(args.component/name).read_bytes() for name in ('usoswm.exe','usoswm-desktop.dll','usoswm-register.exe')}
    files['wmprobe.exe']=probe.read_bytes()
    files['wmready.exe']=ready.read_bytes()
    if args.native_rdp:
        # Test-only notification wrapper uses the already present Startup
        # link. The real launcher and DLL remain byte-identical to the
        # canonical component; no additional persistence is registered.
        files['usoswm-real.exe']=files['usoswm.exe']
        temp=out/'tmp';env=dict(os.environ,TEMP=str(temp),TMP=str(temp),ZIG_GLOBAL_CACHE_DIR=str(out/'zig-global'),ZIG_LOCAL_CACHE_DIR=str(out/'zig-local'))
        wrapper=out/'rdp-startup.exe'
        subprocess.run([str(tools/'zig/zig.exe'),'cc','-target','x86_64-windows.vista-gnu','-Os','-nostdlib','-fno-stack-protector','-fno-builtin','-I'+str(tools/'zig/lib/libc/include/any-windows-any'),str(HERE/'rdp_startup.c'),str(HERE.parents[1]/'nt6/usoswm/runtime.c'),'-Wl,--entry,entry','-Wl,--subsystem,windows','-lkernel32','-luser32','-o',str(wrapper)],env=env,check=True)
        files['usoswm.exe']=wrapper.read_bytes()
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
    flag=': >"$app/testmode-watermark-on.txt"' if args.baseline else 'rm -f "$app/testmode-watermark-on.txt"'
    if args.native_rdp:flag+='\ncat usoswm-real.exe >"$app/usoswm-real.exe"'
    initrd.write_bytes(raw+b'\0'*(-len(raw)%4)+cpio_newc([('update-init',0o100755,INIT.replace('@BASELINE_FLAG@',flag).encode())]))
    command=[str(tools/'qemu/qemu-system-x86_64.exe'),'-machine','q35','-accel','whpx','-accel','tcg','-cpu','qemu64,-xsave','-m','1024','-display','none','-nic','none','-monitor','none','-serial','stdio','-no-reboot','-kernel',str(args.linux_root/'vmlinuz-virt'),'-initrd',str(initrd),'-append','console=ttyS0,115200 rdinit=/update-init loglevel=3','-drive',f'if=virtio,format=qcow2,file={image}','-drive',f'if=virtio,format=raw,readonly=on,file={support}']
    with (out/'update.log').open('wb') as log:subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=180,check=True)
    if b'USOSWM-OWN-UPDATE-PASS' not in (out/'update.log').read_bytes():raise RuntimeError('Own-file stage failed')
    serial=socket.socket();serial.bind(('127.0.0.1',0));serial.listen();serial.settimeout(60)
    qmp=socket.socket();qmp.bind(('127.0.0.1',0));qmp.listen();qmp.settimeout(60)
    rdp_port=None
    if args.native_rdp:
        with socket.socket() as reserved:
            reserved.bind(('127.0.0.1',0));rdp_port=reserved.getsockname()[1]
    command=[str(tools/'qemu/qemu-system-x86_64.exe'),'-machine','pc','-accel',args.accel,'-cpu','max' if args.accel=='tcg' else 'qemu64,-xsave','-smp','2','-m','3072','-vga','std','-usb','-device','usb-tablet','-display','none','-nic','none','-boot','order=c,menu=off','-drive',f'if=ide,index=0,format=qcow2,file={image}','-serial',f'tcp:127.0.0.1:{serial.getsockname()[1]},server=off','-qmp',f'tcp:127.0.0.1:{qmp.getsockname()[1]},server=off','-monitor','none','-rtc','base=2009-07-01T12:00:00,clock=host']
    if rdp_port:
        i=command.index('-nic');command[i:i+2]=['-netdev',f'user,id=rdp,restrict=on,hostfwd=tcp:127.0.0.1:{rdp_port}-:3389','-device','e1000,netdev=rdp']
    (out/'command.json').write_text(json.dumps(command,indent=2))
    with (out/'qemu.log').open('wb') as log:
        process=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT);stream=None
        started=time.monotonic()
        (out/'process.json').write_text(json.dumps({'pid':process.pid,'started':time.time()}))
        try:
            connection,_=serial.accept();connection.settimeout(args.limit_seconds);q,_=qmp.accept();q.settimeout(60)
            stream=q.makefile('rwb',buffering=0);json.loads(stream.readline());trial.qmp_call(stream,'qmp_capabilities')
            print('Owned cold boot: one scheduled probe invocation, no progress queries',flush=True)
            threading.Event().wait(args.boot_delay)
            trial.ui_steps.type_run(trial.qmp_call,stream,r'c:\usos\wmtest\wm-full.exe'+(' --rdp-prepare' if rdp_port else '' if args.baseline else ' --post'))
            with (out/'serial.log').open('wb') as evidence:
                incoming=connection.makefile('rb')
                while True:
                    connection.settimeout(max(1,args.limit_seconds-(time.monotonic()-started)))
                    line=incoming.readline()
                    if not line:raise RuntimeError('Guest closed before completion')
                    evidence.write(line);evidence.flush();text=line.decode(errors='replace').strip();print(text,flush=True)
                    if text=='WM_UAC_REQUESTED':trial.ui_steps.consent_checkpoint(trial.qmp_call,stream,out,args.consent_action)
                    if text=='WM_UAC_FAILED':raise RuntimeError('VM consent was declined; no elevated test started')
                    if text=='WM_RDP_PREP_FAILED':raise RuntimeError('Guest RDP configuration failed')
                    if text.startswith(('SETUP_MODE_OUTSIDE_SETUP_EXIT=','SETUP_BACKGROUND_OUTSIDE_SETUP=')) and int(text.split('=')[1],16):raise RuntimeError('Setup background activated outside setup: '+text)
                    if text=='WM_RDP_READY':
                        import native_trial
                        native_trial.run(args.native_rdp,rdp_port,incoming,connection,out)
                        process.wait(timeout=300)
                        (out/'result.json').write_text(json.dumps({'exit':process.returncode,'rdp':True,'native_shutdown':True}))
                        return
                    if text.startswith(('WM_BASELINE_','WM_FILTERED_','WM_OPT_OUT_')) and text!='WM_BASELINE_COMPLETE':
                        if text.endswith('_CAD'):
                            trial.qmp_call(stream,'human-monitor-command',{'command-line':'sendkey ctrl-alt-delete'});threading.Event().wait(3)
                        shot=out/(text.lower()+'.ppm');trial.qmp_call(stream,'screendump',{'filename':str(shot)})
                        from PIL import Image
                        with Image.open(shot) as screen:screen.save(shot.with_suffix('.png'))
                        if text.endswith('_CAD'):
                            trial.qmp_call(stream,'human-monitor-command',{'command-line':'sendkey esc'});threading.Event().wait(1)
                        connection.sendall(b'A')
                    if text=='WM_BASELINE_COMPLETE':break
            code=process.wait(timeout=300);(out/'result.json').write_text(json.dumps({'exit':code,'cold_boot':True}))
        except (TimeoutError,subprocess.TimeoutExpired):
            if stream:
                shot=out/'timeout.ppm';trial.qmp_call(stream,'screendump',{'filename':str(shot)})
                from PIL import Image
                with Image.open(shot) as screen:screen.save(shot.with_suffix('.png'))
            raise
        finally:
            if process.returncode is None:
                try:
                    if stream:trial.qmp_call(stream,'quit')
                    process.wait(timeout=10)
                except (OSError,RuntimeError,subprocess.TimeoutExpired):process.terminate();process.wait(timeout=60)
            serial.close();qmp.close()

if __name__=='__main__':main()
