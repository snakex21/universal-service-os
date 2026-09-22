"""Verify and package the upstream DOS RAM-disk engine; no Microsoft files."""
from pathlib import Path
import hashlib
import json
import shutil
from build_dos_reboot import build as build_reboot


def build(root: Path):
    vendor = root / 'tools/vendor/syslinux/6.03'
    manifest = json.loads((vendor / 'manifest.json').read_text())
    out = root / 'zig-out/dos-native'
    out.mkdir(parents=True, exist_ok=True)
    for name, expected in manifest['files'].items():
        source = vendor / name
        if hashlib.sha256(source.read_bytes()).hexdigest() != expected:
            raise ValueError('Syslinux checksum mismatch: ' + name)
        shutil.copyfile(source, out / name)
    shutil.copyfile(vendor / 'manifest.json', out / 'manifest.json')
    print('[PASS] DOS support: verified MEMDISK 6.03, license and upstream sources')
    patch_vendor = root / 'tools/vendor/patcher9x/0.9.91'
    patch_manifest = json.loads((patch_vendor / 'manifest.json').read_text())
    patch_out = out / 'ram-patch'
    patch_out.mkdir(exist_ok=True)
    for name, expected in patch_manifest['files'].items():
        source = patch_vendor / name
        if hashlib.sha256(source.read_bytes()).hexdigest() != expected:
            raise ValueError('Patcher9x checksum mismatch: ' + name)
        shutil.copyfile(source, patch_out / name)
    shutil.copyfile(patch_vendor / 'manifest.json', patch_out / 'manifest.json')
    shutil.copyfile(patch_vendor / 'NOTICE.TXT', patch_out / 'NOTICE.TXT')
    for source, name in [('dos_startup.cmd', 'INSTALL.BAT'), ('dos_repair.cmd', 'REPAIR.BAT')]:
        text = (root / 'src/platform/bios' / source).read_text(encoding='ascii')
        (patch_out / name).write_bytes(text.replace('\r\n', '\n').replace('\n', '\r\n').encode('ascii'))
    print('[PASS] DOS RAM patch: verified Patcher9x 0.9.91 and CWSDPMI r7')
    dos_vendor = root / 'tools/vendor/himemx/3.40'
    dos_manifest = json.loads((dos_vendor / 'manifest.json').read_text())
    dos_out = out / 'msdos'
    dos_out.mkdir(exist_ok=True)
    for name, expected in dos_manifest['files'].items():
        if hashlib.sha256((dos_vendor / name).read_bytes()).hexdigest() != expected:
            raise ValueError('HimemX checksum mismatch: ' + name)
    for source, name in [('HIMEMX.EXE', 'HIMEMX.EXE'), ('README.TXT', 'HIMEMX.TXT'),
                         ('source-and-binaries.zip', 'HIMEMSRC.ZIP'), ('COPYING', 'LICENSE.TXT')]:
        shutil.copyfile(dos_vendor / source, dos_out / name)
    shutil.copyfile(dos_vendor / 'manifest.json', dos_out / 'manifest.json')
    for source, name in [('install.cmd', 'INSTALL.BAT'), ('live.cmd', 'LIVE.BAT'),
                         ('prepare_files.cmd', 'PREPDOS.BAT'), ('copy_group.cmd', 'COPYDOS.BAT'),
                         ('unpack_file.cmd', 'UNPACK.BAT'),
                         ('windows_start.cmd', 'W3START.BAT'), ('windows_menu.cmd', 'WINMENU.BAT'),
                         ('windows_config.sys', 'W3CONFIG.SYS'), ('windows_auto.cmd', 'W3AUTO.BAT')]:
        text = (root / 'src/platform/bios/msdos' / source).read_text(encoding='ascii')
        # COMMAND.COM expands arguments before applying its 127-byte line
        # limit. Long FOR lists can silently lose the final loop variable.
        arguments = {
            'prepare_files.cmd': ('D:\\DOSFILES', 'C:\\DOS', 'D:'),
            'copy_group.cmd': ('D:\\DOSFILES', 'C:\\DOS', 'COM'),
            'unpack_file.cmd': ('D:\\DOSFILES\\12345678.123', 'C:\\DOS', 'D:\\DOSFILES\\EXPAND.EXE'),
        }.get(source, ())
        for line in text.splitlines():
            expanded = line
            for index, argument in enumerate(arguments, 1):
                expanded = expanded.replace('%' + str(index), argument)
            if len(expanded) > 127:
                raise ValueError('MS-DOS command line exceeds 127 bytes: ' + source)
        (dos_out / name).write_bytes(text.replace('\r\n', '\n').replace('\n', '\r\n').encode('ascii'))
    print('[PASS] MS-DOS support: verified HimemX 3.40, sources, license and DOS helpers')
    build_reboot(root)
    print('[PASS] MS-DOS restart helper: built REBOOT.COM')
    from build_freedos_support import build as build_freedos
    build_freedos(root)


if __name__ == '__main__':
    build(Path(__file__).resolve().parents[1])
