"""Pack Vista USB installation support using the immutable working v11 payload."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys
from build_windows_native_cache import NewcWriter

ROOT = Path(__file__).resolve().parents[1]


def build(root=ROOT, intel_profile=False):
    # Keep the physically successful binaries: changing the installer must not
    # silently rebuild or alter firstboot, certificates or the driver package.
    frozen = root / 'artifacts/vista/hardware-success-v11-20260920-235629'
    # Git-ignored (/artifacts/) but a REQUIRED build input: never clean it up
    # (docs/HANDOFF-2026-09-28-release.md).
    if not (frozen / 'manifest.json').is_file():
        raise SystemExit('Missing required build input ' + str(frozen) + ': the frozen Vista v11 payload '
                         '(git-ignored, must never be cleaned up). Restore it from a backup, e.g. '
                         'zig-out/protected-build-inputs/artifacts/vista/ (docs/HANDOFF-2026-09-28-release.md).')
    manifest = json.loads((frozen / 'manifest.json').read_text(encoding='utf-8'))
    files = []
    for relative, expected in manifest['sha256'].items():
        if not relative.startswith('payload/'):
            continue
        path = frozen / relative
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != expected:
            raise ValueError('Working Vista payload changed: ' + relative)
        files.append((path, relative[len('payload/'):].replace('/', '\\'), digest))
    if len(files) != 13:
        raise ValueError('Unexpected Vista payload inventory')
    out = root / 'zig-out/vista/usb-install'
    out.mkdir(parents=True, exist_ok=True)
    temp=out/'tmp';temp.mkdir(exist_ok=True)
    env=dict(os.environ,TEMP=str(temp),TMP=str(temp),ZIG_GLOBAL_CACHE_DIR=str(root/'tools/cache/zig-global'),ZIG_LOCAL_CACHE_DIR=str(out/'zig-cache'))
    gate=out/'usos-vista-oobe.exe'
    subprocess.run([str(root/'tools/zig/zig.exe'),'cc','-target','x86_64-windows.vista-gnu','-Os','-nostdlib','-fno-stack-protector','-fno-builtin','-I'+str(root/'tools/zig/lib/libc/include/any-windows-any'),str(root/'tools/windows_vista_oobe_gate.c'),'-Wl,--entry,entry','-lkernel32','-ladvapi32','-lnetapi32','-luser32','-o',str(gate)],env=env,check=True)
    # Added independently; the 13 hardware-tested USB files stay byte-identical.
    files.append((gate,'USOS\\oobe.exe',hashlib.sha256(gate.read_bytes()).hexdigest()))
    lines = ['static const struct { const WCHAR *source, *target; BYTE sha256[32]; } vista_files[] = {']
    for index, (path, target, digest) in enumerate(files):
        name = 'vista-payload-%02d.bin' % index
        lines.append('{L"%s",L"%s",{%s}},' % (name, target.replace('\\', '\\\\'), ','.join('0x'+digest[i:i+2] for i in range(0,64,2))))
    lines.append('};')
    (out/'vista_deploy_files.h').write_text('\n'.join(lines)+'\n', encoding='ascii')
    # An explicit hardware-trial option, never an implicit release dependency.
    profile_files=[]
    if intel_profile:
        profile=root/'zig-out/vista/intel-boot-profile'
        metadata=json.loads((profile/'manifest.json').read_text(encoding='utf-8-sig'))
        for original,packed in [('vista-target-esp.bin','vista-target-esp.bin'),('vista-bcdedit.exe','vista-bcdedit.bin'),('vista-bcdedit.exe.mui','vista-bcdedit-mui.bin')]:
            source=profile/original
            digest=hashlib.sha256(source.read_bytes()).hexdigest()
            if digest!=metadata['sha256'][original]:
                raise ValueError('Vista boot profile changed: '+original)
            profile_files.append((source,packed,digest))
    profile_lines=['static const struct { const WCHAR *name; BYTE sha256[32]; } vista_boot_files[] = {']
    for _,name,digest in profile_files:
        profile_lines.append('{L"%s",{%s}},'%(name,','.join('0x'+digest[i:i+2] for i in range(0,64,2))))
    profile_lines.append('{0,{0}}};')
    (out/'vista_boot_files.h').write_text('\n'.join(profile_lines)+'\n',encoding='ascii')
    exe=out/'usos-vista-install.exe'
    subprocess.run([str(root/'tools/zig/zig.exe'),'cc','-target','x86_64-windows.win10-gnu','-Os','-nostdlib','-fno-stack-protector','-fno-builtin','-I'+str(root/'tools/zig/lib/libc/include/any-windows-any'),'-I'+str(out),str(root/'tools/windows_vista_install.c'),'-Wl,--entry,entry','-lkernel32','-ladvapi32','-lversion','-luser32','-o',str(exe)],env=env,check=True)
    destination=root/'zig-out/windows-native';destination.mkdir(parents=True,exist_ok=True)
    # Int10 dispatcher assets, shared with Windows 7 (docs/design/win7-vista-no-csm.md
    # section 7): used only when the plan adds usos-int10-dispatcher.flag. The
    # release UefiSeven binary (manifest-checked), never the source build.
    wrapper=root/'zig-out/windows7-uefi/win7-wrapper.efi'
    if not wrapper.is_file():
        subprocess.run([sys.executable,str(root/'tools/build_windows7_uefi.py')],check=True)
    uefiseven=root/'tools/vendor/uefiseven/1.30'
    seven=json.loads((uefiseven/'manifest.json').read_text())
    for name in ('UefiSeven.efi','LICENSE.txt'):
        if hashlib.sha256((uefiseven/name).read_bytes()).hexdigest()!=seven['files'][name]:
            raise ValueError('UefiSeven checksum mismatch: '+name)
    writer=NewcWriter(destination/'vista-support.cpio.tmp')
    try:
        writer.add_file('usos-vista-install.exe',exe)
        writer.add_bytes('usos-modern-vista.cmd',(root/'tools/windows_vista_modern_startup.cmd').read_bytes().replace(b'\r\n',b'\n').replace(b'\n',b'\r\n'))
        for index,(path,_,_) in enumerate(files):
            writer.add_file('vista-payload-%02d.bin'%index,path)
        for path,name,_ in profile_files:
            writer.add_file(name,path)
        # WIMBoot treats .efi files as boot applications: neutral names, as
        # in win7-support.cpio; the startup script renames them.
        writer.add_file('usos-win7-wrapper.bin',wrapper)
        writer.add_file('usos-win7-video.bin',uefiseven/'UefiSeven.efi')
        writer.add_file('uefiseven-LICENSE.txt',uefiseven/'LICENSE.txt')
        writer.add_bytes('UefiSeven.ini',b'[config]\r\nverbose=0\r\nlogfile=1\r\nskiperrors=0\r\nforce_fakevesa=0\r\n')
    finally:
        writer.close()
    (destination/'vista-support.cpio.tmp').replace(destination/'vista-support.cpio')
    print('VISTA_USB_SUPPORT_BUILT',exe.stat().st_size,(destination/'vista-support.cpio').stat().st_size)


if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser()
    parser.add_argument('--intel-profile',action='store_true')
    build(intel_profile=parser.parse_args().intel_profile)
