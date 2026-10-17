/*
 * Host unit test for CSMWrap 3.1.2-usos11 patch 0012 (src/usos_w2k_hide.inc:
 * HPET / AMD GPIO hidden from Windows 2000 in the legacy DSDT/SSDT copies).
 * Built by tools/tests/csmwrap/test_csmwrap_w2khide.py with the file taken
 * from the patch itself. The AML below is hand-assembled from the ACPI 6.5
 * grammar (chapter 20), shaped like common firmware DSDTs; no firmware dump.
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "usos_w2k_hide.inc"

static int fails;
#define CHECK(c) do { if (!(c)) { printf("  FAIL %s:%d %s\n", __FILE__, __LINE__, #c); fails++; } } while (0)

/* ---- tiny AML assembler -------------------------------------------------- */
struct aml { uint8_t b[4096]; uint32_t n; };

static void put(struct aml *a, const void *p, uint32_t n) { memcpy(a->b + a->n, p, n); a->n += n; }
static void byte(struct aml *a, uint8_t v) { a->b[a->n++] = v; }
static void seg(struct aml *a, const char *s) { put(a, s, 4); }

/* PkgLength for a body of n bytes (the PkgLength counts itself). */
static void pkg(struct aml *a, uint32_t body)
{
    if (body + 1 <= 0x3F) { byte(a, (uint8_t)(body + 1)); return; }
    uint32_t v = body + 2;
    byte(a, (uint8_t)(0x40 | (v & 0x0F)));
    byte(a, (uint8_t)(v >> 4));
}

static void wrap(struct aml *out, const uint8_t *op, uint32_t opn, const struct aml *body)
{
    put(out, op, opn);
    pkg(out, body->n);
    put(out, body->b, body->n);
}

static void str(struct aml *a, const char *s) { byte(a, 0x0D); put(a, s, (uint32_t)strlen(s) + 1); }
static void dword(struct aml *a, uint32_t v) { byte(a, 0x0C); put(a, &v, 4); }
static void name_str(struct aml *a, const char *n, const char *s) { byte(a, 0x08); seg(a, n); str(a, s); }
static void name_eisa(struct aml *a, const char *n, const uint8_t e[4]) { byte(a, 0x08); seg(a, n); byte(a, 0x0C); put(a, e, 4); }
static void name_raw(struct aml *a, const char *n, const uint8_t *v, uint32_t k) { byte(a, 0x08); seg(a, n); put(a, v, k); }

/* Method(_STA, 0, NotSerialized) { If (LGreaterEqual(TSOS, 0x70)) { Return (0x0F) } Return (Zero) } */
static void sta_method_tsos(struct aml *a)
{
    struct aml m = {0}, ifb = {0};
    seg(&m, "_STA"); byte(&m, 0x00);
    /* LGreaterEqual = LNot(LLess): 0x92 0x95 TSOS 0x0A 0x70 */
    byte(&ifb, 0x92); byte(&ifb, 0x95); seg(&ifb, "TSOS"); byte(&ifb, 0x0A); byte(&ifb, 0x70);
    byte(&ifb, 0xA4); byte(&ifb, 0x0A); byte(&ifb, 0x0F);
    uint8_t ifop = 0xA0;
    wrap(&m, &ifop, 1, &ifb);
    byte(&m, 0xA4); byte(&m, 0x00);
    uint8_t op = 0x14;
    wrap(a, &op, 1, &m);
}

/* Method(_CRS) { Return (RBUF) } with a Name(RBUF, ResourceTemplate { IRQ 7 + Memory32Fixed }) */
static void crs(struct aml *a)
{
    static const uint8_t rbuf[] = {
        0x11, 0x1A, 0x0A, 0x17,
        0x89, 0x06, 0x00, 0x0D, 0x01, 0x07, 0x00, 0x00, 0x00,
        0x86, 0x09, 0x00, 0x01, 0x00, 0x15, 0xD8, 0xFE, 0x00, 0x04, 0x00, 0x00,
        0x79, 0x00,
    };
    name_raw(a, "RBUF", rbuf, sizeof(rbuf));
    struct aml m = {0};
    seg(&m, "_CRS"); byte(&m, 0x08);                        /* Serialized */
    byte(&m, 0xA4); seg(&m, "RBUF");
    uint8_t op = 0x14;
    wrap(a, &op, 1, &m);
}

