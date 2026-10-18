/* Host test for CSMWrap patch 0015 (src/usos_pciirq_core.inc).
 * Built by test_csmwrap_pciirq.py with -include of the .inc taken out of
 * the patch. The X470 case uses the PIC-mode _PRT packages of the ASRock
 * X470 Master SLI/ac DSDT (PD00 / PD03 / PD09 / PD13 / PD14, LNKA..LNKH,
 * _PRS = IRQ 4,5,7,10,11,14,15) and the PCI tree from the Linux log of the
 * same board; Interrupt Pin values are typical (A for single-function
 * endpoints and root ports) - the test checks the mechanism, not the board.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fails;
#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); fails++; } } while (0)

enum { A, B, C, D, E, F, G, H };
static const uint16_t X470_PRS = (1u << 4) | (1u << 5) | (1u << 7) | (1u << 10) | (1u << 11) | (1u << 14) | (1u << 15);

static int add_bus(struct pciirq_state *s, uint8_t bus, int parent, uint8_t bdev)
{
    struct pciirq_bus *b = &s->buses[s->nbuses];
    memset(b, 0, sizeof(*b));
    b->bus = bus;
    b->parent = (int16_t)parent;
    b->bridge_dev = bdev;
    b->prt_first = (uint16_t)s->nprt;
    return (int)s->nbuses++;
}

static void prt(struct pciirq_state *s, int bi, uint8_t dev, uint8_t pin, int link, uint32_t gsi)
{
    struct pciirq_prt *e = &s->prt[s->nprt++];
    e->dev = dev;
    e->pin = pin;
    e->link = (int16_t)link;
    e->gsi = gsi;
    s->buses[bi].has_prt = true;
    s->buses[bi].prt_count++;
}

/* 4 rows 0xFFFF for links l0..l3 */
static void prt4(struct pciirq_state *s, int bi, int l0, int l1, int l2, int l3)
{
    prt(s, bi, 0, 0, l0, 0);
    prt(s, bi, 0, 1, l1, 0);
    prt(s, bi, 0, 2, l2, 0);
    prt(s, bi, 0, 3, l3, 0);
}

static int fn(struct pciirq_state *s, int bi, uint8_t dev, uint8_t func, uint8_t pin)
{
    struct pciirq_func *f = &s->funcs[s->nfuncs];
    f->bus_idx = (int16_t)bi;
    f->dev = dev;
    f->func = func;
    f->pin = pin;
    f->route = PCIIRQ_NONE;
    return (int)s->nfuncs++;
}

static void links(struct pciirq_state *s, int n, uint16_t prs)
{
    s->nlinks = (size_t)n;
    for (int i = 0; i < n; i++) {
        memset(&s->links[i], 0, sizeof(s->links[i]));
        s->links[i].prs = prs;
        s->links[i].settable = true;
    }
}

static uint8_t irq_of(struct pciirq_state *s, int f)
{
    return pciirq_func_irq(s, s->funcs[f].route);
}

/* simulate the glue: _SRS succeeds */
static void apply(struct pciirq_state *s)
{
    uint8_t want[PCIIRQ_MAX_LINKS];
    pciirq_resolve_all(s);
    pciirq_choose(s, want);
    for (size_t l = 0; l < s->nlinks; l++)
        if (want[l])
            s->links[l].irq = want[l];
}

