"""Build only the optional EFI trial menu; never runs a VM or updates a disk."""
from pathlib import Path
import os, subprocess, hashlib, json, shutil

root = Path(__file__).resolve().parents[1]
output = root / 'zig-out/csmwrap-trial'
output.mkdir(parents=True, exist_ok=True)
temp = output / 'tmp'
temp.mkdir(exist_ok=True)
vendor = root / 'tools/vendor/csmwrap/3.1.2'
manifest = json.loads((vendor/'manifest.json').read_text(encoding='utf8'))
for name, expected in manifest['files'].items():
    if hashlib.sha256((vendor/name).read_bytes()).hexdigest() != expected:
        raise ValueError('Vendor checksum mismatch: '+name)
env = dict(os.environ, TEMP=str(temp), TMP=str(temp),
           ZIG_GLOBAL_CACHE_DIR=str(root/'tools/cache/zig-global'),
           ZIG_LOCAL_CACHE_DIR=str(output/'zig-cache'))
subprocess.run([str(root/'tools/zig/zig.exe'), 'build-exe', '-target', 'x86_64-uefi',
                '-O', 'ReleaseSmall', str(root/'tools/csmwrap_boot_menu.zig'),
                '-femit-bin='+str(output/'BOOTX64.EFI')], env=env, check=True)
for name in [*manifest['files'], 'manifest.json']:
    shutil.copyfile(vendor/name, output/name)
(output/'csmwrap.ini').write_bytes(b'; USOS physical hardware trial\r\nverbose = true\r\n')
print('PASS: EFI menu compiled; CSMWrap vendor hashes verified. No VM/E2E.')
