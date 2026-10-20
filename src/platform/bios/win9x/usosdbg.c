/*
 * USOSDBG.EXE - live USB keyboard bridge diagnostics for Windows 9x (and
 * Windows 3.1 386 enhanced mode) under CSMWrap.
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 *
 * Started on the desktop with a PS/2 keyboard (or the mouse: File Run).
 * Every 500 ms it shows:
 *   KEY   the USOSKEY.COM shared block (INT 2Fh AX=D700h): heartbeat, ring
 *         head/tail, captured/passed/dropped, and from version 2 on the
 *         INT 08h / INT 1Ch hits seen in the real-mode (V86) chain, all
 *         INT 15h/4Fh calls and the ones not from INT 09h (USB), the SS:SP
 *         of the last INT 08h and of the last USB INT 15h/4Fh, and
 *         USOSKEY.DRV's polls / forced / refused counters
 *   INT16 from USOSKEY v3 on: the INT 16h guard counters (answered from
 *         the BIOS data area / chained to SeaBIOS) and the last caller
 *   EVT   from USOSKEY v3 on: the last 32 keybd_event calls of USOSKEY.DRV,
 *         oldest first: seq:VK d/u scan [x = extended], c / s = Ctrl /
 *         Shift as the driver had sent them (80 down; from 2026-10-06 on,
 *         before that GetAsyncKeyState, which is not safe at interrupt
 *         time), f = 0040:0017/0018 after the call; the INT16 line shows
 *         USER's own Ctrl/Shift state read here
 *   MOUSE from USOSKEY v4 on: USOSMOUS.DRV's BIOS registration (INT 15h
 *         C205h/C207h/C200h result), packets the INT 15h C207h callback
 *         saw / stored / dropped / ignored, the last packet, the driver's
 *         polls and event procedure calls
 *   WHEEL USOSMOUS.DRV's wheel state (USOSWHEELINFO: knock answer, wheel
 *         event calls), the BIOS device ID now (INT 15h C204h, read only;
 *         W sends the knock again and asks once more), the 4th bytes of
 *         the 32 ring slots, and CSMWrap patch 0018's record (signature
 *         USOSMWHL in the first MiB): per mouse report/boot protocol and
 *         why, wMaxPacketSize, the field layout, the last raw packet, the
 *         wheel packet count and the first bytes of the HID report
 *         descriptor (S saves them all to the log); with CSMWrap
 *         3.1.2-usos15 (patch 0020) also the record's ring of the last 16
 *         INT 15h AH=C2h calls (function, BX, ES, caller CS:IP, device ID
 *         after the call, result) and what followed the last IntelliMouse
 *         knock (rates 200, 100, 80): a later C201h reset / C205h init
 *         and its caller
 *   VMD   USOSVMD.VXD / VMOUSE mode (1.7): C:\USOS9X\USOSVMD.ON, what
 *         USOSMOUS.DRV decided (USOSVMDINFO: VMOUSE / USOSVMD APIs, the
 *         VxD's mode, its V86 callback, the VMOUSE event callback, the
 *         direct INT 15h path) and the VxD's own status block (loaded,
 *         VMOUSE version and mouse type, callbacks from SeaBIOS and how many
 *         came while a DOS VM was current, the last VM handle and packet,
 *         packets posted to VMOUSE, ring drops, error bits)
 *   IVT   INT 08h/09h/15h/16h/1Ch/2Fh vectors of the system VM
 *   MAP   linear (system VM V86) against physical (DPMI 0800h) for a few
 *         pages: page 0 (control: the IVT page is per VM, expected to
 *         differ), the USOSKEY page, the INT 08h and USB INT 15h/4Fh stack
 *         pages, and C0000-FFFFF (SeaBIOS low zone, its extra stack: where
 *         CSMWrap's helper core writes the HID report, by physical address)
 *   NIC   every network controller (class 02h) and the I211 (8086:1539):
 *         command (INTx disable), status (interrupt status), line / pin,
 *         MSI / MSI-X enable, the bridges above it
 *   IRQ   ELCR (4D0h/4D1h), the 8259 masks (in 21h / A1h: VPICD's view of
 *         the system VM; IRR / ISR are not read), the NIC's line in both
 *   PIR   the $PIR routing table in F0000-FFFFF (header, slot entries, the
 *         NIC's and its bridges' entries marked)
 *   PCI   every xHCI (class 0C0330) through ports CF8h/CFCh: command,
 *         status, BARs, interrupt; its registers through a DPMI 0800h
 *         mapping (USBCMD, USBSTS, MFINDEX twice, PORTSC of connected
 *         ports); every bridge above an xHCI bus: bus numbers, windows,
 *         bridge control. Same format as USOSDIAG.COM's PCI section (DOS,
 *         C:\USOS9X\DIAG.LOG), so the two can be compared line by line
 *   DISK  from CSMWrap 3.1.2-usos16 (patch 0021) on: SeaBIOS's USB disk
 *         service record (USOS UDSK in the first MiB): the UDS device
 *         table (state, BIOS number, VID:PID, port, capacity, counters,
 *         last op / CSW / sense), the BIOS disk table, the event ring; the
 *         channel 1 words after the CSMPPrxy mailbox and the USOSUSB.MPD
 *         status page they point to (docs/usb9x-hotswap-design-2026-10-19.md)
 * S appends the current screen to C:\USOS9X\USOSDBG.LOG, Esc quits.
 *
 * Log mode (1.5 on, for USOSLOG.EXE, no window shown, no key needed):
 *   USOSDBG.EXE /L <file> [/F] [/D] [/N <hex>]
 * takes two snapshots one second apart (so the "+n" deltas are per second),
 * writes the second one to <file> (created anew) and exits. Without /F the
 * PCI section (xHCI MMIO mapping) is left out: DPMI 0800h mappings cannot
 * be released, so USOSLOG asks for it only on its first run after a boot.
 * /N dumps the usosnet 0.4 statistics page at that physical address
 * (registry UsosnetStatsPa) as USNS+ooo: hex lines. The wheel knock (W) is
 * never sent in log mode; the C204h ID question is asked once per run as
 * on the first display.
 * /D writes the DISK section only, from one snapshot (USOSLOG on a
 * drive change).
 * Nothing is written to any device: configuration space and xHCI registers
 * are only read.
 *
 * No OpenWatcom runtime is linked (own entry point, -zl): the binary is
 * this file plus import records. Built with tools/build_win9x_support.py.
 */
#include <windows.h>
#include "usosuds.h"

#define LINES 144
#define WIDTH 256

typedef struct {
    char magic[4];
    WORD version;
    BYTE head, tail, alive, pad;
    WORD dropped, captured, passed;
    BYTE ring[64];
    WORD forced, refused;
    /* version 2 */
    WORD polls;
    BYTE last4f, last4f9;
    DWORD c08, c1c, c4f, c4fusb;
    WORD sp08, ss08, sp4f, ss4f;
    /* version 3 */
    WORD c16[10];
    WORD last16ax, last16ip, last16cs;
    WORD evseq;
    BYTE evlog[32][8];
    /* version 4: USB mouse (USOSMOUS.DRV) */
    BYTE mhead, mtail, malive, mstate;
    WORD mcb;
    WORD mdropped, mignored, mpolls;
    DWORD mpackets;
    BYTE mlast[4];
    WORD mevents, merr;
    BYTE mring[128];                /* 32 x status, X, Y, wheel */
} SHARED;

/* USOSMOUS.DRV USOSWHEELINFO (version 1; 2 adds notches). */
typedef struct {
    BYTE version, pref, wheel, knock_id;
    WORD knock_err, knocks, wheel_calls;
    int last_sum;
    WORD notches;                   /* version 2: running notch count, up positive */
} WHEELINFO;

/* USOSKEY.DRV USOSWHEELLOG (version 1): wheel scrolling decisions. */
typedef struct {
    WORD seq;
    DWORD tick;
    int notches;
    BYTE action, kind;
    WORD hwnd, sent, code;
    char cls[20];
} WSREC;
typedef struct {
    BYTE version, enabled;
    WORD seq, swallowed, expired;
    DWORD lines;
    WSREC rec[16];
} WSLOG;

/* USOSMOUS.DRV USOSVMDINFO (version 1) with USOSVMD.VXD's status block. */
typedef struct {
    BYTE version, checked, flag, vmouse_api, vxd_api, vxd_mode, active, cb_ok;
    DWORD vxd_cb;
    WORD direct_err, vxd_status, wheel_only_polls;
    BYTE vxd[64];
} VMDINFO;

/* USOSVMD.VXD status block (PM API function 2, src/platform/win9x/
 * usosvmd.asm), 64 bytes. */
typedef struct {
    WORD sig;
    BYTE version, mode;
    WORD vmd_version;
    BYTE type_init, type_now;
    DWORD cb, sb, callbacks, foreign, posted, own_drop, shared_put, shared_drop, last_vm;
    BYTE last[4];
    WORD err, type_changes;
    DWORD ticks;
    WORD attach;
    DWORD sys_vm;
    WORD reclaims;
} VXDSTAT;

/* CSMWrap patch 0018: SeaBIOS's usb_mouse_diag (version 1, natural
 * alignment, 310 bytes). */
typedef struct {
    BYTE iface, maxpacket, report, report_id;
    signed char result;
    BYTE pad;
    WORD desclen;
    BYTE loc[6][3];                 /* off, size, sign: X, Y, wheel, buttons 1-3 */
} MDIAGDEV;
typedef struct {
    DWORD sig[2];
    BYTE version, count, wheel, id, rate1, rate2, last_dev;
    signed char last_z;
    DWORD packets, zpackets, skipped;
    BYTE last_raw[16];
    MDIAGDEV dev[4];
    WORD desc_got;
    BYTE desc[160];
} MDIAG;

typedef struct {
    DWORD edi, esi, ebp, reserved, ebx, edx, ecx, eax;
    WORD flags, es, ds, fs, gs, ip, cs, sp, ss;
} RMREGS;

extern BOOL FAR PASCAL WaitEvent(HANDLE);
extern BOOL FAR PASCAL InitApp(HINSTANCE);

/* Reserved instance data: KERNEL's InitTask writes the stack bounds into
 * the first 16 bytes of DGROUP. */
#pragma data_seg("_NULL", "BEGDATA")
char null_area[32] = { 0 };
#pragma data_seg()

static char text[LINES][WIDTH];
static int nlines;
static HINSTANCE instance;
static HWND window;
static WORD lin_sel, phys_sel, bda_sel;
static DWORD prev_c08, prev_c1c, prev_c4f, prev_c4fusb, prev_tick;
static WORD prev_polls, prev_captured;
static DWORD prev_mpackets;
static WORD prev_mpolls, prev_mevents;
static WORD snapshots;
static int char_h = 16;
static RMREGS rm;
static BYTE knock_now;              /* W pressed: knock before the next C204h */
static BYTE id_asked, id_failed;    /* C204h asked (first display, after W) */
static WORD id_result;
static DWORD mdiag_at;              /* physical address of the 0018 record, 0 not found */
static BYTE mdiag_scanned;
static BYTE log_mode, log_pci;      /* /L, /F */
static BYTE disk_only;              /* /D: the DISK section only, one snapshot */
static char log_path[128];
static DWORD net_pa;                /* /N */
static WORD e_cmdseg, e_cmdoff;     /* command tail (InitTask ES:BX) */

static LPSTR line(void)
{
    if (nlines >= LINES) nlines = LINES - 1;
    text[nlines][0] = 0;
    return (LPSTR)text[nlines++];
}

static BYTE FAR *linear(DWORD base, DWORD limit)
{
    SetSelectorBase(lin_sel, base);
    SetSelectorLimit(lin_sel, limit);
    return (BYTE FAR *)MAKELP(lin_sel, 0);
}

/* ---------------------------------------------------------- physical */
static DWORD map_from[16], map_to[16];
static int maps;

/* DPMI 0800h: physical -> linear (cached: 0.9 hosts cannot unmap). */
static DWORD phys_linear(DWORD phys, DWORD size)
{
    WORD hi = HIWORD(phys), lo = LOWORD(phys), shi = HIWORD(size), slo = LOWORD(size);
    WORD fail = 0;
    DWORD lin;
    int i;
    for (i = 0; i < maps; i++) if (map_from[i] == phys) return map_to[i];
    _asm {
        push si
        push di
        mov ax, 0800h
        mov bx, hi
        mov cx, lo
        mov si, shi
        mov di, slo
        int 31h
        pop di
        pop si
        jnc ok
        mov fail, 1
    ok:
        mov hi, bx
        mov lo, cx
    }
    if (fail) return 0;
    lin = ((DWORD)hi << 16) | lo;
    if (maps < 16) { map_from[maps] = phys; map_to[maps] = lin; maps++; }
    return lin;
}

