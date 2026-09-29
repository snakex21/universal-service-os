"""USB keyboard for Windows 3.x under CSMWrap (docs/design/bios-via-csmwrap.md):
USOSKEY.COM (DOS TSR, src/platform/bios/msdos/usoskey.S, zig cc + ld.lld at
0100h) and USOSKEY.DRV (Win16 installable driver, src/platform/win3/usoskey.c,
OpenWatcom 2.0 wcc/wlink, no OpenWatcom runtime linked).

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


def build_driver(out: Path, work: Path) -> Path:
    ow = openwatcom()
    env = dict(os.environ, WATCOM=str(ow), INCLUDE=f'{ow / "h"};{ow / "h/win"}',
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


def build(root: Path = ROOT, out: Path | None = None):
    out = (out or root / 'zig-out/dos-native/msdos').resolve()
    work = root / 'zig-out/win3-usb-keyboard'
    out.mkdir(parents=True, exist_ok=True)
    work.mkdir(parents=True, exist_ok=True)
    com = build_tsr(out, work)
    drv = build_driver(out, work)
    print(f'[PASS] Windows 3.x USB keyboard: {com.name} {com.stat().st_size} bytes, {drv.name} {drv.stat().st_size} bytes '
          f'(OpenWatcom snapshot {OW_SNAPSHOT["sha256"][:12]})')


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--out', type=Path)
    a = p.parse_args()
    build(ROOT, a.out)
