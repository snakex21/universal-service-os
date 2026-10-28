#!/usr/bin/env python3
"""usosusb hub support on QEMU (QEMU only; not hardware evidence).

    python tools/tests/usosusb_hub/run_hub_qemu.py [--variant nt6|nt4] [--keep]

Builds the real tools/nt4/usosusb/src/usosusb.c into a bare-metal harness
(harness.c + shim.c, WDK 7.1 in tools/WinDDK71 or %WDKROOT%), turns the
linked image into a multiboot kernel and boots it with QEMU -kernel on
q35 + qemu-xhci, no i8042. The driver's worker thread runs on the boot CPU;
its Diag value and every keyboard / mouse record come out on COM1. No
Windows install, no disk image besides a 64 MiB scratch stick.

Scenarios (one QEMU run, monitor commands in between):
  boot      hub on root port 1 with keyboard 1.1, mouse 1.2, stick 1.3, a
            second hub on 1.4 with a keyboard on 1.4.1 (depth 2); a keyboard
            on root port 2 (root ports unchanged), a mouse on root port 3
  input     sendkey / mouse_move reach the class callbacks
  hotplug   keyboard 1.1 out, keyboard in on 1.4.2, stick 1.3 out and in,
            the depth-2 hub out (its keyboard goes with it)
  mouse     mouse out / in on root port 3 and on hub port 1.2; mouse_move
            and a button must reach the mouse class callback after each
            reattach (X470 2026-10-21: mouse replug failed with -addr4)
  sticks    (NT6 and NT 4.0 builds) the hub with the stick out (its stick
            goes with it), then a stick on root port 4 in and out; NT 4.0:
            every arrival / removal through the mount queue (run by the
            harness in the worker's idle wait) gives exactly one
            LINK + / LINK - of a \\DosDevices letter on COM1. The NT 4.0
            stick is FAT16 (that build publishes FAT12 / FAT16 / NTFS only).

QEMU's usb-hub is a full-speed USB 1.1 hub: the transaction translator
fields (TT hub slot / port) and SuperSpeed hubs (SET_HUB_DEPTH, the USB 3
companion split) are not exercised here.
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]


def find_tool(rel: str) -> Path:
    """tools/<rel> in this checkout, else in the main checkout (worktrees
    have no toolchains)."""
    for base in (ROOT, Path(os.environ.get('USOS_MAIN_CHECKOUT', r'C:\Users\ASRock\Desktop\usos-x470-98se'))):
        p = base / 'tools' / rel
        if p.exists():
            return p
    raise SystemExit(f'missing tools/{rel}')


def wdk_root() -> Path:
    if os.environ.get('WDKROOT'):
        return Path(os.environ['WDKROOT'])
    for p in (ROOT / 'tools' / 'WinDDK71', Path(r'C:\Users\ASRock\Desktop\universal-service-os\tools\WinDDK71')):
        if (p / 'bin' / 'setenv.bat').exists():
            return p
    raise SystemExit('WDK 7.1 not found (WDKROOT)')


def build(variant: str, work: Path) -> Path:
    src = work / 'src'
    if src.exists():
        shutil.rmtree(src)
    src.mkdir(parents=True)
    for name in ('harness.c', 'shim.c', 'sources', 'makefile'):
        shutil.copy(HERE / name, src / name)
    shutil.copy(ROOT / 'tools/nt4/usosusb/src/usosusb.c', src / 'usosusb.c')
    defines = {'nt6': '-DUSOSUSB_NT6', 'nt4': '', 'nt31': '-DUSOSUSB_NT31'}[variant]
    wdk = wdk_root()
    script = work / 'build-harness.cmd'
    script.write_text('@echo off\n'
                      f'set "C_DEFINES={defines}"\n'
                      f'call "{wdk}\\bin\\setenv.bat" {wdk} fre x86 WXP no_oacr\n'
                      'set "BUILD_ALT_DIR=fre"\n'
                      f'cd /d "{src}"\n'
                      'build -cZ\n'
                      'if not exist objfre\\i386\\usbhubh.lib exit /b 4\n'
                      'link /nologo /NODEFAULTLIB /SUBSYSTEM:NATIVE /BASE:0x200000 /FIXED /INCLUDE:_mb_start '
                      '/ENTRY:mb_start /OUT:objfre\\i386\\usbhubh.sys objfre\\i386\\usbhubh.lib '
                      '"%BASEDIR%\\lib\\wxp\\i386\\libcntpr.lib" > link.log 2>&1\n')
    subprocess.run(['cmd', '/d', '/c', str(script)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    out = src / 'objfre' / 'i386' / 'usbhubh.sys'
    if not out.exists():
        for log in [*src.glob('buildfre*.*'), src / 'link.log']:
            if not log.exists():
                continue
            sys.stdout.write(log.read_text(errors='replace')[-4000:])
        raise SystemExit('harness build failed')
    return out


BASE = 0x00200000


def to_multiboot(pe_path: Path, out: Path) -> None:
    """Map the PE at BASE (relocations applied), multiboot a.out-kludge
    header at offset 0, entry = mb_start (found through g_mbmark)."""
    b = pe_path.read_bytes()
    pe = struct.unpack_from('<I', b, 0x3C)[0]
    nsec = struct.unpack_from('<H', b, pe + 6)[0]
    optsz = struct.unpack_from('<H', b, pe + 20)[0]
    opt = pe + 24
    image_base = struct.unpack_from('<I', b, opt + 28)[0]
    size = struct.unpack_from('<I', b, opt + 56)[0]
    reloc_rva, reloc_size = struct.unpack_from('<II', b, opt + 96 + 5 * 8)
    img = bytearray(size)
    sec = opt + optsz
    for i in range(nsec):
        vsize, rva, rawsz, rawoff = struct.unpack_from('<IIII', b, sec + 40 * i + 8)
        n = min(rawsz, vsize) if vsize else rawsz
        img[rva:rva + n] = b[rawoff:rawoff + n]
    delta = (BASE - image_base) & 0xFFFFFFFF
    off = reloc_rva
    while off < reloc_rva + reloc_size:
        page, blk = struct.unpack_from('<II', img, off)
        if blk < 8:
            break
        for k in range((blk - 8) // 2):
            e = struct.unpack_from('<H', img, off + 8 + 2 * k)[0]
            if e >> 12 == 3:
                at = page + (e & 0xFFF)
                v = struct.unpack_from('<I', img, at)[0]
                struct.pack_into('<I', img, at, (v + delta) & 0xFFFFFFFF)
        off += blk
    m = img.find(b'USOSMBH\0')
    if m < 0:
        raise SystemExit('g_mbmark not found')
    entry = struct.unpack_from('<I', img, m + 8)[0]
    flags = 0x00010000
    magic = 0x1BADB002
    hdr = struct.pack('<IIIIIIII', magic, flags, (-(magic + flags)) & 0xFFFFFFFF,
                      BASE, BASE, BASE + size, BASE + size, entry)
    img[0:len(hdr)] = hdr
    out.write_bytes(bytes(img))


def make_stick(path: Path, mib: int = 64, fat16: bool = False) -> None:
    """MBR with one FAT32 LBA partition (type 0Ch) from sector 2048, or
    (fat16, for the NT 4.0 build) a FAT16 partition (type 06h) with a FAT16
    boot sector."""
    sectors = mib * 2048
    with open(path, 'wb') as f:
        f.truncate(sectors * 512)
        mbr = bytearray(512)
        struct.pack_into('<I', mbr, 440, 0x55534F53)
        e = 446
        mbr[e + 4] = 0x06 if fat16 else 0x0C
        struct.pack_into('<II', mbr, e + 8, 2048, sectors - 2048)
        mbr[510:512] = b'\x55\xAA'
        f.seek(0)
        f.write(mbr)
        if fat16:
            bs = bytearray(512)
            bs[0:3] = b'\xEB\x3C\x90'
            bs[3:11] = b'MSDOS5.0'
            # BPB: 512 B/sector, 4 sectors/cluster, 1 reserved, 2 FATs, 512 root
            # entries, no 16-bit total, F8h, 128 sectors/FAT, CHS 63/255, hidden, total
            struct.pack_into('<HBHBHHBHHHII', bs, 11, 512, 4, 1, 2, 512, 0, 0xF8, 128, 63, 255, 2048,
                             sectors - 2048)
            bs[38] = 0x29
            struct.pack_into('<I', bs, 39, 0x12345678)
            bs[54:62] = b'FAT16   '
            bs[510:512] = b'\x55\xAA'
            f.seek(2048 * 512)
            f.write(bs)


class Vm:
    def __init__(self, kernel: Path, stick: Path, work: Path):
        self.serial = work / 'serial.log'
        if self.serial.exists():
            self.serial.unlink()
        with socket.socket() as s:
            s.bind(('127.0.0.1', 0))
            self.port = s.getsockname()[1]
        qemu = find_tool('qemu/qemu-system-x86_64.exe')
        args = [str(qemu), '-machine', 'q35,i8042=off', '-accel', 'tcg', '-cpu', 'max', '-m', '256',
                '-display', 'none', '-nic', 'none', '-no-reboot',
                '-serial', f'file:{self.serial.as_posix()}',
                '-monitor', f'tcp:127.0.0.1:{self.port},server=on,wait=off',
                '-kernel', str(kernel),
                '-drive', f'if=none,id=stick,format=raw,file={stick.as_posix()}',
                '-device', 'qemu-xhci,id=xhci',
                # before the hub mouse: QEMU routes mouse_move to the newest mouse
                '-device', 'usb-mouse,bus=xhci.0,port=3,id=m2',
                '-device', 'usb-hub,bus=xhci.0,port=1,id=hub1',
                '-device', 'usb-kbd,bus=xhci.0,port=1.1,id=k1',
                '-device', 'usb-mouse,bus=xhci.0,port=1.2,id=m1',
                '-device', 'usb-storage,bus=xhci.0,port=1.3,drive=stick,id=s1,removable=on',
                '-device', 'usb-hub,bus=xhci.0,port=1.4,id=hub2',
                '-device', 'usb-kbd,bus=xhci.0,port=1.4.1,id=k2',
                '-device', 'usb-kbd,bus=xhci.0,port=2,id=k3']
        self.proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=open(work / 'qemu.stderr.log', 'wb'))
        time.sleep(1.5)
        self.sock = socket.create_connection(('127.0.0.1', self.port), timeout=10)
        self.sock.settimeout(1)
        self._drain()

    def _drain(self) -> str:
        out = b''
        try:
            while True:
                d = self.sock.recv(65536)
                if not d:
                    break
                out += d
        except OSError:
            pass
        return out.decode(errors='replace')

    def hmp(self, cmd: str) -> str:
        self.sock.sendall((cmd + '\n').encode())
        time.sleep(0.3)
        return self._drain()

    def text(self) -> str:
        return self.serial.read_text(errors='replace') if self.serial.exists() else ''

    def diag(self) -> str:
        lines = [l for l in self.text().splitlines() if l.startswith('REG Diag=')]
        return lines[-1][len('REG Diag='):] if lines else ''

    def wait(self, pattern: str, timeout: float) -> bool:
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if re.search(pattern, self.diag()):
                return True
            if self.proc.poll() is not None:
                return False
            time.sleep(0.5)
        return False

    def stop(self) -> None:
        try:
            self.hmp('quit')
        except OSError:
            pass
        try:
            self.proc.wait(10)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--variant', default='nt6', choices=('nt6', 'nt4', 'nt31'))
    ap.add_argument('--keep', action='store_true', help='keep the work folder')
    ap.add_argument('--work', type=Path)
    a = ap.parse_args()
    work = a.work or Path(tempfile.mkdtemp(prefix='usosusb-hub-'))
    work.mkdir(parents=True, exist_ok=True)
    results: list[tuple[str, bool, str]] = []

    def check(name: str, ok: bool, detail: str = '') -> None:
        results.append((name, ok, detail))
        print(f"[{'PASS' if ok else 'FAIL'}] {name} {detail}".rstrip(), flush=True)

    pe = build(a.variant, work)
    kernel = work / 'usosusb-hub.mb'
    to_multiboot(pe, kernel)
    stick = work / 'stick.img'
    nt4 = a.variant == 'nt4'
    make_stick(stick, fat16=nt4)
    msc = a.variant in ('nt6', 'nt4')
    vm = Vm(kernel, stick, work)
    try:
        # boot: everything enumerated
        want = [r' p7:s\d+-M', r' p5:s\d+H8fs', r' p5\.1:s\d+K-', r' p5\.2:s\d+-M', r' p5\.4:s\d+H8fs', r' p5\.4\.1:s\d+K-', r' p6:s\d+K-']
        if msc:
            want.append(r' p5\.3:s\d+--S\(64M wp0 1v\)')
        ok = vm.wait(r' p5\.4\.1:s\d+K-', 240)
        if msc:
            ok = vm.wait(r'p5\.3:s\d+--S\(', 60) and ok
        d = vm.diag()
        for w in want:
            check(f'boot {w.strip()}', re.search(w, d) is not None)
        print('DIAG', d, flush=True)

        # input through the hubs: QEMU sends keys to the newest keyboard
        # handler; check that some keyboard and the mouse deliver records
        n0 = vm.text().count('KBD ')
        vm.hmp('sendkey a')
        time.sleep(3)
        check('input keyboard records', vm.text().count('KBD ') > n0, f'{vm.text().count("KBD ") - n0} new')
        m0 = vm.text().count('MOU ')
        vm.hmp('mouse_move 10 5')
        vm.hmp('mouse_button 1')
        vm.hmp('mouse_button 0')
        time.sleep(3)
        check('input mouse records (mouse on hub port 1.2)', vm.text().count('MOU ') > m0, f'{vm.text().count("MOU ") - m0} new')

        # hot plug behind the hub
        vm.hmp('device_del k1')
        check('hotplug kbd 1.1 out', vm.wait(r' p5\.1-gone', 30))
        vm.hmp('device_add usb-kbd,bus=xhci.0,port=1.4.2,id=k4')
        check('hotplug kbd in on 1.4.2 (depth 2)', vm.wait(r' p5\.4\.2:s\d+K-', 30))
        if msc:
            vm.hmp('device_del s1')
            check('hotplug stick 1.3 out', vm.wait(r' p5\.3-gone', 30))
            # device_del took the legacy drive along: a new backend first
            vm.hmp(f'drive_add 0 if=none,id=stick2,format=raw,file={stick.as_posix()}')
            vm.hmp('device_add usb-storage,bus=xhci.0,port=1.3,drive=stick2,id=s2,removable=on')
            check('hotplug stick 1.3 in', vm.wait(r'p5\.3-gone.* p5\.3:s\d+--S\(64M wp0 1v\)', 60))
        vm.hmp('device_del hub2')
        ok = vm.wait(r' p5\.4\.1-gone', 30) and vm.wait(r' p5\.4\.2-gone', 5) and vm.wait(r' p5\.4-gone', 5)
        check('hotplug hub 1.4 out with its keyboards', ok)
        vm.hmp('device_add usb-kbd,bus=xhci.0,port=1.1,id=k5')
        check('hotplug kbd back on 1.1', vm.wait(r'p5\.1-gone.* p5\.1:s\d+K-', 30))

        # mouse unplug / replug, root port and hub port; the new mouse is
        # QEMU's newest mouse, so mouse_move goes to it
        def mouse_records(name: str) -> None:
            m0 = vm.text().count('MOU ')
            vm.hmp('mouse_move 7 -3')
            vm.hmp('mouse_button 1')
            vm.hmp('mouse_button 0')
            time.sleep(3)
            check(name, vm.text().count('MOU ') > m0, f'{vm.text().count("MOU ") - m0} new')

        vm.hmp('device_del m2')
        check('mouse root port 3 out', vm.wait(r' p7-gone', 30))
        vm.hmp('device_add usb-mouse,bus=xhci.0,port=3,id=m3')
        check('mouse root port 3 back in', vm.wait(r'p7-gone.* p7:s\d+-M', 30))
        mouse_records('mouse records after root port replug')
        vm.hmp('device_del m3')
        check('mouse root port 3 out again', vm.wait(r'p7-gone.* p7:s\d+-M.* p7-gone', 30))
        vm.hmp('device_add usb-mouse,bus=xhci.0,port=3,id=m5')
        check('mouse root port 3 in again', vm.wait(r'p7-gone.* p7-gone.* p7:s\d+-M', 30))
        mouse_records('mouse records after second root port replug')
        vm.hmp('device_del m1')
        check('mouse hub port 1.2 out', vm.wait(r' p5\.2-gone', 30))
        vm.hmp('device_add usb-mouse,bus=xhci.0,port=1.2,id=m4')
        check('mouse hub port 1.2 back in', vm.wait(r'p5\.2-gone.* p5\.2:s\d+-M', 30))
        mouse_records('mouse records after hub port replug')

        if msc:
            def links(sign: str) -> list[str]:
                return re.findall(r'^LINK ' + re.escape(sign) + r' (.*?)\r?$', vm.text(), re.M)

            def wait_links(sign: str, n: int, timeout: float) -> bool:
                end = time.monotonic() + timeout
                while time.monotonic() < end:
                    if len(links(sign)) >= n:
                        return True
                    time.sleep(0.5)
                return False

            if nt4:
                # boot stick and replugged stick on hub port 1.3: a letter each, one removal
                check('nt4 stick 1.3 letters (boot, replug)', wait_links('+', 2, 30), str(links('+')))
                check('nt4 stick 1.3 unplug removed its letter once', len(links('-')) == 1, str(links('-')))
            # the hub with the stick goes: the stick behind it goes too
            vm.hmp('device_del hub1')
            check('hub 1 out takes stick 1.3 along', vm.wait(r'p5\.3:s\d+--S\(64M wp0 1v\).* p5\.3-gone.* p5-gone', 30))
            if nt4:
                ok = wait_links('-', 2, 30)
                check('nt4 hub unplug removed the stick letter once', ok and len(links('-')) == 2, str(links('-')))
            # a stick on a root port: in and out
            vm.hmp(f'drive_add 0 if=none,id=stick3,format=raw,file={stick.as_posix()}')
            vm.hmp('device_add usb-storage,bus=xhci.0,port=4,drive=stick3,id=s3,removable=on')
            check('stick root port 4 in', vm.wait(r' p4:s\d+--S\(64M wp0 1v\)', 60))
            if nt4:
                check('nt4 stick root port 4 letter', wait_links('+', 3, 30), str(links('+')))
            vm.hmp('device_del s3')
            check('stick root port 4 out', vm.wait(r'p4:s\d+--S\(64M wp0 1v\).* p4-gone', 30))
            if nt4:
                ok = wait_links('-', 3, 30)
                time.sleep(3)
                check('nt4 root port unplug removed the letter once', ok and len(links('-')) == 3, str(links('-')))
                arr, rem = vm.text().count('MNT arrive'), vm.text().count('MNT remove')
                check('nt4 mount queue: 3 arrivals, 3 removals', (arr, rem) == (3, 3), f'{arr}/{rem}')
                check('nt4 letters are \\DosDevices links to UsosUsbDiskN',
                      all(re.fullmatch(r'\\DosDevices\\[D-Z]: -> \\Device\\UsosUsbDisk\d+', l) for l in links('+')),
                      str(links('+')))
        print('DIAG', vm.diag(), flush=True)
    finally:
        vm.stop()
        (work / 'serial-copy.log').write_text(vm.text())
        if not a.keep:
            for p in (stick, kernel):
                try:
                    p.unlink()
                except OSError:
                    pass
    bad = [r for r in results if not r[1]]
    print(f'QEMU only ({a.variant}): {len(results) - len(bad)}/{len(results)} PASS; log {work / "serial-copy.log"}')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
