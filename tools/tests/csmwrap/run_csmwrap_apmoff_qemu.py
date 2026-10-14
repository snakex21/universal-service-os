"""QEMU test for CSMWrap 3.1.2-usos7 patch 0008 (APM power-off).

One small raw disk, OVMF without CSM, TCG, 2 vCPUs (CSMWrap's helper core):
MBR = apmoff_mbr.S (assembled here with zig cc + ld.lld), partition 1 = FAT16
ESP with EFI/BOOT/BOOTX64.EFI = the CSMWrap under test and csmwrap.ini
verbose + serial = true. SeaBIOS boots that disk; the MBR asks for APM
power-off (5307h, BX=0001h, CX=0003h) through

  real   INT 15h in real mode (DOS, Windows 3.x, the USOS BIOS menu)
  pm32   the 32-bit protected-mode interface (5303h) with paging on, the
         way Windows 9x VPOWERD calls it
  pm16   the 16-bit protected-mode interface (5302h)

PASS per run = QEMU reports a guest SHUTDOWN (QMP event, reason
guest-shutdown; a reset does not count), the MBR never prints "APMT-RET"
(the call returned), and the serial log has the expected "USOS APMOFF:"
path line: real -> path=uefi from=1, pm32 -> path=uefi from=3 (UEFI
ResetSystem on the helper core), pm16 -> path=s5 from=2 (the direct S5
write with SLP_TYP from QEMU's \\_S5 = 0). --machine pc and q35.

  python tools/tests/csmwrap/run_csmwrap_apmoff_qemu.py --out DIR [--csmwrap-efi EFI]
      [--mode real --mode pm32 ...] [--machine pc --machine q35] [--root CHECKOUT]

--root: the checkout with tools/qemu and tools/zig (a worktree has neither).
USOS_QEMU_EXE selects a renamed QEMU copy (only this run's PIDs are killed).
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
MODES = {'real': 0, 'pm32': 1, 'pm16': 2}
EXPECT = {'real': 'path=uefi from=1', 'pm32': 'path=uefi from=3', 'pm16': 'path=s5 from=2'}


def assemble(zig: Path, tmp: Path) -> bytes:
    obj, binf = tmp / 'apmoff_mbr.o', tmp / 'apmoff_mbr.bin'
    subprocess.run([str(zig), 'cc', '-target', 'x86-freestanding-none', '-c', str(HERE / 'apmoff_mbr.S'), '-o', str(obj)],
                   check=True)
    subprocess.run([str(zig), 'ld.lld', '-m', 'elf_i386', '--oformat=binary', '--image-base=0', '-Ttext=0x7c00',
                    '-e', '_start', str(obj), '-o', str(binf)], check=True)
    code = binf.read_bytes()
    assert len(code) == 0x1EF, len(code)
    assert not any(code[446:0x1EE]), 'boot code runs into the partition table'
    return code


def make_disk(path: Path, code: bytes, mode: int, efi: bytes):
    mbr = bytearray(SECTOR)
    mbr[:len(code)] = code
    mbr[446:462] = (b'\x00\xfe\xff\xff\xef\xfe\xff\xff' + (2048).to_bytes(4, 'little')
                    + ESP_SECTORS.to_bytes(4, 'little'))
    mbr[0x1EE] = mode
    mbr[510:512] = b'\x55\xaa'
    ini = 'serial = true\r\nserial_port = 0x3f8\r\nverbose = true\r\n'
    with open(path, 'wb') as f:
        f.truncate((2048 + ESP_SECTORS + 2048) * SECTOR)
        f.write(mbr)
        f.seek(2048 * SECTOR)
        f.write(build_fat16({'EFI/BOOT/BOOTX64.EFI': efi, 'EFI/BOOT/CSMWRAP.INI': ini.encode()}, 2048))


def run(root: Path, code: bytes, efi: bytes, mode: str, machine: str, out: Path, minutes: float) -> bool:
    out.mkdir(parents=True, exist_ok=True)
    for f in ('debugcon.log', 'serial.log'):
        (out / f).unlink(missing_ok=True)
    disk, vars_fd = out / 'disk.img', out / 'vars.fd'
    make_disk(disk, code, MODES[mode], efi)
    vars_fd.write_bytes((root / 'tools/qemu/share/edk2-i386-vars.fd').read_bytes())
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        port = s.getsockname()[1]
    qemu = root / 'tools/qemu' / os.environ.get('USOS_QEMU_EXE', 'qemu-system-x86_64.exe')
    cmd = [str(qemu), '-name', f'USOS-apmoff-{mode}-{machine}', '-machine', machine, '-accel', 'tcg', '-cpu', 'max',
           '-smp', '2', '-m', '512', '-display', 'none', '-vga', 'std',
           '-drive', f'if=pflash,format=raw,readonly=on,file={(root / "tools/qemu/share/edk2-x86_64-code.fd").as_posix()}',
           '-drive', f'if=pflash,format=raw,file={vars_fd.as_posix()}',
           '-debugcon', f'file:{(out / "debugcon.log").as_posix()}', '-global', 'isa-debugcon.iobase=0x402',
           '-serial', f'file:{(out / "serial.log").as_posix()}', '-monitor', 'none',
           '-qmp', f'tcp:127.0.0.1:{port},server=on,wait=off',
           '-drive', f'if=none,id=d0,format=raw,file={disk.as_posix()}',
           '-device', 'ahci,id=sata', '-device', 'ide-hd,bus=sata.0,drive=d0']
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=open(out / 'qemu-stderr.log', 'wb'))
    events: list[str] = []
    try:
        time.sleep(1.5)
        q = socket.create_connection(('127.0.0.1', port), timeout=5)
        q.settimeout(2)
        q.sendall(b'{"execute":"qmp_capabilities"}\n')
        buf, deadline = b'', time.time() + minutes * 60
        while time.time() < deadline and proc.poll() is None:
            try:
                chunk = q.recv(65536)
            except socket.timeout:
                continue
            if not chunk:
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
    lines = [l.strip() for l in ser.splitlines() if 'USOS APMOFF' in l]
    off = any(e == 'SHUTDOWN:guest-shutdown' for e in events) and not any(e.startswith('RESET') for e in events)
    ok = off and 'APMT-S' in dbg and 'APMT-RET' not in dbg and 'APMT-NO' not in dbg and any(EXPECT[mode] in l for l in lines)
    print(f'[{mode}/{machine}] {"PASS" if ok else "FAIL"} events={events} debugcon={dbg.strip()[-60:]!r}', flush=True)
    for l in lines:
        print(f'    {l}', flush=True)
    for f in (disk, vars_fd):
        f.unlink(missing_ok=True)
    return ok


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--root', type=Path, default=ROOT)
    p.add_argument('--csmwrap-efi', type=Path, default=ROOT / 'tools/vendor/csmwrap/3.1.2-usos7/csmwrapx64.efi')
    p.add_argument('--mode', action='append', choices=sorted(MODES))
    p.add_argument('--machine', action='append', choices=('pc', 'q35'))
    p.add_argument('--minutes', type=float, default=4)
    a = p.parse_args()
    root = a.root.resolve()
    out = a.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    code = assemble(root / 'tools/zig/zig.exe', out)
    efi = a.csmwrap_efi.read_bytes()
    ok = True
    for machine in a.machine or ['pc', 'q35']:
        for mode in a.mode or ['real', 'pm32', 'pm16']:
            ok &= run(root, code, efi, mode, machine, out / f'{mode}-{machine}', a.minutes)
    print('APMOFF-QEMU-' + ('PASS' if ok else 'FAIL'), flush=True)
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
