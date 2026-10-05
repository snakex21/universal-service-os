"""Windows 95/98/Me support files for the BIOS DOS Setup path
(docs/win9x-modern-2026-09-30.md), in zig-out/dos-native/win9x
(the stick's EFI\\USOS\\dos-native\\win9x):

  U9FIX.COM     SYSTEM.INI memory settings at every start
                (src/platform/bios/win9x/u9fix.S, zig cc + ld.lld at 0100h)
  U9FIX.TXT     what it does, licence and source location
  MSBATCH.INF   the USOS default answer (src/platform/bios/win9x/msbatch.inf)
  USOSVESA.INF  VESA display driver INF (src/platform/bios/win9x/usosvesa.inf,
                MODIFIED from vmdisp9x.inf)
  VESAMINI.DRV, VESAMINI.VXD, VMHAL9X.DLL, VMHAL486.DLL, VMDISP9X.DLL
                vmdisp9x 1.2025.0.119 + VMHal9x, unmodified (MIT,
                tools/vendor/vmdisp9x, checked against manifest.json)
  VMDISP9X.TXT  their SOURCES.txt + MIT licence
  VMDISP9X.TGZ  the vmdisp9x source archive
  USOSKEY.COM, USOSKEY.DRV, VBMOUSE.EXE, VBMOUSE.DRV, VBADOS.TXT
                the USB keyboard bridge (USOS) and VBADOS 0.67 (GPL-2.0+) of
                the MS-DOS support, for installs under CSMWrap
  XHCI98.SYS, XHCI98.INF, XHCI98.TXT
                xhci98 1.1.1.0-usos3-w9x (GPL-2.0-only, MODIFIED: polling,
                Windows 98 SE build; tools/vendor/xhci98/1.1.1.0-usos3-w9x,
                checked against manifest.json): native USB keyboard and mouse
                in 98 SE under CSMWrap. INSTALL.BAT puts them into the Setup
                folder only next to STACK.CAB, the cabinet of the user's USB
                2.0 stack installer (DATA Drivers/Windows 98 SE/USB,
                tools/w9x_csmwrap_target.sh)

Also built, not staged yet (hardware diagnostics, copied by hand):
  USOSDIAG.COM  timer tick / PIC / PIT, INT 15h memory, INT 13h, HPET report
  USOSHPET.COM  clears HPET LegacyReplacement (src/platform/bios/win9x/usosdiag.S)

USOS code is GPL-3.0-or-later; no Microsoft files.

  python tools/build_win9x_support.py [--out zig-out/dos-native/win9x]
"""
from pathlib import Path
import argparse, hashlib, json, os, shutil, subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src/platform/bios/win9x'
VMDISP = ROOT / 'tools/vendor/vmdisp9x/1.2025.0.119'
XHCI98 = ROOT / 'tools/vendor/xhci98/1.1.1.0-usos3-w9x'
XHCI98_FILES = {'release-x86/xhci98.sys': 'XHCI98.SYS', 'release-x86/xhci98.inf': 'XHCI98.INF'}
VMDISP_FILES = {'vesamini.drv': 'VESAMINI.DRV', 'vesamini.vxd': 'VESAMINI.VXD', 'vmhal9x.dll': 'VMHAL9X.DLL',
                'vmhal486.dll': 'VMHAL486.DLL', 'vmdisp9x.dll': 'VMDISP9X.DLL'}
# What the Legacy Core copies to the RAM disk (dos_native_iso.zig win9x_helpers).
FILES = ('U9FIX.COM', 'U9FIX.TXT', 'USOSVESA.INF', 'VESAMINI.DRV', 'VESAMINI.VXD', 'VMHAL9X.DLL',
         'VMHAL486.DLL', 'VMDISP9X.DLL', 'VMDISP9X.TXT') + (
    # Under CSMWrap: the Windows 3.x USB keyboard bridge and VBADOS work in
    # Windows 9x too (copied from the MS-DOS support, built before this).
    'USOSKEY.COM', 'USOSKEY.DRV', 'VBMOUSE.EXE', 'VBMOUSE.DRV', 'VBADOS.TXT')
