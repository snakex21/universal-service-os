/*
 * USOSANS.EXE - answers two first-start dialogs of a USOS-installed
 * Windows 95 / 98 / 98 SE / Me the way the user would, nothing else.
 * Win32, no window, no C runtime (OpenWatcom wcc386 / wlink, PE 4.00).
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 *
 * Started from HKLM\Software\Microsoft\Windows\CurrentVersion\RunServices
 * (value USOSAns; Windows 9x starts these before the logon dialog), only
 * for a USOS answer in automatic mode whose Windows user has an empty
 * password (tools/w9x_csmwrap_target.sh). Every 250 ms, for 10 minutes
 * per start, it looks at the visible top-level dialogs:
 *
 *  1. The Windows Logon dialog of MPRSERV.DLL (first logon "Enter Windows
 *     Password", "Welcome to Windows", "Set Windows Password"; titles and
 *     IDs in usosans_logic.h). When the user name is filled in (Setup's
 *     DefaultUserName), the password field(s) stayed empty for 1 s and OK
 *     is enabled: OK. Windows itself then creates the user's empty
 *     password list and signs in; its hint says the prompt does not come
 *     back. Nothing is ever typed; once anything is in a password field
 *     the dialog is the user's. No password list is written by USOS.
 *  2. The new hardware wizard of SYSDM.CPL ("Add New Hardware Wizard")
 *     for the device "Plug and Play Monitor" (MONITOR.INF *PNP09FF; 98
 *     with DDC on): Next on the intro page (that device name only), on the
 *     search choice (the recommended search still selected), on the search
 *     places ("CD-ROM drive" and "Microsoft Windows Update" unchecked
 *     first, BM_SETCHECK + BN_CLICKED to the page), on the ready page (the found driver is
 *     ...\MONITOR.INF), Finish on the last page (that device name). Any
 *     other device, a changed choice, another driver file or an unknown
 *     result page: that wizard is the user's. The same steps the user did
 *     by hand on the X470 (98 FE PL, 2026-10-27). The search places page
 *     may stay 120 s; a page that stays after its press is logged once and
 *     watched, the next page of the wizard still gets its press. Its
 *     Windows Update offer (a "Microsoft Windows Update" message box,
 *     register now?) gets No, the notice after it OK.
 *  3. Windows 98's first-start Setup wizard (X470 98 FE PL run 3: user
 *     information, licence, product key and "Finish" come at the first
 *     start, not in Setup's mini-Windows): any visible dialog with the
 *     wizard frame buttons 0x3023..5 and a page with the title Static 1070,
 *     judged by USOSPG.DRV's page rules (usospg_logic.h) on 500 ms ticks:
 *     a name -> Next; licence -> 618 checked + its BN_CLICKED, then Next;
 *     all five key fields at 5 characters -> Next; the last page -> Finish,
 *     only in a frame that showed one of the other pages. Name and key
 *     fields are only measured (WM_GETTEXTLENGTH), never read.
 * Diagnostics (C:\USOS9X\USOSANS.TXT, at most 3000 recorder lines): every
 * visible top-level dialog once with what it was taken for; every wizard
 * page at first sight with all its controls (class, ID, Static / Button
 * text, button style and check state, Edits as their length only) and the
 * frame's buttons; why a tick pressed nothing (at every change); and while
 * a wizard is visible, every 50 ms: L / R mouse button and key presses
 * (virtual-key codes and modifiers only; a character key without Alt /
 * Ctrl as "a character key"; GetAsyncKeyState, 9x has no low-level hooks) with the
 * control under the cursor, and a cursor-move summary every 5 s. After 10
 * minutes the helper goes on only while a wizard is shown (30 at most).
 * Presses are WM_COMMAND BN_CLICKED posted to the dialog / wizard frame
 * (as USOSPG.DRV does in Setup's mini-Windows); texts are read with
 * WM_GETTEXT (SendMessageTimeout, 500 ms; a hung window counts as "not
 * ready"). Each step is logged to C:\USOS9X\USOSANS.TXT (beside the EXE;
 * never a password: only whether the fields are empty).
 *
 * Lifetime: C:\USOS9X\USOSANS.STA counts the starts and the starts that
 * reached the desktop (Shell_TrayWnd). The RunServices value is removed
 * (after 15 s, so the shell's value enumeration is not shifted) once two
 * starts reached the desktop and the USOS add-on chain is over (no
 * USOSAddons Run value; on 95 that also means FIRSTBT.OK), at the latest
 * after the 4th start; while the first-desktop coordinator still owns the
 * starts (FIRSTBT.ON, no FIRSTBT.OK / FIRSTBT.ERR) it stays, up to the 12th. Nothing is left running: one instance (a mutex),
 * it ends after 10 minutes.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include "usosans_logic.h"

#define RUNSVC_KEY "Software\\Microsoft\\Windows\\CurrentVersion\\RunServices"
#define RUN_KEY    "Software\\Microsoft\\Windows\\CurrentVersion\\Run"
#define VALUE_NAME "USOSAns"
#define MAX_TOP    32
#define TEXT_CAP   260

static char g_log[MAX_PATH], g_sta[MAX_PATH], g_dir[MAX_PATH];
static unsigned g_boots, g_desk;

static int slen(const char *s) { int n = 0; while (s[n]) n++; return n; }

static void scat(char *d, int cap, const char *s)
{
    int n = slen(d);
    while (*s && n + 1 < cap) d[n++] = *s++;
    d[n] = 0;
}

static void mzero(void *d, unsigned n)
{
    unsigned char *b = (unsigned char *)d;
    while (n--) *b++ = 0;
}

static int seq(const char *a, const char *b)
{
    while (*a && *a == *b) { a++; b++; }
    return *a == *b;
}

static void say(const char *text)
{
    char line[512];
    SYSTEMTIME t;
    HANDLE h;
    DWORD put;
    GetLocalTime(&t);
    wsprintfA(line, "%04d-%02d-%02d %02d:%02d:%02d ", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond);
    scat(line, sizeof line, text);
    scat(line, sizeof line, "\r\n");
    h = CreateFileA(g_log, GENERIC_WRITE, FILE_SHARE_READ, 0, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    if (h == INVALID_HANDLE_VALUE) return;
    SetFilePointer(h, 0, 0, FILE_END);
    WriteFile(h, line, (DWORD)slen(line), &put, 0);
    FlushFileBuffers(h);
    CloseHandle(h);
}

static void say2(const char *a, const char *b)
{
    char line[400];
    line[0] = 0;
    scat(line, sizeof line, a);
    scat(line, sizeof line, b);
    say(line);
}

static int paths(void)
{
    char app[MAX_PATH];
    DWORD n = GetModuleFileNameA(0, app, sizeof app), i;
    if (!n || n >= sizeof app) return 0;
    for (i = n; i && app[i - 1] != '\\' && app[i - 1] != '/'; i--) ;
    if (!i || i > MAX_PATH - 16) return 0;
    app[i] = 0;
    lstrcpyA(g_dir, app);
    lstrcpyA(g_log, app); lstrcatA(g_log, "USOSANS.TXT");
    lstrcpyA(g_sta, app); lstrcatA(g_sta, "USOSANS.STA");
    return 1;
}

static void state_read(void)
{
    char buf[128];
    DWORD got = 0;
    HANDLE h = CreateFileA(g_sta, GENERIC_READ, FILE_SHARE_READ, 0, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
    g_boots = g_desk = 0;
    if (h == INVALID_HANDLE_VALUE) return;
    if (ReadFile(h, buf, sizeof buf - 1, &got, 0) && got) {
        g_boots = an_field(buf, (int)got, "boots");
        g_desk = an_field(buf, (int)got, "desk");
    }
    CloseHandle(h);
}

static void state_write(void)
{
    char buf[64];
    DWORD put;
    HANDLE h = CreateFileA(g_sta, GENERIC_WRITE, 0, 0, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    if (h == INVALID_HANDLE_VALUE) { say("state: cannot write USOSANS.STA"); return; }
    wsprintfA(buf, "boots=%u desk=%u\r\n", g_boots, g_desk);
    WriteFile(h, buf, (DWORD)slen(buf), &put, 0);
    FlushFileBuffers(h);
    CloseHandle(h);
}

static int addons_pending(void)
{
    HKEY k;
    DWORD type, size = 0;
    LONG r;
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, RUN_KEY, 0, KEY_READ, &k) != ERROR_SUCCESS) return 0;
    r = RegQueryValueExA(k, "USOSAddons", 0, &type, 0, &size);
    RegCloseKey(k);
    return r == ERROR_SUCCESS;
}

/* The 95 / 98 first-desktop coordinator (USOSFB, beside this program in
 * C:\USOS9X) still owns the starts: FIRSTBT.ON without FIRSTBT.OK or
 * FIRSTBT.ERR. */
