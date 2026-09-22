"""Pack release-owned WinPE helpers; Windows boot files come from the selected ISO."""
from pathlib import Path
import hashlib
import json
import shutil
import os
from build_windows_native_cache import NewcWriter
from build_windows_source_mount import build as build_helpers
from build_windows7_uefi import build as build_win7_helpers
from build_windows7_nvme import read_assets, build_helpers as build_nvme_helpers
from build_windows7_sha2 import read_cab as read_sha2_cab, CAB_NAME as SHA2_CAB_NAME
from build_windows7_kmdf import read_cab as read_kmdf_cab, CAB_NAME as KMDF_CAB_NAME
from build_windows_vista_support import build as build_vista_support


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
        for src, dst in [('README.md', 'usos-imdisk-README.txt'), ('LICENSE.md', 'usos-imdisk-LICENSE.txt'), ('source.zip', 'usos-imdisk-source.zip')]:
            writer.add_file(dst, vendor / src)
        # Core appends the chosen ISO's files/configuration and one trailer.
    finally:
        writer.close()
    (out / 'support.cpio.tmp').replace(out / 'support.cpio')
    shutil.copyfile(wimboot, out / 'wimboot')
    build_stock_support(root, out)
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


if __name__ == '__main__':
    build(Path(__file__).resolve().parents[1])