/* The first MiB is mapped once as a whole (every page of it is compared
 * on every refresh; mappings cannot be released), the rest per address. */
static BYTE low_state;              /* 0 not tried, 1 mapped, 2 refused */
static DWORD low_lin;

static BYTE FAR *physical(DWORD phys, DWORD size)
{
    DWORD lin;
    if (phys + size <= 0x100000L) {
        if (!low_state) {
            low_lin = phys_linear(0, 0x100000L);
            low_state = low_lin ? 1 : 2;
        }
        if (low_state != 1) return 0;
        lin = low_lin + phys;
    } else {
        lin = phys_linear(phys, size);
    }
    if (!lin) return 0;
    SetSelectorBase(phys_sel, lin);
    SetSelectorLimit(phys_sel, size - 1);
    return (BYTE FAR *)MAKELP(phys_sel, 0);
}

/* ---------------------------------------------------------- KEY / IVT */
static WORD key_seg, key_off;
static WORD stack08_ss, stack08_sp, stack4f_ss, stack4f_sp;

static SHARED FAR *find_shared(void)
{
    WORD al_out = 0, rseg = 0, roff = 0, magic = 0;
    SHARED FAR *s;
    key_seg = 0;
    _asm {
        push si
        push di
        mov ax, 0D700h
        xor bx, bx
        xor cx, cx
        xor dx, dx
        int 2Fh
        mov al_out, ax
        mov rseg, bx
        mov roff, cx
        mov magic, dx
        pop di
        pop si
    }
    if ((al_out & 0xFF) != 0xFF || magic != 0x554B) return 0;
    s = (SHARED FAR *)(linear((DWORD)rseg << 4, 0xFFFFL) + roff);
    if (s->magic[0] != 'U' || s->magic[1] != 'S' || s->magic[2] != 'K' || s->magic[3] != 'Y') return 0;
    key_seg = rseg;
    key_off = roff;
    return s;
}

static void show_v3(SHARED FAR *s)
{
    WORD seq, first, n = 0;
    LPSTR l = 0;
    BYTE FAR *bda = (BYTE FAR *)MAKELP(bda_sel, 0);   /* own selector: s uses lin_sel */
    wsprintf(line(), "INT16 guard (answered/chained): 00 -/%u  01 %u/%u  02 %u/-  10 -/%u  11 %u/%u  12 %u/-  other -/%u  not alive %u",
             s->c16[0], s->c16[1], s->c16[2], s->c16[3], s->c16[4], s->c16[5], s->c16[6], s->c16[7], s->c16[8], s->c16[9]);
    wsprintf(line(), "INT16 last while alive: AX=%04X from %04X:%04X   BDA now 17:%02X 18:%02X 96:%02X 97:%02X   USER Ctrl %04X Shift %04X",
             s->last16ax, s->last16cs, s->last16ip, (WORD)bda[0x17], (WORD)bda[0x18], (WORD)bda[0x96], (WORD)bda[0x97],
             (WORD)GetAsyncKeyState(VK_CONTROL), (WORD)GetAsyncKeyState(VK_SHIFT));
    seq = s->evseq;
    first = seq > 32 ? seq - 32 : 0;
    if (seq == first) wsprintf(line(), "EVT  no keybd_event logged yet (USOSKEY.DRV older than v3, or no key since start)");
    for (; first != seq; first++) {
        BYTE FAR *e = s->evlog[first & 31];
        if (n++ % 4 == 0) { l = line(); wsprintf(l, "EVT "); }
        wsprintf(l + lstrlen(l), "  %u:%02X%c%02X%s c%02X s%02X f%02X/%02X", first, (WORD)e[0],
                 (e[1] & 0x80) ? 'u' : 'd', (WORD)e[2], (LPSTR)((e[3] & 1) ? "x" : " "),
                 (WORD)e[4], (WORD)e[5], (WORD)e[6], (WORD)e[7]);
    }
}

static void show_key(void)
{
    SHARED FAR *s = find_shared();
    DWORD now = GetTickCount();
    stack08_ss = stack4f_ss = 0;
    if (!s) {
        wsprintf(line(), "KEY  USOSKEY.COM not found (INT 2Fh AX=D700h): not loaded before Windows?");
        return;
    }
    wsprintf(line(), "KEY  USOSKEY v%u at %04X:%04X (%s)  USOSKEY.DRV %s  alive(heartbeat):%u  head/tail:%u/%u",
             s->version, key_seg, key_off, (LPSTR)(s->pad == 'W' ? "copy from Windows" : "TSR"),
             (LPSTR)(GetModuleHandle("USOSKEY") ? "loaded" : "NOT loaded"),
             (WORD)s->alive, (WORD)s->head, (WORD)s->tail);
    wsprintf(line(), "KEY  captured:%u (+%u)  passed:%u  dropped:%u  forced:%u  refused:%u",
             s->captured, (WORD)(s->captured - prev_captured), s->passed, s->dropped, s->forced, s->refused);
    prev_captured = s->captured;
    if (s->version < 2) {
        wsprintf(line(), "KEY  USOSKEY.COM v1: no INT 08h/4Fh counters (copy the new USOSKEY.COM)");
    } else {
        wsprintf(line(), "KEY  in %lu ms:  INT08 +%lu  INT1C +%lu  4Fh all +%lu  4Fh usb +%lu  DRV polls +%u",
                 now - prev_tick, s->c08 - prev_c08, s->c1c - prev_c1c, s->c4f - prev_c4f,
                 s->c4fusb - prev_c4fusb, (WORD)(s->polls - prev_polls));
        wsprintf(line(), "KEY  total:  INT08 %lu  INT1C %lu  4Fh all %lu  4Fh usb %lu  DRV polls %u  last 4Fh byte %02X%s",
                 s->c08, s->c1c, s->c4f, s->c4fusb, s->polls, (WORD)s->last4f,
                 (LPSTR)(s->last4f9 ? " (from INT 09h)" : " (usb)"));
        wsprintf(line(), "KEY  SS:SP at last INT08 %04X:%04X   at last USB 4Fh %04X:%04X",
                 s->ss08, s->sp08, s->ss4f, s->sp4f);
        prev_c08 = s->c08; prev_c1c = s->c1c; prev_c4f = s->c4f; prev_c4fusb = s->c4fusb;
        prev_polls = s->polls;
        stack08_ss = s->ss08; stack08_sp = s->sp08;
        stack4f_ss = s->ss4f; stack4f_sp = s->sp4f;
    }
    prev_tick = now;
    if (s->version >= 3) show_v3(s);
}

static void show_mouse(void)
{
    static const char *const states[7] = { "not registered", "registered", "no BIOS mouse (C205h failed)",
                                           "BIOS refused (C207h/C200h)", "disabled", "paused (DOS box open)",
                                           "paused (no DOS-box guard)" };
    SHARED FAR *s = find_shared();
    if (!s || s->version < 4) {
        wsprintf(line(), "MOUSE USOSKEY.COM %s: no mouse ring (copy the new USOSKEY.COM)",
                 (LPSTR)(s ? "older than v4" : "not found"));
        return;
    }
    wsprintf(line(), "MOUSE USOSMOUS.DRV %s  state:%s  last BIOS error:%04X  callback %04X:%04X  alive:%u  head/tail:%u/%u",
             (LPSTR)(GetModuleHandle("MOUSE") ? "MOUSE module loaded" : "no MOUSE module"),
             (LPSTR)(s->mstate < 7 ? states[s->mstate] : "?"), s->merr, key_seg, s->mcb,
             (WORD)s->malive, (WORD)s->mhead, (WORD)s->mtail);
    wsprintf(line(), "MOUSE packets:%lu (+%lu)  dropped:%u  ignored:%u  last %02X %02X %02X  DRV polls:%u (+%u)  events:%u (+%u)",
             s->mpackets, s->mpackets - prev_mpackets, s->mdropped, s->mignored,
             (WORD)s->mlast[0], (WORD)s->mlast[1], (WORD)s->mlast[2],
             s->mpolls, (WORD)(s->mpolls - prev_mpolls), s->mevents, (WORD)(s->mevents - prev_mevents));
    prev_mpackets = s->mpackets;
    prev_mpolls = s->mpolls;
    prev_mevents = s->mevents;
}

/* INT 15h in real mode (V86) through DPMI 0300h, as USOSMOUS.DRV does.
 * 0 ok, 100h | AH BIOS error, FFFFh DPMI refused. */
static WORD bios15(WORD ax, WORD bx)
{
    BYTE failed = 0;
    WORD off = (WORD)(void NEAR *)&rm;
    BYTE NEAR *p = (BYTE NEAR *)&rm;
    WORD i;
    for (i = 0; i < sizeof(rm); i++) p[i] = 0;
    rm.eax = ax;
    rm.ebx = bx;
    rm.flags = 0x0202;
    _asm {
        push es
        push di
        pushad
        mov ax, ds
        mov es, ax
        xor edi, edi
        mov di, off
        mov ax, 0300h
        mov bx, 0015h
        xor cx, cx
        int 31h
        popad
        pop di
        pop es
        jnc ok
        mov failed, 1
    ok:
    }
    if (failed) return 0xFFFF;
    if (rm.flags & 1) return 0x100 | (WORD)((rm.eax >> 8) & 0xFF);
    return 0;
}

static const char *md_reason(int r)
{
    switch (r) {
    case 0: return "report protocol";
    case -1: return "boot: long/truncated item";
    case -2: return "boot: bad report ID";
    case -3: return "boot: nested Push";
    case -4: return "boot: Pop without Push";
    case -5: return "boot: too many report IDs";
    case -6: return "boot: field too big";
    case -7: return "boot: an input report longer than one packet";
    case -8: return "boot: no relative X";
    case -9: return "boot: no relative Y";
    case -10: return "boot: no relative wheel";
    case -11: return "boot: no button 1";
    case -12: return "boot: X without report ID";
    case -20: return "boot: no HID report descriptor";
    case -21: return "boot: report descriptor too long";
    case -22: return "boot: no memory";
    case -23: return "boot: GET_DESCRIPTOR failed";
    case -30: return "boot: SET_PROTOCOL(report) failed";
    }
    return "boot: ?";
}

/* CSMWrap 3.1.2-usos15 (patch 0020): the last INT 15h AH=C2h calls, an
 * extension after the record (SeaBIOS sizeof 312; the version byte stays
 * 1). Read by byte offsets from the record start, valid only with the
 * magic: u32 magic, u16 count (calls since boot, wraps), u8 head (next
 * slot), u8 pad, then 16 x { u16 ax, bx, es, caller cs, caller ip;
 * u8 id after the call, u8 res (0 ok, 80h | AH with CF) }. */
#define C2RG_OFF     312
#define C2RG_MAGIC   0x47523243L    /* "C2RG" */
#define C2RG_COUNT   316
#define C2RG_HEAD    318
#define C2RG_RING    320
#define C2RG_ENTRY   12
#define C2RG_SLOTS   16
#define MDIAG_MAP    512            /* record + ring: 320 + 16 * 12 */
static WORD mdiag_mapped;           /* bytes mapped at mdiag_at */

/* The 0018 record: first MiB, 16-byte steps, from 80000h up (low zone). */
static MDIAG FAR *find_mdiag(void)
{
    MDIAG FAR *d;
    if (!mdiag_scanned) {
        DWORD a;
        BYTE FAR *low = physical(0, 0xFFFFL);  /* maps the first MiB once */
        mdiag_scanned = 1;
        if (!low) return 0;
        for (a = 0x80000L; a < 0x100000L - sizeof(MDIAG); a += 16) {
            DWORD FAR *q = (DWORD FAR *)physical(a, 16);
            if (q && q[0] == 0x534F5355L && q[1] == 0x4C48574DL && ((BYTE FAR *)q)[8] == 1) { mdiag_at = a; break; }
        }
    }
    if (!mdiag_at) return 0;
    /* the ring too when it fits below 1 MiB (the low mapping) */
    mdiag_mapped = mdiag_at + MDIAG_MAP <= 0x100000L ? MDIAG_MAP : sizeof(MDIAG);
    d = (MDIAG FAR *)physical(mdiag_at, mdiag_mapped);
    return d;
}

static const WORD c2_rates[7] = { 10, 20, 40, 60, 80, 100, 200 };

