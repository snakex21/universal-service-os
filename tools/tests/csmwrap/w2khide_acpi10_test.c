/*
 * Integration test for CSMWrap 3.1.2-usos11 patch 0012: usos_acpi10_fixup()
 * (patch 0006 + 0012) end to end on fake firmware tables. Built by
 * tools/tests/csmwrap/test_csmwrap_w2khide.py with usos_acpi10.c patched from
 * the shipped patch files. SPDX-License-Identifier: GPL-2.0-or-later
 */
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include "usos_acpi10.h"

#define BASE 0x7F000000u
#define SIZE 0x40000u
static uint8_t mem[SIZE];
static uint32_t next_alloc;
static int fails, fail_alloc;
#define CHECK(c) do { if (!(c)) { printf("  FAIL %s:%d %s\n", __FILE__, __LINE__, #c); fails++; } } while (0)

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
    if (fail_alloc)
        return 0;
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

static uint8_t *P(uint32_t phys) { return mem + (phys - BASE); }
static uint32_t r32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static uint64_t r64(const uint8_t *p) { uint64_t v; memcpy(&v, p, 8); return v; }
static void w32(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }
static void w64(uint8_t *p, uint64_t v) { memcpy(p, &v, 8); }
static uint8_t sum(const uint8_t *p, uint32_t n) { uint8_t s = 0; while (n--) s += *p++; return s; }
static void fix(uint8_t *t) { t[9] = 0; t[9] = (uint8_t)-sum(t, r32(t + 4)); }

#define RSDP 0x7F000000u
#define RSDT 0x7F000100u
#define XSDT 0x7F000200u
#define FACP 0x7F000400u
#define APIC 0x7F000600u
#define FACS 0x7F000700u
#define DSDT 0x7F001000u
#define SSDT 0x7F002000u

static void hdr(uint32_t phys, const char *sig, uint32_t len)
{
    uint8_t *t = P(phys);
    memcpy(t, sig, 4);
    w32(t + 4, len);
    t[8] = 2;
    memcpy(t + 10, "USOSTS", 6);
    memcpy(t + 16, "TESTTBL ", 8);
}

/* Scope(\_SB) { Device(GPIO) { Name(_HID,"AMDI0030") Name(_CID,"AMDI0030")
 *   Name(_UID, Zero) Method(_STA) { If (LLess(TSOS, 0x70)) { Return (Zero) } Return (0x0F) } } } */
static const uint8_t gpio_aml[] = {
    0x10, 0x47, 0x04, 0x5C, '_', 'S', 'B', '_',
    0x5B, 0x82, 0x3E, 'G', 'P', 'I', 'O',
    0x08, '_', 'H', 'I', 'D', 0x0D, 'A', 'M', 'D', 'I', '0', '0', '3', '0', 0x00,
    0x08, '_', 'C', 'I', 'D', 0x0D, 'A', 'M', 'D', 'I', '0', '0', '3', '0', 0x00,
    0x08, '_', 'U', 'I', 'D', 0x00,
    0x14, 0x14, '_', 'S', 'T', 'A', 0x00,
    0xA0, 0x0A, 0x95, 'T', 'S', 'O', 'S', 0x0A, 0x70, 0xA4, 0x00,
    0xA4, 0x0A, 0x0F,
};
/* Scope(\_SB) { Device(HPET) { Name(_HID, EisaId("PNP0103")) Name(_STA, 0x0F) } } */
static const uint8_t hpet_aml[] = {
    0x10, 0x1E, 0x5C, '_', 'S', 'B', '_',
    0x5B, 0x82, 0x16, 'H', 'P', 'E', 'T',
    0x08, '_', 'H', 'I', 'D', 0x0C, 0x41, 0xD0, 0x01, 0x03,
    0x08, '_', 'S', 'T', 'A', 0x0A, 0x0F,
};
/* the same GPIO device with HID AMDI0031: not ours */
static uint8_t other_aml[sizeof(gpio_aml)];

