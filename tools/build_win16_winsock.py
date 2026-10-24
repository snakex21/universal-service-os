#!/usr/bin/env python3
# Copyright (C) 2026 Maksymilian and the USOS Authors
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build the USOS Win16 Winsock provider (src/platform/bios/win16/winsock16).

Produces zig-out/win16/WINSOCK.DLL (NE, 16-bit Windows 3.x) and
zig-out/win16/TESTLOAD.EXE (the WSAStartup smoke-test application) with the
Open Watcom 16-bit toolchain.  A missing toolchain is reported and treated as a
skip (exit 0) so that a plain ``zig build``/CI run without the Watcom cache
still succeeds; pass ``--strict`` to make a missing toolchain fatal.

Usage:
    python tools/build_win16_winsock.py [--strict] [--verbose]
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC_DIR = ROOT / 'src' / 'platform' / 'bios' / 'win16' / 'winsock16'
OUT_DIR = ROOT / 'zig-out' / 'win16'
OBJ_DIR = ROOT / 'zig-out' / 'win16' / 'obj'
ARTIFACT = OUT_DIR / 'WINSOCK.DLL'
TESTLOAD_ARTIFACT = OUT_DIR / 'TESTLOAD.EXE'


def find_watcom() -> Path | None:
    """USOS_WATCOM first (same convention as the test suite), then the cache."""
    env = os.environ.get('USOS_WATCOM')
    if env:
        candidate = Path(env)
        if (candidate / 'binnt64' / 'wcc.exe').is_file():
            return candidate
        print('USOS_WATCOM=%s does not contain binnt64\\wcc.exe' % env, file=sys.stderr)
        return None
    for base in (ROOT / 'tools' / 'cache' / 'openwatcom',):
        if base.is_dir():
            for candidate in sorted(base.glob('ow-*')):
                if (candidate / 'binnt64' / 'wcc.exe').is_file():
                    return candidate
    return None


def parse_def_exports(def_file: Path) -> list[tuple[str, int]]:
    """Return [(name, ordinal)] from the EXPORTS section of the module def.

    The linker shipped in the toolchain cache (wlink 2.0 beta, 64-bit host)
    refuses module definition files (``file x.def`` -> E3146, ``option
    definition=`` -> E3033), so the build re-states the same list with wlink
    ``export`` directives instead of parsing the .def itself.
    """
    exports: list[tuple[str, int]] = []
    in_exports = False
    for raw in def_file.read_text(encoding='ascii', errors='replace').splitlines():
        line = raw.split(';', 1)[0].strip()
        if not line:
            continue
        if line.upper().startswith('EXPORTS'):
            in_exports = True
            continue
        if not in_exports:
            continue
        match = re.match(r'^([A-Za-z_][\w@$?]*)\s+@(\d+)\b', line)
        if match:
            exports.append((match.group(1), int(match.group(2))))
    if not exports:
        raise SystemExit('no exports found in %s' % def_file)
    return exports


def export_directive(exports: list[tuple[str, int]]) -> list[str]:
    """Export uppercase public names and FAR PASCAL linker symbols.

    A single comma-separated ``export`` argument is long enough that the
    linker's own command-line parser chokes on it (E3033 near '"export'), so
    the whole link is driven from a response file with one line per export.
    """
    items = ['export %s.%d=%s' % (name.upper(), ordinal, name.upper()) for name, ordinal in exports]
    return items


def run(cmd: list[str], verbose: bool, cwd: Path | None = None) -> None:
    if verbose:
        print('  ' + ' '.join(str(part) for part in cmd))
    result = subprocess.run([str(part) for part in cmd], cwd=str(cwd or OBJ_DIR),
                            capture_output=True, text=True)
    if result.stdout.strip():
        print(result.stdout.strip())
    if result.returncode != 0:
        if result.stderr.strip():
            print(result.stderr.strip(), file=sys.stderr)
        raise SystemExit('FAILED (%d): %s' % (result.returncode, cmd[0]))
