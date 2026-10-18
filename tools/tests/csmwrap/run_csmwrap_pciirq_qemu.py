"""QEMU check for CSMWrap 3.1.2-usos12 patch 0015 (csmwrap.ini pci_irq_routing).

pciirq_mbr.S boots through CSMWrap's SeaBIOS (OVMF without CSM, TCG) and
prints what a Windows 9x PCI enumerator reads: INT 1Ah B10Eh ($PIR slots),
Interrupt Pin / Line of every function on buses 0-7, the ELCR. Machines:
pc (PIIX, an e1000 behind a pci-bridge: swizzle) and q35 (an e1000 behind
a PCIe root port). Runs with and without the key:

  key on : CSMWrap prints "pciirq:" lines; every function with a pin has an
           Interrupt Line 1..15 (not 2/8/13) and level in the ELCR; each
           (bus, device) with a pin is in $PIR with that IRQ as its bitmap;
           the device behind the bridge is included.
  key off: no "pciirq:" line, and with --baseline-efi (3.1.2-usos11-int13x)
           the debug console output is byte-identical to the baseline's.

QEMU's OVMF already routes PIIX/ICH9 PIRQs and Interrupt Line itself, so
on QEMU the links normally keep their IRQ (the _SRS path is covered by the
host test; the real case is the X470, where every link is at IRQ 0).

  python tools/tests/csmwrap/run_csmwrap_pciirq_qemu.py --out DIR --csmwrap-efi EFI
      [--machine pc --machine q35] [--root CHECKOUT]

USOS_QEMU_EXE selects a renamed QEMU copy (only this run's PID is killed).
Disposable images only; no physical disk access.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT / 'tools/tests/legacy_bios'))
from run_csmwrap_xp_ovmf import build_fat16, ESP_SECTORS  # noqa: E402

SECTOR = 512


def assemble(zig: Path, tmp: Path) -> bytes:
    obj, binf = tmp / 'pciirq_mbr.o', tmp / 'pciirq_mbr.bin'
    subprocess.run([str(zig), 'cc', '-target', 'x86-freestanding-none', '-c', str(HERE / 'pciirq_mbr.S'),
                    '-o', str(obj)], check=True)
    subprocess.run([str(zig), 'ld.lld', '-m', 'elf_i386', '--oformat=binary', '--image-base=0', '-Ttext=0x7c00',
                    '-e', '_start', str(obj), '-o', str(binf)], check=True)
    code = binf.read_bytes()
    assert len(code) == SECTOR, len(code)
    assert not any(code[446:510]), 'code runs into the partition table'
    return code


def make_disk(path: Path, code: bytes, efi: bytes, key: bool) -> None:
    mbr = bytearray(code)
    mbr[446:462] = (b'\x00\xfe\xff\xff\xef\xfe\xff\xff' + (2048).to_bytes(4, 'little')
                    + ESP_SECTORS.to_bytes(4, 'little'))
    ini = 'serial = true\r\nserial_port = 0x3f8\r\nverbose = true\r\n'
    if key:
        ini += 'pci_irq_routing = true\r\n'
    with open(path, 'wb') as f:
        f.truncate((2048 + ESP_SECTORS + 2048) * SECTOR)
        f.write(mbr)
        f.seek(2048 * SECTOR)
        f.write(build_fat16({'EFI/BOOT/BOOTX64.EFI': efi, 'EFI/BOOT/CSMWRAP.INI': ini.encode()}, 2048))


def parse(dbg: str):
    m = re.search(r' PIR ([0-9A-F]{2}) ([0-9A-F]{4}) ([0-9A-F]{4}) ', dbg)
    pir = (int(m.group(1), 16), int(m.group(2), 16), int(m.group(3), 16)) if m else None
    slots = [bytes.fromhex(r) for r in re.findall(r' R ([0-9A-F]{32}) ', dbg)]
    # F <bus><devfn> <line><pin>
    funcs = [(int(a[:2], 16), int(a[2:], 16), int(b[2:], 16), int(b[:2], 16))
             for a, b in re.findall(r' F ([0-9A-F]{4}) ([0-9A-F]{4}) ', dbg)]
    e = re.search(r' ELCR ([0-9A-F]{4}) ', dbg)
    return pir, slots, funcs, (int(e.group(1), 16) if e else None)


def run(root: Path, code: bytes, efi: bytes, machine: str, key: bool, out: Path, minutes: float) -> bool:
    out.mkdir(parents=True, exist_ok=True)
    for f in ('debugcon.log', 'serial.log'):
        (out / f).unlink(missing_ok=True)
    disk, vars_fd = out / 'disk.img', out / 'vars.fd'
    make_disk(disk, code, efi, key)
    vars_fd.write_bytes((root / 'tools/qemu/share/edk2-i386-vars.fd').read_bytes())
    qemu = root / 'tools/qemu' / os.environ.get('USOS_QEMU_EXE', 'qemu-system-x86_64.exe')
    if machine == 'pc':
        extra = ['-device', 'pci-bridge,id=br1,chassis_nr=1,addr=5',
                 '-device', 'e1000,bus=br1,addr=3,netdev=n0', '-netdev', 'user,id=n0']
        behind = 1  # secondary bus of the only bridge
    else:
        extra = ['-device', 'pcie-root-port,id=rp1,chassis=1,addr=6',
                 '-device', 'e1000e,bus=rp1,netdev=n0', '-netdev', 'user,id=n0']
        behind = 1
    cmd = [str(qemu), '-name', f'USOS-pciirq-{machine}', '-machine', machine, '-accel', 'tcg', '-cpu', 'max',
           '-smp', '2', '-m', '512', '-display', 'none', '-vga', 'std',
           '-drive', f'if=pflash,format=raw,readonly=on,file={(root / "tools/qemu/share/edk2-x86_64-code.fd").as_posix()}',
           '-drive', f'if=pflash,format=raw,file={vars_fd.as_posix()}',
           '-debugcon', f'file:{(out / "debugcon.log").as_posix()}', '-global', 'isa-debugcon.iobase=0x402',
           '-serial', f'file:{(out / "serial.log").as_posix()}', '-monitor', 'none',
           '-device', 'isa-debug-exit,iobase=0xf4,iosize=1',
           '-drive', f'if=none,id=d0,format=raw,file={disk.as_posix()}',
           '-device', 'ide-hd,drive=d0,bootindex=0' if machine == 'pc' else 'ide-hd,drive=d0,bus=ide.0,bootindex=0',
           *extra]
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=open(out / 'qemu-stderr.log', 'wb'))
    try:
        deadline = time.time() + minutes * 60
        while time.time() < deadline and proc.poll() is None:
            time.sleep(1)
    finally:
        if proc.poll() is None:
            proc.kill()  # our own PID only
        proc.wait()
    dbg = (out / 'debugcon.log').read_bytes().decode('latin-1') if (out / 'debugcon.log').exists() else ''
    ser = (out / 'serial.log').read_bytes().decode('latin-1') if (out / 'serial.log').exists() else ''
    lines = [l.strip() for l in ser.splitlines() if 'pciirq:' in l or 'pir:' in l]
    pir, slots, funcs, elcr = parse(dbg)
    errs = []
    if 'PCIIRQ-END' not in dbg or pir is None or elcr is None:
        errs.append('no complete debugcon output')
    elif pir[0] != 0:
        errs.append(f'B10Eh failed ah={pir[0]:02x}')
    slotmap = {(s[0], s[1] & 0xF8): s for s in slots}
    if not errs and key:
        if not any('pciirq:' in l and 'routed' in l for l in lines):
            errs.append('no pciirq summary line')
        for bus, devfn, pin, line in funcs:
            if not (1 <= line <= 15) or line in (2, 8, 13):
                errs.append(f'{bus:02x}:{devfn >> 3:02x}.{devfn & 7} line {line:#x}')
                continue
            if not (elcr >> line) & 1:
                errs.append(f'IRQ {line} not level in ELCR {elcr:04x}')
            s = slotmap.get((bus, devfn & 0xF8))
            if not s:
                errs.append(f'{bus:02x}:{devfn >> 3:02x} not in $PIR')
                continue
            bm = s[3 + (pin - 1) * 3] | (s[4 + (pin - 1) * 3] << 8)
            if bm != (1 << line) or not s[2 + (pin - 1) * 3]:
                errs.append(f'{bus:02x}:{devfn >> 3:02x} pin {pin}: $PIR bitmap {bm:04x} != line {line}')
        if not any(b == behind for b, _, _, _ in funcs):
            errs.append('device behind the bridge not seen')
    elif not errs:
        if any('pciirq:' in l for l in lines):
            errs.append('pciirq ran without the key')
    ok = not errs
    tag = 'on' if key else 'off'
    print(f'[{machine} key {tag}] {"PASS" if ok else "FAIL"} pir={pir} slots={len(slots)} '
          f'funcs={[(f"{b:02x}:{d >> 3:02x}.{d & 7}", p, l) for b, d, p, l in funcs]} elcr={elcr}', flush=True)
    for l in lines:
        print(f'    {l}', flush=True)
    for e in errs:
        print(f'    ERROR {e}', flush=True)
    for f in (disk, vars_fd):
        f.unlink(missing_ok=True)
    (out / 'result.txt').write_text(dbg, encoding='latin-1')
    return ok


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--root', type=Path, default=ROOT)
    p.add_argument('--csmwrap-efi', type=Path, default=ROOT / 'tools/vendor/csmwrap/3.1.2-usos15/csmwrapx64.efi')
    p.add_argument('--machine', action='append', choices=('pc', 'q35'))
    p.add_argument('--minutes', type=float, default=3)
    p.add_argument('--baseline-efi', type=Path, help='key-off output must equal this binary (e.g. usos11-int13x)')
    a = p.parse_args()
    root = a.root.resolve()
    out = a.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    code = assemble(root / 'tools/zig/zig.exe', out)
    efi = a.csmwrap_efi.read_bytes()
    ok = True
    for machine in a.machine or ['pc', 'q35']:
        for key in (True, False):
            ok &= run(root, code, efi, machine, key, out / f'{machine}-{"on" if key else "off"}', a.minutes)
        if a.baseline_efi:
            run(root, code, a.baseline_efi.read_bytes(), machine, False, out / f'{machine}-base', a.minutes)
            def marks(d: str) -> str:  # only the MBR's lines (OVMF's own debug log differs per binary)
                t = (out / d / 'result.txt').read_text(encoding='latin-1')
                return t[t.find(' PIR '):t.find(' PCIIRQ-END ')] if ' PIR ' in t else ''
            same = marks(f'{machine}-base') == marks(f'{machine}-off') != ''
            print(f'[{machine}] key off vs baseline: {"identical" if same else "DIFFERENT"}', flush=True)
            ok &= same
    print('PCIIRQ-QEMU-' + ('PASS' if ok else 'FAIL'), flush=True)
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
