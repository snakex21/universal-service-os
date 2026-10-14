#!/usr/bin/env python3
"""usosmpart (USB multi-partition disk filter) in QEMU, dev PC only.

  stick   --out X.img --layout mbr3|gpt3|mbr1 [--file F ...]
          raw USB stick image: three (or one) FAT16 partitions of 64 MiB,
          labels MP1 MP2 MP3; the files go into every partition's root.
          gpt3 = the USOS stick's shape (ESP type + two basic data).
  prepare-xp --iso XP.iso --out DIR [--profile P]
          the XP package's real preparation chain (run_seabios_xp_uefi_csm_
          textmode.prepare) with this tree's prepare_xp_ntfs_target.sh,
          nt5_usosmpart_stage.sh and tools/nt/usosmpart/bin, on a blank
          12 GiB target (DIR/target.qcow2).
  vm      --disk D.qcow2 --port N [--machine pc] [--usb ehci|xhci]
          [--stick X.img] [--cdrom ISO] [--floppy IMG] [--accel whpx|tcg]
          [--mem 2048]
          starts QEMU in the background with a QMP socket on 127.0.0.1:N; the
          stick (if given) is plugged as usb-storage id=stick.
  qmp     --port N CMD...
          shot FILE | type TEXT | key K[,K..] | plug IMG [fixed] [hub] | unplug | click X Y W H |
          quit | hmp TEXT
          one QMP action against a running vm.

The QEMU binary: USOS_QEMU_DIR (default the main checkout's tools\\qemu).
Scratch images only; no physical disk. Stop QEMU with `qmp quit` (never by
image name). Delete the images afterwards.
"""
from __future__ import annotations

import argparse
import gzip
import json
import os
import socket
import stat
import struct
import subprocess
import sys
import time
import uuid
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
QEMU_DIR = Path(os.environ.get('USOS_QEMU_DIR', r'C:\Users\ASRock\Desktop\Universal_Service_OS\tools\qemu'))
QEMU = QEMU_DIR / 'qemu-system-x86_64.exe'
QEMU_IMG = QEMU_DIR / 'qemu-img.exe'

SECTOR = 512
PART_SECTORS = 64 * 2048


def lfn_entries(name: str, short: bytes) -> bytes:
    """VFAT long-name entries (last first) for a root entry with SHORT."""
    csum = 0
    for b in short:
        csum = (((csum & 1) << 7) + (csum >> 1) + b) & 0xFF
    units = [ord(c) for c in name] + [0]
    units += [0xFFFF] * (-len(units) % 13)
    parts = [units[i:i + 13] for i in range(0, len(units), 13)]
    out = bytearray()
    for n in range(len(parts), 0, -1):
        u = parts[n - 1]
        e = bytearray(32)
        e[0] = n | (0x40 if n == len(parts) else 0)
        e[11], e[13] = 0x0F, csum
        for i, v in enumerate(u):
            off = (1 + 2 * i) if i < 5 else (14 + 2 * (i - 5)) if i < 11 else (28 + 2 * (i - 11))
            struct.pack_into('<H', e, off, v)
        out += e
    return bytes(out)


