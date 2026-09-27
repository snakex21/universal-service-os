#!/usr/bin/env python3
import argparse
import hashlib
from pathlib import Path

SECTOR = 512
VBR_CODE_OFFSET = 90
VBR_CODE_END = 510


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def find_fat32_nt52_template(payload: bytes) -> tuple[int, bytes, bytes]:
    prefix = b"\xeb\x58\x90MSWIN4.1"
    candidates: list[int] = []
    start = 0
    while True:
        pos = payload.find(prefix, start)
        if pos < 0:
            break
        vbr = payload[pos : pos + SECTOR]
        if (
            len(vbr) == SECTOR
            and vbr[510:512] == b"\x55\xaa"
            and b"NTLDR      " in vbr
            and b"NTLDR is missing" in vbr
            and b"Disk error" in vbr
        ):
            candidates.append(pos)
        start = pos + 1

    if len(candidates) != 1:
        raise RuntimeError(
            f"expected exactly one Microsoft NT52 FAT32 VBR template, found {len(candidates)}"
        )

    pos = candidates[0]
    vbr = payload[pos : pos + SECTOR]
    # bootsect.exe stores the FAT32 secondary loader two sectors after the VBR
    # template. This loader performs the Microsoft NTLDR/SETUPLDR handoff that
    # the XP control proved works with the local-source layout.
    stage2 = payload[pos + 2 * SECTOR : pos + 3 * SECTOR]
    if len(stage2) != SECTOR:
        raise RuntimeError(f"NT52 FAT32 stage2 has invalid size: {len(stage2)}")
    if b"\xea\x00\x00\x00\x20" not in stage2:
        raise RuntimeError("NT52 FAT32 stage2 validation failed: 0000:2000 handoff missing")
    return pos, vbr, stage2


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bootsect-exe", required=True)
    parser.add_argument("--vbr-tail-out", required=True)
    parser.add_argument("--stage2-out", required=True)
    parser.add_argument("--ntfs-out")
    # Vista without firmware CSM (vista-x64-sp2-uefi-csmwrap): the NT60 NTFS
    # boot code (loads BOOTMGR) for the PE10 staging partition on the target.
    parser.add_argument("--nt60-ntfs-out")
    args = parser.parse_args()

    bootsect_path = Path(args.bootsect_exe)
    if not bootsect_path.is_file():
        raise FileNotFoundError(f"bootsect.exe missing: {bootsect_path}")

    payload = bootsect_path.read_bytes()
    if args.ntfs_out:
        prefix = b'\xeb\x52\x90NTFS    '
        candidates = []
        cursor = 0
        while True:
            candidate = payload.find(prefix, cursor)
            if candidate < 0:
                break
            cursor = candidate + 1
            block = payload[candidate:candidate + 8192]
            if len(block) == 8192 and block[510:512] == b'\x55\xaa' and b'NTLDR is missing' in block[:512]:
                candidates.append(block)
        if len(candidates) != 1:
            raise RuntimeError('Expected exactly one NT52 NTFS bootstrap')
        block = bytearray(candidates[0])
        # NT52 also selects CHS for low LBAs on NTFS. USB boot ordering can
        # change BIOS geometry, including when the loader reloads its own BPB.
        # Keep the existing EDD capability check and error handling intact.
        if block[212:221] != bytes.fromhex('663B0620000F823A00'):
            raise RuntimeError('NT52 NTFS read routine signature mismatch')
        block[217:221] = b'\x90' * 4
        Path(args.ntfs_out).write_bytes(block)
        print('[PASS] NT52 NTFS EDD bootstrap 8192 bytes SHA256=' + sha256(block))
    if args.nt60_ntfs_out:
        prefix = b'\xeb\x52\x90NTFS    '
        candidates = []
        cursor = 0
        while True:
            candidate = payload.find(prefix, cursor)
            if candidate < 0:
                break
            cursor = candidate + 1
            block = payload[candidate:candidate + 8192]
            if (len(block) == 8192 and block[510:512] == b'\x55\xaa'
                    and b'BOOTMGR is compressed' in block[:512]
                    and 'BOOTMGR'.encode('utf-16-le') in block[512:1024]
                    and b'NTLDR' not in block[:512]):
                candidates.append(block)
        if len(candidates) != 1:
            raise RuntimeError('Expected exactly one NT60 NTFS bootstrap')
        Path(args.nt60_ntfs_out).write_bytes(candidates[0])
        print('[PASS] NT60 NTFS bootstrap 8192 bytes SHA256=' + sha256(candidates[0]))
    pos, vbr, stage2 = find_fat32_nt52_template(payload)
    tail = vbr[VBR_CODE_OFFSET:VBR_CODE_END]
    if len(tail) != 420:
        raise RuntimeError(f"NT52 FAT32 VBR executable tail must be 420 bytes, got {len(tail)}")

    vbr_out = Path(args.vbr_tail_out)
    stage2_out = Path(args.stage2_out)
    vbr_out.parent.mkdir(parents=True, exist_ok=True)
    stage2_out.parent.mkdir(parents=True, exist_ok=True)
    vbr_out.write_bytes(tail)
    stage2_out.write_bytes(stage2)

    print(
        f"[PASS] Microsoft NT52 FAT32 template offset=0x{pos:X} "
        f"vbr_tail={len(tail)} sha256={sha256(tail)}"
    )
    print(
        f"[PASS] Microsoft NT52 FAT32 stage2={len(stage2)} "
        f"sha256={sha256(stage2)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
