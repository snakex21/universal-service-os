"""Digest of a prepared XP target disk image (refactor M4 criterion).

docs/design/refactor-os-pipeline.md section 3: a change to the XP scripts is
accepted when the SAME source ISO and an empty disk give the same prepared
target: the same files and hashes on every partition (no NTFS timestamps),
the same MBR boot code and partition layout, the same partition boot code,
the same WINNT.SIF, TXTSETUP.SIF and MIGRATE.INF.

    python tools/tests/target_digest.py IMAGE.qcow2 --out digest.tsv
    python tools/tests/target_digest.py IMAGE.qcow2 --compare other.tsv

The image is converted to a temporary VHD COPY next to --work (default
tools/tests/artifacts/target-digest), attached with Mount-DiskImage
(elevated shell; read-write, because Windows will not mount an NTFS volume
written by Linux ntfs3 read-only), walked, detached and deleted; the input
image itself is only read. Values that
are random by design are masked: the MBR disk signature (0x1B8) and the NTFS
volume serial (VBR 0x48, 8 bytes).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
QEMU_IMG = ROOT / 'tools' / 'qemu' / 'qemu-img.exe'
ARTIFACTS = ROOT / 'tools' / 'tests' / 'artifacts'
NAMED = ('winnt.sif', 'txtsetup.sif', 'migrate.inf')


def ps(command: str) -> str:
    result = subprocess.run(['powershell.exe', '-NoProfile', '-Command', command], capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit('PowerShell failed: ' + result.stderr.strip())
    return result.stdout


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def masked_mbr(sector: bytes) -> tuple[str, list[tuple[int, int, int]]]:
    boot = bytearray(sector[:512])
    boot[0x1B8:0x1BC] = b'\0\0\0\0'
    parts = []
    for i in range(4):
        entry = sector[446 + 16 * i:446 + 16 * (i + 1)]
        ptype = entry[4]
        start, count = struct.unpack_from('<II', entry, 8)
        if ptype:
            parts.append((ptype, start, count))
    return sha(bytes(boot)), parts


def masked_vbr(sector: bytes) -> str:
    vbr = bytearray(sector)
    if vbr[3:11] == b'NTFS    ':
        vbr[0x48:0x50] = b'\0' * 8
    return sha(bytes(vbr))


def digest(image: Path, work: Path) -> list[str]:
    work.mkdir(parents=True, exist_ok=True)
    if not str(work.resolve()).lower().startswith(str(ARTIFACTS.resolve()).lower()) and not str(work.resolve()).lower().startswith(str((ROOT / 'zig-out').resolve()).lower()):
        raise SystemExit('work folder must be under tools/tests/artifacts or zig-out')
    vhd = work / (image.stem + '.digest.vhd')
    vhd.unlink(missing_ok=True)
    subprocess.run([str(QEMU_IMG), 'convert', '-f', 'qcow2', '-O', 'vpc', str(image), str(vhd)], check=True)
    # Windows refuses to attach a sparse VHD file.
    subprocess.run(['fsutil.exe', 'sparse', 'setflag', str(vhd), '0'], check=True, stdout=subprocess.DEVNULL)
    lines: list[str] = []
    # Raw sectors come from a raw conversion (the VHD data is not at offset 0 for dynamic VHDs).
    rawfile = work / (image.stem + '.digest.raw')
    rawfile.unlink(missing_ok=True)
    subprocess.run([str(QEMU_IMG), 'convert', '-f', 'qcow2', '-O', 'raw', str(image), str(rawfile)], check=True)
    try:
        with rawfile.open('rb') as disk:
            mbr_hash, parts = masked_mbr(disk.read(512))
            lines.append(f'mbr\tboot+table\t{mbr_hash}')
            for index, (ptype, start, count) in enumerate(parts, 1):
                disk.seek(start * 512)
                vbr = disk.read(16 * 512)
                lines.append(f'partition\t{index}\ttype=0x{ptype:02x}\tstart={start}\tsectors={count}\tvbr16={masked_vbr(vbr)}')
    finally:
        rawfile.unlink(missing_ok=True)
    listing = work / (image.stem + '.digest.json')
    listing.unlink(missing_ok=True)
    script = f'''
$ErrorActionPreference = 'Stop'
$v = '{vhd}'
Mount-DiskImage -ImagePath $v -NoDriveLetter | Out-Null
try {{
  Start-Sleep 5
  $d = Get-DiskImage -ImagePath $v | Get-Disk
  $result = @()
  foreach ($p in (Get-Partition -DiskNumber $d.Number)) {{
    $vol = $p | Get-Volume -ErrorAction SilentlyContinue
    if (-not $vol -or -not $vol.Path) {{ continue }}
    $files = @(Get-ChildItem -LiteralPath $vol.Path -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object {{
      [pscustomobject]@{{ path = $_.FullName.Substring($vol.Path.Length); size = $_.Length; sha = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }}
    }})
    $result += [pscustomobject]@{{ partition = $p.PartitionNumber; fs = $vol.FileSystem; label = $vol.FileSystemLabel; files = $files }}
  }}
  $result | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 '{listing}'
}} finally {{ Dismount-DiskImage -ImagePath $v | Out-Null }}
'''
    try:
        ps(script)
    finally:
        vhd.unlink(missing_ok=True)
    data = json.loads(listing.read_text(encoding='utf-8-sig'))
    listing.unlink(missing_ok=True)
    if isinstance(data, dict):
        data = [data]
    for volume in data:
        files = volume.get('files') or []
        if isinstance(files, dict):
            files = [files]
        lines.append(f"volume\t{volume['partition']}\t{volume['fs']}\t{volume['label']}\tfiles={len(files)}")
        for entry in sorted(files, key=lambda e: e['path'].lower()):
            if entry['path'].lower().startswith('system volume information'):
                continue
            tag = 'named' if entry['path'].rsplit('\\', 1)[-1].lower() in NAMED else 'file'
            lines.append(f"{tag}\t{volume['partition']}\t{entry['path']}\t{entry['size']}\t{entry['sha'].lower()}")
    return lines


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('image', type=Path)
    parser.add_argument('--out', type=Path)
    parser.add_argument('--compare', type=Path)
    parser.add_argument('--work', type=Path, default=ARTIFACTS / 'target-digest')
    args = parser.parse_args()
    lines = digest(args.image.resolve(), args.work)
    text = '\n'.join(lines) + '\n'
    if args.out:
        args.out.write_text(text, encoding='utf-8')
    named = sum(1 for l in lines if l.startswith('named'))
    files = sum(1 for l in lines if l.startswith(('file', 'named')))
    print(f'[DIGEST] {args.image.name}: {files} files ({named} of WINNT.SIF/TXTSETUP.SIF/MIGRATE.INF), {sum(1 for l in lines if l.startswith("partition"))} partitions')
    if args.compare:
        expected = args.compare.read_text(encoding='utf-8').splitlines()
        if expected == lines:
            print('[PASS] target digest identical to', args.compare)
            return 0
        import difflib
        for line in list(difflib.unified_diff(expected, lines, 'expected', 'actual', lineterm='', n=0))[:80]:
            print(' ', line)
        print('[FAIL] target digest differs from', args.compare)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
