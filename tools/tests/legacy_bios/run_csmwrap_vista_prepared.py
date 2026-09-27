"""Vista without firmware CSM (profile vista-x64-sp2-uefi-csmwrap): QEMU test.

  prepare  runs tools/vista_csmwrap_target.sh (the product script) in the
           micro-Linux kernel/initramfs of zig-out/micro-linux with a test-only
           rdinit on a blank target: MBR, PE10 staging partition (NT60 boot code,
           bootmgr, BCD, boot.sdi, PE10 Setup image + the USOS Vista helpers),
           CSMWrap ESP. The menus and the DATA mount are skipped; the PE10 donor
           ISO is a raw read-only disk.
  boot     OVMF WITHOUT CSM, i440FX, TCG, std VGA (a PC-AT option ROM): the
           target on AHCI (bootindex 0), a test USOS stick (DATA with the Vista
           ISO) as USB storage on xHCI with USB keyboard and tablet. The firmware
           starts the target's \\EFI\\BOOT\\BOOTX64.EFI = CSMWrap -> SeaBIOS ->
           MBR -> NT60 -> bootmgr -> PE10 -> USOS installer -> Vista Setup (BIOS).
           QEMU keeps running; drive it with
             USOS_NATIVE_RUN=<run> python tools/tests/windows_native/qemu_native.py send|shot|kill

  python tools/tests/legacy_bios/run_csmwrap_vista_prepared.py prepare --run csmwrap-vista
  python tools/tests/legacy_bios/run_csmwrap_vista_prepared.py boot --run csmwrap-vista --stick tools/tests/artifacts/vista-esp-repro/stick-c.vhd

The stick is only read (a qcow2 overlay takes the writes). Everything stays in
tools/tests/artifacts/<run>. No physical disk access.
"""
from pathlib import Path
import argparse, gzip, json, shutil, stat, subprocess, sys, time, uuid
ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_micro_linux as cpio  # noqa: E402
from run_seabios_xp_uefi_csm_textmode import free_port  # noqa: E402

QEMU = ROOT / 'tools/qemu/qemu-system-x86_64.exe'
QEMU_IMG = ROOT / 'tools/qemu/qemu-img.exe'
OVMF_CODE = ROOT / 'tools/qemu/share/edk2-x86_64-code.fd'
OVMF_VARS = ROOT / 'tools/qemu/share/edk2-i386-vars.fd'
MICRO = ROOT / 'zig-out/micro-linux'
SUPPORT = ROOT / 'zig-out/windows-native'
CSMWRAP = ROOT / 'zig-out/usb/EFI/USOS/csmwrap'
ARTIFACTS = ROOT / 'tools/tests/artifacts'
DONOR = ROOT / 'zig-out/vista-e2e/PE10_x64_19041_USOS.iso'
TARGET_BYTES = 24 * 1024 ** 3
# The test stick tools/tests/artifacts/vista-esp-repro/stick-c.vhd (DATA
# PARTUUID from its creation log) and the Vista ISO on it.
DATA_PARTUUID = '2836dc24-36d2-4b2e-aaf1-27c024cc4338'
ISO_NAME = 'pl_windows_vista_with_sp2_x64_dvd_x15-36359.iso'
ISO_SIZE = 3702233088

