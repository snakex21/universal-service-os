/*
 * mpgpt.h - synthetic MBR view of a GPT stick for usosmpart (Windows 2000 /
 * XP x86, which cannot use GPT data disks). Part of Universal Service OS.
 *
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Plain C without any kernel or CRT dependency, so the same code is built
 * into the driver and into the host unit test
 * (tools/tests/usosmpart_gpt_harness.c).
 *
 * MpgBuild reads a stick whose MBR holds only the protective 0xEE entry,
 * checks the primary GPT (header CRC, entry-array CRC, bounds) and builds
 * the bytes 440..511 of an MBR (disk signature, four primary entries,
 * 0x55AA) that describe the GPT partitions:
 *   - Microsoft basic data (EBD0A0A2-...) with an NTFS / exFAT (0x07),
 *     FAT32 (0x0C) or FAT12/16 (0x0E) boot sector: an entry of that type,
 *     writable; GPT attribute 63 (no drive letter), 62 (hidden) or
 *     60 (read-only) set, or an unknown file system: left out;
 *   - EFI system partition: type 0xEF (2000 / XP give it no drive letter),
 *     never writable;
 *   - Microsoft reserved and every other type: left out.
 * At most four entries (ESP dropped first when there are more), sorted by
 * start. Every LBA must fit 32 bits (MBR limit, 2 TiB with 512-byte
 * sectors), else MPG_TOO_BIG. Writes are allowed only inside a writable
 * entry (MpgWriteAllowed), so the protective MBR, both GPT copies, the ESP
 * and the gaps can never be written through the disk.
 *
 * Own code from the UEFI specification (GPT header / entry layout, CRC32),
 * the MBR partition-entry format and the public SCSI block command set.
 */
#ifndef USOS_MPGPT_H
#define USOS_MPGPT_H

typedef unsigned char mpg_u8;
typedef unsigned int mpg_u32;
#ifdef _MSC_VER
typedef unsigned __int64 mpg_u64;
#else
typedef unsigned long long mpg_u64;
#endif

#define MPG_OK              0
#define MPG_NOT_PROTECTIVE  1   /* MBR is not "one 0xEE entry only" */
#define MPG_BAD             2   /* unreadable, invalid or CRC mismatch */
#define MPG_TOO_BIG         3   /* an LBA does not fit 32 bits */
#define MPG_NONE            4   /* no partition that would get a letter */

#define MPG_MAX_PARTS       4
#define MPG_MAX_CAND        8
#define MPG_MAX_ENTRIES     1024

typedef struct _MPG_PART {
    mpg_u32 start;
    mpg_u32 count;
    mpg_u8  type;      /* MBR partition type */
    mpg_u8  writable;
} MPG_PART;

typedef struct _MPG_MAP {
    mpg_u32  n;
    MPG_PART part[MPG_MAX_PARTS];
    mpg_u8   tail[72]; /* MBR bytes 440..511 */
} MPG_MAP;

/* Read one block (block size as given to MpgBuild); nonzero = success. */
typedef int (*MPG_READ_FN)(void *ctx, mpg_u32 lba, mpg_u8 *buf);

static mpg_u32 MpgLe32(const mpg_u8 *p)
{
    return (mpg_u32)p[0] | ((mpg_u32)p[1] << 8) | ((mpg_u32)p[2] << 16) | ((mpg_u32)p[3] << 24);
}

static void MpgPut32(mpg_u8 *p, mpg_u32 v)
{
    p[0] = (mpg_u8)v;
    p[1] = (mpg_u8)(v >> 8);
    p[2] = (mpg_u8)(v >> 16);
    p[3] = (mpg_u8)(v >> 24);
}

static int MpgEq(const mpg_u8 *a, const mpg_u8 *b, mpg_u32 n)
{
    mpg_u32 i;
    for (i = 0; i < n; i++)
        if (a[i] != b[i])
            return 0;
    return 1;
}

