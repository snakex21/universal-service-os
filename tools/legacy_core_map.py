"""Size map of the Legacy BIOS Core: sections, largest functions and data.

Rebuilds the Core object exactly like tools/build_legacy_bios.ps1, but with
symbols (-fno-strip; the code is identical), links it with the same linker
script and prints where the bytes go. Nothing in zig-out/legacy-bios changes.

  python tools/legacy_core_map.py [--top 40] [--out DIR]
"""
from pathlib import Path
import argparse, os, re, struct, subprocess, sys, tempfile

ROOT = Path(__file__).resolve().parents[1]
ZIG = ROOT / 'tools/zig/zig.exe'
NM = Path('C:/msys64/mingw64/bin/nm.exe')
SLOT_PAYLOAD = 512 * 512 - 32 * 512  # Core slot minus the fixed bootstrap window


def build(out: Path) -> Path:
    generated = ROOT / 'zig-out/legacy-bios'
    modules = {'build_info': 'legacy_build_info.zig', 'catalog_mode': 'legacy_catalog_mode.zig', 'test_mode': 'legacy_test_mode.zig'}
    for name in modules.values():
        if not (generated / name).is_file():
            raise SystemExit('run tools/build_legacy_bios.ps1 once first (missing ' + name + ')')
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(ROOT / 'tools/cache/zig-global'))
    obj = out / 'core-main.o'
    subprocess.run([str(ZIG), 'build-obj', '-target', 'x86-freestanding-none', '-mcpu=i386', '-O', 'ReleaseSmall', '-fno-strip',
                    '--dep', 'storage', '--dep', 'catalog', '--dep', 'menu_policy', '--dep', 'graphics', '--dep', 'build_info', '--dep', 'catalog_mode', '--dep', 'test_mode',
                    '-Mroot=' + str(ROOT / 'src/platform/bios/core_main.zig'), '-Mstorage=' + str(ROOT / 'src/storage/root.zig'),
                    '-Mcatalog=' + str(ROOT / 'src/catalog_module.zig'), '-Mmenu_policy=' + str(ROOT / 'src/gui/menu_policy.zig'),
                    '-Mgraphics=' + str(ROOT / 'src/legacy_graphics_module.zig'),
                    *['-M%s=%s' % (k, generated / v) for k, v in modules.items()], '-femit-bin=' + str(obj)], check=True, env=env)
    elf = out / 'core.elf'
    subprocess.run([str(ZIG), 'cc', '-target', 'x86-freestanding-none', '-mcpu=i386', '-nostdlib', '-nodefaultlibs',
                    '-Wl,-T,' + str(ROOT / 'src/platform/bios/core.ld'), '-Wl,--entry=core_start',
                    str(ROOT / 'src/platform/bios/core.S'), str(obj), '-o', str(elf)], check=True, env=env)
    return elf


def sections(elf: bytes):
    shoff, = struct.unpack_from('<I', elf, 0x20)
    shnum, shstrndx = struct.unpack_from('<HH', elf, 0x30)
    headers = [struct.unpack_from('<IIIIII', elf, shoff + i * 40) for i in range(shnum)]
    names = headers[shstrndx][4]
    out = []
    for name, typ, flags, addr, offset, size in headers:
        label = elf[names + name:elf.index(b'\0', names + name)].decode()
        if flags & 2 and typ != 8:  # SHF_ALLOC, not NOBITS
            out.append((label, addr, offset, size))
    return out


def module_of(symbol: str) -> str:
    if symbol.startswith('__anon'):
        return '(anonymous constants)'
    parts = re.split(r'\.', symbol)
    return parts[0] if len(parts) > 1 else '(assembly)'


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--top', type=int, default=40)
    p.add_argument('--out', type=Path)
    a = p.parse_args()
    out = a.out or Path(tempfile.mkdtemp(prefix='usos-core-map-'))
    out.mkdir(parents=True, exist_ok=True)
    elf_path = build(out)
    elf = elf_path.read_bytes()
    secs = sections(elf)
    # objcopy -O binary emits the span from the first to the last loaded byte.
    image = max(addr + size for _, addr, _, size in secs) - min(addr for _, addr, _, _ in secs)
    print('== Sections (bytes)')
    for label, addr, _, size in secs:
        print('  %-8s 0x%05x %7d' % (label, addr, size))
    print('  image    %7d of %d (headroom %d)' % (image, SLOT_PAYLOAD, SLOT_PAYLOAD - image))
    symbols = []
    for line in subprocess.run([str(NM), '-S', '--size-sort', str(elf_path)], capture_output=True, text=True, check=True).stdout.splitlines():
        fields = line.split()
        if len(fields) == 4 and fields[3] != 'core_main':  # core_main is aliased by core_main.core_main
            symbols.append((int(fields[1], 16), fields[2].lower(), fields[3], int(fields[0], 16)))
    by_module = {}
    for size, kind, name, _ in symbols:
        by_module[module_of(name)] = by_module.get(module_of(name), 0) + size
    print('== By module (sized symbols)')
    for name, size in sorted(by_module.items(), key=lambda kv: -kv[1])[:a.top]:
        print('  %7d  %s' % (size, name))
    print('== Largest functions')
    for size, kind, name, _ in sorted((s for s in symbols if s[1] == 't'), reverse=True)[:a.top]:
        print('  %7d  %s' % (size, name))
    print('== Largest data')
    def read(addr, size):
        for _, base, offset, length in secs:
            if base <= addr < base + length:
                return elf[offset + addr - base:offset + addr - base + size]
        return b''
    for size, kind, name, addr in sorted((s for s in symbols if s[1] in 'rd'), reverse=True)[:a.top]:
        data = read(addr, size)
        zero = data.count(0)
        print('  %7d  %-40s %3d%% zero' % (size, name, 100 * zero // max(1, len(data))))
    print('ELF with symbols:', elf_path)


if __name__ == '__main__':
    main()
