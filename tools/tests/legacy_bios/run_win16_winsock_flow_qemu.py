#!/usr/bin/env python3
"""Windows 3.1 + the answer-profile Winsock option through the USOS install flow.

Copyright (C) 2026 Maksymilian and the USOS Authors
SPDX-License-Identifier: GPL-3.0-or-later

QEMU only. Unlike run_win16_testload_qemu.py, nothing is copied into the
installed system by the test: the Winsock files reach the disk only through
the option (DOS.INI winsock=yes -> dos_csmwrap_target.sh -> dos_winsock_apply
-> INSTALL.BAT / Windows Setup / WINMENU.BAT).

  prepare  micro-Linux: dos_csmwrap_target.sh with MS-DOS 6.22 + the Windows
           ISO and a DOS.INI as src/flow/answer/dos.zig renders it for a
           Polish profile with dos_winsock=yes (DOS_WIN_SYSTEM=windows-3-1)
  install  boot the disk: INSTALL.BAT, batch Windows Setup, WINMENU.BAT; a
           serial marker after the menu step (test-only line in WINMENU.BAT),
           then a read-back of what the option staged; snapshot base
  show     overlay, plain boot of the default menu item, screenshot of
           Program Manager (the "USOS Winsock test" group)
  test     overlay, the default item runs WIN /S /B GETHTTP.EXE /EXIT from
           C:\\NET\\WIN16; verdict from C:\\NET\\WIN16\\GETHTTP.LOG/.RSP and
           the DOS DHCP lease

All VM files live in --out; --build-root supplies the built zig-out
(micro-linux, dos-native incl. winsock16, usb/EFI/USOS/csmwrap).
"""
from pathlib import Path
from types import SimpleNamespace
import argparse
import base64
import hashlib
import json
import re
import subprocess
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import run_win16_testload_qemu as ws  # noqa: E402

nt3 = ws.nt3
w9x = ws.w9x

# dos.zig render() for language=pl-PL, dos_winsock=yes.
DOS_INI = (b'; USOS MS-DOS / Windows 1.x-3.x regional settings (src/flow/answer/dos.zig)\r\n'
           b'[dos]\r\nmode=auto\r\ncountry=048\r\ncodepage=852\r\ncpi=EGA.CPI\r\nwinsock=yes\r\n')
LAN = 'user,id=net0,net=172.31.8.0/25,host=172.31.8.2,dhcpstart=172.31.8.15,dns=172.31.8.3'


def files_of(raw: bytes) -> dict:
    out = {}
    for block in raw.replace(b'\r', b'').split(b'WS-FILE:')[1:]:
        name, _, content = block.partition(b'\n')
        out[name.decode()] = base64.b64decode(content.split(b'WS-FILE-END')[0])
    return out


