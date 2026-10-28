"""SPDX-License-Identifier: GPL-3.0-or-later
Replay only the pre-deploy desktop checkpoint in a disposable VM overlay.

This is a deliberately rearmed setup fixture, not a fresh-install PASS. No
physical drive is accepted. An existing failed --gate-native trial is required.
Its private SYSTEM hive is copied only into its new, file-backed overlay.
"""
from pathlib import Path
import argparse,hashlib,io,json,os,socket,struct,subprocess,sys
import pycdlib
from Registry import Registry
sys.path.insert(0,str(Path(__file__).resolve().parent))
import run as trial
import resume

def rearm(path):
    raw=bytearray(path.read_bytes());hive=Registry.Registry(io.BytesIO(raw))
    if raw[:4]!=b'regf' or raw[4:8]!=raw[8:12]:raise ValueError('Unclean hive')
    if hive.open('Setup').value('CmdLine').value().lower()!=r'c:\usos\oobe.exe':raise ValueError('Not the explicit failed lab gate')
    changes=[('Setup','SetupType',0,2),('Setup','SystemSetupInProgress',1,1),
        ('Setup','SetupPhase',4,4),('Setup','OOBEInProgress',1,0),
        (r'Setup\Status\ChildCompletion','setup.exe',2,0)]
    for key,name,before,after in changes:
        value=hive.open(key).value(name);record=value._vkrecord
        if value.value_type()!=Registry.RegDWord or value.value()!=before or record.raw_data_length()!=0x80000004:
            raise ValueError('Unexpected lab-only setup value '+name)
        struct.pack_into('<I',raw,record.absolute_offset(8),after)
    sequence=struct.unpack_from('<I',raw,4)[0]+1
    struct.pack_into('<II',raw,4,sequence,sequence)
    checksum=0
    for offset in range(0,0x1fc,4):checksum^=struct.unpack_from('<I',raw,offset)[0]
    checksum=1 if checksum==0 else 0xfffffffe if checksum==0xffffffff else checksum
    struct.pack_into('<I',raw,0x1fc,checksum)
    checked=Registry.Registry(io.BytesIO(raw))
    for key,name,_,after in changes:
        if checked.open(key).value(name).value()!=after:raise ValueError('Rearm verification failed')
    return bytes(raw)

