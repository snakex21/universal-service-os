/*
 * Host unit test for CSMWrap 3.1.2-usos5 patch 0006 (usos_acpi10.c: ACPI 1.0
 * view, legacy FADT and the legacy AML filter for Windows 2000).
 * Built by tools/tests/csmwrap/test_csmwrap_acpi10.py with the sources taken
 * from the patch itself. SPDX-License-Identifier: GPL-2.0-or-later
 */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "usos_acpi10.h"

#define BASE 0x7F000000u
#define SIZE 0x40000u

static uint8_t mem[SIZE];
static uint32_t next_alloc;
static int fails;

static void *map(void *ctx, uint64_t phys, uint32_t len)
{
    (void)ctx;
    if (phys < BASE || phys + len > (uint64_t)BASE + SIZE)
        return NULL;
    return mem + (phys - BASE);
}

static uint64_t alloc(void *ctx, uint32_t len)
{
    (void)ctx;
    uint32_t a = (next_alloc + 15) & ~15u;
    if (a + len > SIZE)
        return 0;
    next_alloc = a + len;
    memset(mem + a, 0, len);
    return BASE + a;
}

static int logf_(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    printf("    log: ");
    int r = vprintf(fmt, ap);
    va_end(ap);
    return r;
}

static struct usos_acpi10_ops ops = { NULL, map, alloc, logf_, false };

#define CHECK(c) do { if (!(c)) { printf("  FAIL %s:%d %s\n", __FILE__, __LINE__, #c); fails++; } } while (0)

static uint8_t *P(uint32_t phys) { return mem + (phys - BASE); }
static uint32_t r32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static void w32(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }
static void w64(uint8_t *p, uint64_t v) { memcpy(p, &v, 8); }
static uint8_t sum(const uint8_t *p, uint32_t n) { uint8_t s = 0; while (n--) s += *p++; return s; }
static void fix(uint8_t *t) { t[9] = 0; t[9] = (uint8_t)-sum(t, r32(t + 4)); }

/* Fixed layout of the fake firmware tables. */
#define RSDP 0x7F000000u
#define RSDT 0x7F000100u
#define XSDT 0x7F000200u
#define FACP 0x7F000400u
#define APIC 0x7F000600u
#define HPET 0x7F000700u
#define DSDT 0x7F000800u
#define FACS 0x7F000A00u
#define HIGH 0x100000000ull

static void hdr(uint32_t phys, const char *sig, uint32_t len)
{
    uint8_t *t = P(phys);
    memcpy(t, sig, 4);
    w32(t + 4, len);
    t[8] = 1;
    memcpy(t + 10, "USOSTS", 6);
    memcpy(t + 16, "TESTTBL ", 8);
}

static void gas(uint8_t *g, uint8_t space, uint8_t width, uint64_t addr)
{
    g[0] = space; g[1] = width; g[2] = 0; g[3] = 0;
    w64(g + 4, addr);
}

/*
 * Firmware: RSDP rev 2, XSDT (FACP, APIC, HPET, optional high entry),
 * RSDT (FACP, APIC, HPET) unless rsdt=0, FADT rev 6 with 32-bit fields set
 * unless zero32.
 */