def dump(names) -> str:
    return ('for n in ' + ' '.join(names) + '; do if test -f "/target/$n"; then '
            'echo "WS-FILE:$n"; base64 "/target/$n"; echo WS-FILE-END; fi; done\n')


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('mode', choices=['prepare', 'install', 'show', 'test'])
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--build-root', type=Path, required=True)
    p.add_argument('--qemu', type=Path, required=True)
    p.add_argument('--dos-iso', type=Path)
    p.add_argument('--win-iso', type=Path)
    p.add_argument('--seconds', type=int, default=3000)
    args = p.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    nt3.set_root(args.build_root)
    img = args.qemu.with_name('qemu-img.exe')
    target = args.out / 'target.qcow2'
    base = args.out / 'base.qcow2'
    vm = SimpleNamespace(out=args.out, build_root=args.build_root, qemu=args.qemu, netdev=LAN)

    if args.mode == 'prepare':
        if target.exists() or base.exists():
            raise SystemExit('Refusing to overwrite an installation')
        ws.command([img, 'create', '-f', 'qcow2', target, '1G'])
        prep = SimpleNamespace(root=args.build_root, scripts=True, qemu=args.qemu, family='w3', iso=None,
                               dos_iso=args.dos_iso, win3=args.win_iso, win3_floppies=None, nvme=False,
                               outer_mb=1536, timeout=900, env=[])
        original = w9x.overlay
        w9x.overlay = lambda a: original(a) + nt3.cpio_newc([('usos-e2e/DOS.INI', 0o100644, DOS_INI)])
        ok = ws.prepare_blocking(prep, args.out, target,
                                 env='DOS_REGIONAL=/usos-e2e/DOS.INI DOS_WIN_SYSTEM=windows-3-1 ')
        console = (args.out / 'console.log').read_bytes()
        staged = b'Winsock (experimental): C:\\NET\\WIN16 staged' in console
        print('PREPARE', ok, 'WINSOCK-STAGED', staged)
        return 0 if ok and staged else 1

    if args.mode == 'install':
        if base.exists():
            raise SystemExit('Already installed')
        ws.linux(vm, target, 'install-notify',
                 "test -f /target/USOSDOS/WINMENU.BAT\n"
                 "grep -q 'WIN16' /target/USOSDOS/WINMENU.BAT\n"
                 "sed -i '/SMARTDRV.EXE \\/C/a echo WS-INSTALL-COMPLETE>COM1\\r' /target/USOSDOS/WINMENU.BAT\n"
                 "grep -c WS-INSTALL-COMPLETE /target/USOSDOS/WINMENU.BAT\n")
        done = ws.boot(vm, target, 'install', args.seconds, 'WS-INSTALL-COMPLETE')
        raw = ws.linux(vm, target, 'install-check',
                       "test -f /target/USOSW3/MENU.TAG && test -f /target/WINDOWS/WIN.COM && echo WS-INSTALL-PASS\n"
                       "sha256sum /target/WINDOWS/WINSOCK.DLL /target/NET/WIN16/WINSOCK.DLL /target/NET/USOSPKTQ.COM "
                       "/target/NET/USOSPKT.COM /target/NET/NETSTART.BAT 2>&1 | sed 's/^/WS-SHA /'\n"
                       "ls /target/WINDOWS/*.GRP /target/WINDOWS/*.grp 2>/dev/null | sed 's/^/WS-GRP /'\n"
                       "for g in /target/WINDOWS/*.GRP /target/WINDOWS/*.grp; do test -f \"$g\" || continue; "
                       "if grep -q 'USOS Winsock test' \"$g\" && grep -qi 'GETHTTP' \"$g\"; then echo \"WS-GRPHIT $g\"; fi; done\n"
                       + dump(['AUTOEXEC.BAT', 'NET/NETSTART.BAT', 'NET/WIN16/STAGE.LOG', 'WINDOWS/PROGMAN.INI',
                               'USOSW3/W3AUTO.BAT']))
        (args.out / 'install-check.txt').write_bytes(raw)
        files = files_of(raw)
        evidence = args.out / 'install-files'
        evidence.mkdir(exist_ok=True)
        for name, data in files.items():
            (evidence / name.replace('/', '-')).write_bytes(data)
        sha = {m[1].decode().replace('/target/', ''): m[0].decode()
               for m in re.findall(rb'WS-SHA ([0-9a-f]{64})\s+(\S+)', raw)}
        checks = {
            'menu_step_done': done and b'WS-INSTALL-PASS' in raw,
            'winsock_dll_in_windows': sha.get('WINDOWS/WINSOCK.DLL') is not None
                and sha.get('WINDOWS/WINSOCK.DLL') == sha.get('NET/WIN16/WINSOCK.DLL'),
            'usospktq': 'NET/USOSPKTQ.COM' in sha,
            'queue_line': b'set USOSPKT_QUEUE=1' in files.get('AUTOEXEC.BAT', b''),
            'queue_netstart': b'USOSPKTQ.COM /Q 0x60' in files.get('NET/NETSTART.BAT', b''),
            'stage_log': b'WINSOCK.DLL: copied to C:\\WINDOWS' in files.get('NET/WIN16/STAGE.LOG', b''),
            'progman_group': b'WS-GRPHIT' in raw,
        }
        (args.out / 'install-verdict.json').write_text(json.dumps({'checks': checks, 'sha256': sha}, indent=2))
        print(json.dumps(checks, indent=2))
        if not checks['menu_step_done']:
            raise SystemExit('Installation incomplete; retained for diagnosis')
        ws.command([img, 'snapshot', '-c', 'base', target])
        target.rename(base)
        return 0 if all(checks.values()) else 1

    disk = args.out / (args.mode + '.qcow2')
    if disk.exists():
        raise SystemExit('Overlay exists: ' + str(disk))
    ws.command([img, 'create', '-f', 'qcow2', '-F', 'qcow2', '-b', base, disk])
    if args.mode == 'show':
        ws.linux(vm, disk, 'show-stage', "printf '\\r\\nECHO WS-SHOW-DONE>COM1\\r\\n' >> /target/AUTOEXEC.BAT\n")
        ws.boot(vm, disk, 'show-run', min(args.seconds, 240), None)
        print('SCREENSHOT', args.out / 'show-run/final.png')
        return 0
    stage = ("rm -f /target/NET/WIN16/GETHTTP.LOG /target/NET/WIN16/GETHTTP.RSP /target/NET/MTCP.CFG "
             "/target/NET/DHCP.LOG /target/NET/USOSPKT.LOG\n"
             "grep -q 'WIN.COM /S /B' /target/AUTOEXEC.BAT\n"
             "sed -i 's@WIN.COM /S /B@WIN.COM /S /B C:\\\\NET\\\\WIN16\\\\GETHTTP.EXE /EXIT@' /target/AUTOEXEC.BAT\n"
             "grep -c 'GETHTTP.EXE /EXIT' /target/AUTOEXEC.BAT\n"
             "printf '\\r\\nECHO WS-APP-DONE>COM1\\r\\n' >> /target/AUTOEXEC.BAT\n")
    ws.linux(vm, disk, 'test-stage', stage)
    done = ws.boot(vm, disk, 'test-run', min(args.seconds, 900), 'WS-APP-DONE')
    raw = ws.linux(vm, disk, 'test-read', dump(['NET/WIN16/GETHTTP.LOG', 'NET/WIN16/GETHTTP.RSP', 'NET/USOSPKT.LOG',
                                                 'NET/DHCP.LOG', 'NET/MTCP.CFG']))
    files = files_of(raw)
    evidence = args.out / 'test-files'
    evidence.mkdir(exist_ok=True)
    for name, data in files.items():
        (evidence / name.replace('/', '-')).write_bytes(data)
    log = files.get('NET/WIN16/GETHTTP.LOG', b'')
    response = files.get('NET/WIN16/GETHTTP.RSP', b'')
    print(log.decode('ascii', errors='replace'))
    passed = b'PASS HTTP 200' in log and response.startswith((b'HTTP/1.0 200', b'HTTP/1.1 200'))
    headers, separator, body = response.partition(b'\r\n\r\n')
    passed = passed and bool(separator)
    for header in headers.split(b'\r\n'):
        if header.lower().startswith(b'content-length:'):
            passed = passed and len(body) == int(header.split(b':', 1)[1])
    passed = passed and b'config=USOSPKT queue; IP from C:\\NET\\MTCP.CFG' in log
    dhcp = (b'Offer received, Acknowledged' in files.get('NET/DHCP.LOG', b'') and
            re.search(rb'^IPADDR\s+172\.31\.8\.\d+', files.get('NET/MTCP.CFG', b''), re.M) is not None)
    passed = passed and done and dhcp
    verdict = {'pass': passed, 'app_returned': done, 'dos_dhcp_pass': dhcp, 'netdev': LAN,
               'files': {n: {'bytes': len(d), 'sha256': hashlib.sha256(d).hexdigest()} for n, d in files.items()}}
    (args.out / 'test-verdict.json').write_text(json.dumps(verdict, indent=2))
    print(json.dumps(verdict, indent=2))
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