/* zlib-style CRC32 (reflected, 0xEDB88320); pass the previous result. */
static mpg_u32 MpgCrc(mpg_u32 crc, const mpg_u8 *p, mpg_u32 n)
{
    mpg_u32 i, k;
    crc = ~crc;
    for (i = 0; i < n; i++) {
        crc ^= p[i];
        for (k = 0; k < 8; k++)
            crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
    }
    return ~crc;
}

/* MBR type for the file system in a boot sector, 0 = not recognised. */
static mpg_u8 MpgFsType(const mpg_u8 *b)
{
    static const mpg_u8 ntfs[8] = { 'N', 'T', 'F', 'S', ' ', ' ', ' ', ' ' };
    static const mpg_u8 exfat[8] = { 'E', 'X', 'F', 'A', 'T', ' ', ' ', ' ' };
    static const mpg_u8 fat32[8] = { 'F', 'A', 'T', '3', '2', ' ', ' ', ' ' };
    static const mpg_u8 fat1x[4] = { 'F', 'A', 'T', '1' };
    if (b[510] != 0x55 || b[511] != 0xAA)
        return 0;
    if (MpgEq(b + 3, ntfs, 8) || MpgEq(b + 3, exfat, 8))
        return 0x07;
    if (MpgEq(b + 82, fat32, 8))
        return 0x0C;
    if (MpgEq(b + 54, fat1x, 4))
        return 0x0E;
    return 0;
}