static const uint8_t EISA_PNP0103[4] = { 0x41, 0xD0, 0x01, 0x03 };
static const uint8_t EISA_AMD0030[4] = { 0x05, 0xA4, 0x00, 0x30 };
static const uint8_t EISA_PNP0C02[4] = { 0x41, 0xD0, 0x0C, 0x02 };

static void device(struct aml *a, const char *n, const struct aml *body)
{
    static const uint8_t op[2] = { 0x5B, 0x82 };
    struct aml d = {0};
    seg(&d, n);
    put(&d, body->b, body->n);
    wrap(a, op, 2, &d);
}

static void scope(struct aml *a, const char *path, const struct aml *body)
{
    struct aml s = {0};
    put(&s, path, (uint32_t)strlen(path));
    put(&s, body->b, body->n);
    uint8_t op = 0x10;
    wrap(a, &op, 1, &s);
}

/* DSDT: 36-byte header + body (checksum irrelevant to the filter itself). */
static uint32_t table(uint8_t *t, const struct aml *body)
{
    memset(t, 0, 36);
    memcpy(t, "DSDT", 4);
    uint32_t len = 36 + body->n;
    memcpy(t + 4, &len, 4);
    t[8] = 2;
    memcpy(t + 36, body->b, body->n);
    return len;
}

/* ---- devices ------------------------------------------------------------- */
static void gpio_body(struct aml *b, int variant)
{
    if (variant == 0) name_str(b, "_HID", "AMDI0030");
    if (variant == 1) name_eisa(b, "_HID", EISA_AMD0030);
    if (variant == 2) name_str(b, "_HID", "AMDI0031");      /* not ours */
    if (variant == 3) name_str(b, "_HID", "AMDI0010");      /* not ours (I2C) */
    if (variant == 0 || variant == 2) name_str(b, "_CID", variant == 0 ? "AMDI0030" : "AMDI0031");
    name_raw(b, "_UID", (const uint8_t[]){ 0x00 }, 1);
    crs(b);
    sta_method_tsos(b);
}

static void hpet_body(struct aml *b, int name_sta)
{
    name_eisa(b, "_HID", EISA_PNP0103);
    name_raw(b, "_UID", (const uint8_t[]){ 0x00 }, 1);
    if (name_sta) name_raw(b, "_STA", (const uint8_t[]){ 0x0A, 0x0F }, 2);
    else sta_method_tsos(b);
    crs(b);
}

/* PCI0 is not flat (OperationRegion) -> the walker looks inside it. */
static void build_x470_like(struct aml *root, int gpio_variant, int with_hpet)
{
    struct aml sb = {0}, pci = {0}, g = {0}, h = {0};
    name_eisa(&pci, "_HID", (const uint8_t[]){ 0x41, 0xD0, 0x0A, 0x08 });   /* PNP0A08 */
    /* OperationRegion(PCFG, PCI_Config, Zero, 0x0100) */
    byte(&pci, 0x5B); byte(&pci, 0x80); seg(&pci, "PCFG"); byte(&pci, 0x02); byte(&pci, 0x00); byte(&pci, 0x0B); byte(&pci, 0x00); byte(&pci, 0x01);
    if (with_hpet) { hpet_body(&h, 0); device(&pci, "HPET", &h); }
    gpio_body(&g, gpio_variant);
    device(&sb, "PCI0", &pci);
    device(&sb, "GPIO", &g);
    /* Name(TSOS, 0x75) at the root */
    name_raw(root, "TSOS", (const uint8_t[]){ 0x0A, 0x75 }, 2);
    scope(root, "_SB_", &sb);
}

static uint8_t T[8192], U[8192];

/* The _STA method of the device named dev returns Zero (A4 00) after apply. */
static const uint8_t *find_seg(const uint8_t *t, uint32_t len, const char *s, uint32_t from)
{
    for (uint32_t i = from; i + 4 <= len; i++)
        if (!memcmp(t + i, s, 4))
            return t + i;
    return NULL;
}

static unsigned run(uint8_t *t, uint32_t len, bool apply, unsigned *kinds)
{
    *kinds = 0;
    return usos_w2k_hide(t, len, apply, kinds);
}

/* Dry run must not write; apply must hit the same devices; a second pass
 * finds nothing; only bytes inside _STA bodies change. */
