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
 *     places (as shown), on the ready page (the found driver is
 *     ...\MONITOR.INF), Finish on the last page (that device name). Any
 *     other device, a changed choice, another driver file or an unknown
 *     result page: that wizard is the user's. The same steps the user did
 *     by hand on the X470 (98 FE PL, 2026-10-27).
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
 * after the 4th start. Nothing is left running: one instance (a mutex),
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

static char g_log[MAX_PATH], g_sta[MAX_PATH];
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
    "the driver is not MONITOR.INF", "page stayed after the press", "press limit" };

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
static const char *const page_name[] = { "none", "other", "intro", "search choice", "search places", "ready", "finish" };

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
        }
    }
    act = hw_step(&g_hw, (unsigned long)frame, (unsigned long)page, &p);
    if (act == AA_NEXT) { press(frame, HW_NEXT_ID); say2("wizard: Next pressed on ", page_name[kind]); }
    else if (act == AA_FINISH) { press(frame, HW_FINISH_ID); say("wizard: Finish pressed (Plug and Play Monitor)"); }
    else if (act == AA_LEAVE) say2("wizard: left to the user: ", event_name[g_hw.event]);
}

static void scan(void)
{
    char title[TEXT_CAP];
    int i, kind, hw_seen = 0;
    g_ntop = 0;
    EnumWindows(top_cb, 0);
    for (i = 0; i < g_ntop; i++) {
        title[0] = 0;
        if (!GetWindowTextA(g_top[i], title, sizeof title)) continue;
        kind = an_logon_kind(title);
        if (kind != AK_NONE) logon_tick(g_top[i], title, kind);
        else if (!hw_seen && an_is_hw_frame(title)) { hw_seen = 1; hw_tick(g_top[i]); }
    }
}

void __cdecl usos_entry(void)
{
    char line[200];
    DWORD start, now;
    HANDLE mutex;
    int pending, desk_now = 0;
    if (!paths()) ExitProcess(2);
    mutex = CreateMutexA(0, FALSE, "USOSANS-instance");
    if (mutex && GetLastError() == ERROR_ALREADY_EXISTS) ExitProcess(0);
    if (!(GetVersion() & 0x80000000UL)) { say("USOSANS: not Windows 9x, nothing to do"); ExitProcess(0); }
    state_read();
    g_boots++;
    pending = addons_pending();
    wsprintfA(line, "USOSANS start %u (desktop reached in %u earlier starts, add-on chain %s)",
              g_boots, g_desk, pending ? "pending" : "over");
    say(line);
    if (an_remove_now(g_boots, g_desk, pending)) {
        state_write();
        remove_value(g_boots > AN_MAX_BOOTS ? "start limit" : "first starts done");
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
        if (now - start >= AN_LIFETIME_MS) break;
        Sleep(AN_TICK_MS);
    }
    pending = addons_pending();
    say("USOSANS: 10 minutes over, ending");
    /* The next start would only remove the value: do it now. */
    if (an_remove_now(g_boots + 1, g_desk, pending))
        remove_value(g_boots + 1 > AN_MAX_BOOTS ? "start limit" : "first starts done");
    ExitProcess(0);
}