static int beside(const char *leaf)
{
    char path[MAX_PATH];
    lstrcpyA(path, g_dir);
    lstrcatA(path, leaf);
    return GetFileAttributesA(path) != (DWORD)-1;
}

static int chain_open(void)
{
    return beside("FIRSTBT.ON") && !beside("FIRSTBT.OK") && !beside("FIRSTBT.ERR");
}

/* The shell enumerates RunServices by index: deleting our own value at
 * once could shift the next one onto our index (the 95 Run lesson,
 * tools/w9x_reg95.sh). Wait first. */
static void remove_value(const char *why)
{
    HKEY k;
    LONG r = ERROR_FILE_NOT_FOUND;
    Sleep(15000);
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, RUNSVC_KEY, 0, KEY_SET_VALUE, &k) == ERROR_SUCCESS) {
        r = RegDeleteValueA(k, VALUE_NAME);
        RegCloseKey(k);
    }
    say2(r == ERROR_SUCCESS ? "RunServices USOSAns removed: " : "RunServices USOSAns not removed (absent or refused): ", why);
}

static int text_of(HWND w, char *out, int cap)
{
    DWORD res = 0;
    out[0] = 0;
    if (!w) return -1;
    if (!SendMessageTimeoutA(w, WM_GETTEXT, (WPARAM)cap, (LPARAM)out, SMTO_ABORTIFHUNG, 500, &res)) { out[0] = 0; return -1; }
    out[cap - 1] = 0;
    return slen(out);
}

static int length_of(HWND w)
{
    DWORD res = 0;
    if (!w) return -1;
    if (!SendMessageTimeoutA(w, WM_GETTEXTLENGTH, 0, 0, SMTO_ABORTIFHUNG, 500, &res)) return -1;
    return (int)res;
}

static int checked(HWND w)
{
    DWORD res = 0;
    if (!w) return 0;
    if (!SendMessageTimeoutA(w, BM_GETCHECK, 0, 0, SMTO_ABORTIFHUNG, 500, &res)) return 0;
    return res == BST_CHECKED;
}

