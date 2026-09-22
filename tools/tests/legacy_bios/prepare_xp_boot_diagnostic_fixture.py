#!/usr/bin/env python3
import argparse
import hashlib
import os
import struct
import zlib

SECTOR = 512
VBR_CODE_ADDR = 0x7C5A
VBR_HELPER_ADDR = 0x7D7B
STAGE2_ADDR = 0x8000
STAGE2_HELPER_ADDR = 0x8148
PRELUDE_ORIGINAL_MBR_OFFSET = 0x0C00
PRELUDE_RUNTIME_OFFSET = 0x0E00
EXPECTED_CRC_SENTINEL = 0xA17EC0DE
NTLDR_BYTES_SENTINEL = 0xA17E51AE


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def read_exact(f, offset: int, size: int) -> bytes:
    f.seek(offset)
    data = f.read(size)
    if len(data) != size:
        raise RuntimeError(f"short read at {offset}: got {len(data)} want {size}")
    return data


def write_exact(f, offset: int, data: bytes) -> None:
    f.seek(offset)
    written = f.write(data)
    if written != len(data):
        raise RuntimeError(f"short write at {offset}: got {written} want {len(data)}")


def call16(site_addr: int, target_addr: int) -> bytes:
    disp = target_addr - (site_addr + 3)
    if not -32768 <= disp <= 32767:
        raise RuntimeError(f"near call out of range site=0x{site_addr:04X} target=0x{target_addr:04X}")
    return b'\xE8' + struct.pack('<h', disp)


def jmp16(site_addr: int, target_addr: int) -> bytes:
    disp = target_addr - (site_addr + 3)
    if not -32768 <= disp <= 32767:
        raise RuntimeError(f"near jump out of range site=0x{site_addr:04X} target=0x{target_addr:04X}")
    return b'\xE9' + struct.pack('<h', disp)


