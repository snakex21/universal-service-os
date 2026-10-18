/* End-to-end host test for CSMWrap patch 0015: the real src/usos_pciirq.c and
 * uACPI (both from the patched CSMWrap tree) run on the host against a
 * firmware DSDT + FADT given on the command line, with a simulated PCI tree
 * and simulated I/O ports. Built by test_csmwrap_pciirq.py --acpi-dir with
 * the fake efi.h / printf.h / csmwrap.h / io.h it writes next to the copy of
 * usos_pciirq.c. The firmware tables are not part of the repository (a USOS
 * ACPI dump, EFI\USOS\Logs\ACPI\<machine>\, is read at run time).
 *
 * The PCI tree is the ASRock X470 Master SLI/ac one from its Linux log;
 * Interrupt Pin values are typical (see pciirq_host_test.c). I/O: AMD FCH
 * PCI_INTR index/data 0xC00/0xC01 (all routing registers 0 at start, as the
 * X470 firmware leaves them: Linux "LNKA configured for IRQ 0"), ELCR
 * 0x4D0/0x4D1; any other port write is a failure.
 *
 *   pciirq_e2e <DSDT.aml> <FACP.bin>
 */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <uacpi/kernel_api.h>
#include <uacpi/uacpi.h>
#include "usos_pciirq.h"

static int fails;
#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); fails++; } } while (0)

/* ---- simulated PCI ---- */
struct fn { uint8_t bus, dev, func, mf, bridge, sec, pin; uint8_t cfg[256]; };
static struct fn tree[] = {
    {0x00, 0x00, 0, 0, 0, 0, 0}, {0x00, 0x01, 0, 1, 0, 0, 0}, {0x00, 0x01, 3, 0, 1, 0x01, 1},
    {0x00, 0x02, 0, 0, 0, 0, 0}, {0x00, 0x03, 0, 1, 0, 0, 0}, {0x00, 0x03, 1, 0, 1, 0x0a, 1},
    {0x00, 0x04, 0, 0, 0, 0, 0}, {0x00, 0x05, 0, 0, 0, 0, 0}, {0x00, 0x07, 0, 1, 0, 0, 0},
    {0x00, 0x07, 1, 0, 1, 0x0b, 1}, {0x00, 0x08, 0, 1, 0, 0, 0}, {0x00, 0x08, 1, 0, 1, 0x0c, 1},
    {0x00, 0x14, 0, 1, 0, 0, 0}, {0x00, 0x14, 3, 0, 0, 0, 0},
    {0x00, 0x18, 0, 1, 0, 0, 0}, {0x00, 0x18, 1, 0, 0, 0, 0}, {0x00, 0x18, 7, 0, 0, 0, 0},
    {0x01, 0x00, 0, 1, 0, 0, 1}, {0x01, 0x00, 1, 0, 0, 0, 2}, {0x01, 0x00, 2, 0, 1, 0x02, 0},
    {0x02, 0x00, 0, 0, 1, 0x03, 1}, {0x02, 0x01, 0, 0, 1, 0x04, 1}, {0x02, 0x02, 0, 0, 1, 0x05, 1},
    {0x02, 0x03, 0, 0, 1, 0x06, 1}, {0x02, 0x04, 0, 0, 1, 0x07, 1}, {0x02, 0x06, 0, 0, 1, 0x08, 1},
    {0x02, 0x07, 0, 0, 1, 0x09, 1},
    {0x03, 0x00, 0, 0, 0, 0, 1},   /* Wi-Fi */
    {0x04, 0x00, 0, 0, 0, 0, 1},   /* I211 */
    {0x07, 0x00, 0, 0, 0, 0, 1},   /* Micron NVMe */
    {0x0a, 0x00, 0, 1, 0, 0, 1}, {0x0a, 0x00, 1, 0, 0, 0, 2},           /* GPU + HDMI audio */
    {0x0b, 0x00, 0, 0, 0, 0, 1},
    {0x0c, 0x00, 0, 1, 0, 0, 0}, {0x0c, 0x00, 1, 0, 0, 0, 2}, {0x0c, 0x00, 3, 0, 0, 0, 4},
    {0x0c, 0x00, 4, 0, 0, 0, 3},
};
#define NTREE (sizeof(tree) / sizeof(tree[0]))
enum { I_GPP8 = 5, I_WIFI = 27, I_I211 = 28, I_NVME = 29, I_XHC0 = 35 };

