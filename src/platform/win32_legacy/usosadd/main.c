/* USOSADD.EXE - USOS legacy post-install runner, Win32 part.
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 *
 * Runs on Windows 95 RTM through NT 4.0: kernel32/user32/advapi32 imports
 * only (VERSION.DLL and the NT token functions are loaded at run time), no
 * C runtime (own entry point ua_start, built by tools/build_usosadd.py).
 * Behaviour: docs/design/legacy-compat-pack.md section 2.6.
 *
 *   USOSADD.EXE          run / resume the chain (started from HKLM Run after
 *                        the shell is up; never from RunOnce, which Windows 98
 *                        Setup processes while it is still finishing)
 *   USOSADD.EXE /dry     detect and log the plan only
 *   USOSADD.EXE /reset   forget the state (STATE.INI)
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include "ua.h"
#include "ndis_repair.h"
#include "../../../../tools/legacy_desktop_wait.h"

#define MANIFEST_CAP (256 * 1024)
#define SMALL_CAP (16 * 1024)

/* The large tables live in memory from VirtualAlloc: statics would be
 * written into the file (no C runtime to clear a BSS). */
#define VERBUF_CAP (64 * 1024)
#define SEEN_CAP 24
static struct big {
    char manifest[MANIFEST_CAP];
    char select[SMALL_CAP];
    char statebuf[SMALL_CAP];
    char stateout[SMALL_CAP];
    char appendbuf[SMALL_CAP];
    char verbuf[VERBUF_CAP];
    char seen[SEEN_CAP][96];     /* dialog titles logged for the running package */
    char runonce_last[UA_LINE];  /* RunOnce names last seen while it runs */
    ua_ini m, sel, st;
    ua_pkgs p;
    ua_plan plan;
    ua_state state;
    ua_choice choice;
} *g_big;
#define g_manifest (g_big->manifest)
#define g_select (g_big->select)
#define g_statebuf (g_big->statebuf)
#define g_stateout (g_big->stateout)
#define g_verbuf (g_big->verbuf)
#define g_m (g_big->m)
#define g_sel (g_big->sel)
#define g_st (g_big->st)
#define g_p (g_big->p)
#define g_plan (g_big->plan)
#define g_state (g_big->state)
#define g_choice (g_big->choice)
static ua_system g_sys;
static ua_facts g_facts;

static char g_root[UA_PATH];     /* folder of USOSADD.EXE */
static char g_log[UA_PATH];
static char g_win[UA_PATH], g_sysdir[UA_PATH], g_pf[UA_PATH];
static int g_pl;                 /* Polish messages */
static int g_setup_mode;         /* source950 ordinary RunOnce, before tray */
static HWND g_wnd, g_text;
static DWORD g_last_code;       /* exit code of the last command */
static int g_restart_asked;     /* a command of this package exited 3010 / 1641 */
static HWND g_guard;             /* /setup: hidden window that refuses installer restarts */
static const ua_pkg *g_guard_pkg; /* package whose commands run while the guard refuses */
static int g_restart_refused;    /* times this package's restart was refused */
static char g_deferred[UA_MAX_PKGS]; /* /setup: retried after one restart at the end of the chain */

/* ---- small helpers -------------------------------------------------------- */

/* ZeroMemory would call memset from the C library. */
static void zero(void *p, int n) { char *c = (char *)p; while (n-- > 0) *c++ = 0; }

static void path_join(char *out, const char *a, const char *b) {
    out[0] = 0;
    ua_append(out, UA_PATH, a);
    if (out[0] && out[ua_len(out) - 1] != '\\') ua_append(out, UA_PATH, "\\");
    ua_append(out, UA_PATH, b);
}

static int read_file(const char *path, char *buf, int cap) {
    HANDLE h = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ, 0, OPEN_EXISTING, 0, 0);
    DWORD got = 0;
    if (h == INVALID_HANDLE_VALUE) return -1;
    if (!ReadFile(h, buf, (DWORD)(cap - 1), &got, 0)) got = 0;
    CloseHandle(h);
    buf[got] = 0;
    return (int)got;
}

static int write_file(const char *path, const char *buf, int len) {
    HANDLE h = CreateFileA(path, GENERIC_WRITE, 0, 0, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    DWORD put = 0;
    if (h == INVALID_HANDLE_VALUE) return 0;
    WriteFile(h, buf, (DWORD)len, &put, 0);
    FlushFileBuffers(h);
    CloseHandle(h);
    return (int)put == len;
}

static int exists(const char *path) { return GetFileAttributesA(path) != (DWORD)-1; }

/* CPUID is optional on old CPUs. The ID-bit check precedes the instruction.
 * NT4's preparation VM must not install the pack before the hardware boot. */
static unsigned virtual_machine(void);
#pragma aux virtual_machine = \
    "pushfd" "pop eax" "mov edx,eax" "xor eax,200000h" \
    "push eax" "popfd" "pushfd" "pop eax" "push edx" "popfd" \
    "xor eax,edx" "and eax,200000h" "jz bare" \
    "mov eax,1" "db 0fh,0a2h" "test ecx,80000000h" "jnz guest" \
    "mov eax,40000000h" "db 0fh,0a2h" "cmp eax,40000000h" "jb bare" \
    "cmp eax,40010000h" "jae bare" \
    "guest:" "mov eax,1" "jmp done" \
    "bare:" "xor eax,eax" "done:" \
    value [eax] modify [ebx ecx edx];

static void make_dirs(const char *path) {
    char tmp[UA_PATH];
    int i;
    ua_copy(tmp, sizeof tmp, path);
    for (i = 3; tmp[i]; i++) {
        if (tmp[i] == '\\') { tmp[i] = 0; CreateDirectoryA(tmp, 0); tmp[i] = '\\'; }
    }
    CreateDirectoryA(tmp, 0);
}

static void log_line(const char *text) {
    char line[UA_LINE + 64];
    SYSTEMTIME t;
    HANDLE h;
    DWORD put;
    GetLocalTime(&t);
    wsprintfA(line, "%04d-%02d-%02d %02d:%02d:%02d ", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond);
    ua_append(line, sizeof line, text);
    ua_append(line, sizeof line, "\r\n");
    h = CreateFileA(g_log, GENERIC_WRITE, FILE_SHARE_READ, 0, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    if (h == INVALID_HANDLE_VALUE) return;
    SetFilePointer(h, 0, 0, FILE_END);
    WriteFile(h, line, (DWORD)ua_len(line), &put, 0);
    CloseHandle(h);
}

static void log2(const char *a, const char *b) {
    char line[UA_LINE];
    line[0] = 0;
    ua_append(line, sizeof line, a);
    ua_append(line, sizeof line, b);
    log_line(line);
}

/* ---- registry and file versions ------------------------------------------- */

static int reg_string(HKEY hive, const char *key, const char *value, char *out, int cap, DWORD *type) {
    HKEY k;
    DWORD size = (DWORD)cap - 1;
    LONG r;
    out[0] = 0;
    if (RegOpenKeyExA(hive, key, 0, KEY_READ, &k) != ERROR_SUCCESS) return 0;
    r = RegQueryValueExA(k, (value && *value) ? value : 0, 0, type, (LPBYTE)out, &size);
    RegCloseKey(k);
    if (r != ERROR_SUCCESS) return 0;
    out[size < (DWORD)cap ? size : (DWORD)cap - 1] = 0;
    return 1;
}

static int reg_key_exists(HKEY hive, const char *key) {
    HKEY k;
    if (RegOpenKeyExA(hive, key, 0, KEY_READ, &k) != ERROR_SUCCESS) return 0;
    RegCloseKey(k);
    return 1;
}

/* TCP/IP for requires=tcpip: an Enum\Network\MSTCP instance whose Driver
 * (NetTrans\NNNN) has its class key, or else an AF_INET stream socket
 * opens (WSOCK32, loaded only here). X470 95 OSR2.1 PL native (2026-10-27):
 * the first boot's PnP had left no MSTCP instance (an orphan NetTrans\0000
 * "TCP/IP" class key), socket() failed with 10047, and W95WS2 answered
 * "TCP NOT currently installed" in a box loop, then the retry restart. */
typedef int (WINAPI *PFN_WSASTART)(WORD, void *);
typedef unsigned int (WINAPI *PFN_SOCKET)(int, int, int);
typedef int (WINAPI *PFN_CLOSESOCK)(unsigned int);
typedef int (WINAPI *PFN_WSACLEAN)(void);
static int tcpip_present(char *how, int cap) {
    HKEY k;
    char name[64], drv[64], key[160];
    DWORD i, n, type;
    int found = 0;
    HMODULE w;
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, "Enum\\Network\\MSTCP", 0, KEY_READ, &k) == ERROR_SUCCESS) {
        for (i = 0; !found && i < 64; i++) {
            n = sizeof name;
            if (RegEnumKeyExA(k, i, name, &n, 0, 0, 0, 0) != ERROR_SUCCESS) break;
            ua_copy(key, sizeof key, "Enum\\Network\\MSTCP\\");
            ua_append(key, sizeof key, name);
            if (!reg_string(HKEY_LOCAL_MACHINE, key, "Driver", drv, sizeof drv, &type) || type != REG_SZ ||
                !ua_ieqn(drv, "NetTrans\\", 9)) continue;
            ua_copy(key, sizeof key, "System\\CurrentControlSet\\Services\\Class\\");
            ua_append(key, sizeof key, drv);
            if (reg_key_exists(HKEY_LOCAL_MACHINE, key)) {
                found = 1;
                ua_copy(how, cap, "Enum\\Network\\MSTCP\\");
                ua_append(how, cap, name);
                ua_append(how, cap, " -> ");
                ua_append(how, cap, drv);
            }
        }
        RegCloseKey(k);
    }
    if (found) return 1;
    w = LoadLibraryA("WSOCK32.DLL");
    if (w) {
        static DWORD data[128]; /* WSADATA (about 400 bytes) */
        PFN_WSASTART start = (PFN_WSASTART)GetProcAddress(w, "WSAStartup");
        PFN_SOCKET sock = (PFN_SOCKET)GetProcAddress(w, "socket");
        PFN_CLOSESOCK close = (PFN_CLOSESOCK)GetProcAddress(w, "closesocket");
        PFN_WSACLEAN clean = (PFN_WSACLEAN)GetProcAddress(w, "WSACleanup");
        if (start && sock && close && clean && start(0x0101, data) == 0) {
            unsigned int s = sock(2, 1, 6); /* AF_INET, SOCK_STREAM, IPPROTO_TCP */
            if (s != (unsigned int)~0U) { close(s); found = 1; ua_copy(how, cap, "AF_INET socket opened"); }
            clean();
        }
        FreeLibrary(w);
    }
    if (!found) ua_copy(how, cap, "no MSTCP instance with a NetTrans key, no AF_INET socket");
    return found;
}

