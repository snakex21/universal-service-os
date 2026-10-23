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
  USOSKEY.COM, USOSKEY.DRV, USOSMOUS.DRV, VBMOUSE.EXE, VBMOUSE.DRV, VBADOS.TXT
                the USB keyboard and mouse bridge (USOS; USOSMOUS.DRV: 98 SE
                and 98 mouse.drv) and VBADOS 0.67 (GPL-2.0+) of
                the MS-DOS support, for installs under CSMWrap
  DOSMOUSE.BAT, INWIN.COM
                USB mouse for DOS programs in MS-DOS mode of 95/98/98 SE
                under CSMWrap (src/platform/bios/win9x/dosmouse.cmd, inwin.S;
                docs/dos-mouse-2026-10-18.md): VBMOUSE for one DOS session,
                unloaded before Windows starts; INWIN.COM refuses DOS boxes
  XHCI98.SYS, XHCI98.INF, XHCI98.TXT
                xhci98 1.1.1.0-usos3-w9x (GPL-2.0-only, MODIFIED: polling,
                Windows 98 SE build; tools/vendor/xhci98/1.1.1.0-usos3-w9x,
                checked against manifest.json): native USB keyboard and mouse
                in 98 SE under CSMWrap. INSTALL.BAT puts them into the Setup
                folder only next to STACK.CAB, the cabinet of the user's USB
                2.0 stack installer (DATA Drivers/Windows 98 SE/USB,
                tools/w9x_csmwrap_target.sh), and only with the opt-in flag
                EFI/USOS/win9x/xhci98.flag (default off: on the X470 xhci98
                takes the controller from the USOSKEY bridge, HID not working)

  CREGFIX.SYS, CREGFIX.TXT
                CREGFIX f0693437 (mintsuki, 0BSD, unmodified,
                tools/vendor/cregfix/f0693437, checked against manifest.json):
                the first CONFIG.SYS line under CSMWrap (boot floppy and C:),
                clears the control registers CSMWrap leaves set

  USOSNVME.MPD, USOSNVME.INF
                usosnvme 1.0 for Windows 9x (USOS, GPL-3.0-or-later): the NVMe
                SCSI miniport for SCSIPORT.PDR (tools/nt/usosnvme, committed
                build bin/W9X/usosnvme.mpd; usosnvme9x.inf). Only for an
                NVMe target with DATA's nvme-experimental.txt
                (tools/w9x_nvme.sh); otherwise removed from C:\\USOS9X
  USOSUSB.MPD, USOSUSB.INF, USOSUSB.REG
                USOSUSB for Windows 9x (USOS, GPL-3.0-or-later): the USB stick
                SCSI miniport on CSMWrap's SeaBIOS USB disk service
                (tools/nt/usosusb9x: bin/W9X/usosusb.mpd, usosusb.inf; usosusb.reg =
                REGEDIT4 fragment of its Root\\SCSIAdapter devnode with the
                class instance placeholder @CLASSIDX@). On by default (X470 Me
                PASS 2026-10-19), off with DATA's usb-storage-off.txt
                (tools/w9x_csmwrap_target.sh fills in the class instance;
                otherwise removed from C:\\USOS9X)

Hardware diagnostics, staged (the UEFI path copies them to C:\\USOS9X;
nothing runs them unless EFI/USOS/win9x/diag.flag exists):
  USOSDIAG.COM  timer tick / PIC / PIT, INT 15h memory, INT 13h, PCI, VBE, HPET report
  USOSDBG.EXE   Win16 program for the 9x desktop: USOSKEY bridge counters,
                V86-vs-physical page map, xHCI and bridge PCI state, live
                (src/platform/bios/win9x/usosdbg.c, OpenWatcom like USOSKEY.DRV)

