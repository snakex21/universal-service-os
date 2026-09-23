"""XP UEFI-CSM package: prepare a blank disk with the packaged scripts, then boot
it alone under SeaBIOS and record every XP text-mode screen until files copy.

Phase 1 runs the package's own chain (probe_nt5_source, driver preflight,
target_disk_guard snapshot, the automatic plan and prepare_xp_target.sh ->
prepare_xp_ntfs_target.sh) in the package kernel with a test-only rdinit;
only the menus are skipped. Phase 2 boots the prepared disk as BIOS 0x80
with no USOS media and no ISO, polls VGA text memory and optionally types
keys (--keys) during text mode to show what they can change.

  python tools/tests/legacy_bios/run_seabios_xp_uefi_csm_textmode.py --output zig-out/xp-uefi-textmode-<tag> [--keys "d c esc f3 ret"]
Disposable images only; no physical disk access.
"""
from pathlib import Path
import argparse, gzip, json, socket, stat, subprocess, sys, time
ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'tools'))
import build_micro_linux as cpio

QEMU=ROOT/'tools/qemu/qemu-system-x86_64.exe'
QEMU_IMG=ROOT/'tools/qemu/qemu-img.exe'
SEABIOS=ROOT/'tools/qemu/share/bios-256k.bin'
PACKAGE=ROOT/'zig-out/xp-uefi-csm'
DEFAULT_ISO=Path('L:/Systems/Windows/Windows XP/Images/pl_windows_xp_professional_with_service_pack_3_x86_cd_x14-80476.iso')
TARGET_BYTES=12*1024**3

PROBE_INIT=r'''#!/bin/sh
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
/bin/busybox --install -s
mount -t proc proc /proc; mount -t sysfs sysfs /sys; mount -t devtmpfs devtmpfs /dev
mkdir -p /run /tmp /mnt/source /mnt/esp/EFI/USOS-XP /mnt/esp/EFI/USOS; mount -t tmpfs tmpfs /run
log() { printf '[TEXTMODE_PROBE] %s\n' "$*"; }
finish() { log "RESULT $1"; sync; poweroff -f; sleep 5; }
for d in /sys/bus/pci/devices/*; do modprobe "$(cat "$d/modalias")" 2>/dev/null; done
for m in sd_mod isofs ntfs3 loop; do modprobe $m 2>/dev/null; done
sleep 3; mdev -s; cat /proc/partitions
mount -t iso9660 -o ro,map=off /dev/sdc /mnt/source || finish 'FAIL iso mount'
export SOURCE_ROOT=/mnt/source TARGET_DEVICE=/dev/sdb USOS_DISK_DEVICE=/dev/sda
export TARGET_SNAPSHOT=/run/xp-target.snapshot XP_ALLOW_EMPTY=yes
export XP_BIOS_DRIVE=80 XP_BIOS_CYLINDERS=1024 XP_BIOS_HEADS=255 XP_BIOS_SPT=63
export XP_READY_FILE=/mnt/esp/EFI/USOS-XP/xp-target-ready.ini XPSETUP_MOUNT=/mnt/xpsetup
. /usr/lib/usos/nt5_profile.sh; usos_nt5_profile
sh /usr/lib/usos/probe_nt5_source.sh || finish 'FAIL source probe'
. /usr/lib/usos/xp_driver_stage.sh; usos_xp_driver_preflight || finish 'FAIL driver preflight'
sh /usr/lib/usos/target_disk_guard.sh snapshot || finish 'FAIL snapshot'
awk -f /usr/lib/usos/xp_windows_partition_plan.awk "$TARGET_SNAPSHOT" > /run/xp-windows.plan || finish 'FAIL plan'
cat /run/xp-windows.plan; export XP_WINDOWS_PLAN=/run/xp-windows.plan
. /usr/lib/usos/target_disk_identity.sh
TARGET_CONFIRMATION="CREATE XPSETUP $(usos_disk_model "$TARGET_DEVICE") $(usos_disk_serial "$TARGET_DEVICE")"; export TARGET_CONFIRMATION
sh /usr/lib/usos/prepare_xp_target.sh || finish 'FAIL prepare_xp_target'
finish PREPARED-PASS
'''

def free_port():
    s=socket.socket();s.bind(('127.0.0.1',0));p=s.getsockname()[1];s.close();return p

class Monitor:
    def __init__(self,port):
        for _ in range(100):
            try:self.s=socket.create_connection(('127.0.0.1',port),timeout=5);break
            except OSError:time.sleep(0.1)
        self.s.settimeout(0.3);self.drain()
    def drain(self):
        try:
            while self.s.recv(65536):pass
        except OSError:pass
    def cmd(self,text):self.s.sendall(text.encode()+b'\n');time.sleep(0.15);self.drain()

def vga_text(dump,rows_count):
    b=dump.read_bytes();rows=[]
    for r in range(rows_count):
        rows.append(''.join(chr(c) if 32<=c<127 else ' ' for c in b[r*160:r*160+160:2]).rstrip())
    return '\n'.join(rows)

