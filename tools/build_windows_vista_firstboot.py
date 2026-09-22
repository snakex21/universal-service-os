"""Build the Vista-only first-boot helper; never run it on the technician host."""
from pathlib import Path
import os
import subprocess


def build(root: Path, local_signature=False) -> Path:
    out = root / 'zig-out/vista/firstboot'
    scratch = out / 'tmp'
    scratch.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, TEMP=str(scratch), TMP=str(scratch),
               ZIG_GLOBAL_CACHE_DIR=str(root / 'tools/cache/zig-global'),
               ZIG_LOCAL_CACHE_DIR=str(out / 'zig-cache'))
    target = out / 'usos-vista-firstboot.exe'
    signature_flags=['-DUSOS_VISTA_LOCAL_SIGNATURE'] if local_signature else []
    subprocess.run([str(root / 'tools/zig/zig.exe'), 'cc', '-target',
                    'x86_64-windows.vista-gnu', '-Os', '-nostdlib',
                    '-fno-stack-protector', '-fno-builtin',
                    '-I'+str(root / 'tools/zig/lib/libc/include/any-windows-any'),
                    '-I'+str(root / 'zig-out/vista/usb-test-package'),
                    '-I'+str(root / 'zig-out/vista/community-usb'),
                    str(root / 'tools/windows_vista_firstboot.c'),
                    '-Wl,--entry,entry', '-lkernel32', '-lsetupapi',
                    '-lnewdev', '-lcfgmgr32', '-lcrypt32', '-ladvapi32', '-o', str(target)]+signature_flags,
                   env=env, check=True)
    print('VISTA_FIRSTBOOT_BUILD_OK', target.stat().st_size)
    trust=out/'usos-vista-trust.exe'
    subprocess.run([str(root/'tools/zig/zig.exe'),'cc','-target','x86_64-windows.vista-gnu','-Os','-nostdlib','-fno-stack-protector','-fno-builtin','-DUSOS_CERT_PREPARE_ONLY','-I'+str(root/'tools/zig/lib/libc/include/any-windows-any'),'-I'+str(root/'zig-out/vista/community-usb'),str(root/'tools/windows_vista_firstboot.c'),'-Wl,--entry,entry','-lkernel32','-ladvapi32','-lcrypt32','-o',str(trust)]+signature_flags,env=env,check=True)
    print('VISTA_TRUST_PREPARE_BUILD_OK',trust.stat().st_size)
    bootstrap=out/'usb.exe'
    subprocess.run([str(root/'tools/zig/zig.exe'),'cc','-target','x86_64-windows.vista-gnu','-Os','-nostdlib','-fno-stack-protector','-fno-builtin','-I'+str(root/'tools/zig/lib/libc/include/any-windows-any'),str(root/'tools/windows_vista_usb_bootstrap.c'),'-Wl,--entry,entry','-lkernel32','-ladvapi32','-o',str(bootstrap)],env=env,check=True)
    print('VISTA_USB_BOOTSTRAP_BUILD_OK',bootstrap.stat().st_size)
    prereq=out/'usos-vista-kmdf.exe'
    subprocess.run([str(root/'tools/zig/zig.exe'),'cc','-target','x86_64-windows.vista-gnu','-Os','-nostdlib','-fno-stack-protector','-fno-builtin','-I'+str(root/'tools/zig/lib/libc/include/any-windows-any'),'-I'+str(root/'zig-out/vista/community-usb'),str(root/'tools/windows_vista_kmdf.c'),'-Wl,--entry,entry','-lkernel32','-ladvapi32','-lversion','-o',str(prereq)],env=env,check=True)
    print('VISTA_KMDF_PREREQUISITE_BUILD_OK',prereq.stat().st_size)
    return target


if __name__ == '__main__':
    import argparse
    parser=argparse.ArgumentParser();parser.add_argument('--local-signature',action='store_true')
    build(Path(__file__).resolve().parents[1],parser.parse_args().local_signature)