static int button_ready(HWND w) { return w && IsWindowVisible(w) && IsWindowEnabled(w); }

static void press(HWND parent, int id)
{
    HWND b = GetDlgItem(parent, id);
    PostMessageA(parent, WM_COMMAND, MAKEWPARAM(id, BN_CLICKED), (LPARAM)b);
}

/* ---- window lists ---- */

static HWND g_top[MAX_TOP];
static int g_ntop;

static BOOL CALLBACK top_cb(HWND w, LPARAM l)
{
    char cls[16];
    (void)l;
    if (g_ntop >= MAX_TOP) return FALSE;
    if (!IsWindowVisible(w)) return TRUE;
    if (!GetClassNameA(w, cls, sizeof cls) || !seq(cls, "#32770")) return TRUE;
    g_top[g_ntop++] = w;
    return TRUE;
}

typedef struct { HWND frame, page; } PAGEFIND;

static BOOL CALLBACK page_cb(HWND w, LPARAM l)
{
    PAGEFIND *f = (PAGEFIND *)l;
    char cls[16];
    if (GetParent(w) != f->frame || !IsWindowVisible(w)) return TRUE;
    if (!GetClassNameA(w, cls, sizeof cls) || !seq(cls, "#32770")) return TRUE;
    f->page = w;
    return FALSE;
}

typedef struct { HWND page; int monitor; int inf; char first[TEXT_CAP]; char file[TEXT_CAP]; } TEXTSCAN;

/* Every Static / Edit of a ready page: one is the stock monitor, one
 * names ...\MONITOR.INF. */
static BOOL CALLBACK text_cb(HWND w, LPARAM l)
{
    TEXTSCAN *t = (TEXTSCAN *)l;
    char cls[16], buf[TEXT_CAP];
    if (!GetClassNameA(w, cls, sizeof cls)) return TRUE;
    if (lstrcmpiA(cls, "Static") && lstrcmpiA(cls, "Edit")) return TRUE;
    if (text_of(w, buf, sizeof buf) <= 0) return TRUE;
    if (an_is_monitor(buf)) { t->monitor = 1; if (!t->first[0]) lstrcpynA(t->first, buf, TEXT_CAP); }
    if (an_names_monitor_inf(buf)) { t->inf = 1; if (!t->file[0]) lstrcpynA(t->file, buf, TEXT_CAP); }
    return TRUE;
}

/* ---- logon ---- */

/* One state per logon dialog (a confirmation may show while the first
 * dialog is still up); the OK limit counts over all of them. */
#define LOG_SLOTS 4
static ANLOGSTATE g_log_slot[LOG_SLOTS];
static unsigned g_log_next;
static unsigned char g_log_presses;

static ANLOGSTATE *log_slot(HWND w, int *fresh)
{
    unsigned i;
    for (i = 0; i < LOG_SLOTS; i++)
        if (g_log_slot[i].cur == (unsigned long)w) { *fresh = 0; return &g_log_slot[i]; }
    *fresh = 1;
    i = g_log_next++ % LOG_SLOTS;
    mzero(&g_log_slot[i], sizeof g_log_slot[i]);
    return &g_log_slot[i];
}
static const char *const kind_name[] = { "-", "first logon", "welcome", "set password" };
static const char *const event_name[] = { "", "unexpected controls", "a password was typed", "no user name",
    "button not enabled", "another device", "the choice was changed", "device not confirmed",
    "the driver is not MONITOR.INF", "page stayed after the press", "press limit",
    "Windows Update / CD-ROM stayed checked on the search places page" };

static void logon_tick(HWND w, const char *title, int kind)
{
    ANLOGON v;
    ANLOGSTATE *st;
    int act, fresh;
    char line[400];
    HWND ok = GetDlgItem(w, AN_OK_ID);
    v.kind = (unsigned char)kind;
    if (kind == AK_SET) {
        v.shape = GetDlgItem(w, AN_NEW_ID) && GetDlgItem(w, AN_CONFIRM_ID) && ok;
        v.user_len = 0;
        v.pass_len = length_of(GetDlgItem(w, AN_NEW_ID));
        v.confirm_len = length_of(GetDlgItem(w, AN_CONFIRM_ID));
    } else {
        v.shape = GetDlgItem(w, AN_USER_ID) && GetDlgItem(w, AN_PASS_ID) && ok;
        v.user_len = length_of(GetDlgItem(w, AN_USER_ID));
        v.pass_len = length_of(GetDlgItem(w, AN_PASS_ID));
        v.confirm_len = 0;
    }
    v.ok_ready = (unsigned char)button_ready(ok);
    st = log_slot(w, &fresh);
    if (fresh) {
        wsprintfA(line, "logon dialog \"%s\" (%s): user name %s, password field %s", title, kind_name[kind],
                  kind == AK_SET ? "-" : v.user_len > 0 ? "filled" : "empty",
                  v.pass_len == 0 ? "empty" : v.pass_len < 0 ? "unreadable" : "not empty");
        say(line);
    }
    st->presses = g_log_presses;
    act = an_logon_step(st, (unsigned long)w, &v);
    g_log_presses = st->presses;
    if (act == AA_OK) {
        press(w, AN_OK_ID);
        say2("logon: OK pressed (empty password) on ", kind_name[kind]);
    } else if (act == AA_LEAVE) {
        say2("logon: dialog left to the user: ", event_name[st->event]);
    }
}

/* ---- the new hardware wizard ---- */