static struct fn *find(unsigned bus, unsigned dev, unsigned func)
{
    for (size_t i = 0; i < NTREE; i++)
        if (tree[i].bus == bus && tree[i].dev == dev && tree[i].func == func)
            return &tree[i];
    return NULL;
}

static void tree_init(void)
{
    for (size_t i = 0; i < NTREE; i++) {
        struct fn *f = &tree[i];
        memset(f->cfg, 0, sizeof(f->cfg));
        f->cfg[0] = 0x22; f->cfg[1] = 0x10;
        f->cfg[0x0e] = (uint8_t)((f->bridge ? 1 : 0) | (f->mf ? 0x80 : 0));
        if (f->bridge) {
            f->cfg[0x18] = f->bus;
            f->cfg[0x19] = f->sec;
            f->cfg[0x1a] = f->sec;
        }
        f->cfg[0x3d] = f->pin;
        f->cfg[0x3c] = 0xff;
    }
}

uint8_t pciConfigReadByte(unsigned bus, unsigned dev, unsigned func, unsigned off)
{
    struct fn *f = find(bus, dev, func);
    return f ? f->cfg[off & 0xff] : 0xff;
}
uint16_t pciConfigReadWord(unsigned bus, unsigned dev, unsigned func, unsigned off)
{
    return (uint16_t)(pciConfigReadByte(bus, dev, func, off) | (pciConfigReadByte(bus, dev, func, off + 1) << 8));
}
static int cfg_writes, bad_cfg_writes;
void pciConfigWriteByte(unsigned bus, unsigned dev, unsigned func, unsigned off, uint8_t v)
{
    struct fn *f = find(bus, dev, func);
    cfg_writes++;
    if (!f || off != 0x3c) {
        bad_cfg_writes++;
        return;
    }
    f->cfg[0x3c] = v;
}

/* ---- simulated ports ---- */
static uint8_t fch_idx, fch[256], elcr[2];
static int bad_io;
uint8_t inb(uint16_t port)
{
    switch (port) {
    case 0xc00: return fch_idx;
    case 0xc01: return fch[fch_idx];
    case 0x4d0: return elcr[0];
    case 0x4d1: return elcr[1];
    default: return 0xff;
    }
}
void outb(uint16_t port, uint8_t v)
{
    switch (port) {
    case 0xc00: fch_idx = v; break;
    case 0xc01: fch[fch_idx] = v; break;
    case 0x4d0: elcr[0] = v; break;
    case 0x4d1: elcr[1] = v; break;
    default: printf("unexpected out %04x %02x\n", port, v); bad_io++;
    }
}

/* ---- uACPI kernel API (host) ---- */
struct region { uint64_t phys; uint8_t *host; size_t len; };
static struct region regs[64];
static size_t nregs;
static uint64_t rsdp_phys;

static void add_region(uint64_t phys, void *host, size_t len)
{
    regs[nregs].phys = phys;
    regs[nregs].host = host;
    regs[nregs].len = len;
    nregs++;
}

