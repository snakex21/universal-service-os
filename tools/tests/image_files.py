"""Copy files out of the first NTFS partition of a disk image (qcow2/vdi/vhd).

    python tools/tests/image_files.py IMAGE --out DIR 'WINDOWS/system32/$winnt$.inf' 'boot.ini' ...

The image is converted to a temporary VHD copy under zig-out (the input is
only read), attached without a drive letter via Mount-DiskImage (elevated
shell; read-write, Windows refuses ntfs3-written NTFS read-only), the files
are copied, and the copy is detached and deleted. Missing files are reported.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
QEMU_IMG = ROOT / 'tools' / 'qemu' / 'qemu-img.exe'


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument('image', type=Path)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('files', nargs='+')
    a = p.parse_args()
    out = a.out.resolve(); out.mkdir(parents=True, exist_ok=True)
    work = ROOT / 'zig-out' / 'image-files'; work.mkdir(parents=True, exist_ok=True)
    # Unique per image path: parallel runs must not share the temporary copy.
    tag = __import__('hashlib').sha256(str(a.image.resolve()).lower().encode()).hexdigest()[:12]
    vhd = work / f'{a.image.stem}-{tag}.copy.vhd'; vhd.unlink(missing_ok=True)
    fmt = {'.vdi': 'vdi', '.vhd': 'vpc', '.raw': 'raw'}.get(a.image.suffix.lower(), 'qcow2')
    subprocess.run([str(QEMU_IMG), 'convert', '-f', fmt, '-O', 'vpc', str(a.image.resolve()), str(vhd)], check=True)
    subprocess.run(['fsutil.exe', 'sparse', 'setflag', str(vhd), '0'], check=True, stdout=subprocess.DEVNULL)
    copies = '\n'.join(
        f"  $s = Join-Path $root '{f.replace(chr(39), chr(39) * 2)}'; if (Test-Path -LiteralPath $s) {{ Copy-Item -LiteralPath $s -Destination '{out}' -Force; 'copied {f}' }} else {{ 'missing {f}' }}"
        for f in a.files)
    script = f"""
$ErrorActionPreference = 'Stop'
$v = '{vhd}'
Mount-DiskImage -ImagePath $v -NoDriveLetter | Out-Null
try {{
  Start-Sleep 4
  $d = Get-DiskImage -ImagePath $v | Get-Disk
  $p = Get-Partition -DiskNumber $d.Number | Where-Object {{ $_.Size -gt 100MB }} | Select-Object -First 1
  $root = ($p | Get-Volume).Path
{copies}
}} finally {{
  Dismount-DiskImage -ImagePath $v | Out-Null
}}
"""
    try:
        r = subprocess.run(['powershell.exe', '-NoProfile', '-Command', script], capture_output=True, text=True)
        print(r.stdout.strip()); print(r.stderr.strip(), file=sys.stderr)
        return r.returncode
    finally:
        vhd.unlink(missing_ok=True)


if __name__ == '__main__':
    sys.exit(main())
