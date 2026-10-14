/*
 * Host unit test for CSMWrap 3.1.2-usos7 patch 0008 (seabios/src/fw/usos_s5.h:
 * \_S5 SLP_TYP values from AML without an interpreter, PM1_CNT values).
 * Built by tools/tests/csmwrap/test_csmwrap_apmoff.py with the header taken
 * from the patch itself. Extra arguments: DSDT/SSDT files with the expected
 * SLP_TYPa, as path=typ (e.g. a QEMU dump =0, the X470 dump =5).
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
#include "usos_s5.h"

static int fails;
#define CHECK(c) do { if (!(c)) { printf("  FAIL %s:%d %s\n", __FILE__, __LINE__, #c); fails++; } } while (0)

/* Parse a copy in an exact-size heap buffer so an overread trips the sanitizer. */
static int parse(const u8 *aml, u32 len, u8 *a, u8 *b)
{
    u8 *copy = malloc(len ? len : 1);
    memcpy(copy, aml, len);
    *a = *b = 0xEE;
    int r = usos_s5_parse(copy, len, a, b);
    free(copy);
    return r;
}

#define EXPECT(name, bytes, ok, ta, tb) do {                                  \
    static const u8 v[] = bytes; u8 a, b;                                      \
    int r = parse(v, sizeof(v), &a, &b);                                       \
    printf("  %-34s -> %s %d/%d\n", name, r ? "found" : "none", r ? a : -1, r ? b : -1); \
    CHECK(r == (ok));                                                          \
    if (ok) { CHECK(a == (ta)); CHECK(b == (tb)); }                            \
    for (u32 n = 0; n < sizeof(v); n++) parse(v, n, &a, &b);  /* truncations */ \
} while (0)

#define B(...) { __VA_ARGS__ }

int main(int argc, char **argv)
{
    /* QEMU pc/q35 (BXPC DSDT): Name(_S5, Package(4){Zero, Zero, Zero, Zero}) */
    EXPECT("qemu pc/q35 _S5 {0,0,0,0}", B(0x10, 0x08, 0x5F, 0x53, 0x35, 0x5F, 0x12, 0x06, 0x04, 0x00, 0x00, 0x00, 0x00, 0x10), 1, 0, 0);
    /* ASRock X470 (AMI ALASKA DSDT): Package(4){0x05, Zero, Zero, Zero} */
    EXPECT("x470 _S5 {5,0,0,0}", B(0x00, 0x08, 0x5F, 0x53, 0x35, 0x5F, 0x12, 0x07, 0x04, 0x0A, 0x05, 0x00, 0x00, 0x00, 0x14, 0x42), 1, 5, 0);
    /* Intel ICH style with root prefix: Name(\_S5, Package(){7, 7, 0, 0}) */
    EXPECT("root prefix, {7,7,0,0}", B(0x08, 0x5C, 0x5F, 0x53, 0x35, 0x5F, 0x12, 0x0A, 0x04, 0x0A, 0x07, 0x0A, 0x07, 0x00, 0x00), 1, 7, 7);
    /* One packed element (ACPI 1.0 form), WordConst 0x0707 */
    EXPECT("packed word 0x0607", B(0x08, 0x5F, 0x53, 0x35, 0x5F, 0x12, 0x05, 0x01, 0x0B, 0x07, 0x06), 1, 7, 6);
    /* Two-byte PkgLength, DWordConst and One */
    EXPECT("pkglength 2 bytes, dword+one", B(0x08, 0x5F, 0x53, 0x35, 0x5F, 0x12, 0x40, 0x00, 0x02, 0x0C, 0x05, 0x00, 0x00, 0x00, 0x01), 1, 5, 1);
    /* Ones is masked to 3 bits */
    EXPECT("ones -> 7", B(0x08, 0x5F, 0x53, 0x35, 0x5F, 0x12, 0x04, 0x02, 0xFF, 0x00), 1, 7, 0);
    /* _S5 as a method or with a name element: not evaluated */
    EXPECT("method _S5", B(0x14, 0x08, 0x5F, 0x53, 0x35, 0x5F, 0x00, 0xA4, 0x0A, 0x05), 0, 0, 0);
    EXPECT("element is a name", B(0x08, 0x5F, 0x53, 0x35, 0x5F, 0x12, 0x07, 0x02, 0x53, 0x4C, 0x50, 0x35, 0x00), 0, 0, 0);
    /* a false start (not a package) before the real one */
    EXPECT("false start then real", B(0x08, 0x5F, 0x53, 0x35, 0x5F, 0x0A, 0x01, 0x08, 0x5F, 0x53, 0x35, 0x5F, 0x12, 0x07, 0x04, 0x0A, 0x05, 0x00, 0x00, 0x00), 1, 5, 0);
    /* _S4 is not _S5 */
    EXPECT("only _S4", B(0x08, 0x5F, 0x53, 0x34, 0x5F, 0x12, 0x07, 0x04, 0x0A, 0x06, 0x00, 0x00, 0x00), 0, 0, 0);
    EXPECT("empty package", B(0x08, 0x5F, 0x53, 0x35, 0x5F, 0x12, 0x02, 0x00, 0x00, 0x00), 0, 0, 0);

    /* PM1_CNT values: SLP_TYP bits 10-12, SLP_EN bit 13, others kept */
    CHECK(usos_s5_cnt(0x0000, 5, 1) == 0x3400);   /* X470 PM1a_CNT 0x804 */
    CHECK(usos_s5_cnt(0x0000, 0, 1) == 0x2000);   /* QEMU (the upstream write) */
    CHECK(usos_s5_cnt(0x0001, 5, 0) == 0x1401);   /* SCI_EN kept, SLP_EN clear */
    CHECK(usos_s5_cnt(0x3C01, 0, 0) == 0x0001);   /* old SLP_TYP/SLP_EN cleared */
    CHECK(usos_s5_cnt(0xFFFF, 7, 1) == 0xFFFF);
    CHECK(usos_s5_cnt(0x0204, 0x0D, 1) == 0x3604);/* typ masked to 3 bits */

    for (int i = 1; i < argc; i++) {
        char *eq = strrchr(argv[i], '=');
        if (!eq) { CHECK(!"argument path=typ"); continue; }
        *eq = 0;
        FILE *f = fopen(argv[i], "rb");
        if (!f) { printf("  cannot open %s\n", argv[i]); fails++; continue; }
        static u8 buf[1 << 20];
        u32 n = (u32)fread(buf, 1, sizeof(buf), f);
        fclose(f);
        u8 a = 0, b = 0;
        int r = n > 36 && parse(buf + 36, n - 36, &a, &b);
        printf("  %s -> %s %d/%d (want %s)\n", argv[i], r ? "found" : "none", a, b, eq + 1);
        CHECK(r && a == (u8)atoi(eq + 1));
    }

    if (fails) {
        printf("APMOFF-HOST-FAIL %d\n", fails);
        return 1;
    }
    printf("APMOFF-HOST-PASS\n");
    return 0;
}
