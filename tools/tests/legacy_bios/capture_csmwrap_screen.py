"""Screenshot of the CSMWrap phase itself (before SeaBIOS takes the screen):
boots the prepared XP disk plus a CSMWrap ESP (as run_csmwrap_xp_ovmf.py) on
OVMF without CSM, watches the serial port for CSMWrap's 'Unlock!' line and
pauses the VM there for a screendump. With the upstream binary the logo is
on screen at that point; with 3.1.2-usos1 and verbose = false it is not.

  python tools/tests/legacy_bios/capture_csmwrap_screen.py --output zig-out/csmwrap-shot \
      --prepared zig-out/xp-uefi-textmode-en-v5/target.qcow2 [--csmwrap-efi X.efi] [--verbose true|false]

Disposable images only; no physical disk access.
"""
from pathlib import Path
import argparse, json, shutil, socket, subprocess, sys, time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_csmwrap_xp_ovmf import QEMU, OVMF_CODE, OVMF_VARS, make_overlay, to_png  # noqa: E402
from run_seabios_xp_uefi_csm_textmode import Monitor, free_port  # noqa: E402


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--prepared', type=Path, required=True)
    p.add_argument('--csmwrap-efi', type=Path)
    p.add_argument('--verbose', choices=('true', 'false'), default='true')
    p.add_argument('--accel', default='tcg,thread=multi')
    p.add_argument('--timeout', type=float, default=120)
    a = p.parse_args()
    out = a.output.resolve()
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    disk = out / 'after.qcow2'
    # serial = true so CSMWrap reports progress ('Unlock!') on COM1 whatever verbose says
    make_overlay(a.prepared, disk, esp=True, ini=f'serial = true\nserial_port = 0x3f8\nverbose = {a.verbose}\n',
                 efi_path=a.csmwrap_efi)
    vars_copy = out / 'vars.fd'
    shutil.copyfile(OVMF_VARS, vars_copy)
    mport, sport = free_port(), free_port()
    cmd = [QEMU, '-machine', 'pc', '-accel', a.accel, '-cpu', 'max', '-m', '1024', '-smp', '2',
           '-drive', f'if=pflash,unit=0,format=raw,readonly=on,file={OVMF_CODE}',
           '-drive', f'if=pflash,unit=1,format=raw,file={vars_copy}',
           '-display', 'none', '-nic', 'none', '-vga', 'std',
           '-serial', f'tcp:127.0.0.1:{sport},server=on,wait=on',
           '-monitor', f'tcp:127.0.0.1:{mport},server=on,wait=off',
           '-drive', f'if=ide,index=0,format=qcow2,file={disk}']
    proc = subprocess.Popen([str(c) for c in cmd], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    result = {'unlock_seen': False}
    try:
        for _ in range(100):
            try:
                ser = socket.create_connection(('127.0.0.1', sport), timeout=5)
                break
            except OSError:
                time.sleep(0.1)
        mon = Monitor(mport)
        ser.settimeout(0.05)
        log = b''
        end = time.time() + a.timeout
        while time.time() < end and b'Unlock!' not in log:
            try:
                log += ser.recv(65536)
            except socket.timeout:
                pass
        if b'Unlock!' in log:
            mon.cmd('stop')
            result['unlock_seen'] = True
            ppm = out / 'csmwrap-phase.ppm'
            mon.cmd(f'screendump "{ppm.as_posix()}"')
            time.sleep(1)
            result['screenshot'] = str(to_png(ppm))
        (out / 'serial-until-unlock.log').write_bytes(log)
        mon.cmd('quit')
    finally:
        try:
            proc.wait(10)
        except Exception:
            proc.kill()
    vars_copy.unlink(missing_ok=True)
    disk.unlink(missing_ok=True)
    print(json.dumps(result))
    return 0 if result['unlock_seen'] else 1


if __name__ == '__main__':
    sys.exit(main())
