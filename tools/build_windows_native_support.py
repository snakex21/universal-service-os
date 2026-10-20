"""Pack release-owned WinPE helpers; Windows boot files come from the selected ISO."""
from pathlib import Path
import hashlib
import json
import shutil
import os
import subprocess
from build_windows_native_cache import NewcWriter
from build_windows_source_mount import build as build_helpers
from build_windows7_uefi import build as build_win7_helpers
from build_windows7_nvme import read_assets, build_helpers as build_nvme_helpers
from build_windows7_sha2 import read_cab as read_sha2_cab, CAB_NAME as SHA2_CAB_NAME
from build_windows7_kmdf import read_cab as read_kmdf_cab, CAB_NAME as KMDF_CAB_NAME
from build_windows_vista_support import build as build_vista_support
from build_usosnvme_nt6_signed import build as build_usosnvme_nt6_signed


def build(root: Path):
    helpers = root / 'zig-out/windows-source-mount'
    build_helpers(root, helpers)
    out = root / 'zig-out/windows-native'
    out.mkdir(parents=True, exist_ok=True)
    vendor = root / 'tools/vendor/imdisk/2.1.2'
    manifest = json.loads((vendor / 'manifest.json').read_text())
    for name, expected in manifest['files'].items():
        if hashlib.sha256((vendor / name).read_bytes()).hexdigest() != expected:
            raise ValueError('ImDisk checksum mismatch: ' + name)
    wimboot = root / 'tools/vendor/wimboot/2.9.0/wimboot'
    if hashlib.sha256(wimboot.read_bytes()).hexdigest() != '5f067ccdc4d084d5bf77b6c853bd0f8402dfc2b4cd1b103d358993ae97fae8e3':
        raise ValueError('wimboot checksum mismatch')
    writer = NewcWriter(out / 'support.cpio.tmp')
    try:
        writer.add_bytes('usos-start.cmd', (root / 'tools/windows_iso_startup.cmd').read_bytes().replace(b'\r\n', b'\n').replace(b'\n', b'\r\n'))
        writer.add_bytes('winpeshl.ini', b'[LaunchApp]\r\nAppPath=%SYSTEMROOT%\\System32\\usos-launch-%PROCESSOR_ARCHITECTURE%.exe\r\n')
        writer.add_bytes('usos-build.txt', (os.environ.get('USOS_BUILD_ID', 'DEV')+'\r\n').encode('ascii'))
        for arch in ('x86', 'x86_64'):
            writer.add_file('usos-log-' + arch + '.exe', helpers / ('usos-log-' + arch + '.exe'))
            writer.add_file('usos-usb-report-' + arch + '.exe', helpers / ('usos-usb-report-' + arch + '.exe'))
            writer.add_file('usos-source-' + arch + '.exe', helpers / ('usos-source-' + arch + '.exe'))
            launcher_arch = 'AMD64' if arch == 'x86_64' else 'x86'
            writer.add_file('usos-launch-' + launcher_arch + '.exe', helpers / ('usos-launch-' + arch + '.exe'))
            for ext in ('exe', 'cpl', 'sys'):
                name = 'imdisk-' + arch + '.' + ext
                writer.add_file(name, vendor / name)
        # tools/windows_hidden_commands.h: profile answer commands without consoles.
        writer.add_file('usos-run-hidden.exe', helpers / 'usos-run-hidden.exe')
        for src, dst in [('README.md', 'usos-imdisk-README.txt'), ('LICENSE.md', 'usos-imdisk-LICENSE.txt'), ('source.zip', 'usos-imdisk-source.zip')]:
            writer.add_file(dst, vendor / src)
        # Core appends the chosen ISO's files/configuration and one trailer.
    finally:
        writer.close()
    (out / 'support.cpio.tmp').replace(out / 'support.cpio')
    shutil.copyfile(wimboot, out / 'wimboot')
    build_stock_support(root, out)
    build_modern_support(root, out)
    build_vista_support(root)
    print('[PASS] Native Windows support:', (out / 'support.cpio').stat().st_size, 'bytes')


