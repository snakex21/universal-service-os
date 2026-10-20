/*
 * usoskey_wheel.h - USOSKEY.DRV universal wheel scrolling: the decisions.
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 *
 * Pure logic, no Windows call (host-tested by
 * tools/tests/legacy_bios/test_usoskey_wheel.py); usoskey.c does the
 * Windows side (WH_GETMESSAGE hook, task time). Windows 98 / 98 SE / Me
 * USER sends WM_MOUSEWHEEL to the focus window only, and Win16 windows
 * (16-bit COMMCTRL "SysTreeView" in Me's Device Manager, any 16-bit
 * program) do nothing with it. When a notch comes (USOSMOUS.DRV's notch
 * counter moved) the window under the pointer, or its first ancestor with
 * WS_VSCROLL, is looked at:
 *   - no such window: stock path (WM_MOUSEWHEEL as USER sends it),
 *   - a Win32 window of a class not in the no-wheel list: stock path (the
 *     98 / Me controls and programs scroll themselves; no double scroll),
 *   - a Win16 window (its module is an NE module without the Win32 flag)
 *     or a no-wheel class: WM_VSCROLL SB_LINEUP / SB_LINEDOWN, lines per
 *     notch from SPI_GETWHEELSCROLLLINES (SB_PAGEUP / SB_PAGEDOWN for
 *     WHEEL_PAGESCROLL), then SB_ENDSCROLL, sent to that window; the
 *     WM_MOUSEWHEEL of those notches is turned into WM_NULL.
 * SYSTEM.INI [usosmous] WheelScroll=0 switches it off (default 1).
 * Windows 95 (2026-10-20): 95 USER has no WM_MOUSEWHEEL at all (USOSMOUS.DRV
 * does not call USER's wheel event there, only its notch counter moves), so
 * no window gets a wheel message on its own. wheel_decide95: a window with
 * WS_VSCROLL under the pointer (or an ancestor) always gets WM_VSCROLL,
 * Win16 and Win32 alike; without one, the registered MSWHEEL_ROLLMSG (the
 * IntelliPoint 1.x "MSWheel" message; 95 OSR2's COMCTL32.DLL and IE 3's
 * SHDOCVW.DLL / MSHTML.DLL register it) goes to the window under the
 * pointer (WA_ROLLMSG; [usosmous] MSWheel=0 switches that part off). One
 * path per notch, so no window scrolls twice.
 * Callers keep every buffer they pass in DGROUP (SS is not DS in the
 * driver).
 */
#ifndef USOSKEY_WHEEL_H
#define USOSKEY_WHEEL_H

/* Actions (also the USOSWHEELLOG record's action byte). */
#define WA_NONE       0
#define WA_STOCK_NONE 1     /* nothing scrollable under the pointer */
#define WA_STOCK_32   2     /* a Win32 window that takes the wheel */
#define WA_TRANSLATE  3     /* WM_VSCROLL to the window under the pointer */
#define WA_OFF        4     /* WheelScroll=0 */
#define WA_ROLLMSG    5     /* Windows 95: MSWHEEL_ROLLMSG to the window under the pointer */

/* Module kinds (wheel_module_kind). */
#define WM_KIND_UNKNOWN 0   /* no readable module: treated as Win32 */
#define WM_KIND_WIN16   1
#define WM_KIND_WIN32   2

#define WHEEL_SB_LINEUP    0
#define WHEEL_SB_LINEDOWN  1
#define WHEEL_SB_PAGEUP    2
#define WHEEL_SB_PAGEDOWN  3
#define WHEEL_SB_ENDSCROLL 8
#define WHEEL_MAX_SCROLLS  60       /* WM_VSCROLL per batch, at most */
#define WHEEL_SWALLOW_MS   2000     /* WM_MOUSEWHEEL at most this old is a translated one */

/* A 16-bit module database (the selector GetModuleHandle returns): "NE" at
 * 0, the module flags at 0Ch; Windows 9x keeps one for every Win32 module
 * too, with NE_FFLAGS_WIN32 (0010h) set. */
static unsigned char wheel_module_kind(const unsigned char *mdb)
{
    unsigned short flags;
    if (!mdb || mdb[0] != 'N' || mdb[1] != 'E') return WM_KIND_UNKNOWN;
    flags = (unsigned short)(mdb[0x0C] | (mdb[0x0D] << 8));
    return (flags & 0x0010) ? WM_KIND_WIN32 : WM_KIND_WIN16;
}

