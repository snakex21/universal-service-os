"""Exercise graphics controller reconnection with a real OVMF driver."""
from pathlib import Path
import os, subprocess
ROOT = Path(__file__).resolve().parents[2]
out = ROOT / 'zig-out/graphics-connect-test'
boot = out / 'media/EFI/BOOT'
boot.mkdir(parents=True, exist_ok=True)
temp = out / 'tmp'
temp.mkdir(exist_ok=True)
env = dict(os.environ, TEMP=str(temp), TMP=str(temp),
           ZIG_GLOBAL_CACHE_DIR=str(ROOT/'tools/cache/zig-global'),
           ZIG_LOCAL_CACHE_DIR=str(out/'zig-cache'))
subprocess.run([str(ROOT/'tools/zig/zig.exe'), 'build-exe', '-target',
                'x86_64-uefi', '-O', 'ReleaseSmall',
                str(ROOT/'tools/windows7_uefi_graphics_probe.zig'),
                '-femit-bin='+str(boot/'BOOTX64.EFI')], env=env, check=True)
qemu = ROOT/'tools/qemu'
with (out/'qemu.log').open('wb') as log:
    result = subprocess.run([str(qemu/'qemu-system-x86_64.exe'), '-machine',
        'q35', '-m', '256M', '-display', 'none', '-nic', 'none', '-monitor',
        'none', '-serial', 'none', '-drive',
        'if=pflash,format=raw,readonly=on,file='+str(qemu/'share/edk2-x86_64-code.fd'),
        '-drive', 'if=pflash,format=raw,snapshot=on,file='+str(qemu/'share/edk2-i386-vars.fd'),
        '-drive', 'format=raw,file=fat:rw:'+str(out/'media'),
        '-device', 'isa-debug-exit,iobase=0xf4,iosize=0x04', '-no-reboot'],
        env=env, stdout=log, stderr=log, timeout=45,
        creationflags=subprocess.CREATE_NO_WINDOW)
if result.returncode != 33:
    raise RuntimeError(f'GOP reconnection fixture failed: {result.returncode}')
print('PASS actual UEFI GOP disconnect/reconnect and existing GOP preservation')
