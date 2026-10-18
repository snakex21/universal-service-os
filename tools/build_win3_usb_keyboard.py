"""USB keyboard for Windows 3.x under CSMWrap (docs/design/bios-via-csmwrap.md):
USOSKEY.COM (DOS TSR, src/platform/bios/msdos/usoskey.S, zig cc + ld.lld at
0100h) and USOSKEY.DRV (Win16 installable driver, src/platform/win3/usoskey.c,
OpenWatcom 2.0 wcc/wlink, no OpenWatcom runtime linked). USB mouse:
USOSMOUS.DRV (Win16 mouse driver, src/platform/win3/usosmous.c) on the
mouse ring of the same TSR (shared block version 4). Windows 1.0x USB mouse:
USOSMS1.DRV (src/platform/win1/usosms1.S, NE file written here).

OpenWatcom is pinned (OW_SNAPSHOT below): the snapshot archive is taken from
tools/cache/openwatcom or tools/cache/buildkit-downloads (build kit), or
downloaded once from the pinned URL and checked by SHA-256; only binnt64,
h and lib286/win are extracted. The compiler's licence (Sybase Open Watcom
Public License 1.0) covers the tools, not this output: the driver links no
OpenWatcom library code (own entry point, -zl, import records only).

  python tools/build_win3_usb_keyboard.py [--out zig-out/dos-native/msdos]
"""
from pathlib import Path
import argparse, hashlib, os, shutil, subprocess, sys, tarfile, urllib.request

ROOT = Path(__file__).resolve().parents[1]
OW_SNAPSHOT = {
    'file': 'ow-snapshot-2026-09-01.tar.xz',
    'url': 'https://github.com/open-watcom/open-watcom-v2/releases/download/2026-09-01-Build/ow-snapshot.tar.xz',
    'sha256': 'bac354f3c75ffa49ff8d70a44e475de7e7c1823fff04b80c14787bd0792c9bdf',
    'license': 'Sybase Open Watcom Public License 1.0 (tools only)',
}
OW_CACHE = ROOT / 'tools/cache/openwatcom'
OW_PARTS = ('./binnt64', './h', './lib286/win', './license.txt')


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def openwatcom() -> Path:
    home = OW_CACHE / ('ow-' + OW_SNAPSHOT['sha256'][:12])
    if (home / 'binnt64/wcc.exe').is_file() and (home / 'lib286/win/windows.lib').is_file():
        return home
    archive = None
    for candidate in (OW_CACHE / OW_SNAPSHOT['file'], ROOT / 'tools/cache/buildkit-downloads' / OW_SNAPSHOT['file']):
        if candidate.is_file():
            archive = candidate
            break
    if archive is None:
        archive = OW_CACHE / OW_SNAPSHOT['file']
        archive.parent.mkdir(parents=True, exist_ok=True)
        print('[DOWNLOAD]', OW_SNAPSHOT['url'], flush=True)
        urllib.request.urlretrieve(OW_SNAPSHOT['url'], archive)
    if sha256(archive) != OW_SNAPSHOT['sha256']:
        raise SystemExit(f'OpenWatcom snapshot hash mismatch: {archive}')
    tmp = home.with_name(home.name + '.tmp')
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir(parents=True)
    with tarfile.open(archive) as t:
        members = [m for m in t.getmembers() if any(m.name == p or m.name.startswith(p + '/') for p in OW_PARTS)]
        t.extractall(tmp, members=members, filter='data')
    shutil.rmtree(home, ignore_errors=True)
    tmp.rename(home)
    return home


def build_tsr(out: Path, work: Path) -> Path:
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(ROOT / 'tools/cache/zig-global'))
    zig = str(ROOT / 'tools/zig/zig.exe')
    obj, elf, com = work / 'usoskey.o', work / 'usoskey.elf', out / 'USOSKEY.COM'
    subprocess.run([zig, 'cc', '-target', 'x86-freestanding-none', '-mcpu=i386', '-c',
                    str(ROOT / 'src/platform/bios/msdos/usoskey.S'), '-o', str(obj)], env=env, check=True)
    subprocess.run([zig, 'ld.lld', '-m', 'elf_i386', '-T', str(ROOT / 'src/platform/bios/msdos/com.ld'),
                    str(obj), '-o', str(elf)], env=env, check=True)
    subprocess.run([zig, 'objcopy', '-O', 'binary', str(elf), str(com)], env=env, check=True)
    data = com.read_bytes()
    if not 0 < len(data) <= 2048 or data[4:8] != b'USKY':
        raise ValueError('unexpected USOSKEY.COM layout')
    return com


