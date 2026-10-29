"""Builds the USOS NT pre-boot logger (tools/nt_bootlog) as
zig-out/nt-bootlog/BOOTX64.EFI and runs its host unit tests first.
Never runs a VM and never writes a disk; deployment is a separate step
(the target ESP keeps CSMWrap as \\EFI\\BOOT\\CSMWRAPX.EFI)."""
from pathlib import Path
import hashlib, os, subprocess, sys

root = Path(__file__).resolve().parents[1]
output = root / 'zig-out/nt-bootlog'
output.mkdir(parents=True, exist_ok=True)
temp = output / 'tmp'
temp.mkdir(exist_ok=True)
zig = str(root / 'tools/zig/zig.exe')
env = dict(os.environ, TEMP=str(temp), TMP=str(temp),
           ZIG_GLOBAL_CACHE_DIR=str(root / 'tools/cache/zig-global'),
           ZIG_LOCAL_CACHE_DIR=str(output / 'zig-cache'))
subprocess.run([zig, 'test', str(root / 'tools/nt_bootlog/decode.zig')], env=env, check=True)
efi = output / 'BOOTX64.EFI'
subprocess.run([zig, 'build-exe', '-target', 'x86_64-uefi', '-O', 'ReleaseSmall',
                str(root / 'tools/nt_bootlog/main.zig'), '-femit-bin=' + str(efi)],
               env=env, check=True)
data = efi.read_bytes()
assert data[:2] == b'MZ', 'not a PE image'
print('PASS: nt-bootlog built', efi, len(data), 'bytes sha256', hashlib.sha256(data).hexdigest())
sys.exit(0)