void *uacpi_kernel_map(uacpi_phys_addr addr, uacpi_size len)
{
    for (size_t i = 0; i < nregs; i++)
        if (addr >= regs[i].phys && addr + len <= regs[i].phys + regs[i].len)
            return regs[i].host + (addr - regs[i].phys);
    /* anything else (SystemMemory operation regions, FACS): zeroed scratch */
    void *p = calloc(1, len + 16);
    if (nregs < 64)
        add_region(addr, p, len);
    return p;
}
void uacpi_kernel_unmap(void *p, uacpi_size len) { (void)p; (void)len; }
uacpi_status uacpi_kernel_get_rsdp(uacpi_phys_addr *out) { *out = rsdp_phys; return UACPI_STATUS_OK; }
void uacpi_kernel_log(uacpi_log_level lvl, const uacpi_char *s)
{
    if (lvl <= UACPI_LOG_WARN)
        printf("uacpi: %s", s);
}
void *uacpi_kernel_alloc(uacpi_size n) { return malloc(n ? n : 1); }
void uacpi_kernel_free(void *p) { free(p); }
uacpi_u64 uacpi_kernel_get_nanoseconds_since_boot(void) { static uacpi_u64 t; return t += 1000; }
void uacpi_kernel_stall(uacpi_u8 us) { (void)us; }
void uacpi_kernel_sleep(uacpi_u64 ms) { (void)ms; }
uacpi_handle uacpi_kernel_create_mutex(void) { return malloc(1); }
void uacpi_kernel_free_mutex(uacpi_handle h) { free(h); }
uacpi_handle uacpi_kernel_create_event(void) { return malloc(1); }
void uacpi_kernel_free_event(uacpi_handle h) { free(h); }
uacpi_thread_id uacpi_kernel_get_thread_id(void) { return (uacpi_thread_id)1; }
uacpi_status uacpi_kernel_acquire_mutex(uacpi_handle h, uacpi_u16 t) { (void)h; (void)t; return UACPI_STATUS_OK; }
void uacpi_kernel_release_mutex(uacpi_handle h) { (void)h; }
uacpi_bool uacpi_kernel_wait_for_event(uacpi_handle h, uacpi_u16 t) { (void)h; (void)t; return UACPI_TRUE; }
void uacpi_kernel_signal_event(uacpi_handle h) { (void)h; }
void uacpi_kernel_reset_event(uacpi_handle h) { (void)h; }
uacpi_status uacpi_kernel_handle_firmware_request(uacpi_firmware_request *r) { (void)r; return UACPI_STATUS_OK; }
uacpi_status uacpi_kernel_install_interrupt_handler(uacpi_u32 irq, uacpi_interrupt_handler h, uacpi_handle c, uacpi_handle *o)
{ (void)irq; (void)h; (void)c; *o = malloc(1); return UACPI_STATUS_OK; }
uacpi_status uacpi_kernel_uninstall_interrupt_handler(uacpi_interrupt_handler h, uacpi_handle i) { (void)h; free(i); return UACPI_STATUS_OK; }
uacpi_handle uacpi_kernel_create_spinlock(void) { return malloc(1); }
void uacpi_kernel_free_spinlock(uacpi_handle h) { free(h); }
uacpi_cpu_flags uacpi_kernel_lock_spinlock(uacpi_handle h) { (void)h; return 0; }
void uacpi_kernel_unlock_spinlock(uacpi_handle h, uacpi_cpu_flags f) { (void)h; (void)f; }
uacpi_status uacpi_kernel_schedule_work(uacpi_work_type t, uacpi_work_handler h, uacpi_handle c) { (void)t; (void)h; (void)c; return UACPI_STATUS_OK; }
uacpi_status uacpi_kernel_wait_for_work_completion(void) { return UACPI_STATUS_OK; }
uacpi_interrupt_state uacpi_kernel_disable_interrupts(void) { return 0; }
void uacpi_kernel_restore_interrupts(uacpi_interrupt_state s) { (void)s; }

