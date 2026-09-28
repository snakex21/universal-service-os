"""Boot a real GOP mode-change regression fixture; wait for guest termination."""
from pathlib import Path
import os, subprocess
ROOT=Path(__file__).resolve().parents[2]
out=ROOT/'zig-out/graphics-refresh-test'
boot=out/'media/EFI/BOOT';boot.mkdir(parents=True,exist_ok=True)
temp=out/'tmp';temp.mkdir(exist_ok=True)
info=out/'build-info.zig'
info.write_text('pub const id="GRAPHICS-TEST"; pub const epoch:u64=0; pub const source_sha256="TEST"; pub const version="";')
env=dict(os.environ,TEMP=str(temp),TMP=str(temp),ZIG_GLOBAL_CACHE_DIR=str(ROOT/'tools/cache/zig-global'),ZIG_LOCAL_CACHE_DIR=str(out/'zig-cache'))
subprocess.run([str(ROOT/'tools/zig/zig.exe'),'build-exe','-target','x86_64-uefi','-O','ReleaseSmall','--dep','usos','--dep','ps2_mouse','-Mroot='+str(ROOT/'src/platform/uefi/graphics_refresh_probe.zig'),'--dep','build_info','-Musos='+str(ROOT/'src/root.zig'),'-Mbuild_info='+str(info),'-Mps2_mouse='+str(ROOT/'src/arch/x86/ps2_mouse.zig'),'-femit-bin='+str(boot/'BOOTX64.EFI')],env=env,check=True)
qemu=ROOT/'tools/qemu'
with (out/'qemu.log').open('wb') as log:
    result=subprocess.run([str(qemu/'qemu-system-x86_64.exe'),'-machine','q35','-m','256M','-display','none','-nic','none','-monitor','none','-serial','file:'+str(out/'serial.log'),'-drive','if=pflash,format=raw,readonly=on,file='+str(qemu/'share/edk2-x86_64-code.fd'),'-drive','if=pflash,format=raw,snapshot=on,file='+str(qemu/'share/edk2-i386-vars.fd'),'-drive','format=raw,file=fat:rw:'+str(out/'media'),'-device','isa-debug-exit,iobase=0xf4,iosize=0x04','-no-reboot'],env=env,stdout=log,stderr=log,timeout=45,creationflags=subprocess.CREATE_NO_WINDOW)
text=(out/'serial.log').read_text(errors='replace')
if result.returncode!=33 or 'GRAPHICS_REFRESH_PASS' not in text:raise RuntimeError(text)
print('PASS actual UEFI GOP resize: renderer uses the new 1024x768 geometry')