static uint32_t aml_table(uint32_t phys, const char *sig, const uint8_t *body, uint32_t n)
{
    hdr(phys, sig, 36 + n);
    memcpy(P(phys) + 36, body, n);
    fix(P(phys));
    return 36 + n;
}

static void setup(const uint8_t *dsdt_body, uint32_t dn)
{
    memset(mem, 0, SIZE);
    next_alloc = 0x10000;
    fail_alloc = 0;
    aml_table(DSDT, "DSDT", dsdt_body, dn);
    aml_table(SSDT, "SSDT", hpet_aml, sizeof(hpet_aml));
    memcpy(P(FACS), "FACS", 4); w32(P(FACS) + 4, 64);
    hdr(APIC, "APIC", 44); fix(P(APIC));
    hdr(FACP, "FACP", 276);
    uint8_t *f = P(FACP);
    f[8] = 6;
    w32(f + 36, FACS); w32(f + 40, DSDT);
    w32(f + 56, 0x800); w32(f + 64, 0x804); w32(f + 76, 0x808); w32(f + 80, 0x820);
    f[88] = 4; f[89] = 2; f[91] = 4; f[92] = 8;
    w64(f + 132, FACS); w64(f + 140, DSDT);
    fix(f);
    hdr(XSDT, "XSDT", 36 + 24);
    w64(P(XSDT) + 36, FACP); w64(P(XSDT) + 44, APIC); w64(P(XSDT) + 52, SSDT);
    fix(P(XSDT));
    hdr(RSDT, "RSDT", 36 + 12);
    w32(P(RSDT) + 36, FACP); w32(P(RSDT) + 40, APIC); w32(P(RSDT) + 44, SSDT);
    fix(P(RSDT));
    uint8_t *r = P(RSDP);
    memcpy(r, "RSD PTR ", 8);
    memcpy(r + 9, "USOSTS", 6);
    r[15] = 2;
    w32(r + 16, RSDT);
    w32(r + 20, 36);
    w64(r + 24, XSDT);
    r[8] = (uint8_t)-sum(r, 20);
    r[32] = (uint8_t)-sum(r, 36);
}

static uint8_t rsdp_copy[36], orig[0x3000];

static uint32_t run(bool legacy)
{
    memcpy(orig, mem, sizeof(orig));
    memcpy(rsdp_copy, P(RSDP), 36);
    ops.legacy_fadt = legacy;
    uint32_t fl = usos_acpi10_fixup(&ops, rsdp_copy);
    ops.legacy_fadt = false;
    return fl;
}

static uint8_t *rsdt_entry(const char *sig)
{
    uint8_t *t = map(NULL, r32(rsdp_copy + 16), 36);
    if (!t || sum(t, r32(t + 4)) != 0) return NULL;
    for (uint32_t i = 0; i < (r32(t + 4) - 36) / 4; i++) {
        uint8_t *e = map(NULL, r32(t + 36 + 4 * i), 36);
        if (e && !memcmp(e, sig, 4)) return e;
    }
    return NULL;
}

static const uint8_t *find(const uint8_t *t, const char *s)
{
    for (uint32_t i = 36; i + 4 <= r32(t + 4); i++)
        if (!memcmp(t + i, s, 4)) return t + i;
    return NULL;
}

