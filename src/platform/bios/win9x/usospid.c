/*
 * USOSPID.DRV - the Windows 95 OEM Product ID for Setup's own page.
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 *
 * Windows 95 RTM / OSR1 (SETUP 4.00.950) with a native phase 1 under
 * CSMWrap: an OEM ID in MSBATCH.INF [Setup] ProductID makes SUWIN drop the
 * whole batch file (tools/w9x_pid95.sh), and even when it loaded, the
 * "Product Identification" page took only its edit field. So the ID goes
 * out of MSBATCH.INF and into C:\USOS9X\USOSPID.KEY (tools/w9x_pid95.sh
 * w9x_pid95_stage_key), and this installable driver, loaded by Setup's own
 * mini-Windows (MINI.CAB SYSTEM.INI [boot] drivers=, next to USOSKEY.DRV;
 * src/compat/win3x/w9x_mini.zig), types it into that page once:
 *
 *   DRV_LOAD    reads USOSPID.KEY (ddddd-OEM-ddddddd-ddddd), overwrites
 *               the file with zeros and deletes it; no valid key: the load
 *               fails and the driver is gone (Setup asks as before).
 *   DRV_ENABLE  a WH_CBT hook: every window that becomes active
 *               (HCBT_ACTIVATE, in its own task) gets a 500 ms timer of
 *               this driver.
 *   timer       (task time, the window's own message loop) the decisions
 *               of usospid_logic.h: the active wizard frame (Next 0x3024)
 *               showing the OEM page (Edit 526 + Static 1010, no 1097)
 *               twice in a row with an empty field -> WM_SETTEXT of the
 *               key; the next tick, with the field holding 23 characters
 *               and Next enabled -> WM_COMMAND Next (BN_CLICKED), posted.
 *               The "Invalid Product ID" box (OK 1, Ignore 1118, Exit 2)
 *               before that -> OK once (back to the page; Setup's batch
 *               mode pressed Next on the empty field). After typing, that
 *               box, another page or a field the user changed: stop.
 *   stop        all timers killed, the hook removed, the key zeroed. Also
 *               after 30 minutes, at DRV_DISABLE / DRV_FREE and in WEP.
 *
 * Nothing is logged (the key never leaves this driver's data segment).
 * The control IDs and why they identify the page: usospid_logic.h. Only
 * USER and KERNEL calls that Windows 3.1 standard mode has; the imports
 * are checked against the mini-Windows USER.EXE / KRNL386.EXE
 * (tools/tests/legacy_bios/test_usospid.py). No OpenWatcom runtime is
 * linked (own entry point, -zl), as USOSKEY.DRV.
 */
#include <windows.h>
#include "usospid_logic.h"

#define KEY_FILE   "C:\\USOS9X\\USOSPID.KEY"
#define PID_TIMER  0x5550
#define TICK_MS    500
#define MAX_ARMED  8

/* DGROUP only: SS is not DS in a driver (-zu), so nothing on the stack is
 * handed to Windows by address. */
static char key[PID_KEY_LEN + 1];
static BYTE buf[64];
static OFSTRUCT of;
static char cls[16];
static PIDSTATE st;
static PIDVIEW view;
static HHOOK cbt_hook;
static DWORD started;
static HWND armed[MAX_ARMED];
static BYTE stopping;

static void zero(BYTE *p, int n)
{
    while (n-- > 0) *p++ = 0;
}

/* The key file: read, overwritten with zeros, deleted. 1 = a valid key. */
static int read_key(void)
{
    HFILE f;
    int n, ok;
    f = OpenFile(KEY_FILE, &of, OF_READ);
    if (f == HFILE_ERROR) return 0;
    n = _lread(f, buf, sizeof(buf));
    _lclose(f);
    if (n < 0 || n > (int)sizeof(buf)) n = 0;
    ok = pid_key_parse(buf, n, key);
    zero(buf, sizeof(buf));
    f = OpenFile(KEY_FILE, &of, OF_WRITE);
    if (f != HFILE_ERROR) {
        if (n) _lwrite(f, (LPCSTR)buf, n);
        _lclose(f);
    }
    OpenFile(KEY_FILE, &of, OF_DELETE);
    return ok;
}

static int class_is(HWND w, const char *name)
{
    int i, n, want = 0;
    if (!w) return 0;
    while (name[want]) want++;
    n = GetClassName(w, cls, sizeof(cls));
    if (n != want) return 0;
    for (i = 0; i < n; i++) {
        char a = cls[i], b = name[i];
        if (a >= 'a' && a <= 'z') a = (char)(a - 32);
        if (b >= 'a' && b <= 'z') b = (char)(b - 32);
        if (a != b) return 0;
    }
    return 1;
}

