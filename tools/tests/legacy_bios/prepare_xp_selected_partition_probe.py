"""Disposable experiment: local source on the selected Windows partition.

Inputs are read-only backing images. The injected init script is test-only.
"""
import argparse
import gzip
import socket
import stat
import struct
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools"))
import build_micro_linux as cpio

SIF = r'''[Data]
msdosinitiated="1"
floppyless="1"
UseSignatures="yes"
InstallDir="\WINDOWS"
EulaComplete="1"
winntupgrade="no"
win9xupgrade="no"
OriSrc="D:\"
OriTyp="5"
[Unattended]
UnattendMode=ProvideDefault
OemSkipEula=Yes
OemPreinstall=No
Repartition=No
FileSystem=LeaveAlone
TargetPath=\WINDOWS
WaitForReboot=No
'''

PREPARE = r'''#!/bin/sh
set -eu
fail() { echo "[SELECTED_PROBE] STOP: $1"; poweroff -f; exit 1; }
. /usr/lib/usos/target_disk_identity.sh
[ "$(usos_disk_serial /dev/sdb)" = XP-SELECTED-PROBE ] || fail 'wrong target'
[ "$(usos_disk_size /dev/sdb)" = 120034123776 ] || fail 'wrong size'
dd if=/dev/sdb of=/run/before.bin bs=512 count=1 2>/dev/null
cmp -s /run/before.bin /probe-before.bin || fail 'input MBR changed'
dd if=/probe-partition.bin of=/dev/sdb bs=1 seek=462 count=16 conv=notrunc 2>/dev/null
blockdev --rereadpt /dev/sdb
mdev -s
[ -b /dev/sdb1 ] && [ -b /dev/sdb2 ] || fail 'missing partitions'
mkntfs -Q -F -L XPWINDOWS /dev/sdb2 || fail 'format failed'
modprobe ntfs3
mkdir -p /mnt/probe-setup /mnt/probe-windows
mount -t vfat /dev/sdb1 /mnt/probe-setup
mount -t ntfs3 /dev/sdb2 /mnt/probe-windows
cp -a '/mnt/probe-setup/$WIN_NT$.~LS' /mnt/probe-windows/
test -s '/mnt/probe-windows/$WIN_NT$.~LS/I386/NTLDR' || fail 'copy incomplete'
rm -rf '/mnt/probe-setup/$WIN_NT$.~LS'
cp /probe-winnt.sif '/mnt/probe-setup/$WIN_NT$.~BT/WINNT.SIF'
sync
umount /mnt/probe-windows
umount /mnt/probe-setup
echo '[SELECTED_PROBE] PREPARED PASS source=NTFS-partition-2 boot=FAT32-partition-1'
sync
poweroff -f
'''

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    original = ROOT / "zig-out/repair-bios-20260909/vbox-staging/xp-target.raw"
    usos_original = ROOT / "zig-out/repair-bios-20260909/vbox-staging/fixture/xp-menu-usos.qcow2"
    qi = ROOT / "tools/qemu/qemu-img.exe"
    target = out / "selected-target.qcow2"
    usos = out / "usos.qcow2"
    for source, fmt, dest in [(original, "raw", target), (usos_original, "qcow2", usos)]:
        subprocess.run([str(qi), "create", "-f", "qcow2", "-F", fmt, "-b", str(source), str(dest)], check=True)
    with original.open("rb") as handle:
        before = handle.read(512)
    assert before[462:510] == bytes(48), "probe requires only XPSETUP on input"
    entry = struct.pack("<B3sB3sII", 0, b"\xfe\xff\xff", 7, b"\xfe\xff\xff", 4196352, 33554432)
    entries = cpio.parse_newc(gzip.decompress((ROOT / "zig-out/micro-linux/initramfs-usos").read_bytes()))
    init = entries["usos-init"].data.decode()
    anchor = 'if [ -n "$LEGACY_ACTION" ]; then'
    assert anchor in init
    entries["usos-init"].data = init.replace(anchor, "sh /probe-prepare.sh\n" + anchor, 1).encode()
    for name, data in [("probe-prepare.sh", PREPARE.encode()), ("probe-winnt.sif", SIF.encode()), ("probe-before.bin", before), ("probe-partition.bin", entry)]:
        cpio.put(entries, cpio.Entry(name, stat.S_IFREG | 0o644, data))
    initramfs = out / "initramfs-probe"
    initramfs.write_bytes(gzip.compress(cpio.newc(entries), compresslevel=9, mtime=0))
    serial = out / "serial.log"
    command = [str(ROOT / "tools/qemu/qemu-system-x86_64.exe"), "-machine", "pc", "-accel", "tcg,thread=multi", "-cpu", "max", "-m", "512", "-smp", "2", "-display", "none", "-nic", "none", "-serial", "file:" + str(serial), "-kernel", str(ROOT / "zig-out/micro-linux/vmlinuz-virt"), "-initrd", str(initramfs), "-append", "console=ttyS0,115200 rdinit=/usos-init usos.esp_partuuid=ed5ccc07-7a88-4bfe-b5d1-34d45b2db302", "-drive", "if=ide,index=0,format=qcow2,file=" + str(usos), "-drive", "if=none,id=target,format=qcow2,file=" + str(target), "-device", "ide-hd,bus=ide.0,unit=1,drive=target,serial=XP-SELECTED-PROBE"]
    with (out / "qemu.log").open("w") as log:
        subprocess.run(command, stdout=log, stderr=log, timeout=240, check=True, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    transcript = serial.read_text(errors="replace")
    assert "[SELECTED_PROBE] PREPARED PASS" in transcript, transcript[-4000:]
    vdi = out / "selected-target.vdi"
    subprocess.run([str(qi), "convert", "-f", "qcow2", "-O", "vdi", str(target), str(vdi)], check=True)
    subprocess.run([sys.executable, str(Path(__file__).with_name("patch_vdi_geometry.py")), str(vdi), "--cylinders", "1024", "--heads", "240", "--sectors", "63"], check=True)
    print("[PASS] Prepared experiment: " + str(vdi))

if __name__ == "__main__":
    main()