PROBE_INIT = r'''#!/bin/sh
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
/bin/busybox --install -s
mount -t proc proc /proc; mount -t sysfs sysfs /sys; mount -t devtmpfs devtmpfs /dev
mkdir -p /run /tmp; mount -t tmpfs tmpfs /run
log() { printf '[VISTA_PROBE] %s\n' "$*"; }
finish() { log "RESULT $1"; sync; poweroff -f; sleep 5; }
for d in /sys/bus/pci/devices/*; do modprobe "$(cat "$d/modalias")" 2>/dev/null; done
for m in sd_mod ntfs3 udf isofs loop; do modprobe $m 2>/dev/null; done
sleep 3; mdev -s; cat /proc/partitions
TARGET_DEV= DONOR_DEV=
for b in /sys/block/sd?; do
  case "$(cat "$b/size")" in 50331648) TARGET_DEV=/dev/${b##*/} ;; *) DONOR_DEV=/dev/${b##*/} ;; esac
done
log "disks target=$TARGET_DEV donor=$DONOR_DEV"
[ -n "$TARGET_DEV" ] && [ -n "$DONOR_DEV" ] || finish 'FAIL disk identification'
ANSWER=
[ ! -f /probe-answer.xml ] || ANSWER=/probe-answer.xml
TARGET_DEVICE=$TARGET_DEV VISTA_DONOR_ISO=$DONOR_DEV VISTA_REQUEST_DIR=/probe-request VISTA_SUPPORT_DIR=/probe-support \
  VISTA_ANSWER_XML=$ANSWER USOS_CSMWRAP_DIR=/csmwrap-src USOS_CSMWRAP_VERBOSE_FLAG=/probe-verbose.flag \
  sh /usr/lib/usos/vista_csmwrap_target.sh || finish 'FAIL vista_csmwrap_target'
dd if="$TARGET_DEV" bs=512 count=1 2>/dev/null | od -An -tx1 | tail -n 6
finish PREPARED-PASS
'''


def source_binding():
    """usos-source.ini as src/platform/bios/windows_iso_config.zig encodes it."""
    path = f'Systems\\Windows\\Windows Vista\\Images\\{ISO_NAME}\0'.encode('ascii')
    return b'USOSISO1' + uuid.UUID(DATA_PARTUUID).bytes_le + ISO_SIZE.to_bytes(8, 'little') + path


