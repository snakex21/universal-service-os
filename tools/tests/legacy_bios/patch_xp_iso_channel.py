from __future__ import annotations

import argparse
import hashlib
import shutil
from pathlib import Path


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest().upper()


def main() -> int:
    ap = argparse.ArgumentParser(description='Test-only in-place SETUPP.INI channel patch inside an XP ISO copy.')
    ap.add_argument('source', type=Path)
    ap.add_argument('output', type=Path)
    ap.add_argument('--from-pid', default='Pid=76447000')
    ap.add_argument('--to-pid', default='Pid=76447OEM')
    args = ap.parse_args()

    src = args.source.resolve()
    dst = args.output.resolve()
    old = args.from_pid.encode('ascii')
    new = args.to_pid.encode('ascii')
    if len(old) != len(new):
        raise SystemExit('replacement must be exactly the same length')
    if not src.is_file():
        raise SystemExit(f'source ISO missing: {src}')
    dst.parent.mkdir(parents=True, exist_ok=True)

    data = src.read_bytes()
    count_old = data.count(old)
    count_new = data.count(new)
    if count_old != 1:
        raise SystemExit(f'expected exactly one {args.from_pid!r}, found {count_old}')
    if count_new != 0:
        raise SystemExit(f'output marker already present in source: {args.to_pid!r} count={count_new}')

    offset = data.index(old)
    patched = bytearray(data)
    patched[offset:offset + len(old)] = new
    dst.write_bytes(patched)

    check = dst.read_bytes()
    if check.count(old) != 0 or check.count(new) != 1:
        raise SystemExit('readback marker validation failed')
    changed = [i for i, (a, b) in enumerate(zip(data, check)) if a != b]
    expected = list(range(offset, offset + len(old)))
    actual_nonmatching = [i for i in changed if i not in expected]
    if actual_nonmatching:
        raise SystemExit(f'unexpected changed offsets outside marker: first={actual_nonmatching[:8]}')

    print(f'[PASS] source_sha256={hashlib.sha256(data).hexdigest().upper()}')
    print(f'[PASS] output_sha256={hashlib.sha256(check).hexdigest().upper()}')
    print(f'[PASS] patched_iso_offset={offset}')
    print(f'[PASS] marker={args.from_pid} -> {args.to_pid}')
    print(f'[PASS] changed_bytes={len(changed)} confined_to_marker=yes')
    print(f'[PASS] output={dst}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