static HWSTATE g_hw;
static unsigned char g_hw_why = 0xFF;
static const char *const page_name[] = { "none", "other", "intro", "search choice", "search places", "ready", "finish" };
static const char *const hw_why_name[] = { "", "no page visible", "page of an unknown kind (only watched)",
    "page settling", "its button is not enabled yet", "pressed, waiting for the page to go",
    "page stayed after the press (only watched)", "this wizard was left to the user" };
static void dump_page(HWND frame, HWND page);

static void hw_tick(HWND frame)
{
    PAGEFIND f;
    HWPAGE p;
    TEXTSCAN t;
    char name[TEXT_CAP], line[700];
    int act, kind;
    HWND page;
    f.frame = frame; f.page = 0;
    EnumChildWindows(frame, page_cb, (LPARAM)&f);
    page = f.page;
    mzero(&p, sizeof p);
    name[0] = 0;
    t.page = page; t.monitor = 0; t.inf = 0; t.first[0] = 0; t.file[0] = 0;
    if (page) {
        p.name = GetDlgItem(page, HW_NAME_ID) != 0;
        p.me_auto = GetDlgItem(page, HW_ME_AUTO_ID) != 0;
        p.me_auto_on = (unsigned char)checked(GetDlgItem(page, HW_ME_AUTO_ID));
        p.me_manual_on = (unsigned char)checked(GetDlgItem(page, HW_ME_MANUAL_ID));
        p.search = GetDlgItem(page, HW_SEARCH_ID) != 0;
        p.search_on = (unsigned char)checked(GetDlgItem(page, HW_SEARCH_ID));
        p.list = GetDlgItem(page, HW_LIST_ID) != 0;
        p.list_on = (unsigned char)checked(GetDlgItem(page, HW_LIST_ID));
        p.places = GetDlgItem(page, HW_PLACE1_ID) && GetDlgItem(page, HW_PLACE4_ID);
        p.ready = GetDlgItem(page, HW_READY_ID) && GetDlgItem(page, HW_LOCATION_ID);
        p.fin = GetDlgItem(page, HW_FIN_ICON_ID) && GetDlgItem(page, HW_FIN_NAME_ID);
        kind = hw_classify(&p);
        if (kind == HP_INTRO) text_of(GetDlgItem(page, HW_NAME_ID), name, sizeof name);
        else if (kind == HP_FINISH) text_of(GetDlgItem(page, HW_FIN_NAME_ID), name, sizeof name);
        if (kind == HP_INTRO || kind == HP_FINISH) p.monitor = (unsigned char)an_is_monitor(name);
        if (kind == HP_READY) {
            EnumChildWindows(page, text_cb, (LPARAM)&t);
            p.monitor = (unsigned char)t.monitor;
            p.monitor_inf = (unsigned char)t.inf;
            lstrcpynA(name, t.first, sizeof name);
        }
        if (kind == HP_PLACES) {
            p.cd_on = (unsigned char)checked(GetDlgItem(page, HW_PLACE_CD_ID));
            p.wu_on = (unsigned char)checked(GetDlgItem(page, HW_PLACE_WU_ID));
        }
        p.next_ready = (unsigned char)button_ready(GetDlgItem(frame, HW_NEXT_ID));
        p.finish_ready = (unsigned char)button_ready(GetDlgItem(frame, HW_FINISH_ID));
    } else kind = HP_NONE;
    if ((unsigned long)frame != g_hw.frame) say("new hardware wizard shown");
    if ((unsigned long)frame != g_hw.frame || (unsigned long)page != g_hw.page || kind != g_hw.kind) {
        if (kind != HP_NONE) {
            wsprintfA(line, "wizard page: %s%s%s%s%s", page_name[kind], name[0] ? ", device \"" : "", name,
                      name[0] ? "\"" : "", kind == HP_READY ? (t.inf ? ", driver " : ", no MONITOR.INF") : "");
            if (kind == HP_READY && t.inf) scat(line, sizeof line, t.file);
            say(line);
        } else say("wizard page: none visible (no #32770 child of the frame)");
        dump_page(frame, page);
    }
    act = hw_step(&g_hw, (unsigned long)frame, (unsigned long)page, &p);
    if (act == AA_UNCHECK) {
        /* the check box cleared, then BN_CLICKED to the page: its handler
         * reads the new state as after a click */
        static const int ids[2] = { HW_PLACE_WU_ID, HW_PLACE_CD_ID };
        static const char *const names[2] = { "Microsoft Windows Update (3496)", "CD-ROM drive (3495)" };
        int j;
        for (j = 0; j < 2; j++) {
            HWND box = GetDlgItem(page, ids[j]);
            DWORD res;
            if (!checked(box)) continue;
            SendMessageTimeoutA(box, BM_SETCHECK, BST_UNCHECKED, 0, SMTO_ABORTIFHUNG, 500, &res);
            press(page, ids[j]);
            say2("wizard: search places: unchecked ", names[j]);
        }
    }
    else if (act == AA_NEXT) { press(frame, HW_NEXT_ID); say2("wizard: Next pressed on ", page_name[kind]); }
    else if (act == AA_FINISH) { press(frame, HW_FINISH_ID); say("wizard: Finish pressed (Plug and Play Monitor)"); }
    else if (act == AA_LEAVE && g_hw.event == AE_STUCK) say2("wizard: page stayed after the press, still watching: ", page_name[kind]);
    else if (act == AA_LEAVE) say2("wizard: left to the user: ", event_name[g_hw.event]);
    if (act == AA_NONE && g_hw.why != g_hw_why) {
        g_hw_why = g_hw.why;
        if (g_hw.why != AW_NONE && g_hw.why != AW_SETTLING) say2("wizard: nothing pressed: ", hw_why_name[g_hw.why]);
    } else if (act != AA_NONE) g_hw_why = 0xFF;
}

