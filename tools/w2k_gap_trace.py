r"""Read the AHCINT trace from the USOS gap of a Windows 2000 disk.

    python tools/w2k_gap_trace.py \\.\PhysicalDrive10      (Windows, read-only)
    python tools/w2k_gap_trace.py /dev/sda                  (Linux, read-only)
    python tools/w2k_gap_trace.py image.qcow2               (through qemu-io)
    python tools/w2k_gap_trace.py image.raw

Read-only: opens the disk/image for reading only. Prints the marker at LBA
2046 (boot counter, last verify result, disk signature), the test sector at
2045 and the four trace records at 2040-2043 (tools/vendor/ahcint/
1.3.0.0-usos4/MODIFIED.txt; staged by tools/w2k_stage.sh). Records of
usos4 (fields in minimal hex) are also decoded: the counters, the stall
snapshot (port registers of a command busy for 2 s) and every port line.
"""
from __future__ import annotations

import re
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIRST, COUNT = 2040, 7

WHY = {
    'init': 'driver start (marker read, write test passed)',
    'init-VERIFY-FAIL': 'driver start, write test FAILED',
    'periodic': 'every 2048 writes',
    'shutdown': 'SRB_FUNCTION_SHUTDOWN',
    'flush1': 'first flush',
    'write-lba0': 'first write to LBA 0',
    'write-lba2048': 'first write over LBA 2048',
    'BUGCHECK': 'STOP (bugcheck callback)',
    'busreset': 'ScsiPort reset the bus (a request timed out at the ScsiPort level)',
    'idle20s': '20 s without a new request while the miniport timer still ran',
    'stall': 'a command was still busy after 2 s and timed out at 3 s',
    'slow': 'a command took more than 2 s but completed',
}


def fields(line: str) -> dict[str, int]:
    """key=hexvalue pairs of one trace line (a repeated key gets a suffix)."""
    out: dict[str, int] = {}
    for key, value in re.findall(r'(\w+)=([0-9A-Fa-f]+)\b', line):
        name, n = key, 2
        while name in out:
            name, n = f'{key}{n}', n + 1
        out[name] = int(value, 16)
    return out


def tfd_text(tfd: int) -> str:
    sts, err = tfd & 0xFF, (tfd >> 8) & 0xFF
    bits = [n for b, n in ((0x80, 'BSY'), (0x40, 'DRDY'), (0x20, 'DF'), (0x08, 'DRQ'), (0x01, 'ERR')) if sts & b]
    return f'status {sts:02X} ({" ".join(bits) or "-"}) error {err:02X}'


def is_text(value: int) -> str:
    names = {0: 'DHRS', 1: 'PSS', 2: 'DSS', 3: 'SDBS', 4: 'UFS', 5: 'DPS', 6: 'PCS', 7: 'DMPS', 22: 'PRCS', 23: 'IPMS',
             24: 'OFS', 26: 'INFS', 27: 'IFS', 28: 'HBDS', 29: 'HBFS', 30: 'TFES', 31: 'CPDS'}
    return ' '.join(n for b, n in names.items() if value >> b & 1) or '-'


def explain(text: str) -> list[str]:
    """Plain-language notes for one usos4 trace record (empty for older ones)."""
    notes: list[str] = []
    if 'usos4' not in text.split('\n', 1)[0]:
        return notes
    for line in text.splitlines():
        f = fields(line)
        if line.startswith('AHCINT'):
            m = re.search(r'why=(\S+)', line)
            if m:
                notes.append(f'why: {m.group(1)} = {WHY.get(m.group(1), "?")}')
        elif 'isr' in f and 'srb' in f:
            notes.append(f"interrupts {f['isr']} (claimed {f.get('own', 0)}; AHCINT polls, none expected), "
                         f"timer ticks {f['tm']} ({f['tm'] / 4:.0f} s), requests {f['srb']}, idle {f['idle'] / 4:.0f} s, "
                         f"bus resets {f['bres']}, stalls {f['stalls']}")
        elif line.startswith('snap'):
            mode = 'irq' if (f.get('ghc', 0) & 2) and f.get('ie', 0) else 'poll'
            op = f.get('op', 0)
            notes.append(f"STALL port {f.get('p')}: CI {f.get('ci', 0):08X} ({'still issued' if f.get('ci') else 'cleared'}) "
                         f"SACT {f.get('sact', 0):08X}, completion by {mode}")
            notes.append(f"  command {'ATAPI %02X' % (op & 0xFF) if op > 0xFF else 'ATA %02X' % op} "
                         f"LBA {f.get('lba', 0):08X} count {f.get('n', 0)}; TFD {tfd_text(f.get('tfd', 0))}")
            notes.append(f"  PxIS {f.get('is', 0):08X} [{is_text(f.get('is', 0))}] PxSERR {f.get('serr', 0):08X} "
                         f"PxCMD {f.get('cmd', 0):08X} HBA IS {f.get('his', 0):08X}")
        elif line.startswith('port'):
            notes.append(f"port {f.get('p')}: SSTS {f.get('ssts', 0):X} CI {f.get('ci', 0):X} TFD {tfd_text(f.get('tfd', 0))} "
                         f"IS [{is_text(f.get('is', 0))}] SERR {f.get('serr', 0):X}")
    return notes


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
        print(f'--- LBA {lba} (boot % 4 = {lba - 2040}): ' + (text if text else '(empty)'))
        for note in explain(text):
            print('    > ' + note)
    return 0


if __name__ == '__main__':
    sys.exit(main())
