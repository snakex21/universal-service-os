"""Build the windowless USOS display tool; all outputs/caches are portable."""
from pathlib import Path
import importlib.util
import os
import subprocess
import sys

NAME = 'USOSRES.EXE'

def build(root: Path, output: Path, win9x: bool = False, registrar: bool = False) -> Path:
    zig = Path(os.environ.get('USOS_ZIG', root/'tools/zig/zig.exe'))
    output.mkdir(parents=True, exist_ok=True)
    temporary = output/'tmp'
    temporary.mkdir(exist_ok=True)
    env = dict(os.environ, TEMP=str(temporary), TMP=str(temporary),
               ZIG_GLOBAL_CACHE_DIR=str(root/'tools/cache/zig-global'),
               ZIG_LOCAL_CACHE_DIR=str(output/'zig-cache'))
    exe = output/('USOSNT3.EXE' if registrar else NAME)
    source = 'nt3/usosnt3/src/usosnt3.c' if registrar else 'windows_usos_res.c'
    defines = ['-DUSOSRES_9X'] if win9x else []
    if registrar:
        defines += ['-DWINVER=0x0400', '-D_WIN32_WINNT=0x0400']
    subprocess.run([str(zig), 'cc', '-target', 'x86-windows-gnu', '-mcpu=i586', '-Os', '-nostdlib',
                    '-fno-stack-protector', '-fno-builtin', '-I'+str(zig.parent/'lib/libc/include/any-windows-any'),
                    *defines, str(root/'tools'/source), '-Wl,--entry,entry',
                    '-Wl,--subsystem,'+('console' if registrar else 'windows'),
                    '-lkernel32', '-ladvapi32', '-o', str(exe)],
                   env=env, check=True)
    spec = importlib.util.spec_from_file_location('res_pe_version', root/'tools/nt4/pe_nt4_version.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    exe.write_bytes(module.set_nt4(exe.read_bytes(), 3, 10))
    return exe


def build_nt3(root: Path, output: Path | None = None) -> Path:
    """Single entry point shared by the package and its import/flow tests."""
    return build(root, output or root/'zig-out/windows-usos-res', registrar=True)


def build_nt3_answer(root: Path, output: Path | None = None) -> Path:
    """USOSANS3.EXE (tools/nt3/usosans3): the native NT 3.5x GUI-mode Setup
    page recorder, Win32 GUI subsystem, kernel32 + user32 only, PE 3.10."""
    zig = Path(os.environ.get('USOS_ZIG', root/'tools/zig/zig.exe'))
    output = output or root/'zig-out/windows-usos-res'
    output.mkdir(parents=True, exist_ok=True)
    temporary = output/'tmp'
    temporary.mkdir(exist_ok=True)
    env = dict(os.environ, TEMP=str(temporary), TMP=str(temporary),
               ZIG_GLOBAL_CACHE_DIR=str(root/'tools/cache/zig-global'),
               ZIG_LOCAL_CACHE_DIR=str(output/'zig-cache'))
    exe = output/'USOSANS3.EXE'
    subprocess.run([str(zig), 'cc', '-target', 'x86-windows-gnu', '-mcpu=i586', '-Os', '-nostdlib',
                    '-fno-stack-protector', '-fno-builtin', '-I'+str(zig.parent/'lib/libc/include/any-windows-any'),
                    '-DWINVER=0x0400', '-D_WIN32_WINNT=0x0400', str(root/'tools/nt3/usosans3/usosans3.c'),
                    '-Wl,--entry,entry', '-Wl,--subsystem,windows', '-lkernel32', '-luser32', '-o', str(exe)],
                   env=env, check=True)
    spec = importlib.util.spec_from_file_location('res_pe_version', root/'tools/nt4/pe_nt4_version.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    exe.write_bytes(module.set_nt4(exe.read_bytes(), 3, 10))
    return exe


def build_nt31_answer(root: Path, output: Path | None = None) -> Path:
    """USOSANS31.EXE (tools/nt3/native31): the native NT 3.1 GUI-mode Setup
    page answerer (Date/Time, AS Domain Settings) on the USOSANS3 recorder,
    Win32 GUI subsystem, kernel32 + user32 only, i486, PE 3.10."""
    zig = Path(os.environ.get('USOS_ZIG', root/'tools/zig/zig.exe'))
    output = output or root/'zig-out/windows-usos-res'
    output.mkdir(parents=True, exist_ok=True)
    temporary = output/'tmp'
    temporary.mkdir(exist_ok=True)
    env = dict(os.environ, TEMP=str(temporary), TMP=str(temporary),
               ZIG_GLOBAL_CACHE_DIR=str(root/'tools/cache/zig-global'),
               ZIG_LOCAL_CACHE_DIR=str(output/'zig-cache'))
    exe = output/'USOSANS31.EXE'
    subprocess.run([str(zig), 'cc', '-target', 'x86-windows-gnu', '-mcpu=i486', '-Os', '-nostdlib',
                    '-fno-stack-protector', '-fno-builtin', '-I'+str(zig.parent/'lib/libc/include/any-windows-any'),
                    '-DWINVER=0x0400', '-D_WIN32_WINNT=0x0400', str(root/'tools/nt3/native31/usosans31.c'),
                    '-Wl,--entry,entry', '-Wl,--subsystem,windows', '-lkernel32', '-luser32', '-o', str(exe)],
                   env=env, check=True)
    spec = importlib.util.spec_from_file_location('res_pe_version', root/'tools/nt4/pe_nt4_version.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    exe.write_bytes(module.set_nt4(exe.read_bytes(), 3, 10))
    return exe


def build_collector(root: Path, output: Path) -> Path:
    """Use an explicit toolchain, otherwise the buildkit's pinned resolver."""
    if os.environ.get('USOS_WATCOM'):
        watcom = Path(os.environ['USOS_WATCOM'])
    else:
        from build_win3_usb_keyboard import openwatcom
        watcom = openwatcom()
    compiler = watcom/'binnt64/wcc.exe'
    if not compiler.is_file():
        raise FileNotFoundError('Set USOS_WATCOM to the OpenWatcom folder containing binnt64/wcc.exe')
    output.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, WATCOM=str(watcom), INCLUDE=str(watcom/'h')+';'+str(watcom/'h/win'),
               PATH=str(watcom/'binnt64')+os.pathsep+os.environ.get('PATH', ''), TEMP=str(output), TMP=str(output))
    obj, exe = output/'usosvbi.obj', output/'USOSVBI.EXE'
    subprocess.run([str(compiler), '-q', '-bt=windows', '-ms', '-zl', '-s', '-3', '-osi', '-w3', '-we',
                    '-fo='+str(obj), str(root/'tools/windows9x_vbe_collect.c')], env=env, check=True)
    subprocess.run([str(watcom/'binnt64/wlink.exe'), '@'+str(root/'tools/windows9x_vbe_collect.lnk'),
                    'file', str(obj), 'name', str(exe), 'option', 'map='+str(output/'usosvbi.map')], env=env, check=True)
    return exe

if __name__ == '__main__':
    root = Path(__file__).resolve().parents[1]
    out = Path(sys.argv[1]) if len(sys.argv)>1 else root/'zig-out/windows-usos-res'
    print(build(root, out))
    print(build(root, out, registrar=True))
    print(build(root, out/'9x', win9x=True))
    print(build_collector(root, out/'9x'))