static void setup(int with_rsdt, int zero32, int high_entry)
{
    memset(mem, 0, SIZE);
    next_alloc = 0x10000;
    hdr(DSDT, "DSDT", 36); fix(P(DSDT));
    memcpy(P(FACS), "FACS", 4); w32(P(FACS) + 4, 64);
    hdr(APIC, "APIC", 44); fix(P(APIC));
    hdr(HPET, "HPET", 56); fix(P(HPET));

    hdr(FACP, "FACP", 276);
    uint8_t *f = P(FACP);
    f[8] = 6;
    if (!zero32) {
        w32(f + 36, FACS); w32(f + 40, DSDT);
        w32(f + 56, 0x800); w32(f + 64, 0x804); w32(f + 76, 0x808); w32(f + 80, 0x820);
        f[88] = 4; f[89] = 2; f[91] = 4; f[92] = 8;
    }
    w64(f + 132, FACS); w64(f + 140, DSDT);
    gas(f + 148, 1, 32, 0x800);
    gas(f + 172, 1, 16, 0x804);
    gas(f + 208, 1, 32, 0x808);
    gas(f + 220, 1, 64, 0x820);
    fix(f);

    uint32_t nx = high_entry ? 4 : 3;
    hdr(XSDT, "XSDT", 36 + 8 * nx);
    w64(P(XSDT) + 36, FACP); w64(P(XSDT) + 44, APIC); w64(P(XSDT) + 52, HPET);
    if (high_entry) w64(P(XSDT) + 60, HIGH + 0x1000);
    fix(P(XSDT));

    if (with_rsdt) {
        hdr(RSDT, "RSDT", 48);
        w32(P(RSDT) + 36, FACP); w32(P(RSDT) + 40, APIC); w32(P(RSDT) + 44, HPET);
        fix(P(RSDT));
    }

    uint8_t *r = P(RSDP);
    memcpy(r, "RSD PTR ", 8);
    memcpy(r + 9, "USOSTS", 6);
    r[15] = 2;
    w32(r + 16, with_rsdt ? RSDT : 0);
    w32(r + 20, 36);
    w64(r + 24, XSDT);
    r[8] = (uint8_t)-sum(r, 20);
    r[32] = (uint8_t)-sum(r, 36);
}

static uint8_t rsdp_copy[36];

static uint32_t run(void)
{
    memcpy(rsdp_copy, P(RSDP), 36);
    return usos_acpi10_fixup(&ops, rsdp_copy);
}

static int rsdp_ok(void) { return sum(rsdp_copy, 20) == 0 && sum(rsdp_copy, 36) == 0; }

static uint8_t *rsdt_of_copy(uint32_t *n)
{
    uint32_t a = r32(rsdp_copy + 16);
    uint8_t *t = map(NULL, a, 36);
    if (!t) return NULL;
    *n = (r32(t + 4) - 36) / 4;
    return t;
}

static uint8_t *facp_of_copy(void)
{
    uint32_t n = 0;
    uint8_t *t = rsdt_of_copy(&n);
    for (uint32_t i = 0; t && i < n; i++) {
        uint8_t *e = map(NULL, r32(t + 36 + 4 * i), 36);
        if (e && !memcmp(e, "FACP", 4)) return e;
    }
    return NULL;
}

static void test_valid_unchanged(void)
{
    printf("valid ACPI 1.0 view stays unchanged\n");
    setup(1, 0, 0);
    uint8_t before[SIZE / 4];
    memcpy(before, mem, sizeof(before));
    uint32_t fl = run();
    CHECK(fl == 0);
    CHECK(memcmp(rsdp_copy, P(RSDP), 36) == 0);
    CHECK(memcmp(before, mem, sizeof(before)) == 0);
    CHECK(next_alloc == 0x10000);
}

static void test_rsdt_zero(void)
{
    printf("RsdtAddress 0: RSDT built from the XSDT, high entry left out\n");
    setup(0, 0, 1);
    uint32_t fl = run();
    CHECK(fl & USOS_ACPI10_RSDT_SYNTH);
    CHECK(fl & USOS_ACPI10_RSDP_UPDATED);
    CHECK(fl & USOS_ACPI10_SKIPPED_HIGH);
    CHECK(!(fl & USOS_ACPI10_FADT_FIXED));
    CHECK(rsdp_ok());
    uint32_t n = 0;
    uint8_t *t = rsdt_of_copy(&n);
    CHECK(t && !memcmp(t, "RSDT", 4));
    CHECK(n == 3);
    CHECK(t && sum(t, r32(t + 4)) == 0);
    CHECK(t && t[8] == 1);
    CHECK(t && !memcmp(t + 10, "USOSTS", 6));
    CHECK(t && r32(t + 36) == FACP && r32(t + 40) == APIC && r32(t + 44) == HPET);
    CHECK(r32(rsdp_copy + 24) == XSDT);
    CHECK(r32(P(RSDP) + 16) == 0); /* firmware RSDP untouched */
}

static void test_rsdt_bad_checksum(void)
{
    printf("RSDT with a bad checksum: rebuilt\n");
    setup(1, 0, 0);
    P(RSDT)[9] ^= 0x55;
    uint32_t fl = run();
    CHECK(fl & USOS_ACPI10_RSDT_SYNTH);
    CHECK(r32(rsdp_copy + 16) != RSDT);
    CHECK(rsdp_ok());
}