static unsigned roundtrip(const char *what, const struct aml *body, unsigned want_hits, unsigned want_kinds)
{
    uint32_t len = table(T, body);
    memcpy(U, T, len);
    unsigned k1, k2, k3;
    unsigned dry = run(T, len, false, &k1);
    CHECK(!memcmp(T, U, len));
    unsigned app = run(T, len, true, &k2);
    unsigned again = run(T, len, false, &k3);
    printf("%-58s hits %u kinds %u\n", what, dry, k1);
    CHECK(dry == want_hits && k1 == want_kinds);
    CHECK(app == dry && k2 == k1);
    CHECK(again == 0 && k3 == 0);
    CHECK(len == 36 + body->n);
    if (!dry) CHECK(!memcmp(T, U, len));
    return dry;
}

static void test_x470_gpio_method(void)
{
    struct aml r = {0};
    build_x470_like(&r, 0, 0);
    roundtrip("AMDI0030 _HID + _CID, method _STA (X470 shape)", &r, 1, W2KH_GPIO);
    const uint8_t *s = find_seg(T, 36 + r.n, "_STA", 36);
    CHECK(s && s[4] == 0x00 && s[5] == 0xA4 && s[6] == 0x00 && s[7] == 0xA3);
    /* resources and names untouched */
    CHECK(find_seg(T, 36 + r.n, "RBUF", 36) && find_seg(T, 36 + r.n, "AMDI", 36));
    const uint8_t irq[] = { 0x89, 0x06, 0x00, 0x0D, 0x01, 0x07 };
    int found = 0;
    for (uint32_t i = 36; i + sizeof(irq) <= 36 + r.n; i++) if (!memcmp(T + i, irq, sizeof(irq))) found = 1;
    CHECK(found);
}

static void test_amd0030_eisa(void)
{
    struct aml r = {0};
    build_x470_like(&r, 1, 0);
    roundtrip("AMD0030 as EISA ID integer", &r, 1, W2KH_GPIO);
}

static void test_hpet_and_gpio(void)
{
    struct aml r = {0};
    build_x470_like(&r, 0, 1);
    roundtrip("HPET (EISA PNP0103) inside non-flat PCI0 + GPIO", &r, 2, W2KH_HPET | W2KH_GPIO);
}

static void test_name_sta(void)
{
    struct aml r = {0}, h = {0}, sb = {0};
    hpet_body(&h, 1);
    device(&sb, "HPET", &h);
    scope(&r, "\\_SB_", &sb);
    roundtrip("HPET with Name(_STA, 0x0F)", &r, 1, W2KH_HPET);
    const uint8_t *s = find_seg(T, 36 + r.n, "_STA", 36);
    CHECK(s && s[4] == 0x0A && s[5] == 0x00);

    struct aml r2 = {0}, h2 = {0}, sb2 = {0};
    name_str(&h2, "_HID", "PNP0103");
    name_raw(&h2, "_STA", (const uint8_t[]){ 0x01 }, 1);
    device(&sb2, "HPET", &h2);
    scope(&r2, "\\_SB_", &sb2);
    roundtrip("HPET string _HID with Name(_STA, One)", &r2, 1, W2KH_HPET);
    s = find_seg(T, 36 + r2.n, "_STA", 36);
    CHECK(s && s[4] == 0x00);
}

static void test_cid_only(void)
{
    struct aml r = {0}, g = {0}, sb = {0};
    name_str(&g, "_HID", "VEND0001");
    name_str(&g, "_CID", "AMDI0030");
    sta_method_tsos(&g);
    device(&sb, "GPIO", &g);
    scope(&r, "\\_SB_", &sb);
    roundtrip("unknown _HID, _CID \"AMDI0030\"", &r, 1, W2KH_GPIO);

    struct aml r2 = {0}, g2 = {0}, sb2 = {0}, pk = {0};
    name_str(&g2, "_HID", "VEND0002");
    /* Name(_CID, Package(2) { EisaId("PNP0C02"), EisaId("AMD0030") }) */
    byte(&pk, 0x02);
    byte(&pk, 0x0C); put(&pk, EISA_PNP0C02, 4);
    byte(&pk, 0x0C); put(&pk, EISA_AMD0030, 4);
    byte(&g2, 0x08); seg(&g2, "_CID");
    uint8_t op = 0x12;
    wrap(&g2, &op, 1, &pk);
    sta_method_tsos(&g2);
    device(&sb2, "GPI1", &g2);
    scope(&r2, "\\_SB_", &sb2);
    roundtrip("_CID Package { PNP0C02, AMD0030 }", &r2, 1, W2KH_GPIO);
}

