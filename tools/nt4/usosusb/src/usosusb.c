/*
 * usosusb.sys - USB keyboard and mouse for Windows NT 4.0 on xHCI machines.
 *
 * Universal Service OS (USOS)
 * Copyright (C) 2026 Maksymilian and the USOS Authors (see NOTICE)
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Own implementation, written for USOS from the public xHCI 1.2, USB 2.0 and
 * HID 1.11 specifications (no third-party code). NT 4.0 has no USB stack and
 * its i8042prt needs a real keyboard controller; boards like the X470 have
 * only xHCI. Under CSMWrap the USB keyboard works only while BIOS code runs
 * (SeaBIOS polls xHCI from INT 08h), and NT never calls that.
 *
 * This is a legacy (non-PnP) NT 4.0 keyboard and pointer port driver:
 *
 *  - DriverEntry creates \Device\KeyboardPortN and \Device\PointerPortN
 *    (N = first free number, after i8042prt's), writes them to
 *    HARDWARE\DEVICEMAP\KeyboardPort / PointerPort, and answers the
 *    kbdclass/mouclass connect, enable and query IOCTLs like i8042prt.
 *    Both devices always exist, so mouclass always has a port to connect to.
 *  - A system thread finds every xHCI controller (PCI class 0C0330), takes
 *    it from the firmware (USBLEGSUP), resets it and runs it without
 *    interrupts: one command ring, one event ring, polled every 10 ms.
 *  - Devices on root ports and behind USB 2.0 / 3.x hubs (up to 4 hub
 *    tiers): enable slot, address, read the device and configuration
 *    descriptors, pick the first HID boot keyboard and boot mouse interface,
 *    configure their interrupt IN endpoint, SET_PROTOCOL(boot), SET_IDLE(0).
 *    Hot plug through port status events (root ports) and the hub status
 *    change endpoint plus a slow GET_PORT_STATUS poll (hub ports). Hubs get
 *    the Route String, Hub / Number of Ports / TT fields in the Slot Context
 *    (USB 2.0 hub class requests, SET_HUB_DEPTH for SuperSpeed hubs).
 *  - Keyboard boot reports become scan code set 1 make/break codes
 *    (KEYBOARD_INPUT_DATA) with software typematic repeat; Caps/Num/Scroll
 *    lock LEDs follow IOCTL_KEYBOARD_SET_INDICATORS (SET_REPORT). Mouse boot
 *    reports become relative MOUSE_INPUT_DATA (3 buttons, wheel byte if any).
 *    Input goes to the class service callback at DISPATCH_LEVEL.
 *  - Services\usosusb\Parameters\Diag (REG_SZ) gets a short state line
 *    (controllers, ports, devices) for diagnostics on real hardware.
 *
 * Imports only routines that NT 4.0 RTM and SP6a export
 * (tools/tests/check_nt4_driver_imports.py).
 */

#include <ntddk.h>
#include <ntddkbd.h>
#include <ntddmou.h>
#include <kbdmou.h>
#ifdef USOSUSB_NT6
#include <ntdddisk.h>
#include <ntddstor.h>
#include <mountdev.h>
#include <mountmgr.h>
#endif

#ifdef USOSUSB_NT31
/* NT 3.1 (build-nt31.cmd): its kernel exports IoCompleteRequest, its HAL
   KeRaiseIrql / KeLowerIrql (stdcall), not the fastcall Iof / Kf forms
   the WDK macros name. */
#undef IoCompleteRequest
#undef KeRaiseIrql
#undef KeLowerIrql
__declspec(dllimport) VOID __stdcall IoCompleteRequest(PIRP Irp, CCHAR PriorityBoost);
__declspec(dllimport) VOID __stdcall KeRaiseIrql(KIRQL NewIrql, PKIRQL OldIrql);
__declspec(dllimport) VOID __stdcall KeLowerIrql(KIRQL NewIrql);
#define USOSUSB_VERSION L"usosusb 1.1-nt31"
#elif defined(USOSUSB_NT6)
/* Vista / Server 2008 SP2 x86 (build-nt6.cmd): same legacy port devices;
   kbdclass / mouclass connect them as legacy ports (\Device\KeyboardClassLegacyN,
   \Device\PointerClassLegacyN, which win32k opens). PCI configuration goes
   through the HAL (its lock; other CPUs run), input is sent once a class
   driver connected even before its ENABLE, and a Conn value shows the
   connect / enable state. */
#pragma warning(disable:4996)   /* HalGetBusDataByOffset is marked obsolete */
#define USOSUSB_VERSION L"usosusb 1.2-nt6"
/* USB mass storage (bulk-only transport, SCSI transparent command set):
   removable volumes for the file systems, drive letters via the mount
   manager. */
#define USOSUSB_MSC 1
#else
#define USOSUSB_VERSION L"usosusb 1.2-nt4"
#endif

#define MAXHC 4
#define MAXDEV 16
#define MAXTIER 4               /* hubs at tiers 0..3: devices up to 4 hubs deep */
#define RING_TRBS 256           /* one 4 KiB page per ring */

/* TRB types */
#define TRB_NORMAL 1
#define TRB_SETUP 2
#define TRB_DATA 3
#define TRB_STATUS 4
#define TRB_LINK 6
#define TRB_ENABLE_SLOT 9
#define TRB_DISABLE_SLOT 10
#define TRB_ADDRESS_DEVICE 11
#define TRB_CONFIGURE_EP 12
#define TRB_EVALUATE_CTX 13
#define TRB_RESET_EP 14
#define TRB_SET_TR_DEQ 16
#define TRB_STOP_EP 15
#define TRB_EV_TRANSFER 32
#define TRB_EV_COMMAND 33
#define TRB_EV_PORT 34

#define CC_SUCCESS 1
#define CC_SHORT 13
#define CC_STALL 6

/* PORTSC */
#define PS_CCS 0x00000001
#define PS_PED 0x00000002
#define PS_PR 0x00000010
#define PS_PP 0x00000200
#define PS_CHANGES 0x00FE0000
#define PS_PRC 0x00200000
#define PS_KEEP 0x0E00C3E1      /* CCS, PLS, PP, speed, PIC, wake bits: written back as read */

typedef struct _RING {
    volatile ULONG *v;          /* RING_TRBS * 4 dwords */
    ULONG pa;
    ULONG idx;
    ULONG cycle;
} RING;

struct _HC;

typedef struct _DEV {
    struct _HC *hc;
    UCHAR used, slot, port, speed;
    /* topology: port = port on the parent (root port when parent == 0),
       parent = index + 1 of the hub in hc->dev, rport = root hub port,
       tier = hubs between the root port and this device, route = xHCI
       Route String, tthub / ttport = the high-speed hub whose transaction
       translator serves this LS / FS device (0 = none) */
    UCHAR parent, rport, tier, gone;
    UCHAR tthub, ttport;
    ULONG route;
    UCHAR dclass;               /* bDeviceClass */
    WCHAR path[24];             /* Diag name, e.g. p5 or p5.2.1 */
    /* hub: ports, status change endpoint (uses kring and buf + 1024) */
    UCHAR ishub, nports, hdci, hmps, hival, httt, hss, hpwr;
    volatile ULONG hchg;        /* bit per hub port (1..15) to look at */
    ULONG hfail;                /* ports whose device failed; retried after a connect change */
    ULONG hlive;                /* status change endpoint queued and working */
    UCHAR *out, *in, *buf;      /* output context, input context, data page */
    ULONG outpa, inpa, bufpa;
    RING ep0;
    volatile int ctl_done;
    ULONG ctl_cc;
    /* keyboard */
    UCHAR kdci, kintf, kmps, kival;
    RING kring;
    UCHAR kold[8];
    UCHAR kleds, kleds_sent;
    /* mouse */
    UCHAR mdci, mintf, mmps, mival;
    RING mring;
    UCHAR mold;
#ifdef USOSUSB_MSC
    /* mass storage (bulk-only): interface, bulk IN / OUT */
    UCHAR sintf, sidci, sodci, siaddr, soaddr, siburst, soburst;
    USHORT simps, somps, vid, pid;
    RING sring, oring;
    volatile int blk_done;
    ULONG blk_cc, blk_resid;
    ULONG tag;
    ULONG blocks;               /* 512-byte sectors */
    UCHAR wp, nvol;
    struct _VOL *vol[4];
#endif
} DEV;

typedef struct _HC {
    volatile UCHAR *base;
    volatile ULONG *op, *ir0, *db;
    ULONG ctxsz, maxslots, maxports;
    ULONG pciaddr;
    USHORT vid, did;
    volatile ULONG *dcbaa;
    ULONG dcbaapa;
    RING cmd;
    volatile ULONG *evt;
    ULONG evtpa, evidx, evcycle;
    volatile int cmd_done;
    ULONG cmd_cc, cmd_slot;
    ULONG portchg;              /* bit per port (1..31) to look at */
    volatile int hubchg;        /* a hub reported a port change */
    DEV dev[MAXDEV];
    int ok;
} HC;

typedef struct _PORTEXT {
    int keyboard;
    int connected;
    LONG enabled;
    LONG enable_seen;
    CONNECT_DATA conn;
    KEYBOARD_TYPEMATIC_PARAMETERS typematic;
    KEYBOARD_INDICATOR_PARAMETERS leds;
} PORTEXT;

static HC g_hc[MAXHC];
static int g_nhc;
static PDEVICE_OBJECT g_kbd, g_mou;
static UNICODE_STRING g_regpath;
static WCHAR g_regbuf[256];
static WCHAR g_diag[1024];
static volatile LONG g_ledseq;
#ifdef USOSUSB_NT6
static volatile LONG g_connseq;  /* bumped on connect / enable / disable */
static ULONG g_kbd_sent, g_mou_sent;   /* input records passed to the class drivers */
#endif

#ifdef USOSUSB_MSC
static void msc_attach(DEV *d);
static void msc_detach(DEV *d);
#endif

/* typematic state (worker thread only) */
static UCHAR g_rep_usage;
static LARGE_INTEGER g_rep_next;

/* ------------------------------------------------------------------ */
/* small helpers                                                       */

static void delay_ms(ULONG ms)
{
    LARGE_INTEGER t;
    t.QuadPart = -(LONGLONG)ms * 10000;
    KeDelayExecutionThread(KernelMode, FALSE, &t);
}

static LONGLONG now_ms(void)
{
    LARGE_INTEGER t;
    KeQuerySystemTime(&t);
    return t.QuadPart / 10000;
}

static void *alloc_page(ULONG *pa)
{
    PHYSICAL_ADDRESS hi;
    void *v;
    hi.QuadPart = 0x7FFFFFFF;
    v = MmAllocateContiguousMemory(PAGE_SIZE, hi);
    if (!v)
        return NULL;
    RtlZeroMemory(v, PAGE_SIZE);
    *pa = MmGetPhysicalAddress(v).LowPart;
    return v;
}

/* Tiny formatter (no C runtime): %u %d %x %02x %c %s (wide), ULONG args. */
static void wfmt(WCHAR *out, size_t cap, const WCHAR *f, const ULONG_PTR *arg)
{
    size_t o = 0;
    while (*f && o + 1 < cap) {
        WCHAR c = *f++, tmp[12];
        int w = 0, neg = 0, k = 0;
        ULONG v, base;
        if (c != L'%') {
            out[o++] = c;
            continue;
        }
        if (*f == L'0') {
            f++;
            w = *f++ - L'0';
        }
        c = *f++;
        if (c == L'c') {
            out[o++] = (WCHAR)*arg++;
            continue;
        }
        if (c == L's') {
            const WCHAR *t = (const WCHAR *)*arg++;
            while (*t && o + 1 < cap)
                out[o++] = *t++;
            continue;
        }
        v = (ULONG)*arg++;
        base = c == L'x' ? 16 : 10;
        if (c == L'd' && (LONG)v < 0) {
            neg = 1;
            v = (ULONG)-(LONG)v;
        }
        do {
            tmp[k++] = L"0123456789abcdef"[v % base];
            v /= base;
        } while (v && k < 11);
        while (k < w && k < 11)
            tmp[k++] = L'0';
        if (neg && o + 1 < cap)
            out[o++] = L'-';
        while (k && o + 1 < cap)
            out[o++] = tmp[--k];
    }
    out[o] = 0;
}

static void diag_add(const WCHAR *fmt, ULONG_PTR a, ULONG_PTR b, ULONG_PTR c, ULONG_PTR d)
{
    ULONG_PTR args[4];
    size_t n = wcslen(g_diag);
    if (n + 80 >= sizeof(g_diag) / sizeof(WCHAR))
        return;
    args[0] = a; args[1] = b; args[2] = c; args[3] = d;
    wfmt(g_diag + n, sizeof(g_diag) / sizeof(WCHAR) - n, fmt, args);
}

static void diag_write(void)
{
    WCHAR path[300];
    if (g_regpath.Length / sizeof(WCHAR) + 12 >= sizeof(path) / sizeof(WCHAR))
        return;
    RtlCopyMemory(path, g_regpath.Buffer, g_regpath.Length);
    RtlCopyMemory(path + g_regpath.Length / sizeof(WCHAR), L"\\Parameters", 12 * sizeof(WCHAR));
    RtlCreateRegistryKey(RTL_REGISTRY_ABSOLUTE, path);
    RtlWriteRegistryValue(RTL_REGISTRY_ABSOLUTE, path, L"Diag", REG_SZ, g_diag,
                          (ULONG)(wcslen(g_diag) + 1) * sizeof(WCHAR));
}

#ifdef USOSUSB_NT6
/* Parameters\Conn (REG_SZ): class connection per port, e.g.
   "kbd c1 e1/1 n42 mou c1 e1/1 n7" (connected, ENABLE seen / count,
   input records sent). */
static void conn_write(void)
{
    WCHAR path[300], line[96];
    ULONG_PTR a[8];
    PORTEXT *k = g_kbd ? (PORTEXT *)g_kbd->DeviceExtension : NULL;
    PORTEXT *m = g_mou ? (PORTEXT *)g_mou->DeviceExtension : NULL;
    if (g_regpath.Length / sizeof(WCHAR) + 12 >= sizeof(path) / sizeof(WCHAR))
        return;
    a[0] = k ? k->connected : 9; a[1] = k ? k->enable_seen : 9; a[2] = k ? (ULONG)k->enabled : 0; a[3] = g_kbd_sent;
    a[4] = m ? m->connected : 9; a[5] = m ? m->enable_seen : 9; a[6] = m ? (ULONG)m->enabled : 0; a[7] = g_mou_sent;
    wfmt(line, 96, L"kbd c%u e%u/%d n%u ", a);
    wfmt(line + wcslen(line), 96 - wcslen(line), L"mou c%u e%u/%d n%u", a + 4);
    RtlCopyMemory(path, g_regpath.Buffer, g_regpath.Length);
    RtlCopyMemory(path + g_regpath.Length / sizeof(WCHAR), L"\\Parameters", 12 * sizeof(WCHAR));
    RtlCreateRegistryKey(RTL_REGISTRY_ABSOLUTE, path);
    RtlWriteRegistryValue(RTL_REGISTRY_ABSOLUTE, path, L"Conn", REG_SZ, line,
                          (ULONG)(wcslen(line) + 1) * sizeof(WCHAR));
}
#endif
#ifdef USOSUSB_NT6
/* addr = mechanism 1 form (bus 23:16, device 15:11, function 10:8). */
static ULONG pci_slot(ULONG addr)
{
    PCI_SLOT_NUMBER s;
    s.u.AsULONG = 0;
    s.u.bits.DeviceNumber = (addr >> 11) & 0x1F;
    s.u.bits.FunctionNumber = (addr >> 8) & 7;
    return s.u.AsULONG;
}

static ULONG pci_read(ULONG addr, ULONG off)
{
    ULONG v = 0xFFFFFFFFu;
    if (HalGetBusDataByOffset(PCIConfiguration, (addr >> 16) & 0xFF, pci_slot(addr), &v, off & 0xFC, 4) != 4)
        return 0xFFFFFFFFu;
    return v;
}