/* ---- recorder output (bounded) ---- */

static unsigned g_rec_lines;

static void rec_say(const char *text)
{
    int allow = an_rec_allow(&g_rec_lines);
    if (allow == 1) say(text);
    else if (allow == 2) say("recorder: 3000 lines, detailed logging stops");
}

/* Control characters and quotes of a control's text as blanks. */
static void flatten(char *s)
{
    for (; *s; s++) if ((unsigned char)*s < 32 || *s == '"') *s = ' ';
}

static int class_of(HWND w, const char *name)
{
    char cls[16];
    return w && GetClassNameA(w, cls, sizeof cls) && !lstrcmpiA(cls, name);
}

static int is_child(HWND w)
{
    return (GetWindowLongA(w, GWL_STYLE) & WS_CHILD) != 0;
}

/* The text of a Static, Button or dialog only: never an Edit's. */
static int safe_text(HWND w, char *out, int cap)
{
    out[0] = 0;
    if (!w) return 0;
    if (is_child(w) && !class_of(w, "Static") && !class_of(w, "Button") && !class_of(w, "#32770")) return 0;
    if (text_of(w, out, cap) < 0) out[0] = 0;
    flatten(out);
    return slen(out);
}

/* " cls=.. id=.. text=".." style=.. check=.. enabled" of w. */
static void describe(HWND w, char *line, int cap)
{
    char cls[16], txt[80], part[200];
    LONG style;
    if (!w) { scat(line, cap, " window=none"); return; }
    if (!GetClassNameA(w, cls, sizeof cls)) cls[0] = 0;
    style = GetWindowLongA(w, GWL_STYLE);
    wsprintfA(part, " cls=%s", cls);
    scat(line, cap, part);
    if (style & WS_CHILD) { wsprintfA(part, " id=%d", GetDlgCtrlID(w)); scat(line, cap, part); }
    if (!lstrcmpiA(cls, "Edit")) { wsprintfA(part, " length=%d", length_of(w)); scat(line, cap, part); }
    else if (safe_text(w, txt, sizeof txt)) { wsprintfA(part, " text=\"%s\"", txt); scat(line, cap, part); }
    if (!lstrcmpiA(cls, "Button")) {
        DWORD res = 0;
        SendMessageTimeoutA(w, BM_GETCHECK, 0, 0, SMTO_ABORTIFHUNG, 500, &res);
        wsprintfA(part, " style=%d check=%d", (int)(style & 15), (int)res);
        scat(line, cap, part);
    }
    scat(line, cap, IsWindowVisible(w) ? (IsWindowEnabled(w) ? " enabled" : " disabled") : " hidden");
}

static BOOL CALLBACK dump_cb(HWND w, LPARAM l)
{
    int *count = (int *)l;
    char line[400];
    if (++*count > 40) return FALSE;
    lstrcpyA(line, "  control");
    describe(w, line, sizeof line);
    rec_say(line);
    return TRUE;
}

/* A page seen for the first time: every control, then the frame's buttons. */
static void dump_page(HWND frame, HWND page)
{
    static const int ids[] = { 0x3023, 0x3024, 0x3025, IDCANCEL };
    static const char *const names[] = { "Back", "Next", "Finish", "Cancel" };
    char line[400];
    int i, count = 0;
    if (page) EnumChildWindows(page, dump_cb, (LPARAM)&count);
    for (i = 0; i < 4; i++) {
        HWND b = GetDlgItem(frame, ids[i]);
        if (!b) continue;
        wsprintfA(line, "  frame %s", names[i]);
        describe(b, line, sizeof line);
        rec_say(line);
    }
}

/* ---- Windows 98's first-start Setup wizard ---- */

static SUSTATE g_su;
static HWND g_su_page_logged;
static int g_su_kind_logged = -1;
static unsigned char g_su_why = 0xFF;
static const char *const su_kind_name[] = { "other", "user information", "licence", "product key", "finish" };
static const char *const su_why_name[] = { "", "no page with the title Static 1070", "page not one of the four kinds",
    "finish page, but no user / licence / key page seen in this frame", "page settling", "Next not enabled yet",
    "pressed, waiting for the page to go", "page left to the user" };

static int is_setup_frame(HWND w)
{
    return class_of(GetDlgItem(w, PG_BACK_ID), "Button") && class_of(GetDlgItem(w, PG_NEXT_ID), "Button")
        && class_of(GetDlgItem(w, PG_FINISH_ID), "Button");
}

static BOOL CALLBACK su_page_cb(HWND w, LPARAM l)
{
    PAGEFIND *f = (PAGEFIND *)l;
    if (GetParent(w) != f->frame || !IsWindowVisible(w) || !class_of(w, "#32770")) return TRUE;
    if (!GetDlgItem(w, PG_TITLE_ID)) return TRUE;
    f->page = w;
    return FALSE;
}

static BOOL CALLBACK clickable_cb(HWND w, LPARAM l)
{
    PGSHAPE *sh = (PGSHAPE *)l;
    if (IsWindowVisible(w) && (class_of(w, "Edit") || class_of(w, "Button") || class_of(w, "ListBox") || class_of(w, "ComboBox")))
        if (sh->clickable < 255) sh->clickable++;
    return TRUE;
}