static int MpgBuild(MPG_READ_FN rd, void *ctx, mpg_u32 lastLba, mpg_u32 bs, mpg_u8 *buf, MPG_MAP *map)
{
    /* GUIDs in their on-disk (mixed-endian) byte order */
    static const mpg_u8 basic[16] = { 0xA2, 0xA0, 0xD0, 0xEB, 0xE5, 0xB9, 0x33, 0x44,
                                      0x87, 0xC0, 0x68, 0xB6, 0xB7, 0x26, 0x99, 0xC7 };
    static const mpg_u8 esp[16] = { 0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11,
                                    0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B };
    static const mpg_u8 efipart[8] = { 'E', 'F', 'I', ' ', 'P', 'A', 'R', 'T' };
    mpg_u8 *blk = buf, *probe = buf + bs;
    MPG_PART cand[MPG_MAX_CAND], t;
    mpg_u32 nc = 0, writable = 0, prot = 0, sig, guidx, firstU, lastU, elba, ne, es, ecrc;
    mpg_u32 hsz, hcrc, perBlk, blocks, b, j, i, k, crc = 0;

    map->n = 0;
    if (bs < 512 || bs > 4096 || (bs & (bs - 1)))
        return MPG_BAD;
    if (lastLba == 0xFFFFFFFFu)         /* READ CAPACITY(10) saturated: > 2 TiB */
        return MPG_TOO_BIG;
    if (lastLba < 67)                   /* MBR + 2 x (header + 32 entry blocks) */
        return MPG_BAD;

    if (!rd(ctx, 0, blk) || blk[510] != 0x55 || blk[511] != 0xAA)
        return MPG_BAD;
    for (i = 0; i < 4; i++) {
        mpg_u8 type = blk[446 + 16 * i + 4];
        if (!type)
            continue;
        if (type != 0xEE)
            return MPG_NOT_PROTECTIVE;
        prot++;
    }
    if (prot != 1)
        return MPG_NOT_PROTECTIVE;
    sig = MpgLe32(blk + 440);

    if (!rd(ctx, 1, blk) || !MpgEq(blk, efipart, 8))
        return MPG_BAD;
    hsz = MpgLe32(blk + 12);
    if (hsz < 92 || hsz > bs)
        return MPG_BAD;
    hcrc = MpgLe32(blk + 16);
    MpgPut32(blk + 16, 0);
    if (MpgCrc(0, blk, hsz) != hcrc)
        return MPG_BAD;
    if (MpgLe32(blk + 24) != 1 || MpgLe32(blk + 28))    /* MyLBA */
        return MPG_BAD;
    if (MpgLe32(blk + 36) || MpgLe32(blk + 44) || MpgLe32(blk + 52) || MpgLe32(blk + 76))
        return MPG_TOO_BIG;
    firstU = MpgLe32(blk + 40);
    lastU = MpgLe32(blk + 48);
    elba = MpgLe32(blk + 72);
    ne = MpgLe32(blk + 80);
    es = MpgLe32(blk + 84);
    ecrc = MpgLe32(blk + 88);
    guidx = MpgLe32(blk + 56) ^ MpgLe32(blk + 60) ^ MpgLe32(blk + 64) ^ MpgLe32(blk + 68);
    if (firstU < 2 || firstU > lastU || lastU > lastLba || es < 128 || es > bs || (es & (es - 1)) ||
        !ne || ne > MPG_MAX_ENTRIES || elba < 2 || elba > lastLba)
        return MPG_BAD;
    perBlk = bs / es;
    blocks = (ne + perBlk - 1) / perBlk;
    if (blocks > lastLba - elba + 1)
        return MPG_BAD;

    for (b = 0; b < blocks; b++) {
        if (!rd(ctx, elba + b, blk))
            return MPG_BAD;
        for (j = 0; j < perBlk && b * perBlk + j < ne; j++) {
            const mpg_u8 *e = blk + j * es;
            mpg_u32 first, last, zero = 1;
            mpg_u8 type;
            crc = MpgCrc(crc, e, es);
            for (k = 0; k < 16; k++)
                if (e[k])
                    zero = 0;
            if (zero)
                continue;
            if (MpgLe32(e + 36) || MpgLe32(e + 44))
                return MPG_TOO_BIG;
            first = MpgLe32(e + 32);
            last = MpgLe32(e + 40);
            if (first < firstU || last > lastU || last < first)
                return MPG_BAD;
            if (MpgEq(e, esp, 16)) {
                type = 0xEF;
            } else if (MpgEq(e, basic, 16)) {
                /* attribute byte 7: bit 60 read-only, 62 hidden, 63 no drive letter */
                if (e[55] & 0xD0)
                    continue;
                if (!rd(ctx, first, probe))
                    continue;
                type = MpgFsType(probe);
                if (!type)
                    continue;
            } else {
                continue;               /* MSR, Linux, ... */
            }
            if (nc == MPG_MAX_CAND)
                continue;
            cand[nc].start = first;
            cand[nc].count = last - first + 1;
            cand[nc].type = type;
            cand[nc].writable = (mpg_u8)(type != 0xEF);
            nc++;
        }
    }
    if (crc != ecrc)
        return MPG_BAD;
    for (i = 0; i < nc; i++)
        for (k = i + 1; k < nc; k++)
            if (cand[i].start <= cand[k].start + (cand[k].count - 1) &&
                cand[k].start <= cand[i].start + (cand[i].count - 1))
                return MPG_BAD;
    while (nc > MPG_MAX_PARTS) {        /* drop the last ESP, else the last entry */
        mpg_u32 drop = nc - 1;
        for (i = nc; i-- > 0;)
            if (!cand[i].writable) {
                drop = i;
                break;
            }
        for (i = drop; i + 1 < nc; i++)
            cand[i] = cand[i + 1];
        nc--;
    }
    for (i = 1; i < nc; i++)            /* insertion sort by start */
        for (k = i; k > 0 && cand[k - 1].start > cand[k].start; k--) {
            t = cand[k];
            cand[k] = cand[k - 1];
            cand[k - 1] = t;
        }
    for (i = 0; i < nc; i++)
        writable += cand[i].writable;
    if (!writable)
        return MPG_NONE;

    for (i = 0; i < 72; i++)
        map->tail[i] = 0;
    if (!sig)
        sig = guidx ? guidx : 0x534F5355u;  /* 'USOS' */
    MpgPut32(map->tail, sig);
    for (i = 0; i < nc; i++) {
        mpg_u8 *e = map->tail + 6 + 16 * i;
        e[1] = 0xFE; e[2] = 0xFF; e[3] = 0xFF;  /* CHS: beyond 1024 cylinders, use LBA */
        e[4] = cand[i].type;
        e[5] = 0xFE; e[6] = 0xFF; e[7] = 0xFF;
        MpgPut32(e + 8, cand[i].start);
        MpgPut32(e + 12, cand[i].count);
        map->part[i] = cand[i];
    }
    map->tail[70] = 0x55;
    map->tail[71] = 0xAA;
    map->n = nc;
    return MPG_OK;
}