static void test_no_match(void)
{
    struct aml r = {0};
    build_x470_like(&r, 2, 0);
    roundtrip("AMDI0031 (not ours): unchanged", &r, 0, 0);
    struct aml r2 = {0};
    build_x470_like(&r2, 3, 0);
    roundtrip("AMDI0010 (I2C, not ours): unchanged", &r2, 0, 0);

    /* AMDI00300 / AMDI003 are not AMDI0030 */
    struct aml r3 = {0}, g = {0}, sb = {0};
    name_str(&g, "_HID", "AMDI00300");
    name_str(&g, "_CID", "AMDI003");
    sta_method_tsos(&g);
    device(&sb, "GPIO", &g);
    scope(&r3, "\\_SB_", &sb);
    roundtrip("prefix / longer IDs: unchanged", &r3, 0, 0);
}

static void test_already_zero_and_unsafe_shapes(void)
{
    struct aml r = {0}, g = {0}, sb = {0};
    name_str(&g, "_HID", "AMDI0030");
    name_raw(&g, "_STA", (const uint8_t[]){ 0x00 }, 1);
    device(&sb, "GPIO", &g);
    scope(&r, "\\_SB_", &sb);
    roundtrip("Name(_STA, Zero) already: no hit", &r, 0, 0);

    /* _HID as a method: would need AML execution -> unchanged */
    struct aml r2 = {0}, g2 = {0}, sb2 = {0}, m = {0};
    seg(&m, "_HID"); byte(&m, 0x00); byte(&m, 0xA4); str(&m, "AMDI0030");
    uint8_t op = 0x14;
    wrap(&g2, &op, 1, &m);
    sta_method_tsos(&g2);
    device(&sb2, "GPIO", &g2);
    scope(&r2, "\\_SB_", &sb2);
    roundtrip("Method(_HID): unchanged", &r2, 0, 0);

    /* two _STA: unchanged */
    struct aml r3 = {0}, g3 = {0}, sb3 = {0};
    name_str(&g3, "_HID", "AMDI0030");
    sta_method_tsos(&g3);
    name_raw(&g3, "_STA", (const uint8_t[]){ 0x0A, 0x0F }, 2);
    device(&sb3, "GPIO", &g3);
    scope(&r3, "\\_SB_", &sb3);
    roundtrip("duplicate _STA: unchanged", &r3, 0, 0);

    /* no _STA at all (always present): unchanged, nothing to edit in place */
    struct aml r4 = {0}, g4 = {0}, sb4 = {0};
    name_str(&g4, "_HID", "AMDI0030");
    crs(&g4);
    device(&sb4, "GPIO", &g4);
    scope(&r4, "\\_SB_", &sb4);
    roundtrip("no _STA: unchanged", &r4, 0, 0);

    /* _STA method with an argument: unchanged */
    struct aml r5 = {0}, g5 = {0}, sb5 = {0}, m5 = {0};
    name_str(&g5, "_HID", "AMDI0030");
    seg(&m5, "_STA"); byte(&m5, 0x01); byte(&m5, 0xA4); byte(&m5, 0x0A); byte(&m5, 0x0F);
    wrap(&g5, &op, 1, &m5);
    device(&sb5, "GPIO", &g5);
    scope(&r5, "\\_SB_", &sb5);
    roundtrip("_STA method with ArgCount 1: unchanged", &r5, 0, 0);

    /* device with an OperationRegion (not flat): unchanged */
    struct aml r6 = {0}, g6 = {0}, sb6 = {0};
    name_str(&g6, "_HID", "AMDI0030");
    byte(&g6, 0x5B); byte(&g6, 0x80); seg(&g6, "GPRG"); byte(&g6, 0x00); byte(&g6, 0x0C); dword(&g6, 0xFED81500); byte(&g6, 0x0B); byte(&g6, 0x00); byte(&g6, 0x04);
    sta_method_tsos(&g6);
    device(&sb6, "GPIO", &g6);
    scope(&r6, "\\_SB_", &sb6);
    roundtrip("non-flat device (OperationRegion inside): unchanged", &r6, 0, 0);

    /* inside an If block: not walked */
    struct aml r7 = {0}, g7 = {0}, ifb = {0}, sb7 = {0};
    gpio_body(&g7, 0);
    byte(&ifb, 0x01);
    device(&ifb, "GPIO", &g7);
    uint8_t ifop = 0xA0;
    wrap(&sb7, &ifop, 1, &ifb);
    scope(&r7, "\\_SB_", &sb7);
    roundtrip("device inside If(One): unchanged", &r7, 0, 0);
}

