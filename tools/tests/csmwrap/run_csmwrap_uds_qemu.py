"""QEMU protocol test of CSMWrap 3.1.2-usos16 patch 0021 (USB disk service, channel 1 of the
helper core) and 3.1.2-usos17 patch 0022 (hot-swap) without Windows: uds_mbr.S drives the channel
from real mode the way the Windows 9x miniport USOSUSB.MPD does from ring 0
(docs/usb9x-hotswap-design-2026-10-19.md, test plan).

Disks: the boot disk on -device nvme (uds_mbr.S in LBA 0-7, FAT16 ESP with EFI/BOOT/BOOTX64.EFI =
the CSMWrap under test, csmwrap.ini serial + verbose), a 64 MiB stick on qemu-xhci usb-storage
(removable=on; LBA 0 starts with "UDSTICK0", LBA 256.. a 64 KiB block starting with "UBIG").
OVMF without CSM, TCG, 2 vCPUs (the helper core). free mode: a usb-kbd and a usb-mouse on the
same qemu-xhci, i8042 off (keys reach INT 16h only through the USB keyboard). The sticks are
-blockdev nodes, so they survive device_del and can be plugged again.

  free   csmwrap.ini int13_boot_disk_only = true: the stick has no BIOS number. All markers up to
         UDS-GONE2: ENUM, INQUIRY, READ, WRITE + READ back across 64 KiB boundaries, 64 KiB reads,
         BADREQ, STATUS record, CHECK + sense, then QMP device_del of the stick while 64 KiB reads
         run -> GONE (latency measured on the host), GONE again at once, ENUM state 2. The host
         checks LBA 64-79 of the stick image = the MBR's pattern.
         usos17 (the MBR expects record version 2, so a usos16 binary fails at UDS-STAT): then the keyboard ('a'), stick 2
         (32 MiB, "UDSTICK1") plugged -> a new generation in entry 0, its capacity and sector 0;
         stick 2 out and stick 1 in within one QMP write -> a new generation, "UDSTICK0"; EJECT;
         6 unplug / replug cycles; the keyboard again ('b').
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
HOTSWAP = ('UDS-KEY1?', 'UDS-KBD1', 'UDS-PLUG?', 'UDS-NEW', 'UDS-FAST?', 'UDS-FAST', 'UDS-EJECT', 'UDS-CYC?',
           'UDS-CYC', 'UDS-KEY2?', 'UDS-KBD2', 'UDS-REC')
CYCLES = 6
OWNED = ('UDS-S', 'UDS-CH', 'UDS-ENUM', 'UDS-OWNED')


def assemble(zig: Path, tmp: Path) -> bytes:
    obj, binf = tmp / 'uds_mbr.o', tmp / 'uds_mbr.bin'
    subprocess.run([str(zig), 'cc', '-target', 'x86-freestanding-none', '-c', str(HERE / 'uds_mbr.S'),
                    '-o', str(obj)], check=True)
    subprocess.run([str(zig), 'ld.lld', '-m', 'elf_i386', '--oformat=binary', '--image-base=0', '-Ttext=0x7c00',
                    '-e', '_start', str(obj), '-o', str(binf)], check=True)
    code = binf.read_bytes()
    assert len(code) == 0x2000, len(code)
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


def make_disks(boot: Path, stick: Path, stick2: Path, code: bytes, efi: bytes, only: bool) -> None:
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
    # stick 1: a volume without a partition table ("FAT32" at 52h, 55AAh);
    # stick 2: an MBR with an NTFS partition at LBA 2048 (the media check)
    s0 = bytearray(b'UDSTICK0' + bytes(SECTOR - 8))
    s0[82:90] = b'FAT32   '
    s0[510:512] = b'\x55\xaa'
    with open(stick, 'wb') as f:
        f.truncate(STICK_SECTORS * SECTOR)
        f.write(s0)
        f.seek(256 * SECTOR)
        f.write(big_block())
    s1 = bytearray(b'UDSTICK1' + bytes(SECTOR - 8))
    s1[446:462] = bytes([0, 0, 0, 0, 7, 0, 0, 0]) + (2048).to_bytes(4, 'little') + (4096).to_bytes(4, 'little')
    s1[510:512] = b'\x55\xaa'
    vbr = bytearray(SECTOR)
    vbr[0:11] = b'\xebR\x90NTFS    '
    vbr[510:512] = b'\x55\xaa'
    with open(stick2, 'wb') as f:
        f.truncate(STICK_SECTORS // 2 * SECTOR)
        f.write(s1)
        f.seek(2048 * SECTOR)
        f.write(vbr)


def record_check(rec: bytes) -> str:
    """the USOSUDSK version 2 record after the run (src/platform/bios/win9x/usosuds.h)"""
    import struct
    if len(rec) != 984 or rec[:8] != b'USOSUDSK' or rec[8] != 2:
        return f'bad record ({len(rec)} bytes, {rec[:9]!r})'
    passes, att, det, fails = struct.unpack_from('<IIII', rec, 768)
    ctls, armed, pool_used, last_fail = rec[784:788]
    pool, = struct.unpack_from('<I', rec, 788)
    ports, ccs_post, busy_arm, ccs_now = struct.unpack_from('<IIII', rec, 792)
    fs, t0, t1, t2, t3, flags, ctl, attach, part_lba, hash0 = struct.unpack_from('<BBBBBBBBII', rec, 856)
    evs = [rec[640 + 8 * i + 6] for i in range(16)]
    why = []
    if not (armed == 1 and ctls == 1 and pool and pool_used == 1):
        why.append(f'armed {armed} ctls {ctls} pool {pool:x} used {pool_used}')
    if att != 2 + CYCLES or det < 1 + CYCLES or fails:
        why.append(f'attaches {att} detaches {det} fails {fails}/{last_fail}')
    if bin(busy_arm).count('1') != 3:   # keyboard, mouse and the POST stick had slots at arming
        why.append(f'busy_arm {busy_arm:x}')
    # last cycle (6th, even): stick 1, a FAT32 volume without a partition table
    if (fs, flags, attach, ctl, part_lba) != (5, 3, 1, 0, 0):
        why.append(f'media fs {fs} flags {flags} attach {attach} ctl {ctl} lba {part_lba}')
    if 11 not in evs or 16 not in evs:
        why.append(f'events {evs}')
    return ('ok' if not why else 'FAIL ' + '; '.join(why)) + (
        f' (passes {passes}, attaches {att}, detaches {det}, ports {ports}, ccs_post {ccs_post:x},'
        f' busy {busy_arm:x}, media fs {fs} types {t0:02x}{t1:02x}{t2:02x}{t3:02x} hash0 {hash0:08x})')


def run(root: Path, code: bytes, efi: bytes, mode: str, out: Path, minutes: float, hotswap: bool) -> bool:
    out.mkdir(parents=True, exist_ok=True)
    for f in ('debugcon.log', 'serial.log'):
        (out / f).unlink(missing_ok=True)
    boot, stick, stick2, vars_fd = out / 'boot.img', out / 'stick.img', out / 'stick2.img', out / 'vars.fd'
    make_disks(boot, stick, stick2, code, efi, mode == 'free')
    hot = mode == 'free' and hotswap
    vars_fd.write_bytes((root / 'tools/qemu/share/edk2-i386-vars.fd').read_bytes())
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        port = s.getsockname()[1]
    qemu = root / 'tools/qemu' / os.environ.get('USOS_QEMU_EXE', 'qemu-system-x86_64.exe')
    dbg_path = out / 'debugcon.log'
    cmd = [str(qemu), '-name', f'USOS-uds-{mode}', '-machine', os.environ.get('UDS_MACHINE', 'q35,i8042=off') if hot else 'q35',
           '-accel', 'tcg', '-cpu', 'max',
           '-smp', '2', '-m', '512', '-display', 'none', '-vga', 'std', '-nic', 'none',
           '-drive', f'if=pflash,format=raw,readonly=on,file={(root / "tools/qemu/share/edk2-x86_64-code.fd").as_posix()}',
           '-drive', f'if=pflash,format=raw,file={vars_fd.as_posix()}',
           '-debugcon', f'file:{dbg_path.as_posix()}', '-global', 'isa-debugcon.iobase=0x402',
           '-serial', f'file:{(out / "serial.log").as_posix()}', '-monitor', 'none',
           '-qmp', f'tcp:127.0.0.1:{port},server=on,wait=off',
           '-drive', f'if=none,id=d0,format=raw,file={boot.as_posix()}',
           '-device', 'nvme,serial=USOSUDS0,drive=d0,bootindex=0',
           '-device', 'qemu-xhci,id=xhci']
    if hot:
        cmd += ['-device', 'usb-kbd,bus=xhci.0,id=kbd', '-device', 'usb-mouse,bus=xhci.0,id=mouse']
    for node, img in (('stick', stick), ('stick2', stick2)):
        cmd += ['-blockdev', f'driver=file,filename={img.as_posix()},node-name={node}f',
                '-blockdev', f'driver=raw,file={node}f,node-name={node}']
    cmd += ['-device', 'usb-storage,bus=xhci.0,drive=stick,removable=on,id=stickdev']
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=open(out / 'qemu-stderr.log', 'wb'))
    events: list[str] = []
    unplug_at = gone_at = None
    done_marks: set[str] = set()
    cycles_done = 0
    current, serial_id = 'stickdev', 0

    def qmp(q, *cmds):
        q.sendall(b''.join(json.dumps(c).encode() + b'\n' for c in cmds))

    def add(drive):
        nonlocal serial_id
        serial_id += 1
        dev = f'hs{serial_id}'
        return dev, {'execute': 'device_add', 'arguments': {'driver': 'usb-storage', 'bus': 'xhci.0',
                                                            'drive': drive, 'removable': True, 'id': dev}}

    def key(k):
        return {'execute': 'send-key', 'arguments': {'keys': [{'type': 'qcode', 'data': k}]}}
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
            try:
                if hot and b' UDS-KEY1? ' in dbg and 'k1' not in done_marks:
                    done_marks.add('k1')
                    time.sleep(0.3)
                    qmp(q, key('a'))
                if hot and b' UDS-PLUG? ' in dbg and 'plug' not in done_marks:
                    done_marks.add('plug')
                    current, c = add('stick2')
                    qmp(q, c)
                if hot and b' UDS-FAST? ' in dbg and 'fast' not in done_marks:
                    done_marks.add('fast')
                    old = current
                    current, c = add('stick')
                    # out and in within one write: the port's CSC latch has to catch it
                    qmp(q, {'execute': 'device_del', 'arguments': {'id': old}}, c)
                if hot and dbg.count(b' UDS-CYC? ') > cycles_done:
                    cycles_done += 1
                    old = current
                    qmp(q, {'execute': 'device_del', 'arguments': {'id': old}})
                    time.sleep(0.4)
                    current, c = add('stick2' if cycles_done % 2 else 'stick')
                    qmp(q, c)
                if hot and b' UDS-KEY2? ' in dbg and 'k2' not in done_marks:
                    done_marks.add('k2')
                    time.sleep(0.3)
                    qmp(q, key('b'))
                if hot and b' UDS-REC ' in dbg and 'rec' not in done_marks:
                    done_marks.add('rec')
                    (out / 'udsk.bin').unlink(missing_ok=True)
                    qmp(q, {'execute': 'pmemsave', 'arguments': {'val': 0x13000, 'size': 984,
                                                                 'filename': (out / 'udsk.bin').as_posix()}})
            except OSError:
                break
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
    want = (FREE + (HOTSWAP if hot else ())) if mode == 'free' else OWNED
    marks = [m for m in want if f' {m} ' in dbg]
    failed = re.search(r' UDS-F[^ ] ', dbg)   # " UDS-F<step> ", not UDS-FREE / UDS-FAST
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
        ok = (ok and marks == list(want) and written == pattern() and latency is not None and latency < 3.0
              and probed)
        if hot:
            ok = ok and cycles_done == CYCLES and dbg.count(' UDS-CYC? ') == CYCLES
            rec = (out / 'udsk.bin').read_bytes() if (out / 'udsk.bin').exists() else b''
            check = record_check(rec)
            print(f'    record: {check}', flush=True)
            ok = ok and check.startswith('ok')
    else:
        # a stick INT 13h owns gets no UDS traffic at all (no probe)
        ok = ok and marks == list(OWNED) and not any(' cap ' in l for l in uds)
    print(f'[{mode}] {"PASS" if ok else "FAIL"} events={events} debugcon={dbg.strip()[-160:]!r} '
          f'unplug->gone={latency if latency is None else round(latency, 2)}s', flush=True)
    for l in uds:
        print(f'    {l}', flush=True)
    print(f'    hot-swap: {"on" if hot else "off"}, cycles {cycles_done}, QMP events {len(events)}', flush=True)
    for f in (boot, stick, stick2, vars_fd):
        f.unlink(missing_ok=True)
    return ok


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--root', type=Path, default=REPO)
    p.add_argument('--csmwrap-efi', type=Path, default=REPO / 'tools/vendor/csmwrap/3.1.2-usos17/csmwrapx64.efi')
    p.add_argument('--mode', action='append', choices=('free', 'owned'))
    p.add_argument('--minutes', type=float, default=8)
    a = p.parse_args()
    root = a.root.resolve()
    out = a.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    code = assemble(root / 'tools/zig/zig.exe', out)
    efi = a.csmwrap_efi.read_bytes()
    ok = True
    for mode in a.mode or ['free', 'owned']:
        ok &= run(root, code, efi, mode, out / mode, a.minutes, True)
    print('UDS-QEMU-' + ('PASS' if ok else 'FAIL'), flush=True)
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
