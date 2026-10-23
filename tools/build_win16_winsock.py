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
    """One wlink ``export`` directive per entry (C names get a '_').

    A single comma-separated ``export`` argument is long enough that the
    linker's own command-line parser chokes on it (E3033 near '"export'), so
    the whole link is driven from a response file with one line per export.
    """
    items = ['export %s.%d=%s' % (name, ordinal, name.upper()) for name, ordinal in exports]
    return items


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
        'name %s' % ARTIFACT,
        'file %s' % obj,
        'file %s' % (libs / 'libentry.obj'),
        'library %s' % (libs / 'windows.lib'),
        'library %s' % (libs / 'clibl.lib'),
    ]
    directives += export_directive(exports)
    response = OBJ_DIR / 'winsock16.lnk'
    response.write_text('\r\n'.join(directives) + '\r\n', encoding='ascii')
    run([wlink, '@%s' % response], verbose)

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