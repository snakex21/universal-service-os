"""QEMU test for CSMWrap 3.1.2-usos8 patches 0008 + 0009 (APM power-off).

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
path line. usos8 (patch 0009) goes ACPI mode -> S5 first on every path:
real -> path=s5 from=1, pm32 -> path=s5 from=3, pm16 -> path=s5 from=2 (the
direct S5 write with SLP_TYP from QEMU's \\_S5 = 0), and no "path=uefi"
line (the helper-core ResetSystem runs only when S5 left the machine on).
--expect-usos7 checks the usos7 order (real/pm32 -> path=uefi first).
--machine pc and q35.

--cmos-check (usos8): the guest is kept after the power-off (-no-shutdown),
the APM test disk (a USB stick) is unplugged, the machine reset, and OVMF
boots the second disk: a FAT ESP with the USOS UEFI menu (--usos-esp DIR,
default zig-out/usb). The menu must read the CMOS breadcrumbs (serial
"[APM_OFF]") and write EFI/USOS/Logs/apm-off.txt with 01h = A6h (S5
written) and one 5307h call from the tested path.

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
import shutil
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
EXPECT = {'real': 'path=s5 from=1', 'pm32': 'path=s5 from=3', 'pm16': 'path=s5 from=2'}
EXPECT_USOS7 = {'real': 'path=uefi from=1', 'pm32': 'path=uefi from=3', 'pm16': 'path=s5 from=2'}


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


PATH_CODE = {'real': 1, 'pm16': 2, 'pm32': 3}


def qmp_cmd(q: socket.socket, command: str, **arguments) -> None:
    msg = {'execute': command}
    if arguments:
        msg['arguments'] = arguments
    q.sendall(json.dumps(msg).encode() + b'\n')


def run(root: Path, code: bytes, efi: bytes, mode: str, machine: str, out: Path, minutes: float, expect=EXPECT,
        usos_esp: Path | None = None) -> bool:
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
           '-device', 'ahci,id=sata', '-device', 'ide-hd,bus=sata.0,drive=d0' + (',bootindex=0' if usos_esp else '')]
    esp_copy = None
    if usos_esp:
        # Phase 2 disk: a copy of the USOS stick's EFI folder as a vvfat ESP.
        esp_copy = out / 'usos-esp'
        shutil.rmtree(esp_copy, ignore_errors=True)
        shutil.copytree(usos_esp / 'EFI', esp_copy / 'EFI')
        (esp_copy / 'EFI/USOS/Logs/apm-off.txt').unlink(missing_ok=True)
        cmd += ['-no-shutdown', '-nic', 'none',
                '-drive', f'if=none,id=d1,format=raw,file=fat:rw:{esp_copy.as_posix()}',
                '-device', 'ide-hd,bus=sata.1,drive=d1,bootindex=1']
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=open(out / 'qemu-stderr.log', 'wb'))
    events: list[str] = []
    phase2 = False
    crumbs_seen = False
    try:
        time.sleep(1.5)
        q = socket.create_connection(('127.0.0.1', port), timeout=5)
        q.settimeout(2)
        qmp_cmd(q, 'qmp_capabilities')
        buf, deadline = b'', time.time() + minutes * 60
        while time.time() < deadline and proc.poll() is None:
            try:
                chunk = q.recv(65536)
            except socket.timeout:
                chunk = b''
            buf += chunk
            while b'\n' in buf:
                line, buf = buf.split(b'\n', 1)
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                if 'event' in msg:
                    events.append(f"{msg['event']}:{msg.get('data', {}).get('reason', '')}")
            if not phase2 and any(e.startswith(('SHUTDOWN', 'RESET')) for e in events):
                if not usos_esp or not any(e == 'SHUTDOWN:guest-shutdown' for e in events):
                    break
                # The guest is stopped (-no-shutdown). Hide the APM disk's
                # partition table, reset: OVMF boots the USOS ESP, and the
                # menu must find the CMOS record CSMWrap left.
                phase2 = True
                qmp_cmd(q, 'human-monitor-command', **{'command-line': 'qemu-io d0 "write -z 0 512"'})
                time.sleep(0.5)
                qmp_cmd(q, 'system_reset')
                time.sleep(0.5)
                qmp_cmd(q, 'cont')
                deadline = time.time() + minutes * 60
            if phase2:
                ser = (out / 'serial.log').read_bytes() if (out / 'serial.log').exists() else b''
                if b'[INPUT_REPORT END]' in ser or b'[APM_OFF] save failed' in ser:
                    crumbs_seen = b'[APM_OFF]' in ser
                    time.sleep(3)  # let the FAT write reach vvfat
                    break
        if phase2:
            try:
                qmp_cmd(q, 'quit')
            except OSError:
                pass
    finally:
        try:
            proc.wait(20)
        except subprocess.TimeoutExpired:
            proc.kill()  # our own PID only
            proc.wait()
    dbg = (out / 'debugcon.log').read_bytes().decode('latin-1') if (out / 'debugcon.log').exists() else ''
    ser = (out / 'serial.log').read_bytes().decode('latin-1') if (out / 'serial.log').exists() else ''
    lines = [l.strip() for l in ser.splitlines() if 'USOS APMOFF' in l]
    if usos_esp:
        first = [e for e in events[:events.index('SHUTDOWN:guest-shutdown') + 1]] if 'SHUTDOWN:guest-shutdown' in events else events
        off = 'SHUTDOWN:guest-shutdown' in first and not any(e.startswith('RESET') for e in first)
    else:
        off = any(e == 'SHUTDOWN:guest-shutdown' for e in events) and not any(e.startswith('RESET') for e in events)
    ok = off and 'APMT-S' in dbg and 'APMT-RET' not in dbg and 'APMT-NO' not in dbg and any(expect[mode] in l for l in lines)
    if expect is EXPECT:
        ok = ok and not any('path=uefi' in l for l in lines)
    print(f'[{mode}/{machine}] {"PASS" if ok else "FAIL"} events={events} debugcon={dbg.strip()[-60:]!r}', flush=True)
    for l in lines:
        print(f'    {l}', flush=True)
    if usos_esp:
        log = esp_copy / 'EFI/USOS/Logs/apm-off.txt'
        text = log.read_text(encoding='latin-1') if log.exists() else ''
        want = [f'CMOS 01h=46 03h={PATH_CODE[mode] * 15 + 1:02d} ', 'last step: 6 = S5 written',
                'calls: 1 (last from ']
        cmos_ok = phase2 and crumbs_seen and all(w in text for w in want)
        print(f'[{mode}/{machine}] CMOS record {"PASS" if cmos_ok else "FAIL"} (apm-off.txt {"present" if text else "missing"})',
              flush=True)
        for l in text.splitlines():
            print(f'    | {l}', flush=True)
        ok = ok and cmos_ok
        shutil.rmtree(esp_copy, ignore_errors=True)
    for f in (disk, vars_fd):
        f.unlink(missing_ok=True)
    return ok


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--root', type=Path, default=ROOT)
    p.add_argument('--csmwrap-efi', type=Path, default=ROOT / 'tools/vendor/csmwrap/3.1.2-usos8/csmwrapx64.efi')
    p.add_argument('--expect-usos7', action='store_true', help='usos7 order: helper ResetSystem first on real/pm32')
    p.add_argument('--mode', action='append', choices=sorted(MODES))
    p.add_argument('--machine', action='append', choices=('pc', 'q35'))
    p.add_argument('--minutes', type=float, default=4)
    p.add_argument('--cmos-check', action='store_true', help='then boot the USOS menu and check apm-off.txt')
    p.add_argument('--usos-esp', type=Path, default=ROOT / 'zig-out/usb', help='USOS stick tree for --cmos-check')
    a = p.parse_args()
    root = a.root.resolve()
    out = a.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    code = assemble(root / 'tools/zig/zig.exe', out)
    efi = a.csmwrap_efi.read_bytes()
    ok = True
    for machine in a.machine or ['pc', 'q35']:
        for mode in a.mode or ['real', 'pm32', 'pm16']:
            ok &= run(root, code, efi, mode, machine, out / f'{mode}-{machine}', a.minutes,
                      EXPECT_USOS7 if a.expect_usos7 else EXPECT, a.usos_esp.resolve() if a.cmos_check else None)
    print('APMOFF-QEMU-' + ('PASS' if ok else 'FAIL'), flush=True)
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
