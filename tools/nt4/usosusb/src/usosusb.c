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
 *  - Devices on root ports only (no hubs): enable slot, address, read the
 *    device and configuration descriptors, pick the first HID boot keyboard
 *    and boot mouse interface, configure their interrupt IN endpoint,
 *    SET_PROTOCOL(boot), SET_IDLE(0). Hot plug through port status events.
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
#define USOSUSB_VERSION L"usosusb 1.0-nt31"
#elif defined(USOSUSB_NT6)
/* Vista / Server 2008 SP2 x86 (build-nt6.cmd): same legacy port devices;
   kbdclass / mouclass connect them as legacy ports (\Device\KeyboardClassLegacyN,
   \Device\PointerClassLegacyN, which win32k opens). PCI configuration goes
   through the HAL (its lock; other CPUs run), input is sent once a class
   driver connected even before its ENABLE, and a Conn value shows the
   connect / enable state. */
#pragma warning(disable:4996)   /* HalGetBusDataByOffset is marked obsolete */
#define USOSUSB_VERSION L"usosusb 1.0-nt6"
#else
#define USOSUSB_VERSION L"usosusb 1.0-nt4"
#endif

#define MAXHC 4
#define MAXDEV 16
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
static WCHAR g_diag[512];
static volatile LONG g_ledseq;
#ifdef USOSUSB_NT6
static volatile LONG g_connseq;  /* bumped on connect / enable / disable */
static ULONG g_kbd_sent, g_mou_sent;   /* input records passed to the class drivers */
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
    if (!d->used)
        return;
    if (g_rep_usage && d->kdci)
        g_rep_usage = 0;
    if (d->slot) {
        hc_cmd(hc, 0, 0, (TRB_DISABLE_SLOT << 10) | ((ULONG)d->slot << 24));
        hc->dcbaa[d->slot * 2] = 0;
    }
    d->used = 0;
    d->slot = 0;
}

