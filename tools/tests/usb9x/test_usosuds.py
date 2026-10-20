"""USOS USB disk service (UDS) ABI v1 draft: host test of src/platform/bios/win9x/usosuds_slot.c
(request validation of the helper side, removable-slot state machine of USOSUSB.MPD),
docs/usb9x-hotswap-design-2026-10-19.md stage 1. zig cc, UBSan, -m32 and native.
Usage: python -I tools/tests/usb9x/test_usosuds.py [zig]"""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
SRC = ROOT / 'src/platform/bios/win9x'


def find_zig() -> str:
    if len(sys.argv) > 1:
        return sys.argv[1]
    for cand in (ROOT / 'tools/zig/zig.exe', ROOT.parent.parent / 'Desktop/usos-x470-98se/tools/zig/zig.exe',
                 ROOT.parent.parent / 'Desktop/Universal_Service_OS/tools/zig/zig.exe'):
        if cand.exists():
            return str(cand)
    z = shutil.which('zig')
    if z:
        return z
    raise SystemExit('zig not found (pass its path)')


def static_checks() -> None:
    code = (SRC / 'usosuds_slot.c').read_text(encoding='utf-8')
    # no C runtime: builds unchanged for SeaBIOS, the 9x miniport (WDK 7.1) and USOSDBG
    for banned in ('#include <string.h>', 'memcpy(', 'memset(', 'malloc(', 'printf('):
        assert banned not in code, banned
    head = (SRC / 'usosuds.h').read_text(encoding='utf-8')
    assert 'GPL-3.0-or-later' in head and 'GPL-3.0-or-later' in code


def main() -> int:
    static_checks()
    zig = find_zig()
    with tempfile.TemporaryDirectory() as td:
        t = Path(td)
        env = dict(os.environ)
        env.setdefault('ZIG_GLOBAL_CACHE_DIR', str(t / 'zig-cache'))
        for name, extra in (('native', []), ('x86', ['-target', 'x86-windows-gnu'])):
            exe = t / f'uds_{name}.exe'
            cc = [zig, 'cc', *extra, '-std=c99', '-O1', '-Wall', '-Wextra', '-Werror', '-fsanitize=undefined',
                  '-fno-sanitize-recover=all', '-I', str(SRC), str(HERE / 'uds_host_test.c'),
                  str(SRC / 'usosuds_slot.c'), '-o', str(exe)]
            r = subprocess.run(cc, capture_output=True, text=True, env=env)
            if r.returncode:
                print(r.stdout + r.stderr)
                return 1
            r = subprocess.run([str(exe)], capture_output=True, text=True)
            print(f'[{name}] ' + r.stdout.strip())
            if r.returncode:
                return 1
        # the miniport compiler: WDK 7.1 cl, strict C89 (/Za), warnings as errors; skipped without a WDK
        wdk = next((w for w in (os.environ.get('WDKROOT'), ROOT / 'tools/WinDDK71',
                                Path.home() / 'Desktop/universal-service-os/tools/WinDDK71')
                    if w and (Path(w) / 'bin/x86/x86/cl.exe').is_file()), None)
        if wdk:
            wdk = Path(wdk)
            env2 = dict(env, TEMP=str(t), TMP=str(t),
                        PATH=str(wdk / 'bin/x86/x86') + os.pathsep + str(wdk / 'bin/x86') + os.pathsep + env.get('PATH', ''))
            r = subprocess.run([str(wdk / 'bin/x86/x86/cl.exe'), '/nologo', '/c', '/W4', '/WX', '/Za', '/O1', '/GS-',
                                '/Zl', '/I' + str(SRC), '/Fo' + str(t / 'usosuds_slot.obj'), str(SRC / 'usosuds_slot.c')],
                               capture_output=True, text=True, env=env2, cwd=t)
            if r.returncode:
                print(r.stdout + r.stderr)
                return 1
            print('[wdk71] cl /W4 /WX /Za PASS')
        else:
            print('[wdk71] skipped (no WDK 7.1)')
    print('USOSUDS-TEST PASS')
    return 0


if __name__ == '__main__':
    sys.exit(main())