typedef DWORD (WINAPI *PFN_VSIZE)(LPSTR, LPDWORD);
typedef BOOL (WINAPI *PFN_VINFO)(LPSTR, DWORD, DWORD, LPVOID);
typedef BOOL (WINAPI *PFN_VQUERY)(LPVOID, LPSTR, LPVOID *, PUINT);

/* File version as "a.b.c.d"; 0 when the file has none. */
static int file_version(const char *path, char *out, int cap) {
    static HMODULE ver;
    static PFN_VSIZE vsize;
    static PFN_VINFO vinfo;
    static PFN_VQUERY vquery;
    DWORD handle = 0, size;
    VS_FIXEDFILEINFO *fi;
    UINT len;
    out[0] = 0;
    if (!ver) {
        ver = LoadLibraryA("VERSION.DLL");
        if (!ver) return 0;
        vsize = (PFN_VSIZE)GetProcAddress(ver, "GetFileVersionInfoSizeA");
        vinfo = (PFN_VINFO)GetProcAddress(ver, "GetFileVersionInfoA");
        vquery = (PFN_VQUERY)GetProcAddress(ver, "VerQueryValueA");
    }
    if (!vsize || !vinfo || !vquery) return 0;
    size = vsize((LPSTR)path, &handle);
    if (size == 0 || size > sizeof g_verbuf) return 0;
    if (!vinfo((LPSTR)path, 0, size, g_verbuf)) return 0;
    if (!vquery(g_verbuf, "\\", (LPVOID *)&fi, &len) || len < sizeof *fi) return 0;
    wsprintfA(out, "%u.%u.%u.%u", (unsigned)HIWORD(fi->dwFileVersionMS), (unsigned)LOWORD(fi->dwFileVersionMS),
              (unsigned)HIWORD(fi->dwFileVersionLS), (unsigned)LOWORD(fi->dwFileVersionLS));
    (void)cap;
    return 1;
}

/* ---- detection -------------------------------------------------------------- */

static void detect(void) {
    OSVERSIONINFOA v;
    char path[UA_PATH], ver[64];
    int i;
    v.dwOSVersionInfoSize = sizeof v;
    GetVersionExA(&v);
    g_facts.nt = v.dwPlatformId == VER_PLATFORM_WIN32_NT;
    g_facts.major = (int)v.dwMajorVersion;
    g_facts.minor = (int)v.dwMinorVersion;
    g_facts.build = (int)(v.dwBuildNumber & 0xffff);
    ua_copy(g_facts.csd, sizeof g_facts.csd, v.szCSDVersion);
    g_facts.subver[0] = 0;
    if (!g_facts.nt)
        reg_string(HKEY_LOCAL_MACHINE, "Software\\Microsoft\\Windows\\CurrentVersion", "SubVersionNumber",
                   g_facts.subver, sizeof g_facts.subver, 0);
    g_facts.lang_id = GetSystemDefaultLangID();
    for (i = 0; i < 4; i++) g_facts.ntkern_ver[i] = 0;
    if (!g_facts.nt) {
        path_join(path, g_sysdir, "VMM32\\NTKERN.VXD");
        if (file_version(path, ver, sizeof ver)) {
            const char *s = ver;
            for (i = 0; i < 4; i++) {
                g_facts.ntkern_ver[i] = ua_atoi(s);
                while (*s && *s != '.') s++;
                if (*s) s++;
            }
        } else {
            /* Fallback: the USB supplement's USBD.SYS (to verify on OSR2.1). */
            path_join(path, g_win, "SYSTEM32\\DRIVERS\\USBD.SYS");
            if (exists(path)) { g_facts.ntkern_ver[0] = 4; g_facts.ntkern_ver[1] = 3; }
        }
    }
    g_facts.sp6a_hotfix = g_facts.nt &&
        reg_key_exists(HKEY_LOCAL_MACHINE, "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Hotfix\\Q246009");
    ua_detect(&g_facts, &g_sys);
}

/* ---- checks ----------------------------------------------------------------- */

static void vars_for(const ua_pkg *p, ua_vars *v) {
    v->root = g_root;
    v->win = g_win;
    v->sys = g_sysdir;
    v->pf = g_pf;
    v->dir = p->dir;
}

/* 1 = installed, 0 = not, -1 = no check */
static int run_check(const ua_pkg *p) {
    char expanded[UA_LINE], got[128];
    ua_vars v;
    ua_check c;
    DWORD type = 0;
    HKEY hive;
    if (!*p->check) return -1;
    vars_for(p, &v);
    ua_expand(&v, p->check, expanded, sizeof expanded);
    if (!ua_parse_check(expanded, &c)) { log2("  check not understood: ", p->check); return -1; }
    hive = c.hive ? HKEY_CURRENT_USER : HKEY_LOCAL_MACHINE;
    switch (c.kind) {
    case UA_CHK_FILE:
        if (!exists(c.path)) return 0;
        if (!c.min[0]) return 1;
        if (!file_version(c.path, got, sizeof got)) return 0;
        return ua_vercmp(got, c.min) >= 0;
    case UA_CHK_NTSP:
        return g_sys.ntsp[0] && ua_vercmp(g_sys.ntsp, c.min) >= 0;
    case UA_CHK_REG:
        if (!c.value[0]) return reg_key_exists(hive, c.path);
        return reg_string(hive, c.path, c.value, got, sizeof got, &type);
    case UA_CHK_REGVER:
        if (!reg_string(hive, c.path, c.value, got, sizeof got, &type) || type != REG_SZ) return 0;
        return ua_vercmp(got, c.min) >= 0;
    case UA_CHK_REGDW:
        if (!reg_string(hive, c.path, c.value, got, sizeof got, &type) || type != REG_DWORD) return 0;
        return (int)(*(DWORD *)got) >= ua_atoi(c.min);
    }
    return -1;
}

/* ---- window ----------------------------------------------------------------- */

/* The package line stays, its elapsed time below it is redrawn every
 * second by a WM_TIMER (dispatched by pump() in run_one's 250 ms wait), so
 * a package that runs for minutes (X470 98 FE PL: .NET 2.0, no sign of life,
 * the user took it for a hang) still shows that the box is alive. */
#define UA_TICK_TIMER 1
static char g_shown[UA_LINE];   /* package text without the elapsed line */
static DWORD g_pkg_start;       /* GetTickCount at the package start */
static int g_pkg_timing;        /* the elapsed line is shown */

static void elapsed_text(char *out, int cap, DWORD ms) {
    DWORD sec = ms / 1000;
    char num[16];
    ua_copy(out, cap, g_pl ? "Up\263yn\352\263o: " : "Elapsed: ");
    ua_itoa(num, sizeof num, (int)(sec / 60));
    ua_append(out, cap, num);
    ua_append(out, cap, (sec % 60) < 10 ? ":0" : ":");
    ua_itoa(num, sizeof num, (int)(sec % 60));
    ua_append(out, cap, num);
}

static void status_draw(void) {
    char text[UA_LINE + 64], line[48];
    ua_copy(text, sizeof text, g_shown);
    if (g_pkg_timing) {
        elapsed_text(line, sizeof line, GetTickCount() - g_pkg_start);
        ua_append(text, sizeof text, "\r\n");
        ua_append(text, sizeof text, line);
    }
    if (g_text) SetWindowTextA(g_text, text);
}

static LRESULT CALLBACK wnd_proc(HWND w, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_CLOSE) return 0; /* not closable while installing */
    if (msg == WM_TIMER && wp == UA_TICK_TIMER) { if (g_pkg_timing) status_draw(); return 0; }
    return DefWindowProcA(w, msg, wp, lp);
}