/* short name of one C2xxh call (BH as the function takes it) */
static void c2_name(LPSTR t, WORD ax, WORD bx)
{
    WORD bh = bx >> 8;
    if ((ax >> 8) != 0xC2) { wsprintf(t, "%04X", ax); return; }
    switch (ax & 0xFF) {
    case 0: wsprintf(t, "C200 %s", (LPSTR)(bh ? "on" : "off")); break;
    case 1: wsprintf(t, "C201 reset"); break;
    case 2:
        if (bh < 7) wsprintf(t, "C202 rate %u", c2_rates[bh]);
        else wsprintf(t, "C202 rate ?%u", bh);
        break;
    case 3: wsprintf(t, "C203 res %u", bh); break;
    case 4: wsprintf(t, "C204 getid"); break;
    case 5: wsprintf(t, "C205 init pkt %u", bh); break;
    case 6: wsprintf(t, "C206 %s", (LPSTR)(bh == 0 ? "status" : bh == 1 ? "scale 1:1" : bh == 2 ? "scale 2:1" : "?")); break;
    case 7: wsprintf(t, "C207 handler"); break;
    default: wsprintf(t, "%04X", ax); break;
    }
}

/* the C2 ring, oldest first, four calls a line, then what followed the
 * last IntelliMouse knock (rates 200, 100, 80) */
static void show_c2(BYTE FAR *rec)
{
    WORD count, head, n, first, i, k, knock = 0xFFFF, resets = 0, inits = 0, offs = 0, other = 0;
    WORD reset_cs = 0, reset_ip = 0, reset_ax = 0;
    BYTE FAR *e[C2RG_SLOTS];
    LPSTR l = 0;
    char nm[24];
    if (mdiag_mapped < MDIAG_MAP) {
        wsprintf(line(), "WHEEL  C2 ring: not mapped (record above %05lX)", 0x100000L - MDIAG_MAP);
        return;
    }
    if (*(DWORD FAR *)(rec + C2RG_OFF) != C2RG_MAGIC) {
        wsprintf(line(), "WHEEL  C2 ring: none (CSMWrap before usos15)");
        return;
    }
    count = *(WORD FAR *)(rec + C2RG_COUNT);
    head = rec[C2RG_HEAD] & (C2RG_SLOTS - 1);
    if (count < C2RG_SLOTS && head == count) { n = count; first = 0; }
    else { n = C2RG_SLOTS; first = head; }
    for (i = 0; i < n; i++) e[i] = rec + C2RG_RING + ((first + i) & (C2RG_SLOTS - 1)) * C2RG_ENTRY;
    wsprintf(line(), "WHEEL  C2 ring: %u INT 15h AH=C2h calls since boot, last %u (oldest first; ID after the call; ok / err AH)",
             count, n);
    for (i = 0; i < n; i++) {
        WORD FAR *w = (WORD FAR *)e[i];
        BYTE res = e[i][11];
        if (i % 4 == 0) { l = line(); wsprintf(l, "WHEEL  C2 #%u:", (WORD)(count - n + i)); }
        c2_name(nm, w[0], w[1]);
        wsprintf(l + lstrlen(l), "  %s bx=%04X es=%04X @%04X:%04X id%u ", (LPSTR)nm, w[1], w[2], w[3], w[4],
                 (WORD)e[i][10]);
        if (res) wsprintf(l + lstrlen(l), "err%02X", (WORD)(res & 0x7F));
        else lstrcat(l, "ok");
    }
    /* the last knock: C202 rate 200, 100, 80 in a row */
    for (i = 0; i + 2 < n; i++) {
        WORD FAR *a = (WORD FAR *)e[i], FAR *b = (WORD FAR *)e[i + 1], FAR *c = (WORD FAR *)e[i + 2];
        if (a[0] == 0xC202 && b[0] == 0xC202 && c[0] == 0xC202 &&
            (a[1] >> 8) == 6 && (b[1] >> 8) == 5 && (c[1] >> 8) == 4) knock = i + 2;
    }
    if (knock == 0xFFFF) {
        wsprintf(line(), "WHEEL  C2 knock (rate 200,100,80) not in the ring: never sent, or more than %u calls ago", n);
        return;
    }
    for (k = knock + 1; k < n; k++) {
        WORD FAR *w = (WORD FAR *)e[k];
        WORD f = w[0];
        if (f == 0xC201 || f == 0xC205) {
            if (f == 0xC201) resets++; else inits++;
            if (!reset_ax) { reset_ax = f; reset_cs = w[3]; reset_ip = w[4]; }
        } else if (f == 0xC200 && !(w[1] >> 8)) offs++;
        else other++;
    }
    l = line();
    wsprintf(l, "WHEEL  C2 after the last knock (#%u, id%u): resets C201 %u  inits C205 %u  off C200 %u  other %u  ID now %u",
             (WORD)(count - n + knock), (WORD)e[knock][10], resets, inits, offs, other, (WORD)e[n - 1][10]);
    if (reset_ax)
        wsprintf(l + lstrlen(l), "  -> first reset/init after it: %04X from %04X:%04X", reset_ax, reset_cs, reset_ip);
}

static void show_wheel(void)
{
    SHARED FAR *s = find_shared();
    FARPROC info = GetModuleHandle("MOUSE") ? GetProcAddress(GetModuleHandle("MOUSE"), "USOSWHEELINFO") : 0;
    MDIAG FAR *d;
    LPSTR l;
    WORD r, i, nz = 0, last = 0;
    if (info) {
        WHEELINFO FAR *w = (WHEELINFO FAR *)((DWORD (FAR PASCAL *)(void))info)();
        wsprintf(line(), "WHEEL USOSMOUS: wanted:%s  knock answered ID:%02X  wheel:%s  knocks:%u  knock error:%04X  wheel calls:%u  last sum:%d",
                 (LPSTR)(w->pref == 2 ? "yes" : w->pref == 1 ? "no (Wheel=0 or before 98)" : "not asked"),
                 (WORD)w->knock_id, (LPSTR)(w->wheel ? "ON" : "off"), w->knocks, w->knock_err, w->wheel_calls, w->last_sum);
        if (w->version >= 2)
            wsprintf(line(), "WHEEL USOSMOUS notch count:%d (up positive; last sum %d = %s)", (int)w->notches, w->last_sum,
                     (LPSTR)(w->last_sum < 0 ? "up" : w->last_sum > 0 ? "down" : "none"));
    } else {
        wsprintf(line(), "WHEEL USOSMOUS.DRV without USOSWHEELINFO (older driver)");
    }
    /* C204h only on the first display and after W (with an i8042 mouse it
     * is a device command; the USB emulation answers from memory) */
    if (knock_now) {
        knock_now = 0;
        bios15(0xC202, 0x0600); bios15(0xC202, 0x0500); bios15(0xC202, 0x0400);
        id_asked = 0;
    }
    if (!id_asked) {
        id_asked = 1;
        r = bios15(0xC204, 0);
        id_result = r ? r : (WORD)((rm.ebx >> 8) & 0xFF);
        id_failed = r != 0;
    }
    wsprintf(line(), "WHEEL BIOS C204h (at start / after W): %s%02X  (3 = IntelliMouse, wheel bytes sent; 0 = no knock or no wheel mouse; W = knock again)",
             (LPSTR)(id_failed ? "error " : "ID "), id_result);
    if (s && s->version >= 4) {
        for (i = 0; i < 32; i++) if (s->mring[i * 4 + 3]) { nz++; last = s->mring[i * 4 + 3]; }
        wsprintf(line(), "WHEEL last packet 4th byte:%02X  ring slots with a wheel byte:%u/32 (last %02X)",
                 (WORD)s->mlast[3], nz, last);
    }
    d = find_mdiag();
    if (!d) {
        wsprintf(line(), "WHEEL SeaBIOS: no USOSMWHL record (CSMWrap without patch 0018, or no USB mouse set up)");
        return;
    }
    wsprintf(line(), "WHEEL SeaBIOS at %05lX: mice:%u  wheel mouse:%u  ID:%u  rates:%u,%u  packets:%lu  with wheel:%lu  other reports:%lu  last z:%d (mouse %u)",
             mdiag_at, (WORD)d->count, (WORD)d->wheel, (WORD)d->id, (WORD)d->rate1, (WORD)d->rate2,
             d->packets, d->zpackets, d->skipped, (int)d->last_z, (WORD)d->last_dev);
    for (i = 0; i < d->count && i < 4; i++) {
        MDIAGDEV FAR *v = &d->dev[i];
        wsprintf(line(), "WHEEL  mouse %u: if %u  maxpacket %u  %s (%d)  report ID %u  desc %u bytes  X %u/%u  Y %u/%u  W %u/%u  B1 %u",
                 i, (WORD)v->iface, (WORD)v->maxpacket, (LPSTR)md_reason(v->result), (int)v->result, (WORD)v->report_id,
                 v->desclen, (WORD)v->loc[0][0], (WORD)v->loc[0][1], (WORD)v->loc[1][0], (WORD)v->loc[1][1],
                 (WORD)v->loc[2][0], (WORD)v->loc[2][1], (WORD)v->loc[3][0]);
    }
    l = line();
    wsprintf(l, "WHEEL  last raw:");
    for (i = 0; i < 16; i++) wsprintf(l + lstrlen(l), " %02X", (WORD)d->last_raw[i]);
    for (r = 0; r < d->desc_got; r += 64) {
        l = line();
        wsprintf(l, "WHEEL  desc+%03u:", r);
        for (i = r; i < d->desc_got && i < r + 64; i++) wsprintf(l + lstrlen(l), "%02X", (WORD)d->desc[i]);
    }
    show_c2((BYTE FAR *)d);
}

/* USOSKEY.DRV's wheel scrolling (USOSWHEELLOG): per notch batch the real
 * delta (USOSMOUS.DRV's counter, up positive) and what was done. */
static void show_wheelscroll(void)
{
    static const char *const actions[6] = { "-", "stock (nothing scrollable under the pointer)",
        "stock (Win32 window)", "translated to WM_VSCROLL", "off", "95: MSWHEEL_ROLLMSG posted" };
    static const char *const kinds[3] = { "?", "Win16", "Win32" };
    HINSTANCE key = GetModuleHandle("USOSKEY");
    FARPROC info = key ? GetProcAddress(key, "USOSWHEELLOG") : 0;
    WSLOG FAR *g;
    WORD i, first;
    if (!info) {
        wsprintf(line(), "WHEEL USOSKEY scrolling: no USOSWHEELLOG (USOSKEY.DRV not loaded or older)");
        return;
    }
    g = (WSLOG FAR *)((DWORD (FAR PASCAL *)(void))info)();
    wsprintf(line(), "WHEEL USOSKEY scrolling: hook:%s  decisions:%u  WM_MOUSEWHEEL swallowed:%u  dropped:%u  wheel lines:%lu",
             (LPSTR)(g->enabled ? "on" : "off"), g->seq, g->swallowed, g->expired, g->lines);
    first = g->seq > 16 ? g->seq - 16 : 0;
    for (i = first; i < g->seq; i++) {
        WSREC FAR *r = &g->rec[i % 16];
        if (r->seq != i + 1) continue;
        wsprintf(line(), "WHEEL  #%u t%lu delta %d notch(es) = %d (%s)  %s  hwnd %04X %s %s  sent %u x SB %u",
                 r->seq, r->tick, r->notches, r->notches * 120, (LPSTR)(r->notches > 0 ? "up" : r->notches < 0 ? "down" : "none"),
                 (LPSTR)actions[r->action < 6 ? r->action : 0], r->hwnd, (LPSTR)kinds[r->kind < 3 ? r->kind : 0],
                 (LPSTR)(r->cls[0] ? r->cls : "-"), r->sent, r->code);
    }
}

static LPCSTR vmd_mode_name(BYTE m)
{
    return m == 0 ? "no VMOUSE" : m == 1 ? "minidriver (posts to VMOUSE)" : m == 2 ? "observer (VMOUSE has another mouse)" : "no answer";
}