static void su_tick(HWND frame)
{
    PAGEFIND f;
    PGSHAPE sh;
    PGVIEW v;
    HWND page, next, fin;
    unsigned char act;
    int i, keys = 0, kind = PG_OTHER;
    char title[TEXT_CAP], line[600];
    if ((unsigned long)frame != g_su.frame) { g_su_page_logged = 0; g_su_kind_logged = -1; g_su_why = 0xFF; say("setup wizard frame seen"); }
    f.frame = frame; f.page = 0;
    EnumChildWindows(frame, su_page_cb, (LPARAM)&f);
    page = f.page;
    next = GetDlgItem(frame, PG_NEXT_ID);
    fin = GetDlgItem(frame, PG_FINISH_ID);
    mzero(&v, sizeof v);
    v.active = 1;
    if (page) {
        mzero(&sh, sizeof sh);
        sh.title = 1;
        sh.name = (unsigned char)class_of(GetDlgItem(page, PG_NAME_ID), "Edit");
        sh.org = (unsigned char)class_of(GetDlgItem(page, PG_ORG_ID), "Edit");
        sh.eula_text = (unsigned char)class_of(GetDlgItem(page, PG_EULA_TEXT_ID), "Edit");
        sh.eula_yes = (unsigned char)class_of(GetDlgItem(page, PG_EULA_YES_ID), "Button");
        sh.eula_no = (unsigned char)class_of(GetDlgItem(page, PG_EULA_NO_ID), "Button");
        for (i = 0; i < PG_KEY_FIELDS; i++)
            if (class_of(GetDlgItem(page, PG_KEY1_ID + i), "Edit")) sh.key_edits++;
        EnumChildWindows(page, clickable_cb, (LPARAM)&sh);
        sh.next_shown = (unsigned char)(next && IsWindowVisible(next));
        sh.finish_shown = (unsigned char)(fin && IsWindowVisible(fin));
        kind = pg_classify(&sh);
        v.kind = (unsigned char)kind;
        v.page = (unsigned short)(unsigned long)page;
        switch (kind) {
        case PG_USER:   v.filled = length_of(GetDlgItem(page, PG_NAME_ID)) > 0; break;
        case PG_EULA:
            v.filled = 1;
            v.accepted = (unsigned char)checked(GetDlgItem(page, PG_EULA_YES_ID));
            v.declined = (unsigned char)checked(GetDlgItem(page, PG_EULA_NO_ID));
            break;
        case PG_KEY:
            /* only the lengths of the key fields, never their text */
            for (i = 0; i < PG_KEY_FIELDS; i++)
                if (length_of(GetDlgItem(page, PG_KEY1_ID + i)) == PG_KEY_PART_LEN) keys++;
            v.filled = keys == PG_KEY_FIELDS;
            break;
        case PG_FINISH: v.filled = (unsigned char)button_ready(fin); break;
        }
        v.next_ready = (unsigned char)button_ready(next);
        if (page != g_su_page_logged || kind != g_su_kind_logged) {
            g_su_page_logged = page;
            g_su_kind_logged = kind;
            safe_text(GetDlgItem(page, PG_TITLE_ID), title, sizeof title);
            wsprintfA(line, "setup wizard page: %s \"%s\", next %s, finish %s%s", su_kind_name[kind], title,
                      v.next_ready ? "ready" : "not ready", button_ready(fin) ? "ready" : "not ready",
                      kind == PG_USER ? (v.filled ? ", name filled" : ", name empty")
                      : kind == PG_EULA ? (v.accepted ? ", accept checked" : v.declined ? ", decline checked" : ", nothing checked")
                      : "");
            if (kind == PG_KEY) { char k[40]; wsprintfA(k, ", key fields complete %d of 5", keys); scat(line, sizeof line, k); }
            say(line);
            dump_page(frame, page);
        }
    }
    act = su_step(&g_su, (unsigned long)frame, &v);
    switch (act) {
    case PA_ACCEPT: {
        DWORD res;
        HWND yes = GetDlgItem(page, PG_EULA_YES_ID), no = GetDlgItem(page, PG_EULA_NO_ID);
        SendMessageTimeoutA(yes, BM_SETCHECK, BST_CHECKED, 0, SMTO_ABORTIFHUNG, 500, &res);
        SendMessageTimeoutA(no, BM_SETCHECK, BST_UNCHECKED, 0, SMTO_ABORTIFHUNG, 500, &res);
        press(page, PG_EULA_YES_ID);
        say("setup wizard: licence accepted (618), automatic mode");
        break;
    }
    case PA_NEXT:
        press(frame, PG_NEXT_ID);
        say2("setup wizard: Next pressed on ", su_kind_name[g_su.pg.kind]);
        break;
    case PA_FINISH:
        press(frame, PG_FINISH_ID);
        say("setup wizard: Finish pressed");
        break;
    default:
        switch (g_su.pg.event) {
        case PE_LEFT:
            say2("setup wizard: left to the user: ",
                 g_su.pg.kind == PG_EULA ? "licence declined" : g_su.pg.kind == PG_KEY ? "key not complete" : "name empty");
            break;
        case PE_NO_NEXT: say2("setup wizard: left to the user, Next stayed disabled on ", su_kind_name[g_su.pg.kind]); break;
        case PE_STUCK:   say2("setup wizard: left to the user, page stayed after the press: ", su_kind_name[g_su.pg.kind]); break;
        }
    }
    if (g_su.why != g_su_why) {
        g_su_why = g_su.why;
        if (g_su.why != SW_NONE && g_su.why != SW_SETTLING) say2("setup wizard: nothing pressed: ", su_why_name[g_su.why]);
    }
}

