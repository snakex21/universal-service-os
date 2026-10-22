/*
 * Host harness for tools/nt/usosmpart/src/mpgpt.h (synthetic MBR view of a
 * GPT stick). Built and run by tools/tests/test_usosmpart.py.
 *
 *   harness <image> <lastLba> <blockSize> [w <lba> <n>]... [c <hex cdb>]...
 *
 * Prints "rc=<n> parts=<n>", one "part <type> <start> <count> <writable>"
 * line per entry, "tail <hex of MBR bytes 440..511>", then one line per
 * query: "w <lba> <n> <allowed>" / "c <kind> <lba> <n>".
 *
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../nt/usosmpart/src/mpgpt.h"

#ifdef _WIN32
#define img_seek _fseeki64
#else
#define img_seek fseeko
#endif

typedef struct { FILE *f; mpg_u32 bs; } IMG;

static int img_read(void *ctx, mpg_u32 lba, mpg_u8 *buf)
{
    IMG *im = (IMG *)ctx;
    if (img_seek(im->f, (long long)lba * im->bs, SEEK_SET))
        return 0;
    return fread(buf, 1, im->bs, im->f) == im->bs;
}

int main(int argc, char **argv)
{
    IMG im;
    MPG_MAP map;
    mpg_u8 *buf;
    mpg_u32 last, i;
    int rc, a;
    if (argc < 4)
        return 2;
    im.f = fopen(argv[1], "rb");
    if (!im.f)
        return 2;
    last = (mpg_u32)strtoul(argv[2], NULL, 0);
    im.bs = (mpg_u32)strtoul(argv[3], NULL, 0);
    buf = (mpg_u8 *)malloc(2 * 4096);
    memset(&map, 0xCC, sizeof(map));
    rc = MpgBuild(img_read, &im, last, im.bs, buf, &map);
    printf("rc=%d parts=%u\n", rc, rc == MPG_OK ? map.n : 0);
    if (rc == MPG_OK) {
        for (i = 0; i < map.n; i++)
            printf("part %02x %u %u %u\n", map.part[i].type, map.part[i].start, map.part[i].count, map.part[i].writable);
        printf("tail ");
        for (i = 0; i < 72; i++)
            printf("%02x", map.tail[i]);
        printf("\n");
    } else {
        map.n = 0;
    }
    for (a = 4; a < argc; a++) {
        if (!strcmp(argv[a], "w") && a + 2 < argc) {
            mpg_u64 lba = strtoull(argv[a + 1], NULL, 0);
            mpg_u32 n = (mpg_u32)strtoul(argv[a + 2], NULL, 0);
            printf("w %llu %u %d\n", (unsigned long long)lba, n, MpgWriteAllowed(&map, lba, n));
            a += 2;
        } else if (!strcmp(argv[a], "c") && a + 1 < argc) {
            mpg_u8 cdb[32];
            mpg_u32 len = (mpg_u32)(strlen(argv[a + 1]) / 2), n = 0;
            mpg_u64 lba = 0;
            int kind;
            for (i = 0; i < len && i < 32; i++) {
                unsigned v;
                sscanf(argv[a + 1] + 2 * i, "%2x", &v);
                cdb[i] = (mpg_u8)v;
            }
            kind = MpgCdb(cdb, len, &lba, &n);
            printf("c %d %llu %u\n", kind, (unsigned long long)lba, n);
            a += 1;
        }
    }
    free(buf);
    fclose(im.f);
    return 0;
}