/* The visible child page of a wizard frame that is the OEM Product ID page. */
static HWND oem_page(HWND frame)
{
    HWND c;
    for (c = GetWindow(frame, GW_CHILD); c; c = GetWindow(c, GW_HWNDNEXT)) {
        if (!IsWindowVisible(c)) continue;
        if (class_is(GetDlgItem(c, PID_EDIT_ID), "Edit") && GetDlgItem(c, PID_LABEL_ID) &&
            !GetDlgItem(c, PID_ADVANCED_ID))
            return c;
    }
    return 0;
}

static int invalid_box(HWND w)
{
    return class_is(GetDlgItem(w, PID_IGNORE_ID), "Button") && GetDlgItem(w, IDOK) && GetDlgItem(w, IDCANCEL);
}

static void stop_all(void)
{
    int i;
    if (stopping) return;
    stopping = 1;
    st.done = 1;
    for (i = 0; i < MAX_ARMED; i++) {
        if (armed[i] && IsWindow(armed[i])) KillTimer(armed[i], PID_TIMER);
        armed[i] = 0;
    }
    if (cbt_hook) { UnhookWindowsHookEx(cbt_hook); cbt_hook = 0; }
    zero((BYTE *)key, sizeof(key));
    stopping = 0;
}

void FAR PASCAL __export __loadds tick(HWND w, UINT msg, UINT id, DWORD now)
{
    HWND page = 0, edit = 0, next = 0;
    int len = -1;
    (void)msg; (void)id; (void)now;
    if (st.done) { KillTimer(w, PID_TIMER); return; }
    zero((BYTE *)&view, sizeof(view));
    view.expired = GetTickCount() - started > PID_LIFETIME_MS;
    view.active = GetActiveWindow() == w;
    view.box = (BYTE)invalid_box(w);
    if (!view.box) {
        next = GetDlgItem(w, PID_NEXT_ID);
        if (class_is(next, "Button")) page = oem_page(w);
    }
    if (page) {
        edit = GetDlgItem(page, PID_EDIT_ID);
        len = GetWindowTextLength(edit);
    }
    view.page = page != 0;
    view.edit_empty = len == 0;
    view.edit_full = len == PID_KEY_LEN;
    view.next_ready = next && IsWindowVisible(next) && IsWindowEnabled(next);
    switch (pid_step(&st, &view)) {
    case PA_TYPE:
        SetWindowText(edit, key);
        break;
    case PA_NEXT:
        PostMessage(w, WM_COMMAND, PID_NEXT_ID, MAKELPARAM(next, BN_CLICKED));
        stop_all();
        break;
    case PA_DISMISS:
        PostMessage(w, WM_COMMAND, IDOK, MAKELPARAM(GetDlgItem(w, IDOK), BN_CLICKED));
        break;
    case PA_STOP:
        stop_all();
        break;
    }
}

/* A window became active (its own task): give it this driver's timer.
 * SetTimer with the same window and ID only restarts it. */
static void arm(HWND w)
{
    int i, slot = -1;
    if (!SetTimer(w, PID_TIMER, TICK_MS, (TIMERPROC)tick)) return;
    for (i = 0; i < MAX_ARMED; i++) {
        if (armed[i] == w) return;
        if (slot < 0 && (!armed[i] || !IsWindow(armed[i]))) slot = i;
    }
    if (slot >= 0) armed[slot] = w;
    else KillTimer(w, PID_TIMER);       /* no slot to kill it later: not armed */
}

LRESULT FAR PASCAL __export __loadds cbt_proc(int code, WPARAM wp, LPARAM lp)
{
    LRESULT r = CallNextHookEx(cbt_hook, code, wp, lp);
    if (code == HCBT_ACTIVATE && wp && !st.done) arm((HWND)wp);
    return r;
}

static int start(void)
{
    if (cbt_hook || st.done) return 1;
    started = GetTickCount();
    cbt_hook = SetWindowsHookEx(WH_CBT, (HOOKPROC)cbt_proc, GetModuleHandle("USOSPID"), 0);
    if (!cbt_hook) stop_all();
    return 1;
}

LRESULT FAR PASCAL __export __loadds DriverProc(DWORD id, HANDLE driver, UINT msg, LPARAM p1, LPARAM p2)
{
    (void)id; (void)driver; (void)p1; (void)p2;
    switch (msg) {
    case DRV_LOAD:    return read_key() ? 1L : 0L;
    case DRV_ENABLE:  return start();
    case DRV_DISABLE:
    case DRV_FREE:    stop_all(); return 1L;
    case DRV_OPEN:
    case DRV_CLOSE:   return 1L;
    }
    return 0L;
}

int FAR PASCAL __export __loadds WEP(int exit_type)
{
    (void)exit_type;
    stop_all();
    return 1;
}

/* DLL entry (no C runtime): DS = DGROUP. Returns AX = 1. */
#pragma aux dll_entry "__DLLstart_"
void __declspec(naked) __far dll_entry(void)
{
    _asm {
        mov ax, 1
        retf
    }
}