/* ---- the Windows Update offer (a message box over the wizard) ---- */

static ANWUSTATE g_wu;

static void wu_tick(HWND w)
{
    ANWUBOX v;
    int act;
    v.yes = (unsigned char)button_ready(GetDlgItem(w, AN_YES_ID));
    v.no = (unsigned char)button_ready(GetDlgItem(w, AN_NO_ID));
    v.ok = (unsigned char)button_ready(GetDlgItem(w, AN_OK_ID));
    v.cancel = (unsigned char)button_ready(GetDlgItem(w, AN_CANCEL_ID));
    v.wizard = (unsigned char)(g_hw.frame && IsWindowVisible((HWND)g_hw.frame));
    act = an_wu_step(&g_wu, (unsigned long)w, &v);
    if (act == AA_NO) { press(w, AN_NO_ID); say("Windows Update offer: No pressed (no registration, no Windows Update)"); }
    else if (act == AA_CANCEL) { press(w, AN_CANCEL_ID); say("Windows Update offer: Cancel pressed"); }
    else if (act == AA_OK) { press(w, AN_OK_ID); say("Windows Update notice: OK pressed"); }
    else if (act == AA_LEAVE) say(v.wizard ? "Windows Update box left to the user (not Yes / No, OK / Cancel or OK alone, or press limit)"
                                         : "Windows Update box left to the user (no new hardware wizard shown)");
}

/* ---- top-level dialogs seen (once per window) ---- */

#define SEEN_SLOTS 24
static HWND g_seen[SEEN_SLOTS];
static unsigned g_seen_next;

static void note_dialog(HWND w, const char *title, const char *what)
{
    char line[400];
    int i;
    for (i = 0; i < SEEN_SLOTS; i++) if (g_seen[i] == w) return;
    g_seen[g_seen_next++ % SEEN_SLOTS] = w;
    wsprintfA(line, "dialog seen: \"%s\" -> %s", title, what);
    rec_say(line);
}

/* ---- the click recorder ---- */

static HWND g_watch;                /* the wizard frame of the last scan */
static unsigned char g_btn[2], g_keys[256];
static PGMOVES g_moves;
static POINT g_pt;
static int g_have_pt;

static HWND top_of(HWND w)
{
    int i;
    for (i = 0; i < 16 && w && is_child(w); i++) w = GetParent(w);
    return w;
}

static void rec_click(const char *what, POINT pt)
{
    char line[600], title[80], part[200];
    HWND w = WindowFromPoint(pt), top = top_of(w);
    wsprintfA(line, "%s at %d,%d:", what, (int)pt.x, (int)pt.y);
    describe(w, line, sizeof line);
    title[0] = 0;
    if (top) GetWindowTextA(top, title, sizeof title);
    flatten(title);
    wsprintfA(part, " top=\"%s\"%s", title, top == g_watch ? "" : " (not the wizard)");
    scat(line, sizeof line, part);
    if (top == g_watch && g_su.frame == (unsigned long)g_watch && g_su_page_logged) {
        safe_text(GetDlgItem(g_su_page_logged, PG_TITLE_ID), title, sizeof title);
        wsprintfA(part, " page=\"%s\"", title);
        scat(line, sizeof line, part);
    } else if (top == g_watch && g_hw.frame == (unsigned long)g_watch) {
        wsprintfA(part, " page=%s", page_name[g_hw.kind]);
        scat(line, sizeof line, part);
    }
    rec_say(line);
}

