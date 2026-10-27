/*
 * USOSPG.DRV - moves Windows 98 / 98 SE Setup past its filled-in pages.
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 *
 * Windows 98 and 98 SE with a native phase 1 under CSMWrap (X470 98 FE PL,
 * 2026-10-27): Setup loaded MSBATCH.INF (Express=1, ShowEula=0) and filled
 * the pages from it, yet stopped on "User information" (name and company
 * filled), the licence agreement, the product key (filled) and the last
 * "Finish" page; with the phase 1 in the VM the same answer went past them.
 * This installable driver, loaded by Setup's own mini-Windows (MINI.CAB
 * SYSTEM.INI [boot] drivers=, next to USOSKEY.DRV;
 * src/compat/win3x/w9x_mini.zig), presses the button a user would press,
 * and only when the page already holds what Setup needs:
 *
 *   DRV_LOAD    C:\USOS9X\USOSPG.CFG must say mode=auto (the target script
 *               writes it only for a USOS answer in automatic mode); else
 *               the load fails and the driver is gone.
 *   DRV_ENABLE  a WH_CBT hook: every wizard frame (Back / Next / Finish
 *               0x3023..5 Buttons) that becomes active (HCBT_ACTIVATE),
 *               and the active one at DRV_ENABLE, gets a 500 ms timer of
 *               this driver. Other windows are not armed.
 *   DRV_DISABLE a pause: timers killed, the hook removed, the state kept
 *               (usospg_logic.h pg_may_start); the next DRV_ENABLE
 *               resumes. Setup's mini-Windows sends the pair around its
 *               own work (X470 98 FE PL, 2026-10-27: after the first two
 *               pages, the driver stopped there for good before).
 *   timer       the active wizard frame (Back / Next / Finish 0x3023..5)
 *               and its visible page (usospg_logic.h): user information
 *               with a name -> Next; licence -> "accept" (618 checked, its
 *               BN_CLICKED to the page) then Next; product key with all
 *               five fields at 5 characters -> Next; the last page with
 *               Finish -> Finish. WM_COMMAND (BN_CLICKED) posted to the
 *               frame, as the button would. A page shown with an empty
 *               field, a declined licence, Next that stays disabled or a
 *               page that does not go away: left to the user for good.
 *   stop        after 30 minutes, at DRV_FREE and in WEP: timers
 *               killed, the hook removed, never started again.
 *
 * C:\USOS9X\USOSPG.TXT gets a line per page seen (its kind and title) and
 * per action or give-up; for the key only how many fields are complete,
 * never their text (the driver reads only their lengths). Only USER and
 * KERNEL calls that Windows 3.1 standard mode has; the imports are checked
 * against the 98 / 98 SE mini-Windows (tools/tests/legacy_bios/
 * test_usospg.py). No OpenWatcom runtime (own entry point, -zl), as
 * USOSPID.DRV.
 */
#include <windows.h>
#include "usospg_logic.h"

#define CFG_FILE  "C:\\USOS9X\\USOSPG.CFG"
#define LOG_FILE  "C:\\USOS9X\\USOSPG.TXT"
#define PG_TIMER  0x5547
#define TICK_MS   500
#define MAX_ARMED 16

/* DGROUP only: SS is not DS in a driver (-zu), so nothing on the stack is
 * handed to Windows by address. */
static BYTE buf[64];
static OFSTRUCT of;
static char cls[16];
static char title[48];
static char line[128];
static char path[24];
static unsigned lpos;
static PGSTATE st;
static PGVIEW view;
static PGSHAPE shape;
static HHOOK cbt_hook;
static DWORD started;
static HWND armed[MAX_ARMED];
static unsigned short armed_id[MAX_ARMED];
static BYTE armed_alive[MAX_ARMED];
static BYTE no_slot_logged;
static HWND logged_page;
static BYTE key_complete;
static BYTE stopping;

static const char *const kind_name[] = { "other", "user", "eula", "key", "finish" };

static void copy_path(const char *s)
{
    int i = 0;
    while (s[i] && i < (int)sizeof(path) - 1) { path[i] = s[i]; i++; }
    path[i] = 0;
}