def fat16_volume(sectors: int, label: str, files: dict[str, bytes]) -> bytearray:
    """A FAT16 volume (8.3 names in the root), hidden sectors patched later."""
    spc, reserved, fats, root_entries = 4, 1, 2, 512
    clusters = sectors // spc
    fat_sectors = (clusters * 2 + SECTOR - 1) // SECTOR + 1
    root_sectors = root_entries * 32 // SECTOR
    data_start = reserved + fats * fat_sectors + root_sectors
    vol = bytearray(sectors * SECTOR)
    boot = bytearray(SECTOR)
    boot[0:3] = b'\xEB\x3C\x90'
    boot[3:11] = b'USOSMPT '
    struct.pack_into('<HBHBHHBHHHII', boot, 11, SECTOR, spc, reserved, fats, root_entries,
                     0 if sectors > 0xFFFF else sectors, 0xF8, fat_sectors, 63, 255, 0,
                     sectors if sectors > 0xFFFF else 0)
    boot[36], boot[38] = 0x80, 0x29
    boot[39:43] = struct.pack('<I', zlib.crc32(label.encode()))
    boot[43:54] = label.encode().ljust(11)
    boot[54:62] = b'FAT16   '
    boot[510:512] = b'\x55\xAA'
    vol[0:SECTOR] = boot
    fat = [0xFFF8, 0xFFFF]
    root = bytearray()
    entry = bytearray(32)
    entry[0:11] = label.encode().ljust(11)
    entry[11] = 0x08
    root += entry
    for name, data in files.items():
        stem, _, ext = name.upper().partition('.')
        first = len(fat) if data else 0
        count = (len(data) + spc * SECTOR - 1) // (spc * SECTOR)
        for i in range(count):
            fat.append(len(fat) + 1 if i < count - 1 else 0xFFFF)
            off = (data_start + (first + i - 2) * spc) * SECTOR
            chunk = data[i * spc * SECTOR:(i + 1) * spc * SECTOR]
            vol[off:off + len(chunk)] = chunk
        e = bytearray(32)
        if len(stem) > 8 or len(ext) > 3 or name != name.upper():
            short = (stem[:6] + '~1').ljust(8).encode() + ext[:3].ljust(3).encode()
            root += lfn_entries(name, short)
            e[0:11] = short
        else:
            e[0:11] = stem.ljust(8).encode()[:8] + ext.ljust(3).encode()[:3]
        e[11] = 0x20
        struct.pack_into('<HI', e, 26, first, len(data))
        root += e
    fat_bytes = b''.join(struct.pack('<H', v) for v in fat)
    for i in range(fats):
        off = (reserved + i * fat_sectors) * SECTOR
        vol[off:off + len(fat_bytes)] = fat_bytes
    off = (reserved + fats * fat_sectors) * SECTOR
    vol[off:off + len(root)] = root
    return vol


def stick(out: Path, layout: str, files: list[Path]) -> None:
    payload = {f.name: f.read_bytes() for f in files}
    count = 1 if layout == 'mbr1' else 3
    start = 2048
    total = start + count * PART_SECTORS + 2048
    disk = bytearray(total * SECTOR)
    starts = [start + i * PART_SECTORS for i in range(count)]
    for i, lba in enumerate(starts):
        vol = fat16_volume(PART_SECTORS, 'MP%d' % (i + 1), payload)
        struct.pack_into('<I', vol, 28, lba)
        disk[lba * SECTOR:(lba + PART_SECTORS) * SECTOR] = vol
    mbr = bytearray(SECTOR)
    mbr[440:444] = struct.pack('<I', 0x55534F53)
    if layout.startswith('mbr'):
        for i, lba in enumerate(starts):
            mbr[446 + 16 * i:462 + 16 * i] = bytes([0, 0xFE, 0xFF, 0xFF, 0x06, 0xFE, 0xFF, 0xFF]) + struct.pack('<II', lba, PART_SECTORS)
    else:
        mbr[446:462] = bytes([0, 0, 2, 0, 0xEE, 0xFF, 0xFF, 0xFF]) + struct.pack('<II', 1, min(total - 1, 0xFFFFFFFF))
        esp = uuid.UUID('C12A7328-F81F-11D2-BA4B-00A0C93EC93B').bytes_le
        data = uuid.UUID('EBD0A0A2-B9E5-4433-87C0-68B6B72699C7').bytes_le
        entries = bytearray(128 * 128)
        for i, lba in enumerate(starts):
            e = bytearray(128)
            e[0:16] = esp if i == 0 else data
            e[16:32] = uuid.uuid4().bytes_le
            struct.pack_into('<QQ', e, 32, lba, lba + PART_SECTORS - 1)
            e[56:56 + 2 * len('MP%d' % (i + 1))] = ('MP%d' % (i + 1)).encode('utf-16-le')
            entries[i * 128:(i + 1) * 128] = e
        ecrc = zlib.crc32(entries) & 0xFFFFFFFF

        def header(cur: int, backup: int, elba: int) -> bytes:
            h = bytearray(92)
            h[0:8] = b'EFI PART'
            struct.pack_into('<IIIIQQQQ16sQIII', h, 8, 0x00010000, 92, 0, 0, cur, backup, 34, total - 34,
                             uuid.uuid4().bytes_le, elba, 128, 128, ecrc)
            struct.pack_into('<I', h, 16, zlib.crc32(h) & 0xFFFFFFFF)
            return bytes(h).ljust(SECTOR, b'\0')
        disk[SECTOR:2 * SECTOR] = header(1, total - 1, 2)
        disk[2 * SECTOR:34 * SECTOR] = entries
        disk[(total - 33) * SECTOR:(total - 1) * SECTOR] = entries
        disk[(total - 1) * SECTOR:total * SECTOR] = header(total - 1, 1, total - 33)
    mbr[510:512] = b'\x55\xAA'
    disk[0:SECTOR] = mbr
    out.write_bytes(disk)
    print('stick', out, layout, '%d MiB' % (len(disk) >> 20))


