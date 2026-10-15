"""QEMU test for CSMWrap 3.1.2-usos10 patch 0010 (SeaBIOS NVMe runtime re-arm).

Windows 98 SE boots from NVMe (CSMWrap SeaBIOS INT 13h, then usosnvme.mpd).
usosnvme rebuilds the admin queue in its own memory at start and, on the exit
to real mode, sends CC.SHN and disables the controller. WIN.COM /z (98's APM
power-off) then needs INT 13h again. Windows 98 itself cannot be used for
this in QEMU (under CSMWrap its VMM exit hangs, docs/research/
win9x-acpi-2026-10-15.md), so nvme_rearm_mbr.S replays the driver's register
sequence from a boot sector:

  R1   INT 13h read through SeaBIOS's POST queues
  REF  controller enabled with a foreign admin queue (usosnvme running):
       the INT 13h read must fail at once, nothing is touched
  R2   CC.SHN normal + CC.EN = 0 (usosnvme's exit): the read works again
  W    INT 13h write of the LBA 1 copy to LBA 4 (FUA after the re-arm); the
       host compares LBA 4 with LBA 1 after the run
  then APM 5300h/5301h/5307h in real mode -> QEMU guest shutdown.

One raw disk on -device nvme (MBR, stage 2 in LBA 1-2, FAT16 ESP with
EFI/BOOT/BOOTX64.EFI = the CSMWrap under test, csmwrap.ini serial + verbose),
OVMF without CSM, TCG, 2 vCPUs. PASS per machine = all four markers on the
debug console, no failure marker, guest shutdown, serial "USOS NVME: re-arm"
and "USOS NVME: re-armed", LBA 4 = LBA 1. --expect-old: the usos8 control
(the R2 read must FAIL, which is the X470 98 SE bug).

  python tools/tests/csmwrap/run_csmwrap_nvme_rearm_qemu.py --out DIR [--csmwrap-efi EFI]
      [--machine pc --machine q35] [--root CHECKOUT] [--expect-old]

USOS_QEMU_EXE selects a renamed QEMU copy (only this run's PID is killed).
Disposable images only; no physical disk access.
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT / 'tools/tests/legacy_bios'))
from run_csmwrap_xp_ovmf import build_fat16, ESP_SECTORS  # noqa: E402

SECTOR = 512
MARKERS = ('NVRA-S', 'NVRA-R1', 'NVRA-REF', 'NVRA-R2', 'NVRA-W')


def assemble(zig: Path, tmp: Path) -> bytes:
    obj, binf = tmp / 'nvme_rearm_mbr.o', tmp / 'nvme_rearm_mbr.bin'
    subprocess.run([str(zig), 'cc', '-target', 'x86-freestanding-none', '-c', str(HERE / 'nvme_rearm_mbr.S'),
                    '-o', str(obj)], check=True)
    subprocess.run([str(zig), 'ld.lld', '-m', 'elf_i386', '--oformat=binary', '--image-base=0', '-Ttext=0x7c00',
                    '-e', '_start', str(obj), '-o', str(binf)], check=True)
    code = binf.read_bytes()
    assert len(code) == 0x600, len(code)
    assert not any(code[446:510]), 'code runs into the partition table'
    return code


def make_disk(path: Path, code: bytes, efi: bytes) -> bytes:
    img = bytearray(code)
    mbr = img  # sector 0 (partition table, signature)
    mbr[446:462] = (b'\x00\xfe\xff\xff\xef\xfe\xff\xff' + (2048).to_bytes(4, 'little')
                    + ESP_SECTORS.to_bytes(4, 'little'))
    mbr[510:512] = b'\x55\xaa'
    sig = bytearray(SECTOR)
    sig[504:508] = b'NVRA'
    ini = 'serial = true\r\nserial_port = 0x3f8\r\nverbose = true\r\n'
    with open(path, 'wb') as f:
        f.truncate((2048 + ESP_SECTORS + 2048) * SECTOR)
        f.write(img)
        f.seek(2048 * SECTOR)
        f.write(build_fat16({'EFI/BOOT/BOOTX64.EFI': efi, 'EFI/BOOT/CSMWRAP.INI': ini.encode()}, 2048))
    return bytes(img[SECTOR:2 * SECTOR])


def run(root: Path, code: bytes, efi: bytes, machine: str, out: Path, minutes: float, expect_old: bool) -> bool:
    out.mkdir(parents=True, exist_ok=True)
    for f in ('debugcon.log', 'serial.log'):
        (out / f).unlink(missing_ok=True)
    disk, vars_fd = out / 'disk.img', out / 'vars.fd'
    lba1 = make_disk(disk, code, efi)
    vars_fd.write_bytes((root / 'tools/qemu/share/edk2-i386-vars.fd').read_bytes())
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        port = s.getsockname()[1]
    qemu = root / 'tools/qemu' / os.environ.get('USOS_QEMU_EXE', 'qemu-system-x86_64.exe')
    cmd = [str(qemu), '-name', f'USOS-nvme-rearm-{machine}', '-machine', machine, '-accel', 'tcg', '-cpu', 'max',
           '-smp', '2', '-m', '512', '-display', 'none', '-vga', 'std', '-nic', 'none',
           '-drive', f'if=pflash,format=raw,readonly=on,file={(root / "tools/qemu/share/edk2-x86_64-code.fd").as_posix()}',
           '-drive', f'if=pflash,format=raw,file={vars_fd.as_posix()}',
           '-debugcon', f'file:{(out / "debugcon.log").as_posix()}', '-global', 'isa-debugcon.iobase=0x402',
           '-serial', f'file:{(out / "serial.log").as_posix()}', '-monitor', 'none',
           '-qmp', f'tcp:127.0.0.1:{port},server=on,wait=off',
           '-drive', f'if=none,id=d0,format=raw,file={disk.as_posix()}',
           '-device', 'nvme,serial=USOSNVRA,drive=d0,bootindex=0']
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=open(out / 'qemu-stderr.log', 'wb'))
    events: list[str] = []
    try:
        time.sleep(1.5)
        q = socket.create_connection(('127.0.0.1', port), timeout=5)
        q.settimeout(2)
        q.sendall(b'{"execute": "qmp_capabilities"}\n')
        buf, deadline = b'', time.time() + minutes * 60
        while time.time() < deadline and proc.poll() is None:
            try:
                chunk = q.recv(65536)
            except socket.timeout:
                chunk = b''
            except OSError:
                break
            buf += chunk
            while b'\n' in buf:
                line, buf = buf.split(b'\n', 1)
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                if 'event' in msg:
                    events.append(f"{msg['event']}:{msg.get('data', {}).get('reason', '')}")
            if any(e.startswith(('SHUTDOWN', 'RESET')) for e in events):
                break
    finally:
        try:
            proc.wait(20)
        except subprocess.TimeoutExpired:
            proc.kill()  # our own PID only
            proc.wait()
    dbg = (out / 'debugcon.log').read_bytes().decode('latin-1') if (out / 'debugcon.log').exists() else ''
    ser = (out / 'serial.log').read_bytes().decode('latin-1') if (out / 'serial.log').exists() else ''
    nv = [l.strip() for l in ser.splitlines() if 'USOS NVME' in l]
    off = 'SHUTDOWN:guest-shutdown' in events and not any(e.startswith('RESET') for e in events)
    with open(disk, 'rb') as f:
        f.seek(4 * SECTOR)
        lba4 = f.read(SECTOR)
    marks = [m for m in MARKERS if f' {m} ' in dbg]
    if expect_old:
        # usos8: the re-armed read must fail (step 8) and nothing re-arms.
        ok = off and marks == ['NVRA-S', 'NVRA-R1', 'NVRA-REF'] and 'NVRA-F8' in dbg and not nv
    else:
        ok = (off and marks == list(MARKERS) and 'NVRA-F' not in dbg and 'NVRA-RET' not in dbg
              and any('re-arm (cc' in l for l in nv) and any(l.endswith('re-armed') for l in nv)
              and any('other queues' in l for l in nv) and lba4 == lba1)
    print(f'[{machine}] {"PASS" if ok else "FAIL"} events={events} debugcon={dbg.strip()[-90:]!r} '
          f'lba4=lba1:{lba4 == lba1}', flush=True)
    for l in nv:
        print(f'    {l}', flush=True)
    for f in (disk, vars_fd):
        f.unlink(missing_ok=True)
    return ok


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--root', type=Path, default=ROOT)
    p.add_argument('--csmwrap-efi', type=Path, default=ROOT / 'tools/vendor/csmwrap/3.1.2-usos10/csmwrapx64.efi')
    p.add_argument('--machine', action='append', choices=('pc', 'q35'))
    p.add_argument('--minutes', type=float, default=4)
    p.add_argument('--expect-old', action='store_true', help='control run with usos8 or older: the R2 read fails')
    a = p.parse_args()
    root = a.root.resolve()
    out = a.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    code = assemble(root / 'tools/zig/zig.exe', out)
    efi = a.csmwrap_efi.read_bytes()
    ok = True
    for machine in a.machine or ['pc', 'q35']:
        ok &= run(root, code, efi, machine, out / machine, a.minutes, a.expect_old)
    print('NVME-REARM-QEMU-' + ('PASS' if ok else 'FAIL'), flush=True)
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
