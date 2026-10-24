#!/usr/bin/env python3
# Copyright (C) 2026 Maksymilian and the USOS Authors
# SPDX-License-Identifier: GPL-3.0-or-later
"""Two fresh USOS-flow Win16 bases; stage3 applications belong on COW only.

No physical devices, live progress polling, base overwrites or cleanup.
The build-root is a read-only source of the existing integrated profile.
Windows3.1's normal installer may use STANDARD; every stage3 application
overlay must explicitly launch WIN /3 /B and prove enhanced mode itself.
"""
from pathlib import Path
from types import SimpleNamespace
import argparse
import hashlib
import json
import os
import re
import socket
import stat
import subprocess
import sys
import threading
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import run_win16_winsock_flow_qemu as flow

RUNTIME = Path(r'K:\USOS-VM\winsock-etap3-20261024')
SYSTEMS = {'win31': 'windows-3-1', 'wfw311': 'windows-wfw-3-11'}
LAN = flow.LAN


def guarded(path: Path) -> Path:
    path = Path(os.path.abspath(path))
    if any(c in str(path) for c in ',\r\n\x00') or not path.is_relative_to(RUNTIME) or path == RUNTIME:
        raise ValueError('Only a named child of the exact stage3 runtime is allowed')
    for component in (RUNTIME, *path.parents, path):
        try: info = component.stat(follow_symlinks=False)
        except FileNotFoundError: continue
        if info.st_file_attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT:
            raise ValueError('Reparse points are not allowed in VM output paths')
    return path


def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''): digest.update(block)
    return digest.hexdigest()


def receipt(path: Path, value):
    guarded(path)
    with path.open('x', encoding='utf-8', newline='\n') as output:
        json.dump(value, output, indent=2); output.write('\n')


def make_overlay(out: Path, base: Path, tag: str, qemu: Path) -> Path:
    out, base = guarded(out), guarded(base)
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9-]{0,63}', tag):
        raise ValueError('Invalid overlay tag')
    if not base.is_file() or base.name != 'base.qcow2':
        raise ValueError('An installed named base.qcow2 is required')
    disk = guarded(out / (tag + '.qcow2'))
    if disk.exists(): raise ValueError('Refusing to overwrite a test overlay')
    flow.ws.command([qemu.with_name('qemu-img.exe'), 'create', '-f', 'qcow2', '-F', 'qcow2', '-b', base, disk])
    receipt(out / (tag + '-overlay.json'), {'base': str(base), 'base_sha256': sha(base),
            'overlay': str(disk), 'applications_on_base': False})
    return disk


def boot(args, disk: Path, tag: str, seconds: int, marker=None) -> bool:
    """One bounded completion wait and final capture; keep PPM and PNG."""
    disk = guarded(disk)
    if not 1 <= seconds <= 3300: raise ValueError('A bounded run is required')
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9-]{0,63}', tag): raise ValueError('Invalid run tag')
    out = guarded(args.out / tag); out.mkdir(exist_ok=False)
    port = flow.nt3.free_port()
    cmd = [str(args.qemu), '-machine', 'pc,smm=off,vmport=off', '-accel', 'tcg',
           '-cpu', 'pentium3', '-m', '64', '-display', 'none', '-vga', 'std',
           '-netdev', args.netdev, '-device', 'igb,netdev=net0',
           '-object', f'filter-dump,id=cap,netdev=net0,file={(out/"network.pcap").as_posix()}',
           '-monitor', f'tcp:127.0.0.1:{port},server=on,wait=off', '-serial', 'stdio',
           '-drive', f'file={disk.as_posix()},format=qcow2,if=ide,index=0']
    receipt(out / 'command.json', cmd)
    event, matched = threading.Event(), threading.Event()
    started = time.monotonic()
    with (out/'serial.log').open('xb') as log, (out/'qemu.log').open('xb') as error:
        process = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=error)
        def read_serial():
            for line in iter(process.stdout.readline, b''):
                log.write(line); log.flush()
                if marker and marker.encode('ascii') in line:
                    matched.set(); event.set()
            event.set()  # Actual EOF is completion, never a status probe.
        reader = threading.Thread(target=read_serial, daemon=True); reader.start()
        try:
            event.wait(seconds)
            with socket.create_connection(('127.0.0.1', port), timeout=10) as monitor:
                monitor.settimeout(10); monitor.recv(4096)
                transcript = bytearray()
                for line in ('stop', 'screendump "' + (out/'final.ppm').as_posix() + '"'):
                    monitor.sendall((line+'\n').encode())
                    data = bytearray()
                    while not data.endswith(b'(qemu) '):
                        part = monitor.recv(65536)
                        if not part: raise RuntimeError('HMP closed during final capture')
                        data.extend(part)
                    transcript.extend(data)
                (out/'hmp.log').write_bytes(transcript)
                monitor.sendall(b'quit\n')
                try:
                    while monitor.recv(65536): pass
                except ConnectionError: pass
            process.wait(timeout=30)
        finally:
            if process.returncode is None:
                try: process.wait(timeout=3)
                except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=10)
            reader.join(timeout=5)
    if (out/'final.ppm').exists():
        from PIL import Image
        Image.open(out/'final.ppm').save(out/'final.png')
    receipt(out/'completed.json', {'qemu_only': True, 'marker': marker, 'marker_seen': matched.is_set(),
            'returncode': process.returncode, 'elapsed_seconds': time.monotonic()-started,
            'one_final_capture': True, 'progress_queries': False})
    return matched.is_set()