Staged for the CSMWrap flow since 2026-10-19 (X470 Windows Me pass):
  USOSVMD.VXD   the USB mouse in MS-DOS boxes, a VMOUSE minidriver
                (src/platform/win9x/usosvmd.asm, built with the MS-DOS support
                by tools/build_win3_usb_keyboard.py); 95 / 98 / 98 SE / Me, on by
                default, DATA vmd-off.txt turns it off (tools/w9x_csmwrap_target.sh)
  USOSLOG.EXE   Win32, no window: silent logger, started from the machine Run
                key (USOS answer; DATA logging-off.txt turns it off); mouse (via
                USOSDBG.EXE /L), usosnet 0.4 statistics, DNS / TCP / HTTP tests,
                processes, startup entries, USB disk record into
                C:\\USOS9X\\LOGS\\USOSLOG.TXT (src/platform/bios/win9x/usoslog.c,
                OpenWatcom wcc386 / wlink, PE 4.00; tools/tests/test_usoslog.py).
                --usoslog builds only USOSDBG.EXE and USOSLOG.EXE (in-place kits).

Also built, not staged (copied by hand):
  USOSHPET.COM  clears HPET LegacyReplacement (src/platform/bios/win9x/usosdiag.S)
  USOSWHERE.COM TSR: interrupted CS:IP, ticks, PSP and last INT 13h/15h/21h/2Fh
                AX in the top right corner (src/platform/bios/win9x/usoswhere.S)
  USOSV10.COM   TSR: INT 10h on a private 2 KiB stack (src/platform/bios/win9x/usosv10.S)

USOS code is GPL-3.0-or-later; no Microsoft files.

  python tools/build_win9x_support.py [--out zig-out/dos-native/win9x]
"""
from pathlib import Path
import argparse, hashlib, json, os, shutil, subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src/platform/bios/win9x'
VMDISP = ROOT / 'tools/vendor/vmdisp9x/1.2025.0.119'
XHCI98 = ROOT / 'tools/vendor/xhci98/1.1.1.0-usos3-w9x'
CREGFIX = ROOT / 'tools/vendor/cregfix/f0693437'
XHCI98_FILES = {'release-x86/xhci98.sys': 'XHCI98.SYS', 'release-x86/xhci98.inf': 'XHCI98.INF'}
VMDISP_FILES = {'vesamini.drv': 'VESAMINI.DRV', 'vesamini.vxd': 'VESAMINI.VXD', 'vmhal9x.dll': 'VMHAL9X.DLL',
                'vmhal486.dll': 'VMHAL486.DLL', 'vmdisp9x.dll': 'VMDISP9X.DLL'}
# What the Legacy Core copies to the RAM disk (dos_native_iso.zig win9x_helpers).
FILES = ('U9FIX.COM', 'U9FIX.TXT', 'USOSVESA.INF', 'VESAMINI.DRV', 'VESAMINI.VXD', 'VMHAL9X.DLL',
         'VMHAL486.DLL', 'VMDISP9X.DLL', 'VMDISP9X.TXT') + (
    # Under CSMWrap: the Windows 3.x USB keyboard bridge and VBADOS work in
    # Windows 9x too (copied from the MS-DOS support, built before this).
    'USOSKEY.COM', 'USOSKEY.DRV', 'USOSMOUS.DRV', 'VBMOUSE.EXE', 'VBMOUSE.DRV', 'VBADOS.TXT') + (
    # Under CSMWrap: VBMOUSE in MS-DOS mode only (DOSSTART.BAT calls DOSMOUSE).
    'DOSMOUSE.BAT', 'INWIN.COM') + (
    # Under CSMWrap: CONFIG.SYS loads it first (dos_native_iso.zig, INSTALL.BAT).
    'CREGFIX.SYS', 'USOSLAN.EXE')
BRIDGE = ('USOSKEY.COM', 'USOSKEY.DRV', 'USOSMOUS.DRV', 'VBMOUSE.EXE', 'VBMOUSE.DRV', 'VBADOS.TXT',
          'USOSVMD.VXD')
# Everything on the stick (the payload list and the release check use it).
STAGED = FILES + ('MSBATCH.INF', 'VMDISP9X.TGZ', 'XHCI98.SYS', 'XHCI98.INF', 'XHCI98.TXT',
                   'CREGFIX.TXT') + (
    # Hardware diagnostics: on the stick, so the UEFI path's target writer
    # (tools/w9x_csmwrap_target.sh) puts them into C:\USOS9X; nothing runs
    # them unless EFI/USOS/win9x/diag.flag exists (USOSDIAG BOOT, INSTALL.BAT).
    'USOSDIAG.COM', 'USOSDBG.EXE') + (
    # NVMe targets with nvme-experimental.txt only (tools/w9x_nvme.sh).
    'USOSNVME.MPD', 'USOSNVME.INF') + (
    # USB sticks (default; DATA usb-storage-off.txt turns them off, tools/w9x_csmwrap_target.sh).
    'USOSUSB.MPD', 'USOSUSB.INF', 'USOSUSB.REG') + (
    # CSMWrap flow: mouse in MS-DOS boxes (98/98 SE/Me) and the silent logger.
    'USOSVMD.VXD', 'USOSLOG.EXE')
USOSNVME = ROOT / 'tools/nt/usosnvme'
USOSUSB = ROOT / 'tools/nt/usosusb9x'
USOSUSB_FILES = ('bin/W9X/usosusb.mpd', 'usosusb.inf', 'usosusb.reg')

NOTICE = """U9FIX.COM - USOS helper for Windows 95/98/Me
Copyright (C) 2026 Maksymilian and the USOS Authors.