static void pump(void) {
    MSG msg;
    while (PeekMessageA(&msg, 0, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }
}

static void window_open(void) {
    WNDCLASSA wc;
    HINSTANCE inst = GetModuleHandleA(0);
    int w = 520, h = 130;   /* header, package, slow note, elapsed time */
    zero(&wc, sizeof wc);
    wc.lpfnWndProc = wnd_proc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursorA(0, (LPCSTR)IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
    wc.lpszClassName = "USOSADD";
    RegisterClassA(&wc);
    /* Not topmost and not centred: package installers' own questions must
     * stay visible (QEMU 2026-10-03: DUN 1.4 dialogs were hidden). */
    g_wnd = CreateWindowExA(0, "USOSADD", "USOS", WS_POPUP | WS_CAPTION | WS_VISIBLE,
                            8, 8, w, h, 0, 0, inst, 0);
    g_text = CreateWindowExA(0, "STATIC", "", WS_CHILD | WS_VISIBLE | SS_LEFT, 12, 12, w - 30, h - 45,
                             g_wnd, 0, inst, 0);
    pump();
}

/* /setup (the 95 / 98 first-desktop coordinator USOSFB): a hidden
 * top-level window answers WM_QUERYENDSESSION with FALSE while a package's
 * commands run, so an installer cannot restart the PC in the middle of the
 * chain; USOSADD and USOSFB decide the restarts. X470 98 FE PL 2026-10-27:
 * WMP 7.1's setup_wm restarted Windows itself although its IExpress outer
 * had /R:N (STATE.INI wmp71-pl=running:1; USOSFB's own final restart was
 * then rejected). On 9x one FALSE cancels ExitWindowsEx of any process;
 * EWX_FORCE (no WM_QUERYENDSESSION) cannot be refused, and that case is
 * left to the resume of the package still "running". A refused restart is
 * a restart the package asked for (batched). Our own restart paths take
 * the guard down first (guard_off). */
static LRESULT CALLBACK guard_proc(HWND w, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_QUERYENDSESSION) {
        if (!g_guard_pkg) return TRUE;
        if (g_restart_refused++ < 3) log2("    installer restart refused: ", g_guard_pkg->id);
        return FALSE;
    }
    if (msg == WM_ENDSESSION && wp && g_guard_pkg)
        log2("    session ends while the package runs (restart not refusable); it resumes as running: ", g_guard_pkg->id);
    return DefWindowProcA(w, msg, wp, lp);
}

static void guard_open(void) {
    WNDCLASSA wc;
    HINSTANCE inst = GetModuleHandleA(0);
    zero(&wc, sizeof wc);
    wc.lpfnWndProc = guard_proc;
    wc.hInstance = inst;
    wc.lpszClassName = "USOSADDGuard";
    RegisterClassA(&wc);
    g_guard = CreateWindowExA(0, "USOSADDGuard", "USOSADD restart guard", WS_POPUP, 0, 0, 0, 0, 0, 0, inst, 0);
    log_line(g_guard ? "USOSADD setup: restart guard on (installer restarts refused while a package runs)"
                     : "USOSADD setup: restart guard window not created");
}

static void guard_off(void) {
    g_guard_pkg = 0;
    if (g_guard) { DestroyWindow(g_guard); g_guard = 0; pump(); }
}

static void timing_off(void) {
    if (g_pkg_timing && g_wnd) KillTimer(g_wnd, UA_TICK_TIMER);
    g_pkg_timing = 0;
}

static void status(const char *text) {
    timing_off();
    ua_copy(g_shown, sizeof g_shown, text);
    status_draw();
    pump();
}

/* A package starts: its text, the elapsed time from now (every second). */
static void status_package(const char *text) {
    ua_copy(g_shown, sizeof g_shown, text);
    g_pkg_start = GetTickCount();
    g_pkg_timing = g_wnd && SetTimer(g_wnd, UA_TICK_TIMER, 1000, 0);
    status_draw();
    pump();
}

/* ---- running commands --------------------------------------------------------- */

/* ---- answering installer questions ------------------------------------------ */

/* Rules "title|action" from [pack] answerN and the running package's
 * answerN: a visible top-level dialog (class #32770) whose title starts with
 * <title> gets <action>: a button ID (7 = No, 6 = Yes, 1 = OK, 2 = Cancel) is
 * pressed; "source" types the Windows source folder (HKLM ...\Setup
 * SourcePath) into the dialog's edit/combo field and presses OK (the
 * "Kopiowanie plikow / Copying Files" prompt for a file from the CD). */
static const ua_pkg *g_answer_pkg;
static char g_source[UA_PATH];
static int g_seen_n;             /* titles in g_big->seen, reset per package */
static HWND g_answered;          /* last dialog answered, and when */
static DWORD g_answered_tick;

/* Diagnostics: each new dialog title once per package ("dialog seen"). */
static void note_dialog(const char *title) {
    int i;
    for (i = 0; i < g_seen_n; i++) if (ua_ieq(g_big->seen[i], title)) return;
    if (g_seen_n < SEEN_CAP) ua_copy(g_big->seen[g_seen_n++], sizeof g_big->seen[0], title);
    log2("    dialog seen: ", title);
}

static int rule_for(const char *title, char *action, int cap) {
    char key[16], num[8], rule[200];
    const char *sections[2], *v;
    int s, k;
    sections[0] = "pack";
    sections[1] = g_answer_pkg ? g_answer_pkg->section : 0;
    for (s = 1; s >= 0; s--) {
        if (!sections[s]) continue;
        for (k = 1; k < 32; k++) {
            int i;
            key[0] = 0;
            ua_append(key, sizeof key, "answer");
            ua_itoa(num, sizeof num, k);
            ua_append(key, sizeof key, num);
            v = ua_ini_get(&g_m, sections[s], key);
            if (!v) break;
            ua_copy(rule, sizeof rule, v);
            for (i = 0; rule[i] && rule[i] != '|'; i++) ;
            if (!rule[i]) continue;
            rule[i] = 0;
            if (ua_ieqn(title, rule, ua_len(rule))) { ua_copy(action, cap, rule + i + 1); return 1; }
        }
    }
    return 0;
}

static BOOL CALLBACK find_field(HWND w, LPARAM lp) {
    char cls[32];
    GetClassNameA(w, cls, sizeof cls);
    if ((ua_ieq(cls, "Edit") || ua_ieq(cls, "ComboBox")) && IsWindowVisible(w)) { *(HWND *)lp = w; return FALSE; }
    return TRUE;
}

static BOOL CALLBACK answer_window(HWND w, LPARAM lp) {
    char cls[16], title[128], action[64];
    (void)lp;
    if (!IsWindowVisible(w) || w == g_wnd) return TRUE;
    GetClassNameA(w, cls, sizeof cls);
    if (!ua_ieq(cls, "#32770")) return TRUE;
    GetWindowTextA(w, title, sizeof title);
    if (!title[0]) return TRUE;
    note_dialog(title);
    if (!rule_for(title, action, sizeof action)) return TRUE;
    /* The posted command closes the box; a box still visible on the next
     * 250 ms poll gets the same answer again only after a second. */
    if (w == g_answered && GetTickCount() - g_answered_tick < 1000) return TRUE;
    g_answered = w;
    g_answered_tick = GetTickCount();
    if (ua_ieq(action, "source")) {
        HWND field = 0;
        EnumChildWindows(w, find_field, (LPARAM)&field);
        if (!field || !g_source[0]) return TRUE; /* e.g. the progress window of the same title */
        SendMessageA(field, WM_SETTEXT, 0, (LPARAM)g_source);
        log2("    answered (source folder): ", title);
        PostMessageA(w, WM_COMMAND, IDOK, 0);
    } else {
        int id = ua_atoi(action);
        if (id <= 0) return TRUE;
        log2("    answered: ", title);
        PostMessageA(w, WM_COMMAND, (WPARAM)id, 0);
    }
    return TRUE;
}

#define RUN_KEY "Software\\Microsoft\\Windows\\CurrentVersion\\Run"
#define RUNONCE_KEY "Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce"

/* HKLM RunOnce value names and the number of RunOnceEx sections (IE's
 * registrations wait there for iernonce), after <prefix>. */
static void runonce_line(char *line, int cap, const char *prefix) {
    char name[128];
    HKEY k;
    DWORD i = 0, n, keys = 0;
    line[0] = 0;
    ua_append(line, cap, prefix);
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, RUNONCE_KEY, 0, KEY_READ, &k) == ERROR_SUCCESS) {
        for (i = 0; i < 64; i++) {
            n = sizeof name;
            if (RegEnumValueA(k, i, name, &n, 0, 0, 0, 0) != ERROR_SUCCESS) break;
            ua_append(line, cap, i ? ", " : " ");
            ua_append(line, cap, name[0] ? name : "(default)");
        }
        if (!i) ua_append(line, cap, " -");
        RegCloseKey(k);
    } else {
        ua_append(line, cap, " (no key)");
    }
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, RUNONCE_KEY "Ex", 0, KEY_READ, &k) == ERROR_SUCCESS) {
        if (RegQueryInfoKeyA(k, 0, 0, 0, &keys, 0, 0, 0, 0, 0, 0, 0) != ERROR_SUCCESS) keys = 0;
        RegCloseKey(k);
    }
    ua_append(line, cap, "; RunOnceEx sections: ");
    ua_itoa(name, 16, (int)keys);
    ua_append(line, cap, name);
}

/* Diagnostics while a package runs, log only (X470 95 RTM, 2026-10-27: IE
 * 5.5's install showed a RUNDLL error box for IEDKCS32.DLL,
 * BrandCleanInstallStubs while its replacements were pending): every 2 s the RunOnce list is compared with the last one seen
 * and logged when it changed, with the tick count. */
static void runonce_watch(int start) {
    char line[UA_LINE], num[16];
    runonce_line(line, sizeof line, "");
    if (start) { ua_copy(g_big->runonce_last, sizeof g_big->runonce_last, line); return; }
    if (ua_ieq(line, g_big->runonce_last)) return;
    ua_copy(g_big->runonce_last, sizeof g_big->runonce_last, line);
    ua_itoa(num, sizeof num, (int)GetTickCount());
    ua_copy(line, sizeof line, "    RunOnce now (tick ");
    ua_append(line, sizeof line, num);
    ua_append(line, sizeof line, "):");
    ua_append(line, sizeof line, g_big->runonce_last);
    log_line(line);
}