def prepare_xp(iso: Path, out: Path, profile: str) -> None:
    sys.path.insert(0, str(HERE / 'legacy_bios'))
    import run_seabios_xp_uefi_csm_textmode as tm
    tm.QEMU, tm.QEMU_IMG, tm.SEABIOS = QEMU, QEMU_IMG, QEMU_DIR / 'share/bios-256k.bin'
    extra = {'usr/lib/usos/nt5-usosmpart/i386/usosmpart.sys': (ROOT / 'tools/nt/usosmpart/bin/i386/usosmpart.sys').read_bytes(),
             'usr/lib/usos/nt5-usosmpart/amd64/usosmpart.sys': (ROOT / 'tools/nt/usosmpart/bin/amd64/usosmpart.sys').read_bytes()}
    parse = tm.cpio.parse_newc

    def parse_plus(data):
        entries = parse(data)
        for name, blob in extra.items():
            tm.cpio.put(entries, tm.cpio.Entry(name, stat.S_IFREG | 0o644, blob))
        return entries
    tm.cpio.parse_newc = parse_plus
    out.mkdir(parents=True, exist_ok=True)
    target = tm.prepare(out, iso, profile=profile, tree_scripts=('prepare_xp_ntfs_target.sh', 'nt5_usosmpart_stage.sh'))
    log = (out / 'prepare-serial.log').read_text(errors='replace')
    for line in log.splitlines():
        if 'NT5_MPART' in line or 'RESULT' in line:
            print(line)
    (out / 'usos-blank.qcow2').unlink(missing_ok=True)
    print('target', target)


