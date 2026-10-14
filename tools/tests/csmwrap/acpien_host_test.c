/*
 * Host unit test for CSMWrap 3.1.2-usos6 patch 0007 (usos_acpien.c: legacy
 * to ACPI mode before the legacy boot, RTC A/B recorded around it).
 * Built by tools/tests/csmwrap/test_csmwrap_acpien.py with the sources taken
 * from the patch itself. SPDX-License-Identifier: GPL-2.0-or-later
 */
#include <stdio.h>
#include <string.h>
#include "usos_acpien.h"

static int fails;
#define CHECK(c) do { if (!(c)) { printf("  FAIL %s:%d %s\n", __FILE__, __LINE__, #c); fails++; } } while (0)

static void w16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void w32(uint8_t *p, uint32_t v) { w16(p, (uint16_t)v); w16(p + 2, (uint16_t)(v >> 16)); }
static void w64(uint8_t *p, uint64_t v) { w32(p, (uint32_t)v); w32(p + 4, (uint32_t)(v >> 32)); }
static uint8_t sum(const uint8_t *p, uint32_t n) { uint8_t s = 0; while (n--) s = (uint8_t)(s + *p++); return s; }

/* ---- fake machine ------------------------------------------------------ */
struct machine {
    uint8_t cmos_index;
    uint8_t rtc_a, rtc_b;
    uint16_t pm1a_cnt;
    uint32_t pm_tmr;         /* advances per read */
    uint32_t tmr_step;
    int smi_sets_after;      /* SCI_EN after this many PM1a_CNT reads; <0 never */
    uint8_t smi_rtc_b;       /* RTC B the SMI writes (0 = untouched) */
    int smi_count, reads_after_smi, cmos_c_reads;
    uint16_t smi_port, pm1a_port, tmr_port;
    uint8_t smi_value;
    int bad_port;
};

static uint8_t m_inb(void *ctx, uint16_t port)
{
    struct machine *m = ctx;
    if (port == 0x71) {
        uint8_t i = m->cmos_index & 0x7F;
        if (!(m->cmos_index & 0x80)) m->bad_port++;        /* NMI must stay off */
        if (i == 0x0A) return m->rtc_a;
        if (i == 0x0B) return m->rtc_b;
        if (i == 0x0C) m->cmos_c_reads++;
        return 0;
    }
    m->bad_port++;
    return 0xFF;
}

static uint16_t m_inw(void *ctx, uint16_t port)
{
    struct machine *m = ctx;
    if (port != m->pm1a_port) { m->bad_port++; return 0xFFFF; }
    if (m->smi_count) {
        m->reads_after_smi++;
        if (m->smi_sets_after >= 0 && m->reads_after_smi > m->smi_sets_after) m->pm1a_cnt |= 1;
    }
    return m->pm1a_cnt;
}

static uint32_t m_inl(void *ctx, uint16_t port)
{
    struct machine *m = ctx;
    if (port != m->tmr_port) { m->bad_port++; return 0; }
    uint32_t v = m->pm_tmr;
    m->pm_tmr += m->tmr_step;
    return v;
}

static void m_outb(void *ctx, uint16_t port, uint8_t val)
{
    struct machine *m = ctx;
    if (port == 0x70) { m->cmos_index = val; return; }
    if (port == m->smi_port) {
        m->smi_count++;
        m->smi_value = val;
        if (m->smi_rtc_b) m->rtc_b = m->smi_rtc_b;
        return;
    }
    m->bad_port++;
}

static void machine_init(struct machine *m)
{
    memset(m, 0, sizeof(*m));
    m->rtc_a = 0x26;
    m->rtc_b = 0x02;
    m->pm1a_cnt = 0x0000;
    m->tmr_step = 100;
    m->smi_sets_after = 3;
    m->smi_port = 0xB2;
    m->pm1a_port = 0x804;
    m->tmr_port = 0x808;
}

static struct usos_acpien_fadt x470(void)
{
    struct usos_acpien_fadt f = { 0xB2, 0xA0, 0x804, 0x808, true, false };
    return f;
}

static void run(struct machine *m, const struct usos_acpien_fadt *f, struct usos_acpien_result *r)
{
    struct usos_acpien_io io = { m, m_inb, m_inw, m_inl, m_outb };
    usos_acpien_run(&io, f, r);
}

/* ---- FADT parsing ------------------------------------------------------ */
static void build_fadt(uint8_t *t, uint32_t len, uint8_t rev)
{
    memset(t, 0, len);
    memcpy(t, "FACP", 4);
    w32(t + 4, len);
    t[8] = rev;
    w32(t + 48, 0xB2);
    t[52] = 0xA0;
    t[53] = 0xA1;
}