static DWORD spawn(char *cmdline, const char *cwd) {
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    DWORD code = (DWORD)-1;
    zero(&si, sizeof si);
    si.cb = sizeof si;
    if (!CreateProcessA(0, cmdline, 0, 0, FALSE, 0, 0, (cwd && *cwd) ? cwd : 0, &si, &pi)) {
        char num[16];
        ua_itoa(num, sizeof num, (int)GetLastError());
        log2("    CreateProcess failed, error ", num);
        return (DWORD)-1;
    }
    /* Poll the dialogs on every wake-up, at most every 250 ms: a quiet
     * second never came while a busy installer kept posting messages, so
     * the final "Winsock2 Setup" box stayed open (X470 95 RTM, 2026-10-26). */
    {
        DWORD last = GetTickCount() - 250, watched = GetTickCount();
        for (;;) {
            DWORD r = MsgWaitForMultipleObjects(1, &pi.hProcess, FALSE, 250, QS_ALLINPUT);
            if (r == WAIT_OBJECT_0) break;
            pump();
            if (GetTickCount() - last >= 250) {
                last = GetTickCount();
                EnumWindows(answer_window, 0);
            }
            if (g_answer_pkg && GetTickCount() - watched >= 2000) {
                watched = GetTickCount();
                runonce_watch(0);
            }
        }
    }
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return code;
}

static int code_ok(const ua_pkg *p, DWORD code) {
    const char *codes = ua_ini_get(&g_m, p->section, "codes");
    char num[16];
    ua_itoa(num, sizeof num, (int)code);
    if (!codes || !*codes) return code == 0 || code == 3010 || code == 1641;
    return ua_list_has(codes, num);
}

static int builtin_copy(const char *src, const char *dst, int force) {
    char vs[64], vd[64];
    if (!exists(src)) { log2("    missing: ", src); return 0; }
    if (!force && exists(dst)) {
        if (!(file_version(src, vs, sizeof vs) && file_version(dst, vd, sizeof vd) && ua_vercmp(vs, vd) > 0)) {
            log2("    kept (same or newer): ", dst);
            return 1;
        }
    }
    SetFileAttributesA(dst, FILE_ATTRIBUTE_NORMAL);
    if (!CopyFileA(src, dst, FALSE)) { log2("    copy failed: ", dst); return 0; }
    log2("    copied: ", dst);
    return 1;
}

static int builtin_append(const char *file, const char *text) {
    char *buf = g_big->appendbuf;
    int n = read_file(file, buf, SMALL_CAP), i, len = ua_len(text);
    HANDLE h;
    DWORD put;
    if (n < 0) n = 0;
    for (i = 0; i + len <= n; i++) {
        if (ua_ieqn(buf + i, text, len) && (i == 0 || buf[i - 1] == '\n') &&
            (i + len == n || buf[i + len] == '\r' || buf[i + len] == '\n')) {
            log2("    already in the file: ", text);
            return 1;
        }
    }
    h = CreateFileA(file, GENERIC_WRITE, 0, 0, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    if (h == INVALID_HANDLE_VALUE) return 0;
    SetFilePointer(h, 0, 0, FILE_END);
    if (n > 0 && buf[n - 1] != '\n') WriteFile(h, "\r\n", 2, &put, 0);
    WriteFile(h, text, (DWORD)len, &put, 0);
    WriteFile(h, "\r\n", 2, &put, 0);
    CloseHandle(h);
    log2("    appended: ", text);
    return 1;
}

static int run_one(const ua_pkg *p, const char *raw) {
    char line[UA_LINE], cmd[UA_LINE + 200], num[16];
    ua_vars v;
    ua_cmd c;
    DWORD code;
    vars_for(p, &v);
    ua_expand(&v, raw, line, sizeof line);
    ua_parse_cmd(line, &c);
    log2("  > ", line);
    switch (c.kind) {
    case UA_CMD_COPY: return builtin_copy(c.a, c.b, 0);
    case UA_CMD_FORCE: return builtin_copy(c.a, c.b, 1);
    case UA_CMD_ATTRIB: return SetFileAttributesA(c.a, FILE_ATTRIBUTE_NORMAL) != 0;
    case UA_CMD_APPEND: return builtin_append(c.a, c.b);
    case UA_CMD_INF:
        cmd[0] = 0;
        ua_append(cmd, sizeof cmd, g_facts.nt ? "rundll32.exe setupapi.dll,InstallHinfSection " : "rundll.exe setupx.dll,InstallHinfSection ");
        ua_append(cmd, sizeof cmd, c.b);
        ua_append(cmd, sizeof cmd, " 128 ");
        ua_append(cmd, sizeof cmd, c.a);
        code = spawn(cmd, 0);
        break;
    case UA_CMD_MSI:
        cmd[0] = 0;
        ua_append(cmd, sizeof cmd, "msiexec.exe /i \"");
        ua_append(cmd, sizeof cmd, c.a);
        ua_append(cmd, sizeof cmd, "\" /qn ");
        ua_append(cmd, sizeof cmd, c.b);
        code = spawn(cmd, 0);
        break;
    case UA_CMD_CD:
        ua_copy(cmd, sizeof cmd, c.b);
        code = spawn(cmd, c.a);
        break;
    default:
        ua_copy(cmd, sizeof cmd, c.b);
        code = spawn(cmd, 0);
        break;
    }
    ua_itoa(num, sizeof num, (int)code);
    log2("    exit code ", num);
    g_last_code = ua_command_exit(cmd, code);
    if(g_last_code!=code) {
        log_line("    DXSETUP success with restart: exit 1 treated as 3010");
        g_state.pending_reboot=1;
    }
    if (g_last_code == 3010 || g_last_code == 1641) g_restart_asked = 1;
    return code_ok(p, g_last_code);
}

/* ---- state, restart ------------------------------------------------------------ */

static void save_state(void) {
    char path[UA_PATH];
    int n = ua_state_write(&g_state, &g_p, g_stateout, sizeof g_stateout);
    path_join(path, g_root, "STATE.INI");
    write_file(path, g_stateout, n);
}

static void set_state(int i, int st) {
    g_state.st[i] = st;
    save_state();
    log2("  -> ", ua_state_name(st));
}

/* failed / skipped with the reason shown in the final summary */
static void set_why(int i, int st, const char *why, const char *detail) {
    g_state.why[i][0] = 0;
    ua_append(g_state.why[i], sizeof g_state.why[i], why);
    if (detail && *detail) ua_append(g_state.why[i], sizeof g_state.why[i], detail);
    log2("  reason: ", g_state.why[i]);
    set_state(i, st);
}

/* HKLM Run "USOSAddons" = this program, until the chain is finished. Run
 * (not RunOnce): Run entries start after the shell, and RunOnce entries of
 * the first boot run inside Windows 98 Setup's last phase, where a restart
 * breaks Setup (QEMU run 2026-10-03). */
static void register_run(void) {
    HKEY k;
    char exe[UA_PATH + 4];
    exe[0] = 0;
    ua_append(exe, sizeof exe, "\"");
    path_join(exe + 1, g_root, "USOSADD.EXE");
    ua_append(exe, sizeof exe, "\"");
    if (RegCreateKeyExA(HKEY_LOCAL_MACHINE, RUN_KEY, 0, 0, 0, KEY_WRITE, 0, &k, 0) == ERROR_SUCCESS) {
        RegSetValueExA(k, "USOSAddons", 0, REG_SZ, (const BYTE *)exe, (DWORD)ua_len(exe) + 1);
        RegCloseKey(k);
    }
}

static void unregister(void) {
    HKEY k;
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, RUN_KEY, 0, KEY_WRITE, &k) == ERROR_SUCCESS) {
        RegDeleteValueA(k, "USOSAddons");
        RegCloseKey(k);
    }
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, RUNONCE_KEY, 0, KEY_WRITE, &k) == ERROR_SUCCESS) {
        RegDeleteValueA(k, "USOSAddons");
        RegCloseKey(k);
    }
}

/* USOSFB's builds: 4.00 950 (RTM / OSR1) and the OSR2 family (1111,
 * 1212..1216); 4.10 98 FE (1998) and 98 SE (2222). */
static int coordinated_build(int minor, int build) {
    build &= 0xffff;
    if (minor == 0) return build == 950 || build == 1111 || build == 1212 || build == 1214 || build == 1216;
    return minor == 10 && (build == 1998 || build == 2222);
}

/* The display boundary USOSFB waits for (usosfb.c display_ready): 950's
 * VESALATE.BAT binding, or on OSR2 (no VESALATE) VESA95.BAT's one attempt;
 * 98 stages neither (open boundary). */
static int display_boundary(void) {
    if (exists("C:\\USOS9X\\VESALATE.BAT")) return exists("C:\\USOS9X\\VLATE.OK");
    return exists("C:\\USOS9X\\VESA95.OK") || exists("C:\\USOS9X\\VESA95.BAD") || !exists("C:\\USOS9X\\VESA95.BAT");
}

/* Windows Setup still finishing: its RunOnce\Setup list is not empty, or
 * there is no taskbar yet. */