static void pci_write(ULONG addr, ULONG off, ULONG v)
{
    HalSetBusDataByOffset(PCIConfiguration, (addr >> 16) & 0xFF, pci_slot(addr), &v, off & 0xFC, 4);
}
#else
/* PCI configuration mechanism 1 (CF8h/CFCh), interrupts off on this CPU. */
static ULONG pci_read(ULONG addr, ULONG off)
{
    ULONG v;
    __asm cli
    WRITE_PORT_ULONG((PULONG)0xCF8, addr | (off & 0xFC));
    v = READ_PORT_ULONG((PULONG)0xCFC);
    __asm sti
    return v;
}

static void pci_write(ULONG addr, ULONG off, ULONG v)
{
    __asm cli
    WRITE_PORT_ULONG((PULONG)0xCF8, addr | (off & 0xFC));
    WRITE_PORT_ULONG((PULONG)0xCFC, v);
    __asm sti
}
#endif

/* ------------------------------------------------------------------ */
/* rings                                                               */

static int ring_init(RING *r)
{
    r->v = (volatile ULONG *)alloc_page(&r->pa);
    if (!r->v)
        return 0;
    r->idx = 0;
    r->cycle = 1;
    return 1;
}

static void ring_wrap(RING *r)
{
    volatile ULONG *t = r->v + r->idx * 4;
    t[0] = r->pa;
    t[1] = 0;
    t[2] = 0;
    t[3] = (TRB_LINK << 10) | 2 /* toggle cycle */ | r->cycle;
    r->idx = 0;
    r->cycle ^= 1;
}

/* Room for n TRBs in a row (a TD never crosses the link TRB). */
static void ring_reserve(RING *r, ULONG n)
{
    if (r->idx + n > RING_TRBS - 1)
        ring_wrap(r);
}

static ULONG ring_push(RING *r, ULONG d0, ULONG d1, ULONG d2, ULONG d3)
{
    volatile ULONG *t;
    ULONG pa;
    if (r->idx >= RING_TRBS - 1)
        ring_wrap(r);
    t = r->v + r->idx * 4;
    pa = r->pa + r->idx * 16;
    t[0] = d0;
    t[1] = d1;
    t[2] = d2;
    t[3] = (d3 & ~1u) | r->cycle;
    r->idx++;
    return pa;
}

static ULONG ring_enq_pa(RING *r)
{
    if (r->idx >= RING_TRBS - 1)
        ring_wrap(r);
    return r->pa + r->idx * 16;
}

static void doorbell(HC *hc, ULONG slot, ULONG target)
{
    hc->db[slot] = target;
}

static void write64(volatile ULONG *reg, ULONG lo)
{
    reg[0] = lo;
    reg[1] = 0;
}

/* ------------------------------------------------------------------ */
/* input to the class drivers                                          */

static int port_live(PORTEXT *x)
{
    if (!x->connected || !x->conn.ClassService)
        return 0;
#ifdef USOSUSB_NT6
    /* until the first ENABLE / DISABLE: the class driver connected */
    if (!x->enable_seen)
        return 1;
#endif
    return x->enabled > 0;
}

static void send_kbd(KEYBOARD_INPUT_DATA *a, ULONG n)
{
    PORTEXT *x;
    KIRQL old;
    ULONG used = 0;
    if (!g_kbd || !n)
        return;
    x = (PORTEXT *)g_kbd->DeviceExtension;
    if (!port_live(x))
        return;
    KeRaiseIrql(DISPATCH_LEVEL, &old);
    (*(PSERVICE_CALLBACK_ROUTINE)(ULONG_PTR)x->conn.ClassService)(x->conn.ClassDeviceObject, a, a + n, &used);
    KeLowerIrql(old);
#ifdef USOSUSB_NT6
    g_kbd_sent += n;
#endif
}

static void send_mou(MOUSE_INPUT_DATA *a)
{
    PORTEXT *x;
    KIRQL old;
    ULONG used = 0;
    if (!g_mou)
        return;
    x = (PORTEXT *)g_mou->DeviceExtension;
    if (!port_live(x))
        return;
    KeRaiseIrql(DISPATCH_LEVEL, &old);
    (*(PSERVICE_CALLBACK_ROUTINE)(ULONG_PTR)x->conn.ClassService)(x->conn.ClassDeviceObject, a, a + 1, &used);
    KeLowerIrql(old);
#ifdef USOSUSB_NT6
    g_mou_sent++;
#endif
}

/*
 * HID keyboard usage (page 7) -> scan code set 1. 0x100 = E0 prefix,
 * 0 = no key. From the public USB HID Usage Tables / PS/2 set 1 layout.
 */
static const USHORT g_set1[0x68] = {
    /* 00 */ 0, 0, 0, 0, 0x1E, 0x30, 0x2E, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17, 0x24, 0x25, 0x26,
    /* 10 */ 0x32, 0x31, 0x18, 0x19, 0x10, 0x13, 0x1F, 0x14, 0x16, 0x2F, 0x11, 0x2D, 0x15, 0x2C, 0x02, 0x03,
    /* 20 */ 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x1C, 0x01, 0x0E, 0x0F, 0x39, 0x0C, 0x0D, 0x1A,
    /* 30 */ 0x1B, 0x2B, 0x2B, 0x27, 0x28, 0x29, 0x33, 0x34, 0x35, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x40,
    /* 40 */ 0x41, 0x42, 0x43, 0x44, 0x57, 0x58, 0x137, 0x46, 0 /* Pause: own case */, 0x152, 0x147, 0x149, 0x153, 0x14F, 0x151, 0x14D,
    /* 50 */ 0x14B, 0x150, 0x148, 0x45, 0x135, 0x37, 0x4A, 0x4E, 0x11C, 0x4F, 0x50, 0x51, 0x4B, 0x4C, 0x4D, 0x47,
    /* 60 */ 0x48, 0x49, 0x52, 0x53, 0x56, 0x15D, 0x15E, 0x59,
};
/* modifiers E0..E7: LCtrl LShift LAlt LGUI RCtrl RShift RAlt(AltGr) RGUI */
static const USHORT g_mod[8] = { 0x1D, 0x2A, 0x38, 0x15B, 0x11D, 0x36, 0x138, 0x15C };

static USHORT usage_code(UCHAR u)
{
    if (u >= 0xE0 && u <= 0xE7)
        return g_mod[u - 0xE0];
    if (u < sizeof(g_set1) / sizeof(g_set1[0]))
        return g_set1[u];
    switch (u) {
    case 0x87: return 0x73;    /* International1 (Ro) */
    case 0x88: return 0x70;    /* Katakana/Hiragana */
    case 0x89: return 0x7D;    /* Yen */
    case 0x8A: return 0x79;    /* Henkan */
    case 0x8B: return 0x7B;    /* Muhenkan */
    }
    return 0;
}

static ULONG key_event(KEYBOARD_INPUT_DATA *o, UCHAR u, int brk)
{
    USHORT c;
    RtlZeroMemory(o, 2 * sizeof(*o));
    if (u == 0x48) {            /* Pause: E1 1D 45 */
        o[0].MakeCode = 0x1D;
        o[0].Flags = KEY_E1 | (brk ? KEY_BREAK : 0);
        o[1].MakeCode = 0x45;
        o[1].Flags = brk ? KEY_BREAK : 0;
        return 2;
    }
    c = usage_code(u);
    if (!c)
        return 0;
    o[0].MakeCode = c & 0xFF;
    o[0].Flags = (USHORT)(((c & 0x100) ? KEY_E0 : 0) | (brk ? KEY_BREAK : 0));
    return 1;
}

static int in_report(const UCHAR *r, UCHAR u)
{
    int i;
    for (i = 2; i < 8; i++)
        if (r[i] == u)
            return 1;
    return 0;
}

static void kbd_report(DEV *d, const UCHAR *raw, ULONG len)
{
    KEYBOARD_INPUT_DATA ev[40];
    UCHAR r[8];
    ULONG n = 0;
    int i;
    PORTEXT *x = g_kbd ? (PORTEXT *)g_kbd->DeviceExtension : NULL;
    if (len < 3)
        return;
    RtlZeroMemory(r, sizeof(r));
    RtlCopyMemory(r, raw, len < 8 ? len : 8);
    if (r[2] == 1 && r[3] == 1)     /* ErrorRollOver: keep the old state */
        return;
    for (i = 0; i < 8; i++) {
        UCHAR bit = (UCHAR)(1 << i);
        if ((d->kold[0] & bit) && !(r[0] & bit))
            n += key_event(ev + n, (UCHAR)(0xE0 + i), 1);
    }
    for (i = 2; i < 8; i++)
        if (d->kold[i] > 3 && !in_report(r, d->kold[i])) {
            n += key_event(ev + n, d->kold[i], 1);
            if (g_rep_usage == d->kold[i])
                g_rep_usage = 0;
        }
    for (i = 0; i < 8; i++) {
        UCHAR bit = (UCHAR)(1 << i);
        if (!(d->kold[0] & bit) && (r[0] & bit))
            n += key_event(ev + n, (UCHAR)(0xE0 + i), 0);
    }
    for (i = 2; i < 8; i++)
        if (r[i] > 3 && !in_report(d->kold, r[i])) {
            n += key_event(ev + n, r[i], 0);
            if (r[i] != 0x39 && r[i] != 0x47 && r[i] != 0x53 && r[i] != 0x48) {   /* no repeat for locks/Pause */
                LONGLONG delay = 500;
                if (x && x->typematic.Delay >= 250 && x->typematic.Delay <= 1000)
                    delay = x->typematic.Delay;
                g_rep_usage = r[i];
                g_rep_next.QuadPart = now_ms() + delay;
            }
        }
    RtlCopyMemory(d->kold, r, 8);
    send_kbd(ev, n);
}

static void kbd_repeat(void)
{
    KEYBOARD_INPUT_DATA ev[2];
    ULONG n;
    LONGLONG t, period = 33;
    PORTEXT *x = g_kbd ? (PORTEXT *)g_kbd->DeviceExtension : NULL;
    if (!g_rep_usage)
        return;
    t = now_ms();
    if (t < g_rep_next.QuadPart)
        return;
    if (x && x->typematic.Rate >= 2 && x->typematic.Rate <= 30)
        period = 1000 / x->typematic.Rate;
    g_rep_next.QuadPart = t + period;
    n = key_event(ev, g_rep_usage, 0);
    send_kbd(ev, n);
}

static void mou_report(DEV *d, const UCHAR *r, ULONG len)
{
    MOUSE_INPUT_DATA m;
    UCHAR b, o;
    if (len < 3)
        return;
    RtlZeroMemory(&m, sizeof(m));
    b = (UCHAR)(r[0] & 7);
    o = d->mold;
    if ((b & 1) && !(o & 1)) m.ButtonFlags |= MOUSE_LEFT_BUTTON_DOWN;
    if (!(b & 1) && (o & 1)) m.ButtonFlags |= MOUSE_LEFT_BUTTON_UP;
    if ((b & 2) && !(o & 2)) m.ButtonFlags |= MOUSE_RIGHT_BUTTON_DOWN;
    if (!(b & 2) && (o & 2)) m.ButtonFlags |= MOUSE_RIGHT_BUTTON_UP;
    if ((b & 4) && !(o & 4)) m.ButtonFlags |= MOUSE_MIDDLE_BUTTON_DOWN;
    if (!(b & 4) && (o & 4)) m.ButtonFlags |= MOUSE_MIDDLE_BUTTON_UP;
    d->mold = b;
    m.Flags = MOUSE_MOVE_RELATIVE;
    m.LastX = (LONG)(signed char)r[1];
    m.LastY = (LONG)(signed char)r[2];
    m.RawButtons = b;
    if (len >= 4 && r[3]) {
        m.ButtonFlags |= MOUSE_WHEEL;
        m.ButtonData = (USHORT)(SHORT)((signed char)r[3] * 120);
    }
    if (m.ButtonFlags || m.LastX || m.LastY)
        send_mou(&m);
}

/* ------------------------------------------------------------------ */
/* events                                                              */

static DEV *dev_by_slot(HC *hc, ULONG slot)
{
    int i;
    for (i = 0; i < MAXDEV; i++)
        if (hc->dev[i].used && hc->dev[i].slot == slot)
            return &hc->dev[i];
    return NULL;
}

static void queue_intr(DEV *d, int kbd)
{
    HC *hc = d->hc;
    ULONG off = kbd ? 1024 : 2048;
    ULONG len = kbd ? d->kmps : d->mmps;
    RING *r = kbd ? &d->kring : &d->mring;
    if (len > 64)
        len = 64;
    ring_push(r, d->bufpa + off, 0, len, (TRB_NORMAL << 10) | (1 << 5) /* IOC */ | (1 << 2) /* ISP */);
    doorbell(hc, d->slot, kbd ? d->kdci : d->mdci);
}

/* hub status change endpoint: one TD for the port bitmap */
static void queue_hub(DEV *d)
{
    ULONG len = d->hmps;
    if (len > 8 || !len)
        len = len ? 8 : 1;
    ring_push(&d->kring, d->bufpa + 1024, 0, len, (TRB_NORMAL << 10) | (1 << 5) /* IOC */ | (1 << 2) /* ISP */);
    doorbell(d->hc, d->slot, d->hdci);
    d->hlive = 1;
}

static void hc_poll(HC *hc)
{
    int n = 0;
    for (;;) {
        volatile ULONG *e = hc->evt + hc->evidx * 4;
        ULONG d2 = e[2], d3 = e[3], d0 = e[0];
        ULONG type, cc;
        if ((d3 & 1) != hc->evcycle)
            break;
        type = (d3 >> 10) & 0x3F;
        cc = d2 >> 24;
        if (type == TRB_EV_COMMAND) {
            hc->cmd_cc = cc;
            hc->cmd_slot = d3 >> 24;
            hc->cmd_done = 1;
        } else if (type == TRB_EV_PORT) {
            ULONG p = d0 >> 24;
            if (p >= 1 && p <= 31)
                hc->portchg |= 1u << p;
        } else if (type == TRB_EV_TRANSFER) {
            DEV *d = dev_by_slot(hc, d3 >> 24);
            ULONG ep = (d3 >> 16) & 0x1F;
            if (d) {
                if (ep == 1) {
                    d->ctl_cc = cc;
                    d->ctl_done = 1;
                } else if (d->ishub && ep == d->hdci) {
                    /* bit 0 = hub, bit n = port n; handled in the worker loop */
                    if (cc == CC_SUCCESS || cc == CC_SHORT) {
                        ULONG asked = d->hmps > 8 ? 8 : (d->hmps ? d->hmps : 1);
                        ULONG resid = d2 & 0xFFFFFF, got = resid <= asked ? asked - resid : 0, k, bits = 0;
                        for (k = 0; k < got && k < 4; k++)
                            bits |= (ULONG)d->buf[1024 + k] << (8 * k);
                        d->hchg |= bits;
                        hc->hubchg = 1;
                        queue_hub(d);
                    } else {
                        d->hlive = 0;   /* hub gone or endpoint halted: the slow poll takes over */
                    }
                } else if (ep == d->kdci || ep == d->mdci) {
                    int kbd = ep == d->kdci;
                    ULONG asked = kbd ? d->kmps : d->mmps;
                    ULONG resid = d2 & 0xFFFFFF, got;
                    if (asked > 64)
                        asked = 64;
                    got = resid <= asked ? asked - resid : 0;
                    if (cc == CC_SUCCESS || cc == CC_SHORT) {
                        if (kbd)
                            kbd_report(d, d->buf + 1024, got);
                        else
                            mou_report(d, d->buf + 2048, got);
                        queue_intr(d, kbd);
                    }
                    /* errors: endpoint stopped (unplug); the port event cleans up */
                }
#ifdef USOSUSB_MSC
                else if (d->sidci && (ep == d->sidci || ep == d->sodci)) {
                    d->blk_cc = cc;
                    d->blk_resid = d2 & 0xFFFFFF;
                    d->blk_done = 1;
                }
#endif
            }
        }
        hc->evidx++;
        if (hc->evidx == RING_TRBS) {
            hc->evidx = 0;
            hc->evcycle ^= 1;
        }
        n++;
    }
    if (n)
        write64(hc->ir0 + 6, (hc->evtpa + hc->evidx * 16) | 8 /* EHB */);
}