BRIDGE = ('USOSKEY.COM', 'USOSKEY.DRV', 'VBMOUSE.EXE', 'VBMOUSE.DRV', 'VBADOS.TXT')
# Everything on the stick (the payload list and the release check use it).
STAGED = FILES + ('MSBATCH.INF', 'VMDISP9X.TGZ', 'XHCI98.SYS', 'XHCI98.INF', 'XHCI98.TXT')

NOTICE = """U9FIX.COM - USOS helper for Windows 95/98/Me
Copyright (C) 2026 Maksymilian and the USOS Authors.

C:\\AUTOEXEC.BAT runs it before every Windows start:

  C:\\USOS9X\\U9FIX.COM C:\\WINDOWS\\SYSTEM.INI

When a key is missing it adds

  [386Enh] MaxPhysPage=40000     (Windows uses at most 1 GiB of RAM)
  [vcache] MaxFileCache=262144   (disk cache at most 256 MiB)

Keys already present are kept with their value, so a changed value stays.
To stop it, delete the line from C:\\AUTOEXEC.BAT.

This program is free software: you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option)
any later version. It comes WITHOUT ANY WARRANTY. Source code:
src/platform/bios/win9x/u9fix.S in https://github.com/snakex21/universal-service-os
"""


def dos_text(text: str) -> bytes:
    return text.replace('\r\n', '\n').replace('\n', '\r\n').encode('ascii')


def build_u9fix(out: Path, work: Path) -> Path:
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(ROOT / 'tools/cache/zig-global'))
    zig = str(ROOT / 'tools/zig/zig.exe')
    obj, elf, com = work / 'u9fix.o', work / 'u9fix.elf', out / 'U9FIX.COM'
    subprocess.run([zig, 'cc', '-target', 'x86-freestanding-none', '-mcpu=i386', '-c',
                    str(SOURCE / 'u9fix.S'), '-o', str(obj)], env=env, check=True)
    subprocess.run([zig, 'ld.lld', '-m', 'elf_i386', '-T', str(ROOT / 'src/platform/bios/msdos/com.ld'),
                    str(obj), '-o', str(elf)], env=env, check=True)
    subprocess.run([zig, 'objcopy', '-O', 'binary', str(elf), str(com)], env=env, check=True)
    data = com.read_bytes()
    # The file buffer starts behind the code: 48 KiB input + growth must fit
    # below the COM stack at the top of the 64 KiB segment.
    if not 0 < len(data) <= 4096 or b'SYSTEM.U9$' not in data:
        raise ValueError('unexpected U9FIX.COM layout')
    return com


def build_diag(out: Path, work: Path) -> None:
    """USOSDIAG.COM and USOSHPET.COM from one source (-DUSOSHPET)."""
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(ROOT / 'tools/cache/zig-global'))
    zig = str(ROOT / 'tools/zig/zig.exe')
    for name, defines in (('USOSDIAG', []), ('USOSHPET', ['-DUSOSHPET'])):
        obj, elf, com = work / (name + '.o'), work / (name + '.elf'), out / (name + '.COM')
        subprocess.run([zig, 'cc', '-target', 'x86-freestanding-none', '-mcpu=i386', *defines, '-c',
                        str(SOURCE / 'usosdiag.S'), '-o', str(obj)], env=env, check=True)
        subprocess.run([zig, 'ld.lld', '-m', 'elf_i386', '-T', str(ROOT / 'src/platform/bios/msdos/com.ld'),
                        str(obj), '-o', str(elf)], env=env, check=True)
        subprocess.run([zig, 'objcopy', '-O', 'binary', str(elf), str(com)], env=env, check=True)
        data = com.read_bytes()
        # Scratch buffers start at 6F00h (E820/EDD) and 7000h (output).
        if not 0 < len(data) <= 0x6f00 - 0x100 or b'DIAG.LOG' not in data or name.encode() not in data:
            raise ValueError('unexpected %s.COM layout' % name)