static int wheel_ieq(const char *a, const char *b)
{
    for (; *a && *b; a++, b++) {
        char x = *a, y = *b;
        if (x >= 'A' && x <= 'Z') x = (char)(x + 32);
        if (y >= 'A' && y <= 'Z') y = (char)(y + 32);
        if (x != y) return 0;
    }
    return *a == *b;
}

/* Classes that never take WM_MOUSEWHEEL, whoever owns them: the 16-bit
 * COMMCTRL.DLL tree and list views (the 32-bit ones end in "32"). */
static int wheel_no_wheel_class(const char *cls)
{
    return cls && (wheel_ieq(cls, "SysTreeView") || wheel_ieq(cls, "SysListView"));
}

/* has_target: a window with WS_VSCROLL under the pointer (or an
 * ancestor); kind: wheel_module_kind of its module; enabled: WheelScroll. */
static unsigned char wheel_decide(int enabled, int has_target, unsigned char kind, const char *cls)
{
    if (!enabled) return WA_OFF;
    if (!has_target) return WA_STOCK_NONE;
    if (kind == WM_KIND_WIN16 || wheel_no_wheel_class(cls)) return WA_TRANSLATE;
    return WA_STOCK_32;
}

/* Windows 95: INT 2Fh AX=160Ah returns the Windows version in BX (95 and
 * 95 OSR2: 0400h; 98: 040Ah; Me: 045Ah). ax_after: AX after the call (0 =
 * supported). 1 = Windows 95, where USER has no wheel. */
static int wheel_is_95(unsigned short ax_after, unsigned short bx)
{
    return ax_after == 0 && (bx >> 8) == 4 && (bx & 0xFF) < 10;
}

/* Windows 95 (no WM_MOUSEWHEEL): has_target as in wheel_decide; rollmsg:
 * MSWheel not switched off and the message registered. */
static unsigned char wheel_decide95(int enabled, int has_target, int rollmsg)
{
    if (!enabled) return WA_OFF;
    if (has_target) return WA_TRANSLATE;
    return rollmsg ? WA_ROLLMSG : WA_STOCK_NONE;
}

/* MSWHEEL_ROLLMSG wParam: the delta in WHEEL_DELTA (120) units, up
 * positive, kept in a 16-bit int (Win16 WPARAM). */
static short wheel_roll_delta(int notches)
{
    if (notches > 273) notches = 273;
    if (notches < -273) notches = -273;
    return (short)(notches * 120);
}

/* Notches since the last look: USOSMOUS.DRV's 16-bit notch counter (up
 * positive) wraps; the difference is what counts. */
static int wheel_notches(unsigned short now, unsigned short seen)
{
    return (int)(short)(unsigned short)(now - seen);
}

/* WM_VSCROLL plan for notches (up positive) with SPI_GETWHEELSCROLLLINES
 * = lines (0FFFFFFFFh / 0FFFFh WHEEL_PAGESCROLL; the caller passes 3 when
 * the call failed). Sets *code (SB_*) and returns how many to send (0:
 * nothing, e.g. lines = 0). */
static int wheel_plan(int notches, unsigned long lines, unsigned short *code)
{
    int n = notches < 0 ? -notches : notches;
    int count;
    *code = notches > 0 ? WHEEL_SB_LINEUP : WHEEL_SB_LINEDOWN;
    if (!n) return 0;
    if (n > WHEEL_MAX_SCROLLS) n = WHEEL_MAX_SCROLLS;   /* 16-bit int math below */
    if (lines == 0xFFFFFFFFUL || lines == 0xFFFFUL) {
        *code = notches > 0 ? WHEEL_SB_PAGEUP : WHEEL_SB_PAGEDOWN;
        count = n;
    } else {
        if (lines > 100) lines = 3;     /* nonsense from the call */
        count = n * (int)lines;
    }
    if (count > WHEEL_MAX_SCROLLS) count = WHEEL_MAX_SCROLLS;
    return count;
}

/* Is a WM_MOUSEWHEEL with time msg_time one of the translated notches?
 * translated_at: GetTickCount when the last translation was decided; the
 * notch's message was queued before that (its counter moved first). */
static int wheel_swallow(int active, unsigned long translated_at, unsigned long msg_time)
{
    unsigned long age = translated_at - msg_time;
    return active && age < WHEEL_SWALLOW_MS;
}

#endif
