#!/usr/bin/env python3
import argparse
import hashlib

TAIL_BYTES = 420
READ_FUNC_OFFSET = 0x86
CHS_BRANCH_OFFSET = 0x8C
EXPECTED_BRANCH = bytes.fromhex('0F824A00')
PATCHED_BRANCH = bytes.fromhex('90909090')
EXPECTED_CONTEXT = bytes.fromhex('6660663B46F80F824A00666A00')


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--input', required=True)
    ap.add_argument('--output', required=True)
    args = ap.parse_args()

    src = open(args.input, 'rb').read()
    if len(src) != TAIL_BYTES:
        raise RuntimeError(f'NT52 VBR tail must be exactly {TAIL_BYTES} bytes, got {len(src)}')
    ctx = src[READ_FUNC_OFFSET:READ_FUNC_OFFSET + len(EXPECTED_CONTEXT)]
    if ctx != EXPECTED_CONTEXT:
        raise RuntimeError(
            'NT52 read routine signature mismatch at 0x86: '
            f'got={ctx.hex().upper()} want={EXPECTED_CONTEXT.hex().upper()}'
        )
    if src[CHS_BRANCH_OFFSET:CHS_BRANCH_OFFSET + 4] != EXPECTED_BRANCH:
        raise RuntimeError('NT52 CHS branch opcode mismatch')

    out = bytearray(src)
    out[CHS_BRANCH_OFFSET:CHS_BRANCH_OFFSET + 4] = PATCHED_BRANCH
    diffs = [i for i, (a, b) in enumerate(zip(src, out)) if a != b]
    if diffs != [CHS_BRANCH_OFFSET, CHS_BRANCH_OFFSET + 1, CHS_BRANCH_OFFSET + 2, CHS_BRANCH_OFFSET + 3]:
        raise RuntimeError(f'unexpected patch diff offsets: {diffs}')
    open(args.output, 'wb').write(out)
    print(f'[PASS] NT52 EDD-only patch bytes=4 offset=0x{CHS_BRANCH_OFFSET:02X} '
          f'base_sha256={sha256(src)} patched_sha256={sha256(out)}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