def prepare(run, answer=None, verbose=False):
    run.mkdir(parents=True, exist_ok=True)
    target = run / 'target.qcow2'
    target.unlink(missing_ok=True)
    subprocess.run([str(QEMU_IMG), 'create', '-q', '-f', 'qcow2', str(target), str(TARGET_BYTES)], check=True)
    entries = cpio.parse_newc(gzip.decompress((MICRO / 'initramfs-usos').read_bytes()) if (MICRO / 'initramfs-usos').read_bytes()[:2] == b'\x1f\x8b' else (MICRO / 'initramfs-usos').read_bytes())
    put = lambda name, data, mode=0o644: cpio.put(entries, cpio.Entry(name, stat.S_IFREG | mode, data))
    put('probe-init', PROBE_INIT.encode(), 0o755)
    for d in ('probe-request', 'probe-support', 'csmwrap-src'):
        cpio.put(entries, cpio.Entry(d, stat.S_IFDIR | 0o755, b''))
    put('probe-request/usos-source.ini', source_binding())
    for name in ('support.cpio', 'vista-support.cpio'):
        put('probe-support/' + name, (SUPPORT / name).read_bytes())
    for name in ('csmwrapx64.efi', 'LICENSE-CSMWrap-LGPL-2.1.txt', 'COPYING-SeaBIOS-LGPLv3.txt', 'COPYING-SeaBIOS-GPLv3.txt', 'SOURCES.txt'):
        put('csmwrap-src/' + name, (CSMWRAP / name).read_bytes())
    if answer:
        put('probe-answer.xml', Path(answer).read_bytes())
    if verbose:
        put('probe-verbose.flag', b'')
    # The working tree's scripts (the micro-Linux build may be older).
    for name in ('vista_csmwrap_target.sh', 'xp_csmwrap_esp.sh'):
        put('usr/lib/usos/' + name, (ROOT / 'tools' / name).read_bytes().replace(b'\r\n', b'\n'), 0o755)
    initrd = run / 'initramfs-probe'
    initrd.write_bytes(gzip.compress(cpio.newc(entries), compresslevel=1, mtime=0))
    serial = run / 'prepare-serial.log'
    cmd = [str(QEMU), '-machine', 'pc', '-accel', 'tcg,thread=multi', '-cpu', 'max', '-m', '2048', '-smp', '2', '-display', 'none', '-nic', 'none',
           '-serial', 'file:' + str(serial), '-kernel', str(MICRO / 'vmlinuz-virt'), '-initrd', str(initrd),
           '-append', 'console=ttyS0,115200 rdinit=/probe-init quiet',
           '-drive', 'if=none,id=target,format=qcow2,file=' + str(target), '-device', 'ide-hd,bus=ide.0,unit=0,drive=target,serial=VISTA-TARGET',
           '-drive', 'if=none,id=donor,format=raw,snapshot=on,file=' + str(DONOR), '-device', 'ide-hd,bus=ide.1,unit=0,drive=donor,serial=PE10-DONOR']
    started = time.time()
    subprocess.run(cmd, timeout=3600, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    log = serial.read_text(errors='replace')
    ok = '[VISTA_PROBE] RESULT PREPARED-PASS' in log
    print(f'[PREPARE] {"PASS" if ok else "FAIL"} in {time.time() - started:.0f} s')
    print('\n'.join(line for line in log.splitlines() if 'VISTA_CSMWRAP' in line or 'XP_CSMWRAP' in line or 'VISTA_PROBE' in line))
    if not ok:
        raise SystemExit(log[-5000:])
    shutil.copyfile(target, run / 'target-prepared.qcow2')
    return target


def boot(run, stick, accel='tcg,thread=multi'):
    overlay = run / 'stick-overlay.qcow2'
    if not overlay.exists():
        fmt = 'vpc' if stick.suffix.lower() == '.vhd' else 'qcow2'
        subprocess.run([str(QEMU_IMG), 'create', '-q', '-f', 'qcow2', '-F', fmt, '-b', str(stick.resolve()), str(overlay)], check=True)
    shutil.copyfile(OVMF_VARS, run / 'vars.fd')
    port = free_port()
    cmd = [str(QEMU), '-name', 'USOS-csmwrap-vista', '-machine', 'pc', '-accel', accel, '-cpu', 'max', '-m', '4096', '-smp', '2',
           '-nic', 'none', '-display', 'none', '-vga', 'std',
           '-monitor', f'tcp:127.0.0.1:{port},server=on,wait=off',
           '-serial', f'file:{(run / "serial-boot.log").as_posix()}',
           '-drive', f'if=pflash,format=raw,readonly=on,file={OVMF_CODE.as_posix()}',
           '-drive', f'if=pflash,format=raw,file={(run / "vars.fd").as_posix()}',
           '-device', 'ahci,id=sata', '-drive', f'if=none,id=target,format=qcow2,file={(run / "target.qcow2").as_posix()}',
           '-device', 'ide-hd,bus=sata.0,drive=target,serial=VISTATARGET,bootindex=0',
           '-device', 'qemu-xhci,id=xhci', '-device', 'usb-kbd,bus=xhci.0', '-device', 'usb-tablet,bus=xhci.0',
           '-drive', f'if=none,id=stick,format=qcow2,file={overlay.as_posix()}',
           '-device', 'usb-storage,bus=xhci.0,drive=stick,removable=on,serial=USOSSTICK']
    stderr = open(run / 'qemu-boot.stderr.log', 'wb')
    process = subprocess.Popen(cmd, stderr=stderr, stdout=subprocess.DEVNULL, creationflags=getattr(subprocess, 'CREATE_NEW_PROCESS_GROUP', 0))
    (run / 'qemu-state.json').write_text(json.dumps({'pid': process.pid, 'port': port, 'label': 'boot', 'started': time.time()}))
    print(f'[QEMU] pid={process.pid} monitor=127.0.0.1:{port}')


def main():
    p = argparse.ArgumentParser()
    p.add_argument('cmd', choices=['prepare', 'boot'])
    p.add_argument('--run', default='csmwrap-vista')
    p.add_argument('--stick', type=Path, default=ARTIFACTS / 'vista-esp-repro/stick-c.vhd')
    p.add_argument('--answer', type=Path, help='usos-unattend.xml stand-in (merged by the installer)')
    p.add_argument('--verbose', action='store_true', help='csmwrap.ini verbose=true')
    p.add_argument('--accel', default='tcg,thread=multi')
    a = p.parse_args()
    run = (ARTIFACTS / a.run).resolve()
    if a.cmd == 'prepare':
        prepare(run, a.answer, a.verbose)
    else:
        boot(run, a.stick, a.accel)
    return 0


if __name__ == '__main__':
    sys.exit(main())