C:\\AUTOEXEC.BAT runs it before every Windows start:

  C:\\USOS9X\\U9FIX.COM C:\\WINDOWS\\SYSTEM.INI

When a key is missing it adds

  [386Enh] MaxPhysPage=40000     (Windows uses at most 1 GiB of RAM)
  [vcache] MaxFileCache=262144   (disk cache at most 256 MiB)

Keys already present are kept with their value, so a changed value stays.
Windows 95 (U9FIX /95): MaxPhysPage=1E000 instead (at most 480 MiB; 95 is
unstable above about 480 MB), and USOS's own MaxPhysPage=40000 from Setup
is lowered to it; any other value stays.
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


def build_inwin(out: Path, work: Path) -> Path:
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(ROOT / 'tools/cache/zig-global'))
    zig = str(ROOT / 'tools/zig/zig.exe')
    obj, elf, com = work / 'inwin.o', work / 'inwin.elf', out / 'INWIN.COM'
    subprocess.run([zig, 'cc', '-target', 'x86-freestanding-none', '-mcpu=i386', '-c',
                    str(SOURCE / 'inwin.S'), '-o', str(obj)], env=env, check=True)
    subprocess.run([zig, 'ld.lld', '-m', 'elf_i386', '-T', str(ROOT / 'src/platform/bios/msdos/com.ld'),
                    str(obj), '-o', str(elf)], env=env, check=True)
    subprocess.run([zig, 'objcopy', '-O', 'binary', str(elf), str(com)], env=env, check=True)
    data = com.read_bytes()
    if not 0 < len(data) <= 64 or data[:3] != bytes((0xb8, 0x00, 0x16)):
        raise ValueError('unexpected INWIN.COM layout')
    return com


def dosmouse_bat(out: Path) -> None:
    text = (SOURCE / 'dosmouse.cmd').read_text(encoding='ascii')
    if any(len(line) > 127 for line in text.splitlines()):
        raise ValueError('dosmouse.cmd: batch line too long for COMMAND.COM')
    (out / 'DOSMOUSE.BAT').write_bytes(dos_text(text))


