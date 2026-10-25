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
#include "../../../../tools/legacy_desktop_wait.h"

#define MANIFEST_CAP (256 * 1024)
#define SMALL_CAP (16 * 1024)

/* The large tables live in memory from VirtualAlloc: statics would be
 * written into the file (no C runtime to clear a BSS). */
#define VERBUF_CAP (64 * 1024)
static struct big {
    char manifest[MANIFEST_CAP];
    char select[SMALL_CAP];
    char statebuf[SMALL_CAP];
    char stateout[SMALL_CAP];
    char appendbuf[SMALL_CAP];
    char verbuf[VERBUF_CAP];
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

static LRESULT CALLBACK wnd_proc(HWND w, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_CLOSE) return 0; /* not closable while installing */
    return DefWindowProcA(w, msg, wp, lp);
}

static void pump(void) {
    MSG msg;
    while (PeekMessageA(&msg, 0, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }
}

static void window_open(void) {
    WNDCLASSA wc;
    HINSTANCE inst = GetModuleHandleA(0);
    int w = 520, h = 110;
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

static void status(const char *text) {
    if (g_text) SetWindowTextA(g_text, text);
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
    if (!title[0] || !rule_for(title, action, sizeof action)) return TRUE;
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
    for (;;) {
        DWORD r = MsgWaitForMultipleObjects(1, &pi.hProcess, FALSE, 1000, QS_ALLINPUT);
        if (r == WAIT_OBJECT_0) break;
        pump();
        if (r == WAIT_TIMEOUT) EnumWindows(answer_window, 0);
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
    g_last_code = code;
    return code_ok(p, code);
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


#define RUN_KEY "Software\\Microsoft\\Windows\\CurrentVersion\\Run"
#define RUNONCE_KEY "Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce"

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

static void restart(void) {
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
        if (w < UA_OUT_SYSTEM) continue;
        line[0] = 0;
        ua_append(line, sizeof line, "  not planned: ");
        ua_append(line, sizeof line, g_p.pkg[i].id);
        ua_append(line, sizeof line, w == UA_OUT_SYSTEM ? " (not for this system)" : w == UA_OUT_STATUS ? " (status: " : " (needs ");
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
        int x = g_plan.idx[pos], ok, k, check, after;
        const ua_pkg *p = &g_p.pkg[x];
        const char *name = ua_ini_get(&g_m, p->section, name_key);
        int st = g_state.st[x];
        if (st == UA_ST_DONE || st == UA_ST_PRESENT || st == UA_ST_FAILED || st == UA_ST_SKIPPED) continue;
        if (!name) name = p->id;
        if (p->tier == UA_TIER_GROUP) {
            set_state(x, ua_needs_met(&g_m, &g_p, &g_state, &g_sys, x, unmet, sizeof unmet) ? UA_ST_DONE : UA_ST_SKIPPED);
            continue;
        }
        log2("Package ", p->id);
        check = run_check(p);
        if (st == UA_ST_RUNNING) {
            int d = ua_resume_decision(g_state.tries[x], check >= 0, check == 1);
            if (d == 1) { set_state(x, UA_ST_DONE); continue; }
            if (d == 3) { set_why(x, UA_ST_FAILED, g_pl ? "przerwana dwa razy" : "interrupted twice", 0); continue; }
        } else if (check == 1) {
            log_line("  already installed");
            set_state(x, UA_ST_PRESENT);
            continue;
        }
        if (*p->status) { set_why(x, UA_ST_SKIPPED, "status: ", p->status); continue; }
        if (!ua_needs_met(&g_m, &g_p, &g_state, &g_sys, x, unmet, sizeof unmet)) {
            set_why(x, UA_ST_SKIPPED, g_pl ? "wymaga " : "needs ", unmet);
            continue;
        }
        if (!files_present(p)) { set_why(x, UA_ST_SKIPPED, g_pl ? "brak pliku" : "file missing", 0); continue; }
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
        status(line);
        path_join(dir, g_root, "TMP");
        path_join(tmpdir, dir, p->dir);
        make_dirs(tmpdir);
        g_state.tries[x]++;
        set_state(x, UA_ST_RUNNING);
        ok = 1;
        g_last_code = 0;
        g_answer_pkg = p;
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
        check = run_check(p);
        if (check >= 0) ok = check;
        after = ua_after_run(ok, p->reboot, g_state.pending_reboot, g_state.tries[x]);
        if (after == UA_AFTER_RETRY) {
            /* stays "running": after the restart its check decides, else it runs once more */
            ua_itoa(num, sizeof num, (int)g_last_code);
            log2("  not installed yet, a restart is pending: retry after the restart, exit code ", num);
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
}

/* After the last restart: log and show "zainstalowano X/Y, pominieto Z
 * (pow\363d)". A failed package never stops the chain (run_chain goes on). */
static void finish(void) {
    static char text[4096];
    int i, done = 0, failed = 0, skipped = 0, listed = 0;
    char num[8];
    const char *name_key = g_pl ? "name_pl" : "name_en";
    if (!g_setup_mode && g_state.pending_reboot) restart();
    for (i = 0; i < g_plan.count; i++) {
        int st = g_state.st[g_plan.idx[i]];
        if (g_p.pkg[g_plan.idx[i]].tier == UA_TIER_GROUP) continue;
        if (st == UA_ST_DONE || st == UA_ST_PRESENT) done++;
        else if (st == UA_ST_FAILED) failed++;
        else skipped++;
    }
    text[0] = 0;
    ua_append(text, sizeof text, g_pl ? "Pakiet zgodno\234ci USOS: zainstalowano " : "USOS compatibility pack: installed ");
    ua_itoa(num, sizeof num, done); ua_append(text, sizeof text, num);
    ua_append(text, sizeof text, "/");
    ua_itoa(num, sizeof num, done + failed + skipped); ua_append(text, sizeof text, num);
    ua_append(text, sizeof text, g_pl ? ", b\263\352dy: " : ", failed: ");
    ua_itoa(num, sizeof num, failed); ua_append(text, sizeof text, num);
    ua_append(text, sizeof text, g_pl ? ", pomini\352to: " : ", skipped: ");
    ua_itoa(num, sizeof num, skipped); ua_append(text, sizeof text, num);
    log_line(text);
    ua_append(text, sizeof text, "\r\n");
    for (i = 0; i < g_plan.count; i++) {
        int x = g_plan.idx[i], st = g_state.st[x];
        const char *name = ua_ini_get(&g_m, g_p.pkg[x].section, name_key);
        char line[200];
        if (st != UA_ST_FAILED && st != UA_ST_SKIPPED) continue;
        if (g_p.pkg[x].tier == UA_TIER_GROUP) continue;
        line[0] = 0;
        ua_append(line, sizeof line, "- ");
        ua_append(line, sizeof line, name ? name : g_p.pkg[x].id);
        ua_append(line, sizeof line, " (");
        ua_append(line, sizeof line, g_state.why[x][0] ? g_state.why[x] : ua_state_name(st));
        ua_append(line, sizeof line, ")");
        log_line(line);
        if (listed++ < 15) { ua_append(text, sizeof text, "\r\n"); ua_append(text, sizeof text, line); }
    }
    ua_append(text, sizeof text, g_pl ? "\r\n\r\nDziennik: " : "\r\n\r\nLog: ");
    ua_append(text, sizeof text, g_log);
    if (g_setup_mode) {
        lan_defaults(0);
        unregister();
        if (g_wnd) ShowWindow(g_wnd, SW_HIDE);
        log_line("USOSADD setup: chain returned without restarting or showing a summary dialog");
        ExitProcess(failed || skipped ? 2 : g_state.pending_reboot ? 3010 : 0);
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
    if(g_setup_mode && (g_facts.nt||g_facts.major!=4||g_facts.minor!=0||(g_facts.build&0xffff)!=950||!exists("C:\\USOS9X\\VLATE.OK"))){
        log_line("USOSADD setup: source950 late display boundary missing; nothing installed");ExitProcess(2);}
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
    v = ua_ini_get(&g_sel, "select", "expect");
    if (v && *v && !ua_ieq(v, g_sys.os)) log2("  note: USOS expected ", v);
    if (ua_ieq(g_sys.os, "?")) { log_line("USOSADD: unsupported system, nothing done"); ExitProcess(1); }

    ua_selection(&g_m, &g_sel, &g_choice);
    log2("  preset: ", g_choice.preset[0] ? g_choice.preset : "-");
    ua_resolve(&g_m, &g_p, &g_sys, g_choice.full, g_choice.options, g_choice.exclude, &g_plan);
    if (g_state.starts == 0 || dry) log_plan();
    if (dry) ExitProcess(0);

    if(g_setup_mode && exact_switch(cmdline,"check")){
        int failed=0;
        for(i=0;i<g_plan.count;i++){
            int x=g_plan.idx[i],check;
            const ua_pkg *p=&g_p.pkg[x];
            if(p->tier==UA_TIER_GROUP)continue;
            check=run_check(p);
            if(check==0||(check<0&&g_state.st[x]!=UA_ST_DONE&&g_state.st[x]!=UA_ST_PRESENT)){
                failed++;log2("USOSADD setup final check failed: ",p->id);}
        }
        if(!failed){g_state.pending_reboot=0;save_state();unregister();}
        log_line(failed?"USOSADD setup final check incomplete":"USOSADD setup final checks complete");
        ExitProcess(failed?2:0);
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
    window_open();
    status(g_pl ? "USOS: instalowanie dodatk\363w..." : "USOS: installing add-ons...");
    run_chain();
    finish();
    ExitProcess(0);
}