static int setup_busy(void) {
    HKEY k;
    DWORD values = 0;
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, RUNONCE_KEY "\\Setup", 0, KEY_READ, &k) == ERROR_SUCCESS) {
        if (RegQueryInfoKeyA(k, 0, 0, 0, 0, 0, 0, &values, 0, 0, 0, 0) != ERROR_SUCCESS) values = g_setup_mode ? 1 : 0;
        RegCloseKey(k);
        if (values) return 1;
    }
    return !g_setup_mode && FindWindowA("Shell_TrayWnd", 0) == 0;
}

/* Wait for first-session readiness notifications, with a fixed deadline. */
static int addons_desktop_ready(void) { return !setup_busy(); }
static int wait_for_desktop(void) {
    if(!addons_desktop_ready())log_line("USOSADD: waiting for desktop/Setup notifications; bounded, no polling");
    return usos_wait_desktop(addons_desktop_ready,300000);
}

/* IE/DUN installers may reset browser settings. Reuse the network task's
 * helper and its existing config, only when that component was staged. */
static void lan_defaults(int launch) {
    HKEY k;
    const char *exe = g_facts.nt ? "C:\\USOS\\NT4\\USOSLAN.EXE" : "C:\\USOS9X\\USOSLAN.EXE";
    if (!exists(exe)) return;
    if (RegCreateKeyExA(HKEY_LOCAL_MACHINE, RUN_KEY, 0, 0, 0, KEY_WRITE, 0, &k, 0) == ERROR_SUCCESS) {
        RegSetValueExA(k, "USOSLan", 0, REG_SZ, (const BYTE *)exe, (DWORD)ua_len(exe) + 1);
        RegCloseKey(k);
    }
    log_line("  LAN defaults scheduled after compatibility installers");
    if (launch) {
        char command[UA_PATH]; STARTUPINFOA si; PROCESS_INFORMATION pi;
        zero(&si, sizeof si); zero(&pi, sizeof pi); si.cb = sizeof si;
        ua_copy(command, sizeof command, exe);
        ua_append(command, sizeof command, " /refresh");
        if (CreateProcessA(exe, command, 0, 0, FALSE, 0, 0, 0, &si, &pi)) {
            CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
        }
    }
}

typedef BOOL (WINAPI *PFN_OPT)(HANDLE, DWORD, PHANDLE);
typedef BOOL (WINAPI *PFN_LPV)(LPCSTR, LPCSTR, PLUID);
typedef BOOL (WINAPI *PFN_ATP)(HANDLE, BOOL, PTOKEN_PRIVILEGES, DWORD, PTOKEN_PRIVILEGES, PDWORD);

/* Windows 9x: after network components (DUN 1.4) Windows asks for a
 * user name and password at every start, which stops an unattended chain.
 * USOS logs the installing user on automatically (the Winlogon values that
 * TweakUI uses on 9x; empty password, as USOS installs the system without
 * one); kept after the chain so the system starts straight to the desktop. */
static void auto_logon(void) {
    HKEY k;
    char user[64];
    DWORD n = sizeof user;
    if (g_facts.nt) return;
    if (!GetUserNameA(user, &n) || !user[0]) ua_copy(user, sizeof user, "USOS");
    if (RegCreateKeyExA(HKEY_LOCAL_MACHINE, "Software\\Microsoft\\Windows\\CurrentVersion\\Winlogon", 0, 0, 0,
                        KEY_WRITE, 0, &k, 0) != ERROR_SUCCESS)
        return;
    RegSetValueExA(k, "DefaultUserName", 0, REG_SZ, (const BYTE *)user, (DWORD)ua_len(user) + 1);
    RegSetValueExA(k, "DefaultPassword", 0, REG_SZ, (const BYTE *)"", 1);
    RegSetValueExA(k, "AutoAdminLogon", 0, REG_SZ, (const BYTE *)"1", 2);
    RegCloseKey(k);
}

static void repair_ndis_before_restart(void) {
    int result;
    if(!ua_ndis_repair_needed(&g_p,&g_plan,&g_state,&g_sys))return;
    result=ua_ndis_repair(g_win,g_sysdir,g_root,log_line);
    if(!result)ExitProcess(2); /* coordinator holds before its final restart */
    if(result==2){g_state.pending_reboot=1;save_state();}
}

static void restart(void) {
    guard_off();
    repair_ndis_before_restart();
    g_state.pending_reboot = 1;
    save_state();
    if (g_setup_mode) {
        log_line("USOSADD setup: package needs a restart before the chain can finish; caller owns restart");
        ExitProcess(1001);
    }
    register_run();
    lan_defaults(0);
    auto_logon();
    log_line(g_pl ? "Ponowne uruchomienie komputera" : "Restarting the computer");
    status(g_pl ? "Ponowne uruchomienie komputera..." : "Restarting the computer...");
    if (g_facts.nt) {
        HMODULE adv = LoadLibraryA("ADVAPI32.DLL");
        PFN_OPT opt = adv ? (PFN_OPT)GetProcAddress(adv, "OpenProcessToken") : 0;
        PFN_LPV lpv = adv ? (PFN_LPV)GetProcAddress(adv, "LookupPrivilegeValueA") : 0;
        PFN_ATP atp = adv ? (PFN_ATP)GetProcAddress(adv, "AdjustTokenPrivileges") : 0;
        HANDLE tok;
        TOKEN_PRIVILEGES tp;
        if (opt && lpv && atp && opt(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &tok)) {
            lpv(0, "SeShutdownPrivilege", &tp.Privileges[0].Luid);
            tp.PrivilegeCount = 1;
            tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
            atp(tok, FALSE, &tp, 0, 0, 0);
            CloseHandle(tok);
        }
    }
    if (!ExitWindowsEx(EWX_REBOOT | EWX_FORCE, 0)) log_line("ExitWindowsEx failed");
    ExitProcess(0);
}

/* ---- the chain ------------------------------------------------------------------- */

/* Diagnostics after each package: HKLM RunOnce value names and the number
 * of RunOnceEx sections (IE's registrations wait there for iernonce). */
static void log_runonce(void) {
    char line[UA_LINE];
    runonce_line(line, sizeof line, "  RunOnce:");
    log_line(line);
}

/* "not planned" reason for a package that does not fit: the language
 * when only that differs (95 OSR1 EN, X470 2026-10-27: the PL IE / DX
 * packages read "not for this system"). */
static void system_reason(char *line, int cap, const ua_pkg *p) {
    if (ua_os_match(&g_m, p->os, g_sys.os) && !ua_ieq(p->lang, "*") && !ua_ieq(p->lang, g_sys.lang)) {
        ua_append(line, cap, " (language ");
        ua_append(line, cap, p->lang);
        ua_append(line, cap, ", system ");
        ua_append(line, cap, g_sys.lang);
        ua_append(line, cap, ")");
    } else {
        ua_append(line, cap, " (not for this system)");
    }
}

/* Selectable only (tier=option, or option_os= for this system), fitting
 * this system, not selected: logged so a missing package is explained. */
static int option_only(const ua_pkg *p) {
    if (!ua_applicable(&g_m, p, &g_sys, g_sys.ntsp)) return 0;
    if (p->tier == UA_TIER_OPTION) return 1;
    return (p->tier == UA_TIER_FULL || p->tier == UA_TIER_GROUP) &&
           ua_os_match(&g_m, ua_ini_get(&g_m, p->section, "option_os"), g_sys.os);
}

static void log_plan(void) {
    char line[UA_LINE];
    int i;
    for (i = 0; i < g_plan.count; i++) {
        const ua_pkg *p = &g_p.pkg[g_plan.idx[i]];
        line[0] = 0;
        ua_append(line, sizeof line, "  plan: ");
        ua_append(line, sizeof line, p->id);
        log_line(line);
    }
    for (i = 0; i < g_p.count; i++) {
        int w = g_plan.why[i];
        if (w == 0 && option_only(&g_p.pkg[i])) {
            line[0] = 0;
            ua_append(line, sizeof line, "  not planned: ");
            ua_append(line, sizeof line, g_p.pkg[i].id);
            ua_append(line, sizeof line, " (option, not selected)");
            log_line(line);
            continue;
        }
        if (w < UA_OUT_SYSTEM) continue;
        line[0] = 0;
        ua_append(line, sizeof line, "  not planned: ");
        ua_append(line, sizeof line, g_p.pkg[i].id);
        if (w == UA_OUT_SYSTEM) system_reason(line, sizeof line, &g_p.pkg[i]);
        else ua_append(line, sizeof line, w == UA_OUT_STATUS ? " (status: " : " (needs ");
        if (w == UA_OUT_STATUS) { ua_append(line, sizeof line, g_p.pkg[i].status); ua_append(line, sizeof line, ")"); }
        if (w == UA_OUT_NEEDS) { ua_append(line, sizeof line, g_plan.unmet[i]); ua_append(line, sizeof line, ")"); }
        log_line(line);
    }
}

static int files_present(const ua_pkg *p) {
    char key[16], path[UA_PATH], dir[UA_PATH], name[16], num[4];
    int k;
    const char *v;
    v = ua_ini_get(&g_m, p->section, "unpack");
    if (v && *v) { /* zip / iso: staged as a folder of files */
        path_join(dir, g_root, "PKG");
        path_join(path, dir, p->dir);
        return exists(path);
    }
    for (k = 1; k < 32; k++) {
        int i = 0;
        key[0] = 0;
        ua_append(key, sizeof key, "file");
        ua_itoa(num, sizeof num, k);
        ua_append(key, sizeof key, num);
        v = ua_ini_get(&g_m, p->section, key);
        if (!v) break;
        while (v[i] && v[i] != '|' && i < 15) { name[i] = v[i]; i++; }
        name[i] = 0;
        path_join(dir, g_root, "PKG");
        path_join(path, dir, p->dir);
        path_join(dir, path, name);
        if (!exists(dir)) { log2("    missing file: ", dir); return 0; }
    }
    return 1;
}

