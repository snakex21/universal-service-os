"""Build usos-reg.exe (tools/windows_usos_reg.c): the declarative registry set
tool for NT 4.0 SP6 .. Windows 11. i386 console image, no C runtime, zig cc;
the PE OS/subsystem version is then set to 4.00 (tools/nt4/pe_nt4_version.py)
so NT 4.0 loads it. Output: zig-out/windows-usos-reg/usos-reg.exe (untracked),
staged by tools/build_micro_linux.py as usr/lib/usos/usos-reg.exe.

    python tools/build_windows_usos_reg.py [OUTDIR]

The toolchain is tools/zig/zig.exe; USOS_ZIG overrides it (e.g. a worktree
without the untracked toolchain). Universal Service OS (USOS), GPL-3.0-or-later.
"""
from pathlib import Path
import importlib.util
import os
import subprocess
import sys

NAME = 'usos-reg.exe'


def zig_path(root: Path) -> Path:
    override = os.environ.get('USOS_ZIG')
    return Path(override) if override else root / 'tools/zig/zig.exe'


def _set_nt4(root: Path):
    spec = importlib.util.spec_from_file_location('pe_nt4_version', root / 'tools/nt4/pe_nt4_version.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.set_nt4


def build(root: Path, output: Path) -> Path:
    zig = zig_path(root)
    output.mkdir(parents=True, exist_ok=True)
    temp = output / 'tmp'
    temp.mkdir(exist_ok=True)
    env = os.environ.copy()
    env['TEMP'] = env['TMP'] = str(temp)
    env['ZIG_GLOBAL_CACHE_DIR'] = str(root / 'tools/cache/zig-global')
    env['ZIG_LOCAL_CACHE_DIR'] = str(output / 'zig-cache')
    include = zig.parent / 'lib/libc/include/any-windows-any'
    exe = output / NAME
    subprocess.run([str(zig), 'cc', '-target', 'x86-windows-gnu', '-mcpu=i586', '-Os', '-nostdlib', '-fno-stack-protector', '-fno-builtin',
                    '-I' + str(include), str(root / 'tools/windows_usos_reg.c'),
                    '-Wl,--entry,entry', '-Wl,--subsystem,console', '-lkernel32', '-ladvapi32', '-o', str(exe)],
                   env=env, check=True)
    exe.write_bytes(_set_nt4(root)(exe.read_bytes(), 4, 0))
    return exe


if __name__ == '__main__':
    root = Path(__file__).resolve().parents[1]
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'zig-out/windows-usos-reg'
    print(build(root, out))