def prepare(args, vm, target):
    if target.exists() or (args.out/'base.qcow2').exists(): raise ValueError('Installation already exists')
    if not args.dos_iso or not args.win_iso: raise ValueError('Both original media are required')
    for path in (args.dos_iso, args.win_iso):
        if not path.is_file() or any(c in str(path) for c in ',\r\n\x00'): raise ValueError('Invalid media path')
    flow.ws.command([args.qemu.with_name('qemu-img.exe'), 'create', '-f', 'qcow2', target, '1G'])
    prep = SimpleNamespace(root=args.build_root, scripts=True, qemu=args.qemu, family='w3', iso=None,
            dos_iso=args.dos_iso, win3=args.win_iso, win3_floppies=None, nvme=False,
            outer_mb=1536, timeout=900, env=[])
    original = flow.w9x.overlay
    flow.w9x.overlay = lambda options: original(options) + flow.nt3.cpio_newc([('usos-e2e/DOS.INI', 0o100644, flow.DOS_INI)])
    try:
        ok = flow.ws.prepare_blocking(prep, args.out, target,
                env='DOS_REGIONAL=/usos-e2e/DOS.INI DOS_WIN_SYSTEM='+SYSTEMS[args.system]+' ')
    finally: flow.w9x.overlay = original
    console = (args.out/'console.log').read_bytes()
    staged = b'Winsock (experimental): C:\\NET\\WIN16 staged' in console
    receipt(args.out/'prepared.json', {'system': args.system, 'catalog_id': SYSTEMS[args.system],
            'normal_usos_flow': True, 'passed': ok and staged, 'winsock_profile_staged': staged,
            'dos_iso_sha256': sha(args.dos_iso), 'win_iso_sha256': sha(args.win_iso),
            'console_sha256': sha(args.out/'console.log'), 'build_root_readonly': True})
    if not ok or not staged: raise RuntimeError('USOS preparation failed; retained for diagnosis')