static void run_chain(void) {
    char line[UA_LINE], num[16], unmet[48], key[12], tmpdir[UA_PATH], dir[UA_PATH];
    const char *name_key = g_pl ? "name_pl" : "name_en";
    int pos;
    for (pos = 0; pos < g_plan.count; pos++) {
        int x = g_plan.idx[pos], ok, k, check, after, reboot;
        const ua_pkg *p = &g_p.pkg[x];
        const char *name = ua_ini_get(&g_m, p->section, name_key);
        int st = g_state.st[x];
        if (st == UA_ST_DONE || st == UA_ST_PRESENT || st == UA_ST_FAILED || st == UA_ST_SKIPPED || st == UA_ST_MISSING) continue;
        if (!name) name = p->id;
        if (p->tier == UA_TIER_GROUP) {
            set_state(x, ua_needs_met(&g_m, &g_p, &g_state, &g_sys, x, unmet, sizeof unmet) ? UA_ST_DONE
                         : ua_missing_provides(&g_p, &g_state, unmet) ? UA_ST_MISSING : UA_ST_SKIPPED);
            continue;
        }
        log2("Package ", p->id);
        check = run_check(p);
        if (st == UA_ST_RUNNING) {
            int d = ua_resume_decision(g_state.tries[x], check >= 0, check == 1);
            ua_itoa(num, sizeof num, g_state.tries[x]);
            log2(d == 1 ? "  left running (a restart inside the package, or a retry after one): check passes, tries "
                 : d == 2 ? "  left running (a restart inside the package, or a retry after one): not installed, runs again, tries "
                          : "  left running twice, not installed, tries ", num);
            if (d == 1) { set_state(x, UA_ST_DONE); continue; }
            if (d == 3) { set_why(x, UA_ST_FAILED, g_pl ? "przerwana dwa razy" : "interrupted twice", 0); continue; }
        } else if (check == 1) {
            log_line("  already installed");
            set_state(x, UA_ST_PRESENT);
            continue;
        }
        if (*p->status) { set_why(x, UA_ST_SKIPPED, "status: ", p->status); continue; }
        if (!ua_needs_met(&g_m, &g_p, &g_state, &g_sys, x, unmet, sizeof unmet)) {
            if (ua_deferred_provides(&g_p, g_deferred, unmet)) {
                log2("  needs a package retried after the restart; runs after it: ", unmet);
                continue;
            }
            /* its provider's files are not on the media: left out the same
             * way, not a failure (the first desktop does not wait for it) */
            if (ua_missing_provides(&g_p, &g_state, unmet)) {
                set_why(x, UA_ST_MISSING, g_pl ? "wymaga (brak plik\363w): " : "needs (files missing): ", unmet);
                continue;
            }
            set_why(x, UA_ST_SKIPPED, g_pl ? "wymaga " : "needs ", unmet);
            continue;
        }
        if (*p->requires) {
            char how[160];
            const char *missing = ua_requires_missing(p, tcpip_present(how, sizeof how), unmet, sizeof unmet);
            log2("  requires: ", p->requires);
            log2("  TCP/IP: ", how);
            if (missing) {
                /* No dialog, no retry restart: the installer would only fail. */
                if (ua_ieq(missing, "tcpip")) set_why(x, UA_ST_SKIPPED, g_pl ? "TCP/IP nie jest zainstalowany" : "TCP/IP not installed", 0);
                else set_why(x, UA_ST_SKIPPED, g_pl ? "wymaga " : "requires ", missing);
                continue;
            }
        }
        /* Files not on the media (not staged, e.g. hotfixes absent from
         * DATA\Addons): skipped-missing, logged, never a failure. */
        if (!files_present(p)) { set_why(x, UA_ST_MISSING, g_pl ? "brak pliku" : "file missing", 0); continue; }
        /* No restart here merely because one is pending: restarts are batched
         * into the final one (95 RTM: install -> one restart -> desktop);
         * ua_after_run retries a package once after a restart when the
         * pending one was in its way. */
        line[0] = 0;
        ua_append(line, sizeof line, g_pl ? "USOS: instalowanie dodatk\363w (" : "USOS: installing add-ons (");
        ua_itoa(num, sizeof num, pos + 1);
        ua_append(line, sizeof line, num);
        ua_append(line, sizeof line, "/");
        ua_itoa(num, sizeof num, g_plan.count);
        ua_append(line, sizeof line, num);
        ua_append(line, sizeof line, "):\r\n");
        ua_append(line, sizeof line, name);
        /* slow=1 in legacy-pack.ini: known to take minutes (.NET, DirectX 9.0c, MDAC, IE 6 SP1) */
        if (ua_ini_get(&g_m, p->section, "slow") && ua_ieq(ua_ini_get(&g_m, p->section, "slow"), "1"))
            ua_append(line, sizeof line, g_pl ? "\r\nTo mo\277e potrwa\346 kilka minut." : "\r\nThis may take several minutes.");
        status_package(line);
        path_join(dir, g_root, "TMP");
        path_join(tmpdir, dir, p->dir);
        make_dirs(tmpdir);
        g_state.tries[x]++;
        set_state(x, UA_ST_RUNNING);
        ok = 1;
        g_last_code = 0;
        g_restart_asked = 0;
        g_restart_refused = 0;
        if (g_setup_mode) g_guard_pkg = p;
        g_answer_pkg = p;
        g_seen_n = 0;
        g_answered = 0;
        runonce_watch(1);
        for (k = 1; ok && k < 64; k++) {
            const char *cmd;
            key[0] = 0;
            ua_append(key, sizeof key, "run");
            ua_itoa(num, sizeof num, k);
            ua_append(key, sizeof key, num);
            cmd = ua_ini_get(&g_m, p->section, key);
            if (!cmd) break;
            ok = run_one(p, cmd);
        }
        g_answer_pkg = 0;
        g_guard_pkg = 0;
        timing_off();
        {   /* ADDONS.LOG: how long the package's commands ran (m:ss) */
            DWORD sec = (GetTickCount() - g_pkg_start) / 1000;
            char took[48];
            wsprintfA(took, "  elapsed %lu:%02lu (%lu s)", sec / 60, sec % 60, sec);
            log_line(took);
        }
        if (g_restart_refused) {
            log_line("  the installer's own restart was refused: counted as a restart it asked for");
            g_restart_asked = 1;
            g_state.pending_reboot = 1;
            save_state();
        }
        log_runonce();
        check = run_check(p);
        if (check >= 0) ok = check;
        reboot = ua_reboot_for_run(p->reboot, g_restart_asked, g_facts.nt || g_setup_mode);
        if (ok && reboot != p->reboot) log_line("  reboot=now, the installer did not ask for a restart: batched into the final one");
        after = ua_after_run(ok, reboot, g_state.pending_reboot, g_state.tries[x]);
        if (after == UA_AFTER_RETRY) {
            /* stays "running": after the restart its check decides, else it runs once more */
            ua_itoa(num, sizeof num, (int)g_last_code);
            log2("  not installed yet, a restart is pending: retry after the restart, exit code ", num);
            /* /setup: the rest of the chain first, then one restart for all
             * such packages (98 NUSB 3.3a: its USBSTOR.SYS check turns true
             * only after a restart, which came in the middle of the chain). */
            if (g_setup_mode) {
                g_deferred[x] = 1;
                g_state.pending_reboot = 1;
                save_state();
                log_line("  retry deferred to one restart at the end of the chain");
                continue;
            }
            restart();
        }
        if (ok) {
            set_state(x, UA_ST_DONE);
        } else {
            ua_itoa(num, sizeof num, (int)g_last_code);
            set_why(x, UA_ST_FAILED, check == 0 ? (g_pl ? "nie zainstalowano, kod " : "not installed, exit code ")
                                                 : (g_pl ? "b\263\271d, kod " : "error, exit code "), num);
        }
        if (after == UA_AFTER_RESTART) restart();
        if (after == UA_AFTER_PENDING) { g_state.pending_reboot = 1; save_state(); }
    }
    for (pos = 0; pos < g_p.count && !g_deferred[pos]; pos++) ;
    if (pos < g_p.count) {
        log_line("USOSADD setup: end of the chain; one restart for the packages retried after it");
        restart();
    }
}

/* /setup: NOTDONE.TXT beside this program lists the packages of the plan
 * that are not installed (failed, or skipped for an unmet dependency), with
 * their reasons; files not on the media (skipped-missing) are not listed. No
 * such package: the file is removed. USOSFB starts "USOSADD /note" after the
 * final restart when it exists: one box over the desktop, never before it
 * (a failed optional add-on does not hold the first desktop, 2026-10-28).
 * Returns the number of packages listed. */