static void show_vmd(void)
{
    OFSTRUCT of;
    HINSTANCE mouse = GetModuleHandle("MOUSE");
    FARPROC info = mouse ? GetProcAddress(mouse, "USOSVMDINFO") : 0;
    BOOL flag = OpenFile("C:\\USOS9X\\USOSVMD.ON", &of, OF_EXIST) != HFILE_ERROR;
    VMDINFO FAR *v;
    VXDSTAT FAR *x;
    if (!info) {
        wsprintf(line(), "VMD  USOSVMD.ON:%s  USOSMOUS.DRV without USOSVMDINFO (older driver or another mouse.drv)", (LPSTR)(flag ? "yes" : "no"));
        return;
    }
    v = (VMDINFO FAR *)((DWORD (FAR PASCAL *)(void))info)();
    wsprintf(line(), "VMD  USOSVMD.ON:%s  decided:%s  VMOUSE API:%s  USOSVMD API:%s  VxD mode:%s  VMOUSE mode:%s  event callback:%s  C207h -> %04X:%04X  direct INT15 error:%u  wheel polls:%u",
             (LPSTR)(flag ? "yes" : "no"), (LPSTR)(v->checked ? "yes" : "not yet"), (LPSTR)(v->vmouse_api ? "yes" : "no"),
             (LPSTR)(v->vxd_api ? "yes (loaded)" : "no (not loaded)"), (LPSTR)vmd_mode_name(v->vxd_mode),
             (LPSTR)(v->active ? "ON" : "off"), (LPSTR)(v->cb_ok ? "accepted" : "no"),
             HIWORD(v->vxd_cb), LOWORD(v->vxd_cb), v->direct_err, v->wheel_only_polls);
    if (v->vxd_status < sizeof(VXDSTAT)) {
        wsprintf(line(), "VMD  USOSVMD.VXD status: %s", (LPSTR)(v->vxd_api ? "PM API 2 failed" : "VxD not loaded"));
        return;
    }
    x = (VXDSTAT FAR *)v->vxd;
    wsprintf(line(), "VMD  VxD v%u mode:%s  VMOUSE %u.%02u  mouse type at init:%02X now:%02X (2 = ours, 4 = PS/2)  changes:%u reclaims:%u  callback %04X:%04X  block %08lX  attach:%u  err:%04X",
             (WORD)x->version, (LPSTR)vmd_mode_name(x->mode), (WORD)HIBYTE(x->vmd_version), (WORD)LOBYTE(x->vmd_version),
             (WORD)x->type_init, (WORD)x->type_now, x->type_changes, x->reclaims, HIWORD(x->cb), LOWORD(x->cb), x->sb, x->attach, x->err);
    wsprintf(line(), "VMD  BIOS callbacks:%lu  from a DOS VM:%lu  last VM %08lX (system VM %08lX)  last %02X %02X %02X %02X  posted:%lu  own ring full:%lu  shared ring put:%lu full:%lu  ticks:%lu",
             x->callbacks, x->foreign, x->last_vm, x->sys_vm, (WORD)x->last[0], (WORD)x->last[1], (WORD)x->last[2], (WORD)x->last[3],
             x->posted, x->own_drop, x->shared_put, x->shared_drop, x->ticks);
    wsprintf(line(), "VMD  err bits: 1 no V86 callback  2 VMOUSE had a mouse at init  4 bad block  8 type changed later  10 own ring full  20 shared ring full  40 VMOUSE absent  80 DDB tail damaged (v3)");
}

static void show_ivt(void)
{
    static const BYTE ints[6] = { 0x08, 0x09, 0x15, 0x16, 0x1C, 0x2F };
    WORD FAR *ivt = (WORD FAR *)linear(0, 0x3FF);
    WORD v[12];
    int i;
    for (i = 0; i < 6; i++) { v[2 * i] = ivt[ints[i] * 2 + 1]; v[2 * i + 1] = ivt[ints[i] * 2]; }
    wsprintf(line(), "IVT  08:%04X:%04X  09:%04X:%04X  15:%04X:%04X  16:%04X:%04X  1C:%04X:%04X  2F:%04X:%04X",
             v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8], v[9], v[10], v[11]);
}

/* ---------------------------------------------------------- MAP */
/* 0 same, 1 different (twice), 2 no physical mapping */
static int page_differs(DWORD page)
{
    BYTE FAR *p, FAR *l;
    WORD i, pass;
    for (pass = 0; pass < 2; pass++) {
        p = physical(page, 0x1000);
        if (!p) return 2;
        l = linear(page, 0xFFF);
        for (i = 0; i < 0x1000; i++) if (l[i] != p[i]) break;
        if (i == 0x1000) return 0;
    }
    return 1;
}

static LPSTR verdict(int r)
{
    return (LPSTR)(r == 0 ? "same" : r == 1 ? "DIFFERS" : "n/a");
}

static void show_map(void)
{
    char uma[65];
    int i, r, diffs = 0;
    DWORD a;
    LPSTR l = line();
    wsprintf(l, "MAP  linear=physical?  page0(IVT, control):%s", verdict(page_differs(0)));
    if (key_seg) {
        a = ((DWORD)key_seg << 4) & 0xFFFFF000L;
        wsprintf(l + lstrlen(l), "  USOSKEY %05lX:%s", a, verdict(page_differs(a)));
    }
    if (stack08_ss) {
        a = (((DWORD)stack08_ss << 4) + stack08_sp) & 0xFFFFF000L;
        wsprintf(l + lstrlen(l), "  INT08 stack %05lX:%s", a, verdict(page_differs(a)));
    }
    if (stack4f_ss) {
        a = (((DWORD)stack4f_ss << 4) + stack4f_sp) & 0xFFFFF000L;
        wsprintf(l + lstrlen(l), "  USB 4Fh stack %05lX:%s", a, verdict(page_differs(a)));
    }
    for (i = 0; i < 64; i++) {
        r = page_differs(0xC0000L + ((DWORD)i << 12));
        uma[i] = r == 0 ? '.' : r == 1 ? 'X' : '?';
        if (r == 1) diffs++;
    }
    uma[64] = 0;
    wsprintf(line(), "MAP  C0000-FFFFF %s X:%d", (LPSTR)uma, diffs);
}

/* ---------------------------------------------------------- PCI */
static DWORD cfg(DWORD addr, BYTE reg)
{
    DWORD v = 0;
    addr = (addr & 0xFFFFFF00L) | reg;
    _asm {
        mov eax, addr
        mov dx, 0CF8h
        out dx, eax
        mov dx, 0CFCh
        in eax, dx
        mov v, eax
    }
    return v;
}

static BYTE xhci_bus[8];
static int nxhci;
static BYTE max_bus;

static void bdf(LPSTR l, DWORD a)
{
    DWORD id = cfg(a, 0), cs = cfg(a, 4);
    wsprintf(l + lstrlen(l), "%02X:%02X.%X %04X:%04X cmd:%04X sts:%04X",
             (WORD)(a >> 16) & 0xFF, (WORD)(a >> 11) & 0x1F, (WORD)(a >> 8) & 7,
             LOWORD(id), HIWORD(id), LOWORD(cs), HIWORD(cs));
}

static DWORD rd(BYTE FAR *base, WORD off)
{
    return *(DWORD FAR *)(base + off);
}

static void show_xhci(DWORD a)
{
    DWORD bar0 = cfg(a, 0x10), bar1 = cfg(a, 0x14), cap, hcs1, mf1, mf2;
    BYTE FAR *m;
    WORD op, rt, port, ports;
    LPSTR l = line();
    if (nxhci < 8) xhci_bus[nxhci++] = (BYTE)(a >> 16);
    wsprintf(l, "PCI xhci ");
    bdf(l, a);
    wsprintf(l + lstrlen(l), " bar0:%08lX bar1:%08lX int(3C):%08lX", bar0, bar1, cfg(a, 0x3C));
    l = line();
    wsprintf(l, "PCI  mmio ");
    if ((bar0 & 1) || ((bar0 & 6) == 4 && bar1) || !(bar0 & 0xFFFFFFF0L)) {
        wsprintf(l + lstrlen(l), "skipped: BAR not reachable");
        return;
    }
    m = physical(bar0 & 0xFFFFFFF0L, 0x10000L);
    if (!m) { wsprintf(l + lstrlen(l), "skipped: DPMI 0800h refused"); return; }
    cap = rd(m, 0);
    wsprintf(l + lstrlen(l), "cap:%08lX", cap);
    if (cap == 0xFFFFFFFFL) return;
    hcs1 = rd(m, 4);
    op = (WORD)(cap & 0xFF);
    rt = (WORD)(rd(m, 0x18) & 0xFFE0);
    mf1 = rd(m, rt);
    {   /* about 2 ms: MFINDEX counts 125 us microframes */
        DWORD t = GetTickCount();
        while (GetTickCount() - t < 3) ;
    }
    mf2 = rd(m, rt);
    wsprintf(l + lstrlen(l), " hcs1:%08lX usbcmd:%08lX usbsts:%08lX mfindex:%04X>%04X",
             hcs1, rd(m, op), rd(m, op + 4), (WORD)mf1 & 0x3FFF, (WORD)mf2 & 0x3FFF);
    l = line();
    wsprintf(l, "PCI  ports(connected):");
    ports = (WORD)(hcs1 >> 24);
    for (port = 1; port <= ports && port <= 64; port++) {
        DWORD sc = rd(m, op + 0x400 + 0x10 * (port - 1));
        if (!(sc & 1)) continue;
        if (lstrlen(l) > 90) { l = line(); wsprintf(l, "PCI  ports(cont.):"); }
        wsprintf(l + lstrlen(l), " %u=%08lX", port, sc);
    }
}

static void show_bridge(DWORD a)
{
    DWORD mem = cfg(a, 0x20);
    LPSTR l = line();
    wsprintf(l, "PCI  bridge ");
    bdf(l, a);
    wsprintf(l + lstrlen(l), " bus(18):%08lX ctl(3C):%08lX", cfg(a, 0x18), cfg(a, 0x3C));
    wsprintf(line(), "PCI   mem:%08lX-%08lX io/pf(1C,24,28,2C): %08lX %08lX %08lX %08lX",
             (mem << 16) & 0xFFF00000L, (mem & 0xFFF00000L) | 0xFFFFFL,
             cfg(a, 0x1C), cfg(a, 0x24), cfg(a, 0x28), cfg(a, 0x2C));
}

static void scan(int pass)
{
    WORD bus, dev, fn, fns;
    int i;
    for (bus = 0; bus <= max_bus; bus++) {
        for (dev = 0; dev < 32; dev++) {
            fns = 1;
            for (fn = 0; fn < fns; fn++) {
                DWORD a = 0x80000000L | ((DWORD)bus << 16) | ((DWORD)dev << 11) | ((DWORD)fn << 8);
                DWORD id = cfg(a, 0), cls, hdr;
                if (LOWORD(id) == 0xFFFF) continue;
                hdr = cfg(a, 0x0C);
                if (fn == 0 && (hdr & 0x00800000L)) fns = 8;
                cls = cfg(a, 0x08) >> 8;
                if (cls == 0x0C0330L) {
                    if (pass == 0) show_xhci(a);
                } else if (((hdr >> 16) & 0x7F) == 1) {
                    DWORD b = cfg(a, 0x18);
                    BYTE sec = (BYTE)(b >> 8), sub = (BYTE)(b >> 16);
                    if (sub > max_bus) max_bus = sub;
                    if (pass == 1)
                        for (i = 0; i < nxhci; i++)
                            if (xhci_bus[i] >= sec && xhci_bus[i] <= sub) { show_bridge(a); break; }
                }
            }
        }
    }
}

static void show_pci(void)
{
    nxhci = 0;
    max_bus = 0;
    if (LOWORD(cfg(0x80000000L, 0)) == 0xFFFF) {
        wsprintf(line(), "PCI none (00:00.0 reads FFFF)");
        return;
    }
    scan(0);
    scan(1);
    wsprintf(line(), "PCI xhci:%d lastbus:%02X", nxhci, (WORD)max_bus);
}

/* ---------------------------------------------------------- IRQ */
/* Every network controller (class 02h) and the I211 (8086:1539): config
 * 3Ch, command / status, MSI / MSI-X state, the bridges above it; ELCR
 * (4D0h/4D1h), the 8259 masks as VPICD shows them to the system VM (IRR /
 * ISR are not read: OCW3 would be a write), and the $PIR table in
 * F0000-FFFFF with the NIC's entries marked. Only reads (no MMIO). */
#define MAXNIC 4
#define MAXBR  32
static DWORD nic_at[MAXNIC], br_at[MAXBR];
static BYTE br_sec[MAXBR], br_sub[MAXBR];
static int nnic, nbr;

static BYTE inb(WORD port)
{
    BYTE v = 0;
    _asm {
        mov dx, port
        in al, dx
        mov v, al
    }
    return v;
}