def vm(a) -> None:
    ich9 = ['-device', 'ich9-usb-ehci1,id=usb,addr=1d.7,multifunction=on',
            '-device', 'ich9-usb-uhci1,masterbus=usb.0,firstport=0,addr=1d.0,multifunction=on',
            '-device', 'ich9-usb-uhci2,masterbus=usb.0,firstport=2,addr=1d.1,multifunction=on',
            '-device', 'ich9-usb-uhci3,masterbus=usb.0,firstport=4,addr=1d.2,multifunction=on']
    # ich9hub: EHCI + UHCI companions and a usb-hub on port 2 (sticks go to
    # its port 2.1 with `plug IMG hub`): a hub port reports the device as
    # removable, as a front-panel / external port does.
    usb = {'ehci': ['-device', 'usb-ehci,id=usb'], 'xhci': ['-device', 'qemu-xhci,id=usb'],
           'ich9hub': ich9 + ['-device', 'usb-hub,id=hub1,bus=usb.0,port=2']}[a.usb]
    accel = (['-accel', 'whpx,kernel-irqchip=off', '-cpu', 'qemu64,+ssse3,+sse4.1,+sse4.2,+popcnt'] if a.accel == 'whpx'
             else ['-accel', 'tcg,thread=multi', '-cpu', 'max'])
    cmd = [str(QEMU), '-machine', a.machine, *accel, '-m', str(a.mem), '-smp', '2', '-rtc', 'base=localtime',
           '-qmp', 'tcp:127.0.0.1:%d,server,nowait' % a.port, '-display', 'none', '-vga', 'std', '-nic', 'none',
           '-drive', 'if=ide,index=0,format=qcow2,cache=writeback,file=' + str(a.disk), *usb,
           '-device', 'usb-tablet,bus=usb.0' + (',port=1' if a.usb == 'ich9hub' else '')]
    if a.cdrom:
        cmd += ['-drive', 'if=ide,index=2,media=cdrom,readonly=on,file=' + str(a.cdrom)]
    if a.floppy:
        cmd += ['-drive', 'if=floppy,index=0,format=raw,file=' + str(a.floppy)]
    if a.stick:
        cmd += ['-drive', 'if=none,id=stickdrv,format=raw,cache=writethrough,file=' + str(a.stick),
                '-device', 'usb-storage,bus=usb.0,id=stick,drive=stickdrv,removable=on' + (',port=2.1' if a.usb == 'ich9hub' else '')]
    if a.boot:
        cmd += ['-boot', a.boot]
    log = open(str(a.disk) + '.qemu.log', 'ab')
    p = subprocess.Popen(cmd, stdout=log, stderr=log, creationflags=getattr(subprocess, 'CREATE_NEW_PROCESS_GROUP', 0))
    Path(str(a.disk) + '.pid').write_text(str(p.pid))
    print('qemu pid', p.pid, 'qmp port', a.port)


class Qmp:
    def __init__(self, port: int):
        self.s = socket.create_connection(('127.0.0.1', port), timeout=30)
        self.f = self.s.makefile('rwb')
        self.f.readline()
        self.cmd('qmp_capabilities')

    def cmd(self, name: str, **args):
        self.f.write(json.dumps({'execute': name, 'arguments': args} if args else {'execute': name}).encode() + b'\n')
        self.f.flush()
        while True:
            r = json.loads(self.f.readline())
            if 'return' in r or 'error' in r:
                if 'error' in r:
                    raise SystemExit('QMP %s: %s' % (name, r['error']))
                return r['return']


KEYS = {' ': 'spc', '\n': 'ret', '\\': 'backslash', ':': 'shift-semicolon', '.': 'dot', '-': 'minus', '/': 'slash',
        '>': 'shift-dot', '"': 'shift-apostrophe', '_': 'shift-minus', '=': 'equal', ',': 'comma', '*': 'shift-8', '%': 'shift-5', '&': 'shift-7', '|': 'shift-backslash', '(': 'shift-9', ')': 'shift-0',
        '<': 'shift-comma', '?': 'shift-slash', "'": 'apostrophe', ';': 'semicolon', '$': 'shift-4', '!': 'shift-1'}


def keyseq(text: str):
    for ch in text:
        if ch.isalpha():
            yield ('shift-' + ch.lower()) if ch.isupper() else ch
        elif ch.isdigit():
            yield ch
        else:
            yield KEYS[ch]


def send_key(q: Qmp, combo: str):
    q.cmd('send-key', keys=[{'type': 'qcode', 'data': k} for k in combo.split('-')])


