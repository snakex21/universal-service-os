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
 *   DRV_DISABLE logged only: timers and hooks stay until DRV_FREE (X470
 *               98 FE PL run 3, 2026-10-27: DRV_DISABLE came only when the
 *               mini-Windows ended). A later DRV_ENABLE finds the hooks
 *               in place and changes nothing.
 *   DRV_FREE    logged, then everything stopped for good.
 * Note (same run): the stopped pages (user information, licence, key,
 * "Finish") are not shown in this mini-Windows at all (SETUPLOG: dialogs
 * skipped in phase 1); they come at the first start of the installed
 * Windows 98, where USOSANS.EXE runs. This driver stays for the phase 1
 * pages it can see and records input there.
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
 * never their text (the driver reads only their lengths).
 *
 * Input recorder (diagnostics, 2026-10-27: the pages still stopped on the
 * X470 with MSBATCH.INF loaded; does input from the USB bridge make Setup
 * leave its batch mode?). Hooked and unhooked with the CBT hook (DRV_ENABLE,
 * DRV_DISABLE pause, stop); it never presses or changes anything:
 *   WH_MOUSE    every button press (L / R / M, double clicks, non-client)
 *               taken from a queue: "t=<ms since the first DRV_ENABLE>
 *               click L x= y= hit=", the target's class, control ID, text
 *               (Button / Static only), button state, the top-level
 *               window's title and, in a wizard frame, the page title
 *               (Static 1070). Pointer moves are only counted: "moves N
 *               still= dist= in <ms>" at most every 5 s and only when
 *               there were any (moves while nobody touches the mouse are
 *               the phantom input looked for; "still" = the pointer did
 *               not move).
 *   WH_KEYBOARD every key press: its virtual key code and the focus
 *               window as above; with the focus in an Edit / ComboBox a
 *               typing key is "char" only (usospg_logic.h pg_key_hidden).
 *   timer       the licence page's radio buttons 618 / 619 at first sight
 *               and at every change.
 * At most PG_REC_MAX (2000) recorder lines, then one notice; the page and
 * action lines go on. Text is read only from Buttons, Statics, dialogs and
 * top-level windows (rec_text), never from an Edit. Only USER and
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
/* The recorder: its own line and text buffers (GetWindowText may let
 * another task run, and with it a hook or this driver's timer). */
static HHOOK mouse_hook, key_hook;
static BYTE in_rec;
static BYTE rec_hook_failed;
static unsigned rec_lines;
static PGMOVES moves;
static PGRADIO radio;
static char rline[256];
static unsigned rpos;
static char rcls[16];
static char rtext[48];
static char rnum[12];

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

/* Appends s[0 .. *pos) and CR LF to the log (s keeps 2 bytes of room). */
static void write_log(char *s, unsigned *pos)
{
    HFILE f;
    copy_path(LOG_FILE);
    f = OpenFile(path, &of, OF_WRITE);
    if (f == HFILE_ERROR) f = OpenFile(path, &of, OF_CREATE | OF_WRITE);
    if (f != HFILE_ERROR) {
        _llseek(f, 0L, 2);
        s[(*pos)++] = '\r';
        s[(*pos)++] = '\n';
        _lwrite(f, s, *pos);
        _lclose(f);
    }
    *pos = 0;
}