static void test_malformed(void)
{
    /* A good GPIO device followed by a Device whose PkgLength runs past the
     * table: the whole table counts 0 (the dry run decides; nothing hidden). */
    struct aml r = {0};
    build_x470_like(&r, 0, 0);
    byte(&r, 0x5B); byte(&r, 0x82); byte(&r, 0x7F); seg(&r, "BAD_");
    uint32_t len = table(T, &r);
    memcpy(U, T, len);
    unsigned k;
    CHECK(run(T, len, false, &k) == 0 && k == 0);
    CHECK(!memcmp(T, U, len));
    printf("%-58s hits 0\n", "good device + Device PkgLength past the end");

    /* Reserved PkgLength bits set in a Scope: 0 */
    struct aml r2 = {0};
    byte(&r2, 0x10); byte(&r2, 0x70); byte(&r2, 0x00);
    len = table(T, &r2);
    CHECK(run(T, len, false, &k) == 0);
    printf("%-58s hits 0\n", "Scope PkgLength with reserved bits");

    /* Too short for a header */
    CHECK(run(T, 20, false, &k) == 0);
}

/* Every truncation and many random corruptions of the X470-like table:
 * no out-of-range access (UBSan + exact-size heap copies), dry run never
 * writes, apply matches the dry run, a second pass finds nothing. */
static void test_fuzz(void)
{
    struct aml r = {0};
    build_x470_like(&r, 0, 1);
    uint32_t full = table(T, &r);
    unsigned bad = 0;
    for (uint32_t cut = 0; cut <= full; cut++) {
        uint8_t *a = malloc(cut ? cut : 1), *b = malloc(cut ? cut : 1);
        memcpy(a, T, cut); memcpy(b, T, cut);
        unsigned k1, k2, k3;
        unsigned d = run(a, cut, false, &k1);
        if (memcmp(a, b, cut)) bad++;
        unsigned p = run(a, cut, true, &k2);
        if (p != d || k1 != k2 || run(a, cut, false, &k3) != 0) bad++;
        free(a); free(b);
    }
    srand(12345);
    for (int it = 0; it < 20000; it++) {
        uint32_t n = full;
        uint8_t *a = malloc(n), *b = malloc(n);
        memcpy(a, T, n);
        int flips = 1 + rand() % 4;
        for (int f = 0; f < flips; f++) a[36 + (uint32_t)rand() % (n - 36)] = (uint8_t)rand();
        memcpy(b, a, n);
        unsigned k1, k2, k3;
        unsigned d = run(a, n, false, &k1);
        if (memcmp(a, b, n)) bad++;
        unsigned p = run(a, n, true, &k2);
        if (p != d || k1 != k2 || run(a, n, false, &k3) != 0) bad++;
        free(a); free(b);
    }
    printf("%-58s %u inconsistencies\n", "truncations + 20000 random corruptions", bad);
    CHECK(bad == 0);
}

static void test_eisa(void)
{
    CHECK(w2kh_eisa("PNP0103") == 0x0301D041u);
    CHECK(w2kh_eisa("AMD0030") == 0x3000A405u);
    CHECK(w2kh_eisa("AMDI0030") == 0);
    CHECK(w2kh_eisa("pnp0103") == 0);
}

int main(void)
{
    test_eisa();
    test_x470_gpio_method();
    test_amd0030_eisa();
    test_hpet_and_gpio();
    test_name_sta();
    test_cid_only();
    test_no_match();
    test_already_zero_and_unsafe_shapes();
    test_malformed();
    test_fuzz();
    if (fails) {
        printf("W2KHIDE-HOST-TEST FAIL (%d)\n", fails);
        return 1;
    }
    printf("W2KHIDE-HOST-TEST PASS\n");
    return 0;
}
