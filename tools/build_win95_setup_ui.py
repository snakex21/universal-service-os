"""Build the small static Linux classifier used only for Windows 95 input."""
from pathlib import Path
import argparse
import os
import subprocess


def build(root: Path, out: Path, zig: Path | None = None) -> Path:
    root, out = root.resolve(), out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    compiler = zig or Path(os.environ.get('USOS_ZIG', str(root / 'tools/zig/zig.exe')))
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(root / 'tools/cache/zig-global'),
               ZIG_LOCAL_CACHE_DIR=str(out / 'cache'), TMP=str(out), TEMP=str(out))
    binary = out / 'win95-setup-ui'
    subprocess.run([str(compiler), 'cc', '-target', 'x86_64-linux-musl', '-static', '-Os', '-s',
                    '-Wall', '-Wextra', '-Werror', str(root / 'tools/win95_setup_ui.c'), '-o', str(binary)],
                   env=env, check=True)
    if binary.read_bytes()[:4] != b'\x7fELF':
        raise RuntimeError('Expected a static Linux ELF classifier')
    events = out / 'win95-rfb-events'
    subprocess.run([str(compiler), 'cc', '-target', 'x86_64-linux-musl', '-static', '-Os', '-s',
                    '-Wall', '-Wextra', '-Werror', str(root / 'tools/win95_rfb_events.c'), '-o', str(events)],
                   env=env, check=True)
    if events.read_bytes()[:4] != b'\x7fELF':
        raise RuntimeError('Expected a static Linux ELF event receiver')
    return binary


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--project-root', type=Path, required=True)
    p.add_argument('--output-dir', type=Path, required=True)
    p.add_argument('--zig', type=Path)
    a = p.parse_args()
    print(build(a.project_root, a.output_dir, a.zig))
