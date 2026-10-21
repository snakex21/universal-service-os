/*
 * shim.c - the NT kernel / HAL routines usosusb.sys imports, for the
 * bare-metal QEMU harness (tools/tests/usosusb_hub). Test harness only:
 * nothing here ships.
 *
 * Universal Service OS (USOS)
 * Copyright (C) 2026 Maksymilian and the USOS Authors (see NOTICE)
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The harness runs in 32-bit protected mode without paging (multiboot),
 * so virtual = physical. Built without ntddk.h: the definitions carry the
 * decorated stdcall / fastcall names the driver code imports, and the
 * linker resolves the driver's __imp_ references to them (LNK4217).
 * Time comes from the TSC, calibrated against PIT channel 2; text goes to
 * COM1. Registry writes are printed as "REG <name>=<value>".
 */

typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned long u32;
typedef unsigned __int64 u64;
typedef long i32;
typedef __int64 i64;

/* ------------------------------------------------------------------ */
/* port I/O, COM1, TSC                                                 */

static u8 inb(u16 p) { u8 v; __asm { mov dx, p } __asm { in al, dx } __asm { mov v, al } return v; }
static void outb(u16 p, u8 v) { __asm { mov dx, p } __asm { mov al, v } __asm { out dx, al } }
static u32 inl(u16 p) { u32 v; __asm { mov dx, p } __asm { in eax, dx } __asm { mov v, eax } return v; }
static void outl(u16 p, u32 v) { __asm { mov dx, p } __asm { mov eax, v } __asm { out dx, eax } }
static u64 rdtsc(void) { u32 lo, hi; __asm { rdtsc } __asm { mov lo, eax } __asm { mov hi, edx } return ((u64)hi << 32) | lo; }

static u64 g_tsc_ms = 1000000;  /* TSC ticks per millisecond */
static u64 g_tsc0;

void __stdcall harness_putc(char c)
{
    int i;
    for (i = 0; i < 100000 && !(inb(0x3FD) & 0x20); i++)
        ;
    outb(0x3F8, (u8)c);
}

void __stdcall harness_puts(const char *s)
{
    while (*s) {
        if (*s == '\n')
            harness_putc('\r');
        harness_putc(*s++);
    }
}

void __stdcall harness_putw(const unsigned short *s)
{
    while (*s) {
        harness_putc(*s < 0x80 ? (char)*s : '?');
        s++;
    }
}

void __stdcall harness_puthex(u32 v)
{
    int i;
    for (i = 28; i >= 0; i -= 4)
        harness_putc("0123456789abcdef"[(v >> i) & 15]);
}

void __stdcall harness_putdec(i32 v)
{
    char t[12];
    int k = 0;
    u32 u = (u32)v;
    if (v < 0) {
        harness_putc('-');
        u = (u32)-v;
    }
    do {
        t[k++] = (char)('0' + u % 10);
        u /= 10;
    } while (u);
    while (k)
        harness_putc(t[--k]);
}

void __stdcall harness_init(void)
{
    u64 t0, t1;
    u8 g;
    outb(0x21, 0xFF);           /* both PICs masked: the NT4 build's sti stays harmless */
    outb(0xA1, 0xFF);
    outb(0x3F9, 0);             /* COM1 115200 8N1, no interrupts */
    outb(0x3FB, 0x80);
    outb(0x3F8, 1);
    outb(0x3F9, 0);
    outb(0x3FB, 3);
    outb(0x3FC, 3);
    /* TSC against PIT channel 2: 50 ms one-shot */
    g = inb(0x61);
    outb(0x61, (u8)((g & ~2) | 1));
    outb(0x43, 0xB0);
    outb(0x42, (u8)(59659 & 0xFF));
    outb(0x42, (u8)(59659 >> 8));
    t0 = rdtsc();
    while (!(inb(0x61) & 0x20))
        ;
    t1 = rdtsc();
    g_tsc_ms = (t1 - t0) / 50;
    if (!g_tsc_ms)
        g_tsc_ms = 1;
    g_tsc0 = rdtsc();
}

u32 __stdcall harness_ms(void)
{
    return (u32)((rdtsc() - g_tsc0) / g_tsc_ms);
}

static void stall_us(u64 us)
{
    u64 end = rdtsc() + us * g_tsc_ms / 1000;
    while (rdtsc() < end)
        ;
}

/* ------------------------------------------------------------------ */
/* memory: bump allocator from 16 MiB                                  */

static u32 g_heap = 0x01000000;

void *__stdcall harness_alloc(u32 n, u32 align)
{
    u32 p = (g_heap + align - 1) & ~(align - 1);
    u8 *b = (u8 *)p;
    u32 i;
    g_heap = p + n;
    for (i = 0; i < n; i++)
        b[i] = 0;
    return b;
}

