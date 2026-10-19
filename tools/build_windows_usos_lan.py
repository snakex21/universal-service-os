"""Build windowless no-CRT LAN helpers for 9x and NT4/2000. Own outputs only."""
from pathlib import Path
import os
import subprocess
import importlib.util


def build(root: Path, output: Path) -> dict[str, Path]:
    output.mkdir(parents=True, exist_ok=True)
    temp = output / 'tmp'
    temp.mkdir(exist_ok=True)
    env = os.environ.copy()
    env.update(TEMP=str(temp), TMP=str(temp),
               ZIG_GLOBAL_CACHE_DIR=str(root / 'tools/cache/zig-global'),
               ZIG_LOCAL_CACHE_DIR=str(output / 'zig-cache'))
    zig = Path(env.get('USOS_ZIG', root / 'tools/zig/zig.exe'))
    spec = importlib.util.spec_from_file_location('nt4pe', root / 'tools/nt4/pe_nt4_version.py')
    pe = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(pe)
    results = {}
    for system in ('9X', 'NT'):
        name = 'USOSLAN' + system + '.EXE'
        exe = output / name
        subprocess.run([str(zig), 'cc', '-target', 'x86-windows-gnu', '-mcpu=i586',
                        '-Os', '-nostdlib', '-fno-stack-protector', '-fno-builtin',
                        '-I' + str(zig.parent / 'lib/libc/include/any-windows-any'),
                        '-DUSOS_LAN_' + system, str(root / 'tools/windows_usos_lan.c'),
                        '-Wl,--entry,entry', '-Wl,--subsystem,windows',
                        '-lkernel32', '-ladvapi32', '-o', str(exe)], env=env, check=True)
        exe.write_bytes(pe.set_nt4(exe.read_bytes(), 4, 0))
        results[name] = exe
    return results


def stage_driver(root: Path, out: Path) -> list[Path]:
    """No rebuild, ID injection or registry/IRQ change. Pair is optional."""
    out.mkdir(parents=True, exist_ok=True)
    source = root / 'tools/nt/usosnet'
    result = []
    for inf in ('usosnet9x.inf', 'usosnet.inf'):
        sys = source / 'bin/i386/usosnet.sys'
        inf_path = source / 'inf' / inf
        if sys.is_file() and inf_path.is_file():
            for file in (sys, inf_path):
                dest = out / file.name
                dest.write_bytes(file.read_bytes())
                result.append(dest)
    return list(dict.fromkeys(result))


if __name__ == '__main__':
    root = Path(__file__).resolve().parents[1]
    print(build(root, root / 'zig-out/windows-usos-lan'))