static void test_x470(void)
{
    static struct pciirq_state s;
    memset(&s, 0, sizeof(s));
    links(&s, 8, X470_PRS);
    int b0 = add_bus(&s, 0x00, -1, 0);
    /* PD00 */
    prt(&s, b0, 1, 0, A, 0); prt(&s, b0, 1, 1, B, 0); prt(&s, b0, 1, 2, C, 0); prt(&s, b0, 1, 3, D, 0);
    prt(&s, b0, 2, 0, D, 0);
    prt(&s, b0, 3, 0, E, 0); prt(&s, b0, 3, 1, F, 0); prt(&s, b0, 3, 2, G, 0); prt(&s, b0, 3, 3, H, 0);
    prt(&s, b0, 4, 0, H, 0); prt(&s, b0, 5, 0, A, 0); prt(&s, b0, 7, 0, C, 0);
    prt(&s, b0, 8, 0, D, 0); prt(&s, b0, 8, 1, C, 0); prt(&s, b0, 8, 2, D, 0);
    prt(&s, b0, 0x14, 0, A, 0); prt(&s, b0, 0x14, 1, B, 0); prt(&s, b0, 0x14, 2, C, 0); prt(&s, b0, 0x14, 3, D, 0);
    int rp13 = fn(&s, b0, 1, 3, 1), rp31 = fn(&s, b0, 3, 1, 1), rp71 = fn(&s, b0, 7, 1, 1), rp81 = fn(&s, b0, 8, 1, 1);
    int b1 = add_bus(&s, 0x01, b0, 1);              /* GPP2, PD03 */
    prt4(&s, b1, A, B, C, D);
    int xhc = fn(&s, b1, 0, 0, 1), sata = fn(&s, b1, 0, 1, 2);
    int b2 = add_bus(&s, 0x02, b1, 0);              /* Promontory switch, no _PRT */
    int b3 = add_bus(&s, 0x03, b2, 0);
    int wifi = fn(&s, b3, 0, 0, 1);
    int b4 = add_bus(&s, 0x04, b2, 1);
    int i211 = fn(&s, b4, 0, 0, 1);
    int b7 = add_bus(&s, 0x07, b2, 4);
    int nvme = fn(&s, b7, 0, 0, 1);
    int ba = add_bus(&s, 0x0a, b0, 3);              /* GPP8, PD09 */
    prt4(&s, ba, G, H, E, F);
    int gpu = fn(&s, ba, 0, 0, 1), hdmi = fn(&s, ba, 0, 1, 2);
    int bb = add_bus(&s, 0x0b, b0, 7);              /* GP12, PD13 */
    prt4(&s, bb, B, C, D, A);
    int dummy = fn(&s, bb, 0, 0, 1);
    int bc = add_bus(&s, 0x0c, b0, 8);              /* GP13, PD14 */
    prt4(&s, bc, F, G, H, E);
    int psp = fn(&s, bc, 0, 1, 2), xhc0 = fn(&s, bc, 0, 3, 4), azal = fn(&s, bc, 0, 4, 3);
    (void)rp31; (void)rp71; (void)rp81; (void)xhc0;

    apply(&s);
    CHECK(s.funcs[i211].route == B);                /* 04:00.0 INTA -> 02:01 -> 01:00 INTB -> LNKB */
    CHECK(s.funcs[nvme].route == A);                /* 07:00.0 INTA -> 02:04 -> 01:00 INTA (swizzle 4) */
    CHECK(s.funcs[wifi].route == A);
    CHECK(s.funcs[rp13].route == A);
    CHECK(s.funcs[xhc].route == A && s.funcs[sata].route == B);
    CHECK(s.funcs[gpu].route == G && s.funcs[hdmi].route == H);
    CHECK(s.funcs[dummy].route == B);
    CHECK(s.funcs[psp].route == G && s.funcs[azal].route == H);
    CHECK(s.links[A].users == 4 && s.links[B].users == 3);
    for (size_t i = 0; i < s.nfuncs; i++) {
        uint8_t q = irq_of(&s, (int)i);
        CHECK(q == 5 || q == 10 || q == 11);        /* tier 1 inside _PRS */
    }
    CHECK(irq_of(&s, i211) != irq_of(&s, nvme));     /* busiest links apart */
    CHECK(irq_of(&s, nvme) == 11 && irq_of(&s, i211) == 10);
    uint16_t lv = pciirq_level_mask(&s);
    CHECK(lv == ((1u << 5) | (1u << 10) | (1u << 11)));

    uint8_t pir[64 * 16];
    size_t n = pciirq_fill_pir(&s, pir, 64);
    /* one record per (bus, dev): 00:01 00:03 00:07 00:08 01:00 03:00 04:00 07:00 0a:00 0b:00 0c:00 */
    CHECK(n == 11);
    int found = 0;
    for (size_t i = 0; i < n; i++) {
        uint8_t *r = pir + i * 16;
        if (r[0] == 4 && r[1] == 0) {
            found = 1;
            CHECK(r[2] == 0x80 + B);                 /* INTA of the I211 */
            uint16_t bm = (uint16_t)(r[3] | (r[4] << 8));
            CHECK(bm == (1u << irq_of(&s, i211)));
            CHECK(r[5] == 0x80 + C && r[8] == 0x80 + D && r[11] == 0x80 + A);
        }
        CHECK(r[14] == 0 && r[15] == 0);
    }
    CHECK(found);
    CHECK(pciirq_fill_pir(&s, pir, 3) == 3);         /* truncation */
}