static void test_rsdt_missing_apic(void)
{
    printf("RSDT without the APIC that the XSDT lists: rebuilt\n");
    setup(1, 0, 0);
    w32(P(RSDT) + 4, 44);
    w32(P(RSDT) + 40, HPET);
    fix(P(RSDT));
    uint32_t fl = run();
    CHECK(fl & USOS_ACPI10_RSDT_SYNTH);
    uint32_t n = 0;
    uint8_t *t = rsdt_of_copy(&n);
    CHECK(n == 3 && t && r32(t + 40) == APIC);
}

static void test_fadt_zero32(void)
{
    printf("FADT 32-bit fields 0, X_ set: FADT copy, RSDT copy\n");
    setup(1, 1, 0);
    uint8_t orig[276];
    memcpy(orig, P(FACP), 276);
    uint32_t fl = run();
    CHECK(fl & USOS_ACPI10_FADT_FIXED);
    CHECK(fl & USOS_ACPI10_RSDT_COPIED);
    CHECK(!(fl & USOS_ACPI10_RSDT_SYNTH));
    CHECK(rsdp_ok());
    CHECK(memcmp(orig, P(FACP), 276) == 0);
    uint8_t *f = facp_of_copy();
    CHECK(f && f != P(FACP));
    if (!f) return;
    CHECK(sum(f, 276) == 0);
    CHECK(r32(f + 36) == FACS && r32(f + 40) == DSDT);
    CHECK(r32(f + 56) == 0x800 && r32(f + 64) == 0x804 && r32(f + 76) == 0x808 && r32(f + 80) == 0x820);
    CHECK(r32(f + 60) == 0 && r32(f + 68) == 0 && r32(f + 72) == 0 && r32(f + 84) == 0);
    CHECK(f[88] == 4 && f[89] == 2 && f[91] == 4 && f[92] == 8);
    uint32_t n = 0;
    uint8_t *t = rsdt_of_copy(&n);
    CHECK(t && t != P(RSDT) && sum(t, r32(t + 4)) == 0);
    CHECK(sum(P(RSDT), 48) == 0 && r32(P(RSDT) + 36) == FACP); /* firmware RSDT untouched */
    CHECK(r32(rsdp_copy + 24) == XSDT && r32(P(XSDT) + 36) == FACP); /* XSDT keeps the original FADT */
}

static void test_both(void)
{
    printf("RsdtAddress 0 and FADT 32-bit fields 0\n");
    setup(0, 1, 0);
    uint32_t fl = run();
    CHECK(fl & USOS_ACPI10_RSDT_SYNTH);
    CHECK(fl & USOS_ACPI10_FADT_FIXED);
    CHECK(!(fl & USOS_ACPI10_RSDT_COPIED));
    CHECK(rsdp_ok());
    uint8_t *f = facp_of_copy();
    CHECK(f && f != P(FACP) && r32(f + 40) == DSDT && r32(f + 76) == 0x808);
    uint32_t n = 0;
    uint8_t *t = rsdt_of_copy(&n);
    CHECK(t && sum(t, r32(t + 4)) == 0);
}

static void test_high_dsdt_and_mmio(void)
{
    printf("X_DSDT above 4 GiB and a memory-space PM block stay 0\n");
    setup(1, 1, 0);
    uint8_t *f = P(FACP);
    w64(f + 140, HIGH + 0x2000);
    gas(f + 208, 0, 32, 0xFED80000ull); /* PM timer in memory space */
    fix(f);
    uint32_t fl = run();
    CHECK(fl & USOS_ACPI10_FADT_FIXED);
    uint8_t *c = facp_of_copy();
    CHECK(c && r32(c + 40) == 0 && r32(c + 76) == 0 && r32(c + 36) == FACS && r32(c + 56) == 0x800);
    CHECK(c && sum(c, 276) == 0);
}