/* TRUE when [lba, lba + n) lies inside one writable entry. */
static int MpgWriteAllowed(const MPG_MAP *m, mpg_u64 lba, mpg_u32 n)
{
    mpg_u32 i;
    if (!n)
        return 0;
    for (i = 0; i < m->n; i++) {
        const MPG_PART *p = &m->part[i];
        if (p->writable && lba >= p->start && lba + n <= (mpg_u64)p->start + p->count)
            return 1;
    }
    return 0;
}

#define MPG_CDB_OTHER   0
#define MPG_CDB_READ    1   /* *lba / *n valid */
#define MPG_CDB_WRITE   2   /* *lba / *n valid */
#define MPG_CDB_WRITEX  3   /* changes the medium, no range: always refused */

static mpg_u64 MpgBe(const mpg_u8 *p, mpg_u32 n)
{
    mpg_u64 v = 0;
    mpg_u32 i;
    for (i = 0; i < n; i++)
        v = (v << 8) | p[i];
    return v;
}

/* Classify a SCSI block command and decode its LBA range. */
static int MpgCdb(const mpg_u8 *cdb, mpg_u32 len, mpg_u64 *lba, mpg_u32 *n)
{
    int kind;
    mpg_u32 need;
    if (!len)
        return MPG_CDB_OTHER;
    switch (cdb[0]) {
    case 0x08: kind = MPG_CDB_READ; need = 6; break;                /* READ(6) */
    case 0x28: kind = MPG_CDB_READ; need = 10; break;               /* READ(10) */
    case 0xA8: kind = MPG_CDB_READ; need = 12; break;               /* READ(12) */
    case 0x88: kind = MPG_CDB_READ; need = 16; break;               /* READ(16) */
    case 0x0A: kind = MPG_CDB_WRITE; need = 6; break;               /* WRITE(6) */
    case 0x2A: case 0x2E: case 0x41:                                /* WRITE(10), WRITE AND VERIFY(10), WRITE SAME(10) */
        kind = MPG_CDB_WRITE; need = 10; break;
    case 0xAA: case 0xAE: kind = MPG_CDB_WRITE; need = 12; break;   /* WRITE(12), WRITE AND VERIFY(12) */
    case 0x8A: case 0x8E: case 0x93: case 0x89:                     /* WRITE(16), W&V(16), WRITE SAME(16), COMPARE AND WRITE */
        kind = MPG_CDB_WRITE; need = 16; break;
    case 0x04: case 0x42: case 0x3B: case 0x7F:                     /* FORMAT UNIT, UNMAP, WRITE BUFFER, 32-byte CDBs */
        return MPG_CDB_WRITEX;
    default:
        return MPG_CDB_OTHER;
    }
    if (len < need)
        return kind == MPG_CDB_WRITE ? MPG_CDB_WRITEX : MPG_CDB_OTHER;
    switch (need) {
    case 6:
        *lba = MpgBe(cdb + 1, 3) & 0x1FFFFF;
        *n = cdb[4] ? cdb[4] : 256;
        break;
    case 10:
        *lba = MpgBe(cdb + 2, 4);
        *n = (mpg_u32)MpgBe(cdb + 7, 2);
        break;
    case 12:
        *lba = MpgBe(cdb + 2, 4);
        *n = (mpg_u32)MpgBe(cdb + 6, 4);
        break;
    default:
        *lba = MpgBe(cdb + 2, 8);
        *n = cdb[0] == 0x89 ? cdb[13] : (mpg_u32)MpgBe(cdb + 10, 4);
        break;
    }
    if (kind == MPG_CDB_WRITE && !*n && (cdb[0] == 0x41 || cdb[0] == 0x93))
        return MPG_CDB_WRITEX;          /* WRITE SAME, length 0 = to the end */
    return kind;
}

#endif /* USOS_MPGPT_H */