static int write_notdone(void) {
    static char text[4096];
    char path[UA_PATH], line[200];
    const char *name_key = g_pl ? "name_pl" : "name_en";
    int i, listed = 0;
    text[0] = 0;
    ua_append(text, sizeof text, g_pl ? "USOS: nie zainstalowano:\r\n" : "USOS: not installed:\r\n");
    for (i = 0; i < g_plan.count; i++) {
        int x = g_plan.idx[i], st = g_state.st[x];
        const char *name = ua_ini_get(&g_m, g_p.pkg[x].section, name_key);
        if (g_p.pkg[x].tier == UA_TIER_GROUP) continue;
        if (st == UA_ST_DONE || st == UA_ST_PRESENT || st == UA_ST_MISSING) continue;
        line[0] = 0;
        ua_append(line, sizeof line, "- ");
        ua_append(line, sizeof line, name ? name : g_p.pkg[x].id);
        ua_append(line, sizeof line, " (");
        ua_append(line, sizeof line, g_state.why[x][0] ? g_state.why[x] : ua_state_name(st));
        ua_append(line, sizeof line, ")\r\n");
        if (listed++ < 20) ua_append(text, sizeof text, line);
    }
    path_join(path, g_root, "NOTDONE.TXT");
    if (!listed) { DeleteFileA(path); return 0; }
    ua_append(text, sizeof text, g_pl ? "\r\nDziennik: " : "\r\nLog: ");
    ua_append(text, sizeof text, g_log);
    ua_append(text, sizeof text, "\r\n");
    write_file(path, text, ua_len(text));
    log2("USOSADD setup: not installed, listed in ", path);
    return listed;
}

/* /note (USOSFB, after the final restart): once the taskbar is there (at
 * most 2 minutes' wait) the original end-of-chain summary dialog from
 * SUMMARY.TXT (every run, not only with failures), else NOTDONE.TXT as
 * before. Shown once: SUMMARY.SHN is written before the box. */
static void show_note(void) {
    static char text[4096];
    char path[UA_PATH], shown[UA_PATH];
    const char *body = text;
    UINT icon = MB_ICONWARNING;
    int n, waited;
    path_join(shown, g_root, "SUMMARY.SHN");
    if (exists(shown)) ExitProcess(0);
    path_join(path, g_root, "SUMMARY.TXT");
    n = read_file(path, text, sizeof text);
    if (n > 3 && (text[0] == '0' || text[0] == '1') && text[1] == '\r' && text[2] == '\n') {
        icon = text[0] == '1' ? MB_ICONWARNING : MB_ICONINFORMATION;
        body = text + 3;
    } else {
        path_join(path, g_root, "NOTDONE.TXT");
        n = read_file(path, text, sizeof text);
        if (n <= 0) ExitProcess(0);
    }
    if (!write_file(shown, "shown\r\n", 7)) ExitProcess(0);
    for (waited = 0; waited < 120 && !FindWindowA("Shell_TrayWnd", 0); waited++) Sleep(1000);
    Sleep(3000);
    MessageBoxA(0, body, "USOS", MB_OK | icon | MB_SETFOREGROUND);
    ExitProcess(0);
}

/* The summary text of the original end-of-chain dialog: "zainstalowano
 * X/Y, bledy: F, pominieto: S" and the failed / skipped / skipped-missing
 * packages with their reasons (at most 15), then the log path. Logged here.
 * Returns the number failed; *missing gets the skipped-missing count. */
static int summary_text(char *text, int cap, int *missing_out) {
    int i, done = 0, failed = 0, skipped = 0, missing = 0, listed = 0;
    char num[8];
    const char *name_key = g_pl ? "name_pl" : "name_en";
    for (i = 0; i < g_plan.count; i++) {
        int st = g_state.st[g_plan.idx[i]];
        if (g_p.pkg[g_plan.idx[i]].tier == UA_TIER_GROUP) continue;
        if (st == UA_ST_DONE || st == UA_ST_PRESENT) done++;
        else if (st == UA_ST_FAILED) failed++;
        else { skipped++; if (st == UA_ST_MISSING) missing++; }
    }
    text[0] = 0;
    ua_append(text, cap, g_pl ? "Pakiet zgodno\234ci USOS: zainstalowano " : "USOS compatibility pack: installed ");
    ua_itoa(num, sizeof num, done); ua_append(text, cap, num);
    ua_append(text, cap, "/");
    ua_itoa(num, sizeof num, done + failed + skipped); ua_append(text, cap, num);
    ua_append(text, cap, g_pl ? ", b\263\352dy: " : ", failed: ");
    ua_itoa(num, sizeof num, failed); ua_append(text, cap, num);
    ua_append(text, cap, g_pl ? ", pomini\352to: " : ", skipped: ");
    ua_itoa(num, sizeof num, skipped); ua_append(text, cap, num);
    log_line(text);
    ua_append(text, cap, "\r\n");
    for (i = 0; i < g_plan.count; i++) {
        int x = g_plan.idx[i], st = g_state.st[x];
        const char *name = ua_ini_get(&g_m, g_p.pkg[x].section, name_key);
        char line[200];
        if (st != UA_ST_FAILED && st != UA_ST_SKIPPED && st != UA_ST_MISSING) continue;
        if (g_p.pkg[x].tier == UA_TIER_GROUP) continue;
        line[0] = 0;
        ua_append(line, sizeof line, "- ");
        ua_append(line, sizeof line, name ? name : g_p.pkg[x].id);
        ua_append(line, sizeof line, " (");
        ua_append(line, sizeof line, g_state.why[x][0] ? g_state.why[x] : ua_state_name(st));
        ua_append(line, sizeof line, ")");
        log_line(line);
        if (listed++ < 15) { ua_append(text, cap, "\r\n"); ua_append(text, cap, line); }
    }
    ua_append(text, cap, g_pl ? "\r\n\r\nDziennik: " : "\r\n\r\nLog: ");
    ua_append(text, cap, g_log);
    if (missing_out) *missing_out = missing;
    return failed;
}

/* /setup /check: the same dialog after FIRSTBT.OK. Under the coordinator
 * the chain ends in /setup, which shows no dialog (the desktop is not there
 * yet, 756ca823); USOSFB starts "USOSADD /note" on the first desktop and it
 * shows SUMMARY.TXT once. First line "1" / "0": failed packages (the
 * dialog's warning / information icon), then the text. */
static void write_summary(void) {
    static char text[4096];
    char path[UA_PATH];
    int failed;
    ua_copy(text, sizeof text, "0\r\n");
    failed = summary_text(text + 3, sizeof text - 3, 0);
    if (failed) text[0] = '1';
    path_join(path, g_root, "SUMMARY.SHN");
    DeleteFileA(path);
    path_join(path, g_root, "SUMMARY.TXT");
    write_file(path, text, ua_len(text));
    log2("USOSADD setup: summary for the first desktop in ", path);
}

/* After the last restart: log and show "zainstalowano X/Y, pominieto Z
 * (pow\363d)". A failed package never stops the chain (run_chain goes on). */
static void finish(void) {
    static char text[4096];
    int failed, missing;
    char num[8];
    repair_ndis_before_restart();
    if (!g_setup_mode && g_state.pending_reboot) restart();
    failed = summary_text(text, sizeof text, &missing);
    if (g_setup_mode) {
        char end[UA_PATH];
        guard_off();
        lan_defaults(0);
        unregister();
        if (g_wnd) ShowWindow(g_wnd, SW_HIDE);
        /* CHAIN.END: this run reached the end of the chain (USOSFB's final
         * restart needs it next to a STATE.INI without "running"). */
        path_join(end, g_root, "CHAIN.END");
        write_file(end, "chain finished\r\n", 16);
        log_line("USOSADD setup: chain returned without restarting or showing a summary dialog");
        if (missing) {
            ua_itoa(num, sizeof num, missing);
            log2("USOSADD setup: skipped-missing (files not on the media, not a failure): ", num);
        }
        /* Failed or skipped packages never block the first desktop: they are
         * listed (NOTDONE.TXT, shown after it); the exit code only says
         * whether a restart is pending. Exit 2 stays for the runner's own
         * failures (manifest, TMP, NDIS repair). */
        write_notdone();
        ExitProcess(g_state.pending_reboot ? 3010 : 0);
    }
    lan_defaults(1);
    unregister();
    if (g_wnd) ShowWindow(g_wnd, SW_HIDE);
    MessageBoxA(0, text, "USOS", MB_OK | (failed ? MB_ICONWARNING : MB_ICONINFORMATION) | MB_SETFOREGROUND);
}

/* ---- entry ----------------------------------------------------------------------- */

static int has_switch(const char *cmdline, const char *sw) {
    const char *p = cmdline;
    int n = ua_len(sw);
    for (; *p; p++) if ((p[0] == '/' || p[0] == '-') && ua_ieqn(p + 1, sw, n)) return 1;
    return 0;
}

static int exact_switch(const char *cmd,const char *name) {
    const char *p=cmd;int n=ua_len(name);
    for(;*p;p++)if((p==cmd||p[-1]==' '||p[-1]=='\t')&&(p[0]=='/'||p[0]=='-')&&
        ua_ieqn(p+1,name,n)&&(p[n+1]==0||p[n+1]==' '||p[n+1]=='\t'))return 1;
    return 0;
}