def build_stock_support(root: Path, out: Path):
    helpers = root / 'zig-out/windows7-uefi'
    build_win7_helpers(root, helpers)
    nvme_helpers = root / 'zig-out/windows7-nvme'
    build_nvme_helpers(root, nvme_helpers)
    nvme_assets = read_assets(root)
    vendor = root / 'tools/vendor/uefiseven/1.30'
    manifest = json.loads((vendor / 'manifest.json').read_text())
    for name, expected in manifest['files'].items():
        if hashlib.sha256((vendor / name).read_bytes()).hexdigest() != expected:
            raise ValueError('UefiSeven checksum mismatch: ' + name)
    writer = NewcWriter(out / 'win7-support.cpio.tmp')
    try:
        writer.add_file('usos-win7-unattend.exe', nvme_helpers / 'usos-win7-unattend.exe')
        writer.add_file('usos-win7-kmdf-repair.exe', nvme_helpers / 'usos-win7-kmdf-repair.exe')
        writer.add_bytes(SHA2_CAB_NAME, read_sha2_cab(root))
        writer.add_bytes('usos-sha2-required.flag', b'1\r\n')
        writer.add_bytes(KMDF_CAB_NAME, read_kmdf_cab(root))
        writer.add_bytes('usos-kmdf-required.flag', b'1\r\n')
        for name, content in nvme_assets.items():
            if name.startswith('updates/'):
                writer.add_bytes(name.split('/')[-1], content)
        writer.add_bytes('usos-win7-start.cmd', (root / 'tools/windows7_native_startup.cmd').read_bytes().replace(b'\r\n', b'\n').replace(b'\n', b'\r\n'))
        writer.add_bytes('usos-modern-win7.cmd', (root / 'tools/windows7_modern_startup.cmd').read_bytes().replace(b'\r\n', b'\n').replace(b'\n', b'\r\n'))
        # Copied to <target>\Windows\Setup\Scripts\SetupComplete.cmd by the stock
        # PE7 path when Setup ran without an answer file (user drivers).
        writer.add_bytes('usos-win7-setupcomplete.cmd', (root / 'tools/windows7_setupcomplete.cmd').read_bytes().replace(b'\r\n', b'\n').replace(b'\n', b'\r\n'))
        for name in ('usos-win7-finalize.exe', 'usos-drivers.exe', 'usos-unattend-drivers.exe'):
            writer.add_file(name, helpers / name)
        # WIMBoot treats .efi files as boot applications rather than injected
        # WinPE files. Transport target-only EFI assets under neutral names.
        writer.add_file('usos-win7-wrapper.bin', helpers / 'win7-wrapper.efi')
        writer.add_file('usos-win7-video.bin', vendor / 'UefiSeven.efi')
        writer.add_file('uefiseven-LICENSE.txt', vendor / 'LICENSE.txt')
        writer.add_bytes('UefiSeven.ini', b'[config]\r\nverbose=0\r\nlogfile=1\r\nskiperrors=0\r\nforce_fakevesa=0\r\n')
    finally:
        writer.close()
    (out / 'win7-support.cpio.tmp').replace(out / 'win7-support.cpio')
    if (out / 'win7-support.cpio').stat().st_size >= 64 * 1024 * 1024:
        raise ValueError('Win7 support archive exceeds the Core transport limit')
    shutil.copyfile(vendor / 'UefiSeven.efi', out / 'int10.efi')
    shutil.copyfile(helpers / 'int10.original.efi', out / 'int10.original.efi')
    (out / 'UefiSeven.ini').write_bytes(b'[config]\r\nverbose=0\r\nlogfile=1\r\nskiperrors=0\r\n')
    shutil.copyfile(vendor / 'LICENSE.txt', out / 'uefiseven-LICENSE.txt')