def build(watcom: Path, verbose: bool, keep_objects: bool) -> Path:
    """WINSOCK.DLL: NE DLL, libentry.obj + 48 export directives."""
    wcc = watcom / 'binnt64' / 'wcc.exe'
    wlink = watcom / 'binnt64' / 'wlink.exe'
    headers = watcom / 'h' / 'win'
    libs = watcom / 'lib286' / 'win'

    OBJ_DIR.mkdir(parents=True, exist_ok=True)
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    includes = watcom / 'h'
    source = SRC_DIR / 'winsock16.c'
    def_file = SRC_DIR / 'winsock16.def'
    net_dir = SRC_DIR / 'net'
    # winsock16.c first, then the engine: the portable core (net/*.c minus
    # win16_pkt.c) plus win16_pkt.c, which is the only Windows/DPMI consumer.
    sources = [source] + sorted(net_dir.glob('*.c'))
    for needed in (source, def_file, net_dir / 'net.h', net_dir / 'usos_pkt.h',
                   net_dir / 'win16_pkt.c', headers / 'windows.h',
                   headers / 'winsock.h', includes / 'i86.h'):
        if not needed.exists():
            raise SystemExit('missing input: %s' % needed)

    print('Open Watcom: %s' % watcom)
    objs = []
    for one in sources:
        obj = OBJ_DIR / (one.stem + '.obj')
        print('compile: %s' % one.relative_to(ROOT))
        # -bt=windows: 16-bit Windows target, -ml: large model, -zW: Windows
        # prolog/epilog, -bd: build a DLL (no DOS extender stub).  h/ carries
        # i86.h (int86x, MK_FP, segread), h/win the Windows and Winsock API.
        # A DLL runs on its caller's stack: SS is not its own DGROUP. Without
        # -zu, far addresses of automatic REGS/RMCS buffers use the wrong DS.
        run([wcc, '-bt=windows', '-bd', '-ml', '-zu', '-zW', '-zq', '-w3',
             *(['-dUSOS_WS_DIAG'] if os.environ.get('USOS_WS_DIAG') == '1' else []),
             '-I%s' % headers, '-I%s' % includes, '-I%s' % net_dir,
             '-fo=%s' % obj, one], verbose)
        objs.append(obj)

    exports = parse_def_exports(def_file)
    print('link: %s (%d exports)' % (ARTIFACT.relative_to(ROOT), len(exports)))
    # format windows dll: NE DLL (the cached 64-bit wlink knows no
    # 'system windows_dll').  libentry.obj supplies __DLLstart_, clibl.lib the
    # large-model C runtime (__STK, _big_code_).  The linker in the cache does
    # not read module definition files at all, so the export table is restated
    # as wlink directives in a response file.
    directives = [
        'format windows dll',
        'option quiet',
        'option nodefaultlibs',
        'option modname=WINSOCK',
        "option description 'USOS Winsock 1.1 Win16'",
        'name %s' % ARTIFACT,
        'file %s' % (libs / 'libentry.obj'),
        'library %s' % (libs / 'windows.lib'),
        'library %s' % (libs / 'clibl.lib'),
    ]
    directives += ['file %s' % one for one in objs]
    directives += export_directive(exports)
    response = OBJ_DIR / 'winsock16.lnk'
    response.write_text('\r\n'.join(directives) + '\r\n', encoding='ascii')
    run([wlink, '@%s' % response], verbose)

    if not keep_objects:
        shutil.rmtree(OBJ_DIR, ignore_errors=True)
    if not ARTIFACT.exists():
        raise SystemExit('linker reported success but %s is missing' % ARTIFACT)
    return ARTIFACT


def build_testload(watcom: Path, verbose: bool, stem: str = 'testload') -> Path:
    """TESTLOAD.EXE: a small Win16 EXE, no libentry.obj, no export table."""
    wcc = watcom / 'binnt64' / 'wcc.exe'
    wlink = watcom / 'binnt64' / 'wlink.exe'
    headers = watcom / 'h' / 'win'
    includes = watcom / 'h'
    libs = watcom / 'lib286' / 'win'

    OBJ_DIR.mkdir(parents=True, exist_ok=True)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    source = SRC_DIR / (stem + '.c')
    obj = OBJ_DIR / (stem + '.obj')
    artifact = OUT_DIR / (stem.upper() + '.EXE')
    for needed in (source, headers / 'windows.h', headers / 'winsock.h',
                   includes / 'io.h', includes / 'fcntl.h'):
        if not needed.exists():
            raise SystemExit('missing input: %s' % needed)

    print('compile: %s' % source.relative_to(ROOT))
    run([wcc, '-bt=windows', '-ml', '-zW', '-zq', '-w3',
         '-I%s' % headers, '-I%s' % includes, '-fo=%s' % obj, source], verbose)

    print('link: %s' % artifact.relative_to(ROOT))
    # A Win16 EXE needs no libentry.obj (no __DLLstart_) and no export list;
    # windows.lib supplies the WinMain startup and clibl.lib the large-model C
    # runtime used by _lcreat/_lwrite/_lclose.
    directives = [
        'format windows',
        'option quiet',
        'option nodefaultlibs',
        'option modname=%s' % stem.upper(),
        "option description 'USOS %s Win16'" % stem.upper(),
        'name %s' % artifact,
        'file %s' % obj,
        'library %s' % (libs / 'windows.lib'),
        'library %s' % (libs / 'clibl.lib'),
    ]
    response = OBJ_DIR / (stem + '.lnk')
    response.write_text('\r\n'.join(directives) + '\r\n', encoding='ascii')
    run([wlink, '@%s' % response], verbose)
    if not artifact.exists():
        raise SystemExit('linker reported success but %s is missing' % artifact)
    return artifact