static void find_nics(void)
{
    WORD bus, dev, fn, fns, last = 0;
    nnic = nbr = 0;
    for (bus = 0; bus <= last; bus++) {
        for (dev = 0; dev < 32; dev++) {
            fns = 1;
            for (fn = 0; fn < fns; fn++) {
                DWORD a = 0x80000000L | ((DWORD)bus << 16) | ((DWORD)dev << 11) | ((DWORD)fn << 8);
                DWORD id = cfg(a, 0), cls, hdr;
                if (LOWORD(id) == 0xFFFF) continue;
                hdr = cfg(a, 0x0C);
                if (fn == 0 && (hdr & 0x00800000L)) fns = 8;
                cls = cfg(a, 0x08) >> 8;
                if (((cls >> 16) == 0x02 || id == 0x15398086L) && nnic < MAXNIC) nic_at[nnic++] = a;
                if (((hdr >> 16) & 0x7F) == 1 && nbr < MAXBR) {
                    DWORD b = cfg(a, 0x18);
                    br_at[nbr] = a;
                    br_sec[nbr] = (BYTE)(b >> 8);
                    br_sub[nbr] = (BYTE)(b >> 16);
                    if (br_sub[nbr] > last && br_sub[nbr] != 0xFF) last = br_sub[nbr];
                    nbr++;
                }
            }
        }
    }
}

static void irq_list(LPSTR t, WORD bits)
{
    WORD i;
    for (i = 0; i < 16; i++) if (bits & (1 << i)) wsprintf(t + lstrlen(t), " %u", i);
    if (!bits) lstrcat(t, " none");
}

static void show_nic(DWORD a)
{
    DWORD id = cfg(a, 0), cs = cfg(a, 4), il = cfg(a, 0x3C), cls = cfg(a, 0x08) >> 8;
    WORD cmd = LOWORD(cs), sts = HIWORD(cs), pin = (WORD)(il >> 8) & 0xFF, bus = (WORD)(a >> 16) & 0xFF;
    BYTE ptr;
    int n, i;
    LPSTR l = line();
    wsprintf(l, "NIC %02X:%02X.%X %04X:%04X%s class %06lX cmd:%04X (INTx %s, mem %s, master %s) sts:%04X (int %u) line:%02X pin:%c 3C:%08lX bar0:%08lX",
             bus, (WORD)(a >> 11) & 0x1F, (WORD)(a >> 8) & 7, LOWORD(id), HIWORD(id),
             (LPSTR)(id == 0x15398086L ? " (I211)" : ""), cls, cmd,
             (LPSTR)((cmd & 0x400) ? "DISABLED" : "on"), (LPSTR)((cmd & 2) ? "on" : "off"),
             (LPSTR)((cmd & 4) ? "on" : "off"), sts, (sts >> 3) & 1, (WORD)il & 0xFF,
             pin >= 1 && pin <= 4 ? 'A' + pin - 1 : '-', il, cfg(a, 0x10));
    l = line();
    wsprintf(l, "NIC  caps:");
    if (!(sts & 0x10)) lstrcat(l, " none");
    else {
        ptr = (BYTE)(cfg(a, 0x34) & 0xFC);
        for (n = 0; ptr >= 0x40 && n < 48 && lstrlen(l) < 200; n++) {
            DWORD c = cfg(a, ptr);
            WORD capid = (WORD)c & 0xFF, ctl = HIWORD(c);
            if (capid == 0x05)
                wsprintf(l + lstrlen(l), " MSI@%02X ctl:%04X (%s)", (WORD)ptr, ctl, (LPSTR)((ctl & 1) ? "ENABLED" : "off"));
            else if (capid == 0x11)
                wsprintf(l + lstrlen(l), " MSI-X@%02X ctl:%04X (%s%s)", (WORD)ptr, ctl,
                         (LPSTR)((ctl & 0x8000) ? "ENABLED" : "off"), (LPSTR)((ctl & 0x4000) ? ", masked" : ""));
            else wsprintf(l + lstrlen(l), " %02X@%02X", capid, (WORD)ptr);
            ptr = (BYTE)((c >> 8) & 0xFC);
        }
    }
    for (i = 0; i < nbr; i++) {
        if (bus < br_sec[i] || bus > br_sub[i]) continue;
        l = line();
        wsprintf(l, "NIC  bridge above: ");
        bdf(l, br_at[i]);
        wsprintf(l + lstrlen(l), " bus %02X-%02X ctl(3C):%08lX", (WORD)br_sec[i], (WORD)br_sub[i], cfg(br_at[i], 0x3C));
    }
}

/* 1 = the $PIR entry for bus / device belongs to a NIC (2: a bridge above one) */
static int pir_mark(WORD bus, WORD dev)
{
    int i, j;
    for (i = 0; i < nnic; i++)
        if (((nic_at[i] >> 16) & 0xFF) == bus && ((nic_at[i] >> 11) & 0x1F) == dev) return 1;
    for (j = 0; j < nbr; j++) {
        if (((br_at[j] >> 16) & 0xFF) != bus || ((br_at[j] >> 11) & 0x1F) != dev) continue;
        for (i = 0; i < nnic; i++) {
            WORD nb = (WORD)(nic_at[i] >> 16) & 0xFF;
            if (nb >= br_sec[j] && nb <= br_sub[j]) return 2;
        }
    }
    return 0;
}

static void show_pir(void)
{
    BYTE FAR *f = physical(0xF0000L, 0x10000L);
    DWORD o;
    WORD size, i, n, sum;
    LPSTR l = 0;
    if (!f) { wsprintf(line(), "PIR  F0000-FFFFF not mapped (DPMI 0800h refused)"); return; }
    for (o = 0; o + 32 <= 0x10000L; o += 16) {
        BYTE FAR *p = f + (WORD)o;
        if (p[0] != '$' || p[1] != 'P' || p[2] != 'I' || p[3] != 'R') continue;
        size = *(WORD FAR *)(p + 6);
        if (size < 32 || o + size > 0x10000L) continue;
        for (sum = 0, i = 0; i < size; i++) sum += p[i];
        n = (size - 32) / 16;
        l = line();
        wsprintf(l, "PIR  at F%04X: version %u.%u size %u (%u entries) router %02X:%02X.%X compatible %04X:%04X miniport %08lX checksum %s  exclusive IRQs %04X:",
                 (WORD)o, (WORD)p[5], (WORD)p[4], size, n, (WORD)p[8], (WORD)p[9] >> 3, (WORD)p[9] & 7,
                 *(WORD FAR *)(p + 12), *(WORD FAR *)(p + 14), *(DWORD FAR *)(p + 16),
                 (LPSTR)((sum & 0xFF) ? "BAD" : "ok"), *(WORD FAR *)(p + 10));
        irq_list(l, *(WORD FAR *)(p + 10));
        for (i = 0; i < n && i < 32; i++) {
            BYTE FAR *e = p + 32 + i * 16;
            int m = pir_mark(e[0], e[1] >> 3);
            if (i % 2 == 0) { l = line(); wsprintf(l, "PIR "); }
            wsprintf(l + lstrlen(l), " %02X:%02X slot %u A:%02X/%04X B:%02X/%04X C:%02X/%04X D:%02X/%04X%s",
                     (WORD)e[0], (WORD)e[1] >> 3, (WORD)e[14], (WORD)e[2], *(WORD FAR *)(e + 3), (WORD)e[5],
                     *(WORD FAR *)(e + 6), (WORD)e[8], *(WORD FAR *)(e + 9), (WORD)e[11], *(WORD FAR *)(e + 12),
                     (LPSTR)(m == 1 ? " <-NIC" : m == 2 ? " <-bridge above NIC" : ""));
        }
        if (n > 32) wsprintf(line(), "PIR  (%u more entries not shown)", n - 32);
        return;
    }
    wsprintf(line(), "PIR  none in F0000-FFFFF (no $PIR table: the OS has only ACPI _PRT / its own routing)");
}

static void show_irq(void)
{
    WORD elcr, imr, i;
    LPSTR l;
    if (LOWORD(cfg(0x80000000L, 0)) == 0xFFFF) return;
    find_nics();
    if (!nnic) wsprintf(line(), "NIC  no network controller (class 02h) found");
    for (i = 0; i < (WORD)nnic; i++) show_nic(nic_at[i]);
    elcr = inb(0x4D0) | ((WORD)inb(0x4D1) << 8);
    imr = inb(0x21) | ((WORD)inb(0xA1) << 8);
    l = line();
    wsprintf(l, "IRQ  ELCR 4D0/4D1:%02X %02X  level:", elcr & 0xFF, elcr >> 8);
    irq_list(l, elcr);
    wsprintf(l + lstrlen(l), "  IMR 21/A1:%02X %02X (VPICD's view for the system VM) masked:", imr & 0xFF, imr >> 8);
    irq_list(l, imr);
    for (i = 0; i < (WORD)nnic; i++) {
        WORD irq = (WORD)cfg(nic_at[i], 0x3C) & 0xFF;
        if (irq >= 16) {
            wsprintf(line(), "IRQ  NIC %02X:%02X.%X line %02X: no ISA IRQ assigned", (WORD)(nic_at[i] >> 16) & 0xFF,
                     (WORD)(nic_at[i] >> 11) & 0x1F, (WORD)(nic_at[i] >> 8) & 7, irq);
            continue;
        }
        wsprintf(line(), "IRQ  NIC %02X:%02X.%X line %u: %s in ELCR (PCI INTx wants level), %s in IMR%s",
                 (WORD)(nic_at[i] >> 16) & 0xFF, (WORD)(nic_at[i] >> 11) & 0x1F, (WORD)(nic_at[i] >> 8) & 7, irq,
                 (LPSTR)((elcr >> irq) & 1 ? "level" : "EDGE"), (LPSTR)((imr >> irq) & 1 ? "MASKED" : "unmasked"),
                 (LPSTR)(irq >= 8 && (imr & 4) ? ", cascade IRQ 2 MASKED" : ""));
    }
    show_pir();
}

/* ---------------------------------------------------------- NET */
/* usosnet 0.4 statistics page (/N physical address): raw hex, USOSLOG
 * decodes it (layout: tools/nt/usosnet/src/usosnet_proto.h, USNS_BLOCK). */
static void show_net(void)
{
    BYTE FAR *b;
    DWORD FAR *d;
    WORD size, r, i;
    LPSTR l;
    if (!net_pa) return;
    b = physical(net_pa & 0xFFFFF000L, 0x1000);
    if (!b) { wsprintf(line(), "USNS %08lX: DPMI 0800h refused", net_pa); return; }
    b += (WORD)(net_pa & 0xFFF);
    d = (DWORD FAR *)b;
    if (d[0] != 0x534E5355L) { wsprintf(line(), "USNS %08lX: no USNS magic (%08lX)", net_pa, d[0]); return; }
    size = d[2] > 0x1000 - (net_pa & 0xFFF) ? (WORD)(0x1000 - (net_pa & 0xFFF)) : (WORD)d[2];
    wsprintf(line(), "USNS %08lX: version %lu size %u", net_pa, d[1], size);
    for (r = 0; r < size; r += 64) {
        l = line();
        wsprintf(l, "USNS+%03X:", r);
        for (i = r; i < size && i < r + 64; i++) wsprintf(l + lstrlen(l), "%02X", (WORD)b[i]);
    }
}

/* ---------------------------------------------------------- DISK */
/* USB disk service (docs/usb9x-hotswap-design-2026-10-19.md section 4):
 * SeaBIOS's "USOS" "UDSK" record (CSMWrap 3.1.2-usos16 patch 0021, first
 * MiB, 16-byte aligned), the channel 1 words after the "CSMPPrxy" mailbox
 * in the F-segment, and the USOSUSB.MPD status page at channel req_phys +
 * UDS_MP_STATUS_OFFSET (layouts: usosuds.h). Every value is untrusted:
 * counts are clamped, nothing is read outside the first MiB or the status
 * page; only reads. The record and the page are copied first (one
 * consistent view) and the copy's signature is cleared, so a later scan
 * (this or another USOSDBG) never finds a copy in a Win16 data segment.
 * The status page is mapped per run (one DPMI 0800h page, a cached mapping
 * over the miniport's uncached block: read only). */
typedef char uds_diag_size_check[sizeof(struct uds_diag) == 984 ? 1 : -1];
typedef char uds_dev_size_check[sizeof(struct uds_diag_dev) == 64 ? 1 : -1];
typedef char uds_disk_size_check[sizeof(struct uds_diag_disk) == 12 ? 1 : -1];
typedef char uds_mp_size_check[sizeof(struct uds_mp_status) == 104 ? 1 : -1];
typedef char uds_ring_size_check[sizeof(struct uds_mp_ring) == 528 ? 1 : -1];
typedef char uds_media_size_check[sizeof(struct uds_diag_media) == 16 ? 1 : -1];

/* DISK-DECODE-BEGIN (compiled on the host by tools/tests/usb9x/test_usosdbg_disk.py) */
static const char *uds_state_name(BYTE s)
{
    switch (s) {
    case UDS_DEV_EMPTY: return "empty";
    case UDS_DEV_PRESENT: return "present";
    case UDS_DEV_GONE: return "GONE (removed)";
    case UDS_DEV_EJECTED: return "ejected";
    case UDS_DEV_FAILED: return "FAILED (see events)";
    }
    return "?";
}