static void put(const char *s)
{
    while (*s && lpos < sizeof(line) - 3) line[lpos++] = *s++;
}

static void put_num(unsigned v)
{
    char d[6];
    int n = 0;
    do { d[n++] = (char)('0' + v % 10); v /= 10; } while (v && n < 5);
    while (n && lpos < sizeof(line) - 3) line[lpos++] = d[--n];
}

static void log_line(void)
{
    HFILE f;
    copy_path(LOG_FILE);
    f = OpenFile(path, &of, OF_WRITE);
    if (f == HFILE_ERROR) f = OpenFile(path, &of, OF_CREATE | OF_WRITE);
    if (f != HFILE_ERROR) {
        _llseek(f, 0L, 2);
        line[lpos++] = '\r';
        line[lpos++] = '\n';
        _lwrite(f, line, lpos);
        _lclose(f);
    }
    lpos = 0;
}

static void say(const char *what)
{
    lpos = 0;
    put("USOSPG ");
    put(what);
    log_line();
}

static int read_cfg(void)
{
    HFILE f;
    int n;
    copy_path(CFG_FILE);
    f = OpenFile(path, &of, OF_READ);
    if (f == HFILE_ERROR) return 0;
    n = _lread(f, buf, sizeof(buf));
    _lclose(f);
    if (n < 0 || n > (int)sizeof(buf)) n = 0;
    return pg_cfg_auto(buf, n);
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

static int shown(HWND w)
{
    return w && IsWindowVisible(w);
}

static int ready(HWND w)
{
    return shown(w) && IsWindowEnabled(w);
}

/* shape of page c (the frame's Next / Finish already in it). */
static void fill_shape(HWND c)
{
    HWND k;
    int i;
    shape.title = (BYTE)class_is(GetDlgItem(c, PG_TITLE_ID), "Static");
    shape.name = (BYTE)class_is(GetDlgItem(c, PG_NAME_ID), "Edit");
    shape.org = (BYTE)class_is(GetDlgItem(c, PG_ORG_ID), "Edit");
    shape.eula_text = (BYTE)class_is(GetDlgItem(c, PG_EULA_TEXT_ID), "Edit");
    shape.eula_yes = (BYTE)class_is(GetDlgItem(c, PG_EULA_YES_ID), "Button");
    shape.eula_no = (BYTE)class_is(GetDlgItem(c, PG_EULA_NO_ID), "Button");
    shape.key_edits = 0;
    for (i = 0; i < PG_KEY_FIELDS; i++)
        if (class_is(GetDlgItem(c, PG_KEY1_ID + i), "Edit")) shape.key_edits++;
    shape.clickable = 0;
    for (k = GetWindow(c, GW_CHILD); k; k = GetWindow(k, GW_HWNDNEXT)) {
        if (!IsWindowVisible(k)) continue;
        if (class_is(k, "Edit") || class_is(k, "Button") || class_is(k, "ListBox") || class_is(k, "ComboBox"))
            if (shape.clickable < 255) shape.clickable++;
    }
}

/* The visible page of frame w: the first visible child with the title
 * Static 1070 (every Setup page has it). view.kind / filled / accepted /
 * declined for it. 0 when there is none. */
static HWND find_page(HWND w, HWND next, HWND finish)
{
    HWND c;
    int i;
    for (c = GetWindow(w, GW_CHILD); c; c = GetWindow(c, GW_HWNDNEXT)) {
        if (!IsWindowVisible(c) || !GetDlgItem(c, PG_TITLE_ID)) continue;
        fill_shape(c);
        shape.next_shown = (BYTE)shown(next);
        shape.finish_shown = (BYTE)shown(finish);
        view.kind = pg_classify(&shape);
        switch (view.kind) {
        case PG_USER:
            view.filled = GetWindowTextLength(GetDlgItem(c, PG_NAME_ID)) > 0;
            break;
        case PG_EULA:
            view.filled = 1;
            view.accepted = (BYTE)(IsDlgButtonChecked(c, PG_EULA_YES_ID) != 0);
            view.declined = (BYTE)(IsDlgButtonChecked(c, PG_EULA_NO_ID) != 0);
            break;
        case PG_KEY:
            key_complete = 0;
            for (i = 0; i < PG_KEY_FIELDS; i++)
                if (GetWindowTextLength(GetDlgItem(c, PG_KEY1_ID + i)) == PG_KEY_PART_LEN) key_complete++;
            view.filled = key_complete == PG_KEY_FIELDS;
            break;
        case PG_FINISH:
            view.filled = (BYTE)ready(finish);
            break;
        }
        return c;
    }
    return 0;
}

/* First sight of a page: its kind, title and button state. */
static void log_page(HWND page, HWND next, HWND finish)
{
    int i, n;
    if (page == logged_page) return;
    logged_page = page;
    n = GetWindowText(GetDlgItem(page, PG_TITLE_ID), title, sizeof(title));
    lpos = 0;
    put("USOSPG page ");
    put(kind_name[view.kind]);
    put(" '");
    for (i = 0; i < n && i < (int)sizeof(title) - 1; i++)
        if (lpos < sizeof(line) - 3) line[lpos++] = (char)((BYTE)title[i] < 32 ? ' ' : title[i]);
    put("' next=");
    put_num((unsigned)ready(next));
    put(" finish=");
    put_num((unsigned)ready(finish));
    if (view.kind == PG_USER) put(view.filled ? " name=filled" : " name=empty");
    if (view.kind == PG_KEY) { put(" fields-complete="); put_num(key_complete); }
    log_line();
}

static void log_action(unsigned char action)
{
    lpos = 0;
    put("USOSPG ");
    put(kind_name[st.kind]);
    switch (action) {
    case PA_NEXT:   put(": next"); break;
    case PA_FINISH: put(": finish"); break;
    case PA_ACCEPT: put(": accept (618)"); break;
    default:
        switch (st.event) {
        case PE_LEFT:    put(st.kind == PG_EULA ? ": declined, left to the user" : ": not filled, left to the user"); break;
        case PE_NO_NEXT: put(": next stays disabled, left to the user"); break;
        case PE_STUCK:   put(": still shown after the button, left to the user"); break;
        default: return;
        }
    }
    if (st.kind == PG_KEY) { put(" fields-complete="); put_num(key_complete); }
    log_line();
}

/* Timers killed, the hook removed; st is kept (a pause). */
static void pause_all(void)
{
    int i;
    if (stopping) return;
    stopping = 1;
    for (i = 0; i < MAX_ARMED; i++) {
        if (armed[i] && IsWindow(armed[i])) KillTimer(armed[i], PG_TIMER);
        armed[i] = 0;
    }
    if (cbt_hook) { UnhookWindowsHookEx(cbt_hook); cbt_hook = 0; }
    stopping = 0;
}

/* For good: the timeout, DRV_FREE, WEP. */
static void stop_all(void)
{
    pg_end(&st);
    pause_all();
}

void FAR PASCAL __export __loadds tick(HWND w, UINT msg, UINT id, DWORD now)
{
    HWND page = 0, next = 0, finish = 0, radio;
    unsigned char action;
    (void)msg; (void)id; (void)now;
    if (st.done) { KillTimer(w, PG_TIMER); return; }
    view.expired = GetTickCount() - started > PG_LIFETIME_MS;
    view.active = GetActiveWindow() == w;
    view.page = 0;
    view.kind = PG_OTHER;
    view.filled = view.accepted = view.declined = view.next_ready = 0;
    if (view.active) {
        next = GetDlgItem(w, PG_NEXT_ID);
        finish = GetDlgItem(w, PG_FINISH_ID);
        if (class_is(next, "Button") && class_is(finish, "Button") && class_is(GetDlgItem(w, PG_BACK_ID), "Button"))
            page = find_page(w, next, finish);
        if (page) log_page(page, next, finish);
        if (page && view.kind != PG_OTHER) view.page = (unsigned short)page;
        view.next_ready = (BYTE)ready(next);
    }
    action = pg_step(&st, &view);
    log_action(action);
    switch (action) {
    case PA_ACCEPT:
        radio = GetDlgItem(page, PG_EULA_YES_ID);
        CheckRadioButton(page, PG_EULA_YES_ID, PG_EULA_NO_ID, PG_EULA_YES_ID);
        PostMessage(page, WM_COMMAND, PG_EULA_YES_ID, MAKELPARAM(radio, BN_CLICKED));
        break;
    case PA_NEXT:
        PostMessage(w, WM_COMMAND, PG_NEXT_ID, MAKELPARAM(next, BN_CLICKED));
        break;
    case PA_FINISH:
        PostMessage(w, WM_COMMAND, PG_FINISH_ID, MAKELPARAM(finish, BN_CLICKED));
        break;
    case PA_STOP:
        if (st.event == PE_TIMEOUT) say("timeout (30 minutes), stopped");
        stop_all();
        break;
    }
}

/* The wizard frame of Setup: Back / Next / Finish Buttons of its own. */
static int is_frame(HWND w)
{
    return class_is(GetDlgItem(w, PG_NEXT_ID), "Button") && class_is(GetDlgItem(w, PG_FINISH_ID), "Button")
        && class_is(GetDlgItem(w, PG_BACK_ID), "Button");
}

/* A wizard frame became active (its own task): give it this driver's
 * timer. SetTimer with the same window and ID only restarts it. Slots of
 * windows that are gone are reused (pg_arm_slot). */
static void arm(HWND w)
{
    static int already;     /* DGROUP: handed by address (SS != DS) */
    int i, slot;
    if (!w || !is_frame(w)) return;
    for (i = 0; i < MAX_ARMED; i++) {
        armed_id[i] = (unsigned short)armed[i];
        armed_alive[i] = (BYTE)(armed[i] && IsWindow(armed[i]));
    }
    slot = pg_arm_slot(armed_id, armed_alive, MAX_ARMED, (unsigned short)w, &already);
    if (already) return;
    if (slot < 0) {
        if (!no_slot_logged) { no_slot_logged = 1; say("no slot, frame not armed"); }
        return;
    }
    if (!SetTimer(w, PG_TIMER, TICK_MS, (TIMERPROC)tick)) { say("no timer, frame not armed"); return; }
    armed[slot] = w;
    GetClassName(w, cls, sizeof(cls));
    cls[sizeof(cls) - 1] = 0;
    lpos = 0;
    put("USOSPG arm ");
    put(cls);
    put(" slot=");
    put_num((unsigned)slot);
    log_line();
}

LRESULT FAR PASCAL __export __loadds cbt_proc(int code, WPARAM wp, LPARAM lp)
{
    LRESULT r = CallNextHookEx(cbt_hook, code, wp, lp);
    if (code == HCBT_ACTIVATE && wp && !st.done) arm((HWND)wp);
    return r;
}

/* DRV_ENABLE: the first one starts the 30 minutes, every one (after a
 * DRV_DISABLE pause) hooks again and arms the frame already active. */
static int start(void)
{
    if (cbt_hook || !pg_may_start(&st)) return 1;
    if (!started) started = GetTickCount();
    cbt_hook = SetWindowsHookEx(WH_CBT, (HOOKPROC)cbt_proc, GetModuleHandle("USOSPG"), 0);
    if (!cbt_hook) { say("no CBT hook, stopped"); stop_all(); return 1; }
    arm(GetActiveWindow());
    return 1;
}

LRESULT FAR PASCAL __export __loadds DriverProc(DWORD id, HANDLE driver, UINT msg, LPARAM p1, LPARAM p2)
{
    (void)id; (void)driver; (void)p1; (void)p2;
    switch (msg) {
    case DRV_LOAD:
        if (!read_cfg()) return 0L;
        say("load mode=auto");
        return 1L;
    case DRV_ENABLE:
        if (pg_may_start(&st)) say("enable");
        return start();
    case DRV_DISABLE:
        if (pg_may_start(&st)) say("disable (pause)");
        pause_all();
        return 1L;
    case DRV_FREE:    stop_all(); return 1L;
    case DRV_OPEN:
    case DRV_CLOSE:   return 1L;
    }
    return 0L;
}

/* No file work at WEP: KERNEL may already be shutting down. */
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