struct pcih { unsigned bus, dev, func; };
uacpi_status uacpi_kernel_pci_device_open(uacpi_pci_address a, uacpi_handle *o)
{
    struct pcih *h = malloc(sizeof(*h));
    h->bus = a.bus; h->dev = a.device; h->func = a.function;
    *o = h;
    return UACPI_STATUS_OK;
}
void uacpi_kernel_pci_device_close(uacpi_handle h) { free(h); }
uacpi_status uacpi_kernel_pci_read8(uacpi_handle d, uacpi_size o, uacpi_u8 *v)
{ struct pcih *h = d; *v = pciConfigReadByte(h->bus, h->dev, h->func, (unsigned)o); return UACPI_STATUS_OK; }
uacpi_status uacpi_kernel_pci_read16(uacpi_handle d, uacpi_size o, uacpi_u16 *v)
{ struct pcih *h = d; *v = pciConfigReadWord(h->bus, h->dev, h->func, (unsigned)o); return UACPI_STATUS_OK; }
uacpi_status uacpi_kernel_pci_read32(uacpi_handle d, uacpi_size o, uacpi_u32 *v)
{ struct pcih *h = d; *v = pciConfigReadWord(h->bus, h->dev, h->func, (unsigned)o) | ((uacpi_u32)pciConfigReadWord(h->bus, h->dev, h->func, (unsigned)o + 2) << 16); return UACPI_STATUS_OK; }
uacpi_status uacpi_kernel_pci_write8(uacpi_handle d, uacpi_size o, uacpi_u8 v) { (void)d; (void)o; (void)v; bad_cfg_writes++; return UACPI_STATUS_OK; }
uacpi_status uacpi_kernel_pci_write16(uacpi_handle d, uacpi_size o, uacpi_u16 v) { (void)d; (void)o; (void)v; bad_cfg_writes++; return UACPI_STATUS_OK; }
uacpi_status uacpi_kernel_pci_write32(uacpi_handle d, uacpi_size o, uacpi_u32 v) { (void)d; (void)o; (void)v; bad_cfg_writes++; return UACPI_STATUS_OK; }
uacpi_status uacpi_kernel_io_map(uacpi_io_addr base, uacpi_size len, uacpi_handle *o)
{ (void)len; *o = (uacpi_handle)(uintptr_t)(base + 1); return UACPI_STATUS_OK; }
void uacpi_kernel_io_unmap(uacpi_handle h) { (void)h; }
#define PORT(h, o) ((uint16_t)((uintptr_t)(h) - 1 + (o)))
uacpi_status uacpi_kernel_io_read8(uacpi_handle h, uacpi_size o, uacpi_u8 *v) { *v = inb(PORT(h, o)); return UACPI_STATUS_OK; }
uacpi_status uacpi_kernel_io_read16(uacpi_handle h, uacpi_size o, uacpi_u16 *v) { *v = (uacpi_u16)(inb(PORT(h, o)) | (inb(PORT(h, o) + 1) << 8)); return UACPI_STATUS_OK; }
uacpi_status uacpi_kernel_io_read32(uacpi_handle h, uacpi_size o, uacpi_u32 *v) { (void)h; (void)o; *v = 0xffffffff; return UACPI_STATUS_OK; }
uacpi_status uacpi_kernel_io_write8(uacpi_handle h, uacpi_size o, uacpi_u8 v) { outb(PORT(h, o), v); return UACPI_STATUS_OK; }
uacpi_status uacpi_kernel_io_write16(uacpi_handle h, uacpi_size o, uacpi_u16 v) { outb(PORT(h, o), (uint8_t)v); outb((uint16_t)(PORT(h, o) + 1), (uint8_t)(v >> 8)); return UACPI_STATUS_OK; }
uacpi_status uacpi_kernel_io_write32(uacpi_handle h, uacpi_size o, uacpi_u32 v) { (void)h; (void)o; (void)v; bad_io++; return UACPI_STATUS_OK; }

/* ---- tables ---- */
static uint8_t *slurp(const char *path, size_t *len)
{
    FILE *f = fopen(path, "rb");
    if (!f) { printf("cannot open %s\n", path); exit(2); }
    fseek(f, 0, SEEK_END);
    *len = (size_t)ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *b = malloc(*len);
    if (fread(b, 1, *len, f) != *len) exit(2);
    fclose(f);
    return b;
}
static void csum(uint8_t *t, size_t len, size_t at)
{
    uint8_t s = 0;
    t[at] = 0;
    for (size_t i = 0; i < len; i++)
        s = (uint8_t)(s + t[i]);
    t[at] = (uint8_t)-s;
}

static uint8_t pir[64 * 16];

static void report(const char *tag)
{
    printf("[%s] FCH PIRA..H =", tag);
    for (int i = 0; i < 8; i++)
        printf(" %u", fch[i]);
    printf("  ELCR %02x%02x  I211 line %u, NVMe line %u, Wi-Fi line %u\n", elcr[1], elcr[0],
           tree[I_I211].cfg[0x3c], tree[I_NVME].cfg[0x3c], tree[I_WIFI].cfg[0x3c]);
}

static void common_checks(void)
{
    CHECK(bad_io == 0);
    CHECK(bad_cfg_writes == 0);
    /* every function with a pin got an IRQ that its link's FCH register holds */
    for (size_t i = 0; i < NTREE; i++) {
        struct fn *f = &tree[i];
        if (!f->pin || i == I_GPP8 || i == I_XHC0)
            CHECK(f->cfg[0x3c] == 0xff);   /* no pin, or on LNKE (see below) */
        else {
            uint8_t q = f->cfg[0x3c];
            CHECK(q >= 3 && q <= 15 && q != 8 && q != 13);
            CHECK(((elcr[0] | (elcr[1] << 8)) >> q) & 1);
        }
    }
    CHECK(tree[I_I211].cfg[0x3c] == fch[1]);   /* LNKB = PIRB */
    CHECK(tree[I_NVME].cfg[0x3c] == fch[0]);   /* LNKA = PIRA */
    CHECK(tree[I_WIFI].cfg[0x3c] == fch[0]);
    CHECK((elcr[0] & 0x07) == 0 && (elcr[1] & 0x21) == 0);
    size_t n = usos_pciirq_fill_pir(pir, 64);
    int seen = 0;
    for (size_t i = 0; i < n; i++)
        if (pir[i * 16] == 4 && pir[i * 16 + 1] == 0) {
            seen = 1;
            CHECK((pir[i * 16 + 3] | (pir[i * 16 + 4] << 8)) == (1u << fch[1]));
        }
    CHECK(seen);
}