static const char *uds_status_name(DWORD s)
{
    if (s == UDS_S_PENDING) return "pending";
    switch ((WORD)(s > 0xFF ? 0xFF : s)) {
    case UDS_S_OK: return "ok";
    case UDS_S_CHECK: return "check condition";
    case UDS_S_NODEV: return "no device";
    case UDS_S_GONE: return "gone";
    case UDS_S_TIMEOUT: return "timeout";
    case UDS_S_PHASE: return "phase error";
    case UDS_S_BADREQ: return "bad request";
    case UDS_S_OWNED: return "owned by INT 13h";
    case UDS_S_HWFAIL: return "xHCI failed";
    }
    return "?";
}

static const char *uds_why_name(DWORD w)
{
    static const char *const n[11] = { "ok", "magic", "version", "size", "op", "dev", "lun", "cdb", "dir", "len",
                                       "addr" };
    return w <= UDS_WHY_ADDR ? n[(WORD)w] : "?";
}

static const char *uds_ev_name(BYTE e)
{
    static const char *const n[18] = { "?", "present", "GONE", "reset", "eject", "badreq", "HWFAIL", "TIMEOUT",
                                       "PHASE", "REGFAIL", "stall", "plugged in", "PLUG FAILED", "connect",
                                       "unplugged", "connected, not set up at POST", "media", "watch armed" };
    return e <= UDS_EV_ARM ? n[e] : "?";
}

/* UDS_AF_*: why a stick plugged in at runtime was not brought up */
static const char *uds_af_name(BYTE r)
{
    static const char *const n[12] = { "?", "port reset", "Enable Slot", "Address Device", "device descriptor",
                                       "config descriptor", "not a USB stick (no bulk-only mass storage)",
                                       "SET_CONFIGURATION", "Configure Endpoint", "both hot-plug slots in use",
                                       "device table full", "EP0 packet size" };
    return r <= UDS_AF_MPS ? n[r] : "?";
}

/* UDS_FS_*: what the media check found, and whether Windows 9x reads it */
static const char *uds_fs_name(BYTE f)
{
    switch (f) {
    case UDS_FS_UNREAD: return "not checked";
    case UDS_FS_READFAIL: return "sector read failed";
    case UDS_FS_NOSIG: return "no 55AA signature (blank or not a PC disk) - 9x cannot use it";
    case UDS_FS_FAT12: return "FAT12 - 9x reads it";
    case UDS_FS_FAT16: return "FAT16 - 9x reads it";
    case UDS_FS_FAT32: return "FAT32 - 9x reads it (95 OSR2 and later)";
    case UDS_FS_NTFS: return "NTFS - 9x cannot read it (format the stick FAT32)";
    case UDS_FS_EXFAT: return "exFAT - 9x cannot read it (format the stick FAT32)";
    case UDS_FS_GPT: return "GPT partition table - 9x cannot read it (use MBR + FAT32)";
    case UDS_FS_OTHER: return "MBR, unknown file system - 9x probably cannot read it";
    }
    return "?";
}

static const char *uds_phase_name(BYTE r)
{
    switch (r) {
    case 1: return "CBW";
    case 2: return "data";
    case 3: return "CSW";
    case 4: return "CSW signature/tag";
    case 5: return "CSW status 2";
    }
    return "?";
}

/* the result byte as the UDS_EV_* comment defines it */
static void uds_ev_result(LPSTR t, BYTE e, BYTE r)
{
    switch (e) {
    case UDS_EV_PRESENT: wsprintf(t, "luns %u", (WORD)r); break;
    case UDS_EV_GONE: wsprintf(t, "during op %02Xh", (WORD)r); break;
    case UDS_EV_RESET: wsprintf(t, "%s", (LPSTR)(r == 0 ? "ok" : r == 1 ? "failed" : "?")); break;
    case UDS_EV_BADREQ: wsprintf(t, "why %u %s", (WORD)r, (LPSTR)uds_why_name(r)); break;
    case UDS_EV_HWFAIL:
        wsprintf(t, "%s", (LPSTR)(r == 1 ? "registers all ones" : r == 2 ? "halted / host system error" : "?"));
        break;
    case UDS_EV_TIMEOUT:
    case UDS_EV_PHASE:
    case UDS_EV_STALL: wsprintf(t, "phase %u %s", (WORD)r, (LPSTR)uds_phase_name(r)); break;
    case UDS_EV_REGFAIL: wsprintf(t, "%s", (LPSTR)(r == 1 ? "table full" : r == 2 ? "INQUIRY failed" : "?")); break;
    case UDS_EV_ATTACH: wsprintf(t, "luns %u", (WORD)r); break;
    case UDS_EV_ATTFAIL: wsprintf(t, "%u %s", (WORD)r, (LPSTR)uds_af_name(r)); break;
    case UDS_EV_CONNECT:
    case UDS_EV_UNCLAIMED: wsprintf(t, "link state %u", (WORD)r); break;
    case UDS_EV_DETACH: wsprintf(t, "%s", (LPSTR)(r ? "replugged at once" : "port empty")); break;
    case UDS_EV_MEDIA: wsprintf(t, "%s", (LPSTR)uds_fs_name(r)); break;
    case UDS_EV_ARM: wsprintf(t, "%u xHCI", (WORD)r); break;
    default: wsprintf(t, "result %u", (WORD)r); break;
    }
}

/* SeaBIOS block.h DTYPE_* */
static const char *uds_dtype_name(BYTE t)
{
    switch (t) {
    case 0x00: return "none";
    case 0x10: return "floppy";
    case 0x20: return "ATA";
    case 0x21: return "ATAPI";
    case 0x30: return "ramdisk";
    case 0x40: return "CD emulation";
    case 0x50: return "AHCI";
    case 0x51: return "AHCI ATAPI";
    case 0x60: return "virtio-scsi";
    case 0x61: return "virtio-blk";
    case 0x70: return "USB MSC";
    case 0x71: return "USB MSC (32)";
    case 0x72: return "UAS";
    case 0x73: return "UAS (32)";
    case 0x80: return "LSI SCSI";
    case 0x81: return "ESP SCSI";
    case 0x82: return "MegaRAID";
    case 0x83: return "PVSCSI";
    case 0x84: return "MPT SCSI";
    case 0x90: return "SD card";
    case 0x91: return "NVMe";
    }
    return "?";
}

/* SeaBIOS USB_*SPEED */
static const char *uds_speed_name(BYTE s)
{
    switch (s) {
    case 0: return "full";
    case 1: return "low";
    case 2: return "high";
    case 3: return "super";
    }
    return "?";
}

static const char *scsi_op_name(BYTE op)
{
    switch (op) {
    case 0x00: return "TEST UNIT READY";
    case 0x03: return "REQUEST SENSE";
    case 0x12: return "INQUIRY";
    case 0x1A: return "MODE SENSE(6)";
    case 0x1B: return "START STOP UNIT";
    case 0x1E: return "PREVENT ALLOW";
    case 0x23: return "READ FORMAT CAPACITIES";
    case 0x25: return "READ CAPACITY(10)";
    case 0x28: return "READ(10)";
    case 0x2A: return "WRITE(10)";
    case 0x2F: return "VERIFY(10)";
    case 0x35: return "SYNCHRONIZE CACHE";
    case 0x5A: return "MODE SENSE(10)";
    case 0x88: return "READ(16)";
    case 0x8A: return "WRITE(16)";
    case 0x9E: return "READ CAPACITY(16)";
    }
    return "";
}

/* Count blocks of Bs bytes in MiB (Bs a power of two up to 1 MiB, else
 * FFFFFFFFh = unknown; FFFFFFFEh = does not fit) */
static DWORD uds_mib(DWORD lo, DWORD hi, DWORD bs)
{
    WORD k, sh;
    for (k = 0; k <= 20 && (1UL << k) != bs; k++) ;
    if (k > 20) return 0xFFFFFFFFUL;
    sh = 20 - k;
    if (sh == 0) return hi ? 0xFFFFFFFEUL : lo;
    if (hi >> sh) return 0xFFFFFFFEUL;
    return (lo >> sh) | (hi << (32 - sh));
}

static void uds_mib_text(LPSTR t, DWORD mib)
{
    if (mib == 0xFFFFFFFFUL) wsprintf(t, "? MiB");
    else if (mib == 0xFFFFFFFEUL) wsprintf(t, "too big");
    else wsprintf(t, "%lu MiB", mib);
}

/* the record (a copy) found at At; Chan = the CSMPPrxy+48 address found in
 * the F-segment, 0 none */
/* version 2 (CSMWrap 3.1.2-usos17, hot-swap): the port watch and the media check */
static void show_disk_v2(const struct uds_diag *d, WORD devs)
{
    WORD i, c;
    char b[24];
    if (!d->pool) {
        wsprintf(line(), "DISK hot-swap: off (no runtime pool: csmwrap.ini without int13_boot_disk_only)");
    } else {
        LPSTR l = line();
        wsprintf(l, "DISK hot-swap: watch %s  passes %lu  plugged in %lu  unplugged %lu  failed %lu",
                 (LPSTR)(d->armed ? "armed" : "not armed yet (no channel 1 request)"), (DWORD)d->watch_passes,
                 (DWORD)d->attaches, (DWORD)d->detaches, (DWORD)d->attach_fails);
        if (d->attach_fails)
            wsprintf(l + lstrlen(l), " (last: %s)", (LPSTR)uds_af_name(d->last_fail));
        wsprintf(l + lstrlen(l), "  pool %08lX used %u%u", (DWORD)d->pool, (WORD)(d->pool_used & 1),
                 (WORD)((d->pool_used >> 1) & 1));
    }
    c = d->ctls > UDS_DIAG_CTLS ? UDS_DIAG_CTLS : d->ctls;
    for (i = 0; i < c; i++) {
        const struct uds_diag_ctl *x = &d->ctl[i];
        wsprintf(line(), "DISK  xHCI%u: ports %lu  connected at POST %08lX  set up at POST %08lX  connected now %08lX (bit 0 = port 1)",
                 i, (DWORD)x->ports, (DWORD)x->ccs_post, (DWORD)x->busy_arm, (DWORD)x->ccs_now);
    }
    for (i = 0; i < devs; i++) {
        const struct uds_diag_media *m = &d->media[i];
        if (d->dev[i].state == UDS_DEV_EMPTY) continue;
        if (m->ctl == 0xFF) wsprintf(b, "-");
        else wsprintf(b, "xHCI%u", (WORD)m->ctl);
        wsprintf(line(), "DISK  dev %u media: %s  MBR types %02X %02X %02X %02X  volume at LBA %lu  sector 0 FNV %08lX  %s  %s",
                 i, (LPSTR)uds_fs_name(m->fs), (WORD)m->types[0], (WORD)m->types[1], (WORD)m->types[2],
                 (WORD)m->types[3], (DWORD)m->part_lba, (DWORD)m->hash0,
                 (LPSTR)(m->attach ? "plugged in after boot" : "present at POST"), (LPSTR)b);
    }
}