static void port_enum(HC *hc, ULONG p)
{
    volatile ULONG *ps = hc->op + 0x100 + (p - 1) * 4;
    ULONG v = *ps, mps0, slot, cfglen, off, cfgval;
    int i, cc, kind = 0, idx = -1;
    DEV *d = NULL;
    UCHAR *b;

    for (i = 0; i < MAXDEV; i++)
        if (hc->dev[i].used && hc->dev[i].port == p)
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
    for (i = 0; i < MAXDEV; i++)
        if (!hc->dev[i].used) {
            idx = i;
            break;
        }
    if (idx < 0)
        return;
    d = &hc->dev[idx];
    if (!d->out) {
        d->out = (UCHAR *)alloc_page(&d->outpa);
        d->in = (UCHAR *)alloc_page(&d->inpa);
        d->buf = (UCHAR *)alloc_page(&d->bufpa);
        if (!d->out || !d->in || !d->buf || !ring_init(&d->ep0) || !ring_init(&d->kring) || !ring_init(&d->mring)) {
            d->out = NULL;
            return;
        }
    }
    RtlZeroMemory(d->out, PAGE_SIZE);
    RtlZeroMemory((void *)d->ep0.v, PAGE_SIZE);
    RtlZeroMemory((void *)d->kring.v, PAGE_SIZE);
    RtlZeroMemory((void *)d->mring.v, PAGE_SIZE);
    d->ep0.idx = d->kring.idx = d->mring.idx = 0;
    d->ep0.cycle = d->kring.cycle = d->mring.cycle = 1;
    d->hc = hc;
    d->port = (UCHAR)p;
    d->speed = (UCHAR)((v >> 10) & 0xF);
    d->kdci = d->mdci = 0;
    d->mold = 0;
    d->kleds_sent = 0xFF;
    RtlZeroMemory(d->kold, sizeof(d->kold));

    cc = hc_cmd(hc, 0, 0, TRB_ENABLE_SLOT << 10);
    slot = hc->cmd_slot;
    if (cc != CC_SUCCESS || !slot || slot > hc->maxslots) {
        diag_add(L" p%u-slot%d", p, (ULONG)cc, 0, 0);
        return;
    }
    d->slot = (UCHAR)slot;
    d->used = 1;
    hc->dcbaa[slot * 2] = d->outpa;
    hc->dcbaa[slot * 2 + 1] = 0;

    mps0 = d->speed == 4 ? 512 : d->speed == 3 ? 64 : 8;
    RtlZeroMemory(d->in, PAGE_SIZE);
    ictx(d, 0)[1] = 3;                                      /* add slot + EP0 */
    ictx(d, 1)[0] = ((ULONG)d->speed << 20) | (1u << 27);   /* speed, 1 context entry */
    ictx(d, 1)[1] = p << 16;                                /* root hub port */
    ictx(d, 2)[1] = (3 << 1) | (4 << 3) | (mps0 << 16);     /* CErr 3, control, max packet */
    ictx(d, 2)[2] = d->ep0.pa | 1;
    ictx(d, 2)[3] = 0;
    ictx(d, 2)[4] = 8;
    cc = hc_cmd(hc, d->inpa, 0, (TRB_ADDRESS_DEVICE << 10) | (slot << 24));
    if (cc != CC_SUCCESS) {
        diag_add(L" p%u-addr%d", p, (ULONG)cc, 0, 0);
        dev_drop(d);
        return;
    }
    delay_ms(10);
    b = d->buf;
    if (control(d, 0x80, 6, 0x0100, 0, 8) < 0) {
        diag_add(L" p%u-dd", p, 0, 0, 0);
        dev_drop(d);
        return;
    }
    if (d->speed < 3 && b[7] && b[7] != mps0) {
        RtlZeroMemory(d->in, PAGE_SIZE);
        ictx(d, 0)[1] = 2;
        ictx(d, 2)[1] = (3 << 1) | (4 << 3) | ((ULONG)b[7] << 16);
        hc_cmd(hc, d->inpa, 0, (TRB_EVALUATE_CTX << 10) | (slot << 24));
    }
    if (control(d, 0x80, 6, 0x0200, 0, 9) < 0) {
        diag_add(L" p%u-cd", p, 0, 0, 0);
        dev_drop(d);
        return;
    }
    cfglen = b[2] | (b[3] << 8);
    if (cfglen > 1000)
        cfglen = 1000;
    if (cfglen < 9 || control(d, 0x80, 6, 0x0200, 0, (USHORT)cfglen) < 0) {
        diag_add(L" p%u-cd2", p, 0, 0, 0);
        dev_drop(d);
        return;
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
        } else if (T == 5 && L >= 7 && kind) {
            UCHAR addr = b[off + 2], attr = b[off + 3];
            ULONG mps = (b[off + 4] | (b[off + 5] << 8)) & 0x7FF;
            if ((attr & 3) == 3 && (addr & 0x80)) {
                UCHAR dci = (UCHAR)((addr & 0xF) * 2 + 1);
                if (mps > 255) mps = 255;
                if (kind == 1) { d->kdci = dci; d->kmps = (UCHAR)mps; d->kival = b[off + 6]; }
                else { d->mdci = dci; d->mmps = (UCHAR)mps; d->mival = b[off + 6]; }
                kind = 0;
            }
        }
        off += L;
    }
    if (!d->kdci && !d->mdci) {
        diag_add(L" p%u-nohid", p, 0, 0, 0);
        dev_drop(d);
        return;
    }
    {
        ULONG maxdci = d->kdci > d->mdci ? d->kdci : d->mdci;
        UCHAR dcis[2];
        RING *rings[2];
        UCHAR mpss[2], ivs[2];
        int k;
        dcis[0] = d->kdci; rings[0] = &d->kring; mpss[0] = d->kmps; ivs[0] = d->kival;
        dcis[1] = d->mdci; rings[1] = &d->mring; mpss[1] = d->mmps; ivs[1] = d->mival;
        RtlZeroMemory(d->in, PAGE_SIZE);
        RtlCopyMemory(ictx(d, 1), octx(d, 0), hc->ctxsz);
        ictx(d, 1)[0] = (ictx(d, 1)[0] & 0x07FFFFFF) | (maxdci << 27);
        ictx(d, 1)[3] = 0;
        ictx(d, 0)[1] = 1;
        for (k = 0; k < 2; k++) {
            ULONG *ep;
            if (!dcis[k])
                continue;
            ictx(d, 0)[1] |= 1u << dcis[k];
            ep = ictx(d, dcis[k] + 1u);
            ep[0] = (ULONG)xhci_interval(d->speed, ivs[k]) << 16;
            ep[1] = (3 << 1) | (7 << 3) | ((ULONG)mpss[k] << 16);    /* interrupt IN */
            ep[2] = rings[k]->pa | 1;
            ep[3] = 0;
            ep[4] = mpss[k] | ((ULONG)mpss[k] << 16);
        }
        cc = hc_cmd(hc, d->inpa, 0, (TRB_CONFIGURE_EP << 10) | (slot << 24));
        if (cc != CC_SUCCESS) {
            diag_add(L" p%u-cfgep%d", p, (ULONG)cc, 0, 0);
            dev_drop(d);
            return;
        }
    }
    control(d, 0x00, 9, (USHORT)cfgval, 0, 0);                 /* SET_CONFIGURATION */
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
    diag_add(L" p%u:s%u%c%c", p, slot, d->kdci ? L'K' : L'-', d->mdci ? L'M' : L'-');
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
        port_enum(hc, p);
    }
}

static VOID worker(PVOID ctx)
{
    ULONG bus, dv, fn, i;
    LONG seq = 0;
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
        delay_ms(8);
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
    return STATUS_SUCCESS;
}