static void test_parse(void)
{
    uint8_t t[276];
    struct usos_acpien_fadt f;

    /* X470 v6 FADT: 32-bit blocks set, TMR_VAL_EXT */
    build_fadt(t, sizeof t, 6);
    w32(t + 64, 0x804);
    w32(t + 76, 0x808);
    w32(t + 112, 0x0003C5A5);
    CHECK(usos_acpien_parse_fadt(t, sizeof t, &f));
    CHECK(f.smi_cmd == 0xB2 && f.acpi_enable == 0xA0 && f.pm1a_cnt == 0x804 && f.pm_tmr == 0x808);
    CHECK(f.tmr_32bit && !f.hw_reduced);

    /* 32-bit blocks 0, X_ GAS System I/O -> taken from X_ */
    build_fadt(t, sizeof t, 6);
    t[172] = 1; w64(t + 176, 0x1804);
    t[208] = 1; w64(t + 212, 0x1808);
    w32(t + 112, 1u << 20);
    CHECK(usos_acpien_parse_fadt(t, sizeof t, &f));
    CHECK(f.pm1a_cnt == 0x1804 && f.pm_tmr == 0x1808 && !f.tmr_32bit && f.hw_reduced);

    /* X_ in memory space or above 64 KiB -> not usable */
    build_fadt(t, sizeof t, 6);
    t[172] = 0; w64(t + 176, 0x1804);
    t[208] = 1; w64(t + 212, 0x12345);
    CHECK(usos_acpien_parse_fadt(t, sizeof t, &f));
    CHECK(f.pm1a_cnt == 0 && f.pm_tmr == 0);

    /* ACPI 1.0 copy (116 bytes): X_ fields out of range, flags read */
    build_fadt(t, 116, 1);
    w32(t + 64, 0x804);
    w32(t + 76, 0x808);
    w32(t + 112, 0x100);
    CHECK(usos_acpien_parse_fadt(t, 116, &f));
    CHECK(f.pm1a_cnt == 0x804 && f.pm_tmr == 0x808 && f.tmr_32bit);

    /* SMI_CMD beyond the I/O space, short table, wrong signature */
    build_fadt(t, sizeof t, 6);
    w32(t + 48, 0x10000);
    CHECK(usos_acpien_parse_fadt(t, sizeof t, &f) && f.smi_cmd == 0);
    CHECK(usos_acpien_parse_fadt(t, 44, &f) && f.smi_cmd == 0 && f.pm1a_cnt == 0);
    memcpy(t, "APIC", 4);
    CHECK(!usos_acpien_parse_fadt(t, sizeof t, &f));
    CHECK(!usos_acpien_parse_fadt(NULL, 0, &f));
}

/* ---- FADT lookup through the RSDT ------------------------------------- */
#define BASE 0x7F000000u
static uint8_t mem[0x4000];

static void *map(void *ctx, uint64_t phys, uint32_t len)
{
    (void)ctx;
    if (phys < BASE || phys + len > BASE + sizeof mem) return NULL;
    return mem + (phys - BASE);
}

static void test_find(void)
{
    uint8_t rsdp[36];
    uint32_t len;
    memset(mem, 0, sizeof mem);
    /* RSDT at +0x100 with APIC, FACP */
    uint8_t *rsdt = mem + 0x100;
    memcpy(rsdt, "RSDT", 4);
    w32(rsdt + 4, 36 + 8);
    w32(rsdt + 36, BASE + 0x400);
    w32(rsdt + 40, BASE + 0x800);
    memcpy(mem + 0x400, "APIC", 4); w32(mem + 0x400 + 4, 44);
    memcpy(mem + 0x800, "FACP", 4); w32(mem + 0x800 + 4, 116);
    memset(rsdp, 0, sizeof rsdp);
    memcpy(rsdp, "RSD PTR ", 8);
    w32(rsdp + 16, BASE + 0x100);
    rsdp[8] = (uint8_t)-sum(rsdp, 20);
    CHECK(usos_acpien_find_fadt(map, NULL, rsdp, &len) == BASE + 0x800 && len == 116);

    /* bad RSDP checksum, RsdtAddress 0, no FACP */
    rsdp[8]++;
    CHECK(usos_acpien_find_fadt(map, NULL, rsdp, &len) == 0 && len == 0);
    rsdp[8]--;
    memcpy(mem + 0x800, "SSDT", 4);
    CHECK(usos_acpien_find_fadt(map, NULL, rsdp, &len) == 0);
    w32(rsdp + 16, 0);
    rsdp[8] = 0; rsdp[8] = (uint8_t)-sum(rsdp, 20);
    CHECK(usos_acpien_find_fadt(map, NULL, rsdp, &len) == 0);
    CHECK(usos_acpien_find_fadt(map, NULL, NULL, &len) == 0);
}