void *__stdcall MmAllocateContiguousMemory(u32 n, u64 highest)
{
    (void)highest;
    return harness_alloc((n + 4095) & ~4095u, 4096);
}

u64 __stdcall MmGetPhysicalAddress(void *va) { return (u32)va; }
void *__stdcall MmMapIoSpace(u64 pa, u32 n, int cache) { (void)n; (void)cache; return (void *)(u32)pa; }
void *__stdcall MmMapLockedPagesSpecifyCache(void *mdl, int mode, int cache, void *base, u32 bug, int prio)
{
    (void)mdl; (void)mode; (void)cache; (void)base; (void)bug; (void)prio;
    return 0;
}

/* ------------------------------------------------------------------ */
/* time, threads, events                                               */

void __stdcall KeStallExecutionProcessor(u32 us) { stall_us(us); }

i32 __stdcall KeDelayExecutionThread(char mode, u8 alertable, i64 *t)
{
    (void)mode; (void)alertable;
    stall_us((u64)(*t < 0 ? -*t : *t) / 10);
    return 0;
}

void __stdcall KeQuerySystemTime(i64 *t)
{
    *t = (i64)((rdtsc() - g_tsc0) * 10000 / g_tsc_ms) + 0x01D9000000000000;
}

static u8 g_thread[64];
void *__stdcall KeGetCurrentThread(void) { return g_thread; }
i32 __stdcall KeSetPriorityThread(void *t, i32 p) { (void)t; (void)p; return 0; }

/* DISPATCHER_HEADER: Type, Absolute, Size, Inserted, SignalState (+4) */
void __stdcall KeInitializeEvent(void *e, int type, u8 state)
{
    ((u8 *)e)[0] = (u8)type;
    ((i32 *)e)[1] = state;
}

i32 __stdcall KeSetEvent(void *e, i32 inc, u8 wait)
{
    i32 old = ((i32 *)e)[1];
    (void)inc; (void)wait;
    ((i32 *)e)[1] = 1;
    return old;
}

i32 __stdcall KeWaitForSingleObject(void *o, int reason, char mode, u8 alertable, i64 *t)
{
    (void)reason; (void)mode; (void)alertable;
    if (((i32 *)o)[1]) {
        if (((u8 *)o)[0] == 1)  /* SynchronizationEvent: auto reset */
            ((i32 *)o)[1] = 0;
        return 0;
    }
    if (t)
        stall_us((u64)(*t < 0 ? -*t : *t) / 10);
    return 0x102;               /* STATUS_TIMEOUT */
}

typedef void(__stdcall *START)(void *);
START g_harness_threads[4];
int g_harness_nthreads;

i32 __stdcall PsCreateSystemThread(void **h, u32 acc, void *oa, void *proc, void *cid, START start, void *ctx)
{
    (void)acc; (void)oa; (void)proc; (void)cid; (void)ctx;
    if (g_harness_nthreads < 4)
        g_harness_threads[g_harness_nthreads++] = start;
    *h = (void *)(u32)(0x100 + g_harness_nthreads);
    return 0;
}

i32 __stdcall ZwClose(void *h) { (void)h; return 0; }

u8 __fastcall KfRaiseIrql(u8 n) { (void)n; return 0; }
void __fastcall KfLowerIrql(u8 n) { (void)n; }
u8 __fastcall KfAcquireSpinLock(u32 *l) { (void)l; return 0; }
void __fastcall KfReleaseSpinLock(u32 *l, u8 n) { (void)l; (void)n; }

/* LIST_ENTRY */
typedef struct LE { struct LE *f, *b; } LE;

LE *__fastcall ExfInterlockedInsertTailList(LE *head, LE *e, u32 *lock)
{
    LE *was = head->f == head ? 0 : head->b;
    (void)lock;
    e->f = head;
    e->b = head->b;
    head->b->f = e;
    head->b = e;
    return was;
}

LE *__fastcall ExfInterlockedRemoveHeadList(LE *head, u32 *lock)
{
    LE *e = head->f;
    (void)lock;
    if (e == head)
        return 0;
    head->f = e->f;
    e->f->b = head;
    return e;
}

/* ------------------------------------------------------------------ */
/* PCI (NT6 build: HAL; NT4 build: CF8h / CFCh port routines)          */

u32 __stdcall READ_PORT_ULONG(u32 *p) { return inl((u16)(u32)p); }
void __stdcall WRITE_PORT_ULONG(u32 *p, u32 v) { outl((u16)(u32)p, v); }

static u32 cf8(u32 bus, u32 slot, u32 off)
{
    /* PCI_SLOT_NUMBER: device 4:0, function 7:5 */
    return 0x80000000u | (bus << 16) | ((slot & 0x1F) << 11) | (((slot >> 5) & 7) << 8) | (off & 0xFC);
}