def stage_vmdisp9x(out: Path) -> None:
    manifest = json.loads((VMDISP / 'manifest.json').read_text())
    for name, expected in manifest['files'].items():
        if hashlib.sha256((VMDISP / name).read_bytes()).hexdigest() != expected:
            raise ValueError('vmdisp9x checksum mismatch: ' + name)
    for name, staged in VMDISP_FILES.items():
        shutil.copyfile(VMDISP / name, out / staged)
    shutil.copyfile(VMDISP / 'vmdisp9x-1.2025.0.119.tar.gz', out / 'VMDISP9X.TGZ')
    notice = (VMDISP / 'SOURCES.txt').read_text(encoding='ascii') + '\n' + '-' * 72 + '\n\n' + \
        (VMDISP / 'license.txt').read_text(encoding='ascii')
    (out / 'VMDISP9X.TXT').write_bytes(dos_text(notice))
    inf = (SOURCE / 'usosvesa.inf').read_text(encoding='ascii')
    for name in VMDISP_FILES:
        if f'\n{name}=1' not in inf:
            raise ValueError('usosvesa.inf does not list ' + name)
    (out / 'USOSVESA.INF').write_bytes(dos_text(inf))


def stage_xhci98(out: Path) -> None:
    manifest = json.loads((XHCI98 / 'manifest.json').read_text())
    for name, expected in manifest['files'].items():
        if hashlib.sha256((XHCI98 / name).read_bytes()).hexdigest() != expected:
            raise ValueError('xhci98 checksum mismatch: ' + name)
    for name, staged in XHCI98_FILES.items():
        shutil.copyfile(XHCI98 / name, out / staged)
    notice = ('xhci98 %s for Windows 98 SE (MODIFIED by USOS, GPL-2.0-only), %s\n'
              'base: tag %s = commit %s (source tarball sha256 %s)\n'
              'plus %s, built with WDK 7.1.\n'
              'Corresponding source: the USOS sources zip (tools/vendor/xhci98/1.1.1.0-src\n'
              'and tools/vendor/xhci98/1.1.1.0-usos3-w9x).\n'
              'USOS copies XHCI98.SYS/.INF into the 98 SE Setup folder only together with\n'
              "STACK.CAB, the cabinet of the user's USB 2.0 stack installer (NUSB).\n\n" % (
                  manifest['version'], manifest['upstream'], manifest['tag'], manifest['commit'],
                  manifest['source_archive']['sha256'], ', '.join(sorted(manifest['patches']))))
    notice += (XHCI98 / 'MODIFIED.txt').read_text(encoding='ascii') + '\n' + '-' * 72 + '\n\n' + \
        (XHCI98 / 'LICENSE').read_text(encoding='ascii')
    (out / 'XHCI98.TXT').write_bytes(dos_text(notice))


def build(root: Path = ROOT, out: Path | None = None) -> None:
    out = out or root / 'zig-out/dos-native/win9x'
    out.mkdir(parents=True, exist_ok=True)
    work = root / 'zig-out/win9x-support'
    work.mkdir(parents=True, exist_ok=True)
    build_u9fix(out, work)
    build_diag(out, work)
    (out / 'U9FIX.TXT').write_bytes(dos_text(NOTICE))
    answer = (SOURCE / 'msbatch.inf').read_text(encoding='ascii')
    if 'ProductKey' in answer:
        raise ValueError('the default MSBATCH.INF must not carry a product key')
    (out / 'MSBATCH.INF').write_bytes(dos_text(answer))
    stage_vmdisp9x(out)
    stage_xhci98(out)
    msdos = root / 'zig-out/dos-native/msdos'
    for name in BRIDGE:
        if not (msdos / name).is_file():
            raise ValueError('build the MS-DOS support first (missing ' + name + ')')
        shutil.copyfile(msdos / name, out / name)
    missing = [name for name in STAGED if not (out / name).is_file()]
    if missing:
        raise ValueError('missing Windows 9x support files: ' + ', '.join(missing))
    print('[PASS] Windows 9x support: U9FIX.COM, default MSBATCH.INF, vmdisp9x 1.2025.0.119 VESA driver')


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--out', type=Path)
    build(ROOT, p.parse_args().out)
