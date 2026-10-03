r"""Read the AHCINT 1.3.0.0-usos2 trace from the USOS gap of a Windows 2000 disk.

    python tools/w2k_gap_trace.py \\.\PhysicalDrive10      (Windows, read-only)
    python tools/w2k_gap_trace.py /dev/sda                  (Linux, read-only)
    python tools/w2k_gap_trace.py image.qcow2               (through qemu-io)
    python tools/w2k_gap_trace.py image.raw

Read-only: opens the disk/image for reading only. Prints the marker at LBA
2046 (boot counter, last verify result, disk signature), the test sector at
2045 and the four trace records at 2040-2043 (tools/vendor/ahcint/
1.3.0.0-usos2/MODIFIED.txt; staged by tools/w2k_stage.sh).
"""
from __future__ import annotations

import re
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIRST, COUNT = 2040, 7


def read_sectors(path: str) -> bytes:
    if path.lower().endswith('.qcow2'):
        out = subprocess.run([str(ROOT / 'tools/qemu/qemu-io.exe'), '-r', '-U', '-f', 'qcow2', '-c',
                              f'read -v {FIRST * 512} {COUNT * 512}', path], capture_output=True, text=True, check=True).stdout
        data = bytearray()
        for line in out.splitlines():
            m = re.match(r'^[0-9a-f]{8}:\s+((?:[0-9a-f]{2} ){1,16})', line)
            if m:
                data += bytes.fromhex(m.group(1).replace(' ', ''))
        return bytes(data)
    with open(path, 'rb', buffering=0) as f:
        f.seek(FIRST * 512)
        return f.read(COUNT * 512)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    data = read_sectors(sys.argv[1])
    if len(data) < COUNT * 512:
        print('short read')
        return 1
    sector = lambda lba: data[(lba - FIRST) * 512:(lba - FIRST + 1) * 512]
    marker = sector(2046)
    if marker[:12] != b'USOSW2KTRACE':
        print('LBA 2046: no USOS marker (not a disk USOS prepared for Windows 2000, or before usos2)')
        return 1
    boot, verify = struct.unpack_from('<II', marker, 16)
    print(f'marker: boot counter={boot} last verify={ {0: "none", 1: "PASS", 2: "FAIL"}.get(verify, verify)} '
          f'disk signature={marker[32:40].decode(errors="replace")}')
    print('  boot counter 0 = the driver never wrote the marker back (never started, or its writes did not reach the disk)')
    test = sector(2045)
    if test[:4] == b'USOS':
        print(f'LBA 2045 test pattern: boot={struct.unpack_from("<I", test, 4)[0]}')
    else:
        print('LBA 2045 test pattern: absent')
    for lba in range(2040, 2044):
        text = sector(lba).split(b'\0', 1)[0].decode('ascii', 'replace').strip()
        print(f'--- LBA {lba}: ' + (text if text else '(empty)'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
