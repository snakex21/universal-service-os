"""Disposable GPT target that reproduces the X470 Vista failure of 2026-09-26
(artifacts/vista-x470-setup-fail-20260926): a disk that already carries a
Windows 7 layout made by newer tools (WinRE, 100 MB ESP, MSR, C: with data).

  python make_vista_esp_repro_disk.py OUT.vhd [--size-gb 40] [--esp-files DIR]
  python make_vista_esp_repro_disk.py OUT.vhd --blank      (GPT header only)

Layout (the SSD's LBAs): p1 WinRE 2048-1023999, p2 ESP 1024000-1228799,
p3 MSR 1228800-1261567, p4 C: 1261568-end. In Vista Setup the user deletes
only C: (partition 4) and installs into the freed space; the old build then
lets Setup create a second ESP and fails with 0x1F.

Everything happens on the VHD file: it is created here (qemu-img, fixed VHD),
the GPT is written into the file, and the file is attached only to format its
own partitions. The attached disk is checked by its Location (the VHD path)
before any format, and detached afterwards. The ESP gets the Windows 7 boot
files of --esp-files (default: the X470 ESP copy) and a BCD built with
bcdedit /store on the file (no firmware or host BCD change).
"""
from __future__ import annotations

import argparse
import shutil
import struct
import subprocess
import sys
import uuid
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
QEMU_IMG = ROOT / 'tools/qemu/qemu-img.exe'
DEFAULT_ESP = ROOT / 'artifacts/vista-x470-setup-fail-20260926/ssd-esp-p2/esp'
ESP_TYPE = uuid.UUID('c12a7328-f81f-11d2-ba4b-00a0c93ec93b')
WINRE_TYPE = uuid.UUID('de94bba4-06d1-4d40-a16a-bfd50179d6ac')
MSR_TYPE = uuid.UUID('e3c9e316-0b5c-4db8-817d-f92df00215ae')
DATA_TYPE = uuid.UUID('ebd0a0a2-b9e5-4433-87c0-68b6b72699c7')
SECTOR = 512


def gpt(total_sectors: int, parts: list[tuple[uuid.UUID, int, int, int, str]]) -> tuple[bytes, bytes, bytes]:
    """Protective MBR + primary header/entries, and the backup entries/header."""
    entries = bytearray(128 * 128)
    for i, (ptype, first, last, attr, name) in enumerate(parts):
        entries[i * 128:(i + 1) * 128] = (ptype.bytes_le + uuid.uuid4().bytes_le + struct.pack('<QQQ', first, last, attr)
                                          + name.encode('utf-16-le').ljust(72, b'\0'))
    crc_entries = zlib.crc32(entries) & 0xffffffff
    last_lba = total_sectors - 1
    disk_id = uuid.uuid4().bytes_le

    def header(current: int, backup: int, entries_lba: int) -> bytes:
        h = bytearray(struct.pack('<8sIIIIQQQQ16sQIII', b'EFI PART', 0x00010000, 92, 0, 0, current, backup, 34, last_lba - 33,
                                  disk_id, entries_lba, 128, 128, crc_entries))
        h[16:20] = struct.pack('<I', zlib.crc32(h) & 0xffffffff)
        return bytes(h).ljust(SECTOR, b'\0')

    mbr = bytearray(SECTOR)
    mbr[446:462] = struct.pack('<BBBBBBBBII', 0, 0, 2, 0, 0xee, 0xff, 0xff, 0xff, 1, min(total_sectors - 1, 0xffffffff))
    mbr[510:512] = b'\x55\xaa'
    primary = bytes(mbr) + header(1, last_lba, 2) + bytes(entries)
    backup = bytes(entries) + header(last_lba, 1, last_lba - 32)
    return primary, backup, disk_id