static void log_line(void)
{
    write_log(line, &lpos);
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

/* ---- the input recorder ---- */

static int is_frame(HWND);

static void rput(const char *s)
{
    while (*s && rpos < sizeof(rline) - 3) rline[rpos++] = *s++;
}

static void rput_num(unsigned long v)
{
    int i, n = pg_u32_dec(rnum, v);
    for (i = 0; i < n && rpos < sizeof(rline) - 3; i++) rline[rpos++] = rnum[i];
}

static void rput_int(int v)
{
    if (v < 0) { rput("-"); rput_num((unsigned long)(-(long)v)); }
    else rput_num((unsigned long)v);
}

static void rput_hex2(unsigned v)
{
    static const char hex[] = "0123456789abcdef";
    if (rpos < sizeof(rline) - 4) {
        rline[rpos++] = hex[(v >> 4) & 15];
        rline[rpos++] = hex[v & 15];
    }
}

/* rtext between quotes, control characters as blanks. */
static void rput_text(int n)
{
    int i;
    rput("'");
    for (i = 0; i < n && i < (int)sizeof(rtext) - 1; i++)
        if (rpos < sizeof(rline) - 4) rline[rpos++] = (char)((BYTE)rtext[i] < 32 ? ' ' : rtext[i]);
    rput("'");
}

static int is_child(HWND w)
{
    return (GetWindowLong(w, GWL_STYLE) & WS_CHILD) != 0;
}

/* The text of w into rtext, only for a Button, a Static, a dialog or a
 * top-level window: never an Edit's (names, the product key). */
static int rec_text(HWND w)
{
    int n;
    rtext[0] = 0;
    if (!w || !IsWindow(w)) return 0;
    if (is_child(w) && !class_is(w, "Button") && !class_is(w, "Static") && !class_is(w, "#32770")) return 0;
    n = GetWindowText(w, rtext, sizeof(rtext));
    if (n < 0) n = 0;
    if (n > (int)sizeof(rtext) - 1) n = sizeof(rtext) - 1;
    return n;
}

/* rline = "USOSPG t=<ms> <what>": 0 when the recorder's line limit is
 * reached (the notice is written once). */
static int rec_begin(const char *what)
{
    int allow = pg_rec_allow(&rec_lines);
    if (!allow) return 0;
    rpos = 0;
    rput("USOSPG t=");
    rput_num(GetTickCount() - started);
    if (allow == 2) {
        rput(" rec: 2000 lines, the recorder stops logging");
        write_log(rline, &rpos);
        return 0;
    }
    rput(" ");
    rput(what);
    return 1;
}

static void rec_end(void)
{
    write_log(rline, &rpos);
}

static HWND top_of(HWND w)
{
    int i;
    for (i = 0; i < 16 && w && is_child(w); i++) w = GetParent(w);
    return w;
}

/* The visible page of wizard frame w (the child with the title Static). */
static HWND page_of(HWND w)
{
    HWND c;
    for (c = GetWindow(w, GW_CHILD); c; c = GetWindow(c, GW_HWNDNEXT))
        if (IsWindowVisible(c) && GetDlgItem(c, PG_TITLE_ID)) return c;
    return 0;
}

/* " cls= id= text= btn= top= page=" for window w. */
static void rec_where(HWND w)
{
    HWND top, page;
    long style;
    int n;
    if (!w || !IsWindow(w)) { rput(" window=none"); return; }
    n = GetClassName(w, rcls, sizeof(rcls));
    if (n < 0) n = 0;
    if (n > (int)sizeof(rcls) - 1) n = sizeof(rcls) - 1;
    rcls[n] = 0;
    rput(" cls=");
    rput(rcls);
    style = GetWindowLong(w, GWL_STYLE);
    if (style & WS_CHILD) { rput(" id="); rput_num((unsigned)GetDlgCtrlID(w)); }
    if (class_is(w, "Button") || class_is(w, "Static")) { rput(" text="); rput_text(rec_text(w)); }
    if (class_is(w, "Button")) {
        rput(" style=");
        rput_num((unsigned)(style & 15));
        rput(" check=");
        rput_num((unsigned)SendMessage(w, BM_GETCHECK, 0, 0L));
    }
    rput(IsWindowEnabled(w) ? " enabled" : " disabled");
    top = top_of(w);
    if (top && top != w) { rput(" top="); rput_text(rec_text(top)); }
    if (top && is_frame(top) && (page = page_of(top)) != 0) {
        rput(" page=");
        rput_text(rec_text(GetDlgItem(page, PG_TITLE_ID)));
    }
}

/* The "moves" summary when due (force: whatever was counted). */
static void rec_moves(int force)
{
    DWORD now = GetTickCount();
    if (!pg_move_due(&moves, now, force)) return;
    if (rec_begin("moves ")) {
        rput_num(moves.n);
        rput(" still=");
        rput_num(moves.still);
        rput(" dist=");
        rput_num(moves.dist);
        rput(" in ");
        rput_num(now - moves.since);
        rput(" ms");
        rec_end();
    }
    pg_move_reset(&moves);
}

static const char *button_name(UINT msg)
{
    switch (msg) {
    case WM_LBUTTONDOWN:     return "click L";
    case WM_RBUTTONDOWN:     return "click R";
    case WM_MBUTTONDOWN:     return "click M";
    case WM_LBUTTONDBLCLK:   return "dblclk L";
    case WM_RBUTTONDBLCLK:   return "dblclk R";
    case WM_MBUTTONDBLCLK:   return "dblclk M";
    case WM_NCLBUTTONDOWN:   return "ncclick L";
    case WM_NCRBUTTONDOWN:   return "ncclick R";
    case WM_NCMBUTTONDOWN:   return "ncclick M";
    case WM_NCLBUTTONDBLCLK: return "ncdblclk L";
    case WM_NCRBUTTONDBLCLK: return "ncdblclk R";
    }
    return 0;
}

static void rec_mouse(UINT msg, int x, int y, HWND w, UINT hit)
{
    const char *name;
    if (msg == WM_MOUSEMOVE || msg == WM_NCMOUSEMOVE) {
        pg_move_add(&moves, x, y, GetTickCount());
        rec_moves(0);
        return;
    }
    name = button_name(msg);
    if (!name) return;
    rec_moves(0);
    if (!rec_begin(name)) return;
    rput(" x=");
    rput_int(x);
    rput(" y=");
    rput_int(y);
    rput(" hit=");
    rput_int((int)hit);
    rec_where(w);
    rec_end();
}

static void rec_key(UINT vk, LPARAM flags)
{
    HWND f = GetFocus();
    int in_edit = f && (class_is(f, "Edit") || class_is(f, "ComboBox"));
    rec_moves(0);
    if (!rec_begin("key ")) return;
    if (pg_key_hidden(vk, in_edit)) rput("char");
    else { rput("vk=0x"); rput_hex2(vk); }
    if (flags & 0x40000000L) rput(" repeat");
    if (flags & 0x20000000L) rput(" alt");
    rput(" focus");
    rec_where(f);
    rec_end();
}

/* Both hooks pass everything on unchanged (CallNextHookEx first, its
 * result returned); HC_NOREMOVE peeks are not logged. */
LRESULT FAR PASCAL __export __loadds mouse_proc(int code, WPARAM wp, LPARAM lp)
{
    LRESULT r = CallNextHookEx(mouse_hook, code, wp, lp);
    LPMOUSEHOOKSTRUCT m = (LPMOUSEHOOKSTRUCT)lp;
    if (code == HC_ACTION && m && !in_rec && !st.done) {
        in_rec = 1;
        rec_mouse((UINT)wp, m->pt.x, m->pt.y, m->hwnd, m->wHitTestCode);
        in_rec = 0;
    }
    return r;
}

LRESULT FAR PASCAL __export __loadds key_proc(int code, WPARAM wp, LPARAM lp)
{
    LRESULT r = CallNextHookEx(key_hook, code, wp, lp);
    if (code == HC_ACTION && !(lp & 0x80000000L) && !in_rec && !st.done) {
        in_rec = 1;
        rec_key((UINT)wp, lp);
        in_rec = 0;
    }
    return r;
}

/* The licence radios, from the timer: first sight and every change. */
static void rec_radio(HWND page)
{
    unsigned char state = (unsigned char)(view.accepted | (view.declined << 1));
    if (in_rec || !pg_radio_note(&radio, (unsigned short)page, state)) return;
    in_rec = 1;
    if (rec_begin("eula radios accept=")) {
        rput_num(view.accepted);
        rput(" decline=");
        rput_num(view.declined);
        rec_end();
    }
    in_rec = 0;
}

static void rec_hook(void)
{
    HINSTANCE self = GetModuleHandle("USOSPG");
    if (!mouse_hook) mouse_hook = SetWindowsHookEx(WH_MOUSE, (HOOKPROC)mouse_proc, self, 0);
    if (!key_hook) key_hook = SetWindowsHookEx(WH_KEYBOARD, (HOOKPROC)key_proc, self, 0);
    if ((!mouse_hook || !key_hook) && !rec_hook_failed) {
        rec_hook_failed = 1;
        say(!mouse_hook ? "rec: no mouse hook" : "rec: no keyboard hook");
    }
}

static void rec_unhook(void)
{
    if (mouse_hook) { UnhookWindowsHookEx(mouse_hook); mouse_hook = 0; }
    if (key_hook) { UnhookWindowsHookEx(key_hook); key_hook = 0; }
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
    rec_unhook();
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
    if (!in_rec) { in_rec = 1; rec_moves(0); in_rec = 0; }
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
        if (page && view.kind == PG_EULA) rec_radio(page);
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
    rec_hook();
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
    /* X470 98 FE PL run 3 (2026-10-27): DRV_DISABLE came only when the
     * mini-Windows ended; timers and hooks stay until DRV_FREE. */
    case DRV_DISABLE:
        if (pg_may_start(&st)) {
            if (!in_rec) { in_rec = 1; rec_moves(1); in_rec = 0; }
            say("disable (kept running until DRV_FREE)");
        }
        return 1L;
    case DRV_FREE:
        if (pg_may_start(&st)) say("free, stopped");
        stop_all();
        return 1L;
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