static void test_no_xsdt(void)
{
    printf("ACPI 1.0 RSDP, RsdtAddress 0, no XSDT: unchanged\n");
    setup(0, 0, 0);
    P(RSDP)[15] = 0;
    uint32_t fl = run();
    CHECK(fl == USOS_ACPI10_NO_XSDT);
    CHECK(memcmp(rsdp_copy, P(RSDP), 36) == 0);
}

static void test_rsdp_rev0_fadt(void)
{
    printf("short ACPI 1.0 FADT (116 bytes): nothing to fill\n");
    setup(1, 0, 0);
    uint8_t *f = P(FACP);
    w32(f + 4, 116);
    w32(f + 40, 0);
    fix(f);
    uint32_t fl = run();
    CHECK(fl == 0);
}

static void test_legacy_fadt_valid_view(void)
{
    printf("acpi_legacy_fadt, valid 1.0 view: RSDT FACP cut to revision 1 / 116 bytes, XSDT keeps v6\n");
    setup(1, 0, 0);
    uint8_t orig[276];
    memcpy(orig, P(FACP), 276);
    ops.legacy_fadt = true;
    uint32_t fl = run();
    ops.legacy_fadt = false;
    CHECK(fl & USOS_ACPI10_FADT_LEGACY);
    CHECK(fl & USOS_ACPI10_FADT_FIXED);
    CHECK(fl & USOS_ACPI10_RSDT_COPIED);
    CHECK(rsdp_ok());
    CHECK(memcmp(orig, P(FACP), 276) == 0);
    uint8_t *f = facp_of_copy();
    CHECK(f && f != P(FACP));
    if (!f) return;
    CHECK(r32(f + 4) == 116 && f[8] == 1);
    CHECK(sum(f, 116) == 0);
    CHECK(r32(f + 36) == FACS && r32(f + 40) == DSDT && r32(f + 76) == 0x808 && f[91] == 4);
    CHECK(r32(rsdp_copy + 24) == XSDT && r32(P(XSDT) + 36) == FACP && P(FACP)[8] == 6);
}

static void test_legacy_fadt_with_zero32(void)
{
    printf("acpi_legacy_fadt, RsdtAddress 0 and 32-bit fields 0\n");
    setup(0, 1, 0);
    ops.legacy_fadt = true;
    uint32_t fl = run();
    ops.legacy_fadt = false;
    CHECK(fl & USOS_ACPI10_RSDT_SYNTH);
    CHECK(fl & USOS_ACPI10_FADT_LEGACY);
    CHECK(rsdp_ok());
    uint8_t *f = facp_of_copy();
    CHECK(f && r32(f + 4) == 116 && f[8] == 1 && sum(f, 116) == 0);
    CHECK(f && r32(f + 36) == FACS && r32(f + 40) == DSDT && r32(f + 56) == 0x800 && r32(f + 64) == 0x804 && r32(f + 76) == 0x808);
}

static void test_legacy_fadt_v1_unchanged(void)
{
    printf("acpi_legacy_fadt with a complete revision 1 FADT: unchanged\n");
    setup(1, 0, 0);
    uint8_t *f = P(FACP);
    w32(f + 4, 116);
    f[8] = 1;
    fix(f);
    ops.legacy_fadt = true;
    uint32_t fl = run();
    ops.legacy_fadt = false;
    CHECK(fl == 0);
}

/* AML: Name(_CRS, Buffer(n){template}) with the given template. */
static uint32_t aml_name_buffer(uint8_t *a, const char *name, const uint8_t *tpl, uint32_t n)
{
    uint32_t i = 0;
    a[i++] = 0x08; memcpy(a + i, name, 4); i += 4;
    a[i++] = 0x11;
    uint32_t body = 2 + n;                 /* BytePrefix size + ByteList */
    uint32_t plen = body + 2;              /* 2-byte PkgLength */
    a[i++] = (uint8_t)(0x40 | (plen & 0x0F));
    a[i++] = (uint8_t)(plen >> 4);
    a[i++] = 0x0A; a[i++] = (uint8_t)n;
    memcpy(a + i, tpl, n); i += n;
    return i;
}

static uint32_t qword(uint8_t *d, uint64_t min, uint64_t max, uint64_t len)
{
    memset(d, 0, 46);
    d[0] = 0x8A; d[1] = 43; d[2] = 0; d[3] = 0; d[4] = 0x0C; d[5] = 0x03;
    w64(d + 14, min); w64(d + 22, max); w64(d + 38, len);
    return 46;
}