# The opt-in Winsock set for Windows 3.1 / 3.11 / WfW 3.11 installs (answer
# profile dos_winsock, tools/dos_win3_menu.sh dos_winsock_apply). It lives in
# its own ESP folder (EFI\USOS\dos-native\winsock16), never in msdos\, so an
# install without the option copies exactly the same files as before.
PAYLOAD_FILES = ('WINSOCK.DLL', 'GETHTTP.EXE', 'TESTLOAD.EXE', 'USOSPKTQ.COM', 'NETSTART.BAT', 'WINSOCK.TXT')

PAYLOAD_NOTICE = """USOS Winsock for Windows 3.1 / 3.11 / Windows for Workgroups 3.11
(experimental, answer profile option "Winsock (eksperymentalny)").

WINSOCK.DLL   own Winsock 1.1 provider (TCP/IP in the DLL), C:\\WINDOWS
GETHTTP.EXE   test: HTTP GET http://68k.news/ -> C:\\NET\\WIN16\\GETHTTP.LOG/.RSP
TESTLOAD.EXE  test: WSAStartup only
USOSPKTQ.COM  USOSPKT packet driver with the /Q queue for WINSOCK.DLL
NETSTART.BAT  loads USOSPKTQ /Q when USOSPKT_QUEUE=1 (set in AUTOEXEC.BAT)

Copyright (C) 2026 Maksymilian and the USOS Authors.
Licence: GPL-3.0-or-later. Source: src/platform/bios/win16/winsock16 and
src/platform/bios/msdos/usospktq.S of the USOS repository.
WINSOCK.DLL, GETHTTP.EXE and TESTLOAD.EXE are built with Open Watcom 2.0
(pinned snapshot 2026-09-01) and contain its Win16 startup code and C
runtime (clibl.lib, libentry.obj; Sybase Open Watcom Public License 1.0).
"""


def build_payload(root: Path, out: Path) -> list[Path]:
    """Build the opt-in set into out (zig-out/dos-native/winsock16)."""
    sys.path.insert(0, str(root / 'tools'))
    from build_dos_network import build_usospkt_queue
    from build_win3_usb_keyboard import openwatcom
    watcom = Path(os.environ['USOS_WATCOM']) if os.environ.get('USOS_WATCOM') else openwatcom()
    if not (watcom / 'binnt64' / 'wcc.exe').is_file():
        raise SystemExit('Open Watcom without binnt64\\wcc.exe: %s' % watcom)
    out.mkdir(parents=True, exist_ok=True)
    built = [build(watcom, False, False), build_testload(watcom, False), build_testload(watcom, False, 'gethttp')]
    shutil.rmtree(OBJ_DIR, ignore_errors=True)
    for one in built:
        shutil.copyfile(one, out / one.name)
    work = OUT_DIR / 'q-work'
    work.mkdir(parents=True, exist_ok=True)
    build_usospkt_queue(root, out, work)
    shutil.rmtree(work, ignore_errors=True)
    start = (root / 'src/platform/bios/msdos/network_start_queue.cmd').read_text(encoding='ascii')
    for line in start.splitlines():
        if len(line) > 127:
            raise ValueError('network_start_queue.cmd: MS-DOS command line exceeds 127 bytes')
    (out / 'NETSTART.BAT').write_bytes(start.replace('\r\n', '\n').replace('\n', '\r\n').encode('ascii'))
    (out / 'WINSOCK.TXT').write_bytes(PAYLOAD_NOTICE.replace('\n', '\r\n').encode('ascii'))
    files = [out / name for name in PAYLOAD_FILES]
    for one in files:
        if not one.is_file():
            raise SystemExit('Winsock payload incomplete: %s' % one)
    print('[PASS] Win16 Winsock (opt-in): ' + ', '.join('%s %d B' % (f.name, f.stat().st_size) for f in files))
    return files


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--strict', action='store_true',
                        help='fail when Open Watcom is not available')
    parser.add_argument('--verbose', action='store_true', help='echo every command')
    parser.add_argument('--keep-objects', action='store_true', help='keep .obj files')
    args = parser.parse_args(argv)

    watcom = find_watcom()
    if watcom is None:
        message = ('brak Open Watcom - ustaw USOS_WATCOM albo umiesc toolchain w '
                   'tools/cache/openwatcom/ow-*; pomijam build WINSOCK.DLL')
        if args.strict:
            print('ERROR: ' + message, file=sys.stderr)
            return 1
        print('SKIP: ' + message)
        return 0

    artifact = build(watcom, args.verbose, args.keep_objects)
    print('OK: %s (%d bytes)' % (artifact.relative_to(ROOT), artifact.stat().st_size))
    exe = build_testload(watcom, args.verbose)
    print('OK: %s (%d bytes)' % (exe.relative_to(ROOT), exe.stat().st_size))
    exe = build_testload(watcom, args.verbose, 'gethttp')
    print('OK: %s (%d bytes)' % (exe.relative_to(ROOT), exe.stat().st_size))
    if not args.keep_objects:
        shutil.rmtree(OBJ_DIR, ignore_errors=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
