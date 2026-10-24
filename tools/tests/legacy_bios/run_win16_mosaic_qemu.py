#!/usr/bin/env python3
# Copyright (C) 2026 Maksymilian and the USOS Authors
# SPDX-License-Identifier: GPL-3.0-or-later
"""Stage2 Win16 tests on disposable overlays of one USOS profile installation.

Use --mode async for actual hidden-window DNS/socket notifications, or mosaic
for the unmodified NCSA Win16 application. One completion screenshot, no live
progress queries. The browser archive is never stored in the repository.
Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
"""
from pathlib import Path
from types import SimpleNamespace
import argparse
import hashlib
import json
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import run_win16_winsock_flow_qemu as flow


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--mode', choices=('async', 'mosaic'), required=True)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--tag', required=True)
    p.add_argument('--build-root', type=Path, required=True)
    p.add_argument('--qemu', type=Path, required=True)
    p.add_argument('--artifacts', type=Path, required=True)
    p.add_argument('--browser-dir', type=Path)
    p.add_argument('--url', default='http://68k.news/')
    a = p.parse_args()
    if not a.tag.replace('-', '').isalnum():
        p.error('tag must be alphanumeric with hyphens')
    if not a.url.startswith('http://') or len(a.url) > 175 or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-/:_' for c in a.url):
        p.error('test URL must be a simple HTTP URL')
    flow.nt3.set_root(a.build_root)
    base = a.out / 'base.qcow2'
    disk = a.out / (a.tag + '.qcow2')
    flow.ws.command([a.qemu.with_name('qemu-img.exe'), 'create', '-f', 'qcow2',
                     '-F', 'qcow2', '-b', base, disk])
    files = {'WINSOCK.DLL': (a.artifacts / 'WINSOCK.DLL').read_bytes()}
    if a.mode == 'async':
        files['ASYNC.EXE'] = (a.artifacts / 'ASYNCTEST.EXE').read_bytes()
        app = r'C:\NET\WIN16\ASYNC.EXE /EXIT'
        marker = 'WS-APP-DONE'
        names = ['NET/WIN16/ASYNC.LOG', 'NET/WIN16/ASYNC.RSP']
    else:
        if a.browser_dir is None:
            p.error('--browser-dir is required for mosaic')
        exe = (a.browser_dir / 'MOSAIC.EXE').read_bytes()
        files['MOSAIC.EXE'] = exe
        files['MOSRUN.EXE'] = (a.artifacts / 'MOSRUN.EXE').read_bytes()
        ini = (a.browser_dir / 'MOSAIC.INI').read_bytes().replace(b'\r\n', b'\n')
        ini = ini.replace(b'Autoload Home Page=no', b'Autoload Home Page=yes')
        ini = b'\n'.join(('Home Page='+a.url).encode('ascii') if s.startswith(b'Home Page=') else s
                         for s in ini.split(b'\n'))
        ini = ini.replace(b'Display Inline Images=yes', b'Display Inline Images=no')
        ini = b'\n'.join(s for s in ini.split(b'\n') if b'trumpet' not in s.lower())
        files['MOSAIC.INI'] = ini.replace(b'\n', b'\r\n')
        app = r'C:\NET\WIN16\MOSRUN.EXE ' + a.url
        marker = None  # Persistent interactive app; one bounded final capture.
        names = ['NET/WIN16/MOSAIC.LOG']
    stage = ("rm -f /target/NET/MTCP.CFG /target/NET/DHCP.LOG /target/NET/USOSPKT.LOG\n"
             "cp /ws/WINSOCK.DLL /target/WINDOWS/WINSOCK.DLL\n"
             "for f in /ws/*; do cp \"$f\" /target/NET/WIN16/; done\n"
             + ("cp /ws/MOSAIC.INI /target/WINDOWS/MOSAIC.INI\n" if a.mode == 'mosaic' else '') +
             "grep -q 'WIN.COM /S /B' /target/AUTOEXEC.BAT\n"
             "sed -i 's@WIN.COM /S /B@WIN.COM /S /B " + app.replace('\\', '\\\\') + "@' /target/AUTOEXEC.BAT\n"
             "printf '\\r\\nECHO WS-APP-DONE>COM1\\r\\n' >> /target/AUTOEXEC.BAT\n")
    vm = SimpleNamespace(out=a.out, build_root=a.build_root, qemu=a.qemu, netdev=flow.LAN)
    flow.ws.linux(vm, disk, a.tag + '-stage', stage, files)
    done = flow.ws.boot(vm, disk, a.tag + '-run', 90 if a.mode == 'mosaic' else 180, marker)
    names += ['NET/DHCP.LOG', 'NET/MTCP.CFG', 'NET/USOSPKT.LOG', 'NET/WIN16/WINSOCK.LOG', 'AUTOEXEC.BAT']
    data = flow.files_of(flow.ws.linux(vm, disk, a.tag + '-read', flow.dump(names)))
    evidence = a.out / (a.tag + '-files')
    evidence.mkdir()
    for name, value in data.items():
        (evidence / name.replace('/', '-')).write_bytes(value)
    verdict = {'completion': done, 'mode': a.mode, 'url': a.url,
               'injected_sha256': {k: hashlib.sha256(v).hexdigest() for k,v in files.items()},
               'files': {k: {'bytes': len(v), 'sha256': hashlib.sha256(v).hexdigest()} for k,v in data.items()}}
    if a.mode == 'async':
        log = data.get('NET/WIN16/ASYNC.LOG', b'')
        print(log.decode('ascii', 'replace'))
        verdict['pass'] = done and b'PASS async HTTP 200' in log and b'mode=STANDARD' in log and b'FAIL' not in log
    else:
        print(data.get('NET/WIN16/MOSAIC.LOG', b'').decode('ascii', 'replace'))
        verdict['pass'] = None  # A completion marker alone does not prove a rendered page.
        verdict['observation'] = 'single final capture after bounded interactive run'
        verdict['requires_visual_and_pcap_review'] = True
    (a.out / (a.tag + '-verdict.json')).write_text(json.dumps(verdict, indent=2))
    print(json.dumps(verdict, indent=2))
    return 0 if a.mode == 'mosaic' or (done and verdict['pass'] is not False) else 1


if __name__ == '__main__':
    raise SystemExit(main())
