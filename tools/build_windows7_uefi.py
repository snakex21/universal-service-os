"""Build portable Windows 7 EFI and WinPE helpers with the pinned Zig toolchain."""
from pathlib import Path
import os,subprocess

def build(root,output):
    output.mkdir(parents=True,exist_ok=True)
    temp=output/'tmp';temp.mkdir(exist_ok=True)
    env=dict(os.environ,TEMP=str(temp),TMP=str(temp),ZIG_GLOBAL_CACHE_DIR=str(root/'tools/cache/zig-global'),ZIG_LOCAL_CACHE_DIR=str(output/'zig-cache'))
    zig=str(root/'tools/zig/zig.exe')
    subprocess.run([zig,'build-exe','-target','x86_64-uefi','-O','ReleaseSmall','--dep','windows7_video','-Mroot='+str(root/'tools/windows7_uefi_video_check.zig'),'-Mwindows7_video='+str(root/'src/platform/uefi/windows7_video.zig'),'-femit-bin='+str(output/'int10.original.efi')],env=env,check=True)
    include='-I'+str(root/'tools/zig/lib/libc/include/any-windows-any')
    subprocess.run([zig,'cc','-target','x86_64-windows.win7-gnu','-Os','-nostdlib','-fno-stack-protector','-fno-builtin',include,str(root/'tools/windows_driver_archive.c'),'-Wl,--entry,entry','-lkernel32','-ladvapi32','-o',str(output/'usos-drivers.exe')],env=env,check=True)
    subprocess.run([zig,'cc','-target','x86_64-windows.win7-gnu','-Os','-nostdlib','-fno-stack-protector','-fno-builtin',include,str(root/'tools/windows_unattend_drivers.c'),'-Wl,--entry,entry','-lkernel32','-lshlwapi','-lxmllite','-o',str(output/'usos-unattend-drivers.exe')],env=env,check=True)
    # USOS multi-mode VBE handler (tools/windows7_vbe_handler.S), embedded
    # into the dispatcher as the windows7_vbe_handler module.
    hdir=output/'vbe-handler';hdir.mkdir(exist_ok=True)
    subprocess.run([zig,'cc','-target','x86-freestanding-none','-c',str(root/'tools/windows7_vbe_handler.S'),'-o',str(hdir/'handler.o')],env=env,check=True)
    subprocess.run([zig,'objcopy','-O','binary','--only-section=.text',str(hdir/'handler.o'),str(hdir/'handler.bin')],env=env,check=True)
    (hdir/'handler.zig').write_text('pub const code: []const u8 = @embedFile("handler.bin");\n',encoding='utf8')
    subprocess.run([zig,'build-exe','-target','x86_64-uefi','-O','ReleaseSmall','--dep','windows7_video','--dep','edid_mode','--dep','windows7_vbe_handler','-Mroot='+str(root/'tools/windows7_uefi_wrapper.zig'),'-Mwindows7_video='+str(root/'src/platform/uefi/windows7_video.zig'),'-Medid_mode='+str(root/'src/platform/uefi/edid_mode.zig'),'-Mwindows7_vbe_handler='+str(hdir/'handler.zig'),'-femit-bin='+str(output/'win7-wrapper.efi')],env=env,check=True)
    subprocess.run([zig,'cc','-target','x86_64-windows.win7-gnu','-Os','-nostdlib','-fno-stack-protector','-fno-builtin','-I'+str(root/'tools/zig/lib/libc/include/any-windows-any'),str(root/'tools/windows7_uefi_finalize.c'),'-Wl,--entry,entry','-lkernel32','-ladvapi32','-lversion','-o',str(output/'usos-win7-finalize.exe')],env=env,check=True)

if __name__=='__main__':
    root=Path(__file__).resolve().parents[1]
    build(root,root/'zig-out/windows7-uefi')