static void show_disk_record(const struct uds_diag *d, DWORD at, DWORD chan)
{
    WORD i, n, devs, disks, first;
    DWORD events;
    char a[48], b[96], c[20];   /* b: an event result, up to 70 characters (usos17 media names) */
    LPSTR l = 0;
    if (d->version != 1 && d->version != UDS_DIAG_VERSION) {
        wsprintf(line(), "DISK USOSUDSK at %05lX: version %u not decoded (USOSDBG knows version %u)", at,
                 (WORD)d->version, (WORD)UDS_DIAG_VERSION);
        return;
    }
    if (!d->channel) wsprintf(a, " (no channel 1 request served yet)");
    else if (!chan) wsprintf(a, " (no CSMPPrxy found)");
    else if ((DWORD)d->channel == chan) wsprintf(a, " (= CSMPPrxy+48)");
    else wsprintf(a, " (CSMPPrxy+48 is %05lX: DIFFERS)", chan);
    wsprintf(line(), "DISK USOSUDSK at %05lX: version %u  devs %u  disks %u  services %lu  badreq %lu  last why %lu %s  events %lu (next slot %u)  channel %08lX%s",
             at, (WORD)d->version, (WORD)d->devs, (WORD)d->disks, (DWORD)d->services, (DWORD)d->badreq,
             (DWORD)d->last_why, (LPSTR)uds_why_name(d->last_why), (DWORD)d->events, (WORD)d->next_event,
             (DWORD)d->channel, (LPSTR)a);
    devs = d->devs > UDS_MAX_DEVS ? UDS_MAX_DEVS : d->devs;
    if (d->devs > UDS_MAX_DEVS)
        wsprintf(line(), "DISK  devs %u > %u: the first %u shown", (WORD)d->devs, UDS_MAX_DEVS, UDS_MAX_DEVS);
    if (!devs) wsprintf(line(), "DISK  no entry in the UDS table (no stick without a BIOS number at POST)");
    for (i = 0; i < devs; i++) {
        const struct uds_diag_dev *v = &d->dev[i];
        DWORD lo = (DWORD)v->last_lba_lo + 1, hi = (DWORD)v->last_lba_hi + (lo == 0 ? 1 : 0);
        if (v->bios_drive) wsprintf(b, "BIOS %02Xh", (WORD)v->bios_drive);
        else wsprintf(b, "not mapped");
        uds_mib_text(a, uds_mib(lo, hi, (DWORD)v->block_size));
        if (v->last_lba_hi) wsprintf(c, "%lX%08lX", (DWORD)v->last_lba_hi, (DWORD)v->last_lba_lo);
        else wsprintf(c, "%lX", (DWORD)v->last_lba_lo);
        wsprintf(line(), "DISK  dev %u: %s  %s  luns %u  port %u  %04X:%04X  slot %u  %s speed  gen %lu  block %lu  %s (last LBA %s)",
                 i, (LPSTR)uds_state_name(v->state), (LPSTR)b, (WORD)v->luns, (WORD)v->port, (WORD)v->vid,
                 (WORD)v->pid, (WORD)v->slotid, (LPSTR)uds_speed_name(v->speed), (DWORD)v->generation,
                 (DWORD)v->block_size, (LPSTR)a, (LPSTR)c);
        wsprintf(line(), "DISK  dev %u: requests %lu  checks %lu  timeouts %lu  resets %lu  gone %lu  refused %lu  in %lu KiB  out %lu KiB",
                 i, (DWORD)v->requests, (DWORD)v->checks, (DWORD)v->timeouts, (DWORD)v->resets, (DWORD)v->gone,
                 (DWORD)v->refused, (DWORD)v->kib_in, (DWORD)v->kib_out);
        wsprintf(line(), "DISK  dev %u: last op %02Xh %s  CSW %u  sense %X/%02X/%02X  status %u %s",
                 i, (WORD)v->last_op, (LPSTR)scsi_op_name(v->last_op), (WORD)v->last_csw, (WORD)v->last_key,
                 (WORD)v->last_asc, (WORD)v->last_ascq, (WORD)v->last_status,
                 (LPSTR)uds_status_name((DWORD)v->last_status));
    }
    disks = d->disks > UDS_DIAG_DISKS ? UDS_DIAG_DISKS : d->disks;
    wsprintf(line(), "DISK BIOS disk table: %u entr%s%s", (WORD)d->disks, (LPSTR)(d->disks == 1 ? "y" : "ies"),
             (LPSTR)(d->disks > UDS_DIAG_DISKS ? " (more than 8: 8 shown)" :
                     d->disks ? "" : " (filled at the first channel 1 request)"));
    for (i = 0; i < disks; i++) {
        const struct uds_diag_disk *k = &d->disk[i];
        if (!k->bios) continue;
        if (k->uds) wsprintf(b, "  UDS stick %u", (WORD)(k->uds - 1));
        else b[0] = 0;
        uds_mib_text(a, uds_mib((DWORD)k->sectors_lo, (DWORD)k->sectors_hi, 512));
        if (k->sectors_hi)
            wsprintf(line(), "DISK  %02Xh %s (%02Xh)%s  %lX%08lX sectors (%s)", (WORD)k->bios,
                     (LPSTR)uds_dtype_name(k->dtype), (WORD)k->dtype, (LPSTR)b, (DWORD)k->sectors_hi,
                     (DWORD)k->sectors_lo, (LPSTR)a);
        else
            wsprintf(line(), "DISK  %02Xh %s (%02Xh)%s  %lu sectors (%s)", (WORD)k->bios,
                     (LPSTR)uds_dtype_name(k->dtype), (WORD)k->dtype, (LPSTR)b, (DWORD)k->sectors_lo, (LPSTR)a);
    }
    /* the ring, oldest first: the last min(events, 16) before next_event */
    events = (DWORD)d->events;
    n = events < UDS_DIAG_EVENTS ? (WORD)events : UDS_DIAG_EVENTS;
    first = (WORD)((d->next_event - n) & (UDS_DIAG_EVENTS - 1));
    wsprintf(line(), "DISK events: %lu since boot, last %u (oldest first; ms = SeaBIOS timer)", events, n);
    for (i = 0; i < n; i++) {
        const struct uds_diag_event *e = &d->ev[(first + i) & (UDS_DIAG_EVENTS - 1)];
        if (i % 2 == 0) { l = line(); wsprintf(l, "DISK "); }
        uds_ev_result(b, e->event, e->result);
        if (e->dev == 0xFF) wsprintf(a, "-");
        else if (e->dev >= 0xF0) wsprintf(a, "xHCI%u", (WORD)(e->dev & 0x0F));
        else wsprintf(a, "%u", (WORD)e->dev);
        wsprintf(l + lstrlen(l), " #%lu %lums dev %s port %u %s (%s);", events - n + i, (DWORD)e->ms, (LPSTR)a,
                 (WORD)e->port, (LPSTR)uds_ev_name(e->event), (LPSTR)b);
    }
    if (d->version >= 2) show_disk_v2(d, devs);
}

/* channel 1 (a copy) of the CSMPPrxy mailbox at F-segment offset Off */
static void show_disk_channel(const struct uds_channel *c, WORD off)
{
    DWORD m = (DWORD)c->magic;
    wsprintf(line(), "DISK channel at F%04X (CSMPPrxy+48): magic %08lX (%s)  req_phys %08lX  doorbell %lu  done %lu%s",
             off + UDS_CH1_OFFSET, m, (LPSTR)(m == UDS_CH1_MAGIC ? "UDS1" : "not UDS1: CSMWrap before usos16"),
             (DWORD)c->req_phys, (DWORD)c->doorbell, (DWORD)c->done,
             (LPSTR)(c->doorbell != c->done ? "  (request in flight)" : ""));
}

/* the USOSUSB.MPD status page (a copy) at physical At */
static void show_disk_mp(const struct uds_mp_status *s, DWORD at)
{
    WORD i, n;
    LPSTR l = 0;
    if (s->sig[0] != UDS_MP_SIG0 || s->sig[1] != UDS_MP_SIG1) {
        wsprintf(line(), "DISK USOSUSB.MPD status at %08lX: no USOSUMPS signature (%08lX %08lX)", at,
                 (DWORD)s->sig[0], (DWORD)s->sig[1]);
        return;
    }
    l = line();
    wsprintf(l, "DISK USOSUSB.MPD %u.%u status at %08lX: version %u  slots %u  srbs %lu  posted %lu  polled %lu  errors %lu  enums %lu  last status %lu %s",
             (WORD)s->mp_major, (WORD)s->mp_minor, at, (WORD)s->version, (WORD)s->slots, (DWORD)s->srbs,
             (DWORD)s->posted, (DWORD)s->polled, (DWORD)s->errors, (DWORD)s->enums, (DWORD)s->last_status,
             (LPSTR)uds_status_name((DWORD)s->last_status));
    if (s->version >= 2)
        wsprintf(l + lstrlen(l), "  not ready (empty slot) %lu", (DWORD)s->notready);
    if (s->version != 1 && s->version != UDS_MP_VERSION) {
        wsprintf(line(), "DISK  status version %u: slots not decoded (USOSDBG knows version %u)", (WORD)s->version,
                 (WORD)UDS_MP_VERSION);
        return;
    }
    n = s->slots > UDS_MP_SLOTS ? UDS_MP_SLOTS : s->slots;
    for (i = 0; i < n; i++) {
        const struct uds_mp_slot *t = &s->slot[i];
        char dev[8];
        if (t->dev == 0xFF) wsprintf(dev, "none");
        else wsprintf(dev, "%u", (WORD)t->dev);
        if (i % 2 == 0) { l = line(); wsprintf(l, "DISK "); }
        wsprintf(l + lstrlen(l), " slot %u: dev %s %s%s gen %lu srbs %lu last op %02Xh SRB status %02X sense %X/%02X/%02X;",
                 i, (LPSTR)dev, (LPSTR)(t->present ? "present" : "absent"), (LPSTR)(t->ua_pending ? " UA pending" : ""),
                 (DWORD)t->generation, (DWORD)t->srbs, (WORD)t->last_op, (WORD)t->last_srb_status, (WORD)t->last_key,
                 (WORD)t->last_asc, (WORD)t->last_ascq);
    }
}
static const char *uds_op_name(BYTE op)
{
    switch (op) {
    case 0x00: return "TEST UNIT READY";
    case 0x03: return "REQUEST SENSE";
    case 0x12: return "INQUIRY";
    case 0x1A: return "MODE SENSE(6)";
    case 0x1B: return "START STOP";
    case 0x1E: return "PREVENT/ALLOW";
    case 0x25: return "READ CAPACITY";
    case 0x28: return "READ(10)";
    case 0x2A: return "WRITE(10)";
    case 0x2F: return "VERIFY(10)";
    case 0x35: return "SYNC CACHE";
    case 0x5A: return "MODE SENSE(10)";
    }
    return "";
}

/* the USOSUSB.MPD 1.1 request ring (a copy): the last Max entries, oldest first */
static void show_disk_ring(const struct uds_mp_ring *r, DWORD at, WORD max)
{
    WORD i, n;
    DWORD count = (DWORD)r->count;
    if (r->sig[0] != UDS_MP_SIG0 || r->sig[1] != UDS_MP_RSIG1) {
        wsprintf(line(), "DISK request ring at %08lX: no URNG signature (USOSUSB.MPD 1.0?)", at);
        return;
    }
    n = count < UDS_MP_RING ? (WORD)count : UDS_MP_RING;
    if (n > max) n = max;
    wsprintf(line(), "DISK request ring at %08lX: %lu requests, last %u (oldest first; CRC-32 of the data, as zip)", at,
             count, n);
    for (i = 0; i < n; i++) {
        const struct uds_mp_rent *e = &r->ent[((WORD)(r->next % UDS_MP_RING) + UDS_MP_RING - n + i) % UDS_MP_RING];
        wsprintf(line(), "DISK  #%lu slot %u %02Xh %s  LBA %lu  %lu bytes  CRC %08lX  SRB %02X  uds %u %s",
                 count - n + i, (WORD)e->slot, (WORD)e->op, (LPSTR)uds_op_name(e->op), (DWORD)e->lba, (DWORD)e->bytes,
                 (DWORD)e->crc, (WORD)e->srb_status, (WORD)e->uds_status, (LPSTR)uds_status_name((DWORD)e->uds_status));
    }
}
/* DISK-DECODE-END */

static struct uds_diag disk_rec;
static struct uds_mp_status disk_mp;
static struct uds_mp_ring disk_ring;
static struct uds_channel disk_ch;

static void fcopy(void *dst, const BYTE FAR *src, WORD n)
{
    BYTE *d = (BYTE *)dst;
    while (n--) *d++ = *src++;
}

/* the record: the first MiB in 64 KiB windows, 16-byte steps; returns the
 * first match, *Matches = how many */
static DWORD find_udsk(WORD *matches)
{
    DWORD at = 0;
    WORD w, off;
    *matches = 0;
    for (w = 0; w < 16; w++) {
        BYTE FAR *p = physical((DWORD)w << 16, 0x10000L);
        if (!p) return 0;
        for (off = w ? 0 : 0x500; ; off += 16) {
            DWORD FAR *q = (DWORD FAR *)(p + off);
            if (q[0] == UDS_DIAG_SIG0 && q[1] == UDS_DIAG_SIG1 && p[off + 8] && p[off + 8] < 16) {
                if (!*matches) at = ((DWORD)w << 16) + off;
                (*matches)++;
            }
            if (off == 0xFFF0) break;
        }
    }
    return at;
}