def install(args, vm, target):
    base = guarded(args.out/'base.qcow2')
    if base.exists(): raise ValueError('Already installed; use a COW overlay')
    prepared = json.loads((args.out/'prepared.json').read_text())
    if prepared['system'] != args.system or prepared['passed'] is not True: raise ValueError('Prepared system mismatch')
    flow.ws.linux(vm, target, 'install-notify',
            "test -f /target/USOSDOS/WINMENU.BAT\n"
            "grep -q 'WIN16' /target/USOSDOS/WINMENU.BAT\n"
            "sed -i '/SMARTDRV.EXE \\/C/a echo WS3-INSTALL-COMPLETE>COM1\\r' /target/USOSDOS/WINMENU.BAT\n")
    done = boot(vm, target, 'install', args.seconds, 'WS3-INSTALL-COMPLETE')
    names = ['AUTOEXEC.BAT','NET/NETSTART.BAT','NET/WIN16/STAGE.LOG','WINDOWS/PROGMAN.INI','USOSW3/W3AUTO.BAT']
    raw = flow.ws.linux(vm, target, 'install-check',
            "test -f /target/USOSW3/MENU.TAG && test -f /target/WINDOWS/WIN.COM && echo WS3-INSTALL-PASS\n"
            "sha256sum /target/WINDOWS/WINSOCK.DLL /target/NET/WIN16/WINSOCK.DLL /target/NET/USOSPKTQ.COM /target/NET/USOSPKT.COM | sed 's/^/WS-SHA /'\n"
            "for g in /target/WINDOWS/*.GRP /target/WINDOWS/*.grp; do test -f \"$g\" || continue; "
            "if grep -q 'USOS Winsock test' \"$g\" && grep -qi 'GETHTTP' \"$g\"; then echo WS-GRPHIT; fi; done\n" + flow.dump(names))
    (args.out/'install-check.txt').write_bytes(raw)
    files = flow.files_of(raw); evidence = guarded(args.out/'install-files'); evidence.mkdir(exist_ok=False)
    for name,data in files.items(): (evidence/name.replace('/','-')).write_bytes(data)
    hashes = {m[1].decode().replace('/target/',''):m[0].decode() for m in re.findall(rb'WS-SHA ([0-9a-f]{64})\s+(\S+)',raw)}
    checks = {'menu_step_done': done and b'WS3-INSTALL-PASS' in raw,
            'winsock_dll': hashes.get('WINDOWS/WINSOCK.DLL') is not None and hashes.get('WINDOWS/WINSOCK.DLL')==hashes.get('NET/WIN16/WINSOCK.DLL'),
            'queue_file': 'NET/USOSPKTQ.COM' in hashes, 'default_packet_file': 'NET/USOSPKT.COM' in hashes,
            'queue_config': b'set USOSPKT_QUEUE=1' in files.get('AUTOEXEC.BAT',b''),
            'queue_netstart': b'USOSPKTQ.COM /Q 0x60' in files.get('NET/NETSTART.BAT',b''),
            'stage_log': b'WINSOCK.DLL: copied to C:\\WINDOWS' in files.get('NET/WIN16/STAGE.LOG',b''),
            'group': b'WS-GRPHIT' in raw}
    receipt(args.out/'install-verdict.json', {'system':args.system,'checks':checks,'sha256':hashes,
            'applications_installed':False,'stage3_required_launch':'WIN /3 /B',
            'enhanced_execution_not_yet_proven':True})
    if not all(checks.values()): raise RuntimeError('Installation checks failed; no base snapshot created')
    flow.ws.command([args.qemu.with_name('qemu-img.exe'),'snapshot','-c','base',target])
    target.rename(base)
    receipt(args.out/'base.json',{'system':args.system,'image':str(base),'sha256':sha(base),
            'snapshot':'base','normal_usos_flow':True,'applications_installed':False})


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode',choices=('prepare','install','overlay'))
    parser.add_argument('--system',choices=tuple(SYSTEMS),required=True)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--build-root',type=Path,required=True)
    parser.add_argument('--qemu',type=Path,required=True)
    parser.add_argument('--dos-iso',type=Path)
    parser.add_argument('--win-iso',type=Path)
    parser.add_argument('--seconds',type=int,default=3000)
    parser.add_argument('--tag')
    args=parser.parse_args(); args.out=guarded(args.out); args.out.mkdir(parents=True,exist_ok=True)
    flow.nt3.set_root(args.build_root)
    vm=SimpleNamespace(out=args.out,build_root=args.build_root,qemu=args.qemu,netdev=LAN)
    target=guarded(args.out/'target.qcow2')
    if args.mode=='prepare': prepare(args,vm,target)
    elif args.mode=='install': install(args,vm,target)
    else: print(make_overlay(args.out,args.out/'base.qcow2',args.tag or '',args.qemu))
    return 0


if __name__=='__main__': raise SystemExit(main())
