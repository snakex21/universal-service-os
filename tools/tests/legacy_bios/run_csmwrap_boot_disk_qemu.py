"""CSMWrap boot-disk regression (docs/design/csmwrap-integration.md 13.4):
the disk CSMWrap was loaded from must be BIOS drive 0x80, whatever port or
controller other bootable disks sit on, and the other disks keep their
order after it.

Two small raw disks, OVMF without CSM, TCG:
  target: MBR boot code + MBR partition 1 = FAT16 ESP with
          EFI/BOOT/BOOTX64.EFI = CSMWrap (the only UEFI boot option)
  decoy:  MBR boot code + an ACTIVE NTFS-type partition (bootable in BIOS)
Both MBRs run the same 16-bit code: write their own name to the QEMU
debug console (port 0x402), read sector 0 of drive 0x81 with INT 13h and
write the name found there. "USOS-TARGET USOS-DECOY" = target is 0x80 and
the decoy 0x81: PASS. "USOS-DECOY ..." = SeaBIOS booted the decoy: FAIL.

Layouts (all with the decoy's MBR bootable):
  same-port0   decoy port 0, target port 1 of ONE AHCI controller (the bug)
  same-port1   target port 0, decoy port 1 of one AHCI controller
  other-ctrl   decoy on its own AHCI controller at a lower PCI slot
  usb-target   target on qemu-xhci usb-storage (the stick path), decoy on AHCI
  nvme-target  target on an NVMe controller, decoy on AHCI (INT 13h on NVMe,
               docs/nvme-nt-2026-10-11.md: DOS / 9x / NTLDR read through it)
  nvme-decoy   target on AHCI, decoy on NVMe (0x81 read from NVMe)

  python tools/tests/legacy_bios/run_csmwrap_boot_disk_qemu.py --output zig-out/csmwrap-bootdisk \
      [--csmwrap-efi <efi>] [--layout same-port0 ...] [--expect-fail]

USOS_QEMU_EXE selects a renamed QEMU copy in tools/qemu (parallel runs).
Test tool only; disposable images only; no physical disk access.
"""
from pathlib import Path
import argparse, os, struct, subprocess, sys, time

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(ROOT / 'tools'))
from run_csmwrap_xp_ovmf import build_fat16, ESP_SECTORS  # noqa: E402

QEMU = ROOT / 'tools/qemu' / os.environ.get('USOS_QEMU_EXE', 'qemu-system-x86_64.exe')
OVMF_CODE = ROOT / 'tools/qemu/share/edk2-x86_64-code.fd'
OVMF_VARS = ROOT / 'tools/qemu/share/edk2-i386-vars.fd'
CSMWRAP = ROOT / 'tools/vendor/csmwrap/3.1.2-usos5/csmwrapx64.efi'
SECTOR = 512
DISK_SECTORS = 2048 + ESP_SECTORS + 2048
LAYOUTS = ('same-port0', 'same-port1', 'other-ctrl', 'usb-target', 'nvme-target', 'nvme-decoy')


def boot_code(name: bytes) -> bytes:
    """16-bit MBR code (loaded at 0:7C00), offsets fixed by hand."""
    msg, err = 0x60, 0x80
    c = bytearray()
    c += b'\xfa\x31\xc0\x8e\xd8\x8e\xc0\x8e\xd0\xbc\x00\x7c\xfb'  # cli; ds=es=ss=0; sp=7c00; sti
    c += b'\xbe' + struct.pack('<H', 0x7C00 + msg)                # mov si, own name
    c += b'\xe8' + struct.pack('<h', 0x35 - (len(c) + 3))         # call print
    c += b'\xb8\x01\x02\xb9\x01\x00\xba\x81\x00\xbb\x00\x80'      # ax=0201 cx=1 dx=0081 bx=8000
    c += b'\xcd\x13'                                              # int 13h
    c += b'\x72' + bytes([0x2C - (len(c) + 2)])                   # jc fail
    c += b'\xbe' + struct.pack('<H', 0x8000 + msg)                # mov si, name in 0x81's MBR
    c += b'\xe8' + struct.pack('<h', 0x35 - (len(c) + 3))         # call print
    c += b'\xf4\xeb\xfd'                                          # hlt loop
    assert len(c) == 0x2C
    c += b'\xbe' + struct.pack('<H', 0x7C00 + err)                # fail: mov si, err
    c += b'\xe8' + struct.pack('<h', 0x35 - (len(c) + 3))
    c += b'\xf4\xeb\xfd'
    assert len(c) == 0x35
    c += b'\xba\x02\x04\xac\x84\xc0\x74\x03\xee\xeb\xf8\xc3'      # print: dx=402; lodsb loop; ret
    c = c.ljust(msg, b'\0') + b' ' + name + b' \0'
    c = c.ljust(err, b'\0') + b' NO-DRIVE-81 \0'
    return bytes(c)