def ps(script: str) -> str:
    r = subprocess.run(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script], capture_output=True, text=True)
    if r.returncode:
        raise SystemExit('PowerShell failed:\n' + r.stdout + r.stderr)
    return r.stdout.strip()


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument('out', type=Path)
    p.add_argument('--size-gb', type=int, default=40)
    p.add_argument('--esp-files', type=Path, default=DEFAULT_ESP)
    p.add_argument('--blank', action='store_true', help='GPT without partitions (the blank-disk case)')
    a = p.parse_args()
    out = a.out.resolve()
    if out.exists():
        raise SystemExit('refusing to overwrite ' + str(out))
    out.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([str(QEMU_IMG), 'create', '-q', '-f', 'vpc', '-o', 'subformat=fixed,force_size=on', str(out), f'{a.size_gb}G'], check=True)
    # qemu-img makes a sparse file; Windows refuses to attach sparse VHDs.
    subprocess.run(['fsutil', 'sparse', 'setflag', str(out), '0'], check=True, capture_output=True)
    total = (out.stat().st_size - 512) // SECTOR  # fixed VHD: raw data + 512-byte footer
    parts = [] if a.blank else [
        (WINRE_TYPE, 2048, 1023999, 0x8000000000000001, 'Basic data partition'),
        (ESP_TYPE, 1024000, 1228799, 0x8000000000000000, 'EFI system partition'),
        (MSR_TYPE, 1228800, 1261567, 0x8000000000000000, 'Microsoft reserved partition'),
        (DATA_TYPE, 1261568, total - 34 - 2048, 0, 'Basic data partition'),
    ]
    primary, backup, _ = gpt(total, parts)
    with open(out, 'r+b') as f:
        f.write(primary)
        f.seek((total - 33) * SECTOR)
        f.write(backup)
    if a.blank:
        print('[PASS] blank GPT target', out)
        return 0
    esp_files = a.esp_files.resolve()
    work = out.parent / (out.stem + '-mount')
    work.mkdir(exist_ok=True)
    esp_dir, c_dir = work / 'esp', work / 'c'
    esp_dir.mkdir(exist_ok=True); c_dir.mkdir(exist_ok=True)
    vhd = str(out).replace("'", "''")
    # Attach, check that the disk IS this file, format only its partitions.
    number = ps(f"Mount-DiskImage -ImagePath '{vhd}' | Out-Null; $d = $null; "
                f"for ($i = 0; $i -lt 20 -and -not $d; $i++) {{ Start-Sleep -Milliseconds 500; $d = Get-DiskImage -ImagePath '{vhd}' | Get-Disk -ErrorAction SilentlyContinue }}; "
                f"if (-not $d -or $d.Location -ne '{vhd}') {{ Dismount-DiskImage -ImagePath '{vhd}' | Out-Null; throw 'attached disk is not the VHD' }}; $d.Number")
    try:
        ps(f"$d = Get-Disk -Number {number}; if ($d.Location -ne '{vhd}') {{ throw 'disk moved' }}; "
           f"Get-Partition -DiskNumber {number} -PartitionNumber 1 | Format-Volume -FileSystem NTFS -NewFileSystemLabel WinRE -Confirm:$false | Out-Null; "
           f"Get-Partition -DiskNumber {number} -PartitionNumber 2 | Format-Volume -FileSystem FAT32 -NewFileSystemLabel SYSTEM -Confirm:$false | Out-Null; "
           f"Get-Partition -DiskNumber {number} -PartitionNumber 4 | Format-Volume -FileSystem NTFS -NewFileSystemLabel Win7 -Confirm:$false | Out-Null; "
           f"Add-PartitionAccessPath -DiskNumber {number} -PartitionNumber 2 -AccessPath '{esp_dir}\\'; "
           f"Add-PartitionAccessPath -DiskNumber {number} -PartitionNumber 4 -AccessPath '{c_dir}\\'")
        # Windows 7 boot files as bcdboot left them (logs and the BCD are rebuilt).
        for src in esp_files.rglob('*'):
            rel = src.relative_to(esp_files)
            if src.is_dir() or src.name.upper().startswith('BCD') or src.suffix.lower() in ('.log', '.txt') or 'usos-' in src.name.lower():
                continue
            dst = esp_dir / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, dst)
        # The Windows 7 BCD, bound to THIS disk's ESP and C: (store file only).
        store = esp_dir / 'EFI/Microsoft/Boot/BCD'
        store.parent.mkdir(parents=True, exist_ok=True)
        esp_letter, c_letter = ps(f"$e = Get-Partition -DiskNumber {number} -PartitionNumber 2; $c = Get-Partition -DiskNumber {number} -PartitionNumber 4; "
                                  f"$e | Add-PartitionAccessPath -AssignDriveLetter; $c | Add-PartitionAccessPath -AssignDriveLetter; "
                                  f"(Get-Partition -DiskNumber {number} -PartitionNumber 2).DriveLetter; (Get-Partition -DiskNumber {number} -PartitionNumber 4).DriveLetter").split()

        def bcd(*args: str) -> str:
            r = subprocess.run(['bcdedit', '/store', str(store), *args], capture_output=True, text=True, errors='replace')
            if r.returncode:
                raise SystemExit('bcdedit ' + ' '.join(args) + ' failed: ' + r.stdout + r.stderr)
            return r.stdout
        subprocess.run(['bcdedit', '/createstore', str(store)], check=True, capture_output=True)
        bcd('/create', '{bootmgr}', '/d', 'Windows Boot Manager')
        bcd('/set', '{bootmgr}', 'device', f'partition={esp_letter}:')
        bcd('/set', '{bootmgr}', 'path', r'\EFI\Microsoft\Boot\bootmgfw.efi')
        created = bcd('/create', '/d', 'Windows 7', '/application', 'osloader')
        guid = created[created.index('{'):created.index('}') + 1]
        for element, value in (('device', f'partition={c_letter}:'), ('osdevice', f'partition={c_letter}:'),
                               ('path', r'\Windows\system32\winload.efi'), ('systemroot', r'\Windows'), ('locale', 'pl-PL')):
            bcd('/set', guid, element, value)
        bcd('/displayorder', guid, '/addlast')
        bcd('/default', guid)
        bcd('/timeout', '5')
        # C: holds a Windows 7 tree marker and user data that the test later deletes.
        (c_dir / 'Windows/System32').mkdir(parents=True, exist_ok=True)
        (c_dir / 'Windows/System32/usos-repro-marker.txt').write_text('USOS repro: former Windows 7 system volume\n')
        (c_dir / 'Users/Public/Documents').mkdir(parents=True, exist_ok=True)
        (c_dir / 'Users/Public/Documents/data.txt').write_text('user data on the old C:\n')
        ps(f"Remove-PartitionAccessPath -DiskNumber {number} -PartitionNumber 2 -AccessPath '{esp_letter}:\\'; "
           f"Remove-PartitionAccessPath -DiskNumber {number} -PartitionNumber 4 -AccessPath '{c_letter}:\\'; "
           f"Remove-PartitionAccessPath -DiskNumber {number} -PartitionNumber 2 -AccessPath '{esp_dir}\\'; "
           f"Remove-PartitionAccessPath -DiskNumber {number} -PartitionNumber 4 -AccessPath '{c_dir}\\'")
    finally:
        ps(f"Dismount-DiskImage -ImagePath '{vhd}' | Out-Null")
    shutil.rmtree(work, ignore_errors=True)
    print('[PASS] Win7-style target', out)
    return 0


if __name__ == '__main__':
    sys.exit(main())