def build_diag(out: Path, work: Path) -> None:
    """USOSDIAG.COM and USOSHPET.COM from one source (-DUSOSHPET), USOSWHERE.COM."""
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
        # Scratch buffers start at 6A00h (VBE), 6F00h (E820/EDD) and 7000h (output).
        if not 0 < len(data) <= 0x6a00 - 0x100 or b'DIAG.LOG' not in data or name.encode() not in data:
            raise ValueError('unexpected %s.COM layout' % name)
    obj, elf, com = work / 'USOSWHERE.o', work / 'USOSWHERE.elf', out / 'USOSWHERE.COM'
    subprocess.run([zig, 'cc', '-target', 'x86-freestanding-none', '-mcpu=i386', '-c',
                    str(SOURCE / 'usoswhere.S'), '-o', str(obj)], env=env, check=True)
    subprocess.run([zig, 'ld.lld', '-m', 'elf_i386', '-T', str(ROOT / 'src/platform/bios/msdos/com.ld'),
                    str(obj), '-o', str(elf)], env=env, check=True)
    subprocess.run([zig, 'objcopy', '-O', 'binary', str(elf), str(com)], env=env, check=True)
    data = com.read_bytes()
    if not 0 < len(data) <= 4096 or data[0] != 0xE9 or b'USOSWHR1' not in data:
        raise ValueError('unexpected USOSWHERE.COM layout')
    build_usosv10(out, work)
    build_usosvgar(out, work)


def build_usosvgar(out: Path, work: Path) -> Path:
    """USOSVGAR.COM: VGA register readback / latch probe (Windows 3.x redraw)."""
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(ROOT / 'tools/cache/zig-global'))
    zig = str(ROOT / 'tools/zig/zig.exe')
    obj, elf, com = work / 'USOSVGAR.o', work / 'USOSVGAR.elf', out / 'USOSVGAR.COM'
    subprocess.run([zig, 'cc', '-target', 'x86-freestanding-none', '-mcpu=i386', '-c',
                    str(SOURCE / 'usosvgar.S'), '-o', str(obj)], env=env, check=True)
    subprocess.run([zig, 'ld.lld', '-m', 'elf_i386', '-T', str(SOURCE.parent / 'msdos/com.ld'),
                    str(obj), '-o', str(elf)], env=env, check=True)
    subprocess.run([zig, 'objcopy', '-O', 'binary', str(elf), str(com)], env=env, check=True)
    data = com.read_bytes()
    # Output buffer at 8000h: the image must end below it.
    if not 0 < len(data) <= 0x8000 - 0x100 or data[0] != 0xE9 or b'USOSVGR3' not in data:
        raise ValueError('unexpected USOSVGAR.COM layout')
    return com


def build_usosv10(out: Path, work: Path) -> Path:
    """USOSV10.COM: INT 10h on a private stack (Windows 1.x/2.x WIN.COM logo)."""
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(ROOT / 'tools/cache/zig-global'))
    zig = str(ROOT / 'tools/zig/zig.exe')
    obj, elf, com = work / 'USOSV10.o', work / 'USOSV10.elf', out / 'USOSV10.COM'
    subprocess.run([zig, 'cc', '-target', 'x86-freestanding-none', '-mcpu=i386', '-c',
                    str(SOURCE / 'usosv10.S'), '-o', str(obj)], env=env, check=True)
    subprocess.run([zig, 'ld.lld', '-m', 'elf_i386', '-T', str(ROOT / 'src/platform/bios/msdos/com.ld'),
                    str(obj), '-o', str(elf)], env=env, check=True)
    subprocess.run([zig, 'objcopy', '-O', 'binary', str(elf), str(com)], env=env, check=True)
    data = com.read_bytes()
    if not 2048 < len(data) <= 4096 or data[0] != 0xE9 or b'USOSV10A' not in data:
        raise ValueError('unexpected USOSV10.COM layout')
    return com