def main():
    parser=argparse.ArgumentParser()
    for name in ('previous','tool-root','linux-root','component','out'):parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--baseline',action='store_true',help='Keep the native test-mode text through the empty opt-out marker')
    parser.add_argument('--lifecycle',action='store_true',help='Explicit test-only setup-end notification and child process completion proof')
    args=parser.parse_args();previous=args.previous.resolve();out=args.out.resolve()
    if json.loads((previous/'result.json').read_text()).get('status')!='timeout':raise ValueError('Requires the closed failed setup fixture')
    if not (previous/'oobe.exe').is_file():raise ValueError('Requires a gate-native lab image')
    system=rearm(previous/'closed-inspection/files/SYSTEM')
    out.mkdir(parents=True,exist_ok=False);tools=args.tool_root.resolve()
    trial.WORK=out;trial.TOOLS=tools;trial.ARCH='amd64';trial.GATE_NATIVE=True
    probe=trial.build()
    files={name:(args.component/name).read_bytes() for name in ('usoswm.exe','usoswm-desktop.dll','usoswm-register.exe')}
    files.update({'wmprobe.exe':probe.read_bytes(),'wmready.exe':(out/'wmready.exe').read_bytes(),
        'oobe.exe':(out/'oobe.exe').read_bytes(),'SYSTEM':system})
    manifest={name:hashlib.sha256(data).hexdigest() for name,data in files.items()}
    files['sha256.txt']=''.join(digest+'  '+name+'\n' for name,digest in manifest.items()).encode()
    (out/'own-manifest.json').write_text(json.dumps(manifest,indent=2))
    iso=pycdlib.PyCdlib();iso.new(interchange_level=3,joliet=3,vol_ident='USOSSETUPLAB')
    iso.add_directory('/ASSETS',joliet_path='/assets')
    for name,raw in files.items():iso.add_fp(io.BytesIO(raw),len(raw),iso_path='/ASSETS/'+name.upper().replace('-','_')+';1',joliet_path='/assets/'+name)
    support=out/'private-update.iso';iso.write(str(support));iso.close()
    image=out/'target.qcow2'
    subprocess.run([str(tools/'qemu/qemu-img.exe'),'create','-q','-f','qcow2','-F','qcow2','-b',str(previous/'target.qcow2'),str(image)],check=True)
    sys.path.insert(0,str(tools/'tests'))
    from run_nt3_micro_linux_qemu import cpio_newc
    if args.baseline and args.lifecycle:parser.error('Lifecycle needs an active background')
    script=resume.INIT.replace('@BASELINE_FLAG@',': >"$app/testmode-watermark-on.txt"' if args.baseline else 'rm -f "$app/testmode-watermark-on.txt"')
    script=script.replace('cd /\numount /patch;umount /w',
        'gate=$(find /w/USOS -maxdepth 1 -type f -iname oobe.exe)\n'
        'test -n "$gate"\ncat oobe.exe >"$gate"\n'
        'test "$(sha256sum oobe.exe|cut -d\' \' -f1)" = "$(sha256sum "$gate"|cut -d\' \' -f1)"\n'
        'cat SYSTEM >/w/Windows/System32/config/SYSTEM\nsync\ncd /\numount /patch;umount /w')
    raw=(args.linux_root/'initramfs-usos').read_bytes();initrd=out/'replay-initrd'
    initrd.write_bytes(raw+b'\0'*(-len(raw)%4)+cpio_newc([('update-init',0o100755,script.encode())]))
    stage=[str(tools/'qemu/qemu-system-x86_64.exe'),'-machine','q35','-accel','whpx','-accel','tcg','-cpu','qemu64,-xsave','-m','1024','-display','none','-nic','none','-monitor','none','-serial','stdio','-no-reboot','-kernel',str(args.linux_root/'vmlinuz-virt'),'-initrd',str(initrd),'-append','console=ttyS0,115200 rdinit=/update-init loglevel=3','-drive',f'if=virtio,format=qcow2,file={image}','-drive',f'if=virtio,format=raw,readonly=on,file={support}']
    with (out/'update.log').open('wb') as log:subprocess.run(stage,stdout=log,stderr=subprocess.STDOUT,timeout=180,check=True)
    if b'USOSWM-OWN-UPDATE-PASS' not in (out/'update.log').read_bytes():raise RuntimeError('Private replay staging failed')
    with socket.socket() as serial,socket.socket() as qmp:
        serial.bind(('127.0.0.1',0));serial.listen();serial.settimeout(600)
        qmp.bind(('127.0.0.1',0));qmp.listen();qmp.settimeout(60)
        cmd=[str(tools/'qemu/qemu-system-x86_64.exe'),'-machine','pc','-accel','tcg','-cpu','max','-smp','2','-m','3072','-vga','std','-display','none','-nic','none','-monitor','none','-boot','order=c','-drive',f'if=ide,index=0,format=qcow2,file={image}','-serial',f'tcp:127.0.0.1:{serial.getsockname()[1]},server=off','-qmp',f'tcp:127.0.0.1:{qmp.getsockname()[1]},server=off','-rtc','base=2009-07-01T12:00:00,clock=host']
        (out/'command.json').write_text(json.dumps(cmd,indent=2))
        with (out/'qemu.log').open('wb') as log:
            process=subprocess.Popen(cmd,stdout=log,stderr=subprocess.STDOUT);stream=None
            try:
                connection,_=serial.accept();connection.settimeout(600);q,_=qmp.accept();q.settimeout(60)
                stream=q.makefile('rwb',buffering=0);json.loads(stream.readline());trial.qmp_call(stream,'qmp_capabilities')
                print('Setup replay awaiting the single guest checkpoint; no progress queries',flush=True)
                with (out/'serial.log').open('wb') as evidence:
                    incoming=connection.makefile('rb')
                    while True:
                        line=incoming.readline()
                        if not line:raise RuntimeError('Guest closed before setup checkpoint')
                        evidence.write(line);evidence.flush();text=line.decode(errors='replace').strip();print(text,flush=True)
                        if text in ('WM_SETUP_GATE_NATIVE','WM_SETUP_GATE_DESKTOP','WM_SETUP_BACKGROUND_CLOSED'):
                            shot=out/(text.lower()+'.ppm');trial.qmp_call(stream,'screendump',{'filename':str(shot)})
                            from PIL import Image
                            with Image.open(shot) as screen:screen.save(shot.with_suffix('.png'))
                            if text=='WM_SETUP_BACKGROUND_CLOSED' or text=='WM_SETUP_GATE_DESKTOP' and not args.lifecycle:break
                            connection.sendall(b'F' if text=='WM_SETUP_GATE_DESKTOP' else b'A')
                        if text=='WM_SETUP_BACKGROUND_CLOSE_FAILED':raise RuntimeError('Setup background failed to close')
                trial.qmp_call(stream,'quit');process.wait(timeout=30)
                (out/'result.json').write_text(json.dumps({'exit':process.returncode,'setup_replay_checkpoint':True,'opt_out':args.baseline,'setup_end_process_completion':args.lifecycle,'fresh_install_acceptance':False}))
            except TimeoutError:
                if stream:
                    shot=out/'timeout.ppm';trial.qmp_call(stream,'screendump',{'filename':str(shot)})
                    from PIL import Image
                    with Image.open(shot) as screen:screen.save(shot.with_suffix('.png'))
                raise
            finally:
                if process.returncode is None:
                    if stream:trial.qmp_call(stream,'quit')
                    else:process.terminate()
                    process.wait(timeout=30)

if __name__=='__main__':main()
