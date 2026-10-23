#!/usr/bin/env python3
"""Windows 3.1 Winsock VM through the existing USOS install flow.

Copyright (C) 2026 Maksymilian and the USOS Authors
SPDX-License-Identifier: GPL-3.0-or-later

All VM files belong in --out on a scratch drive. --build-root supplies only
read-only dependencies. No private FAT formatter, boot sector, AUTOEXEC,
CONFIG, WIN.INI edits or deletion of ADD852 are used. Installation calls
run_w9x_micro_linux_qemu.install (dos_csmwrap_target -> INSTALL -> W3AUTO).
Only closed test overlays receive a test application argument in W3AUTO and
/Q in NETSTART. Linux mounts are exclusively the supplied file-backed disk.
"""
from pathlib import Path
from types import SimpleNamespace
import argparse
import base64
import hashlib
import json
import os
import socket
import subprocess
import sys
import threading

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/tests'))
import run_nt3_micro_linux_qemu as nt3
import run_w9x_micro_linux_qemu as w9x


def command(args):
    return subprocess.run([str(x) for x in args], check=True, capture_output=True)


def linux(args, disk, tag, script, files=None):
    out = args.out / tag
    out.mkdir(parents=True, exist_ok=True)
    body = ("#!/bin/sh\nexport PATH=/usr/sbin:/usr/bin:/sbin:/bin\n"
            "/bin/busybox --install -s 2>/dev/null\n"
            "mount -t proc proc /proc; mount -t sysfs sys /sys\n"
            "mount -t devtmpfs dev /dev 2>/dev/null\n"
            "for m in ata_piix sd_mod vfat fat nls_cp437 nls_iso8859_1; do modprobe $m 2>/dev/null; done\n"
            "sleep 2; mdev -s 2>/dev/null; mkdir -p /target\n"
            "if mount -t vfat /dev/sda1 /target; then\n" + script +
            "\numount /target; sync; echo WS-LINUX-DONE\n"
            "else echo WS-LINUX-FAIL; fi\npoweroff -f\n")
    entries = [('ws.sh', 0o100755, body.encode()), ('ws', 0o040755, b'')]
    for name, data in (files or {}).items():
        entries.append(('ws/' + name, 0o100644, data))
    initrd = out / 'initrd.cpio'
    prefix = (args.build_root / 'zig-out/micro-linux/initramfs-usos').read_bytes()
    initrd.write_bytes(prefix + bytes(-len(prefix) % 4) + nt3.cpio_newc(entries))
    cmd = [args.qemu, '-machine', 'pc', '-accel', 'whpx', '-accel', 'tcg',
           '-m', '512', '-display', 'none', '-nic', 'none', '-monitor', 'none',
           '-kernel', args.build_root / 'zig-out/micro-linux/vmlinuz-virt',
           '-initrd', initrd, '-append', 'console=ttyS0,115200 rdinit=/ws.sh loglevel=3',
           '-serial', 'stdio', '-drive', f'file={disk.as_posix()},format=qcow2,if=ide']
    result = subprocess.run([str(x) for x in cmd], capture_output=True, timeout=240)
    (out / 'console.log').write_bytes(result.stdout + result.stderr)
    if b'WS-LINUX-DONE' not in result.stdout:
        raise RuntimeError('Linux disk operation failed: ' + str(out))
    return result.stdout