def build_usosdbg(out: Path, work: Path) -> Path:
    """USOSDBG.EXE: Win16 (OpenWatcom wcc/wlink as USOSKEY.DRV, no runtime)."""
    import sys
    sys.path.insert(0, str(ROOT / 'tools'))
    from build_win3_usb_keyboard import openwatcom
    ow = openwatcom()
    env = dict(os.environ, WATCOM=str(ow), INCLUDE=f'{ow / "h"};{ow / "h/win"}',
               PATH=str(ow / 'binnt64') + os.pathsep + os.environ.get('PATH', ''))
    obj = work / 'usosdbg.obj'
    subprocess.run([str(ow / 'binnt64/wcc.exe'), '-q', '-bt=windows', '-ms', '-zl', '-s', '-3', '-osi',
                    '-w3', '-we', '-fo=' + str(obj), str(SOURCE / 'usosdbg.c')], env=env, check=True, cwd=work)
    exe = out / 'USOSDBG.EXE'
    subprocess.run([str(ow / 'binnt64/wlink.exe'), '@' + str(SOURCE / 'usosdbg.lnk'), 'file', str(obj),
                    'name', str(exe), 'option', 'map=' + str(work / 'usosdbg.map')], env=env, check=True, cwd=work)
    data = exe.read_bytes()
    ne = int.from_bytes(data[0x3c:0x3e], 'little')
    if data[ne:ne + 2] != b'NE' or b'USOSDBG.LOG' not in data:
        raise ValueError('USOSDBG.EXE is not the expected NE program')
    if 'clib' in (work / 'usosdbg.map').read_text(errors='replace').lower():
        raise ValueError('USOSDBG.EXE must not link the OpenWatcom C library')
    return exe


OW_LIB386_NT = ('kernel32.lib', 'user32.lib', 'advapi32.lib')
# What USOSLOG.EXE may import statically: the Windows 95 (4.00.950) subset,
# also in 98 / Me / NT 4.0 and later. WSOCK32, IPHLPAPI and Toolhelp32 are
# looked up at run time (missing on some installs / systems).
USOSLOG_IMPORTS = {
    'kernel32.dll': {
        'CloseHandle', 'CreateDirectoryA', 'CreateFileA', 'CreateMutexA', 'CreateProcessA', 'CreateThread',
        'DeleteFileA', 'EnterCriticalSection', 'ExitProcess', 'FindClose', 'FindFirstFileA', 'FindNextFileA',
        'FlushFileBuffers', 'GetCommandLineA', 'GetComputerNameA', 'GetCurrentThreadId', 'GetFileSize',
        'GetLastError', 'GetLocalTime', 'GetModuleFileNameA', 'GetModuleHandleA', 'GetPrivateProfileStringA', 'GetProcAddress',
        'GetProfileStringA', 'GetTickCount', 'GetVersion', 'GetVersionExA', 'GlobalMemoryStatus', 'InitializeCriticalSection',
        'IsBadReadPtr', 'LeaveCriticalSection', 'LoadLibraryA', 'MoveFileA', 'ReadFile', 'SetFilePointer', 'Sleep',
        'WaitForSingleObject', 'WriteFile', 'lstrcatA', 'lstrcmpiA', 'lstrcpyA', 'lstrcpynA', 'lstrlenA'},
    'user32.dll': {
        'CallNextHookEx', 'CreateWindowExA', 'DefWindowProcA', 'DispatchMessageA', 'EnumWindows', 'GetClassNameA',
        'GetCursorPos', 'GetForegroundWindow', 'GetMessageA', 'GetSystemMetrics', 'GetWindowLongA', 'GetWindowTextA',
        'GetWindowThreadProcessId', 'IsWindowVisible', 'KillTimer', 'PeekMessageA', 'PostThreadMessageA',
        'RegisterClassA', 'SetTimer', 'SetWindowsHookExA', 'SystemParametersInfoA', 'UnhookWindowsHookEx', 'WindowFromPoint', 'wsprintfA', 'wvsprintfA'},
    'advapi32.dll': {'RegCloseKey', 'RegEnumKeyExA', 'RegEnumValueA', 'RegOpenKeyExA', 'RegQueryValueExA'},
}


