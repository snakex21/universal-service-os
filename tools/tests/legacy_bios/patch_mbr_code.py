#!/usr/bin/env python3
import argparse
import hashlib
from pathlib import Path


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def main() -> int:
    parser = argparse.ArgumentParser(description="Replace only MBR bytes 0..439 from a donor sector and preserve bytes 440..511.")
    parser.add_argument("--target", required=True, type=Path)
    parser.add_argument("--donor", required=True, type=Path)
    args = parser.parse_args()

    with args.donor.open("rb") as f:
        donor = f.read(512)
    if len(donor) != 512:
        raise SystemExit("donor short MBR read")
    if donor[510:512] != b"\x55\xAA":
        raise SystemExit("donor MBR lacks 55AA")

    with args.target.open("r+b") as f:
        before = f.read(512)
        if len(before) != 512:
            raise SystemExit("target short MBR read")
        if before[510:512] != b"\x55\xAA":
            raise SystemExit("target MBR lacks 55AA before patch")
        preserved_tail = before[440:512]
        f.seek(0)
        f.write(donor[:440])
        f.flush()
        f.seek(0)
        after = f.read(512)

    if after[:440] != donor[:440]:
        raise SystemExit("MBR code readback mismatch")
    if after[440:512] != preserved_tail:
        raise SystemExit("MBR tail 440..511 changed")

    print(f"[PASS] target_mbr_code_sha256_before={sha256(before[:440])}")
    print(f"[PASS] donor_mbr_code_sha256={sha256(donor[:440])}")
    print(f"[PASS] target_mbr_code_sha256_after={sha256(after[:440])}")
    print(f"[PASS] preserved_tail_sha256={sha256(after[440:512])}")
    print("[PASS] bytes 440..511 preserved bit-for-bit; signature=55AA")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