def make_disk(path: Path, name: bytes, esp: bool, efi: bytes):
    mbr = bytearray(SECTOR)
    code = boot_code(name)
    mbr[:len(code)] = code
    struct.pack_into('<I', mbr, 440, 0x55530000 | (1 if esp else 2))
    if esp:
        mbr[446:462] = struct.pack('<B3sB3sII', 0, b'\xfe\xff\xff', 0xEF, b'\xfe\xff\xff', 2048, ESP_SECTORS)
    else:
        mbr[446:462] = struct.pack('<B3sB3sII', 0x80, b'\xfe\xff\xff', 0x07, b'\xfe\xff\xff', 2048, ESP_SECTORS)
    mbr[510:512] = b'\x55\xaa'
    with open(path, 'wb') as f:
        f.truncate(DISK_SECTORS * SECTOR)
        f.write(mbr)
        if esp:
            ini = 'serial = true\r\nserial_port = 0x3f8\r\nverbose = true\r\n'
            f.seek(2048 * SECTOR)
            f.write(build_fat16({'EFI/BOOT/BOOTX64.EFI': efi, 'EFI/BOOT/CSMWRAP.INI': ini.encode()}, 2048))


def qemu_args(layout: str, target: Path, decoy: Path, out: Path, vars_fd: Path) -> list[str]:
    a = [str(QEMU), '-name', f'USOS-bootdisk-{layout}', '-machine', 'pc', '-accel', 'tcg', '-cpu', 'max',
         '-smp', '2', '-m', '1024', '-display', 'none', '-no-reboot', '-vga', 'std',
         '-drive', f'if=pflash,format=raw,readonly=on,file={OVMF_CODE.as_posix()}',
         '-drive', f'if=pflash,format=raw,file={vars_fd.as_posix()}',
         '-debugcon', f'file:{(out / "debugcon.log").as_posix()}', '-global', 'isa-debugcon.iobase=0x402',
         '-serial', f'file:{(out / "serial.log").as_posix()}', '-monitor', 'none',
         '-device', 'qemu-xhci,id=xhci',
         '-drive', f'if=none,id=target,format=raw,cache=writeback,file={target.as_posix()}',
         '-drive', f'if=none,id=decoy,format=raw,cache=writeback,file={decoy.as_posix()}']
    if layout == 'same-port0':
        a += ['-device', 'ahci,id=sata', '-device', 'ide-hd,bus=sata.0,drive=decoy', '-device', 'ide-hd,bus=sata.1,drive=target']
    elif layout == 'same-port1':
        a += ['-device', 'ahci,id=sata', '-device', 'ide-hd,bus=sata.0,drive=target', '-device', 'ide-hd,bus=sata.1,drive=decoy']
    elif layout == 'other-ctrl':
        a += ['-device', 'ahci,id=sata_decoy,addr=0x5', '-device', 'ide-hd,bus=sata_decoy.0,drive=decoy',
              '-device', 'ahci,id=sata,addr=0x6', '-device', 'ide-hd,bus=sata.0,drive=target']
    elif layout == 'usb-target':
        a += ['-device', 'ahci,id=sata', '-device', 'ide-hd,bus=sata.0,drive=decoy',
              '-device', 'usb-storage,bus=xhci.0,drive=target,removable=on']
    elif layout == 'nvme-target':
        a += ['-device', 'ahci,id=sata', '-device', 'ide-hd,bus=sata.0,drive=decoy',
              '-device', 'nvme,drive=target,serial=USOS-NVME-T']
    elif layout == 'nvme-decoy':
        a += ['-device', 'nvme,drive=decoy,serial=USOS-NVME-D',
              '-device', 'ahci,id=sata', '-device', 'ide-hd,bus=sata.0,drive=target']
    return a