def openwatcom_nt(ow: Path) -> None:
    """The Win32 import libraries (lib386/nt) from the pinned OpenWatcom
    snapshot; build_win3_usb_keyboard.openwatcom() unpacks only the 16-bit
    parts."""
    import sys
    import tarfile
    sys.path.insert(0, str(ROOT / 'tools'))
    from build_win3_usb_keyboard import OW_CACHE, OW_SNAPSHOT
    lib = ow / 'lib386/nt'
    if all((lib / n).is_file() for n in OW_LIB386_NT):
        return
    archive = OW_CACHE / OW_SNAPSHOT['file']
    if not archive.is_file():
        archive = ROOT / 'tools/cache/buildkit-downloads' / OW_SNAPSHOT['file']
    with tarfile.open(archive) as t:
        members = [m for m in t.getmembers() if m.name in {'./lib386/nt/' + n for n in OW_LIB386_NT}]
        t.extractall(ow, members=members, filter='data')


def pe_imports(data: bytes) -> dict:
    """{dll (lower case): {names}} of a PE32 image (no ordinal imports expected)."""
    pe = int.from_bytes(data[0x3C:0x40], 'little')
    nsec = int.from_bytes(data[pe + 6:pe + 8], 'little')
    opt = pe + 24
    secs = [(int.from_bytes(data[s + 12:s + 16], 'little'), int.from_bytes(data[s + 8:s + 12], 'little'),
             int.from_bytes(data[s + 20:s + 24], 'little'))
            for s in (opt + int.from_bytes(data[pe + 20:pe + 22], 'little') + 40 * i for i in range(nsec))]

    def off(rva):
        for va, vs, raw in secs:
            if va <= rva < va + max(vs, 1):
                return raw + rva - va
        raise ValueError(f'rva {rva:#x} outside the sections')

    def cstr(o):
        return data[o:data.index(b'\0', o)].decode('ascii')
    imp = int.from_bytes(data[opt + 104:opt + 108], 'little')
    out = {}
    d = off(imp)
    while int.from_bytes(data[d + 12:d + 16], 'little'):
        dll = cstr(off(int.from_bytes(data[d + 12:d + 16], 'little'))).lower()
        thunk = int.from_bytes(data[d:d + 4], 'little') or int.from_bytes(data[d + 16:d + 20], 'little')
        t = off(thunk)
        names = out.setdefault(dll, set())
        while True:
            v = int.from_bytes(data[t:t + 4], 'little')
            if not v:
                break
            if v & 0x80000000:
                names.add(f'#{v & 0xFFFF}')
            else:
                names.add(cstr(off(v) + 2))
            t += 4
        d += 20
    return out