static void test_rules(void)
{
    static struct pciirq_state s;
    /* valid current IRQ kept, invalid current replaced, not settable -> unrouted */
    memset(&s, 0, sizeof(s));
    links(&s, 4, X470_PRS);
    int b0 = add_bus(&s, 0, -1, 0);
    prt(&s, b0, 1, 0, 0, 0);
    prt(&s, b0, 2, 0, 1, 0);
    prt(&s, b0, 3, 0, 2, 0);
    prt(&s, b0, 4, 0, 3, 0);
    prt(&s, b0, 5, 0, -1, 9);                       /* static GSI 9 */
    prt(&s, b0, 6, 0, -1, 2);                       /* static GSI 2: never */
    prt(&s, b0, 7, 0, -1, 23);                      /* APIC GSI: no PIC IRQ */
    s.links[0].cur = 7;                             /* in _PRS -> keep */
    s.links[1].cur = 3;                             /* not in _PRS -> reprogram */
    s.links[2].settable = false;
    s.links[3].prs = 0;                             /* nothing possible */
    int f1 = fn(&s, b0, 1, 0, 1), f2 = fn(&s, b0, 2, 0, 1), f3 = fn(&s, b0, 3, 0, 1);
    int f4 = fn(&s, b0, 4, 0, 1), f5 = fn(&s, b0, 5, 0, 1), f6 = fn(&s, b0, 6, 0, 1);
    int f7 = fn(&s, b0, 7, 0, 1), f8 = fn(&s, b0, 1, 1, 2) /* no row for INTB */, f9 = fn(&s, b0, 9, 0, 0);
    apply(&s);
    CHECK(irq_of(&s, f1) == 7);
    CHECK(irq_of(&s, f2) == 11);
    CHECK(irq_of(&s, f3) == 0);
    CHECK(irq_of(&s, f4) == 0);
    CHECK(irq_of(&s, f5) == 9);
    CHECK(irq_of(&s, f6) == 0 && irq_of(&s, f7) == 0 && irq_of(&s, f8) == 0 && irq_of(&s, f9) == 0);
    CHECK(pciirq_level_mask(&s) == ((1u << 7) | (1u << 9) | (1u << 11)));

    /* a bus with a _PRT and no row is not swizzled further */
    memset(&s, 0, sizeof(s));
    links(&s, 1, X470_PRS);
    b0 = add_bus(&s, 0, -1, 0);
    prt(&s, b0, 2, 0, 0, 0);
    int b1 = add_bus(&s, 1, b0, 2);
    prt(&s, b1, 5, 0, 0, 0);
    int g1 = fn(&s, b1, 6, 0, 1);
    int b2 = add_bus(&s, 2, b0, 2);                 /* no _PRT: INTA dev 0 -> parent dev 2 INTA */
    int g2 = fn(&s, b2, 0, 0, 1);
    int g3 = fn(&s, b2, 1, 0, 1);                   /* dev 1 INTA -> parent INTB: no row */
    apply(&s);
    CHECK(s.funcs[g1].route == PCIIRQ_NONE);
    CHECK(s.funcs[g2].route == 0);
    CHECK(s.funcs[g3].route == PCIIRQ_NONE);

    /* tier 2 only when _PRS has no tier 1 IRQ; never 0/1/2/8/13 */
    memset(&s, 0, sizeof(s));
    links(&s, 2, (1u << 3) | (1u << 14));
    s.links[1].prs = (1u << 0) | (1u << 1) | (1u << 2) | (1u << 8) | (1u << 13);
    b0 = add_bus(&s, 0, -1, 0);
    prt(&s, b0, 1, 0, 0, 0);
    prt(&s, b0, 2, 0, 1, 0);
    int h1 = fn(&s, b0, 1, 0, 1), h2 = fn(&s, b0, 2, 0, 1);
    apply(&s);
    CHECK(irq_of(&s, h1) == 3);
    CHECK(irq_of(&s, h2) == 0);
    CHECK(pciirq_level_mask(&s) == (1u << 3));

    /* unused links are not touched */
    memset(&s, 0, sizeof(s));
    links(&s, 3, X470_PRS);
    b0 = add_bus(&s, 0, -1, 0);
    prt(&s, b0, 1, 0, 2, 0);
    fn(&s, b0, 1, 0, 1);
    uint8_t want[PCIIRQ_MAX_LINKS];
    pciirq_resolve_all(&s);
    CHECK(pciirq_choose(&s, want) == 1);
    CHECK(want[0] == 0 && want[1] == 0 && want[2] == 11);

    /* parent loop guard: a corrupt parent chain ends */
    memset(&s, 0, sizeof(s));
    links(&s, 1, X470_PRS);
    b0 = add_bus(&s, 0, 0, 0);                      /* parent of itself, no _PRT */
    fn(&s, b0, 1, 0, 1);
    pciirq_resolve_all(&s);
    CHECK(s.funcs[0].route == PCIIRQ_NONE);
}

int main(void)
{
    test_x470();
    test_rules();
    if (fails) {
        printf("%d failure(s)\n", fails);
        return 1;
    }
    printf("pciirq host test PASS\n");
    return 0;
}
