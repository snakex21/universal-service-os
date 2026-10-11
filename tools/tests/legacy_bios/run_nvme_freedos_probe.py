"""NVMe INT 13h probe for DOS / 9x (docs/nvme-nt-2026-10-11.md): FreeDOS boots
from an NVMe disk through CSMWrap (OVMF without CSM).

One raw disk on `-device nvme` (the only disk):
  MBR      USOS MBR code (zig-out/xp-geometry-fix-mbr), slot 1 FAT16 C:
           (type 06h, active, LBA 2048), slot 2 the CSMWrap ESP
  C:       FreeDOS 1.4 boot sector (tools/vendor/freedos BOOT16.BIN with this
           volume's BPB), KERNEL.SYS, COMMAND.COM, AUTOEXEC.BAT (echo marker,
           DIR C:\\, write a file and read it back)
OVMF -> the NVMe ESP -> CSMWrap -> SeaBIOS (NVMe INT 13h) -> MBR -> FreeDOS.
PASS when the VGA text screen shows the marker, the DIR listing and the
read-back line.

  python tools/tests/legacy_bios/run_nvme_freedos_probe.py --output DIR

USOS_QEMU_EXE selects a renamed QEMU copy in tools/qemu. Disposable images
only; no physical disk access.
"""
from pathlib import Path
import argparse, os, struct, subprocess, sys, time

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_csmwrap_xp_ovmf import build_fat16, ESP_SECTORS  # noqa: E402
from run_seabios_xp_uefi_csm_textmode import Monitor, free_port, vga_text  # noqa: E402

QEMU = ROOT / 'tools/qemu' / os.environ.get('USOS_QEMU_EXE', 'qemu-system-x86_64.exe')
OVMF_CODE = ROOT / 'tools/qemu/share/edk2-x86_64-code.fd'
OVMF_VARS = ROOT / 'tools/qemu/share/edk2-i386-vars.fd'
CSMWRAP = ROOT / 'tools/vendor/csmwrap/3.1.2-usos4/csmwrapx64.efi'
FREEDOS = ROOT / 'tools/vendor/freedos/1.4'
SECTOR = 512
C_START, C_SECTORS = 2048, ESP_SECTORS
ESP_START = C_START + C_SECTORS + 2048
TOTAL = ESP_START + ESP_SECTORS + 2048
MARKER = 'USOS-NVME-DOS-OK'
AUTOEXEC = ('@echo off\r\necho ' + MARKER + '\r\ndir C:\\ /w\r\necho written-on-nvme> C:\\PROBE.TXT\r\n'
            'type C:\\PROBE.TXT\r\nver\r\n')


def mbr_code() -> bytes:
    for base in (ROOT, Path(os.environ.get('USOS_BUILD_ROOT', ROOT))):
        f = base / 'zig-out/xp-geometry-fix-mbr/xp-geometry-fix-mbr-440.bin'
        if f.is_file():
            return f.read_bytes()
    raise SystemExit('zig-out/xp-geometry-fix-mbr/xp-geometry-fix-mbr-440.bin missing (build.bat, or USOS_BUILD_ROOT)')


def dos_volume() -> bytes:
    files = {'KERNEL.SYS': (FREEDOS / 'KERNEL.SYS').read_bytes(), 'COMMAND.COM': (FREEDOS / 'COMMAND.COM').read_bytes(),
             'AUTOEXEC.BAT': AUTOEXEC.encode('ascii')}
    vol = bytearray(build_fat16(files, C_START))
    boot = bytearray((FREEDOS / 'BOOT16.BIN').read_bytes()[:SECTOR])
    boot[0x0B:0x3E] = vol[0x0B:0x3E]          # this volume's BPB + extended BPB
    boot[0x24] = 0x80                          # BIOS drive number
    boot[0x2B:0x36] = b'USOS-NVME  '
    boot[510:512] = b'\x55\xaa'
    vol[0:SECTOR] = boot
    return bytes(vol)


def make_disk(path: Path):
    mbr = bytearray(SECTOR)
    mbr[:440] = mbr_code()
    struct.pack_into('<I', mbr, 440, 0x55534E56)
    mbr[446:462] = struct.pack('<B3sB3sII', 0x80, b'\xfe\xff\xff', 0x06, b'\xfe\xff\xff', C_START, C_SECTORS)
    mbr[462:478] = struct.pack('<B3sB3sII', 0, b'\xfe\xff\xff', 0xEF, b'\xfe\xff\xff', ESP_START, ESP_SECTORS)
    mbr[510:512] = b'\x55\xaa'
    ini = 'serial = true\nserial_port = 0x3f8\nverbose = true\n'
    esp = build_fat16({'EFI/BOOT/BOOTX64.EFI': CSMWRAP.read_bytes(), 'EFI/BOOT/CSMWRAP.INI': ini.encode()}, ESP_START)
    with open(path, 'wb') as f:
        f.truncate(TOTAL * SECTOR)
        f.write(mbr)
        f.seek(C_START * SECTOR)
        f.write(dos_volume())
        f.seek(ESP_START * SECTOR)
        f.write(esp)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--seconds', type=int, default=180)
    a = p.parse_args()
    out = a.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    disk = out / 'nvme-dos.img'
    make_disk(disk)
    vars_fd = out / 'vars.fd'
    vars_fd.write_bytes(OVMF_VARS.read_bytes())
    port = free_port()
    cmd = [str(QEMU), '-name', 'USOS-nvme-freedos', '-machine', 'pc', '-accel', 'tcg', '-cpu', 'max', '-smp', '2',
           '-m', '1024', '-display', 'none', '-vga', 'std', '-nic', 'none',
           '-drive', f'if=pflash,format=raw,readonly=on,file={OVMF_CODE.as_posix()}',
           '-drive', f'if=pflash,format=raw,file={vars_fd.as_posix()}',
           '-serial', f'file:{(out / "serial.log").as_posix()}',
           '-monitor', f'tcp:127.0.0.1:{port},server=on,wait=off',
           '-drive', f'if=none,id=dos,format=raw,cache=writeback,file={disk.as_posix()}',
           '-device', 'nvme,drive=dos,serial=USOS-NVME-DOS']
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    text, ok = '', False
    try:
        time.sleep(1)
        mon = Monitor(port)
        start = time.time()
        while time.time() - start < a.seconds and proc.poll() is None:
            dump = out / 'vga.bin'
            dump.unlink(missing_ok=True)
            mon.cmd(f'pmemsave 0xb8000 4000 "{dump.as_posix()}"')
            for _ in range(20):
                if dump.exists() and dump.stat().st_size == 4000:
                    break
                time.sleep(0.05)
            text = vga_text(dump, 25) if dump.exists() else ''
            if MARKER in text and 'written-on-nvme' in text and 'KERNEL' in text.upper():
                ok = True
                time.sleep(2)
                break
            time.sleep(2)
        mon.cmd(f'screendump "{(out / "screen.ppm").as_posix()}"')
        mon.cmd('quit')
    finally:
        try:
            proc.wait(15)
        except Exception:
            proc.kill()
    (out / 'screen.txt').write_text(text, encoding='utf-8')
    print(text)
    print('NVME-FREEDOS-' + ('PASS' if ok else 'FAIL'), flush=True)
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