static void show_disk(void)
{
    BYTE FAR *f;
    DWORD at, chan = 0, req;
    WORD off, matches = 0, choff = 0;
    BYTE ch_found = 0;
    at = find_udsk(&matches);
    /* the CSMPPrxy mailbox: F-segment, 8-byte aligned, channel 1 at +48 */
    f = physical(0xF0000L, 0x10000L);
    if (f) {
        for (off = 0; off <= 0xFFF8 - UDS_CH1_OFFSET - sizeof(struct uds_channel); off += 8) {
            BYTE FAR *p = f + off;
            if (p[0] == 'C' && p[1] == 'S' && p[2] == 'M' && p[3] == 'P' && p[4] == 'P' && p[5] == 'r' &&
                p[6] == 'x' && p[7] == 'y') {
                fcopy(&disk_ch, p + UDS_CH1_OFFSET, sizeof(disk_ch));
                ch_found = 1;
                choff = off;
                chan = 0xF0000L + off + UDS_CH1_OFFSET;
                break;
            }
        }
    }
    if (!at) {
        wsprintf(line(), "DISK: no USOSUDSK record (CSMWrap before 3.1.2-usos16)");
    } else {
        BYTE FAR *r = at + sizeof(disk_rec) <= 0x100000L ? physical(at, sizeof(disk_rec)) : 0;
        if (!r) {
            wsprintf(line(), "DISK USOSUDSK at %05lX: the record runs past 1 MiB, not read", at);
        } else {
            fcopy(&disk_rec, r, sizeof(disk_rec));
            disk_rec.sig[0] = 0;            /* the copy must not match a later scan */
            show_disk_record(&disk_rec, at, chan);
            if (matches > 1)
                wsprintf(line(), "DISK  (%u USOSUDSK signatures in the first MiB: the first one shown)", matches);
        }
    }
    if (!f) { wsprintf(line(), "DISK channel: F0000-FFFFF not mapped (DPMI 0800h refused)"); return; }
    if (!ch_found) { wsprintf(line(), "DISK channel: no CSMPPrxy mailbox in F0000-FFFFF"); return; }
    show_disk_channel(&disk_ch, choff);
    if (disk_ch.magic != UDS_CH1_MAGIC) return;
    req = (DWORD)disk_ch.req_phys;
    if (!req) {
        wsprintf(line(), "DISK USOSUSB.MPD: no request block (req_phys 0: miniport not loaded or not started)");
        return;
    }
    if (req > 0xFFFFD000UL) {
        wsprintf(line(), "DISK USOSUSB.MPD: req_phys %08lX out of range, not read", req);
        return;
    }
    {
        DWORD st = req + UDS_MP_STATUS_OFFSET, page = st & 0xFFFFF000UL;
        WORD in = (WORD)(st & 0xFFF);
        BYTE FAR *p = physical(page, in + sizeof(disk_mp) > 0x1000 ? 0x2000 : 0x1000);
        if (!p) { wsprintf(line(), "DISK USOSUSB.MPD status at %08lX: DPMI 0800h refused", st); return; }
        fcopy(&disk_mp, p + in, sizeof(disk_mp));
        show_disk_mp(&disk_mp, st);
        if (disk_mp.sig[0] == UDS_MP_SIG0 && disk_mp.sig[1] == UDS_MP_SIG1 && disk_mp.version >= 2 &&
            in + (UDS_MP_RING_OFFSET - UDS_MP_STATUS_OFFSET) + sizeof(disk_ring) <= 0x1000) {
            fcopy(&disk_ring, p + in + (UDS_MP_RING_OFFSET - UDS_MP_STATUS_OFFSET), sizeof(disk_ring));
            show_disk_ring(&disk_ring, req + UDS_MP_RING_OFFSET, 16);
        }
    }
}

/* ---------------------------------------------------------- UI */
static void refresh(void)
{
    nlines = 0;
    if (disk_only) {
        wsprintf(line(), "USOSDBG 1.8 log mode (disk)  tick:%lu", GetTickCount());
        show_disk();
        return;
    }
    if (log_mode)
        wsprintf(line(), "USOSDBG 1.8 log mode  tick:%lu  pci:%s", GetTickCount(), (LPSTR)(log_pci ? "yes" : "no (first run only)"));
    else
        wsprintf(line(), "USOSDBG 1.8  tick:%lu  S = append to C:\\USOS9X\\USOSDBG.LOG (saved:%u)  W = wheel knock  Esc = quit",
                 GetTickCount(), snapshots);
    show_key();
    show_mouse();
    show_wheel();
    show_wheelscroll();
    show_vmd();
    show_ivt();
    show_map();
    show_irq();
    if (!log_mode || log_pci) show_pci();
    show_net();
    show_disk();
    if (window) InvalidateRect(window, 0, TRUE);
}

static void save(void)
{
    static const char name[] = "C:\\USOS9X\\USOSDBG.LOG";
    HFILE f = _lopen(name, OF_WRITE);
    int i;
    if (f == HFILE_ERROR) f = _lcreat(name, 0);
    if (f == HFILE_ERROR) return;
    _llseek(f, 0, 2);
    for (i = 0; i < nlines; i++) {
        _lwrite(f, text[i], lstrlen(text[i]));
        _lwrite(f, "\r\n", 2);
    }
    _lwrite(f, "\r\n", 2);
    _lclose(f);
    snapshots++;
}

LRESULT FAR PASCAL __export __loadds wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    switch (msg) {
    case WM_CREATE: {
        TEXTMETRIC tm;
        HDC dc = GetDC(hwnd);
        SelectObject(dc, GetStockObject(ANSI_FIXED_FONT));
        GetTextMetrics(dc, &tm);
        char_h = tm.tmHeight + tm.tmExternalLeading;
        ReleaseDC(hwnd, dc);
        SetTimer(hwnd, 1, 500, 0);
        return 0;
    }
    case WM_TIMER:
        refresh();
        return 0;
    case WM_CHAR:
        if (wp == 27) DestroyWindow(hwnd);
        else if (wp == 's' || wp == 'S') { refresh(); save(); refresh(); }
        else if (wp == 'w' || wp == 'W') { knock_now = 1; refresh(); }
        return 0;
    case WM_PAINT: {
        PAINTSTRUCT ps;
        int i;
        HDC dc = BeginPaint(hwnd, &ps);
        SelectObject(dc, GetStockObject(ANSI_FIXED_FONT));
        for (i = 0; i < nlines; i++) TextOut(dc, 4, 2 + i * char_h, text[i], lstrlen(text[i]));
        EndPaint(hwnd, &ps);
        return 0;
    }
    case WM_DESTROY:
        KillTimer(hwnd, 1);
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProc(hwnd, msg, wp, lp);
}

/* ---------------------------------------------------------- log mode */
static DWORD hexval(LPSTR p)
{
    DWORD v = 0;
    for (;; p++) {
        char c = *p;
        if (c >= '0' && c <= '9') v = (v << 4) | (c - '0');
        else if (c >= 'a' && c <= 'f') v = (v << 4) | (c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') v = (v << 4) | (c - 'A' + 10);
        else return v;
    }
}

/* "/L file /F /D /N hex" from the command tail (ends at CR or NUL) */
static void parse_args(void)
{
    char FAR *t = (char FAR *)MAKELP(e_cmdseg, e_cmdoff);
    char arg[128];
    char opt = 0;
    WORD n;
    if (!e_cmdseg) return;
    for (;;) {
        while (*t == ' ' || *t == '\t') t++;
        if (!*t || *t == '\r' || *t == '\n') break;
        for (n = 0; *t && *t != ' ' && *t != '\t' && *t != '\r' && *t != '\n'; t++)
            if (n < sizeof(arg) - 1) arg[n++] = *t;
        arg[n] = 0;
        if (opt) {
            if (opt == 'L') { lstrcpy(log_path, arg); log_mode = 1; }
            else if (opt == 'N') net_pa = hexval(arg);
            opt = 0;
        } else if (arg[0] == '/' || arg[0] == '-') {
            char c = arg[1] & ~0x20;
            if (c == 'F') log_pci = 1;
            else if (c == 'D') disk_only = 1;
            else if (c == 'L' || c == 'N') opt = c;
        }
    }
}

static void write_log(void)
{
    HFILE f = _lcreat(log_path, 0);
    int i;
    if (f == HFILE_ERROR) return;
    for (i = 0; i < nlines; i++) {
        _lwrite(f, text[i], lstrlen(text[i]));
        _lwrite(f, "\r\n", 2);
    }
    _lwrite(f, "USOSDBG END\r\n", 14);
    _lclose(f);
}

/* the one-second pause: a hidden window's timer, so GetMessage blocks (no
 * busy loop holding the Win16 lock) */
static void run_log(HINSTANCE inst)
{
    WNDCLASS wc;
    MSG msg;
    HWND w;
    DWORD t0;
    refresh();
    if (disk_only) {                    /* no counters to compare: one snapshot */
        write_log();
        return;
    }
    wc.style = 0;
    wc.lpfnWndProc = (WNDPROC)DefWindowProc;
    wc.cbClsExtra = 0;
    wc.cbWndExtra = 0;
    wc.hInstance = inst;
    wc.hIcon = 0;
    wc.hCursor = 0;
    wc.hbrBackground = 0;
    wc.lpszMenuName = 0;
    wc.lpszClassName = "USOSDBGL";
    RegisterClass(&wc);                 /* a second instance finds it registered */
    w = CreateWindow("USOSDBGL", "USOSDBG log", WS_POPUP, 0, 0, 1, 1, 0, 0, inst, 0);
    t0 = GetTickCount();
    if (w && SetTimer(w, 1, 1000, 0)) {
        while (GetMessage(&msg, 0, 0, 0)) {
            if (msg.message == WM_TIMER && msg.hwnd == w) break;
            DispatchMessage(&msg);
            if (GetTickCount() - t0 > 5000) break;
        }
        KillTimer(w, 1);
    }
    if (w) DestroyWindow(w);
    refresh();
    write_log();
}

static void run(HINSTANCE inst, HINSTANCE prev, int show)
{
    WNDCLASS wc;
    MSG msg;
    instance = inst;
    parse_args();
    if (prev && !log_mode) return;
    lin_sel = AllocSelector(SELECTOROF((void FAR *)&text));
    phys_sel = AllocSelector(SELECTOROF((void FAR *)&text));
    bda_sel = AllocSelector(SELECTOROF((void FAR *)&text));
    if (!lin_sel || !phys_sel || !bda_sel) return;
    SetSelectorBase(bda_sel, 0x400);
    SetSelectorLimit(bda_sel, 0xFF);
    if (log_mode) {
        run_log(inst);
        FreeSelector(lin_sel);
        FreeSelector(phys_sel);
        FreeSelector(bda_sel);
        return;
    }
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = (WNDPROC)wndproc;
    wc.cbClsExtra = 0;
    wc.cbWndExtra = 0;
    wc.hInstance = inst;
    wc.hIcon = LoadIcon(0, IDI_APPLICATION);
    wc.hCursor = LoadCursor(0, IDC_ARROW);
    wc.hbrBackground = GetStockObject(WHITE_BRUSH);
    wc.lpszMenuName = 0;
    wc.lpszClassName = "USOSDBG";
    if (!RegisterClass(&wc)) return;
    refresh();
    window = CreateWindow("USOSDBG", "USOSDBG - USB keyboard bridge diagnostics", WS_OVERLAPPEDWINDOW,
                          0, 0, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN) * 3 / 4,
                          0, 0, inst, 0);
    if (!window) return;
    ShowWindow(window, show ? show : SW_SHOWNORMAL);
    UpdateWindow(window);
    while (GetMessage(&msg, 0, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    FreeSelector(lin_sel);
    FreeSelector(phys_sel);
    FreeSelector(bda_sel);
}

/* Task entry (no C runtime): InitTask -> DI = hInstance, SI = hPrevInstance,
 * DX = nCmdShow; then WaitEvent(0), InitApp(hInstance), run, exit. */
static WORD e_inst, e_prev, e_show;

extern char edata[], end[];          /* wlink: end of _DATA, end of _BSS */

static void zero_bss(void)
{
    char *p;
    for (p = edata; p < end; p++) *p = 0;   /* uninitialised data */
}

static void start_c(void)
{
    WaitEvent(0);
    InitApp((HINSTANCE)e_inst);
    run((HINSTANCE)e_inst, (HINSTANCE)e_prev, e_show);
}

extern void FAR PASCAL InitTask(void);
#pragma aux task_entry "__usos_start"
void __declspec(naked) __far task_entry(void)
{
    _asm {
        call InitTask
        or ax, ax
        jz fail
        push di
        push si
        push dx
        push es
        push bx
        call zero_bss
        pop bx
        pop es
        pop dx
        pop si
        pop di
        mov e_inst, di
        mov e_prev, si
        mov e_show, dx
        mov e_cmdoff, bx
        mov ax, es
        mov e_cmdseg, ax
        call start_c
    fail:
        mov ax, 4C00h
        int 21h
    }
}
