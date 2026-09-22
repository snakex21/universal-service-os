"""Boot the exact production Core, retaining serial diagnostics and UI input."""
import argparse
import socket
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    out = parser.parse_args().output.resolve()
    out.mkdir(exist_ok=False)
    raw = out / 'usos.raw'
    subprocess.run([str(ROOT / 'tools/qemu/qemu-img.exe'), 'convert', '-O', 'raw',
                    str(ROOT / 'zig-out/repair-bios-20260909/vbox-staging/fixture/xp-menu-usos.qcow2'), str(raw)], check=True)
    with raw.open('r+b') as handle:
        handle.write((ROOT / 'zig-out/legacy-bios/stage1.bin').read_bytes())
        handle.seek(64 * 512)
        handle.write((ROOT / 'zig-out/legacy-bios/core-slot.bin').read_bytes())
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
    def hmp(command):
        with socket.create_connection(('127.0.0.1', port)) as sock:
            sock.sendall((command + '\n').encode())
            time.sleep(.3)
    serial = out / 'serial.log'
    with (out / 'qemu.log').open('w') as log:
        proc = subprocess.Popen([str(ROOT / 'tools/qemu/qemu-system-x86_64.exe'), '-machine', 'pc',
                                 '-m', '512', '-display', 'none', '-nic', 'none', '-vga', 'std',
                                 '-drive', 'format=raw,file=' + str(raw), '-serial', 'file:' + str(serial),
                                 '-monitor', f'tcp:127.0.0.1:{port},server=on,wait=off'],
                                stdout=log, stderr=log, creationflags=0x08000000)
        def wait_for(marker):
            end = time.monotonic() + 60
            while time.monotonic() < end:
                if serial.exists() and marker in serial.read_text(errors='replace'):
                    return
                if proc.poll() is not None: break
                time.sleep(.2)
            raise AssertionError('Boot did not reach ' + marker)
        try:
            wait_for('VESA-2 MENU ACTIVE')
            hmp('screendump ' + str(out / 'menu.ppm').replace('\\', '/'))
            hmp('pmemsave 0xb8000 4000 ' + str(out / 'vga.bin').replace('\\', '/'))
            vga = (out / 'vga.bin').read_bytes()[::2]
            diagnostic = serial.read_text(errors='replace')
            for marker in ['USOS LEGACY BOOTSTRAP', 'CORE HEADER OK', 'CORE LOAD OK', 'CORE CRC OK', 'USOS LEGACY CORE PM32', 'GPT OK']:
                assert marker in diagnostic, marker + ' missing from serial'
                assert marker.encode() not in vga, marker + ' leaked to screen'
            hmp('sendkey d')
            wait_for('USOS LEGACY BIOS DIAGNOSTICS')
            hmp('sendkey esc')
            wait_for('VESA-2 GRAPHICS RESTORED')
            print('[PASS] Production BIOS boot: quiet screen, serial evidence, menu and diagnostics work')
        finally:
            if proc.poll() is None:
                hmp('quit'); proc.wait(timeout=15)


if __name__ == '__main__':
    main()