static int hc_cmd(HC *hc, ULONG d0, ULONG d2, ULONG d3)
{
    int i;
    hc->cmd_done = 0;
    ring_push(&hc->cmd, d0, 0, d2, d3);
    doorbell(hc, 0, 0);
    for (i = 0; i < 20000; i++) {       /* 1 s */
        hc_poll(hc);
        if (hc->cmd_done)
            return (int)hc->cmd_cc;
        KeStallExecutionProcessor(50);
    }
    return -1;
}

/* ------------------------------------------------------------------ */
/* contexts                                                            */

static ULONG *ictx(DEV *d, ULONG i)   /* 0 = input control, 1 = slot, 2 = EP0, dci+1 */
{
    return (ULONG *)(d->in + i * d->hc->ctxsz);
}

static ULONG *octx(DEV *d, ULONG i)   /* 0 = slot, dci */
{
    return (ULONG *)(d->out + i * d->hc->ctxsz);
}

static void ep_recover(DEV *d, ULONG dci, RING *r)
{
    HC *hc = d->hc;
    hc_cmd(hc, 0, 0, (TRB_RESET_EP << 10) | (dci << 16) | ((ULONG)d->slot << 24));
    hc_cmd(hc, ring_enq_pa(r) | r->cycle, 0, (TRB_SET_TR_DEQ << 10) | (dci << 16) | ((ULONG)d->slot << 24));
}

static int control(DEV *d, UCHAR rt, UCHAR req, USHORT val, USHORT idx, USHORT len)
{
    HC *hc = d->hc;
    int i, in = (rt & 0x80) != 0;
    ULONG trt = len ? (in ? 3 : 2) : 0;
    ring_reserve(&d->ep0, 3);
    d->ctl_done = 0;
    ring_push(&d->ep0, rt | (req << 8) | ((ULONG)val << 16), idx | ((ULONG)len << 16), 8,
              (TRB_SETUP << 10) | (1 << 6) /* IDT */ | (trt << 16));
    if (len)
        ring_push(&d->ep0, d->bufpa, 0, len, (TRB_DATA << 10) | (in ? 1 << 16 : 0));
    ring_push(&d->ep0, 0, 0, 0, (TRB_STATUS << 10) | (1 << 5) | ((len && in) ? 0 : 1 << 16));
    doorbell(hc, d->slot, 1);
    for (i = 0; i < 20000; i++) {
        hc_poll(hc);
        if (d->ctl_done)
            break;
        KeStallExecutionProcessor(50);
    }
    if (!d->ctl_done)
        return -1;
    if (d->ctl_cc == CC_SUCCESS || d->ctl_cc == CC_SHORT)
        return 0;
    ep_recover(d, 1, &d->ep0);
    return -(int)d->ctl_cc;
}

static UCHAR xhci_interval(UCHAR speed, UCHAR ival)
{
    ULONG iv, frames;
    if (speed >= 3) {           /* high/super speed: 2^(bInterval-1) microframes */
        iv = ival ? ival - 1u : 0;
        return (UCHAR)(iv > 15 ? 15 : iv);
    }
    frames = ival ? ival : 1;   /* full/low speed: bInterval frames (ms) */
    iv = 3;
    while (iv < 10 && (1u << (iv + 1)) <= frames * 8)
        iv++;
    return (UCHAR)iv;
}

static void dev_drop(DEV *d)
{
    HC *hc = d->hc;
    int i;
    if (!d->used)
        return;
    d->gone = 1;
    /* a hub takes everything behind it along (children first) */
    for (i = 0; d->ishub && i < MAXDEV; i++) {
        DEV *c = &hc->dev[i];
        if (c->used && c->parent == (UCHAR)(d - hc->dev) + 1) {
            dev_drop(c);
            diag_add(L" %s-gone", (ULONG_PTR)c->path, 0, 0, 0);
        }
    }
    if (g_rep_usage && d->kdci)
        g_rep_usage = 0;
#ifdef USOSUSB_MSC
    msc_detach(d);
#endif
    if (d->slot) {
        hc_cmd(hc, 0, 0, (TRB_DISABLE_SLOT << 10) | ((ULONG)d->slot << 24));
        hc->dcbaa[d->slot * 2] = 0;
    }
    d->used = 0;
    d->slot = 0;
    d->ishub = 0;
    d->hchg = 0;
    d->hlive = 0;
}

/* ------------------------------------------------------------------ */
/* hubs (USB 2.0 chapter 11, USB 3.x chapter 10 hub class)            */

#define HUB_PORT_RESET 4
#define HUB_PORT_POWER 8

static ULONG hub_le32(const UCHAR *p)
{
    return p[0] | ((ULONG)p[1] << 8) | ((ULONG)p[2] << 16) | ((ULONG)p[3] << 24);
}

/* GET_PORT_STATUS: wPortStatus in 15:0, wPortChange in 31:16 */
static int hub_status(DEV *h, ULONG n, ULONG *st)
{
    if (control(h, 0xA3, 0 /* GET_STATUS */, 0, (USHORT)n, 4) < 0)
        return 0;
    *st = hub_le32(h->buf);
    return 1;
}

/* CLEAR_PORT_FEATURE for every change bit that is set */
static void hub_clear(DEV *h, ULONG n, ULONG chg)
{
    /* USB 2.0: C_PORT_CONNECTION, C_PORT_ENABLE, C_PORT_SUSPEND,
       C_PORT_OVER_CURRENT, C_PORT_RESET; USB 3.x: C_PORT_CONNECTION, -, -,
       C_PORT_OVER_CURRENT, C_PORT_RESET, C_BH_PORT_RESET,
       C_PORT_LINK_STATE, C_PORT_CONFIG_ERROR */
    static const UCHAR f2[8] = { 16, 17, 18, 19, 20, 0, 0, 0 };
    static const UCHAR f3[8] = { 16, 0, 0, 19, 20, 29, 25, 26 };
    ULONG i;
    for (i = 0; i < 8; i++)
        if (chg & (1u << i)) {
            UCHAR f = h->hss ? f3[i] : f2[i];
            if (f)
                control(h, 0x23, 1 /* CLEAR_FEATURE */, f, (USHORT)n, 0);
        }
}

static DEV *hub_child(DEV *h, ULONG n)
{
    HC *hc = h->hc;
    int i;
    UCHAR me = (UCHAR)(h - hc->dev) + 1;
    for (i = 0; i < MAXDEV; i++)
        if (hc->dev[i].used && hc->dev[i].parent == me && hc->dev[i].port == n)
            return &hc->dev[i];
    return NULL;
}

/* After SET_CONFIGURATION: hub descriptor, Slot Context hub fields,
   SET_HUB_DEPTH, port power, first scan of every port. */
static int hub_start(DEV *d)
{
    HC *hc = d->hc;
    UCHAR *b = d->buf;
    ULONG n, wait, chr;
    int cc;
    d->hss = (UCHAR)(d->speed >= 4);
    if (control(d, 0xA0, 6 /* GET_DESCRIPTOR */, d->hss ? 0x2A00 : 0x2900, 0, d->hss ? 12 : 9) < 0 || b[0] < 7 || b[2] == 0) {
        diag_add(L" %s-hubd", (ULONG_PTR)d->path, 0, 0, 0);
        return 0;
    }
    d->nports = b[2] > 15 ? 15 : b[2];
    chr = b[3] | ((ULONG)b[4] << 8);
    d->httt = (UCHAR)(d->speed == 3 ? (chr >> 5) & 3 : 0);
    d->hpwr = b[5];
    /* Slot Context: Hub = 1, Number of Ports, TT Think Time (MTT stays 0:
       alternate setting 0 is the single-TT interface) */
    RtlZeroMemory(d->in, PAGE_SIZE);
    RtlCopyMemory(ictx(d, 1), octx(d, 0), hc->ctxsz);
    ictx(d, 1)[0] = (ictx(d, 1)[0] & ~(1u << 25)) | (1u << 26);
    ictx(d, 1)[1] = (ictx(d, 1)[1] & 0x00FFFFFF) | ((ULONG)d->nports << 24);
    ictx(d, 1)[2] = (ictx(d, 1)[2] & ~0x00030000u) | ((ULONG)d->httt << 16);
    ictx(d, 1)[3] = 0;
    ictx(d, 0)[1] = 1;                                          /* slot only */
    cc = hc_cmd(hc, d->inpa, 0, (TRB_CONFIGURE_EP << 10) | ((ULONG)d->slot << 24));
    if (cc != CC_SUCCESS) {
        diag_add(L" %s-hubctx%d", (ULONG_PTR)d->path, (ULONG)cc, 0, 0);
        return 0;
    }
    if (d->hss)
        control(d, 0x20, 12 /* SET_HUB_DEPTH */, d->tier, 0, 0);
    for (n = 1; n <= d->nports; n++)
        control(d, 0x23, 3 /* SET_FEATURE */, HUB_PORT_POWER, (USHORT)n, 0);
    wait = (ULONG)d->hpwr * 2;
    delay_ms(wait < 100 ? 100 : wait);
    d->ishub = 1;
    d->hfail = 0;
    d->hchg = ((1u << (d->nports + 1)) - 1) & ~1u;              /* look at every port */
    hc->hubchg = 1;
    queue_hub(d);
    return 1;
}

static DEV *dev_enum(HC *hc, DEV *hub, ULONG p, ULONG speed);

/* worker: one hub port with a change (or the slow poll). Returns 0 when
   the hub did not answer (the rest of its ports wait for the next pass,
   so a dead hub costs one control timeout, not one per port). */
static int hub_port(HC *hc, DEV *h, ULONG n)
{
    ULONG st, ps, pc, i, bit = 1u << n;
    DEV *c = hub_child(h, n);
    if (!hub_status(h, n, &st))
        return 0;               /* hub gone: its own port event drops it */
    ps = st & 0xFFFF;
    pc = st >> 16;
    if (pc)
        hub_clear(h, n, pc);
    if ((pc & 1) || !(ps & 1)) {
        if (c) {
            dev_drop(c);
            diag_add(L" %s-gone", (ULONG_PTR)c->path, 0, 0, 0);
            c = NULL;
        }
        if (pc & 1)
            h->hfail &= ~bit;
    }
    if (!(ps & 1) || c || (h->hfail & bit))
        return 1;
    delay_ms(100);              /* connect debounce */
    control(h, 0x23, 3 /* SET_FEATURE */, HUB_PORT_RESET, (USHORT)n, 0);
    for (i = 0; i < 50; i++) {
        delay_ms(10);
        if (!hub_status(h, n, &st))
            return 0;
        if (((st >> 16) & 0x10) || (!(st & 0x10) && (st & 2)))
            break;              /* C_PORT_RESET, or reset over and enabled */
    }
    if (st >> 16)
        hub_clear(h, n, st >> 16);
    ps = st & 0xFFFF;
    if (!(ps & 1))
        return 1;
    if (!(ps & 2)) {
        diag_add(L" %s.%u-noen", (ULONG_PTR)h->path, n, 0, 0);
        h->hfail |= bit;
        return 1;
    }
    /* xHCI speed ID: 1 full, 2 low, 3 high, 4 super */
    if (h->hss)
        i = 4;
    else
        i = (ps & 0x200) ? 2 : (ps & 0x400) ? 3 : 1;
    delay_ms(10);               /* reset recovery */
    if (!dev_enum(hc, h, n, i))
        h->hfail |= bit;
    return 1;
}

/* worker: hubs whose status change endpoint (or the slow poll) flagged
   ports. Returns 1 when the Diag line changed. */
static int hub_changes(HC *hc)
{
    int i;
    size_t n0 = wcslen(g_diag);
    hc->hubchg = 0;
    for (i = 0; i < MAXDEV; i++) {
        DEV *h = &hc->dev[i];
        ULONG m, n;
        if (!h->used || !h->ishub || !h->hchg)
            continue;
        m = h->hchg;
        h->hchg = 0;
        if (m & 1) {            /* hub status: clear C_HUB_LOCAL_POWER / C_HUB_OVER_CURRENT */
            if (control(h, 0xA0, 0, 0, 0, 4) >= 0) {
                ULONG chg = h->buf[2] | ((ULONG)h->buf[3] << 8);
                if (chg & 1)
                    control(h, 0x20, 1, 0, 0, 0);
                if (chg & 2)
                    control(h, 0x20, 1, 1, 0, 0);
            }
        }
        for (n = 1; n <= h->nports && h->used; n++)
            if ((m & (1u << n)) && !hub_port(hc, h, n))
                break;
    }
    return wcslen(g_diag) != n0;
}

/* worker, about every 2 s: every hub port is read again (covers a hub
   whose status change endpoint stopped), a hub endpoint that stopped is
   queued again */
static void hub_poll_all(HC *hc)
{
    int i;
    for (i = 0; i < MAXDEV; i++) {
        DEV *h = &hc->dev[i];
        if (!h->used || !h->ishub)
            continue;
        h->hchg |= ((1u << (h->nports + 1)) - 1) & ~1u;
        hc->hubchg = 1;
        if (!h->hlive) {
            ep_recover(h, h->hdci, &h->kring);
            queue_hub(h);
        }
    }
}

static void port_enum(HC *hc, ULONG p)
{
    volatile ULONG *ps = hc->op + 0x100 + (p - 1) * 4;
    ULONG v = *ps;
    int i;
    DEV *d = NULL;

    for (i = 0; i < MAXDEV; i++)
        if (hc->dev[i].used && !hc->dev[i].parent && hc->dev[i].port == p)
            d = &hc->dev[i];
    if (!(v & PS_CCS)) {
        if (d) {
            dev_drop(d);
            diag_add(L" p%u-gone", p, 0, 0, 0);
            diag_write();
        }
        return;
    }
    if (d)
        return;
    if (!(v & PS_PED)) {
        *ps = (v & PS_KEEP) | PS_PR;
        for (i = 0; i < 50 && !(*ps & PS_PRC); i++)
            delay_ms(5);
        *ps = (*ps & PS_KEEP) | PS_PRC;
        delay_ms(20);
        v = *ps;
        if (!(v & PS_PED)) {
            diag_add(L" p%u-noen", p, 0, 0, 0);
            return;
        }
    }
    dev_enum(hc, NULL, p, (v >> 10) & 0xF);
}

/* Enumerate the device on root port p (hub == NULL) or on port p of hub.
   Returns the device, or NULL when nothing usable is there. */