def build_kbc(out: Path, work: Path) -> Path:
    """USOSKBC.COM (src/platform/bios/msdos/usoskbc.S): USB keyboard through
    the 8042 and scripted Setup answers for Windows 1.0x-3.0."""
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(ROOT / 'tools/cache/zig-global'))
    zig = str(ROOT / 'tools/zig/zig.exe')
    obj, elf, com = work / 'usoskbc.o', work / 'usoskbc.elf', out / 'USOSKBC.COM'
    subprocess.run([zig, 'cc', '-target', 'x86-freestanding-none', '-mcpu=i386', '-c',
                    str(ROOT / 'src/platform/bios/msdos/usoskbc.S'), '-o', str(obj)], env=env, check=True)
    subprocess.run([zig, 'ld.lld', '-m', 'elf_i386', '-T', str(ROOT / 'src/platform/bios/msdos/com.ld'),
                    str(obj), '-o', str(elf)], env=env, check=True)
    subprocess.run([zig, 'objcopy', '-O', 'binary', str(elf), str(com)], env=env, check=True)
    data = com.read_bytes()
    if not 0 < len(data) <= 4096 or data[4:8] != b'UKBC':
        raise ValueError('unexpected USOSKBC.COM layout')
    sym = elf_symbols(elf)
    if sym['scriptbuf'] - 0x100 != len(data) + (len(data) & 1) and sym['scriptbuf'] - 0x100 != len(data):
        raise ValueError('USOSKBC.COM: the script buffer must follow the image')
    return com


def elf_symbols(elf: Path) -> dict:
    """Symbol name -> value from an ELF32 file (the TSR's labels)."""
    import struct
    data = elf.read_bytes()
    shoff, = struct.unpack_from('<I', data, 0x20)
    shentsize, shnum = struct.unpack_from('<HH', data, 0x2e)
    sections = [struct.unpack_from('<IIIIIIIIII', data, shoff + i * shentsize) for i in range(shnum)]
    symbols = {}
    for sh in sections:
        if sh[1] != 2:                                  # SHT_SYMTAB
            continue
        strtab = sections[sh[6]]
        for off in range(sh[4], sh[4] + sh[5], 16):
            name_off, value = struct.unpack_from('<II', data, off)
            end = data.index(b'\0', strtab[4] + name_off)
            symbols[data[strtab[4] + name_off:end].decode()] = value
    return symbols


def write_tsr_header(com: Path, elf: Path, work: Path) -> Path:
    """usoskey_tsr.h: the resident part of USOSKEY.COM (0100h up to
    resident_end) and its handler / old-vector offsets, so USOSKEY.DRV can
    install it itself where no AUTOEXEC.BAT runs it (Windows Me)."""
    sym = elf_symbols(elf)
    image = com.read_bytes()[:sym['resident_end'] - 0x100]
    names = ['shared', 'int08', 'int09', 'int15', 'int16', 'int1c', 'int2f', 'old08', 'old09', 'old15', 'old16', 'old1c', 'old2f']
    lines = ['/* Generated by tools/build_win3_usb_keyboard.py from USOSKEY.COM. */']
    lines += [f'#define TSR_{n.upper()} 0x{sym[n]:04X}' for n in names]
    lines.append('static const BYTE tsr_image[%d] = {' % len(image))
    for i in range(0, len(image), 16):
        lines.append('    ' + ', '.join('0x%02X' % b for b in image[i:i + 16]) + ',')
    lines.append('};')
    header = work / 'usoskey_tsr.h'
    header.write_text('\n'.join(lines) + '\n')
    return header