def read_fat32_short_file(f, start_lba: int, vbr: bytes, short_name: bytes) -> bytes:
    if len(short_name) != 11:
        raise RuntimeError('FAT32 short name must be exactly 11 bytes')
    bps = struct.unpack_from('<H', vbr, 11)[0]
    spc = vbr[13]
    reserved = struct.unpack_from('<H', vbr, 14)[0]
    fats = vbr[16]
    fat_sectors = struct.unpack_from('<I', vbr, 36)[0]
    root_cluster = struct.unpack_from('<I', vbr, 44)[0]
    if bps != SECTOR or spc == 0 or fats == 0 or fat_sectors == 0 or root_cluster < 2:
        raise RuntimeError('unsupported FAT32 geometry while reading diagnostic NTLDR')
    fat_lba = start_lba + reserved
    data_lba = fat_lba + fats * fat_sectors

    def cluster_lba(cluster: int) -> int:
        if cluster < 2:
            raise RuntimeError(f'invalid FAT32 cluster {cluster}')
        return data_lba + (cluster - 2) * spc

    def fat_next(cluster: int) -> int:
        off = cluster * 4
        sec = fat_lba + off // bps
        pos = off % bps
        entry = read_exact(f, sec * SECTOR, SECTOR)
        return struct.unpack_from('<I', entry, pos)[0] & 0x0FFFFFFF

    seen = set()
    cluster = root_cluster
    found_cluster = None
    found_size = None
    while 2 <= cluster < 0x0FFFFFF8:
        if cluster in seen:
            raise RuntimeError('FAT32 root directory cluster loop')
        seen.add(cluster)
        for sec_index in range(spc):
            sec = read_exact(f, (cluster_lba(cluster) + sec_index) * SECTOR, SECTOR)
            for off in range(0, SECTOR, 32):
                entry = sec[off:off + 32]
                first = entry[0]
                if first == 0x00:
                    cluster = 0x0FFFFFFF
                    break
                if first == 0xE5 or entry[11] == 0x0F or (entry[11] & 0x08):
                    continue
                if entry[0:11] == short_name:
                    hi = struct.unpack_from('<H', entry, 20)[0]
                    lo = struct.unpack_from('<H', entry, 26)[0]
                    found_cluster = (hi << 16) | lo
                    found_size = struct.unpack_from('<I', entry, 28)[0]
                    break
            if found_cluster is not None or cluster >= 0x0FFFFFF8:
                break
        if found_cluster is not None or cluster >= 0x0FFFFFF8:
            break
        cluster = fat_next(cluster)
    if found_cluster is None or found_size is None:
        raise RuntimeError(f'FAT32 file not found: {short_name!r}')

    data = bytearray()
    seen.clear()
    cluster = found_cluster
    while len(data) < found_size:
        if cluster < 2 or cluster >= 0x0FFFFFF8:
            raise RuntimeError('FAT32 file chain ended before file size')
        if cluster in seen:
            raise RuntimeError('FAT32 file cluster loop')
        seen.add(cluster)
        raw = read_exact(f, cluster_lba(cluster) * SECTOR, spc * SECTOR)
        take = min(len(raw), found_size - len(data))
        data.extend(raw[:take])
        if len(data) < found_size:
            cluster = fat_next(cluster)
    return bytes(data)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--target-raw', required=True)
    ap.add_argument('--diag-mbr', required=True)
    ap.add_argument('--diag-prelude', required=True)
    ap.add_argument('--diag-vbr-helper', required=True)
    ap.add_argument('--diag-stage2-helper', required=True)
    ap.add_argument('--diag-runtime', required=True)
    ap.add_argument('--nt52-vbr-tail', required=True)
    ap.add_argument('--nt52-stage2', required=True)
    ap.add_argument('--xpsetup-slot', type=int, default=1)
    ap.add_argument('--expected-xpsetup-start-lba', type=int, default=2048)
    args = ap.parse_args()

    if args.xpsetup_slot not in (1, 2, 3, 4):
        raise RuntimeError('xpsetup slot must be 1..4')

    mbr_code = open(args.diag_mbr, 'rb').read()
    prelude = bytearray(open(args.diag_prelude, 'rb').read())
    vbr_helper = open(args.diag_vbr_helper, 'rb').read()
    stage2_helper = open(args.diag_stage2_helper, 'rb').read()
    runtime = bytearray(open(args.diag_runtime, 'rb').read())
    nt52_vbr_tail = open(args.nt52_vbr_tail, 'rb').read()
    nt52_stage2 = open(args.nt52_stage2, 'rb').read()

    if len(mbr_code) != 440:
        raise RuntimeError(f'diagnostic MBR must be exactly 440 bytes, got {len(mbr_code)}')
    if len(prelude) != 8 * SECTOR:
        raise RuntimeError(f'diagnostic prelude must be exactly {8*SECTOR} bytes, got {len(prelude)}')
    if len(runtime) != SECTOR:
        raise RuntimeError(f'diagnostic runtime must be exactly {SECTOR} bytes, got {len(runtime)}')
    sentinel = struct.pack('<I', EXPECTED_CRC_SENTINEL)
    size_sentinel = struct.pack('<I', NTLDR_BYTES_SENTINEL)
    if runtime.count(sentinel) != 1:
        raise RuntimeError('diagnostic runtime CRC sentinel must occur exactly once')
    if runtime.count(size_sentinel) != 1:
        raise RuntimeError('diagnostic runtime NTLDR-size sentinel must occur exactly once')
    if len(nt52_vbr_tail) != 420:
        raise RuntimeError(f'NT52 VBR tail must be exactly 420 bytes, got {len(nt52_vbr_tail)}')
    if len(nt52_stage2) != SECTOR:
        raise RuntimeError(f'NT52 stage2 must be exactly 512 bytes, got {len(nt52_stage2)}')

    vbr_helper_off = VBR_HELPER_ADDR - VBR_CODE_ADDR
    vbr_helper_end = vbr_helper_off + len(vbr_helper)
    if vbr_helper_off != 0x121 or vbr_helper_end > (0x7DF9 - VBR_CODE_ADDR):
        raise RuntimeError('VBR helper exceeds the approved injection window')

    stage2_helper_off = STAGE2_HELPER_ADDR - STAGE2_ADDR
    stage2_helper_end = stage2_helper_off + len(stage2_helper)
    if stage2_helper_off != 0x148 or stage2_helper_end > 0x1FE:
        raise RuntimeError('stage2 helper exceeds the approved zero-tail injection window')

    expected_stage2_sites = {
        0x000: bytes.fromhex('660FB64610'),
        0x056: bytes.fromhex('E887FC'),
        0x086: bytes.fromhex('8B7509'),
        0x0D6: bytes.fromhex('8A5640'),
    }

    with open(args.target_raw, 'r+b', buffering=0) as f:
        mbr = bytearray(read_exact(f, 0, SECTOR))
        if mbr[510:512] != b'\x55\xAA':
            raise RuntimeError('target MBR signature is not 55AA')
        entry_off = 446 + (args.xpsetup_slot - 1) * 16
        entry = mbr[entry_off:entry_off + 16]
        status = entry[0]
        ptype = entry[4]
        start_lba, sectors = struct.unpack_from('<II', entry, 8)
        if status != 0x80 or ptype != 0x0C:
            raise RuntimeError(f'XPSETUP entry mismatch: status=0x{status:02X} type=0x{ptype:02X}')
        if start_lba != args.expected_xpsetup_start_lba or sectors != 4194304:
            raise RuntimeError(
                f'XPSETUP geometry mismatch: start={start_lba} expected={args.expected_xpsetup_start_lba} sectors={sectors}'
            )

        vbr_off = start_lba * SECTOR
        vbr = bytearray(read_exact(f, vbr_off, SECTOR))
        if vbr[510:512] != b'\x55\xAA':
            raise RuntimeError('XPSETUP VBR signature is not 55AA')
        bps = struct.unpack_from('<H', vbr, 11)[0]
        spc = vbr[13]
        reserved = struct.unpack_from('<H', vbr, 14)[0]
        hidden = struct.unpack_from('<I', vbr, 28)[0]
        label = bytes(vbr[71:82]).decode('ascii', 'replace').rstrip()
        if bps != 512 or spc != 8 or reserved < 32 or hidden != start_lba or label != 'XPSETUP':
            raise RuntimeError(
                f'XPSETUP BPB mismatch: bps={bps} spc={spc} reserved={reserved} hidden={hidden} label={label!r}'
            )

        current_tail = bytes(vbr[90:510])
        if current_tail != nt52_vbr_tail:
            # Localized XP media keeps the NT52 FAT32 machine code identical but
            # translates the three user-facing error strings near the end of the
            # sector. Accept only that known message window; every byte outside
            # it must still match the canonical Microsoft NT52 template.
            localized_message_start = 0x154
            localized_message_end = 0x19E
            mismatches = [
                i for i, (actual, expected) in enumerate(zip(current_tail, nt52_vbr_tail))
                if actual != expected
            ]
            unexpected = [
                i for i in mismatches
                if not (localized_message_start <= i < localized_message_end)
            ]
            if unexpected:
                raise RuntimeError(
                    f'physical/fixture VBR differs from Microsoft NT52 outside localized message window: '
                    f'first_unexpected=0x{unexpected[0]:03X} count={len(unexpected)} '
                    f'got={sha256(current_tail)} want={sha256(nt52_vbr_tail)}'
                )
            print(
                f'[PASS] localized Microsoft NT52 VBR accepted: '
                f'message_window=0x{localized_message_start:03X}..0x{localized_message_end - 1:03X} '
                f'diff_bytes={len(mismatches)} sha256={sha256(current_tail)}'
            )
        if current_tail[0x116:0x121] != b'NTLDR      ':
            raise RuntimeError('Microsoft VBR NTLDR 8.3 name is not at the expected immutable offset')

        current_stage2 = bytearray(read_exact(f, (start_lba + 12) * SECTOR, SECTOR))
        if bytes(current_stage2) != nt52_stage2:
            raise RuntimeError(
                f'physical/fixture stage2 is not the expected Microsoft NT52 loader: '
                f'got={sha256(bytes(current_stage2))} want={sha256(nt52_stage2)}'
            )
        for off, expected in expected_stage2_sites.items():
            actual = bytes(current_stage2[off:off + len(expected)])
            if actual != expected:
                raise RuntimeError(
                    f'NT52 stage2 patch-site mismatch at 0x{off:03X}: got={actual.hex()} want={expected.hex()}'
                )
        if any(current_stage2[0x148:0x1FE]):
            raise RuntimeError('NT52 stage2 helper injection tail is not all zero before instrumentation')
        if current_stage2[0x1FE:0x200] != b'\x55\xAA':
            raise RuntimeError('NT52 stage2 signature is not 55AA')

        ntldr = read_fat32_short_file(f, start_lba, bytes(vbr), b'NTLDR      ')
        if len(ntldr) == 0 or len(ntldr) > 4 * 1024 * 1024:
            raise RuntimeError(f'NTLDR size outside diagnostic bounds: {len(ntldr)}')
        ntldr_crc32 = zlib.crc32(ntldr) & 0xFFFFFFFF
        runtime_crc_off = runtime.find(sentinel)
        runtime_size_off = runtime.find(size_sentinel)
        struct.pack_into('<I', runtime, runtime_crc_off, ntldr_crc32)
        struct.pack_into('<I', runtime, runtime_size_off, len(ntldr))

        original_mbr_code = bytes(mbr[:440])
        original_mbr_tail = bytes(mbr[440:512])
        original_gap = read_exact(f, SECTOR, 8 * SECTOR)
        original_bpb = bytes(vbr[:90])
        original_vbr_sig = bytes(vbr[510:512])
        original_ntldr_name = current_tail[0x116:0x121]
        original_stage2_sig = bytes(current_stage2[0x1FE:0x200])

        # Diagnostic MBR and prelude. The prelude carries an exact copy of the
        # target's original 440-byte MBR code at a fixed in-memory slot; after
        # read-only measurements it restores that code to 0000:7C00 and executes
        # it. Partition table / Disk ID / 55AA remain untouched throughout.
        prelude_end = PRELUDE_ORIGINAL_MBR_OFFSET + len(original_mbr_code)
        runtime_end = PRELUDE_RUNTIME_OFFSET + len(runtime)
        if prelude_end > PRELUDE_RUNTIME_OFFSET:
            raise RuntimeError('diagnostic prelude original MBR copy overlaps runtime slot')
        if runtime_end > len(prelude):
            raise RuntimeError('diagnostic prelude has no room for runtime copy')
        prelude[PRELUDE_ORIGINAL_MBR_OFFSET:prelude_end] = original_mbr_code
        prelude[PRELUDE_RUNTIME_OFFSET:runtime_end] = runtime
        mbr[0:440] = mbr_code
        write_exact(f, 0, mbr)
        write_exact(f, SECTOR, prelude)

        # Instrument the real Microsoft VBR: entry jumps to helper, helper executes
        # the overwritten original setup instructions and returns to 7C6B.
        instrumented_tail = bytearray(current_tail)
        instrumented_tail[0:3] = jmp16(VBR_CODE_ADDR, VBR_HELPER_ADDR)
        instrumented_tail[vbr_helper_off:vbr_helper_end] = vbr_helper
        vbr[90:510] = instrumented_tail
        write_exact(f, vbr_off, vbr)

        # Instrument the real Microsoft stage2 at four exact instruction sites.
        instrumented_stage2 = current_stage2
        instrumented_stage2[0x000:0x005] = call16(0x8000, STAGE2_HELPER_ADDR) + b'\x90\x90'
        instrumented_stage2[0x056:0x059] = call16(0x8056, STAGE2_HELPER_ADDR)
        instrumented_stage2[0x086:0x089] = call16(0x8086, STAGE2_HELPER_ADDR)
        instrumented_stage2[0x0D6:0x0D9] = call16(0x80D6, STAGE2_HELPER_ADDR)
        instrumented_stage2[stage2_helper_off:stage2_helper_end] = stage2_helper
        write_exact(f, (start_lba + 12) * SECTOR, instrumented_stage2)
        f.flush()
        os.fsync(f.fileno())

        verify_mbr = read_exact(f, 0, SECTOR)
        verify_gap = read_exact(f, SECTOR, 8 * SECTOR)
        verify_vbr = read_exact(f, vbr_off, SECTOR)
        verify_stage2 = read_exact(f, (start_lba + 12) * SECTOR, SECTOR)
        if verify_mbr[440:512] != original_mbr_tail:
            raise RuntimeError('diagnostic MBR altered Disk ID / partition table / 55AA')
        if verify_gap != bytes(prelude):
            raise RuntimeError('diagnostic prelude readback mismatch')
        if verify_gap[PRELUDE_ORIGINAL_MBR_OFFSET:PRELUDE_ORIGINAL_MBR_OFFSET + 440] != original_mbr_code:
            raise RuntimeError('diagnostic prelude original-MBR copy mismatch')
        if verify_gap[PRELUDE_RUNTIME_OFFSET:PRELUDE_RUNTIME_OFFSET + SECTOR] != bytes(runtime):
            raise RuntimeError('diagnostic prelude runtime copy mismatch')
        if verify_vbr[:90] != original_bpb or verify_vbr[510:512] != original_vbr_sig:
            raise RuntimeError('instrumented VBR altered BPB or 55AA')
        if verify_vbr[90 + 0x116:90 + 0x121] != original_ntldr_name:
            raise RuntimeError('instrumented VBR altered the NTLDR 8.3 name')
        if verify_stage2[0x1FE:0x200] != original_stage2_sig:
            raise RuntimeError('instrumented stage2 altered 55AA')

    print(f'[PASS] diagnostic fixture target={args.target_raw}')
    print(f'[PASS] XPSETUP slot={args.xpsetup_slot} start={start_lba} sectors={sectors}')
    print(f'[PASS] MBR bytes 440..511 preserved SHA256={sha256(original_mbr_tail)}')
    print(f'[PASS] pre-partition LBA1..8 replaced only in local diagnostic fixture; original SHA256={sha256(original_gap)}')
    print(f'[PASS] original target MBR code captured byte-exactly for post-measurement execution SHA256={sha256(original_mbr_code)}')
    print(f'[PASS] original FAT32 NTLDR CRC32={ntldr_crc32:08X} bytes={len(ntldr)}; CRC and exact byte count patched into LBA8 diagnostic runtime')
    print(f'[PASS] Microsoft VBR BPB + NTLDR name + 55AA preserved; base SHA256={sha256(nt52_vbr_tail)}')
    print(f'[PASS] Microsoft stage2 original patch sites verified; 55AA preserved; base SHA256={sha256(nt52_stage2)}')
    print('[PASS] breadcrumbs patch exact Microsoft path: V(entry) / 2(entry) / F(root read) / N(NTLDR found) / J(before original far jump)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