def prepare(out,iso):
    usos=out/'usos-blank.qcow2';target=out/'target.qcow2'
    for disk,size in ((usos,256*1024**2),(target,TARGET_BYTES)):
        subprocess.run([str(QEMU_IMG),'create','-q','-f','qcow2',str(disk),str(size)],check=True)
    entries=cpio.parse_newc(gzip.decompress((PACKAGE/'initramfs-xp').read_bytes()))
    cpio.put(entries,cpio.Entry('probe-init',stat.S_IFREG|0o755,PROBE_INIT.encode()))
    initrd=out/'initramfs-probe';initrd.write_bytes(gzip.compress(cpio.newc(entries),compresslevel=1,mtime=0))
    serial=out/'prepare-serial.log'
    cmd=[str(QEMU),'-machine','pc','-accel','tcg,thread=multi','-cpu','max','-m','1024','-smp','2','-display','none','-nic','none',
         '-serial','file:'+str(serial),'-kernel',str(PACKAGE/'vmlinuz.efi'),'-initrd',str(initrd),
         '-append','console=ttyS0,115200 rdinit=/probe-init quiet',
         '-drive','if=none,id=usos,format=qcow2,file='+str(usos),'-device','ide-hd,bus=ide.0,unit=0,drive=usos,serial=USOS-PROBE-STICK',
         '-drive','if=none,id=target,format=qcow2,file='+str(target),'-device','ide-hd,bus=ide.0,unit=1,drive=target,serial=XP-TEXTMODE-TARGET',
         '-drive','if=none,id=iso,format=raw,snapshot=on,file='+str(iso),'-device','ide-hd,bus=ide.1,unit=0,drive=iso,serial=XP-SOURCE-ISO']
    subprocess.run(cmd,timeout=1800,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    log=serial.read_text(errors='replace')
    if '[TEXTMODE_PROBE] RESULT PREPARED-PASS' not in log:raise SystemExit('preparation failed:\n'+log[-5000:])
    return target

def textmode(out,target,keys,minutes):
    port=free_port()
    proc=subprocess.Popen([str(QEMU),'-machine','pc','-accel','tcg,thread=multi','-cpu','max','-m','512','-smp','1','-bios',str(SEABIOS),
        '-boot','order=c,strict=on','-display','none','-vga','std','-nic','none','-monitor',f'tcp:127.0.0.1:{port},server=on,wait=off',
        '-drive','if=ide,index=0,format=qcow2,file='+str(target)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    screens=[];last=None;deadline=time.time()+minutes*60;shots=out/'screens';shots.mkdir(exist_ok=True)
    key_list=keys.split() if keys else [];key_index=0;result='timeout';copying_since=None
    try:
        mon=Monitor(port);start=time.time();n=0;last_shot=0;frame=0
        while time.time()<deadline and proc.poll() is None:
            dump=shots/'cur.bin';bda=shots/'bda.bin';dump.unlink(missing_ok=True);bda.unlink(missing_ok=True)
            # BIOS data area 0x484 = text rows - 1 (XP text-mode Setup runs 80x50).
            mon.cmd(f'pmemsave 0x400 256 "{bda.as_posix()}"')
            mon.cmd(f'pmemsave 0xb8000 8000 "{dump.as_posix()}"')
            for _ in range(20):
                if dump.exists() and dump.stat().st_size==8000 and bda.exists() and bda.stat().st_size==256:break
                time.sleep(0.05)
            # Text-mode Setup programs 80x50 itself (the BIOS row count stays 25).
            rows_count=50
            text=vga_text(dump,rows_count) if dump.exists() else ''
            if text.strip() and text!=last:
                n+=1;t=round(time.time()-start,1);last=text
                mon.cmd(f'screendump "{(shots/("%03d.ppm"%n)).as_posix()}"')
                (shots/('%03d.txt'%n)).write_text(text,encoding='utf-8');screens.append({'n':n,'t':t,'text':text})
                print(f'--- screen {n} at {t}s ---\n{text}\n',flush=True)
            if time.time()-start<75 and time.time()-last_shot>=1.5:
                last_shot=time.time();frame+=1
                mon.cmd(f'screendump "{(shots/("boot-%03d.ppm"%frame)).as_posix()}"')
            low=text.lower()
            copying=('kopiuje pliki' in low or 'copying files' in low) and '%' in low
            if copying and not key_list:result='copying';break
            if copying and copying_since is None:copying_since=time.time()
            if copying_since is not None and time.time()-copying_since>45:
                # Keys kept arriving for 45 s of copying: still copying = no effect.
                result='copying';break
            if key_list and ('instalator' in low or 'setup' in low):
                # Every key of the list, each poll: text Mode gets them all repeatedly.
                for key in key_list:
                    mon.cmd('sendkey '+key);key_index+=1
                screens.append({'t':round(time.time()-start,1),'keys':key_list})
            time.sleep(0.1 if key_list else 0.4)
    finally:
        try:mon.cmd('quit')
        except Exception:pass
        try:proc.wait(10)
        except Exception:proc.kill()
    (out/'textmode.json').write_text(json.dumps({'result':result,'keys':key_list,'keys_sent':key_index,'events':screens},indent=1,ensure_ascii=False),encoding='utf-8')
    return result

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--iso',type=Path,default=DEFAULT_ISO)
    p.add_argument('--keys',default='');p.add_argument('--minutes',type=float,default=25);p.add_argument('--reuse-prepared',type=Path)
    a=p.parse_args();out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
    prepared=a.reuse_prepared.resolve() if a.reuse_prepared else prepare(out,a.iso)
    print('[PASS] prepared',prepared,flush=True)
    # Boot an overlay so the prepared image stays pristine for further runs.
    target=out/'boot-overlay.qcow2';target.unlink(missing_ok=True)
    subprocess.run([str(QEMU_IMG),'create','-q','-f','qcow2','-F','qcow2','-b',str(prepared),str(target)],check=True)
    r=textmode(out,target,a.keys,a.minutes)
    print('[RESULT]',r)
    sys.exit(0 if r=='copying' else 1)