static uint32_t dword_mem(uint8_t *d, uint32_t min, uint32_t max)
{
    memset(d, 0, 26);
    d[0] = 0x87; d[1] = 23; d[4] = 0x0C; d[5] = 0x01;
    w32(d + 10, min); w32(d + 14, max); w32(d + 22, max - min + 1);
    return 26;
}

/* PCI root _CRS like QEMU q35: DWord window, QWord window above 4 GiB, a
 * QWord window below 4 GiB, End (checksum byte ck). Returns length. */
static uint32_t q35_template(uint8_t *t, uint8_t ck)
{
    uint32_t n = 0;
    n += dword_mem(t + n, 0x40000000u, 0xDFFFFFFFu);
    n += qword(t + n, 0x100000000ull, 0x8FFFFFFFFull, 0x800000000ull);
    n += qword(t + n, 0xE0000000ull, 0xEFFFFFFFull, 0x10000000ull);
    t[n++] = 0x79; t[n++] = 0;
    if (ck) t[n - 1] = (uint8_t)-sum(t, n - 1);
    return n;
}

#define BIGDSDT 0x7F001000u
#define SSDT1 0x7F002000u

static uint32_t setup_aml(int ssdt, uint8_t ck)
{
    setup(1, 0, 0);
    uint8_t tpl[160];
    uint32_t tn = q35_template(tpl, ck);
    uint8_t *d = P(BIGDSDT);
    hdr(BIGDSDT, "DSDT", 0);
    uint32_t i = 36;
    i += aml_name_buffer(d + i, "_CRS", tpl, tn);
    /* not a template: bytes 0x8A inside a plain data buffer */
    uint8_t junk[50]; memset(junk, 0x8A, sizeof junk);
    i += aml_name_buffer(d + i, "JUNK", junk, sizeof junk);
    w32(d + 4, i); fix(d);
    uint8_t *f = P(FACP);
    w32(f + 40, BIGDSDT); w64(f + 140, BIGDSDT); fix(f);
    if (ssdt) {
        uint8_t *s = P(SSDT1);
        hdr(SSDT1, "SSDT", 0);
        uint32_t j = 36 + aml_name_buffer(s + 36, "CRS2", tpl, tn);
        w32(s + 4, j); fix(s);
        hdr(RSDT, "RSDT", 52);
        w32(P(RSDT) + 36, FACP); w32(P(RSDT) + 40, APIC); w32(P(RSDT) + 44, HPET); w32(P(RSDT) + 48, SSDT1);
        fix(P(RSDT));
    }
    return tn;
}

/* Offset of the first template (Name _CRS) in an AML table built above. */
#define TPL_OFF (36 + 10)

static void check_filtered(const uint8_t *t, uint32_t tn)
{
    const uint8_t *tpl = t + TPL_OFF;
    CHECK(tpl[0] == 0x87 && r32(tpl + 10) == 0x40000000u);           /* DWord kept */
    const uint8_t *q = tpl + 26;
    CHECK(q[0] == 0x8A && q[1] == 43 && q[4] == 0x0C);                 /* header kept */
    int zero = 1;
    for (int k = 14; k < 46; k++) if (q[k]) zero = 0;
    CHECK(zero);                                                        /* high window cleared */
    const uint8_t *q2 = q + 46;
    CHECK(r32(q2 + 14) == 0xE0000000u && r32(q2 + 38) == 0x10000000u); /* low QWord kept */
    CHECK(tpl[tn - 2] == 0x79);
    CHECK(tpl[tn - 1] == 0 || sum(tpl, tn) == 0);
}

