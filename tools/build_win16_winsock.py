#!/usr/bin/env python3
"""Build the USOS Win16 Winsock provider (src/platform/bios/win16/winsock16).

Produces zig-out/win16/WINSOCK.DLL (NE, 16-bit Windows 3.x) with the Open
Watcom 16-bit toolchain.  A missing toolchain is reported and treated as a
skip (exit 0) so that a plain ``zig build``/CI run without the Watcom cache
still succeeds; pass ``--strict`` to make a missing toolchain fatal.

Usage:
    python tools/build_win16_winsock.py [--strict] [--verbose]
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC_DIR = ROOT / 'src' / 'platform' / 'bios' / 'win16' / 'winsock16'
OUT_DIR = ROOT / 'zig-out' / 'win16'
OBJ_DIR = ROOT / 'zig-out' / 'win16' / 'obj'
ARTIFACT = OUT_DIR / 'WINSOCK.DLL'


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


def run(cmd: list[str], verbose: bool, cwd: Path | None = None) -> None:
    if verbose:
        print('  ' + ' '.join(str(part) for part in cmd))
    result = subprocess.run([str(part) for part in cmd], cwd=str(cwd or ROOT),
                            capture_output=True, text=True)
    if result.stdout.strip():
        print(result.stdout.strip())
    if result.returncode != 0:
        if result.stderr.strip():
            print(result.stderr.strip(), file=sys.stderr)
        raise SystemExit('FAILED (%d): %s' % (result.returncode, cmd[0]))
def build(watcom: Path, verbose: bool, keep_objects: bool) -> Path:
    wcc = watcom / 'binnt64' / 'wcc.exe'
    wlink = watcom / 'binnt64' / 'wlink.exe'
    headers = watcom / 'h' / 'win'
    libs = watcom / 'lib286' / 'win'

    OBJ_DIR.mkdir(parents=True, exist_ok=True)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    obj = OBJ_DIR / 'winsock16.obj'

    source = SRC_DIR / 'winsock16.c'
    def_file = SRC_DIR / 'winsock16.def'
    for needed in (source, def_file, headers / 'windows.h', headers / 'winsock.h'):
        if not needed.exists():
            raise SystemExit('missing input: %s' % needed)

    print('Open Watcom: %s' % watcom)
    print('compile: %s' % source.relative_to(ROOT))
    # -bt=windows: 16-bit Windows target, -ml: large model, -zW: Windows
    # prolog/epilog, -bd: build a DLL (no DOS extender stub).
    run([wcc, '-bt=windows', '-bd', '-ml', '-zW', '-zq', '-w3',
         '-I%s' % headers, '-fo=%s' % obj, source], verbose)

    print('link: %s' % ARTIFACT.relative_to(ROOT))
    run([wlink, 'system', 'windows_dll', 'option', 'quiet', 'option', 'nodefaultlibs',
         'name', ARTIFACT, 'file', obj, def_file,
         'library', libs / 'windows.lib', libs / 'winsock.lib'], verbose)

    if not keep_objects:
        shutil.rmtree(OBJ_DIR, ignore_errors=True)
    if not ARTIFACT.exists():
        raise SystemExit('linker reported success but %s is missing' % ARTIFACT)
    return ARTIFACT


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
    return 0


if __name__ == '__main__':
    raise SystemExit(main())