/* ---- the transition ---------------------------------------------------- */
static void test_run(void)
{
    struct machine m;
    struct usos_acpien_result r;
    struct usos_acpien_fadt f = x470();
    uint8_t b[USOS_ACPIEN_RESULT_LEN];

    /* SCI_EN 0 -> SMI -> SCI_EN 1 after 3 polls; SMI changes RTC B */
    machine_init(&m);
    m.smi_rtc_b = 0x12;
    run(&m, &f, &r);
    CHECK(r.status == 'o' && m.smi_count == 1 && m.smi_value == 0xA0);
    CHECK(r.polls == 4 && r.ticks > 0 && r.ticks < USOS_ACPIEN_TIMEOUT_TICKS);
    CHECK(r.rtc_a_before == 0x26 && r.rtc_a_after == 0x26);
    CHECK(r.rtc_b_before == 0x02 && r.rtc_b_after == 0x12);
    CHECK(r.pm1a_cnt_before == 0 && (r.pm1a_cnt_after & 1));
    usos_acpien_bytes(&r, b);
    CHECK(memcmp(b, "AEo\x26\x26\x02\x12\x01", 8) == 0);
    CHECK(m.bad_port == 0 && m.cmos_c_reads == 0);

    /* already in ACPI mode: no SMI */
    machine_init(&m);
    m.pm1a_cnt = 0x0001;
    run(&m, &f, &r);
    CHECK(r.status == 'a' && m.smi_count == 0 && r.polls == 0);
    usos_acpien_bytes(&r, b);
    CHECK(b[2] == 'a' && b[7] == 0x01);

    /* SCI_EN never comes: 3 s on a 32-bit PM timer */
    machine_init(&m);
    m.smi_sets_after = -1;
    m.tmr_step = 1000;
    run(&m, &f, &r);
    CHECK(r.status == 't' && m.smi_count == 1);
    CHECK(r.ticks >= USOS_ACPIEN_TIMEOUT_TICKS && r.ticks < USOS_ACPIEN_TIMEOUT_TICKS + 2000);
    CHECK(r.polls < USOS_ACPIEN_MAX_POLLS);

    /* 24-bit PM timer wrapping during the wait */
    machine_init(&m);
    m.smi_sets_after = -1;
    m.tmr_step = 1000;
    m.pm_tmr = 0x00FFF000u;
    f.tmr_32bit = false;
    run(&m, &f, &r);
    CHECK(r.status == 't' && r.ticks >= USOS_ACPIEN_TIMEOUT_TICKS && r.ticks < USOS_ACPIEN_TIMEOUT_TICKS + 2000);
    f = x470();

    /* stuck PM timer: poll cap */
    machine_init(&m);
    m.smi_sets_after = -1;
    m.tmr_step = 0;
    run(&m, &f, &r);
    CHECK(r.status == 't' && r.polls == USOS_ACPIEN_MAX_POLLS && r.ticks == 0);

    /* no PM timer at all: poll cap, SCI_EN still seen */
    machine_init(&m);
    f.pm_tmr = 0;
    run(&m, &f, &r);
    CHECK(r.status == 'o' && r.ticks == 0 && m.bad_port == 0);
    f = x470();

    /* unusable FADT fields: nothing sent */
    struct usos_acpien_fadt bad[3] = { x470(), x470(), x470() };
    bad[0].smi_cmd = 0;
    bad[1].acpi_enable = 0;
    bad[2].hw_reduced = true;
    for (int i = 0; i < 3; i++) {
        machine_init(&m);
        run(&m, &bad[i], &r);
        CHECK(r.status == 'n' && m.smi_count == 0);
        CHECK(r.rtc_a_before == 0x26 && r.rtc_b_after == 0x02);
    }
    machine_init(&m);
    f.pm1a_cnt = 0;
    run(&m, &f, &r);
    CHECK(r.status == 'n' && m.smi_count == 0 && r.pm1a_cnt_after == 0 && m.bad_port == 0);
}

int main(void)
{
    test_parse();
    test_find();
    test_run();
    if (fails) {
        printf("FAIL (%d)\n", fails);
        return 1;
    }
    printf("ACPIEN-HOST-PASS\n");
    return 0;
}