static void test_legacy_aml_dsdt_ssdt(void)
{
    printf("acpi_legacy_fadt: DSDT/SSDT copies without QWord windows above 4 GiB\n");
    uint32_t tn = setup_aml(1, 0);
    uint32_t dlen = r32(P(BIGDSDT) + 4), slen = r32(P(SSDT1) + 4);
    uint8_t dorig[512], sorig[512];
    memcpy(dorig, P(BIGDSDT), dlen); memcpy(sorig, P(SSDT1), slen);
    ops.legacy_fadt = true;
    uint32_t fl = run();
    ops.legacy_fadt = false;
    CHECK(fl & USOS_ACPI10_AML_FILTERED);
    CHECK(fl & USOS_ACPI10_FADT_LEGACY);
    CHECK(rsdp_ok());
    CHECK(memcmp(dorig, P(BIGDSDT), dlen) == 0 && memcmp(sorig, P(SSDT1), slen) == 0); /* firmware untouched */
    uint8_t *f = facp_of_copy();
    CHECK(f && r32(f + 40) != BIGDSDT && sum(f, 116) == 0);
    uint8_t *d = f ? map(NULL, r32(f + 40), 36) : NULL;
    CHECK(d && !memcmp(d, "DSDT", 4) && r32(d + 4) == dlen && sum(d, dlen) == 0);
    if (d) {
        check_filtered(d, tn);
        CHECK(memcmp(d + TPL_OFF + tn, dorig + TPL_OFF + tn, dlen - TPL_OFF - tn) == 0); /* JUNK unchanged */
    }
    uint32_t n = 0;
    uint8_t *r = rsdt_of_copy(&n);
    CHECK(r && n == 4 && sum(r, r32(r + 4)) == 0 && r32(r + 48) != SSDT1);
    uint8_t *s = r ? map(NULL, r32(r + 48), 36) : NULL;
    CHECK(s && !memcmp(s, "SSDT", 4) && sum(s, slen) == 0);
    if (s) check_filtered(s, tn);
    CHECK(r32(P(XSDT) + 36) == FACP && r32(P(FACP) + 40) == BIGDSDT); /* XSDT view unchanged */
}

static void test_legacy_aml_checksum(void)
{
    printf("acpi_legacy_fadt: End Tag checksum in use is recomputed\n");
    uint32_t tn = setup_aml(0, 1);
    ops.legacy_fadt = true;
    uint32_t fl = run();
    ops.legacy_fadt = false;
    CHECK(fl & USOS_ACPI10_AML_FILTERED);
    uint8_t *f = facp_of_copy();
    uint8_t *d = f ? map(NULL, r32(f + 40), 36) : NULL;
    CHECK(d && d[TPL_OFF + tn - 1] != 0 && sum(d + TPL_OFF, tn) == 0);
    if (d) check_filtered(d, tn);
}

static void test_aml_untouched_without_option(void)
{
    printf("without acpi_legacy_fadt the DSDT/SSDTs stay as they are\n");
    setup_aml(1, 0);
    uint32_t fl = run();
    CHECK(fl == 0);
}

static void test_legacy_v1_fadt_with_high_window(void)
{
    printf("acpi_legacy_fadt, revision 1 FADT (QEMU pc), DSDT with a high window: DSDT copy only\n");
    setup_aml(0, 0);
    uint8_t *f = P(FACP);
    w32(f + 4, 116); f[8] = 1; fix(f);
    ops.legacy_fadt = true;
    uint32_t fl = run();
    ops.legacy_fadt = false;
    CHECK(fl & USOS_ACPI10_AML_FILTERED);
    CHECK(!(fl & USOS_ACPI10_FADT_LEGACY));
    uint8_t *c = facp_of_copy();
    CHECK(c && c != P(FACP) && r32(c + 4) == 116 && r32(c + 40) != BIGDSDT && sum(c, 116) == 0);
}

int main(void)
{
    test_valid_unchanged();
    test_rsdt_zero();
    test_rsdt_bad_checksum();
    test_rsdt_missing_apic();
    test_fadt_zero32();
    test_both();
    test_high_dsdt_and_mmio();
    test_no_xsdt();
    test_rsdp_rev0_fadt();
    test_legacy_fadt_valid_view();
    test_legacy_fadt_with_zero32();
    test_legacy_fadt_v1_unchanged();
    test_legacy_aml_dsdt_ssdt();
    test_legacy_aml_checksum();
    test_aml_untouched_without_option();
    test_legacy_v1_fadt_with_high_window();
    printf(fails ? "ACPI10-HOST-TEST FAIL (%d)\n" : "ACPI10-HOST-TEST PASS\n", fails);
    return fails ? 1 : 0;
}
