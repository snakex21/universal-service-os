#!/usr/bin/env python3
import argparse
import hashlib

SECTOR = 512
MBR_CODE = 440


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--target-raw', required=True)
    ap.add_argument('--mbr-code', required=True)
    args = ap.parse_args()

    code = open(args.mbr_code, 'rb').read()
    if len(code) != MBR_CODE:
        raise RuntimeError(f'MBR code must be exactly {MBR_CODE} bytes, got {len(code)}')

    with open(args.target_raw, 'r+b', buffering=0) as f:
        before = f.read(SECTOR)
        if len(before) != SECTOR or before[510:512] != b'\x55\xAA':
            raise RuntimeError('target MBR is invalid or short')
        tail = before[MBR_CODE:]
        f.seek(0)
        written = f.write(code)
        if written != MBR_CODE:
            raise RuntimeError(f'short MBR code write: {written}')
        f.flush()
        f.seek(0)
        after = f.read(SECTOR)

    if after[:MBR_CODE] != code:
        raise RuntimeError('MBR boot-code readback mismatch')
    if after[MBR_CODE:] != tail:
        raise RuntimeError('MBR Disk ID / partition table / signature changed')

    print(f'[PASS] MBR boot code replaced target={args.target_raw}')
    print(f'[PASS] new code sha256={sha256(code)}')
    print(f'[PASS] bytes 440..511 preserved sha256={sha256(tail)}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
