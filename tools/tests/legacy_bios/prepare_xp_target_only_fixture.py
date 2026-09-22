#!/usr/bin/env python3
import argparse
from pathlib import Path

SECTOR = 512
MBR_CODE_LEN = 440
PARTITION_TABLE = 446
PARTITION_ENTRY = 16
VBR_CODE_OFFSET = 90
STAGE2_RESERVED_SECTOR = 8


def find_nt5_mbr_template(bootsect: bytes) -> bytes:
    prefix = bytes.fromhex("33 c0 8e d0 bc 00 7c 8e c0 8e d8 be 00 7c bf 00")
    required = (
        b"Invalid partition table",
        b"Error loading operating system",
        b"Missing operating system",
    )
    matches = []
    start = 0
    while True:
        pos = bootsect.find(prefix, start)
        if pos < 0:
            break
        block = bootsect[pos : pos + SECTOR]
        if len(block) == SECTOR and block[510:512] == b"\x55\xaa" and all(s in block for s in required):
            matches.append((pos, block))
        start = pos + 1
    if len(matches) != 1:
        raise RuntimeError(f"expected exactly one Microsoft NT5 MBR template, found {len(matches)}")
    return matches[0][1]


def u32le(data: bytes) -> int:
    return int.from_bytes(data, "little")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target-raw", required=True)
    parser.add_argument("--bootsect-exe", required=True)
    parser.add_argument("--vbr-code", required=True)
    parser.add_argument("--stage2", required=True)
    parser.add_argument("--xpsetup-slot", type=int, required=True)
    parser.add_argument("--microsoft-nt52-loader", action="store_true")
    args = parser.parse_args()

    target = Path(args.target_raw)
    bootsect_path = Path(args.bootsect_exe)
    vbr_code_path = Path(args.vbr_code)
    stage2_path = Path(args.stage2)

    if not 1 <= args.xpsetup_slot <= 4:
        raise RuntimeError("XPSETUP slot must be 1..4")

    bootsect_bytes = bootsect_path.read_bytes()
    template = find_nt5_mbr_template(bootsect_bytes)
    vbr_code = vbr_code_path.read_bytes()
    stage2 = stage2_path.read_bytes()
    if len(vbr_code) > 420:
        raise RuntimeError(f"VBR code too large: {len(vbr_code)}")
    if len(stage2) != 24 * SECTOR:
        raise RuntimeError(f"stage2 must be exactly 24 sectors, got {len(stage2)} bytes")

    with target.open("r+b", buffering=0) as f:
        mbr = bytearray(f.read(SECTOR))
        if len(mbr) != SECTOR or mbr[510:512] != b"\x55\xaa":
            raise RuntimeError("target MBR missing 55AA")

        slot = args.xpsetup_slot - 1
        entry_off = PARTITION_TABLE + slot * PARTITION_ENTRY
        entry = bytes(mbr[entry_off : entry_off + PARTITION_ENTRY])
        if entry[4] != 0x0C:
            raise RuntimeError(f"XPSETUP slot type is 0x{entry[4]:02X}, expected FAT32 LBA 0x0C")
        start_lba = u32le(entry[8:12])
        sectors = u32le(entry[12:16])
        if start_lba == 0 or sectors == 0:
            raise RuntimeError("XPSETUP partition has invalid start/count")

        original_disk_id = bytes(mbr[440:446])
        original_entries = [bytes(mbr[PARTITION_TABLE+i*16:PARTITION_TABLE+(i+1)*16]) for i in range(4)]

        # Microsoft NT5 MBR bootstrap code only. Preserve disk signature and
        # all partition geometry/type bytes from the prepared target fixture.
        mbr[:MBR_CODE_LEN] = template[:MBR_CODE_LEN]
        mbr[440:446] = original_disk_id
        for i, original in enumerate(original_entries):
            off = PARTITION_TABLE + i * PARTITION_ENTRY
            mbr[off : off + PARTITION_ENTRY] = original
            mbr[off] = 0x80 if i == slot else 0x00
        mbr[510:512] = b"\x55\xaa"

        f.seek(0)
        f.write(mbr)

        vbr_base = start_lba * SECTOR
        f.seek(vbr_base)
        vbr = bytearray(f.read(SECTOR))
        if len(vbr) != SECTOR or vbr[510:512] != b"\x55\xaa":
            raise RuntimeError("XPSETUP VBR missing 55AA")
        if u32le(vbr[28:32]) != start_lba:
            raise RuntimeError("XPSETUP VBR hidden-sectors does not match partition start")
        if vbr[64] != 0x80:
            raise RuntimeError(f"target-only expects BPB.DrvNum=0x80, got 0x{vbr[64]:02X}")

        if args.microsoft_nt52_loader:
            prefix = b"\xeb\x58\x90MSWIN4.1"
            candidates = []
            start = 0
            while True:
                pos = bootsect_bytes.find(prefix, start)
                if pos < 0:
                    break
                block = bootsect_bytes[pos : pos + SECTOR]
                if (len(block) == SECTOR and block[510:512] == b"\x55\xaa" and
                        b"NTLDR      " in block and b"NTLDR is missing" in block and
                        b"Disk error" in block):
                    candidates.append(pos)
                start = pos + 1
            if len(candidates) != 1:
                raise RuntimeError(f"expected exactly one Microsoft NT52 FAT32 VBR template, found {len(candidates)}")
            pos = candidates[0]
            nt52_vbr = bootsect_bytes[pos : pos + SECTOR]
            nt52_stage2 = bootsect_bytes[pos + 2 * SECTOR : pos + 3 * SECTOR]
            if len(nt52_stage2) != SECTOR or b"\xea\x00\x00\x00\x20" not in nt52_stage2:
                raise RuntimeError("Microsoft NT52 FAT32 stage2 template validation failed")
            # Preserve the real filesystem BPB/EBPB from mkfs.fat, including
            # HiddenSectors and BPB.DrvNum. Replace only executable tail.
            vbr[VBR_CODE_OFFSET:510] = nt52_vbr[VBR_CODE_OFFSET:510]
            f.seek(vbr_base)
            f.write(vbr)
            # Microsoft NT52 FAT32 VBR loads its second stage from
            # partition-relative sector 12 into 0000:8000.
            f.seek(vbr_base + 12 * SECTOR)
            f.write(nt52_stage2)
        else:
            vbr[VBR_CODE_OFFSET : VBR_CODE_OFFSET + len(vbr_code)] = vbr_code
            f.seek(vbr_base)
            f.write(vbr)
            f.seek(vbr_base + STAGE2_RESERVED_SECTOR * SECTOR)
            f.write(stage2)

        # Semantic read-back of the only test-only MBR change: the XPSETUP
        # entry is active, all geometry/type bytes are unchanged, and the
        # disk signature is preserved.
        f.seek(0)
        check = f.read(SECTOR)
        if check[440:446] != original_disk_id:
            raise RuntimeError("disk signature changed")
        for i, original in enumerate(original_entries):
            off = PARTITION_TABLE + i * PARTITION_ENTRY
            actual = bytearray(check[off : off + PARTITION_ENTRY])
            expected = bytearray(original)
            expected[0] = 0x80 if i == slot else 0x00
            if actual != expected:
                raise RuntimeError(f"partition entry {i+1} changed beyond active flag")

    print(f"[PASS] target-only fixture: XPSETUP slot={args.xpsetup_slot} start={start_lba} sectors={sectors} active=yes")
    print("[PASS] Microsoft NT5 MBR code installed; disk signature and partition geometry preserved")
    if args.microsoft_nt52_loader:
        print("[PASS] Microsoft NT52 FAT32 VBR/stage2 installed; BPB.DrvNum=0x80")
    else:
        print("[PASS] current USOS XP VBR/stage2 refreshed; BPB.DrvNum=0x80")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