def build_usoslog(out: Path, work: Path, *, nt3: bool = False) -> Path:
    """USOSLOG.EXE: Win32 GUI program (OpenWatcom wcc386 / wlink, no runtime),
    PE subsystem and OS version 4.00 so Windows 95 / 98 / Me load it."""
    import sys
    sys.path.insert(0, str(ROOT / 'tools'))
    from build_win3_usb_keyboard import openwatcom
    ow = openwatcom()
    openwatcom_nt(ow)
    env = dict(os.environ, WATCOM=str(ow), INCLUDE=f'{ow / "h/nt"};{ow / "h"}',
               PATH=str(ow / 'binnt64') + os.pathsep + os.environ.get('PATH', ''))
    obj = work / 'usoslog.obj'
    subprocess.run([str(ow / 'binnt64/wcc386.exe'), '-q', '-bt=nt', '-zl', '-s', '-5r', '-os', '-zp4',
                    '-w3', '-we', *(['-dUSOS_NT3_RAW_ICMP=1'] if nt3 else []),
                    '-fo=' + str(obj), str(SOURCE / 'usoslog.c')], env=env, check=True, cwd=work)
    exe = out / 'USOSLOG.EXE'
    subprocess.run([str(ow / 'binnt64/wlink.exe'), '@' + str(SOURCE / 'usoslog.lnk'), 'file', str(obj),
                    'name', str(exe), 'option', 'map=' + str(work / 'usoslog.map')], env=env, check=True, cwd=work)
    spec = importlib_util_spec('pe_nt4_version', ROOT / 'tools/nt4/pe_nt4_version.py')
    # wlink stamps the link time into the COFF header: a fixed TimeDateStamp
    # keeps the staged payload reproducible (set_nt4 recomputes the checksum).
    raw = bytearray(exe.read_bytes())
    pe = int.from_bytes(raw[0x3C:0x40], 'little')
    if raw[pe:pe + 4] != b'PE\0\0':
        raise ValueError('USOSLOG.EXE has no PE header')
    raw[pe + 8:pe + 12] = (0).to_bytes(4, 'little')
    data = spec.set_nt4(bytes(raw), 3, 10) if nt3 else spec.set_nt4(bytes(raw), 4, 0)
    exe.write_bytes(data)
    if data[:2] != b'MZ' or b'USOSLOG' not in data:
        raise ValueError('USOSLOG.EXE is not the expected PE program')
    for dll, names in pe_imports(data).items():
        extra = names - USOSLOG_IMPORTS.get(dll, set())
        if extra:
            raise ValueError(f'USOSLOG.EXE imports outside the 9x list: {dll} {sorted(extra)}')
    if 'clib' in (work / 'usoslog.map').read_text(errors='replace').lower():
        raise ValueError('USOSLOG.EXE must not link the OpenWatcom C library')
    return exe


def importlib_util_spec(name: str, path: Path):
    import importlib.util
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


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
    if '\nHKLM,Software\\vmdisp9x\\vesa,NoMemTest,,"1"' not in inf:
        raise ValueError('usosvesa.inf must set NoMemTest="1" (real-hardware VRAM sizing)')
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
              "STACK.CAB, the cabinet of the user's USB 2.0 stack installer (NUSB), and only\n"
              'with the opt-in flag file EFI/USOS/win9x/xhci98.flag (default off).\n\n' % (
                  manifest['version'], manifest['upstream'], manifest['tag'], manifest['commit'],
                  manifest['source_archive']['sha256'], ', '.join(sorted(manifest['patches']))))
    notice += (XHCI98 / 'MODIFIED.txt').read_text(encoding='ascii') + '\n' + '-' * 72 + '\n\n' + \
        (XHCI98 / 'LICENSE').read_text(encoding='ascii')
    (out / 'XHCI98.TXT').write_bytes(dos_text(notice))


def stage_cregfix(out: Path) -> None:
    manifest = json.loads((CREGFIX / 'manifest.json').read_text())
    for name, expected in manifest['files'].items():
        if hashlib.sha256((CREGFIX / name).read_bytes()).hexdigest() != expected:
            raise ValueError('CREGFIX checksum mismatch: ' + name)
    shutil.copyfile(CREGFIX / 'cregfix.sys', out / 'CREGFIX.SYS')
    notice = ('CREGFIX %s (%s), unmodified, %s.\n'
              'Source: cregfix.asm in the USOS sources (tools/vendor/cregfix/f0693437).\n'
              'USOS loads it as the first CONFIG.SYS line of Windows 95/98/Me under\n'
              'CSMWrap (the Setup boot floppy and C:\\CONFIG.SYS).\n\n' % (
                  manifest['commit'][:8], manifest['upstream'], manifest['license']))
    notice += (CREGFIX / 'README').read_text(encoding='ascii') + '\n' + '-' * 72 + '\n\n' + \
        (CREGFIX / 'LICENSE').read_text(encoding='ascii')
    (out / 'CREGFIX.TXT').write_bytes(dos_text(notice))