u32 __stdcall HalGetBusDataByOffset(int type, u32 bus, u32 slot, void *buf, u32 off, u32 len)
{
    (void)type;
    if (len != 4 || (off & 3))
        return 0;
    outl(0xCF8, cf8(bus, slot, off));
    *(u32 *)buf = inl(0xCFC);
    return 4;
}

u32 __stdcall HalSetBusDataByOffset(int type, u32 bus, u32 slot, void *buf, u32 off, u32 len)
{
    (void)type;
    if (len != 4 || (off & 3))
        return 0;
    outl(0xCF8, cf8(bus, slot, off));
    outl(0xCFC, *(u32 *)buf);
    return 4;
}

/* ------------------------------------------------------------------ */
/* I/O manager, object manager, registry, Rtl                         */

i32 __stdcall harness_create_device(void *drv, u32 ext, void *name, u32 type, void **out);

i32 __stdcall IoCreateDevice(void *drv, u32 ext, void *name, u32 type, u32 chr, u8 excl, void **out)
{
    (void)chr; (void)excl;
    return harness_create_device(drv, ext, name, type, out);
}

void *__stdcall IoBuildDeviceIoControlRequest(u32 code, void *dev, void *in, u32 inl_, void *out, u32 outl_,
                                              u8 internal, void *ev, void *iosb)
{
    (void)code; (void)dev; (void)in; (void)inl_; (void)out; (void)outl_; (void)internal; (void)ev; (void)iosb;
    return 0;
}

i32 __stdcall IoGetDeviceObjectPointer(void *name, u32 acc, void **fo, void **dobj)
{
    (void)name; (void)acc; (void)fo; (void)dobj;
    return (i32)0xC0000034;     /* STATUS_OBJECT_NAME_NOT_FOUND */
}

void __stdcall IoSetHardErrorOrVerifyDevice(void *irp, void *dev) { (void)irp; (void)dev; }
u8 __stdcall IoSetThreadHardErrorMode(u8 on) { (void)on; return 1; }
i32 __fastcall IofCallDriver(void *dev, void *irp) { (void)dev; (void)irp; return (i32)0xC0000010; }
void __fastcall IofCompleteRequest(void *irp, char boost) { (void)irp; (void)boost; }
i32 __fastcall ObfDereferenceObject(void *o) { (void)o; return 0; }

u32 __stdcall RtlCompareMemory(const void *a, const void *b, u32 n)
{
    const u8 *x = (const u8 *)a, *y = (const u8 *)b;
    u32 i;
    for (i = 0; i < n && x[i] == y[i]; i++)
        ;
    return i;
}

typedef struct { u16 Length, MaximumLength; u16 *Buffer; } US;

void __stdcall RtlInitUnicodeString(US *u, const u16 *s)
{
    u32 n = 0;
    if (s)
        while (s[n])
            n++;
    u->Buffer = (u16 *)s;
    u->Length = (u16)(n * 2);
    u->MaximumLength = (u16)(s ? n * 2 + 2 : 0);
}

i32 __stdcall RtlCreateRegistryKey(u32 rel, u16 *path) { (void)rel; (void)path; return 0; }

i32 __stdcall RtlWriteRegistryValue(u32 rel, const u16 *path, const u16 *name, u32 type, void *data, u32 len)
{
    (void)rel; (void)path; (void)len;
    harness_puts("REG ");
    harness_putw(name);
    harness_putc('=');
    if (type == 1)              /* REG_SZ */
        harness_putw((const u16 *)data);
    harness_puts("\n");
    return 0;
}

i32 __stdcall ZwCreateFile(void **h, u32 a, void *oa, void *iosb, void *size, u32 attr, u32 share, u32 disp,
                           u32 opt, void *ea, u32 eal)
{
    (void)h; (void)a; (void)oa; (void)iosb; (void)size; (void)attr; (void)share; (void)disp; (void)opt; (void)ea; (void)eal;
    return (i32)0xC0000034;
}

i32 __stdcall ZwOpenKey(void **h, u32 a, void *oa) { (void)h; (void)a; (void)oa; return (i32)0xC0000034; }
i32 __stdcall ZwOpenSymbolicLinkObject(void **h, u32 a, void *oa) { (void)h; (void)a; (void)oa; return (i32)0xC0000034; }
i32 __stdcall ZwQueryValueKey(void *h, void *name, int cls, void *info, u32 len, u32 *res)
{
    (void)h; (void)name; (void)cls; (void)info; (void)len; (void)res;
    return (i32)0xC0000034;
}

/* NT 3.1 build (-DUSOSUSB_NT31): the stdcall forms its kernel / HAL export */
void __stdcall IoCompleteRequest(void *irp, char boost) { (void)irp; (void)boost; }
void __stdcall KeRaiseIrql(u8 n, u8 *old) { (void)n; *old = 0; }
void __stdcall KeLowerIrql(u8 n) { (void)n; }