def build_modern_support(root: Path, out: Path):
    """Windows 10/11 native UEFI start: startup script, ESP guard/finalizer and
    the user-driver helpers shared with the Win7 path (built by build_stock_support)."""
    helpers = root / 'zig-out/windows-modern'
    helpers.mkdir(parents=True, exist_ok=True)
    temp = helpers / 'tmp'
    temp.mkdir(exist_ok=True)
    env = dict(os.environ, TEMP=str(temp), TMP=str(temp), ZIG_GLOBAL_CACHE_DIR=str(root / 'tools/cache/zig-global'), ZIG_LOCAL_CACHE_DIR=str(helpers / 'zig-cache'))
    subprocess.run([str(root / 'tools/zig/zig.exe'), 'cc', '-target', 'x86_64-windows.win10-gnu', '-Os', '-nostdlib', '-fno-stack-protector', '-fno-builtin',
                    '-I' + str(root / 'tools/zig/lib/libc/include/any-windows-any'), str(root / 'tools/windows_modern_uefi_finalize.c'),
                    '-Wl,--entry,entry', '-lkernel32', '-ladvapi32', '-o', str(helpers / 'usos-modern-finalize.exe')], env=env, check=True)
    # 32-bit Windows 8.1 / 10 without CSM (win-x86-uefi-csmwrap): the ISO's own
    # x86 WinPE in BIOS mode; micro-Linux step 610 injects this archive too.
    subprocess.run([str(root / 'tools/zig/zig.exe'), 'cc', '-target', 'x86-windows.win10-gnu', '-Os', '-nostdlib', '-fno-stack-protector', '-fno-builtin',
                    '-I' + str(root / 'tools/zig/lib/libc/include/any-windows-any'), str(root / 'tools/windows_x86_csmwrap.c'),
                    '-Wl,--entry,entry', '-lkernel32', '-luser32', '-lshell32', '-lversion', '-ladvapi32', '-o', str(helpers / 'usos-x86-csmwrap.exe')], env=env, check=True)
    # 32-bit Vista / Server 2008 SP2 on that path: the Vista OOBE gate (WinSAT
    # guard, interrupted-OOBE recovery, autochk limit) as an x86 build that
    # hands over to native windeploy (no USB payload); usos-x86-csmwrap.cmd
    # installs it as C:/USOS/oobe.exe (csmwrap-integration 12.5).
    subprocess.run([str(root / 'tools/zig/zig.exe'), 'cc', '-target', 'x86-windows.vista-gnu', '-Os', '-nostdlib', '-fno-stack-protector', '-fno-builtin',
                    '-DUSOS_GATE_NATIVE_DEPLOY', '-I' + str(root / 'tools/zig/lib/libc/include/any-windows-any'), str(root / 'tools/windows_vista_oobe_gate.c'),
                    '-Wl,--entry,entry', '-Wl,--subsystem,windows', '-lkernel32', '-ladvapi32', '-lnetapi32', '-luser32', '-lcrypt32', '-o', str(helpers / 'usos-vista-oobe-x86.exe')], env=env, check=True)
    # 32-bit 7 / 8.x / 10 before 1703 on that path: usos-usbreenum (USB
    # mass-storage device nodes after Setup, run once from SetupComplete.cmd;
    # usos-x86-csmwrap.cmd :usbfix). Runs in the installed Windows, so the
    # Windows 7 / Vista subsystem version.
    subprocess.run([str(root / 'tools/zig/zig.exe'), 'cc', '-target', 'x86-windows.vista-gnu', '-Os', '-nostdlib', '-fno-stack-protector', '-fno-builtin',
                    '-I' + str(root / 'tools/zig/lib/libc/include/any-windows-any'), str(root / 'tools/windows_usb_reenum.c'),
                    '-Wl,--entry,entry', '-lkernel32', '-ladvapi32', '-lsetupapi', '-lcfgmgr32', '-o', str(helpers / 'usos-usbreenum.exe')], env=env, check=True)
    # Vista / 7 x86 with the bundled usosusb: tells Explorer about the
    # stick letters usosusb's legacy volumes get (no PnP broadcast) and logs
    # them; installed by the usosusb step (:usb_drive_notify, HKLM Run).
    subprocess.run([str(root / 'tools/zig/zig.exe'), 'cc', '-target', 'x86-windows.vista-gnu', '-Os', '-nostdlib', '-fno-stack-protector', '-fno-builtin',
                    '-Wno-missing-declarations', '-I' + str(root / 'tools/zig/lib/libc/include/any-windows-any'), str(root / 'tools/windows_drive_notify.c'),
                    '-Wl,--entry,entry', '-Wl,--subsystem,windows', '-lkernel32', '-luser32', '-lshell32', '-ladvapi32',
                    '-o', str(helpers / 'usos-drivenotify.exe')], env=env, check=True)
    win7 = root / 'zig-out/windows7-uefi'
    subprocess.run([str(root / 'tools/zig/zig.exe'), 'cc', '-target', 'x86-windows.vista-gnu', '-Os', '-nostdlib', '-fno-stack-protector', '-fno-builtin',
                    '-I' + str(root / 'tools/zig/lib/libc/include/any-windows-any'), str(root / 'tools/windows_nvme_modern.c'), '-Wl,--entry,entry', '-lkernel32', '-ladvapi32', '-lcrypt32', '-lshell32',
                    '-o', str(helpers / 'usos-nvme-modern.exe')], env=env, check=True)
    writer = NewcWriter(out / 'modern-support.cpio.tmp')
    try:
        writer.add_bytes('usos-modern-uefi.cmd', (root / 'tools/windows_modern_uefi_startup.cmd').read_bytes().replace(b'\r\n', b'\n').replace(b'\n', b'\r\n'))
        writer.add_file('usos-modern-finalize.exe', helpers / 'usos-modern-finalize.exe')
        writer.add_bytes('usos-x86-csmwrap.cmd', (root / 'tools/windows_x86_csmwrap.cmd').read_bytes().replace(b'\r\n', b'\n').replace(b'\n', b'\r\n'))
        writer.add_file('usos-x86-csmwrap.exe', helpers / 'usos-x86-csmwrap.exe')
        writer.add_file('usos-vista-oobe-x86.exe', helpers / 'usos-vista-oobe-x86.exe')
        # Vista / Server 2008 SP2 and Windows 7 SP1 x86: own xHCI driver
        # (committed build of tools/nt4/usosusb/build-nt6.cmd), registered
        # offline by the nt60_usb step (Win7: only without another xHCI
        # driver). HID and bulk-only disks need no external DATA package.
        writer.add_file('usosusb-nt6.sys', root / 'tools/nt4/usosusb/bin/nt6/i386/usosusb.sys')
        writer.add_file('usos-drivenotify.exe', helpers / 'usos-drivenotify.exe')
        # Windows 7 / 8.x / 10 before 1703 x86: own USB multi-partition disk
        # filter (committed x86 build of tools/nt/usosmpart), registered
        # offline by the mpart step of usos-x86-csmwrap.cmd.
        writer.add_file('usosmpart-x86.sys', root / 'tools/nt/usosmpart/bin/i386/usosmpart.sys')
        writer.add_file('usos-usbreenum.exe', helpers / 'usos-usbreenum.exe')
        # NVMe target, Windows 7 / Vista / Server 2008 x86: own SCSIPORT
        # miniport (2KXP build of tools/nt/usosnvme; imports checked against
        # NT 6.0 SP2 in tools/tests/test_usosnvme.py), registered offline by
        # the nvme step of usos-x86-csmwrap.cmd (docs/nvme-nt6-2026-10-12.md).
        # Signed per build (sys + catalog) with a certificate whose private
        # key is deleted right after signing; the installed system trusts
        # only that certificate, so specialize stages / installs the package
        # silently instead of the NULL driver (section 9).
        signed = helpers / 'usosnvme-nt6'
        build_usosnvme_nt6_signed(root, signed)
        writer.add_file('usosnvme-nt6.sys', signed / 'usosnvme.sys')
        for name in ('usosnvme.inf', 'usosnvme.cat', 'usosnvme.cer'):
            writer.add_file(name, signed / name)
        modern_signed = helpers / 'usosnvme-modern'
        build_usosnvme_nt6_signed(root, modern_signed, modern=True)
        for name in ('usosnvme.inf', 'usosnvme.sys', 'usosnvme.cat', 'usosnvme.cer'):
            writer.add_file('modern-' + name, modern_signed / name)
        writer.add_file('usos-nvme-modern.exe', helpers / 'usos-nvme-modern.exe')
        writer.add_bytes('usos-nvme-modern.cmd', (root / 'tools/windows_nvme_modern.cmd').read_bytes().replace(b'\r\n', b'\n').replace(b'\n', b'\r\n'))
        for name in ('usos-drivers.exe', 'usos-unattend-drivers.exe'):
            writer.add_file(name, win7 / name)
    finally:
        writer.close()
    (out / 'modern-support.cpio.tmp').replace(out / 'modern-support.cpio')
    if (out / 'modern-support.cpio').stat().st_size >= 8 * 1024 * 1024:
        raise ValueError('modern support archive exceeds the Core transport limit')


if __name__ == '__main__':
    build(Path(__file__).resolve().parents[1])