void __cdecl ua_start(void) {
    char path[UA_PATH], line[UA_LINE];
    const char *cmdline = GetCommandLineA(), *v;
    int n, i, dry = has_switch(cmdline, "dry");
    DWORD type;

    g_big = (struct big *)VirtualAlloc(0, sizeof *g_big, MEM_COMMIT, PAGE_READWRITE);
    if (!g_big) ExitProcess(3);
    GetModuleFileNameA(0, g_root, sizeof g_root);
    for (i = ua_len(g_root) - 1; i > 0 && g_root[i] != '\\'; i--) ;
    g_root[i] = 0;
    if (exact_switch(cmdline, "note")) show_note();
    GetWindowsDirectoryA(g_win, sizeof g_win);
    GetSystemDirectoryA(g_sysdir, sizeof g_sysdir);
    if (!reg_string(HKEY_LOCAL_MACHINE, "Software\\Microsoft\\Windows\\CurrentVersion\\Setup", "SourcePath",
                    g_source, sizeof g_source, &type))
        g_source[0] = 0;
    if (!reg_string(HKEY_LOCAL_MACHINE, "Software\\Microsoft\\Windows\\CurrentVersion", "ProgramFilesDir",
                    g_pf, sizeof g_pf, &type))
        ua_copy(g_pf, sizeof g_pf, "C:\\Program Files");

    /* Agreed OS diagnostics locations; state/cache remain in g_root. */
    ua_copy(path, sizeof path, (GetVersion() & 0x80000000UL) ? "C:\\USOS9X\\LOGS" : "C:\\USOS\\NT4");
    make_dirs(path);
    path_join(g_log, path, "ADDONS.LOG");
    path_join(path, g_root, "LEGACY.INI");
    n = read_file(path, g_manifest, sizeof g_manifest);
    if (n <= 0) { log2("USOSADD: manifest not found: ", path); ExitProcess(2); }
    ua_ini_parse(&g_m, g_manifest, n);
    if (has_switch(cmdline, "reset")) {
        path_join(path, g_root, "STATE.INI");
        DeleteFileA(path);
        log_line("USOSADD: state reset");
        ExitProcess(0);
    }
    path_join(path, g_root, "SELECT.INI");
    n = read_file(path, g_select, sizeof g_select);
    if (n <= 0) { log_line("USOSADD: no SELECT.INI, nothing to do"); ExitProcess(0); }
    ua_ini_parse(&g_sel, g_select, n);
    if (ua_load_pkgs(&g_m, &g_p) < 0) { log_line("USOSADD: too many packages"); ExitProcess(2); }
    path_join(path, g_root, "STATE.INI");
    n = read_file(path, g_statebuf, sizeof g_statebuf);
    if (n > 0) { ua_ini_parse(&g_st, g_statebuf, n); ua_state_load(&g_state, &g_st, &g_p); }
    else ua_state_load(&g_state, 0, &g_p);

    detect();
    g_setup_mode=exact_switch(cmdline,"setup");
    if(g_setup_mode && (g_facts.nt||g_facts.major!=4||!coordinated_build(g_facts.minor,g_facts.build)||!display_boundary())){
        log_line("USOSADD setup: 95 (950 / OSR2) / 98 (1998 / 2222) late display boundary missing; nothing installed");ExitProcess(2);}
    /* A start from HKLM Run (MSBATCH [Install] / REG95.REG USOSAddons) while
     * the first-desktop coordinator owns the chain (FIRSTBT.ON, neither
     * FIRSTBT.OK nor FIRSTBT.ERR): nothing runs, the value stays, so the
     * ordinary Run chain still follows if the coordinator stops with
     * FIRSTBT.ERR. After FIRSTBT.OK the value is only removed. OSR2 Setup
     * applies [Install] AddReg (X470 OSR2.1 PL native, 2026-10-27), so Run
     * USOSAddons exists there before the coordinator's first /setup. */
    if(!g_setup_mode && !g_facts.nt && exists("C:\\USOS9X\\FIRSTBT.ON") && !exists("C:\\USOS9X\\FIRSTBT.ERR")){
        if(exists("C:\\USOS9X\\FIRSTBT.OK")){
            unregister();log_line("USOSADD: the first-desktop coordinator finished the chain; Run value removed");ExitProcess(0);}
        log_line("USOSADD: the first-desktop coordinator (USOSFB) runs the chain; nothing done from Run");ExitProcess(0);}
    /* Coordinator only: e.g. IE 5.5 SP2 restarts at once (reboot_setup=now)
     * so its WININIT replacements and RunOnceEx precede the later packages. */
    if(g_setup_mode && ua_setup_overrides(&g_m,&g_p)) log_line("USOSADD setup: reboot_setup/check_setup values applied");
    /* Locale/keyboard can differ from the installation media's language.
     * Stage selects packages by the latter; retain that language on resume. */
    if (!dry) {
        v = ua_ini_get(&g_sel, "select", "lang");
        if (v && (ua_ieq(v, "PL") || ua_ieq(v, "EN") || ua_ieq(v, "XX")))
            ua_copy(g_sys.lang, sizeof g_sys.lang, v);
    }
    if (dry) {
        /* /dry /as:<os>,<lang>[,<ntsp>]: the plan another system would get */
        const char *as = ua_find(cmdline, "/as:");
        if (as) {
            char item[16], arg[48];
            ua_copy(arg, sizeof arg, as + 4);
            for (i = 0; arg[i]; i++) if (arg[i] == ' ') arg[i] = 0;
            if (ua_list_item(arg, 0, item, sizeof item)) ua_copy(g_sys.os, sizeof g_sys.os, item);
            if (ua_list_item(arg, 1, item, sizeof item)) ua_copy(g_sys.lang, sizeof g_sys.lang, item);
            g_sys.ntsp[0] = 0;
            if (ua_list_item(arg, 2, item, sizeof item)) ua_copy(g_sys.ntsp, sizeof g_sys.ntsp, item);
            log2("  detection overridden for the dry run: ", arg);
        }
    }
    g_pl = ua_ieq(g_sys.lang, "PL");
    line[0] = 0;
    wsprintfA(line, "USOSADD start %d: %s %d.%d.%d \"%s\" -> system %s, language %s, NT SP %s%s",
              g_state.starts + 1, g_facts.nt ? "NT" : "9x", g_facts.major, g_facts.minor, g_facts.build,
              g_facts.csd, g_sys.os, g_sys.lang, g_sys.ntsp[0] ? g_sys.ntsp : "-", dry ? " (dry run)" : "");
    log_line(line);
    if (!g_facts.nt && g_facts.subver[0]) {
        wsprintfA(line, "  SubVersionNumber \"%s\"", g_facts.subver);
        log_line(line);
    }
    v = ua_ini_get(&g_sel, "select", "expect");
    if (v && *v && !ua_ieq(v, g_sys.os)) log2("  note: USOS expected ", v);
    if (ua_ieq(g_sys.os, "?")) { log_line("USOSADD: unsupported system, nothing done"); ExitProcess(1); }

    ua_selection(&g_m, &g_sel, &g_choice);
    log2("  preset: ", g_choice.preset[0] ? g_choice.preset : "-");
    ua_resolve(&g_m, &g_p, &g_sys, g_choice.full, g_choice.options, g_choice.exclude, &g_plan);
    if (g_state.starts == 0 || dry) log_plan();
    if (dry) ExitProcess(0);

    /* After the final restart. A package whose check still fails (or that
     * failed / was skipped in the chain) is listed in NOTDONE.TXT and never
     * stops the desktop (2026-10-28): exit 0, USOSFB shows the list after
     * the desktop. Retry stays for the coordinator's own failures. */
    if(g_setup_mode && exact_switch(cmdline,"check")){
        int failed=0;
        for(i=0;i<g_plan.count;i++){
            int x=g_plan.idx[i],check,st=g_state.st[x];
            const ua_pkg *p=&g_p.pkg[x];
            if(p->tier==UA_TIER_GROUP)continue;
            /* files not on the media: not installed on purpose, not a failure */
            if(st==UA_ST_MISSING){log2("USOSADD setup final check: skipped-missing, ignored: ",p->id);continue;}
            check=run_check(p);
            if(check>0&&st!=UA_ST_DONE&&st!=UA_ST_PRESENT){
                /* installed after all (a restart finished it) */
                g_state.why[x][0]=0;g_state.st[x]=UA_ST_DONE;log2("USOSADD setup final check: installed after the restart: ",p->id);continue;}
            if(check==0&&(st==UA_ST_DONE||st==UA_ST_PRESENT)){
                ua_copy(g_state.why[x],sizeof g_state.why[x],g_pl?"brak po restarcie":"not present after the restart");
                g_state.st[x]=UA_ST_FAILED;}
            if(g_state.st[x]!=UA_ST_DONE&&g_state.st[x]!=UA_ST_PRESENT){
                failed++;log2("USOSADD setup final check: not installed, listed: ",p->id);}
        }
        g_state.pending_reboot=0;save_state();unregister();
        write_notdone();
        write_summary();
        log_line(failed?"USOSADD setup final checks complete; packages not installed are listed (not blocking)":"USOSADD setup final checks complete");
        ExitProcess(0);
    }

    /* Started from Run after the shell; still wait while Setup finishes
     * (an older RunOnce entry, or a slow first boot). */
    if(!g_setup_mode)register_run();else unregister();
    if (ua_ieq(g_sys.os,"NT4") && virtual_machine()) {
        log_line("USOSADD: VM deferred; Run retained for the first hardware desktop");
        ExitProcess(0);
    }
    if (!wait_for_desktop()) {
        log_line("USOSADD: Windows Setup is still running, trying again at the next start");
        ExitProcess(0);
    }
    path_join(path, g_root, "TMP");
    make_dirs(path);
    type = GetFileAttributesA(path);
    if (type == (DWORD)-1 || !(type & FILE_ATTRIBUTE_DIRECTORY) ||
        !SetEnvironmentVariableA("TEMP", path) || !SetEnvironmentVariableA("TMP", path)) {
        log_line("USOSADD: private TMP unavailable; no profile-directory fallback");
        ExitProcess(2);
    }
    g_state.starts++;
    g_state.pending_reboot = 0; /* we are running after the restart */
    save_state();
    if (g_setup_mode) {
        path_join(path, g_root, "CHAIN.END");
        DeleteFileA(path);
        guard_open();
    }
    window_open();
    status(g_pl ? "USOS: instalowanie dodatk\363w..." : "USOS: installing add-ons...");
    run_chain();
    finish();
    ExitProcess(0);
}