def run_layout(layout: str, efi: bytes, out: Path, minutes: float) -> str:
    out.mkdir(parents=True, exist_ok=True)
    for f in ('debugcon.log', 'serial.log'):
        (out / f).unlink(missing_ok=True)
    target, decoy, vars_fd = out / 'target.img', out / 'decoy.img', out / 'vars.fd'
    make_disk(target, b'USOS-TARGET', True, efi)
    make_disk(decoy, b'USOS-DECOY', False, efi)
    decoy_before = decoy.read_bytes()
    vars_fd.write_bytes(OVMF_VARS.read_bytes())
    proc = subprocess.Popen(qemu_args(layout, target, decoy, out, vars_fd),
                            stdout=subprocess.DEVNULL, stderr=open(out / 'qemu-stderr.log', 'wb'))
    print(f'[QEMU] {layout} pid={proc.pid}', flush=True)
    result, deadline, text = 'TIMEOUT', time.time() + minutes * 60, ''
    try:
        while time.time() < deadline and proc.poll() is None:
            time.sleep(2)
            raw = (out / 'debugcon.log').read_bytes() if (out / 'debugcon.log').exists() else b''
            text = raw.decode('latin-1')
            first = min((text.find(n) for n in (' USOS-TARGET ', ' USOS-DECOY ') if n in text), default=-1)
            if first < 0:
                continue
            tail = text[first:]
            if tail.count('USOS-') >= 2 or 'NO-DRIVE-81' in tail:
                time.sleep(1)
                tail = (out / 'debugcon.log').read_bytes().decode('latin-1')[first:]
                result = tail.strip().split('\n')[0][:60]
                break
    finally:
        if proc.poll() is None:
            proc.kill()  # our own PID only
        proc.wait()
    unchanged = decoy.read_bytes() == decoy_before
    for f in (target, decoy, vars_fd):
        f.unlink(missing_ok=True)
    serial = (out / 'serial.log').read_text('latin-1') if (out / 'serial.log').exists() else ''
    tagged = [l.strip() for l in serial.splitlines() if 'is the boot disk' in l]
    print(f'[{layout}] debugcon: {result!r}; decoy unchanged: {unchanged}; csmwrap: {tagged[:1]}', flush=True)
    return result if unchanged else result + ' DECOY-WRITTEN'


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument('--output', type=Path, default=ROOT / 'zig-out/csmwrap-bootdisk')
    p.add_argument('--csmwrap-efi', type=Path, default=CSMWRAP)
    p.add_argument('--layout', action='append', choices=LAYOUTS)
    p.add_argument('--minutes', type=float, default=6)
    p.add_argument('--expect-fail', action='store_true', help='control run with an older CSMWrap: same-port0 must boot the decoy')
    a = p.parse_args()
    efi = a.csmwrap_efi.read_bytes()
    ok = True
    for layout in a.layout or LAYOUTS:
        got = run_layout(layout, efi, a.output / layout, a.minutes)
        want = 'USOS-DECOY' if a.expect_fail else 'USOS-TARGET  USOS-DECOY'
        if a.expect_fail:
            passed = got.startswith('USOS-DECOY')
        else:
            passed = got.replace('  ', ' ').startswith('USOS-TARGET USOS-DECOY')
        print(f'[{layout}] {"PASS" if passed else "FAIL"} (want {want!r})', flush=True)
        ok &= passed
    print('BOOT-DISK-' + ('PASS' if ok else 'FAIL'), flush=True)
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