static DEV *dev_enum(HC *hc, DEV *hub, ULONG p, ULONG speed)
{
    ULONG mps0, slot, cfglen, off, cfgval;
    int i, cc, kind = 0, idx = -1;
    DEV *d = NULL;
    UCHAR *b;
    WCHAR path[24];
    ULONG_PTR pa[2];
#ifdef USOSUSB_MSC
    int last = 0;               /* 1 = bulk IN, 2 = bulk OUT just parsed (SS companion) */
#endif

    pa[0] = hub ? (ULONG_PTR)hub->path : p;
    pa[1] = p;
    wfmt(path, 24, hub ? L"%s.%u" : L"p%u", pa);
    for (i = 0; i < MAXDEV; i++)
        if (!hc->dev[i].used) {
            idx = i;
            break;
        }
    if (idx < 0) {
        diag_add(L" %s-full", (ULONG_PTR)path, 0, 0, 0);
        return NULL;
    }
    d = &hc->dev[idx];
    if (!d->out) {
        d->out = (UCHAR *)alloc_page(&d->outpa);
        d->in = (UCHAR *)alloc_page(&d->inpa);
        d->buf = (UCHAR *)alloc_page(&d->bufpa);
        if (!d->out || !d->in || !d->buf || !ring_init(&d->ep0) || !ring_init(&d->kring) || !ring_init(&d->mring)) {
            d->out = NULL;
            return NULL;
        }
#ifdef USOSUSB_MSC
        if (!ring_init(&d->sring) || !ring_init(&d->oring)) {
            d->out = NULL;
            return NULL;
        }
#endif
    }
    RtlZeroMemory(d->out, PAGE_SIZE);
    RtlZeroMemory((void *)d->ep0.v, PAGE_SIZE);
    RtlZeroMemory((void *)d->kring.v, PAGE_SIZE);
    RtlZeroMemory((void *)d->mring.v, PAGE_SIZE);
    d->ep0.idx = d->kring.idx = d->mring.idx = 0;
    d->ep0.cycle = d->kring.cycle = d->mring.cycle = 1;
    d->hc = hc;
    d->port = (UCHAR)p;
    d->speed = (UCHAR)speed;
    d->kdci = d->mdci = 0;
    RtlCopyMemory(d->path, path, sizeof(path));
    /* topology: Route String, root port, transaction translator */
    d->gone = 0;
    d->ishub = d->nports = d->hdci = d->hmps = d->hival = d->httt = d->hss = 0;
    d->hchg = d->hfail = d->hlive = 0;
    d->tthub = d->ttport = 0;
    if (hub) {
        d->parent = (UCHAR)(hub - hc->dev) + 1;
        d->rport = hub->rport;
        d->tier = (UCHAR)(hub->tier + 1);
        d->route = hub->route | ((p > 15 ? 15u : p) << (4 * hub->tier));
        if (hub->speed == 3 && speed < 3) {
            d->tthub = hub->slot;               /* LS / FS device on a high-speed hub */
            d->ttport = (UCHAR)p;
        } else if (hub->speed < 3) {
            d->tthub = hub->tthub;              /* behind a LS / FS hub: its TT */
            d->ttport = hub->ttport;
        }
    } else {
        d->parent = 0;
        d->rport = (UCHAR)p;
        d->tier = 0;
        d->route = 0;
    }
#ifdef USOSUSB_MSC
    RtlZeroMemory((void *)d->sring.v, PAGE_SIZE);
    RtlZeroMemory((void *)d->oring.v, PAGE_SIZE);
    d->sring.idx = d->oring.idx = 0;
    d->sring.cycle = d->oring.cycle = 1;
    d->sidci = d->sodci = 0;
    d->siburst = d->soburst = 0;
    d->nvol = 0;
#endif
    d->mold = 0;
    d->kleds_sent = 0xFF;
    RtlZeroMemory(d->kold, sizeof(d->kold));

    cc = hc_cmd(hc, 0, 0, TRB_ENABLE_SLOT << 10);
    slot = hc->cmd_slot;
    if (cc != CC_SUCCESS || !slot || slot > hc->maxslots) {
        diag_add(L" %s-slot%d", (ULONG_PTR)path, (ULONG)cc, 0, 0);
        return NULL;
    }
    d->slot = (UCHAR)slot;
    d->used = 1;
    hc->dcbaa[slot * 2] = d->outpa;
    hc->dcbaa[slot * 2 + 1] = 0;

    mps0 = d->speed == 4 ? 512 : d->speed == 3 ? 64 : 8;
    RtlZeroMemory(d->in, PAGE_SIZE);
    ictx(d, 0)[1] = 3;                                      /* add slot + EP0 */
    ictx(d, 1)[0] = d->route | ((ULONG)d->speed << 20) | (1u << 27);   /* route, speed, 1 context entry */
    ictx(d, 1)[1] = (ULONG)d->rport << 16;                  /* root hub port */
    ictx(d, 1)[2] = d->tthub | ((ULONG)d->ttport << 8);     /* TT hub slot / port (LS / FS behind a HS hub) */
    ictx(d, 2)[1] = (3 << 1) | (4 << 3) | (mps0 << 16);     /* CErr 3, control, max packet */
    ictx(d, 2)[2] = d->ep0.pa | 1;
    ictx(d, 2)[3] = 0;
    ictx(d, 2)[4] = 8;
    cc = hc_cmd(hc, d->inpa, 0, (TRB_ADDRESS_DEVICE << 10) | (slot << 24));
    if (cc != CC_SUCCESS) {
        diag_add(L" %s-addr%d", (ULONG_PTR)path, (ULONG)cc, 0, 0);
        dev_drop(d);
        return NULL;
    }
    delay_ms(10);
    b = d->buf;
    if (control(d, 0x80, 6, 0x0100, 0, 8) < 0) {
        diag_add(L" %s-dd", (ULONG_PTR)path, 0, 0, 0);
        dev_drop(d);
        return NULL;
    }
    d->dclass = b[4];
    if (d->speed < 3 && b[7] && b[7] != mps0) {
        RtlZeroMemory(d->in, PAGE_SIZE);
        ictx(d, 0)[1] = 2;
        ictx(d, 2)[1] = (3 << 1) | (4 << 3) | ((ULONG)b[7] << 16);
        hc_cmd(hc, d->inpa, 0, (TRB_EVALUATE_CTX << 10) | (slot << 24));
    }
    if (control(d, 0x80, 6, 0x0200, 0, 9) < 0) {
        diag_add(L" %s-cd", (ULONG_PTR)path, 0, 0, 0);
        dev_drop(d);
        return NULL;
    }
    cfglen = b[2] | (b[3] << 8);
    if (cfglen > 1000)
        cfglen = 1000;
    if (cfglen < 9 || control(d, 0x80, 6, 0x0200, 0, (USHORT)cfglen) < 0) {
        diag_add(L" %s-cd2", (ULONG_PTR)path, 0, 0, 0);
        dev_drop(d);
        return NULL;
    }
    cfgval = b[5];
    for (off = 0; off + 2 <= cfglen;) {
        ULONG L = b[off], T = b[off + 1];
        if (L < 2 || off + L > cfglen)
            break;
        if (T == 4 && L >= 9) {
            kind = (b[off + 5] == 3 && b[off + 6] == 1) ? b[off + 7] : 0;
            if (kind == 1 && d->kdci) kind = 0;
            if (kind == 2 && d->mdci) kind = 0;
            if (kind == 1) d->kintf = b[off + 2];
            if (kind == 2) d->mintf = b[off + 2];
            /* hub, alternate setting 0 (single TT), status change endpoint */
            if (!kind && b[off + 5] == 9 && b[off + 3] == 0 && !d->hdci)
                kind = 4;
#ifdef USOSUSB_MSC
            /* mass storage, SCSI transparent, bulk-only, alternate setting 0 */
            if (!kind && b[off + 3] == 0 && b[off + 5] == 8 && b[off + 6] == 6 && b[off + 7] == 0x50 && !d->sidci && !d->sodci) {
                kind = 3;
                d->sintf = b[off + 2];
            }
            last = 0;
        } else if (T == 0x30 && L >= 6) {          /* SuperSpeed endpoint companion */
            if (last == 1) d->siburst = b[off + 2];
            if (last == 2) d->soburst = b[off + 2];
            last = 0;
        } else if (T == 5 && L >= 7 && kind == 3) {
            UCHAR addr = b[off + 2], attr = b[off + 3];
            USHORT mps = (USHORT)((b[off + 4] | (b[off + 5] << 8)) & 0x7FF);
            last = 0;
            if ((attr & 3) == 2) {
                UCHAR dci = (UCHAR)((addr & 0xF) * 2 + ((addr & 0x80) ? 1 : 0));
                if ((addr & 0x80) && !d->sidci) { d->sidci = dci; d->siaddr = addr; d->simps = mps; last = 1; }
                else if (!(addr & 0x80) && !d->sodci) { d->sodci = dci; d->soaddr = addr; d->somps = mps; last = 2; }
                if (d->sidci && d->sodci)
                    kind = 0;
            }
#endif
        } else if (T == 5 && L >= 7 && kind) {
            UCHAR addr = b[off + 2], attr = b[off + 3];
            ULONG mps = (b[off + 4] | (b[off + 5] << 8)) & 0x7FF;
            if ((attr & 3) == 3 && (addr & 0x80)) {
                UCHAR dci = (UCHAR)((addr & 0xF) * 2 + 1);
                if (mps > 255) mps = 255;
                if (kind == 1) { d->kdci = dci; d->kmps = (UCHAR)mps; d->kival = b[off + 6]; }
                else if (kind == 2) { d->mdci = dci; d->mmps = (UCHAR)mps; d->mival = b[off + 6]; }
                else if (kind == 4) { d->hdci = dci; d->hmps = (UCHAR)mps; d->hival = b[off + 6]; }
                kind = 0;
            }
        }
        off += L;
    }
    if (d->hdci && (d->dclass != 9 || d->tier >= MAXTIER)) {
        if (d->dclass == 9)
            diag_add(L" %s-deep", (ULONG_PTR)path, 0, 0, 0);
        d->hdci = 0;
    }
    if (d->hdci)
        d->kdci = d->mdci = 0;  /* a hub is only a hub */
#ifdef USOSUSB_MSC
    if (d->hdci || !d->sidci || !d->sodci)
        d->sidci = d->sodci = 0;
    if (!d->kdci && !d->mdci && !d->sidci && !d->hdci) {
#else
    if (!d->kdci && !d->mdci && !d->hdci) {
#endif
        diag_add(L" %s-nohid", (ULONG_PTR)path, 0, 0, 0);
        dev_drop(d);
        return NULL;
    }
    {
        ULONG maxdci = d->kdci > d->mdci ? d->kdci : d->mdci;
        UCHAR dcis[4];
        RING *rings[4];
        UCHAR mpss[2], ivs[2];
        int k;
        dcis[0] = d->kdci; rings[0] = &d->kring; mpss[0] = d->kmps; ivs[0] = d->kival;
        dcis[1] = d->mdci; rings[1] = &d->mring; mpss[1] = d->mmps; ivs[1] = d->mival;
        dcis[2] = dcis[3] = 0;
        if (d->hdci) {                          /* hub status change endpoint on kring */
            dcis[0] = d->hdci; mpss[0] = d->hmps; ivs[0] = d->hival;
            maxdci = d->hdci;
        }
#ifdef USOSUSB_MSC
        dcis[2] = d->sidci; rings[2] = &d->sring;
        dcis[3] = d->sodci; rings[3] = &d->oring;
        if (d->sidci > maxdci) maxdci = d->sidci;
        if (d->sodci > maxdci) maxdci = d->sodci;
#endif
        RtlZeroMemory(d->in, PAGE_SIZE);
        RtlCopyMemory(ictx(d, 1), octx(d, 0), hc->ctxsz);
        ictx(d, 1)[0] = (ictx(d, 1)[0] & 0x07FFFFFF) | (maxdci << 27);
        ictx(d, 1)[3] = 0;
        ictx(d, 0)[1] = 1;
        for (k = 0; k < 4; k++) {
            ULONG *ep;
            if (!dcis[k])
                continue;
            ictx(d, 0)[1] |= 1u << dcis[k];
            ep = ictx(d, dcis[k] + 1u);
#ifdef USOSUSB_MSC
            if (k >= 2) {                                           /* bulk IN (6) / OUT (2) */
                ULONG mps = k == 2 ? d->simps : d->somps, burst = k == 2 ? d->siburst : d->soburst;
                ep[0] = 0;
                ep[1] = (3 << 1) | ((k == 2 ? 6u : 2u) << 3) | ((burst & 0xFF) << 8) | (mps << 16);
                ep[2] = rings[k]->pa | 1;
                ep[3] = 0;
                ep[4] = 3072;                                       /* average TRB length */
                continue;
            }
#endif
            ep[0] = (ULONG)xhci_interval(d->speed, ivs[k]) << 16;
            ep[1] = (3 << 1) | (7 << 3) | ((ULONG)mpss[k] << 16);    /* interrupt IN */
            ep[2] = rings[k]->pa | 1;
            ep[3] = 0;
            ep[4] = mpss[k] | ((ULONG)mpss[k] << 16);
        }
        cc = hc_cmd(hc, d->inpa, 0, (TRB_CONFIGURE_EP << 10) | (slot << 24));
        if (cc != CC_SUCCESS) {
            diag_add(L" %s-cfgep%d", (ULONG_PTR)path, (ULONG)cc, 0, 0);
            dev_drop(d);
            return NULL;
        }
    }
    control(d, 0x00, 9, (USHORT)cfgval, 0, 0);                 /* SET_CONFIGURATION */
    if (d->hdci) {
        if (!hub_start(d)) {
            dev_drop(d);
            return NULL;
        }
        diag_add(L" %s:s%uH%u%s", (ULONG_PTR)path, slot, d->nports, (ULONG_PTR)(d->hss ? L"ss" : d->speed == 3 ? L"hs" : L"fs"));
        return d;
    }
    if (d->kdci) {
        control(d, 0x21, 0x0B, 0, d->kintf, 0);                  /* SET_PROTOCOL boot */
        control(d, 0x21, 0x0A, 0, d->kintf, 0);                  /* SET_IDLE 0 */
        queue_intr(d, 1);
    }
    if (d->mdci) {
        control(d, 0x21, 0x0B, 0, d->mintf, 0);
        control(d, 0x21, 0x0A, 0, d->mintf, 0);
        queue_intr(d, 0);
    }
    diag_add(L" %s:s%u%c%c", (ULONG_PTR)path, slot, d->kdci ? L'K' : L'-', d->mdci ? L'M' : L'-');
    if (d->tthub)
        diag_add(L"/tt%u.%u", d->tthub, d->ttport, 0, 0);
#ifdef USOSUSB_MSC
    if (d->sidci) {
        diag_add(L"S", 0, 0, 0, 0);
        diag_write();
        msc_attach(d);
    }
#endif
    return d;
}

static void kbd_leds(DEV *d)
{
    PORTEXT *x = (PORTEXT *)g_kbd->DeviceExtension;
    USHORT f = x->leds.LedFlags;
    UCHAR l = (UCHAR)(((f & KEYBOARD_NUM_LOCK_ON) ? 1 : 0) | ((f & KEYBOARD_CAPS_LOCK_ON) ? 2 : 0) |
                      ((f & KEYBOARD_SCROLL_LOCK_ON) ? 4 : 0));
    if (l == d->kleds_sent)
        return;
    d->kleds_sent = l;
    d->buf[0] = l;
    control(d, 0x21, 0x09, 0x0200, d->kintf, 1);                 /* SET_REPORT output */
}

#ifdef USOSUSB_MSC
/* ------------------------------------------------------------------ */
/* USB mass storage: bulk-only transport (USB MSC BOT 1.0), SCSI       */
/* transparent commands, one removable volume device per partition.   */
/*                                                                     */
/* Everything that touches the controller runs on the worker thread:   */
/* READ / WRITE IRPs are queued to it. The mount manager is called     */
/* from a second thread (it sends IOCTLs back to the volumes, and a    */
/* file system mount may read), so the worker never waits for it.      */

#define MAXVOL 32               /* volume devices per boot (never deleted) */
#define CBW_OFF 3072            /* in the device data page */
#define CSW_OFF 3584
#define SNS_OFF 3712

typedef struct _VOL {
    ULONG magic;                /* VOL_MAGIC */
    DEV *d;                     /* NULL once the stick is gone */
    volatile LONG gone;
    ULONG start, count;         /* partition: first LBA, sectors */
    UCHAR ptype, boot, letter, index;
    USHORT namelen;             /* bytes */
    WCHAR name[40];             /* \Device\UsosUsbDiskN */
    UCHAR uid[20];
    PDEVICE_OBJECT dobj;
} VOL;
#define VOL_MAGIC 0x4C4F5655u

static PDRIVER_OBJECT g_drv;
static LIST_ENTRY g_q;          /* queued READ / WRITE IRPs */
static KSPIN_LOCK g_qlock;
static KEVENT g_wake;           /* worker: IRP queued */
static UCHAR *g_bva;            /* 64 KiB bounce buffer, 64 KiB aligned */
static ULONG g_bpa;
static ULONG g_volseq;
/* mount manager requests: volume + op (1 arrive, 0 remove) */
static VOL *g_mvol[64];
static UCHAR g_mop[64];
static ULONG g_mhead, g_mtail;
static KSPIN_LOCK g_mlock;
static KEVENT g_mwake;
static UCHAR g_mmbuf[4096];     /* mount thread only */
static UCHAR g_mmout[4096];
static WCHAR g_msc[512];        /* Parameters\Msc (mount thread only) */

static ULONG be32(const UCHAR *p) { return ((ULONG)p[0] << 24) | ((ULONG)p[1] << 16) | ((ULONG)p[2] << 8) | p[3]; }
static ULONG le32(const UCHAR *p) { return p[0] | ((ULONG)p[1] << 8) | ((ULONG)p[2] << 16) | ((ULONG)p[3] << 24); }
static void put32(UCHAR *p, ULONG v) { p[0] = (UCHAR)v; p[1] = (UCHAR)(v >> 8); p[2] = (UCHAR)(v >> 16); p[3] = (UCHAR)(v >> 24); }
static void putbe32(UCHAR *p, ULONG v) { p[0] = (UCHAR)(v >> 24); p[1] = (UCHAR)(v >> 16); p[2] = (UCHAR)(v >> 8); p[3] = (UCHAR)v; }

static int bounce_init(void)
{
    PHYSICAL_ADDRESS hi;
    UCHAR *v;
    ULONG pa, skip;
    if (g_bva)
        return 1;
    hi.QuadPart = 0x7FFFFFFF;
    v = (UCHAR *)MmAllocateContiguousMemory(0x20000, hi);
    if (!v)
        return 0;
    pa = MmGetPhysicalAddress(v).LowPart;
    skip = (0x10000 - (pa & 0xFFFF)) & 0xFFFF;
    g_bva = v + skip;
    g_bpa = pa + skip;
    return 1;
}

static int port_present(DEV *d)
{
    /* behind a hub: the root port still connected and the hub has not
       reported the device gone (hub ports are read in the worker loop) */
    return d->used && !d->gone && (d->hc->op[0x100 + (d->rport - 1) * 4] & PS_CCS) != 0;
}

/* One bulk TD (a single TRB; the buffer never crosses 64 KiB). Returns the
   completion code (CC_SUCCESS also for a short packet), or -1 after a
   timeout or an unplug (the endpoint is stopped and its ring moved on). */
static int bulk_xfer(DEV *d, int in, ULONG pa, ULONG len, ULONG *got, ULONG ms)
{
    HC *hc = d->hc;
    RING *r = in ? &d->sring : &d->oring;
    ULONG dci = in ? d->sidci : d->sodci, spins = 0;
    LONGLONG end = now_ms() + ms;
    d->blk_done = 0;
    ring_push(r, pa, 0, len, (TRB_NORMAL << 10) | (1 << 5) /* IOC */ | (in ? (1 << 2) : 0) /* ISP */);
    doorbell(hc, d->slot, dci);
    for (;;) {
        hc_poll(hc);
        if (d->blk_done)
            break;
        if (++spins < 400) {            /* about 2 ms busy, then 1 ms sleeps */
            KeStallExecutionProcessor(5);
            continue;
        }
        if (now_ms() > end || !port_present(d)) {
            hc_cmd(hc, 0, 0, (TRB_STOP_EP << 10) | (dci << 16) | ((ULONG)d->slot << 24));
            hc_cmd(hc, ring_enq_pa(r) | r->cycle, 0, (TRB_SET_TR_DEQ << 10) | (dci << 16) | ((ULONG)d->slot << 24));
            d->blk_done = 0;
            return -1;
        }
        delay_ms(1);
    }
    if (got)
        *got = d->blk_resid <= len ? len - d->blk_resid : 0;
    if (d->blk_cc == CC_SUCCESS || d->blk_cc == CC_SHORT)
        return CC_SUCCESS;
    ep_recover(d, dci, r);              /* halted: stall or transaction error */
    return (int)d->blk_cc;
}

static void clear_halt(DEV *d, UCHAR epaddr)
{
    control(d, 0x02, 1 /* CLEAR_FEATURE */, 0 /* ENDPOINT_HALT */, epaddr, 0);
}

/* Bulk-only mass storage reset + clear both halts (reset recovery). */
static void bot_reset(DEV *d)
{
    if (!port_present(d))
        return;
    control(d, 0x21, 0xFF, 0, d->sintf, 0);
    clear_halt(d, d->siaddr);
    clear_halt(d, d->soaddr);
}

/* One SCSI command over BOT. 0 = passed, 1 = failed (sense data waits),
   -1 = transport error (reset recovery done). */
static int bot_cmd(DEV *d, const UCHAR *cdb, ULONG cdblen, int in, ULONG pa, ULONG len, ULONG *got)
{
    UCHAR *cbw = d->buf + CBW_OFF, *csw = d->buf + CSW_OFF;
    ULONG n = 0, i;
    int cc;
    if (got)
        *got = 0;
    if (!port_present(d))
        return -1;
    RtlZeroMemory(cbw, 31);
    d->tag++;
    put32(cbw, 0x43425355);             /* USBC */
    put32(cbw + 4, d->tag);
    put32(cbw + 8, len);
    cbw[12] = (UCHAR)(in ? 0x80 : 0);
    cbw[13] = 0;                        /* LUN 0 */
    cbw[14] = (UCHAR)cdblen;
    RtlCopyMemory(cbw + 15, cdb, cdblen);
    cc = bulk_xfer(d, 0, d->bufpa + CBW_OFF, 31, NULL, 5000);
    if (cc != CC_SUCCESS) {
        bot_reset(d);
        return -1;
    }
    if (len) {
        cc = bulk_xfer(d, in, pa, len, &n, 20000);
        if (cc == CC_STALL)
            clear_halt(d, in ? d->siaddr : d->soaddr);
        else if (cc != CC_SUCCESS) {
            bot_reset(d);
            return -1;
        }
    }
    if (got)
        *got = n;
    for (i = 0; i < 2; i++) {
        RtlZeroMemory(csw, 13);
        n = 0;
        cc = bulk_xfer(d, 1, d->bufpa + CSW_OFF, 13, &n, 5000);
        if (cc != CC_STALL)
            break;
        clear_halt(d, d->siaddr);
    }
    if (cc != CC_SUCCESS || n != 13 || le32(csw) != 0x53425355 || le32(csw + 4) != d->tag || csw[12] > 1) {
        bot_reset(d);
        return -1;
    }
    return csw[12];
}

static void scsi_sense(DEV *d, UCHAR *key, UCHAR *asc)
{
    UCHAR cdb[6];
    UCHAR *b = d->buf + SNS_OFF;
    RtlZeroMemory(cdb, sizeof(cdb));
    cdb[0] = 0x03;                      /* REQUEST SENSE */
    cdb[4] = 18;
    *key = 0;
    *asc = 0;
    RtlZeroMemory(b, 18);
    if (bot_cmd(d, cdb, 6, 1, d->bufpa + SNS_OFF, 18, NULL) == 0) {
        *key = (UCHAR)(b[2] & 0xF);
        *asc = b[12];
    }
}

/* READ(10) / WRITE(10) of c <= 128 sectors through the bounce buffer. */
static NTSTATUS scsi_rw(DEV *d, int wr, ULONG lba, ULONG c)
{
    UCHAR cdb[10], key, asc;
    ULONG got, tries;
    int r;
    for (tries = 0; tries < 4; tries++) {
        if (!port_present(d))
            return STATUS_NO_MEDIA_IN_DEVICE;
        RtlZeroMemory(cdb, sizeof(cdb));
        cdb[0] = (UCHAR)(wr ? 0x2A : 0x28);
        putbe32(cdb + 2, lba);
        cdb[7] = (UCHAR)(c >> 8);
        cdb[8] = (UCHAR)c;
        r = bot_cmd(d, cdb, 10, !wr, g_bpa, c * 512, &got);
        if (r == 0 && got == c * 512)
            return STATUS_SUCCESS;
        if (r == 1) {
            scsi_sense(d, &key, &asc);
            if (key == 2 && asc == 0x3A)
                return STATUS_NO_MEDIA_IN_DEVICE;
            if (key == 7)
                return STATUS_MEDIA_WRITE_PROTECTED;
        }
    }
    return STATUS_IO_DEVICE_ERROR;
}

static NTSTATUS msc_rw(DEV *d, int wr, ULONG lba, ULONG n, UCHAR *va)
{
    while (n) {
        ULONG c = n > 128 ? 128 : n;
        NTSTATUS st;
        if (wr)
            RtlCopyMemory(g_bva, va, c * 512);
        st = scsi_rw(d, wr, lba, c);
        if (!NT_SUCCESS(st))
            return st;
        if (!wr)
            RtlCopyMemory(va, g_bva, c * 512);
        va += c * 512;
        lba += c;
        n -= c;
    }
    return STATUS_SUCCESS;
}

static void mount_queue(VOL *v, UCHAR op)
{
    KIRQL old;
    KeAcquireSpinLock(&g_mlock, &old);
    if (g_mtail - g_mhead < 64) {
        g_mvol[g_mtail & 63] = v;
        g_mop[g_mtail & 63] = op;
        g_mtail++;
    }
    KeReleaseSpinLock(&g_mlock, old);
    KeSetEvent(&g_mwake, 0, FALSE);
}

static int is_boot_sector(const UCHAR *s)
{
    ULONG bps = s[11] | (s[12] << 8), spc = s[13];
    if (RtlCompareMemory(s + 3, "NTFS    ", 8) == 8 || RtlCompareMemory(s + 3, "EXFAT   ", 8) == 8)
        return 1;
    return (s[0] == 0xEB || s[0] == 0xE9) && bps == 512 && spc && !(spc & (spc - 1)) &&
           s[16] >= 1 && s[16] <= 2 && (s[14] | s[15]);
}

static void vol_create(DEV *d, ULONG start, ULONG count, UCHAR ptype, UCHAR boot, ULONG sig)
{
    WCHAR name[40];
    UNICODE_STRING us;
    PDEVICE_OBJECT dobj;
    VOL *v;
    ULONG_PTR a[1];
    if (d->nvol >= 4 || g_volseq >= MAXVOL || !count)
        return;
    a[0] = g_volseq;
    wfmt(name, 40, L"\\Device\\UsosUsbDisk%u", a);
    RtlInitUnicodeString(&us, name);
    if (!NT_SUCCESS(IoCreateDevice(g_drv, sizeof(VOL), &us, FILE_DEVICE_DISK,
                                   FILE_REMOVABLE_MEDIA | FILE_DEVICE_SECURE_OPEN, FALSE, &dobj)))
        return;
    v = (VOL *)dobj->DeviceExtension;
    RtlZeroMemory(v, sizeof(*v));
    v->magic = VOL_MAGIC;
    v->d = d;
    v->start = start;
    v->count = count;
    v->ptype = ptype;
    v->boot = boot;
    v->index = (UCHAR)(d->nvol + 1);
    v->dobj = dobj;
    RtlCopyMemory(v->name, name, sizeof(name));
    v->namelen = (USHORT)(wcslen(name) * sizeof(WCHAR));
    RtlCopyMemory(v->uid, "USOSUSB:", 8);
    v->uid[8] = (UCHAR)d->vid;
    v->uid[9] = (UCHAR)(d->vid >> 8);
    v->uid[10] = (UCHAR)d->pid;
    v->uid[11] = (UCHAR)(d->pid >> 8);
    put32(v->uid + 12, sig);
    put32(v->uid + 16, start);
    dobj->Flags |= DO_DIRECT_IO;
    dobj->AlignmentRequirement = FILE_WORD_ALIGNMENT;
    dobj->SectorSize = 512;
    dobj->Flags &= ~DO_DEVICE_INITIALIZING;
    g_volseq++;
    d->vol[d->nvol++] = v;
    mount_queue(v, 1);
}

/* GPT stick (protective MBR): one volume per partition; Microsoft reserved,
   EFI system partitions (Windows gives them no letter either; keeps the
   USOS stick's ESP away from the file system) and "no drive letter" /
   hidden entries skipped; at most 4 (the USOS stick: DATA, WORK). 32-bit LBAs. */
static void gpt_volumes(DEV *d)
{
    static const UCHAR msr[16] = { 0x16, 0xE3, 0xC9, 0xE3, 0x5C, 0x0B, 0xB8, 0x4D,
                                   0x81, 0x7D, 0xF9, 0x2D, 0xF0, 0x02, 0x15, 0xAE };
    static const UCHAR esp[16] = { 0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11,
                                   0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B };
    UCHAR *h = g_bva, *e;
    ULONG elba, n, esz, sig, i, secs;
    if (!NT_SUCCESS(scsi_rw(d, 0, 1, 1)) || RtlCompareMemory(h, "EFI PART", 8) != 8)
        return;
    elba = le32(h + 72);
    n = le32(h + 80);
    esz = le32(h + 84);
    sig = le32(h + 56);                     /* disk GUID, first 4 bytes */
    if (le32(h + 76) || esz < 128 || esz > 512 || (esz & (esz - 1)) || !elba || elba >= d->blocks)
        return;
    if (n > 128)
        n = 128;
    secs = (n * esz + 511) / 512;
    if (!secs || !NT_SUCCESS(scsi_rw(d, 0, elba, secs)))
        return;
    for (i = 0; i < n && d->nvol < 4; i++) {
        ULONG first, last, k, zero = 1;
        e = g_bva + i * esz;
        for (k = 0; k < 16; k++)
            if (e[k])
                zero = 0;
        if (zero || RtlCompareMemory(e, msr, 16) == 16 || RtlCompareMemory(e, esp, 16) == 16 ||
            (e[55] & 0xC0))                 /* attribute bits 63 (no drive letter), 62 (hidden) */
            continue;
        first = le32(e + 32);
        last = le32(e + 40);
        if (le32(e + 36) || le32(e + 44) || !first || last < first || last >= d->blocks)
            continue;
        vol_create(d, first, last - first + 1, 0x07, 0, sig);
    }
}

/* worker, after SET_CONFIGURATION: bring the medium up and publish its volumes */
static void msc_attach(DEV *d)
{
    UCHAR cdb[10], *b = d->buf + SNS_OFF, *s;
    ULONG got = 0, i, sig;
    int r = -1;
    UCHAR key, asc;
    d->tag = 0;
    d->nvol = 0;
    d->wp = 0;
    d->blocks = 0;
    if (!bounce_init()) {
        diag_add(L"(nomem)", 0, 0, 0, 0);
        return;
    }
    if (control(d, 0x80, 6, 0x0100, 0, 18) >= 0) {
        d->vid = (USHORT)(d->buf[8] | (d->buf[9] << 8));
        d->pid = (USHORT)(d->buf[10] | (d->buf[11] << 8));
    }
    RtlZeroMemory(cdb, sizeof(cdb));
    cdb[0] = 0x12;                                  /* INQUIRY */
    cdb[4] = 36;
    for (i = 0; i < 3 && r != 0; i++) {
        if (i)
            delay_ms(100);
        r = bot_cmd(d, cdb, 6, 1, d->bufpa + SNS_OFF, 36, &got);
    }
    if (r != 0 || (b[0] & 0x1F) != 0) {
        diag_add(L"(inq%d/%x)", (ULONG)r, b[0], 0, 0);
        return;
    }
    for (i = 0; i < 40; i++) {                      /* TEST UNIT READY, up to ~10 s */
        RtlZeroMemory(cdb, sizeof(cdb));
        r = bot_cmd(d, cdb, 6, 0, 0, 0, NULL);
        if (r == 0)
            break;
        if (!port_present(d))
            return;
        if (r == 1) {
            scsi_sense(d, &key, &asc);
            if (key == 2 && asc == 0x3A) {
                diag_add(L"(nomedia)", 0, 0, 0, 0);
                return;
            }
        }
        delay_ms(250);
    }
    if (r != 0) {
        diag_add(L"(notready)", 0, 0, 0, 0);
        return;
    }
    RtlZeroMemory(cdb, sizeof(cdb));
    cdb[0] = 0x25;                                  /* READ CAPACITY(10) */
    r = -1;
    for (i = 0; i < 3 && r != 0; i++) {
        r = bot_cmd(d, cdb, 10, 1, d->bufpa + SNS_OFF, 8, &got);
        if (r == 1)
            scsi_sense(d, &key, &asc);
    }
    if (r != 0 || got < 8 || be32(b + 4) != 512) {
        diag_add(L"(cap%d/%u)", (ULONG)r, r == 0 ? be32(b + 4) : 0, 0, 0);
        return;
    }
    d->blocks = be32(b) == 0xFFFFFFFFu ? 0xFFFFFFFFu : be32(b) + 1;
    RtlZeroMemory(cdb, sizeof(cdb));
    cdb[0] = 0x1A;                                  /* MODE SENSE(6), all pages */
    cdb[2] = 0x3F;
    cdb[4] = 192;
    r = bot_cmd(d, cdb, 6, 1, d->bufpa + SNS_OFF, 192, &got);
    if (r == 0 && got >= 4)
        d->wp = (UCHAR)((b[2] & 0x80) ? 1 : 0);
    else if (r == 1)
        scsi_sense(d, &key, &asc);
    if (!NT_SUCCESS(scsi_rw(d, 0, 0, 1))) {
        diag_add(L"(lba0)", 0, 0, 0, 0);
        return;
    }
    s = g_bva;
    sig = le32(s + 440);
    if (s[510] == 0x55 && s[511] == 0xAA && is_boot_sector(s)) {
        /* superfloppy: the whole medium is one volume; id = volume serial */
        sig = RtlCompareMemory(s + 82, "FAT32", 5) == 5 ? le32(s + 67) : le32(s + 39);
        vol_create(d, 0, d->blocks, (UCHAR)(RtlCompareMemory(s + 3, "NTFS", 4) == 4 ? 7 : 0x0C), 0, sig);
    } else if (s[510] == 0x55 && s[511] == 0xAA) {
        int ok = 1;
        for (i = 0; i < 4; i++)
            if (s[446 + i * 16] & 0x7F)
                ok = 0;
        for (i = 0; ok && i < 4; i++) {
            const UCHAR *e = s + 446 + i * 16;
            ULONG st = le32(e + 8), n = le32(e + 12);
            UCHAR t = e[4];
            if (!t || t == 0x05 || t == 0x0F || t == 0x85 || t == 0xEE || t == 0xEF || !st || !n || st >= d->blocks)
                continue;
            if (n > d->blocks - st)
                n = d->blocks - st;
            vol_create(d, st, n, t, e[0], sig);
        }
        if (ok && s[446 + 4] == 0xEE)
            gpt_volumes(d);
    }
    diag_add(L"(%uM wp%u %uv)", d->blocks >> 11, d->wp, d->nvol, 0);
}

/* A stick that went away behaves like removed media: the file system gets
   STATUS_VERIFY_REQUIRED (DO_VERIFY_VOLUME), its verify read fails and it
   dismounts the volume, instead of retrying its write-behind for ever. */
static NTSTATUS vol_gone_status(VOL *v, PIO_STACK_LOCATION s, PIRP irp)
{
    if ((v->dobj->Flags & DO_VERIFY_VOLUME) && !(s->Flags & SL_OVERRIDE_VERIFY_VOLUME)) {
        if (irp->Tail.Overlay.Thread)
            IoSetHardErrorOrVerifyDevice(irp, v->dobj);
        return STATUS_VERIFY_REQUIRED;
    }
    return STATUS_NO_MEDIA_IN_DEVICE;
}

/* worker: the stick went away (unplug, enumeration failure) */
static void msc_detach(DEV *d)
{
    ULONG i;
    for (i = 0; i < d->nvol; i++) {
        VOL *v = d->vol[i];
        if (!v)
            continue;
        InterlockedExchange((PLONG)&v->gone, 1);
        v->dobj->Flags |= DO_VERIFY_VOLUME;
        v->d = NULL;
        d->vol[i] = NULL;
        mount_queue(v, 0);
    }
    d->nvol = 0;
    d->sidci = d->sodci = 0;
}

/* worker: one queued READ / WRITE */
static void msc_irp(PIRP irp)
{
    PIO_STACK_LOCATION s = IoGetCurrentIrpStackLocation(irp);
    VOL *v = (VOL *)s->DeviceObject->DeviceExtension;
    int wr = s->MajorFunction == IRP_MJ_WRITE;
    ULONGLONG off = (ULONGLONG)s->Parameters.Read.ByteOffset.QuadPart;
    ULONG len = s->Parameters.Read.Length;
    NTSTATUS st;
    UCHAR *va;
    DEV *d = v->d;
    irp->IoStatus.Information = 0;
    if (v->gone || !d || !d->used)
        st = vol_gone_status(v, s, irp);
    else if ((((ULONG)off | len) & 511) || (off >> 9) + (len >> 9) > v->count)
        st = STATUS_INVALID_PARAMETER;
    else if (wr && d->wp)
        st = STATUS_MEDIA_WRITE_PROTECTED;
    else if (!irp->MdlAddress || (va = (UCHAR *)MmGetSystemAddressForMdlSafe(irp->MdlAddress, NormalPagePriority)) == NULL)
        st = STATUS_INSUFFICIENT_RESOURCES;
    else {
        st = msc_rw(d, wr, v->start + (ULONG)(off >> 9), len >> 9, va);
        if (NT_SUCCESS(st))
            irp->IoStatus.Information = len;
    }
    irp->IoStatus.Status = st;
    IoCompleteRequest(irp, IO_DISK_INCREMENT);
}

/* The worker keeps LOW_REALTIME_PRIORITY (HID input must not wait behind a
   busy desktop), so a long copy rests one timer tick every 30 ms: the busy
   waits of a fast stick must not starve the other threads of that CPU. */
static void msc_service(void)
{
    static LONGLONG rest;
    PLIST_ENTRY e;
    while ((e = ExInterlockedRemoveHeadList(&g_q, &g_qlock)) != NULL) {
        LONGLONG t = now_ms();
        if (t - rest > 30) {
            if (rest && t - rest < 1000) {
                ULONG i;
                delay_ms(1);
                for (i = 0; i < (ULONG)g_nhc; i++)
                    hc_poll(&g_hc[i]);
            }
            rest = now_ms();
        }
        msc_irp(CONTAINING_RECORD(e, IRP, Tail.Overlay.ListEntry));
    }
}

static NTSTATUS vol_ioctl(VOL *v, PIO_STACK_LOCATION s, PIRP irp, PVOID sb, ULONG_PTR *info)
{
    ULONG outl = s->Parameters.DeviceIoControl.OutputBufferLength;
    LONGLONG bytes = (LONGLONG)v->count << 9;
    switch (s->Parameters.DeviceIoControl.IoControlCode) {
    case IOCTL_MOUNTDEV_QUERY_DEVICE_NAME: {
        PMOUNTDEV_NAME n = (PMOUNTDEV_NAME)sb;
        if (outl < sizeof(MOUNTDEV_NAME))
            return STATUS_INVALID_PARAMETER;
        n->NameLength = v->namelen;
        if (outl < sizeof(USHORT) + v->namelen) {
            *info = sizeof(MOUNTDEV_NAME);
            return STATUS_BUFFER_OVERFLOW;
        }
        RtlCopyMemory(n->Name, v->name, v->namelen);
        *info = sizeof(USHORT) + v->namelen;
        return STATUS_SUCCESS;
    }
    case IOCTL_MOUNTDEV_QUERY_UNIQUE_ID: {
        PMOUNTDEV_UNIQUE_ID u = (PMOUNTDEV_UNIQUE_ID)sb;
        if (outl < sizeof(MOUNTDEV_UNIQUE_ID))
            return STATUS_INVALID_PARAMETER;
        u->UniqueIdLength = sizeof(v->uid);
        if (outl < sizeof(USHORT) + sizeof(v->uid)) {
            *info = sizeof(MOUNTDEV_UNIQUE_ID);
            return STATUS_BUFFER_OVERFLOW;
        }
        RtlCopyMemory(u->UniqueId, v->uid, sizeof(v->uid));
        *info = sizeof(USHORT) + sizeof(v->uid);
        return STATUS_SUCCESS;
    }
    case IOCTL_MOUNTDEV_LINK_CREATED:
    case IOCTL_MOUNTDEV_LINK_DELETED:
        return STATUS_SUCCESS;
    case IOCTL_DISK_GET_DRIVE_GEOMETRY:
    case IOCTL_DISK_GET_MEDIA_TYPES:
    case IOCTL_STORAGE_GET_MEDIA_TYPES: {
        PDISK_GEOMETRY g = (PDISK_GEOMETRY)sb;
        if (v->gone)
            return STATUS_NO_MEDIA_IN_DEVICE;
        if (outl < sizeof(DISK_GEOMETRY))
            return STATUS_BUFFER_TOO_SMALL;
        g->MediaType = RemovableMedia;
        g->TracksPerCylinder = 255;
        g->SectorsPerTrack = 63;
        g->BytesPerSector = 512;
        g->Cylinders.QuadPart = (LONGLONG)((v->start + v->count) / (255 * 63));
        *info = sizeof(DISK_GEOMETRY);
        return STATUS_SUCCESS;
    }
    case IOCTL_DISK_GET_PARTITION_INFO: {
        PPARTITION_INFORMATION p = (PPARTITION_INFORMATION)sb;
        if (v->gone)
            return STATUS_NO_MEDIA_IN_DEVICE;
        if (outl < sizeof(PARTITION_INFORMATION))
            return STATUS_BUFFER_TOO_SMALL;
        RtlZeroMemory(p, sizeof(*p));
        p->StartingOffset.QuadPart = (LONGLONG)v->start << 9;
        p->PartitionLength.QuadPart = bytes;
        p->HiddenSectors = v->start;
        p->PartitionNumber = v->index;
        p->PartitionType = v->ptype;
        p->BootIndicator = v->boot ? TRUE : FALSE;
        p->RecognizedPartition = TRUE;
        *info = sizeof(PARTITION_INFORMATION);
        return STATUS_SUCCESS;
    }
    case IOCTL_DISK_GET_PARTITION_INFO_EX: {
        PPARTITION_INFORMATION_EX p = (PPARTITION_INFORMATION_EX)sb;
        if (v->gone)
            return STATUS_NO_MEDIA_IN_DEVICE;
        if (outl < sizeof(PARTITION_INFORMATION_EX))
            return STATUS_BUFFER_TOO_SMALL;
        RtlZeroMemory(p, sizeof(*p));
        p->PartitionStyle = PARTITION_STYLE_MBR;
        p->StartingOffset.QuadPart = (LONGLONG)v->start << 9;
        p->PartitionLength.QuadPart = bytes;
        p->PartitionNumber = v->index;
        p->Mbr.PartitionType = v->ptype;
        p->Mbr.BootIndicator = v->boot ? TRUE : FALSE;
        p->Mbr.RecognizedPartition = TRUE;
        p->Mbr.HiddenSectors = v->start;
        *info = sizeof(PARTITION_INFORMATION_EX);
        return STATUS_SUCCESS;
    }
    case IOCTL_DISK_GET_LENGTH_INFO:
        if (v->gone)
            return STATUS_NO_MEDIA_IN_DEVICE;
        if (outl < sizeof(GET_LENGTH_INFORMATION))
            return STATUS_BUFFER_TOO_SMALL;
        ((PGET_LENGTH_INFORMATION)sb)->Length.QuadPart = bytes;
        *info = sizeof(GET_LENGTH_INFORMATION);
        return STATUS_SUCCESS;
    case IOCTL_DISK_IS_WRITABLE: {
        DEV *d = v->d;
        if (v->gone || !d)
            return STATUS_NO_MEDIA_IN_DEVICE;
        return d->wp ? STATUS_MEDIA_WRITE_PROTECTED : STATUS_SUCCESS;
    }
    case IOCTL_DISK_CHECK_VERIFY:
    case IOCTL_STORAGE_CHECK_VERIFY:
    case IOCTL_STORAGE_CHECK_VERIFY2:
        if (v->gone)
            return vol_gone_status(v, s, irp);
        if (outl >= sizeof(ULONG)) {
            *(PULONG)sb = 0;                        /* media change count */
            *info = sizeof(ULONG);
        }
        return STATUS_SUCCESS;
    case IOCTL_DISK_VERIFY:
    case IOCTL_DISK_MEDIA_REMOVAL:
    case IOCTL_STORAGE_MEDIA_REMOVAL:
        return v->gone ? STATUS_NO_MEDIA_IN_DEVICE : STATUS_SUCCESS;
    case IOCTL_STORAGE_GET_HOTPLUG_INFO: {
        PSTORAGE_HOTPLUG_INFO h = (PSTORAGE_HOTPLUG_INFO)sb;
        if (outl < sizeof(STORAGE_HOTPLUG_INFO))
            return STATUS_BUFFER_TOO_SMALL;
        RtlZeroMemory(h, sizeof(*h));
        h->Size = sizeof(*h);
        h->MediaRemovable = TRUE;
        h->DeviceHotplug = TRUE;
        *info = sizeof(*h);
        return STATUS_SUCCESS;
    }
    }
    return STATUS_INVALID_DEVICE_REQUEST;
}

static NTSTATUS vol_dispatch(PDEVICE_OBJECT dobj, PIRP irp)
{
    PIO_STACK_LOCATION s = IoGetCurrentIrpStackLocation(irp);
    VOL *v = (VOL *)dobj->DeviceExtension;
    NTSTATUS st = STATUS_SUCCESS;
    ULONG_PTR info = 0;
    switch (s->MajorFunction) {
    case IRP_MJ_READ:
    case IRP_MJ_WRITE:
        if (v->gone) {
            st = vol_gone_status(v, s, irp);
            break;
        }
        if (!s->Parameters.Read.Length)
            break;
        IoMarkIrpPending(irp);
        ExInterlockedInsertTailList(&g_q, &irp->Tail.Overlay.ListEntry, &g_qlock);
        KeSetEvent(&g_wake, 0, FALSE);
        return STATUS_PENDING;
    case IRP_MJ_DEVICE_CONTROL:
        st = vol_ioctl(v, s, irp, irp->AssociatedIrp.SystemBuffer, &info);
        break;
    default:                    /* create, close, cleanup, flush, shutdown */
        break;
    }
    irp->IoStatus.Status = st;
    irp->IoStatus.Information = info;
    IoCompleteRequest(irp, IO_NO_INCREMENT);
    return st;
}

/* ---- mount manager (mount thread) ---- */

static void msc_note(const WCHAR *fmt, ULONG_PTR a, ULONG_PTR b, ULONG_PTR c)
{
    WCHAR path[300];
    ULONG_PTR args[3];
    size_t n = wcslen(g_msc);
    if (n + 64 >= sizeof(g_msc) / sizeof(WCHAR)) {
        n = 0;
        g_msc[0] = 0;
    }
    args[0] = a;
    args[1] = b;
    args[2] = c;
    wfmt(g_msc + n, sizeof(g_msc) / sizeof(WCHAR) - n, fmt, args);
    if (g_regpath.Length / sizeof(WCHAR) + 12 >= sizeof(path) / sizeof(WCHAR))
        return;
    RtlCopyMemory(path, g_regpath.Buffer, g_regpath.Length);
    RtlCopyMemory(path + g_regpath.Length / sizeof(WCHAR), L"\\Parameters", 12 * sizeof(WCHAR));
    RtlCreateRegistryKey(RTL_REGISTRY_ABSOLUTE, path);
    RtlWriteRegistryValue(RTL_REGISTRY_ABSOLUTE, path, L"Msc", REG_SZ, g_msc,
                          (ULONG)(wcslen(g_msc) + 1) * sizeof(WCHAR));
}

static NTSTATUS mm_ioctl(ULONG code, PVOID in, ULONG inl, PVOID out, ULONG outl)
{
    UNICODE_STRING n;
    PFILE_OBJECT fo;
    PDEVICE_OBJECT mm;
    KEVENT ev;
    IO_STATUS_BLOCK io;
    PIRP irp;
    NTSTATUS st;
    RtlInitUnicodeString(&n, MOUNTMGR_DEVICE_NAME);
    st = IoGetDeviceObjectPointer(&n, FILE_READ_ATTRIBUTES, &fo, &mm);
    if (!NT_SUCCESS(st))
        return st;
    KeInitializeEvent(&ev, NotificationEvent, FALSE);
    irp = IoBuildDeviceIoControlRequest(code, mm, in, inl, out, outl, FALSE, &ev, &io);
    if (!irp) {
        ObDereferenceObject(fo);
        return STATUS_INSUFFICIENT_RESOURCES;
    }
    st = IoCallDriver(mm, irp);
    if (st == STATUS_PENDING) {
        KeWaitForSingleObject(&ev, Executive, KernelMode, FALSE, NULL);
        st = io.Status;
    }
    ObDereferenceObject(fo);
    return st;
}

/* g_mmbuf = a MOUNTMGR_MOUNT_POINT that names the volume's device */
static ULONG mm_point(VOL *v)
{
    PMOUNTMGR_MOUNT_POINT mp = (PMOUNTMGR_MOUNT_POINT)g_mmbuf;
    RtlZeroMemory(mp, sizeof(*mp));
    mp->DeviceNameOffset = sizeof(*mp);
    mp->DeviceNameLength = v->namelen;
    RtlCopyMemory(g_mmbuf + sizeof(*mp), v->name, v->namelen);
    return sizeof(*mp) + v->namelen;
}

/* the volume's drive letter in the mount manager, 0 if none */
static WCHAR mm_letter(VOL *v)
{
    PMOUNTMGR_MOUNT_POINTS pts = (PMOUNTMGR_MOUNT_POINTS)g_mmout;
    ULONG inl = mm_point(v), i;
    RtlZeroMemory(g_mmout, sizeof(g_mmout));
    if (!NT_SUCCESS(mm_ioctl(IOCTL_MOUNTMGR_QUERY_POINTS, g_mmbuf, inl, g_mmout, sizeof(g_mmout))))
        return 0;
    for (i = 0; i < pts->NumberOfMountPoints; i++) {
        PMOUNTMGR_MOUNT_POINT p = &pts->MountPoints[i];
        const WCHAR *l = (const WCHAR *)(g_mmout + p->SymbolicLinkNameOffset);
        if ((ULONG)(UCHAR *)(p + 1) > (ULONG)(g_mmout + sizeof(g_mmout)) ||
            p->SymbolicLinkNameOffset + p->SymbolicLinkNameLength > sizeof(g_mmout))
            break;
        if (p->SymbolicLinkNameLength == 14 * sizeof(WCHAR) &&
            RtlCompareMemory(l, L"\\DosDevices\\", 12 * sizeof(WCHAR)) == 12 * sizeof(WCHAR) && l[13] == L':')
            return l[12];
    }
    return 0;
}

/* a letter nobody uses now and the mount manager keeps for no other volume */
static int letter_free(VOL *v, WCHAR c)
{
    WCHAR link[16];
    UNICODE_STRING us;
    OBJECT_ATTRIBUTES oa;
    HANDLE h;
    NTSTATUS st;
    UCHAR kv[sizeof(KEY_VALUE_PARTIAL_INFORMATION) + 64];
    ULONG got;
    RtlCopyMemory(link, L"\\DosDevices\\X:", 15 * sizeof(WCHAR));
    link[12] = c;
    RtlInitUnicodeString(&us, link);
    InitializeObjectAttributes(&oa, &us, OBJ_CASE_INSENSITIVE | OBJ_KERNEL_HANDLE, NULL, NULL);
    if (NT_SUCCESS(ZwOpenSymbolicLinkObject(&h, GENERIC_READ, &oa))) {
        ZwClose(h);
        return 0;
    }
    RtlInitUnicodeString(&us, L"\\Registry\\Machine\\SYSTEM\\MountedDevices");
    InitializeObjectAttributes(&oa, &us, OBJ_CASE_INSENSITIVE | OBJ_KERNEL_HANDLE, NULL, NULL);
    if (!NT_SUCCESS(ZwOpenKey(&h, KEY_READ, &oa)))
        return 1;
    RtlInitUnicodeString(&us, link);
    st = ZwQueryValueKey(h, &us, KeyValuePartialInformation, kv, sizeof(kv), &got);
    ZwClose(h);
    if (st == STATUS_OBJECT_NAME_NOT_FOUND)
        return 1;
    if (NT_SUCCESS(st)) {
        PKEY_VALUE_PARTIAL_INFORMATION p = (PKEY_VALUE_PARTIAL_INFORMATION)kv;
        if (p->DataLength == sizeof(v->uid) && RtlCompareMemory(p->Data, v->uid, sizeof(v->uid)) == sizeof(v->uid))
            return 1;
    }
    return 0;
}

static void mnt_arrive(VOL *v)
{
    PMOUNTMGR_TARGET_NAME t = (PMOUNTMGR_TARGET_NAME)g_mmbuf;
    NTSTATUS st;
    WCHAR c = 0, k;
    int set = 0;
    t->DeviceNameLength = v->namelen;
    RtlCopyMemory(t->DeviceName, v->name, v->namelen);
    st = mm_ioctl(IOCTL_MOUNTMGR_VOLUME_ARRIVAL_NOTIFICATION, t, sizeof(USHORT) + v->namelen, NULL, 0);
    if (!v->gone)
        c = mm_letter(v);
    for (k = L'D'; !c && !v->gone && k <= L'Z'; k++) {
        PMOUNTMGR_CREATE_POINT_INPUT cp = (PMOUNTMGR_CREATE_POINT_INPUT)g_mmbuf;
        WCHAR link[16];
        if (!letter_free(v, k))
            continue;
        RtlCopyMemory(link, L"\\DosDevices\\X:", 15 * sizeof(WCHAR));
        link[12] = k;
        cp->SymbolicLinkNameOffset = sizeof(*cp);
        cp->SymbolicLinkNameLength = 14 * sizeof(WCHAR);
        cp->DeviceNameOffset = (USHORT)(sizeof(*cp) + 14 * sizeof(WCHAR));
        cp->DeviceNameLength = v->namelen;
        RtlCopyMemory(g_mmbuf + cp->SymbolicLinkNameOffset, link, 14 * sizeof(WCHAR));
        RtlCopyMemory(g_mmbuf + cp->DeviceNameOffset, v->name, v->namelen);
        if (NT_SUCCESS(mm_ioctl(IOCTL_MOUNTMGR_CREATE_POINT, cp, cp->DeviceNameOffset + v->namelen, NULL, 0))) {
            c = k;
            set = 1;
        }
    }
    v->letter = (UCHAR)c;
    msc_note(set ? L"%s:%x+%c " : L"%s:%x=%c ", (ULONG_PTR)(v->name + 8), (ULONG)st, c ? c : L'-');
}

/* Make the file system notice the removal now: a volume open runs its
   verify (DO_VERIFY_VOLUME is set), which fails, so it dismounts. */
static void vol_kick(VOL *v)
{
    UNICODE_STRING us;
    OBJECT_ATTRIBUTES oa;
    IO_STATUS_BLOCK io;
    HANDLE h;
    us.Buffer = v->name;
    us.Length = v->namelen;
    us.MaximumLength = sizeof(v->name);
    InitializeObjectAttributes(&oa, &us, OBJ_CASE_INSENSITIVE | OBJ_KERNEL_HANDLE, NULL, NULL);
    if (NT_SUCCESS(ZwCreateFile(&h, FILE_READ_DATA | SYNCHRONIZE, &oa, &io, NULL, 0,
                                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, FILE_OPEN,
                                FILE_SYNCHRONOUS_IO_NONALERT, NULL, 0)))
        ZwClose(h);
}

static void mnt_remove(VOL *v)
{
    NTSTATUS st;
    vol_kick(v);
    st = mm_ioctl(IOCTL_MOUNTMGR_DELETE_POINTS, g_mmbuf, mm_point(v), g_mmout, sizeof(g_mmout));
    msc_note(L"%s:gone%x ", (ULONG_PTR)(v->name + 8), (ULONG)st, 0);
    v->letter = 0;
}

static VOID mount_thread(PVOID ctx)
{
    UNREFERENCED_PARAMETER(ctx);
    IoSetThreadHardErrorMode(FALSE);    /* no "insert a disk" pop-ups for a stick that is gone */
    for (;;) {
        VOL *v;
        UCHAR op = 0;
        KIRQL old;
        KeWaitForSingleObject(&g_mwake, Executive, KernelMode, FALSE, NULL);
        for (;;) {
            KeAcquireSpinLock(&g_mlock, &old);
            v = NULL;
            if (g_mhead != g_mtail) {
                v = g_mvol[g_mhead & 63];
                op = g_mop[g_mhead & 63];
                g_mhead++;
            }
            KeReleaseSpinLock(&g_mlock, old);
            if (!v)
                break;
            if (op)
                mnt_arrive(v);
            else
                mnt_remove(v);
        }
    }
}
#endif /* USOSUSB_MSC */

/* ------------------------------------------------------------------ */
/* controller                                                          */

static int wait_reg(volatile ULONG *r, ULONG mask, ULONG want, ULONG ms)
{
    ULONG i;
    for (i = 0; i < ms * 10; i++) {
        if ((*r & mask) == want)
            return 1;
        KeStallExecutionProcessor(100);
    }
    return 0;
}

static int hc_start(HC *hc, ULONG pciaddr)
{
    ULONG bar0 = pci_read(pciaddr, 0x10), bar1 = pci_read(pciaddr, 0x14), cmd, cap, i;
    ULONG hcs1, hcs2, hcc1, nsp, xecp, pagesz;
    PHYSICAL_ADDRESS pa;
    volatile ULONG *spa;
    ULONG spapa;

    hc->pciaddr = pciaddr;
    if ((bar0 & 6) == 4 && bar1) {
        diag_add(L" hc:bar64", 0, 0, 0, 0);
        return 0;
    }
    /* D0, memory + bus master */
    cap = pci_read(pciaddr, 0x34) & 0xFC;
    for (i = 0; cap && i < 48; i++) {
        ULONG h = pci_read(pciaddr, cap);
        if ((h & 0xFF) == 1) {
            ULONG pm = pci_read(pciaddr, cap + 4);
            if (pm & 3) {
                pci_write(pciaddr, cap + 4, pm & ~3u);
                delay_ms(10);
            }
            break;
        }
        cap = (h >> 8) & 0xFC;
    }
    cmd = pci_read(pciaddr, 4);
    pci_write(pciaddr, 4, (cmd & 0xFFFF) | 6);
    pa.QuadPart = bar0 & ~0xFu;
    hc->base = (volatile UCHAR *)MmMapIoSpace(pa, 0x10000, MmNonCached);
    if (!hc->base)
        return 0;
    hcs1 = *(volatile ULONG *)(hc->base + 4);
    hcs2 = *(volatile ULONG *)(hc->base + 8);
    hcc1 = *(volatile ULONG *)(hc->base + 0x10);
    hc->op = (volatile ULONG *)(hc->base + (*(volatile ULONG *)hc->base & 0xFF));
    hc->db = (volatile ULONG *)(hc->base + (*(volatile ULONG *)(hc->base + 0x14) & ~3u));
    hc->ir0 = (volatile ULONG *)(hc->base + (*(volatile ULONG *)(hc->base + 0x18) & ~0x1Fu) + 0x20);
    hc->maxslots = hcs1 & 0xFF;
    hc->maxports = (hcs1 >> 24) & 0xFF;
    if (hc->maxports > 31)
        hc->maxports = 31;
    if (hc->maxslots > MAXDEV)
        hc->maxslots = MAXDEV;
    hc->ctxsz = (hcc1 & 4) ? 64 : 32;

    /* firmware -> OS handoff (USBLEGSUP), forced when the firmware does not answer */
    xecp = ((hcc1 >> 16) & 0xFFFF) * 4;
    for (i = 0; xecp && i < 64; i++) {
        volatile ULONG *x = (volatile ULONG *)(hc->base + xecp);
        ULONG v = *x;
        if ((v & 0xFF) == 1) {
            if (v & (1u << 16)) {
                *x = v | (1u << 24);
                if (!wait_reg(x, 1u << 16, 0, 1000)) {
                    *x = (*x & ~(1u << 16)) | (1u << 24);
                    diag_add(L" forced", 0, 0, 0, 0);
                }
            } else {
                *x = v | (1u << 24);
            }
            x[1] = (x[1] & ~0x0000E011u) | 0xE0000000;   /* SMI enables off, RW1C status cleared */
            break;
        }
        if (!((v >> 8) & 0xFF))
            break;
        xecp += ((v >> 8) & 0xFF) * 4;
    }

    /* stop, reset */
    hc->op[0] &= ~1u;
    if (!wait_reg(hc->op + 1, 1, 1, 100))
        diag_add(L" nohalt", 0, 0, 0, 0);
    hc->op[0] |= 2;
    delay_ms(2);
    if (!wait_reg(hc->op, 2, 0, 1000) || !wait_reg(hc->op + 1, 1u << 11, 0, 1000)) {
        diag_add(L" hc:reset-timeout", 0, 0, 0, 0);
        return 0;
    }
    pagesz = hc->op[2] & 0xFFFF;
    if (!(pagesz & 1)) {
        diag_add(L" hc:pagesize%x", pagesz, 0, 0, 0);
        return 0;
    }
    hc->op[0xE] = hc->maxslots;                                 /* CONFIG */

    hc->dcbaa = (volatile ULONG *)alloc_page(&hc->dcbaapa);
    if (!hc->dcbaa || !ring_init(&hc->cmd))
        return 0;
    nsp = ((hcs2 >> 27) & 0x1F) | (((hcs2 >> 21) & 0x1F) << 5);
    if (nsp) {
        if (nsp > 256)
            return 0;
        spa = (volatile ULONG *)alloc_page(&spapa);
        if (!spa)
            return 0;
        for (i = 0; i < nsp; i++) {
            ULONG p;
            if (!alloc_page(&p))
                return 0;
            spa[i * 2] = p;
            spa[i * 2 + 1] = 0;
        }
        hc->dcbaa[0] = spapa;
        hc->dcbaa[1] = 0;
    }
    write64(hc->op + 0xC, hc->dcbaapa);                         /* DCBAAP */
    write64(hc->op + 6, hc->cmd.pa | 1);                        /* CRCR, RCS = 1 */

    {
        ULONG erstpa;
        volatile ULONG *erst = (volatile ULONG *)alloc_page(&erstpa);
        hc->evt = (volatile ULONG *)alloc_page(&hc->evtpa);
        if (!erst || !hc->evt)
            return 0;
        erst[0] = hc->evtpa;
        erst[1] = 0;
        erst[2] = RING_TRBS;
        erst[3] = 0;
        hc->evidx = 0;
        hc->evcycle = 1;
        hc->ir0[0] = 1;                                         /* IMAN: clear IP, IE off */
        hc->ir0[2] = 1;                                         /* ERSTSZ */
        write64(hc->ir0 + 6, hc->evtpa);                        /* ERDP */
        write64(hc->ir0 + 4, erstpa);                           /* ERSTBA */
    }
    hc->op[0] = (hc->op[0] & ~(1u << 2)) | 1;                   /* run, no interrupts */
    if (!wait_reg(hc->op + 1, 1, 0, 100)) {
        diag_add(L" hc:norun", 0, 0, 0, 0);
        return 0;
    }
    for (i = 1; i <= hc->maxports; i++) {
        volatile ULONG *ps = hc->op + 0x100 + (i - 1) * 4;
        if (!(*ps & PS_PP))
            *ps = (*ps & PS_KEEP) | PS_PP;
    }
    hc->ok = 1;
    return 1;
}

static void port_changes(HC *hc)
{
    ULONG p, mask = hc->portchg;
    hc->portchg = 0;
    for (p = 1; p <= hc->maxports; p++) {
        volatile ULONG *ps;
        ULONG v;
        if (!(mask & (1u << p)))
            continue;
        ps = hc->op + 0x100 + (p - 1) * 4;
        v = *ps;
        if (v & PS_CHANGES)
            *ps = (v & PS_KEEP) | (v & PS_CHANGES);
#ifdef USOSUSB_MSC
        if (v & 0x00020000) {   /* CSC: a device that was here is gone, even if another one is plugged in already */
            int k;
            for (k = 0; k < MAXDEV; k++)
                if (hc->dev[k].used && !hc->dev[k].parent && hc->dev[k].port == p) {
                    dev_drop(&hc->dev[k]);
                    diag_add(L" p%u-gone", p, 0, 0, 0);
                }
        }
#endif
        port_enum(hc, p);
    }
}

static VOID worker(PVOID ctx)
{
    ULONG bus, dv, fn, i;
    LONG seq = 0;
    LONGLONG hub_next = 0;
#ifdef USOSUSB_NT6
    ULONG tick = 0, conn_last = 0xFFFFFFFFu;
#endif
    UNREFERENCED_PARAMETER(ctx);
    KeSetPriorityThread(KeGetCurrentThread(), LOW_REALTIME_PRIORITY);

    g_diag[0] = 0;
    diag_add(L"%s:", (ULONG_PTR)USOSUSB_VERSION, 0, 0, 0);
    for (bus = 0; bus < 256 && g_nhc < MAXHC; bus++)
        for (dv = 0; dv < 32 && g_nhc < MAXHC; dv++)
            for (fn = 0; fn < 8 && g_nhc < MAXHC; fn++) {
                ULONG a = 0x80000000u | (bus << 16) | (dv << 11) | (fn << 8);
                ULONG id = pci_read(a, 0), cls, hdr;
                if ((id & 0xFFFF) == 0xFFFF || (id & 0xFFFF) == 0) {
                    if (fn == 0)
                        break;
                    continue;
                }
                cls = pci_read(a, 8) >> 8;
                if (cls == 0x0C0330) {
                    HC *hc = &g_hc[g_nhc];
                    hc->vid = (USHORT)id;
                    hc->did = (USHORT)(id >> 16);
                    diag_add(L" hc%u=%02x:%02x.%u", g_nhc, bus, dv, fn);
#ifdef USOSUSB_NT31
                    diag_write();
#endif
                    if (hc_start(hc, a)) {
                        diag_add(L"(%u ports)", hc->maxports, 0, 0, 0);
                        g_nhc++;
                    } else {
                        diag_add(L"(failed)", 0, 0, 0, 0);
                    }
                }
                hdr = pci_read(a, 0x0C) >> 16;
                if (fn == 0 && !(hdr & 0x80))
                    break;
            }
    if (!g_nhc)
        diag_add(L" no-xhci", 0, 0, 0, 0);
    diag_write();
    delay_ms(150);
    for (i = 0; i < (ULONG)g_nhc; i++)
        g_hc[i].portchg = 0xFFFFFFFEu;
    for (;;) {
        int changed = 0;
        for (i = 0; i < (ULONG)g_nhc; i++) {
            HC *hc = &g_hc[i];
            hc_poll(hc);
            if (hc->portchg) {
                port_changes(hc);
                changed = 1;
            }
            if (hc->hubchg && hub_changes(hc))
                changed = 1;
        }
        if (now_ms() >= hub_next) {
            hub_next = now_ms() + 2000;
            for (i = 0; i < (ULONG)g_nhc; i++)
                hub_poll_all(&g_hc[i]);
        }
        if (changed)
            diag_write();
        if (seq != g_ledseq) {
            seq = g_ledseq;
            for (i = 0; i < (ULONG)g_nhc; i++) {
                int k;
                for (k = 0; k < MAXDEV; k++)
                    if (g_hc[i].dev[k].used && g_hc[i].dev[k].kdci)
                        kbd_leds(&g_hc[i].dev[k]);
            }
        }
        kbd_repeat();
#ifdef USOSUSB_MSC
        msc_service();
#endif
#ifdef USOSUSB_NT6
        if (++tick >= 250) {
            ULONG sum = (ULONG)g_connseq + g_kbd_sent + g_mou_sent;
            tick = 0;
            if (sum != conn_last) {
                conn_last = sum;
                conn_write();
            }
        }
#endif
#ifdef USOSUSB_MSC
        {
            LARGE_INTEGER t;
            t.QuadPart = -80000;                /* 8 ms, or at once for queued I/O */
            KeWaitForSingleObject(&g_wake, Executive, KernelMode, FALSE, &t);
        }
#else
        delay_ms(8);
#endif
    }
}

/* ------------------------------------------------------------------ */
/* port devices                                                        */

static NTSTATUS dispatch(PDEVICE_OBJECT dobj, PIRP irp)
{
    PIO_STACK_LOCATION s = IoGetCurrentIrpStackLocation(irp);
    PORTEXT *x = (PORTEXT *)dobj->DeviceExtension;
    NTSTATUS st = STATUS_SUCCESS;
    ULONG info = 0, code, inl, outl;
    PVOID sb = irp->AssociatedIrp.SystemBuffer;

#ifdef USOSUSB_MSC
    if (dobj != g_kbd && dobj != g_mou)
        return vol_dispatch(dobj, irp);
#endif
    if (s->MajorFunction == IRP_MJ_INTERNAL_DEVICE_CONTROL || s->MajorFunction == IRP_MJ_DEVICE_CONTROL) {
        code = s->Parameters.DeviceIoControl.IoControlCode;
        inl = s->Parameters.DeviceIoControl.InputBufferLength;
        outl = s->Parameters.DeviceIoControl.OutputBufferLength;
        switch (code) {
        case IOCTL_INTERNAL_KEYBOARD_CONNECT:
        case IOCTL_INTERNAL_MOUSE_CONNECT:
            if (x->connected)
                st = STATUS_SHARING_VIOLATION;
            else if (inl < sizeof(CONNECT_DATA) || !s->Parameters.DeviceIoControl.Type3InputBuffer)
                st = STATUS_INVALID_PARAMETER;
            else {
                x->conn = *(PCONNECT_DATA)s->Parameters.DeviceIoControl.Type3InputBuffer;
                x->connected = 1;
#ifdef USOSUSB_NT6
                InterlockedIncrement((PLONG)&g_connseq);
#endif
            }
            break;
        case IOCTL_INTERNAL_KEYBOARD_DISCONNECT:
        case IOCTL_INTERNAL_MOUSE_DISCONNECT:
            st = STATUS_NOT_IMPLEMENTED;
            break;
        case IOCTL_INTERNAL_KEYBOARD_ENABLE:
        case IOCTL_INTERNAL_MOUSE_ENABLE:
            InterlockedIncrement(&x->enabled);
            x->enable_seen = 1;
#ifdef USOSUSB_NT6
            InterlockedIncrement((PLONG)&g_connseq);
#endif
            break;
        case IOCTL_INTERNAL_KEYBOARD_DISABLE:
        case IOCTL_INTERNAL_MOUSE_DISABLE:
            if (x->enabled > 0)
                InterlockedDecrement(&x->enabled);
            x->enable_seen = 1;
#ifdef USOSUSB_NT6
            InterlockedIncrement((PLONG)&g_connseq);
#endif
            break;
        case IOCTL_KEYBOARD_QUERY_ATTRIBUTES:
            if (outl < sizeof(KEYBOARD_ATTRIBUTES))
                st = STATUS_BUFFER_TOO_SMALL;
            else {
                PKEYBOARD_ATTRIBUTES a = (PKEYBOARD_ATTRIBUTES)sb;
                RtlZeroMemory(a, sizeof(*a));
                a->KeyboardIdentifier.Type = 4;                 /* 101/102-key enhanced */
                a->KeyboardMode = 1;                            /* scan code set 1 */
                a->NumberOfFunctionKeys = 12;
                a->NumberOfIndicators = 3;
                a->NumberOfKeysTotal = 101;
                a->InputDataQueueLength = 100;
                a->KeyRepeatMinimum.Rate = 2;
                a->KeyRepeatMinimum.Delay = 250;
                a->KeyRepeatMaximum.Rate = 30;
                a->KeyRepeatMaximum.Delay = 1000;
                info = sizeof(*a);
            }
            break;
        case IOCTL_KEYBOARD_QUERY_TYPEMATIC:
            if (outl < sizeof(KEYBOARD_TYPEMATIC_PARAMETERS))
                st = STATUS_BUFFER_TOO_SMALL;
            else {
                *(PKEYBOARD_TYPEMATIC_PARAMETERS)sb = x->typematic;
                info = sizeof(KEYBOARD_TYPEMATIC_PARAMETERS);
            }
            break;
        case IOCTL_KEYBOARD_SET_TYPEMATIC:
            if (inl < sizeof(KEYBOARD_TYPEMATIC_PARAMETERS))
                st = STATUS_INVALID_PARAMETER;
            else
                x->typematic = *(PKEYBOARD_TYPEMATIC_PARAMETERS)sb;
            break;
        case IOCTL_KEYBOARD_QUERY_INDICATORS:
            if (outl < sizeof(KEYBOARD_INDICATOR_PARAMETERS))
                st = STATUS_BUFFER_TOO_SMALL;
            else {
                *(PKEYBOARD_INDICATOR_PARAMETERS)sb = x->leds;
                info = sizeof(KEYBOARD_INDICATOR_PARAMETERS);
            }
            break;
        case IOCTL_KEYBOARD_SET_INDICATORS:
            if (inl < sizeof(KEYBOARD_INDICATOR_PARAMETERS))
                st = STATUS_INVALID_PARAMETER;
            else {
                x->leds = *(PKEYBOARD_INDICATOR_PARAMETERS)sb;
                InterlockedIncrement((PLONG)&g_ledseq);
            }
            break;
        case IOCTL_KEYBOARD_QUERY_INDICATOR_TRANSLATION: {
            ULONG need = FIELD_OFFSET(KEYBOARD_INDICATOR_TRANSLATION, IndicatorList) + 3 * sizeof(INDICATOR_LIST);
            if (outl < need)
                st = STATUS_BUFFER_TOO_SMALL;
            else {
                PKEYBOARD_INDICATOR_TRANSLATION t = (PKEYBOARD_INDICATOR_TRANSLATION)sb;
                t->NumberOfIndicatorKeys = 3;
                t->IndicatorList[0].MakeCode = 0x3A;
                t->IndicatorList[0].IndicatorFlags = KEYBOARD_CAPS_LOCK_ON;
                t->IndicatorList[1].MakeCode = 0x45;
                t->IndicatorList[1].IndicatorFlags = KEYBOARD_NUM_LOCK_ON;
                t->IndicatorList[2].MakeCode = 0x46;
                t->IndicatorList[2].IndicatorFlags = KEYBOARD_SCROLL_LOCK_ON;
                info = need;
            }
            break;
        }
        case IOCTL_MOUSE_QUERY_ATTRIBUTES:
            if (outl < sizeof(MOUSE_ATTRIBUTES))
                st = STATUS_BUFFER_TOO_SMALL;
            else {
                PMOUSE_ATTRIBUTES a = (PMOUSE_ATTRIBUTES)sb;
                a->MouseIdentifier = MOUSE_I8042_HARDWARE;
                a->NumberOfButtons = 3;
                a->SampleRate = 100;
                a->InputDataQueueLength = 100;
                info = sizeof(*a);
            }
            break;
        default:
            st = STATUS_INVALID_DEVICE_REQUEST;
            break;
        }
    }
    irp->IoStatus.Status = st;
    irp->IoStatus.Information = info;
    IoCompleteRequest(irp, IO_NO_INCREMENT);
    return st;
}

static PDEVICE_OBJECT make_port(PDRIVER_OBJECT drv, const WCHAR *base, const WCHAR *mapkey, int keyboard)
{
    WCHAR name[64];
    UNICODE_STRING us;
    PDEVICE_OBJECT d = NULL;
    NTSTATUS st;
    int n;
    for (n = 0; n < 10; n++) {
        ULONG_PTR args[2];
        args[0] = (ULONG_PTR)base;
        args[1] = (ULONG_PTR)n;
        wfmt(name, 64, L"\\Device\\%s%u", args);
        RtlInitUnicodeString(&us, name);
        st = IoCreateDevice(drv, sizeof(PORTEXT), &us, FILE_DEVICE_8042_PORT, 0, FALSE, &d);
        if (NT_SUCCESS(st))
            break;
        d = NULL;
        if (st != STATUS_OBJECT_NAME_COLLISION && st != STATUS_OBJECT_NAME_EXISTS)
            return NULL;
    }
    if (!d)
        return NULL;
    d->Flags |= DO_BUFFERED_IO;
    RtlZeroMemory(d->DeviceExtension, sizeof(PORTEXT));
    ((PORTEXT *)d->DeviceExtension)->keyboard = keyboard;
    ((PORTEXT *)d->DeviceExtension)->typematic.Rate = 30;
    ((PORTEXT *)d->DeviceExtension)->typematic.Delay = 250;
    RtlCreateRegistryKey(RTL_REGISTRY_DEVICEMAP, (PWSTR)mapkey);
    RtlWriteRegistryValue(RTL_REGISTRY_DEVICEMAP, mapkey, name, REG_SZ, g_regbuf,
                          (ULONG)(wcslen(g_regbuf) + 1) * sizeof(WCHAR));
    d->Flags &= ~DO_DEVICE_INITIALIZING;
    return d;
}

NTSTATUS DriverEntry(PDRIVER_OBJECT drv, PUNICODE_STRING reg)
{
    HANDLE th;
    NTSTATUS st;
    ULONG n = reg->Length / sizeof(WCHAR);
    if (n >= sizeof(g_regbuf) / sizeof(WCHAR))
        n = sizeof(g_regbuf) / sizeof(WCHAR) - 1;
    RtlCopyMemory(g_regbuf, reg->Buffer, n * sizeof(WCHAR));
    g_regbuf[n] = 0;
    g_regpath.Buffer = g_regbuf;
    g_regpath.Length = (USHORT)(n * sizeof(WCHAR));
    g_regpath.MaximumLength = sizeof(g_regbuf);

    drv->MajorFunction[IRP_MJ_CREATE] = dispatch;
    drv->MajorFunction[IRP_MJ_CLOSE] = dispatch;
    drv->MajorFunction[IRP_MJ_DEVICE_CONTROL] = dispatch;
    drv->MajorFunction[IRP_MJ_INTERNAL_DEVICE_CONTROL] = dispatch;
#ifdef USOSUSB_MSC
    g_drv = drv;
    InitializeListHead(&g_q);
    KeInitializeSpinLock(&g_qlock);
    KeInitializeSpinLock(&g_mlock);
    KeInitializeEvent(&g_wake, SynchronizationEvent, FALSE);
    KeInitializeEvent(&g_mwake, SynchronizationEvent, FALSE);
    drv->MajorFunction[IRP_MJ_READ] = dispatch;
    drv->MajorFunction[IRP_MJ_WRITE] = dispatch;
    drv->MajorFunction[IRP_MJ_CLEANUP] = dispatch;
    drv->MajorFunction[IRP_MJ_FLUSH_BUFFERS] = dispatch;
    drv->MajorFunction[IRP_MJ_SHUTDOWN] = dispatch;
#endif

#ifdef USOSUSB_NT31
    /* NT 3.1 bring-up: a Diag line at once, so a stop before the worker
       still shows how far DriverEntry came. */
    g_diag[0] = 0;
    diag_add(L"%s: entry", (ULONG_PTR)USOSUSB_VERSION, 0, 0, 0);
    diag_write();
#endif
    g_kbd = make_port(drv, L"KeyboardPort", L"KeyboardPort", 1);
    g_mou = make_port(drv, L"PointerPort", L"PointerPort", 0);
#ifdef USOSUSB_NT31
    diag_add(L" kbd=%u mou=%u", (ULONG_PTR)(g_kbd != NULL), (ULONG_PTR)(g_mou != NULL), 0, 0);
    diag_write();
#endif
    if (!g_kbd && !g_mou)
        return STATUS_NO_SUCH_DEVICE;
    st = PsCreateSystemThread(&th, THREAD_ALL_ACCESS, NULL, NULL, NULL, worker, NULL);
    if (NT_SUCCESS(st))
        ZwClose(th);
#ifdef USOSUSB_MSC
    if (NT_SUCCESS(PsCreateSystemThread(&th, THREAD_ALL_ACCESS, NULL, NULL, NULL, mount_thread, NULL)))
        ZwClose(th);
#endif
    return STATUS_SUCCESS;
}