/* Virtual-key code and modifiers only, never a character (an_key_code_shown). */
static void rec_key(int vk)
{
    char line[400], what[64];
    POINT pt;
    int alt = (GetAsyncKeyState(VK_MENU) & 0x8000) != 0, ctrl = (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0;
    int shift = (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0;
    const char *name = vk == VK_RETURN ? " Enter" : vk == VK_TAB ? " Tab" : vk == VK_ESCAPE ? " Esc"
                     : vk == VK_MENU ? " Alt" : vk == VK_CONTROL ? " Ctrl" : vk == VK_SHIFT ? " Shift" : "";
    if (an_key_code_shown(vk, alt, ctrl)) wsprintfA(what, "VK 0x%02X%s", vk, name);
    else lstrcpyA(what, "(a character key)");
    if (vk != VK_MENU && alt) lstrcatA(what, " +Alt");
    if (vk != VK_CONTROL && ctrl) lstrcatA(what, " +Ctrl");
    if (vk != VK_SHIFT && shift) lstrcatA(what, " +Shift");
    GetCursorPos(&pt);
    wsprintfA(line, "key %s, window under the cursor:", what);
    describe(WindowFromPoint(pt), line, sizeof line);
    rec_say(line);
}

static void rec_poll(void)
{
    static const int vk_btn[2] = { VK_LBUTTON, VK_RBUTTON };
    static const char *const btn_name[2] = { "click L", "click R" };
    char line[200];
    POINT pt;
    DWORD now = GetTickCount();
    int i, watching = g_watch && IsWindowVisible(g_watch);
    for (i = 0; i < 2; i++) {
        int down = (GetAsyncKeyState(vk_btn[i]) & 0x8000) != 0;
        if (an_edge(&g_btn[i], down) && watching) { GetCursorPos(&pt); rec_click(btn_name[i], pt); }
    }
    for (i = 0; i < 256; i++) {
        int down;
        if (!an_key_polled(i)) continue;
        down = (GetAsyncKeyState(i) & 0x8000) != 0;
        if (an_edge(&g_keys[i], down) && watching) rec_key(i);
    }
    if (!watching) { g_have_pt = 0; pg_move_reset(&g_moves); return; }
    GetCursorPos(&pt);
    if (g_have_pt && (pt.x != g_pt.x || pt.y != g_pt.y)) pg_move_add(&g_moves, (int)pt.x, (int)pt.y, now);
    g_pt = pt;
    g_have_pt = 1;
    if (pg_move_due(&g_moves, now, 0)) {
        wsprintfA(line, "cursor moved in %u polls (50 ms), distance %lu, in %lu ms", g_moves.n, g_moves.dist, now - g_moves.since);
        rec_say(line);
        pg_move_reset(&g_moves);
    }
}

static unsigned g_scans;

static void scan(void)
{
    char title[TEXT_CAP];
    int i, kind, hw_seen = 0, su_seen = 0;
    g_ntop = 0;
    g_watch = 0;
    g_scans++;
    EnumWindows(top_cb, 0);
    for (i = 0; i < g_ntop; i++) {
        title[0] = 0;
        GetWindowTextA(g_top[i], title, sizeof title);
        kind = an_logon_kind(title);
        if (kind != AK_NONE) { note_dialog(g_top[i], title, "logon dialog"); logon_tick(g_top[i], title, kind); }
        else if (an_is_wu_box(title)) { note_dialog(g_top[i], title, "Windows Update offer of the device installer"); wu_tick(g_top[i]); }
        else if (!hw_seen && an_is_hw_frame(title)) {
            note_dialog(g_top[i], title, "new hardware wizard");
            hw_seen = 1;
            if (!g_watch) g_watch = g_top[i];
            hw_tick(g_top[i]);
        } else if (!su_seen && is_setup_frame(g_top[i])) {
            note_dialog(g_top[i], title, "wizard frame (Back / Next / Finish): Setup pages looked for");
            su_seen = 1;
            g_watch = g_top[i];
            if (!(g_scans & 1)) su_tick(g_top[i]);      /* 500 ms ticks, as in USOSPG.DRV */
        } else note_dialog(g_top[i], title, "not handled (title / buttons not known)");
    }
}

void __cdecl usos_entry(void)
{
    char line[200];
    DWORD start, now;
    HANDLE mutex;
    int pending, desk_now = 0, k;
    if (!paths()) ExitProcess(2);
    mutex = CreateMutexA(0, FALSE, "USOSANS-instance");
    if (mutex && GetLastError() == ERROR_ALREADY_EXISTS) ExitProcess(0);
    if (!(GetVersion() & 0x80000000UL)) { say("USOSANS: not Windows 9x, nothing to do"); ExitProcess(0); }
    state_read();
    g_boots++;
    pending = addons_pending();
    /* With the first-desktop coordinator (FIRSTBT.ON) USOSFB runs the
     * add-on chain, not the USOSAddons Run value: its markers say whether
     * the chain is over (X470 98 FE PL 2026-10-28 logged "chain over" at
     * the start of a package boot). The removal decision is unchanged. */
    wsprintfA(line, "USOSANS start %u (desktop reached in %u earlier starts, add-on chain %s)",
              g_boots, g_desk,
              !beside("FIRSTBT.ON") ? (pending ? "pending" : "over")
              : beside("FIRSTBT.OK") ? "over (USOSFB: FIRSTBT.OK)"
              : beside("FIRSTBT.ERR") ? "stopped (USOSFB: FIRSTBT.ERR)"
              : "pending (USOSFB: no FIRSTBT.OK / ERR yet)");
    say(line);
    say(chain_open() ? "first-desktop coordinator still owns the starts (FIRSTBT.ON, no FIRSTBT.OK / ERR): value kept up to 12 starts"
                     : "first-desktop coordinator not staged or finished");
    if (an_remove_now(g_boots, g_desk, pending, chain_open())) {
        state_write();
        remove_value(g_boots > AN_HARD_MAX_BOOTS ? "hard start limit" : g_boots > AN_MAX_BOOTS ? "start limit" : "first starts done");
        ExitProcess(0);
    }
    state_write();
    start = GetTickCount();
    for (;;) {
        scan();
        if (!desk_now && FindWindowA("Shell_TrayWnd", 0)) {
            desk_now = 1;
            g_desk++;
            state_write();
            say("desktop reached");
        }
        now = GetTickCount();
        if (an_time_up(now - start, g_watch && IsWindowVisible(g_watch))) break;
        for (k = 0; k < AN_TICK_MS / AN_POLL_MS; k++) { rec_poll(); Sleep(AN_POLL_MS); }
    }
    pending = addons_pending();
    say("USOSANS: time over (10 minutes, longer while a wizard was shown), ending");
    /* The next start would only remove the value: do it now. */
    if (an_remove_now(g_boots + 1, g_desk, pending, chain_open()))
        remove_value(g_boots + 1 > AN_HARD_MAX_BOOTS ? "hard start limit" : g_boots + 1 > AN_MAX_BOOTS ? "start limit" : "first starts done");
    ExitProcess(0);
}
