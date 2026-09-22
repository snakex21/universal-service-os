"""Build the small real-mode DOS restart/command-prefill helper."""
from pathlib import Path
import os
import subprocess


def build(root: Path, output_dir: Path | None = None) -> Path:
    out = output_dir if output_dir is not None else root / 'zig-out/dos-native/msdos'
    out.mkdir(parents=True, exist_ok=True)
    obj_dir = out / 'obj' if output_dir is not None else root / 'zig-out/dos-reboot'
    obj_dir.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(root / 'tools/cache/zig-global'))
    zig = str(root / 'tools/zig/zig.exe')
    obj = obj_dir / 'reboot.o'
    binary = out / 'REBOOT.COM'
    subprocess.run([zig, 'cc', '-target', 'x86-freestanding-none', '-mcpu=i386',
                    '-c', str(root / 'src/platform/bios/msdos/reboot.S'),
                    '-o', str(obj)], env=env, check=True)
    subprocess.run([zig, 'objcopy', '-O', 'binary', '-j', '.rodata.dos_reboot',
                    str(obj), str(binary)], env=env, check=True)
    if not 0 < binary.stat().st_size <= 1024:
        raise ValueError('Unexpected DOS restart helper size')
    return binary


if __name__ == '__main__':
    print(build(Path(__file__).resolve().parents[1]))