def boot(args, disk, tag, seconds, marker=None):
    """Wait for serial completion; one final screenshot, never progress polls."""
    out = args.out / tag
    out.mkdir(parents=True, exist_ok=True)
    port = nt3.free_port()
    cmd = [str(args.qemu), '-machine', 'pc,smm=off,vmport=off', '-accel', 'tcg',
           '-cpu', 'pentium3', '-m', '64', '-display', 'none', '-vga', 'std',
           '-netdev', 'user,id=net0', '-device', 'igb,netdev=net0',
           '-object', f'filter-dump,id=cap,netdev=net0,file={(out/"network.pcap").as_posix()}',
           '-monitor', f'tcp:127.0.0.1:{port},server=on,wait=off',
           '-serial', 'stdio', '-drive', f'file={disk.as_posix()},format=qcow2,if=ide,index=0']
    (out / 'command.json').write_text(json.dumps(cmd, indent=2))
    log = (out / 'serial.log').open('wb')
    stderr = (out / 'qemu.log').open('wb')
    q = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=stderr)
    (out / 'pid.txt').write_text(str(q.pid))
    completed = threading.Event()
    def reader():
        for line in iter(q.stdout.readline, b''):
            log.write(line); log.flush()
            if marker and marker.encode() in line:
                completed.set()
    t = threading.Thread(target=reader, daemon=True); t.start()
    # Bounded initial installation experiment, or actual serial completion.
    completed.wait(seconds)
    mon = socket.create_connection(('127.0.0.1', port), timeout=10)
    mon.settimeout(10)
    mon.recv(4096)
    transcript = bytearray()
    for line in ('stop', 'screendump "' + (out/'final.ppm').as_posix() + '"'):
        mon.sendall((line + '\n').encode())
        data = b''
        while not data.endswith(b'(qemu) '):
            part = mon.recv(65536)
            if not part: raise RuntimeError('HMP closed during command')
            data += part
        transcript.extend(data)
    mon.sendall(b'quit\n')
    try:
        while mon.recv(65536): pass
    except ConnectionError:
        pass
    mon.close()
    try:
        q.wait(30)
    except subprocess.TimeoutExpired:
        q.kill(); q.wait(10)
        raise
    finally:
        t.join(5); log.close(); stderr.close()
    (out/'hmp.log').write_bytes(transcript)
    from PIL import Image
    Image.open(out/'final.ppm').save(out/'final.png')
    (out/'final.ppm').unlink()
    return completed.is_set()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('mode', choices=['prepare', 'install', 'test'])
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--build-root', type=Path, required=True)
    p.add_argument('--qemu', type=Path, required=True)
    p.add_argument('--dos-iso', type=Path)
    p.add_argument('--win-iso', type=Path)
    p.add_argument('--case', choices=['queue', 'nodriver', 'nodll', 'gethttp'], default='queue')
    p.add_argument('--tag', help='Unique overlay/evidence name for a revised test')
    p.add_argument('--seconds', type=int, default=300)
    args = p.parse_args(); args.out.mkdir(parents=True, exist_ok=True)
    nt3.set_root(args.build_root)
    img = args.qemu.with_name('qemu-img.exe')
    target = args.out / 'target.qcow2'
    if args.mode == 'prepare':
        if target.exists():
            raise SystemExit('Refusing to overwrite installation; use its base/overlay')
        command([img, 'create', '-f', 'qcow2', target, '1G'])
        prep = SimpleNamespace(root=args.build_root, scripts=True, qemu=args.qemu,
            family='w3', iso=None, dos_iso=args.dos_iso, win3=args.win_iso,
            nvme=False, outer_mb=1536, timeout=600, env=[])
        # Use committed installer scripts from this branch, not newer donor scripts.
        mapping={'INSTALL.BAT':'install.cmd', 'W3START.BAT':'windows_start.cmd',
                 'WINMENU.BAT':'windows_menu.cmd', 'W3AUTO.BAT':'windows_auto.cmd'}
        replacements = []
        for binary, source in mapping.items():
            a=(args.build_root/'zig-out/dos-native/msdos'/binary).read_bytes().replace(b'\r\n',b'\n')
            b=(ROOT/'src/platform/bios/msdos'/source).read_bytes().replace(b'\r\n',b'\n')
            if a != b:
                replacements.append(('usos-e2e/esp/EFI/USOS/dos-native/msdos/' + binary,
                                     0o100644, b.replace(b'\n', b'\r\n')))
        original_overlay = w9x.overlay
        w9x.overlay = lambda a: original_overlay(a) + nt3.cpio_newc(replacements)
        if not w9x.install(prep, args.out, target):
            raise SystemExit('USOS preparation failed')
    elif args.mode == 'install':
        if (args.out/'base.qcow2').exists():
            raise SystemExit('Already installed; do not reinstall')
        boot(args, target, 'install', args.seconds)
        raw = linux(args, target, 'install-check',
            "test -f /target/USOSW3/MENU.TAG && test -f /target/WINDOWS/WIN.COM && echo WS-INSTALL-PASS\n"
            "find /target -maxdepth 2 -type f | head -n 30\n")
        if b'WS-INSTALL-PASS' not in raw:
            raise SystemExit('Installation incomplete; retained for diagnosis')
        command([img, 'snapshot', '-c', 'base', target])
        target.rename(args.out/'base.qcow2')
    else:
        base = args.out/'base.qcow2'
        tag = args.tag or args.case
        disk = args.out/(tag+'.qcow2')
        if disk.exists():
            raise SystemExit('Case overlay exists; use a distinct output name')
        command([img, 'create', '-f', 'qcow2', '-F', 'qcow2', '-b', base, disk])
        artifact = ROOT/'zig-out/win16'
        files = {'WINSOCK.DLL':(artifact/'WINSOCK.DLL').read_bytes(),
                 'TESTLOAD.EXE':(artifact/'TESTLOAD.EXE').read_bytes(),
                 'USOSPKTQ.COM':(artifact/'USOSPKTQ.COM').read_bytes()}
        app = 'GETHTTP' if args.case == 'gethttp' else 'TESTLOAD'
        if app == 'GETHTTP': files['GETHTTP.EXE']=(artifact/'GETHTTP.EXE').read_bytes()
        (args.out/(tag+'-inputs.json')).write_text(json.dumps({
            'case': args.case, 'base_snapshot': 'base',
            'sha256': {name: hashlib.sha256(data).hexdigest() for name, data in files.items()}
        }, indent=2))
        script = "mkdir -p /target/TEST\ncp /ws/*.EXE /target/WINDOWS/\n"
        script += "rm -f /target/WSTEST.LOG /target/WSDIAG.LOG /target/GETHTTP.LOG /target/GETHTTP.RSP /target/TEST/WINSOCK.DLL /target/WINDOWS/WINSOCK.DLL /target/WINDOWS/SYSTEM/WINSOCK.DLL\n"
        if args.case != 'nodll': script += "cp /ws/WINSOCK.DLL /target/WINDOWS/SYSTEM/\n"
        if args.case != 'nodriver':
            script += "cp /ws/USOSPKTQ.COM /target/NET/USOSPKT.COM\nsed -i 's@USOSPKT.COM 0x60@USOSPKT.COM /Q 0x60@' /target/NET/NETSTART.BAT\n"
        else:
            script += "mv /target/NET/NETSTART.BAT /target/NET/NETSTART.OFF\n"
        script += "sed -i 's@WIN.COM /S /B@WIN.COM /S /B "+app+".EXE@' /target/AUTOEXEC.BAT\n"
        script += "printf '\r\nECHO WS-APP-DONE>COM1\r\n' >> /target/AUTOEXEC.BAT\n"
        linux(args, disk, tag+'-stage', script, files)
        done = boot(args, disk, tag+'-run', args.seconds, 'WS-APP-DONE')
        raw = linux(args, disk, tag+'-read',
            "for n in WSTEST.LOG WSDIAG.LOG GETHTTP.LOG GETHTTP.RSP NET/USOSPKT.LOG NET/DHCP.LOG; do if test -f /target/$n; then echo WS-FILE:$n; base64 /target/$n; echo WS-FILE-END; fi; done\n")
        (args.out/(tag+'-result.txt')).write_bytes(raw)
        print('APP_RETURNED', done)
        extracted = {}
        for block in raw.replace(b'\r', b'').split(b'WS-FILE:')[1:]:
            name, _, content = block.partition(b'\n')
            extracted[name.decode()] = base64.b64decode(content.split(b'WS-FILE-END')[0])
        evidence = args.out / (tag+'-files')
        evidence.mkdir()
        for name, content in extracted.items():
            (evidence/name.replace('/', '-')).write_bytes(content)
        result = extracted.get('GETHTTP.LOG' if app == 'GETHTTP' else 'WSTEST.LOG', b'')
        print(result.decode('ascii', errors='replace'))
        if args.case == 'queue':
            passed = (b'name=0 ordinal=0 USOS WINSOCK OK' in result and
                      b'desc=USOS Winsock 1.1 (Win16)' in result)
        elif args.case == 'nodriver':
            passed = b'name=10091 ordinal=10091' in result
        elif args.case == 'nodll':
            passed = b'err=load:' in result and b'missing-export' not in result
        else:
            response = extracted.get('GETHTTP.RSP', b'')
            passed = (b'PASS HTTP 200' in result and len(response) > 12 and
                      response.startswith((b'HTTP/1.0 200', b'HTTP/1.1 200')))
            headers, separator, body = response.partition(b'\r\n\r\n')
            passed = passed and bool(separator)
            for header in headers.split(b'\r\n'):
                if header.lower().startswith(b'content-length:'):
                    passed = passed and len(body) == int(header.split(b':', 1)[1])
        (args.out/(tag+'-verdict.json')).write_text(json.dumps({
            'pass': passed, 'app_returned': done, 'case': args.case,
            'files': {n: {'bytes': len(d), 'sha256':hashlib.sha256(d).hexdigest()}
                      for n, d in extracted.items()}}, indent=2))
        if not passed: return 1
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