def stage_usosnvme(out: Path) -> None:
    """usosnvme.mpd (USOSNVME_W9X build, committed) + its 9x INF."""
    mpd = (USOSNVME / 'bin/W9X/usosnvme.mpd').read_bytes()
    if mpd[:2] != b'MZ' or b'SCSIPORT.SYS' not in mpd or b'ntoskrnl' in mpd.lower():
        raise ValueError('unexpected usosnvme.mpd (build: tools/nt/usosnvme/build.cmd w9x)')
    (out / 'USOSNVME.MPD').write_bytes(mpd)
    inf = (USOSNVME / 'usosnvme9x.inf').read_text(encoding='ascii')
    (out / 'USOSNVME.INF').write_bytes(dos_text(inf))


def stage_usosusb(out: Path, source: Path = USOSUSB) -> None:
    """usosusb.mpd (the 9x SCSIPORT.PDR build) + its INF + its REGEDIT4 devnode fragment."""
    missing = [name for name in USOSUSB_FILES if not (source / name).is_file()]
    if missing:
        raise ValueError('USOSUSB miniport not built yet: missing %s in %s' % (', '.join(missing), source))
    mpd = (source / USOSUSB_FILES[0]).read_bytes()
    pe = int.from_bytes(mpd[0x3c:0x40], 'little') if len(mpd) >= 0x40 else 0
    if mpd[:2] != b'MZ' or mpd[pe:pe + 4] != b'PE\0\0' or b'SCSIPORT.SYS' not in mpd.upper() or \
            b'ntoskrnl' in mpd.lower():
        raise ValueError('unexpected usosusb.mpd (not a PE miniport importing SCSIPORT.SYS)')
    reg = (source / USOSUSB_FILES[2]).read_text(encoding='ascii')
    if not reg.startswith('REGEDIT4') or '@CLASSIDX@' not in reg:
        raise ValueError('usosusb.reg must be a REGEDIT4 fragment with the @CLASSIDX@ class instance placeholder')
    (out / 'USOSUSB.MPD').write_bytes(mpd)
    (out / 'USOSUSB.INF').write_bytes(dos_text((source / USOSUSB_FILES[1]).read_text(encoding='ascii')))
    (out / 'USOSUSB.REG').write_bytes(dos_text(reg))


def build(root: Path = ROOT, out: Path | None = None) -> None:
    out = out or root / 'zig-out/dos-native/win9x'
    out.mkdir(parents=True, exist_ok=True)
    work = root / 'zig-out/win9x-support'
    work.mkdir(parents=True, exist_ok=True)
    build_u9fix(out, work)
    build_inwin(out, work)
    dosmouse_bat(out)
    build_diag(out, work)
    build_usosdbg(out, work)
    build_usoslog(out, work)
    (out / 'U9FIX.TXT').write_bytes(dos_text(NOTICE))
    answer = (SOURCE / 'msbatch.inf').read_text(encoding='ascii')
    if 'ProductKey' in answer:
        raise ValueError('the default MSBATCH.INF must not carry a product key')
    (out / 'MSBATCH.INF').write_bytes(dos_text(answer))
    stage_vmdisp9x(out)
    stage_xhci98(out)
    stage_cregfix(out)
    stage_usosnvme(out)
    stage_usosusb(out)
    from build_windows_usos_lan import build as build_lan
    shutil.copyfile(build_lan(root, work / 'network')['USOSLAN9X.EXE'], out / 'USOSLAN.EXE')
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
    p.add_argument('--usoslog', action='store_true',
                   help='only USOSDBG.EXE and USOSLOG.EXE (for in-place kits)')
    a = p.parse_args()
    if a.usoslog:
        o = a.out or ROOT / 'zig-out/win9x-usoslog'
        w = ROOT / 'zig-out/win9x-support'
        o.mkdir(parents=True, exist_ok=True)
        w.mkdir(parents=True, exist_ok=True)
        print(build_usosdbg(o, w))
        print(build_usoslog(o, w))
    else:
        build(ROOT, a.out)
