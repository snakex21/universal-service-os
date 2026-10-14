"""QEMU smoke test for CSMWrap 3.1.2-usos6 patches 0006 (ACPI 1.0 view) and
0007 (ACPI mode enabled before the legacy boot, with --legacy-fadt).

Boots an already prepared Windows 2000/XP CSMWrap target (its MBR partition
with $WIN_NT$.~BT or an installed system, plus the CSMWrap ESP) on OVMF
without CSM, through a disposable qcow2 overlay (the target is never
written). On the overlay's ESP:
  \\EFI\\BOOT\\BOOTX64.EFI = acpi10_break.zig (with --break): zeroes the RSDP's
      RsdtAddress and the FADT 32-bit fields that have an X_ twin, then
      starts CSMWRAP.EFI; without --break, CSMWrap itself
  \\EFI\\BOOT\\CSMWRAP.EFI = the CSMWrap under test, csmwrap.ini verbose+serial
PASS = the serial log has CSMWrap's "USOS ACPI10" lines (when --break: the
RSDT was built and the FADT copy made) and the guest reaches the NT kernel's
own text-mode screen (Setup copying files / the GUI-mode boot screen); with
--legacy-fadt also CSMWrap's "USOS ACPIEN: status" line, without it no
"USOS ACPIEN" line at all (the option-off flows keep the usos5 path).
--expect-logon: an installed system, PASS = no bugcheck until the time is up
(look at final.ppm for the logon screen).

  python tools/tests/csmwrap/run_csmwrap_acpi10_qemu.py --target T.qcow2 --csmwrap csmwrapx64.efi --out DIR [--break] [--minutes 8]

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
import warnings
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
MAIN = Path(os.environ.get('USOS_MAIN_CHECKOUT', ROOT.parents[1] / 'Desktop/usos-x470-98se'))


def tool(name: str) -> Path:
    for base in (ROOT, MAIN):
        p = base / 'tools/qemu' / name
        if p.exists():
            return p
    raise SystemExit(f'{name} not found')


QEMU = tool(os.environ.get('USOS_QEMU_EXE', 'qemu-system-x86_64.exe'))
QEMU_IMG = tool('qemu-img.exe')
OVMF_CODE = tool('share/edk2-x86_64-code.fd')
OVMF_VARS = tool('share/edk2-i386-vars.fd')
KERNEL_SCREENS = ('copying files', 'kopiuje pliki', 'instalator systemu windows', 'windows 2000 setup', 'windows setup',
                  'instalator kopiuje', 'please wait while setup', 'czekaj')


def run(cmd, **kw):
    return subprocess.run([str(c) for c in cmd], check=True, capture_output=True, **kw)


def build_breaker(out: Path) -> Path:
    zig = None
    for base in (ROOT, MAIN):
        if (base / 'tools/zig/zig.exe').exists():
            zig = base / 'tools/zig/zig.exe'
            break
    efi = out / 'acpi10-break.efi'
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(out / 'zig-cache'))
    run([zig, 'build-exe', '-target', 'x86_64-uefi', '-O', 'ReleaseSmall',
         '-Mroot=' + str(Path(__file__).with_name('acpi10_break.zig')), '-femit-bin=' + str(efi),
         '--cache-dir', str(out / 'zig-cache-local')], env=env)
    return efi


def esp_location(overlay: Path, out: Path) -> tuple[int, int]:
    mbr = out / 'mbr.bin'
    run([QEMU_IMG, 'dd', '-f', 'qcow2', '-O', 'raw', 'bs=512', 'count=1', f'if={overlay}', f'of={mbr}'])
    data = mbr.read_bytes()
    for i in range(4):
        e = data[446 + 16 * i: 462 + 16 * i]
        if e[4] == 0xEF:
            return int.from_bytes(e[8:12], 'little'), int.from_bytes(e[12:16], 'little')
    raise SystemExit('no ESP (type EF) in the target MBR')


def patch_esp(overlay: Path, out: Path, boot: bytes, csmwrap: bytes, ini_extra: str = '') -> None:
    start, count = esp_location(overlay, out)
    esp = out / 'esp.raw'
    esp.unlink(missing_ok=True)
    # qemu-img dd counts the skipped blocks in count
    run([QEMU_IMG, 'dd', '-f', 'qcow2', '-O', 'raw', 'bs=512', f'skip={start}', f'count={start + count}', f'if={overlay}', f'of={esp}'])
    with warnings.catch_warnings():
        warnings.simplefilter('ignore')
        from pyfatfs.PyFatFS import PyFatFS
    fs = PyFatFS(str(esp))
    try:
        for name, blob in (('/EFI/BOOT/BOOTX64.EFI', boot), ('/EFI/BOOT/CSMWRAP.EFI', csmwrap),
                           ('/EFI/BOOT/csmwrap.ini', b'verbose = true\r\nserial = true\r\n' + ini_extra.encode())):
            folder, leaf = name.rsplit('/', 1)
            for old in fs.listdir(folder):  # FAT names are case-insensitive, pyfatfs is not
                if old.lower() == leaf.lower():
                    fs.remove(folder + '/' + old)
            with fs.openbin(name, 'w') as f:
                f.write(blob)
    finally:
        fs.close()
    # Back into the overlay through a raw window on the partition (qemu-io's
    # write -s reads its file in text mode on Windows).
    run([QEMU_IMG, 'convert', '-n', '-f', 'raw', str(esp), '--target-image-opts',
         f'driver=raw,offset={start * 512},size={count * 512},file.driver=qcow2,file.file.filename={overlay.as_posix()}'])
    esp.unlink()


class Monitor:
    def __init__(self, port: int):
        for _ in range(50):
            try:
                self.s = socket.create_connection(('127.0.0.1', port), timeout=5)
                break
            except OSError:
                time.sleep(0.2)
        self.read()

    def read(self) -> str:
        data = b''
        self.s.settimeout(0.5)
        try:
            while not data.endswith(b'(qemu) '):
                chunk = self.s.recv(65536)
                if not chunk:
                    break
                data += chunk
        except OSError:
            pass
        return data.decode(errors='replace')

    def cmd(self, line: str) -> str:
        self.s.sendall(line.encode() + b'\n')
        return self.read()


def vga_text(dump: Path) -> str:
    b = dump.read_bytes()
    rows = []
    for r in range(len(b) // 160):
        rows.append(''.join(chr(c) if 32 <= c < 127 else ' ' for c in b[r * 160:(r + 1) * 160:2]).rstrip())
    return '\n'.join(rows)


def blue_screen(ppm: Path) -> bool:
    """More than half of the pixels NT-bugcheck blue (binary P6 screendump)."""
    data = ppm.read_bytes()
    parts = data.split(b'\n', 3)
    if len(parts) < 4 or parts[0] != b'P6':
        return False
    px = parts[3]
    n = len(px) // 3
    step = max(1, n // 4000)
    hits = sum(1 for i in range(0, n, step) if px[3 * i + 2] > 100 and px[3 * i] < 60 and px[3 * i + 1] < 60)
    return hits * step * 2 > n


def boot(out: Path, overlay: Path, minutes: float, accel: str, machine: str = 'pc') -> dict:
    vars_copy = out / 'vars.fd'
    shutil.copyfile(OVMF_VARS, vars_copy)
    serial = out / 'serial.log'
    serial.unlink(missing_ok=True)
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        port = s.getsockname()[1]
    cmd = [QEMU, '-machine', machine, '-accel', accel, '-cpu', 'max', '-m', '1024', '-smp', '2',
           '-drive', f'if=pflash,unit=0,format=raw,readonly=on,file={OVMF_CODE}',
           '-drive', f'if=pflash,unit=1,format=raw,file={vars_copy}',
           '-display', 'none', '-nic', 'none', '-serial', f'file:{serial}',
           '-monitor', f'tcp:127.0.0.1:{port},server=on,wait=off',
           '-drive', f'if=ide,index=0,format=qcow2,file={overlay}', '-vga', 'std'] + os.environ.get('USOS_QEMU_EXTRA', '').split()  # e.g. -global q35-pcihost.pci-hole64-size=0
    proc = subprocess.Popen([str(c) for c in cmd], stdout=subprocess.DEVNULL, stderr=open(out / 'qemu-stderr.log', 'wb'))
    result, screens, last = 'timeout', [], None
    start = time.time()
    try:
        time.sleep(1)
        mon = Monitor(port)
        frame, last_shot = 0, 0.0
        while time.time() - start < minutes * 60 and proc.poll() is None:
            if time.time() - last_shot >= 2.0 and frame < 400:
                last_shot = time.time()
                frame += 1
                shot = out / f"frame-{frame:03d}.ppm"
                mon.cmd(f'screendump "{shot.as_posix()}"')
                time.sleep(0.3)
                if shot.exists() and blue_screen(shot):
                    # The NT kernel's own bugcheck screen (graphics mode, so
                    # not in B8000h): the HAL got through phase 0.
                    result = 'kernel-bsod'
                    shutil.copyfile(shot, out / 'final.ppm')
                    break
            dump = out / 'cur.bin'
            dump.unlink(missing_ok=True)
            mon.cmd(f'pmemsave 0xb8000 8000 "{dump.as_posix()}"')
            for _ in range(20):
                if dump.exists() and dump.stat().st_size == 8000:
                    break
                time.sleep(0.05)
            text = vga_text(dump) if dump.exists() else ''
            if text.strip() and text != last and any(c.isalpha() for c in text):
                last = text
                n = len(screens) + 1
                (out / f'text-{n:03d}.txt').write_text(text, encoding='utf-8')
                mon.cmd(f'screendump "{(out / f"text-{n:03d}.ppm").as_posix()}"')
                screens.append({'t': round(time.time() - start, 1), 'text': text.strip()[:300]})
                print(f'--- screen {n} at {screens[-1]["t"]}s ---\n{text.strip()[:300]}\n', flush=True)
                if any(k in text.lower() for k in KERNEL_SCREENS):
                    result = 'kernel-screen'
                    time.sleep(3)
                    mon.cmd(f'screendump "{(out / "final.ppm").as_posix()}"')
                    break
            time.sleep(0.5)
        else:
            try:
                mon.cmd(f'screendump "{(out / "final.ppm").as_posix()}"')
            except Exception:
                pass
    finally:
        try:
            mon.cmd('quit')
        except Exception:
            pass
        try:
            proc.wait(15)
        except Exception:
            proc.kill()
    log = serial.read_text(errors='replace') if serial.exists() else ''
    return {'result': result, 'screens': len(screens), 'serial_acpi10': [l for l in log.splitlines() if 'ACPI10' in l],
            'serial_acpien': [l for l in log.splitlines() if 'ACPIEN' in l]}


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument('--target', type=Path, required=True, help='prepared CSMWrap target qcow2 (read only, used as backing file)')
    p.add_argument('--csmwrap', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--break', dest='brk', action='store_true', help='zero RsdtAddress and FADT 32-bit fields first')
    p.add_argument('--minutes', type=float, default=8)
    p.add_argument('--legacy-fadt', action='store_true', help='csmwrap.ini acpi_legacy_fadt = true (the Windows 2000 flow)')
    p.add_argument('--accel', default='tcg,thread=multi')
    p.add_argument('--expect-logon', action='store_true', help='installed target: PASS = no bugcheck until --minutes are up')
    p.add_argument('--machine', default='pc', help='q35: FADT revision 3+ (longer than the 0x84 bytes the Windows 2000 ACPI HALs copy)')
    a = p.parse_args()
    out = a.out.resolve()
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    overlay = out / 'overlay.qcow2'
    run([QEMU_IMG, 'create', '-f', 'qcow2', '-F', 'qcow2', '-b', str(a.target.resolve()), str(overlay)])
    csmwrap = a.csmwrap.read_bytes()
    boot_efi = build_breaker(out).read_bytes() if a.brk else csmwrap
    patch_esp(overlay, out, boot_efi, csmwrap, 'acpi_legacy_fadt = true\r\n' if a.legacy_fadt else '')
    summary = boot(out, overlay, a.minutes, a.accel, a.machine)
    lines = summary['serial_acpi10']
    reached = ('timeout',) if a.expect_logon else ('kernel-screen', 'kernel-bsod')
    ok = summary['result'] in reached and any('USOS ACPI10' in l for l in lines)
    en = summary['serial_acpien']
    ok = ok and (any('USOS ACPIEN: status' in l for l in en) if a.legacy_fadt else not en)
    if a.brk:
        ok = ok and any('built RSDT' in l for l in lines) and any('ACPI10-BREAK RSDP' in l for l in lines)
    summary['pass'] = ok
    (out / 'summary.json').write_text(json.dumps(summary, indent=1), encoding='utf-8')
    print(json.dumps(summary, indent=1))
    overlay.unlink(missing_ok=True)
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
