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
 *   IVT   INT 08h/09h/15h/1Ch/2Fh vectors of the system VM
 *   MAP   linear (system VM V86) against physical (DPMI 0800h) for a few
 *         pages: page 0 (control: the IVT page is per VM, expected to
 *         differ), the USOSKEY page, the INT 08h and USB INT 15h/4Fh stack
 *         pages, and C0000-FFFFF (SeaBIOS low zone, its extra stack: where
 *         CSMWrap's helper core writes the HID report, by physical address)
 *   PCI   every xHCI (class 0C0330) through ports CF8h/CFCh: command,
 *         status, BARs, interrupt; its registers through a DPMI 0800h
 *         mapping (USBCMD, USBSTS, MFINDEX twice, PORTSC of connected
 *         ports); every bridge above an xHCI bus: bus numbers, windows,
 *         bridge control. Same format as USOSDIAG.COM's PCI section (DOS,
 *         C:\USOS9X\DIAG.LOG), so the two can be compared line by line
 * S appends the current screen to C:\USOS9X\USOSDBG.LOG, Esc quits.
 * Nothing is written to any device: configuration space and xHCI registers
 * are only read.
 *
 * No OpenWatcom runtime is linked (own entry point, -zl): the binary is
 * this file plus import records. Built with tools/build_win9x_support.py.
 */
#include <windows.h>

#define LINES 64
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
} SHARED;

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
static WORD lin_sel, phys_sel;
static DWORD prev_c08, prev_c1c, prev_c4f, prev_c4fusb, prev_tick;
static WORD prev_polls, prev_captured;
static WORD snapshots;
static int char_h = 16;

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

static void show_key(void)
{
    SHARED FAR *s = find_shared();
    DWORD now = GetTickCount();
    stack08_ss = stack4f_ss = 0;
    if (!s) {
        wsprintf(line(), "KEY  USOSKEY.COM not found (INT 2Fh AX=D700h): not loaded before Windows?");
        return;
    }
    wsprintf(line(), "KEY  USOSKEY v%u at %04X:%04X  USOSKEY.DRV %s  alive(heartbeat):%u  head/tail:%u/%u",
             s->version, key_seg, key_off, (LPSTR)(GetModuleHandle("USOSKEY") ? "loaded" : "NOT loaded"),
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
}

static void show_ivt(void)
{
    static const BYTE ints[5] = { 0x08, 0x09, 0x15, 0x1C, 0x2F };
    WORD FAR *ivt = (WORD FAR *)linear(0, 0x3FF);
    WORD v[10];
    int i;
    for (i = 0; i < 5; i++) { v[2 * i] = ivt[ints[i] * 2 + 1]; v[2 * i + 1] = ivt[ints[i] * 2]; }
    wsprintf(line(), "IVT  08:%04X:%04X  09:%04X:%04X  15:%04X:%04X  1C:%04X:%04X  2F:%04X:%04X",
             v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8], v[9]);
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

/* ---------------------------------------------------------- UI */
static void refresh(void)
{
    nlines = 0;
    wsprintf(line(), "USOSDBG 1.0  tick:%lu  S = append to C:\\USOS9X\\USOSDBG.LOG (saved:%u)  Esc = quit",
             GetTickCount(), snapshots);
    show_key();
    show_ivt();
    show_map();
    show_pci();
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

static void run(HINSTANCE inst, HINSTANCE prev, int show)
{
    WNDCLASS wc;
    MSG msg;
    instance = inst;
    if (prev) return;
    lin_sel = AllocSelector(SELECTOROF((void FAR *)&text));
    phys_sel = AllocSelector(SELECTOROF((void FAR *)&text));
    if (!lin_sel || !phys_sel) return;
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
        call zero_bss
        pop dx
        pop si
        pop di
        mov e_inst, di
        mov e_prev, si
        mov e_show, dx
        call start_c
    fail:
        mov ax, 4C00h
        int 21h
    }
}