def build_driver(out: Path, work: Path) -> Path:
    ow = openwatcom()
    env = dict(os.environ, WATCOM=str(ow), INCLUDE=f'{work};{ow / "h"};{ow / "h/win"}',
               PATH=str(ow / 'binnt64') + os.pathsep + os.environ.get('PATH', ''))
    obj = work / 'usoskey.obj'
    subprocess.run([str(ow / 'binnt64/wcc.exe'), '-q', '-bt=windows', '-bd', '-ms', '-zu', '-zl', '-s', '-3', '-osi',
                    '-w3', '-we', '-fo=' + str(obj), str(ROOT / 'src/platform/win3/usoskey.c')], env=env, check=True, cwd=work)
    drv = out / 'USOSKEY.DRV'
    subprocess.run([str(ow / 'binnt64/wlink.exe'), '@' + str(ROOT / 'src/platform/win3/usoskey.lnk'),
                    'file', str(obj), 'name', str(drv), 'option', 'map=' + str(work / 'usoskey.map')], env=env, check=True, cwd=work)
    data = drv.read_bytes()
    ne = int.from_bytes(data[0x3c:0x3e], 'little')
    if data[ne:ne + 2] != b'NE' or b'DRIVERPROC' not in data:
        raise ValueError('USOSKEY.DRV is not the expected NE driver')
    libs = (work / 'usoskey.map').read_text(errors='replace')
    if 'clib' in libs.lower():
        raise ValueError('USOSKEY.DRV must not link the OpenWatcom C library')
    return drv


def build_mouse_driver(out: Path, work: Path) -> Path:
    ow = openwatcom()
    env = dict(os.environ, WATCOM=str(ow), INCLUDE=f'{work};{ow / "h"};{ow / "h/win"}',
               PATH=str(ow / 'binnt64') + os.pathsep + os.environ.get('PATH', ''))
    obj = work / 'usosmous.obj'
    subprocess.run([str(ow / 'binnt64/wcc.exe'), '-q', '-bt=windows', '-bd', '-ms', '-zu', '-zl', '-s', '-3', '-osi',
                    '-w3', '-we', '-fo=' + str(obj), str(ROOT / 'src/platform/win3/usosmous.c')], env=env, check=True, cwd=work)
    drv = out / 'USOSMOUS.DRV'
    subprocess.run([str(ow / 'binnt64/wlink.exe'), '@' + str(ROOT / 'src/platform/win3/usosmous.lnk'),
                    'file', str(obj), 'name', str(drv), 'option', 'map=' + str(work / 'usosmous.map')], env=env, check=True, cwd=work)
    data = drv.read_bytes()
    ne = int.from_bytes(data[0x3c:0x3e], 'little')
    if data[ne:ne + 2] != b'NE' or b'MOUSEGETINTVECT' not in data or b'MOUSE' not in data:
        raise ValueError('USOSMOUS.DRV is not the expected NE mouse driver (module MOUSE)')
    if 'clib' in (work / 'usosmous.map').read_text(errors='replace').lower():
        raise ValueError('USOSMOUS.DRV must not link the OpenWatcom C library')
    return drv


def ne_driver(code: bytes, module: str, description: str, exports, stub_text: str) -> bytes:
    """A Windows 1.0x driver file in the layout of the shipped NOMOUSE.DRV:
    MZ stub, NE header (linker version 4.0, library without automatic data
    segment, flags 8004h), one fixed preloaded code segment without
    relocations (512-byte alignment), resident name = module, entry table
    with one bundle for segment 1, non-resident names = description plus
    the exported names. exports: [(ordinal, NAME, offset)], ordinals 1..n."""
    import struct
    msg = stub_text.encode('ascii') + b'\r\n$'
    stub_code = bytes([0x0e, 0x1f, 0xba, 0x0e, 0x00, 0xb4, 0x09, 0xcd, 0x21,   # push cs; pop ds; mov dx,0Eh; mov ah,9; int 21h
                       0xb8, 0x01, 0x4c, 0xcd, 0x21]) + msg                    # mov ax,4C01h; int 21h
    ne_off = 0x40 + ((len(stub_code) + 15) & ~15)
    stub_size = ne_off
    mz = bytearray(0x40)
    struct.pack_into('<2s13H', mz, 0, b'MZ', stub_size % 512, (stub_size + 511) // 512, 0, 4, 0x10, 0xffff,
                     0, 0xb8, 0, 0, 0, 0x40, 0)
    struct.pack_into('<I', mz, 0x3c, ne_off)
    head = bytes(mz) + stub_code.ljust(ne_off - 0x40, b'\0')
    exports = sorted(exports)
    if [o for o, _, _ in exports] != list(range(1, len(exports) + 1)):
        raise ValueError('ordinals must be 1..n')
    segtab = 0x40
    restab = segtab + 8
    resnames = bytes([len(module)]) + module.encode() + b'\0\0' + b'\0'
    modtab = restab + len(resnames)
    enttab = modtab                                     # no module references, no imported names
    entries = bytes([len(exports), 1]) + b''.join(struct.pack('<BH', 1, off) for _, _, off in exports) + b'\0\0'
    nres = bytes([len(description)]) + description.encode() + b'\0\0'
    for o, name, _ in sorted(exports, key=lambda e: e[1]):
        nres += bytes([len(name)]) + name.encode() + struct.pack('<H', o)
    nres += b'\0'
    tables_end = ne_off + enttab + len(entries)
    nres_off = tables_end
    seg_off = (nres_off + len(nres) + 511) & ~511
    hdr = bytearray(0x40)
    struct.pack_into('<2sBBHHIHHHHHHHHHHHHHHHHIHH', hdr, 0, b'NE', 4, 0, enttab, len(entries), 0, 0x8004,
                     0, 0, 0, 0, 0, 0, 0,               # no automatic data, heap, stack, CS:IP, SS:SP
                     1, 0, len(nres), segtab, restab, restab, modtab, modtab, nres_off, 0, 9)  # alignment shift 9
    seg = struct.pack('<HHHH', seg_off >> 9, len(code), 0x0040, len(code))
    body = bytes(hdr) + seg + resnames + entries
    out = bytearray(head + body + nres)
    out += b'\0' * (seg_off - len(out))
    out += code
    return bytes(out)


