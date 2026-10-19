"""QEMU protocol test of CSMWrap 3.1.2-usos16 patch 0021 (USB disk service, channel 1 of the
helper core) without Windows: uds_mbr.S drives the channel from real mode the way the Windows 9x
miniport USOSUSB.MPD does from ring 0 (docs/usb9x-hotswap-design-2026-10-19.md, test plan).

Disks: the boot disk on -device nvme (uds_mbr.S in LBA 0-7, FAT16 ESP with EFI/BOOT/BOOTX64.EFI =
the CSMWrap under test, csmwrap.ini serial + verbose), a 64 MiB stick on qemu-xhci usb-storage
(removable=on; LBA 0 starts with "UDSTICK0", LBA 256.. a 64 KiB block starting with "UBIG").
OVMF without CSM, TCG, 2 vCPUs (the helper core). No USB keyboard/mouse (see uds_mbr.S).

  free   csmwrap.ini int13_boot_disk_only = true: the stick has no BIOS number. All markers up to
         UDS-GONE2: ENUM, INQUIRY, READ, WRITE + READ back across 64 KiB boundaries, 64 KiB reads,
         BADREQ, STATUS record, CHECK + sense, then QMP device_del of the stick while 64 KiB reads
         run -> GONE (latency measured on the host), GONE again at once, ENUM state 2. The host
         checks LBA 64-79 of the stick image = the MBR's pattern.
  owned  without the key: the stick is BIOS drive 81h, ENUM reports it and SCSI is refused (OWNED).

  python tools/tests/csmwrap/run_csmwrap_uds_qemu.py --out DIR --csmwrap-efi EFI [--mode free --mode owned]
      [--root CHECKOUT]

--root: the checkout with tools/qemu and tools/zig (a worktree has none: pass the main checkout).
USOS_QEMU_EXE selects a renamed QEMU copy (only this run's PID is ever killed).
Disposable images only (deleted after the run); no physical disk access.
"""
from __future__ import annotations

import argparse
import json
import re
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
sys.path.insert(0, str(REPO / 'tools/tests/legacy_bios'))
from run_csmwrap_xp_ovmf import build_fat16, ESP_SECTORS  # noqa: E402

SECTOR = 512
STICK_SECTORS = 64 * 2048
FREE = ('UDS-S', 'UDS-CH', 'UDS-ENUM', 'UDS-FREE', 'UDS-INQ', 'UDS-R0', 'UDS-W', 'UDS-RB', 'UDS-BIG',
        'UDS-BAD', 'UDS-STAT', 'UDS-SENSE', 'UDS-RESET', 'UDS-UNPLUG?', 'UDS-GONE', 'UDS-GONE2')
OWNED = ('UDS-S', 'UDS-CH', 'UDS-ENUM', 'UDS-OWNED')


def assemble(zig: Path, tmp: Path) -> bytes:
    obj, binf = tmp / 'uds_mbr.o', tmp / 'uds_mbr.bin'
    subprocess.run([str(zig), 'cc', '-target', 'x86-freestanding-none', '-c', str(HERE / 'uds_mbr.S'),
                    '-o', str(obj)], check=True)
    subprocess.run([str(zig), 'ld.lld', '-m', 'elf_i386', '--oformat=binary', '--image-base=0', '-Ttext=0x7c00',
                    '-e', '_start', str(obj), '-o', str(binf)], check=True)
    code = binf.read_bytes()
    assert len(code) == 0x1000, len(code)
    assert not any(code[446:510]), 'code runs into the partition table'
    return code


def pattern() -> bytes:
    """the MBR's write pattern: 5Ah, then +7 per byte (mod 256), 8 KiB"""
    return bytes((0x5A + 7 * i) & 0xFF for i in range(8192))


def big_block() -> bytes:
    data = bytearray(65536)
    for i in range(0, 65536, 4):
        data[i:i + 4] = (i * 2654435761 & 0xFFFFFFFF).to_bytes(4, 'little')
    data[0:4] = b'UBIG'
    return bytes(data)


def make_disks(boot: Path, stick: Path, code: bytes, efi: bytes, only: bool) -> None:
    img = bytearray(code)
    img[446:462] = (b'\x00\xfe\xff\xff\xef\xfe\xff\xff' + (2048).to_bytes(4, 'little')
                    + ESP_SECTORS.to_bytes(4, 'little'))
    img[510:512] = b'\x55\xaa'
    ini = 'serial = true\r\nserial_port = 0x3f8\r\nverbose = true\r\n'
    if only:
        ini += 'int13_boot_disk_only = true\r\n'
    with open(boot, 'wb') as f:
        f.truncate((2048 + ESP_SECTORS + 2048) * SECTOR)
        f.write(img)
        f.seek(2048 * SECTOR)
        f.write(build_fat16({'EFI/BOOT/BOOTX64.EFI': efi, 'EFI/BOOT/CSMWRAP.INI': ini.encode()}, 2048))
    with open(stick, 'wb') as f:
        f.truncate(STICK_SECTORS * SECTOR)
        f.write(b'UDSTICK0' + bytes(SECTOR - 8))
        f.seek(256 * SECTOR)
        f.write(big_block())


