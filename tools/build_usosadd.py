"""USOSADD.EXE, the legacy post-install runner for Windows 95/98/Me/NT 4.0
(docs/design/legacy-compat-pack.md, src/platform/win32_legacy/usosadd).

Built with OpenWatcom 2.0 wcc386/wlink from the pinned snapshot that
tools/build_win3_usb_keyboard.py uses (same archive and SHA-256; this script
extracts binnt64, h, h/nt and lib386/nt into its own cache folder). No
OpenWatcom library code is linked: own entry point (ua_start), -zl, import
libraries only, so the Sybase Open Watcom Public License covers the tools,
not this output. The result is checked: i386 PE, subsystem 4.0 GUI, imports
only KERNEL32/USER32/ADVAPI32.

  python tools/build_usosadd.py [--out zig-out/legacy-pack]
"""
from pathlib import Path
import argparse, os, shutil, struct, subprocess, sys, tarfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_win3_usb_keyboard import OW_SNAPSHOT, OW_CACHE, ROOT, sha256  # noqa: E402

SRC = ROOT / 'src/platform/win32_legacy/usosadd'
SOURCES = ('str.c', 'ini.c', 'detect.c', 'plan.c', 'cmd.c', 'state.c', 'main.c')
OW_PARTS = ('./binnt64', './h', './lib386/nt', './license.txt')
ALLOWED_IMPORTS = {'KERNEL32.DLL', 'USER32.DLL', 'ADVAPI32.DLL'}


def openwatcom386() -> Path:
    home = OW_CACHE / ('ow386-' + OW_SNAPSHOT['sha256'][:12])
    if (home / 'binnt64/wcc386.exe').is_file() and (home / 'lib386/nt/kernel32.lib').is_file():
        return home
    archive = None
    for candidate in (OW_CACHE / OW_SNAPSHOT['file'], ROOT / 'tools/cache/buildkit-downloads' / OW_SNAPSHOT['file']):
        if candidate.is_file():
            archive = candidate
            break
    if archive is None:
        from build_win3_usb_keyboard import openwatcom  # downloads and pins the archive once
        openwatcom()
        archive = OW_CACHE / OW_SNAPSHOT['file']
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


def pe_imports(data: bytes) -> tuple[dict, set[str]]:
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    if data[pe:pe + 4] != b'PE\0\0':
        raise ValueError('not a PE file')
    machine, nsec = struct.unpack_from('<HH', data, pe + 4)
    opt = pe + 24
    magic = struct.unpack_from('<H', data, opt)[0]
    subsys_major, subsys_minor = struct.unpack_from('<HH', data, opt + 48)
    subsystem = struct.unpack_from('<H', data, opt + 68)[0]
    ndirs = struct.unpack_from('<I', data, opt + 92)[0]
    imp_rva = struct.unpack_from('<I', data, opt + 96 + 8)[0] if ndirs > 1 else 0
    sections = []
    sh = opt + struct.unpack_from('<H', data, pe + 20)[0]
    for i in range(nsec):
        va, vsize, raw_size, raw_ptr = (struct.unpack_from('<I', data, sh + i * 40 + 12)[0],
                                        struct.unpack_from('<I', data, sh + i * 40 + 8)[0],
                                        struct.unpack_from('<I', data, sh + i * 40 + 16)[0],
                                        struct.unpack_from('<I', data, sh + i * 40 + 20)[0])
        sections.append((va, max(vsize, raw_size), raw_ptr))

    def off(rva):
        for va, size, ptr in sections:
            if va <= rva < va + size:
                return ptr + rva - va
        raise ValueError(f'rva {rva:#x} outside sections')

    names = set()
    if imp_rva:
        d = off(imp_rva)
        while True:
            name_rva = struct.unpack_from('<I', data, d + 12)[0]
            if name_rva == 0:
                break
            o = off(name_rva)
            names.add(data[o:data.index(b'\0', o)].decode('ascii').upper())
            d += 20
    info = {'machine': machine, 'magic': magic, 'subsystem': subsystem, 'subsystem_version': (subsys_major, subsys_minor)}
    return info, names


def check_exe(exe: Path) -> dict:
    info, names = pe_imports(exe.read_bytes())
    if info['machine'] != 0x14c or info['magic'] != 0x10b:
        raise ValueError(f'{exe.name}: not an i386 PE32')
    if info['subsystem'] != 2 or info['subsystem_version'] != (4, 0):
        raise ValueError(f'{exe.name}: subsystem {info["subsystem"]} {info["subsystem_version"]}, want GUI 4.0')
    extra = names - ALLOWED_IMPORTS
    if extra:
        raise ValueError(f'{exe.name}: unexpected imports {sorted(extra)}')
    info['imports'] = sorted(names)
    return info


def build(out: Path | None = None) -> Path:
    ow = openwatcom386()
    out = (out or ROOT / 'zig-out/legacy-pack').resolve()
    work = ROOT / 'zig-out/usosadd-build'
    out.mkdir(parents=True, exist_ok=True)
    work.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, WATCOM=str(ow), INCLUDE=f'{ow / "h"};{ow / "h/nt"}',
               PATH=str(ow / 'binnt64') + os.pathsep + os.environ.get('PATH', ''))
    objs = []
    for name in SOURCES:
        # The runner calls the ANSI API: Polish strings are written as cp1250
        # escapes, so the sources stay ASCII (no editor or code page surprises).
        if not (SRC / name).read_bytes().isascii():
            raise ValueError(f'{name}: non-ASCII bytes; write Polish letters as cp1250 octal escapes')
        obj = work / (Path(name).stem + '.obj')
        subprocess.run([str(ow / 'binnt64/wcc386.exe'), '-q', '-bt=nt', '-mf', '-3r', '-zl', '-s', '-os', '-zq',
                        '-w4', '-we', '-wcd=202', '-fo=' + str(obj), str(SRC / name)], env=env, check=True, cwd=work)
        objs.append(obj)
    exe = out / 'USOSADD.EXE'
    directives = [
        'format windows nt', 'runtime windows=4.0', 'option quiet', 'option start=_ua_start',
        'option stack=256k', 'option map=' + str(work / 'usosadd.map'), f'libpath {ow / "lib386/nt"}',
        'library kernel32,user32,advapi32', 'name ' + str(exe),
    ] + ['file ' + str(o) for o in objs]
    lnk = work / 'usosadd.lnk'
    lnk.write_text('\n'.join(directives) + '\n')
    subprocess.run([str(ow / 'binnt64/wlink.exe'), '@' + str(lnk)], env=env, check=True, cwd=work)
    mapped = (work / 'usosadd.map').read_text(errors='replace').lower()
    if 'clib' in mapped or 'plib' in mapped:
        raise ValueError('USOSADD.EXE must not link the OpenWatcom C library')
    info = check_exe(exe)
    print(f'[PASS] USOSADD.EXE {exe.stat().st_size} bytes, PE i386 subsystem 4.0, imports {", ".join(info["imports"])} '
          f'(OpenWatcom snapshot {OW_SNAPSHOT["sha256"][:12]})')
    return exe


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--out', type=Path)
    a = p.parse_args()
    build(a.out)