static void test_legacy_hides(void)
{
    printf("legacy_fadt: GPIO (DSDT) and HPET (SSDT) hidden in the RSDT copies only\n");
    setup(gpio_aml, sizeof(gpio_aml));
    uint32_t fl = run(true);
    CHECK(fl & USOS_ACPI10_GPIO_HIDDEN);
    CHECK(fl & USOS_ACPI10_HPET_HIDDEN);
    CHECK(fl & USOS_ACPI10_AML_FILTERED);
    CHECK(fl & USOS_ACPI10_FADT_LEGACY);
    CHECK(!memcmp(orig, mem, sizeof(orig)));                        /* firmware tables untouched */
    uint8_t *f = rsdt_entry("FACP");
    CHECK(f && f != P(FACP) && sum(f, r32(f + 4)) == 0);
    uint8_t *d = f ? map(NULL, r32(f + 40), 36) : NULL;
    CHECK(d && d != P(DSDT) && r32(d + 4) == r32(P(DSDT) + 4) && sum(d, r32(d + 4)) == 0);
    const uint8_t *sta = d ? find(d, "_STA") : NULL;
    CHECK(sta && sta[4] == 0x00 && sta[5] == 0xA4 && sta[6] == 0x00 && sta[7] == 0xA3);
    /* every byte outside the _STA body and the checksum is the firmware's */
    if (d && sta) {
        uint32_t lo = (uint32_t)(sta + 5 - d), hi = lo + 14;
        for (uint32_t i = 0; i < r32(d + 4); i++)
            if (i != 9 && (i < lo || i >= hi)) CHECK(d[i] == P(DSDT)[i]);
    }
    uint8_t *s = rsdt_entry("SSDT");
    CHECK(s && s != P(SSDT) && sum(s, r32(s + 4)) == 0);
    const uint8_t *hs = s ? find(s, "_STA") : NULL;
    CHECK(hs && hs[4] == 0x0A && hs[5] == 0x00);
    /* XSDT view unchanged: same XSDT, its FACP the firmware's with X_DSDT */
    CHECK(r64(rsdp_copy + 24) == XSDT && r64(P(XSDT) + 36) == FACP && r64(P(FACP) + 140) == DSDT);
}

static void test_not_legacy(void)
{
    printf("without legacy_fadt: nothing hidden, view valid and unchanged\n");
    setup(gpio_aml, sizeof(gpio_aml));
    uint32_t fl = run(false);
    CHECK(!(fl & (USOS_ACPI10_GPIO_HIDDEN | USOS_ACPI10_HPET_HIDDEN | USOS_ACPI10_AML_FILTERED)));
    CHECK(r32(rsdp_copy + 16) == RSDT && rsdt_entry("SSDT") == P(SSDT));
    CHECK(!memcmp(orig, mem, sizeof(orig)));
}

static void test_no_match(void)
{
    printf("legacy_fadt, AMDI0031 in the DSDT: DSDT not copied, SSDT HPET still hidden\n");
    memcpy(other_aml, gpio_aml, sizeof(gpio_aml));
    other_aml[28] = '1'; other_aml[42] = '1';                      /* AMDI0031 in _HID and _CID */
    setup(other_aml, sizeof(other_aml));
    uint32_t fl = run(true);
    CHECK(!(fl & USOS_ACPI10_GPIO_HIDDEN) && (fl & USOS_ACPI10_HPET_HIDDEN));
    uint8_t *f = rsdt_entry("FACP");
    CHECK(f && r32(f + 40) == DSDT);
}

static void test_bad_checksum(void)
{
    printf("legacy_fadt, DSDT with a bad checksum: never rewritten\n");
    setup(gpio_aml, sizeof(gpio_aml));
    P(DSDT)[9] ^= 0x55;
    uint32_t fl = run(true);
    CHECK(!(fl & USOS_ACPI10_GPIO_HIDDEN));
    uint8_t *f = rsdt_entry("FACP");
    CHECK(f && r32(f + 40) == DSDT);
}

static void test_alloc_failure(void)
{
    printf("legacy_fadt, no memory: firmware tables untouched\n");
    setup(gpio_aml, sizeof(gpio_aml));
    fail_alloc = 1;
    uint32_t fl = run(true);
    CHECK(fl & USOS_ACPI10_ALLOC_FAILED);
    CHECK(!(fl & (USOS_ACPI10_GPIO_HIDDEN | USOS_ACPI10_HPET_HIDDEN)));
    CHECK(!memcmp(orig, mem, sizeof(orig)));
}

int main(void)
{
    test_legacy_hides();
    test_not_legacy();
    test_no_match();
    test_bad_checksum();
    test_alloc_failure();
    if (fails) {
        printf("W2KHIDE-ACPI10-TEST FAIL (%d)\n", fails);
        return 1;
    }
    printf("W2KHIDE-ACPI10-TEST PASS\n");
    return 0;
}