int main(int argc, char **argv)
{
    if (argc != 3) {
        printf("usage: pciirq_e2e DSDT.aml FACP.bin\n");
        return 2;
    }
    size_t dlen, flen;
    uint8_t *dsdt = slurp(argv[1], &dlen);
    uint8_t *fadt = slurp(argv[2], &flen);
    CHECK(!memcmp(dsdt, "DSDT", 4) && !memcmp(fadt, "FACP", 4));
    uint64_t dsdt_phys = 0;
    memcpy(&dsdt_phys, fadt + 140, 8);
    if (!dsdt_phys)
        memcpy(&dsdt_phys, fadt + 40, 4);
    static uint8_t xsdt[36 + 8], rsdp[36];
    memcpy(xsdt, "XSDT", 4);
    uint32_t xl = sizeof(xsdt);
    memcpy(xsdt + 4, &xl, 4);
    xsdt[8] = 1;
    memcpy(xsdt + 10, "USOSTS", 6);
    uint64_t fadt_phys = 0x10003000;
    memcpy(xsdt + 36, &fadt_phys, 8);
    csum(xsdt, sizeof(xsdt), 9);
    memcpy(rsdp, "RSD PTR ", 8);
    memcpy(rsdp + 9, "USOSTS", 6);
    rsdp[15] = 2;
    uint64_t xsdt_phys = 0x10002000;
    uint32_t rl = 36;
    memcpy(rsdp + 20, &rl, 4);
    memcpy(rsdp + 24, &xsdt_phys, 8);
    csum(rsdp, 20, 8);
    csum(rsdp, 36, 32);
    rsdp_phys = 0x10001000;
    add_region(rsdp_phys, rsdp, sizeof(rsdp));
    add_region(xsdt_phys, xsdt, sizeof(xsdt));
    add_region(fadt_phys, fadt, flen);
    add_region(dsdt_phys, dsdt, dlen);

    tree_init();
    if (uacpi_initialize(UACPI_FLAG_NO_ACPI_MODE) != UACPI_STATUS_OK || uacpi_namespace_load() != UACPI_STATUS_OK) {
        printf("uACPI load failed\n");
        return 1;
    }

    /* 1: firmware left every link at 0 (X470); port writes of uACPI's own
     * init (PM1/GPE enables, CMOS by AML) do not count */
    bad_io = bad_cfg_writes = 0;
    CHECK(usos_pciirq_init());
    report("zero");
    common_checks();
    for (int i = 0; i < 8; i++)
        CHECK(fch[i] == 0 || fch[i] == 5 || fch[i] == 10 || fch[i] == 11 || (i == 4 && fch[i] == 0x1f));
    CHECK(fch[0] && fch[1] && fch[0] != fch[1]);   /* NVMe and I211 links apart */
    CHECK(fch[5] == 0);                             /* LNKF: no device in this tree */
    /* X470 LNKE._SRS stores FindSetRightBit(PIRE) - 1 instead of using its
     * argument: _CRS check fails, the link is left disabled by its _DIS
     * (0x1F) and its functions keep Interrupt Line 0xFF */
    CHECK(fch[4] == 0x1f);

    /* 2: a valid current routing is kept, an invalid one replaced */
    tree_init();
    memset(fch, 0, sizeof(fch));
    elcr[0] = elcr[1] = 0;
    fch[0] = 7;      /* in _PRS: keep */
    fch[1] = 3;      /* not in _PRS (4,5,7,10,11,14,15): reprogram */
    bad_io = bad_cfg_writes = 0;
    CHECK(usos_pciirq_init());
    report("preset");
    common_checks();
    CHECK(fch[0] == 7);
    CHECK(fch[1] == 5 || fch[1] == 10 || fch[1] == 11);
    CHECK(fch[4] == 0x1f);

    if (fails) {
        printf("%d failure(s)\n", fails);
        return 1;
    }
    printf("pciirq e2e host test PASS\n");
    return 0;
}