def build_win1_mouse(out: Path, work: Path) -> Path:
    """USOSMS1.DRV (src/platform/win1/usosms1.S): BIOS pointing-device
    (USB under CSMWrap) mouse driver for Windows 1.0x, module MOUSE."""
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(ROOT / 'tools/cache/zig-global'))
    zig = str(ROOT / 'tools/zig/zig.exe')
    obj, elf, raw = work / 'usosms1.o', work / 'usosms1.elf', work / 'usosms1.bin'
    subprocess.run([zig, 'cc', '-target', 'x86-freestanding-none', '-mcpu=i386', '-c',
                    str(ROOT / 'src/platform/win1/usosms1.S'), '-o', str(obj)], env=env, check=True)
    subprocess.run([zig, 'ld.lld', '-m', 'elf_i386', '-T', str(ROOT / 'src/platform/win1/drv.ld'),
                    str(obj), '-o', str(elf)], env=env, check=True)
    subprocess.run([zig, 'objcopy', '-O', 'binary', str(elf), str(raw)], env=env, check=True)
    code = raw.read_bytes()
    sym = elf_symbols(elf)
    if not 0 < len(code) <= 2048 or code[14:18] != b'USM1' or sym['seg_end'] != len(code):
        raise ValueError('unexpected USOSMS1 segment layout')
    drv = out / 'USOSMS1.DRV'
    drv.write_bytes(ne_driver(code, 'MOUSE', 'USOS USB mouse (BIOS pointing device)',
                              [(1, 'INQUIRE', sym['inquire']), (2, 'ENABLE', sym['enable']), (3, 'DISABLE', sym['disable'])],
                              'USOSMS1.DRV is a Windows 1.0x mouse driver.'))
    return drv


def build(root: Path = ROOT, out: Path | None = None):
    out = (out or root / 'zig-out/dos-native/msdos').resolve()
    work = root / 'zig-out/win3-usb-keyboard'
    out.mkdir(parents=True, exist_ok=True)
    work.mkdir(parents=True, exist_ok=True)
    com = build_tsr(out, work)
    write_tsr_header(com, work / 'usoskey.elf', work)
    drv = build_driver(out, work)
    mouse = build_mouse_driver(out, work)
    kbc = build_kbc(out, work)
    win1 = build_win1_mouse(out, work)
    from usos_keyscript import build_all as build_keyscripts
    scripts = build_keyscripts(out)
    print(f'[PASS] Windows 3.x USB keyboard and mouse: {com.name} {com.stat().st_size} bytes, {drv.name} {drv.stat().st_size} bytes, '
          f'{mouse.name} {mouse.stat().st_size} bytes, {win1.name} {win1.stat().st_size} bytes, {kbc.name} {kbc.stat().st_size} bytes, {len(scripts)} key scripts '
          f'(OpenWatcom snapshot {OW_SNAPSHOT["sha256"][:12]})')


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--out', type=Path)
    a = p.parse_args()
    build(ROOT, a.out)