def qmp(a) -> None:
    q = Qmp(a.port)
    op = a.cmd[0]
    if op == 'shot':
        # HMP: the QMP command returned before the file existed in one run.
        target = Path(a.cmd[1]).resolve()
        target.unlink(missing_ok=True)
        q.cmd('human-monitor-command', **{'command-line': 'screendump %s -f png' % target.as_posix()})
        # With -display none the dump completes on a later display update;
        # keep the monitor busy until the file is there.
        for _ in range(40):
            if target.exists() and target.stat().st_size:
                break
            time.sleep(0.25)
            q.cmd('query-status')
    elif op == 'type':
        for k in keyseq(' '.join(a.cmd[1:])):
            send_key(q, k)
            time.sleep(0.05)
    elif op == 'key':
        for combo in a.cmd[1].split(','):
            send_key(q, combo)
            time.sleep(0.2)
    elif op == 'plug':
        q.cmd('blockdev-add', **{'node-name': 'stick2', 'driver': 'raw',
                                  'file': {'driver': 'file', 'filename': str(Path(a.cmd[1]).resolve()), 'cache': {'direct': False}}})
        opts = a.cmd[2:]
        dev = dict(driver='usb-storage', id='stick', drive='stick2', bus='usb.0', removable='fixed' not in opts)
        if 'hub' in opts:
            dev['port'] = '2.1'   # the usb-hub of `vm --usb ich9hub`
        q.cmd('device_add', **dev)
    elif op == 'unplug':
        q.cmd('device_del', id='stick')
        time.sleep(2)
        for node in ('stick2', 'stickdrv'):
            try:
                q.cmd('blockdev-del', **{'node-name': node})
            except SystemExit:
                pass
    elif op == 'click':
        # click X Y W H: left click at pixel (X, Y) of a W x H screen (usb-tablet).
        x, y, w, h = (int(v) for v in a.cmd[1:5])
        ax, ay = x * 32767 // (w - 1), y * 32767 // (h - 1)
        q.cmd('input-send-event', events=[{'type': 'abs', 'data': {'axis': 'x', 'value': ax}},
                                          {'type': 'abs', 'data': {'axis': 'y', 'value': ay}}])
        time.sleep(0.2)
        for down in (True, False):
            q.cmd('input-send-event', events=[{'type': 'btn', 'data': {'down': down, 'button': 'left'}}])
            time.sleep(0.1)
    elif op == 'hmp':
        print(q.cmd('human-monitor-command', **{'command-line': ' '.join(a.cmd[1:])}))
    elif op == 'quit':
        q.cmd('quit')
    else:
        raise SystemExit('unknown qmp op ' + op)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='op', required=True)
    s = sub.add_parser('stick')
    s.add_argument('--out', type=Path, required=True)
    s.add_argument('--layout', choices=('mbr3', 'gpt3', 'mbr1'), default='mbr3')
    s.add_argument('--file', type=Path, action='append', default=[])
    s = sub.add_parser('prepare-xp')
    s.add_argument('--iso', type=Path, required=True)
    s.add_argument('--out', type=Path, required=True)
    s.add_argument('--profile', default='xp-x86-sp3-uefi-csm')
    s = sub.add_parser('vm')
    s.add_argument('--disk', type=Path, required=True)
    s.add_argument('--port', type=int, required=True)
    s.add_argument('--machine', default='pc')
    s.add_argument('--usb', choices=('ehci', 'xhci', 'ich9hub'), default='ehci')
    s.add_argument('--stick', type=Path)
    s.add_argument('--cdrom', type=Path)
    s.add_argument('--floppy', type=Path)
    s.add_argument('--boot')
    s.add_argument('--accel', choices=('whpx', 'tcg'), default='whpx')
    s.add_argument('--mem', type=int, default=2048)
    s = sub.add_parser('qmp')
    s.add_argument('--port', type=int, required=True)
    s.add_argument('cmd', nargs='+')
    a = p.parse_args()
    if a.op == 'stick':
        stick(a.out, a.layout, a.file)
    elif a.op == 'prepare-xp':
        prepare_xp(a.iso, a.out, a.profile)
    elif a.op == 'vm':
        vm(a)
    else:
        qmp(a)


if __name__ == '__main__':
    main()