def run(root: Path, code: bytes, efi: bytes, mode: str, out: Path, minutes: float) -> bool:
    out.mkdir(parents=True, exist_ok=True)
    for f in ('debugcon.log', 'serial.log'):
        (out / f).unlink(missing_ok=True)
    boot, stick, vars_fd = out / 'boot.img', out / 'stick.img', out / 'vars.fd'
    make_disks(boot, stick, code, efi, mode == 'free')
    vars_fd.write_bytes((root / 'tools/qemu/share/edk2-i386-vars.fd').read_bytes())
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        port = s.getsockname()[1]
    qemu = root / 'tools/qemu' / os.environ.get('USOS_QEMU_EXE', 'qemu-system-x86_64.exe')
    dbg_path = out / 'debugcon.log'
    cmd = [str(qemu), '-name', f'USOS-uds-{mode}', '-machine', 'q35', '-accel', 'tcg', '-cpu', 'max',
           '-smp', '2', '-m', '512', '-display', 'none', '-vga', 'std', '-nic', 'none',
           '-drive', f'if=pflash,format=raw,readonly=on,file={(root / "tools/qemu/share/edk2-x86_64-code.fd").as_posix()}',
           '-drive', f'if=pflash,format=raw,file={vars_fd.as_posix()}',
           '-debugcon', f'file:{dbg_path.as_posix()}', '-global', 'isa-debugcon.iobase=0x402',
           '-serial', f'file:{(out / "serial.log").as_posix()}', '-monitor', 'none',
           '-qmp', f'tcp:127.0.0.1:{port},server=on,wait=off',
           '-drive', f'if=none,id=d0,format=raw,file={boot.as_posix()}',
           '-device', 'nvme,serial=USOSUDS0,drive=d0,bootindex=0',
           '-device', 'qemu-xhci,id=xhci',
           '-drive', f'if=none,id=stick,format=raw,file={stick.as_posix()}',
           '-device', 'usb-storage,bus=xhci.0,drive=stick,removable=on,id=stickdev']
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=open(out / 'qemu-stderr.log', 'wb'))
    events: list[str] = []
    unplug_at = gone_at = None
    try:
        time.sleep(1.5)
        q = socket.create_connection(('127.0.0.1', port), timeout=5)
        q.settimeout(0.05)
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
            dbg = dbg_path.read_bytes() if dbg_path.exists() else b''
            if unplug_at is None and b'UDS-UNPLUG?' in dbg:
                time.sleep(0.5)   # let a few 64 KiB reads run
                try:
                    q.sendall(b'{"execute": "device_del", "arguments": {"id": "stickdev"}}\n')
                except OSError:
                    break
                unplug_at = time.time()
            if unplug_at is not None and gone_at is None and b'UDS-GONE ' in dbg:
                gone_at = time.time()
            if any(e.startswith(('SHUTDOWN', 'RESET')) for e in events):
                break
    finally:
        try:
            proc.wait(20)
        except subprocess.TimeoutExpired:
            proc.kill()  # our own PID only
            proc.wait()
    dbg = dbg_path.read_bytes().decode('latin-1') if dbg_path.exists() else ''
    ser = (out / 'serial.log').read_bytes().decode('latin-1') if (out / 'serial.log').exists() else ''
    uds = [l.strip() for l in ser.splitlines() if 'USOS UDS' in l]
    off = 'SHUTDOWN:guest-shutdown' in events and not any(e.startswith('RESET') for e in events)
    marks = [m for m in (FREE if mode == 'free' else OWNED) if f' {m} ' in dbg]
    failed = re.search(r' UDS-F[^R]', dbg)   # " UDS-F<step> ", not UDS-FREE
    ok = off and not failed and 'UDS-RET' not in dbg and bool(uds)
    latency = None
    if mode == 'free':
        with open(stick, 'rb') as f:
            f.seek(64 * SECTOR)
            written = f.read(8192)
        latency = None if gone_at is None or unplug_at is None else gone_at - unplug_at
        if written != pattern():
            print(f'    stick LBA 64: {written[:16].hex()} (want {pattern()[:16].hex()})', flush=True)
        probed = any(l.endswith('cap 131071 x 512') for l in uds)   # first ENUM probed the stick
        ok = (ok and marks == list(FREE) and written == pattern() and latency is not None and latency < 3.0
              and probed)
    else:
        # a stick INT 13h owns gets no UDS traffic at all (no probe)
        ok = ok and marks == list(OWNED) and not any(' cap ' in l for l in uds)
    print(f'[{mode}] {"PASS" if ok else "FAIL"} events={events} debugcon={dbg.strip()[-160:]!r} '
          f'unplug->gone={latency if latency is None else round(latency, 2)}s', flush=True)
    for l in uds:
        print(f'    {l}', flush=True)
    for f in (boot, stick, vars_fd):
        f.unlink(missing_ok=True)
    return ok


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--root', type=Path, default=REPO)
    p.add_argument('--csmwrap-efi', type=Path, default=REPO / 'tools/vendor/csmwrap/3.1.2-usos16/csmwrapx64.efi')
    p.add_argument('--mode', action='append', choices=('free', 'owned'))
    p.add_argument('--minutes', type=float, default=6)
    a = p.parse_args()
    root = a.root.resolve()
    out = a.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    code = assemble(root / 'tools/zig/zig.exe', out)
    efi = a.csmwrap_efi.read_bytes()
    ok = True
    for mode in a.mode or ['free', 'owned']:
        ok &= run(root, code, efi, mode, out / mode, a.minutes)
    print('UDS-QEMU-' + ('PASS' if ok else 'FAIL'), flush=True)
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
