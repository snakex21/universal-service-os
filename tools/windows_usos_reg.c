/*
 * windows_usos_reg.c - usos-reg.exe: apply a declarative registry set file.
 *
 * Universal Service OS (USOS)
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 *   usos-reg.exe [--log FILE] [--dry-run] [--hive NTUSER.DAT] SETFILE
 *
 * Clean-room USOS tool. i386 console image marked 4.00, no C runtime,
 * imports only kernel32/advapi32 functions present in Windows NT 4.0
 * (IsWow64Process is resolved at run time). Runs on NT 4.0 SP6 .. 11.
 *
 * SETFILE (UTF-8 or ASCII, CRLF or LF; ';' or '#' comment lines and blank
 * lines ignored), one entry per line:
 *
 *   ROOT\Key\Path|ValueName|type|data
 *
 * ROOT  HKLM     HKEY_LOCAL_MACHINE\Key\Path
 *       DEFAULT  HKEY_USERS\.DEFAULT\Key\Path (logon screen, system account)
 *       USER     the Default User hive (NTUSER.DAT every new profile is made
 *                from, loaded under HKEY_USERS\USOSREG<pid>) and, when the
 *                process user is not LocalSystem, also HKEY_CURRENT_USER.
 *                With --hive the given hive replaces the Default User hive
 *                and HKEY_CURRENT_USER is left alone (offline use).
 * type  dword (decimal or 0x hex), sz, expand_sz, binary ("ff,00,..."),
 *       del (delete the value; data empty). Empty ValueName = default value.
 *
 * The whole file is parsed first: any malformed line rejects it (exit 1,
 * nothing written, the line number is reported). Keys are created as
 * needed. Under WOW64 every key is opened with KEY_WOW64_64KEY.
 * --dry-run parses and prints each operation and writes nothing.
 * Messages go to stdout, or are appended to FILE with --log.
 * Exit 0 all applied, 2 some entries failed (the others are applied),
 * 1 bad arguments or an unreadable/malformed set file.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#define NOTICE "usos-reg (Universal Service OS), GPL-3.0-or-later, source: tools/windows_usos_reg.c"
#define MAX_FILE   (512u*1024u)
#define MAX_ENTRY  8192u
#define MAX_BIN    (256u*1024u)
#define WOW64_64KEY 0x0100

enum { R_HKLM=1, R_DEFAULT, R_USER };
enum { T_DWORD=1, T_SZ, T_EXPAND_SZ, T_BINARY, T_DEL };

struct ent {
    WCHAR *key, *name, *data;
    DWORD line, dword, binoff, binlen;
    BYTE root, type;
};

static char raw[MAX_FILE+4];
static WCHAR text[MAX_FILE+4];
static struct ent ents[MAX_ENTRY];
static DWORD nents;
static BYTE bin[MAX_BIN];
static DWORD binused;
static char msg[4096];
static DWORD msglen;
static HANDLE out = INVALID_HANDLE_VALUE;
static WCHAR path[2048], hivepath[MAX_PATH*2], tmpw[MAX_PATH*2], hivename[32];
static WCHAR *argv[16];
static REGSAM wow;
static DWORD okcount, failcount;

/* The compiler may emit calls to these for struct copies/zeroing. */
void *memset(void *p, int v, size_t n) { volatile BYTE *b = p; while (n--) *b++ = (BYTE)v; return p; }
void *memcpy(void *d, const void *s, size_t n) { volatile BYTE *a = d; const BYTE *b = s; while (n--) *a++ = *b++; return d; }

static DWORD wlen(const WCHAR *s) { DWORD n = 0; while (s[n]) n++; return n; }
static void wcopy(WCHAR *d, const WCHAR *s) { while ((*d++ = *s++)); }
static void wcat(WCHAR *d, const WCHAR *s) { wcopy(d + wlen(d), s); }
static WCHAR wup(WCHAR c) { return c >= 'a' && c <= 'z' ? (WCHAR)(c - 32) : c; }
static int wieq(const WCHAR *a, const WCHAR *b) { while (*a && wup(*a) == wup(*b)) { a++; b++; } return wup(*a) == wup(*b); }
static int weq(const WCHAR *a, const WCHAR *b) { while (*a && *a == *b) { a++; b++; } return *a == *b; }

/* ---- output ---------------------------------------------------------- */
static void flush(void)
{
    DWORD w;
    msg[msglen++] = '\r'; msg[msglen++] = '\n';
    if (out != INVALID_HANDLE_VALUE) WriteFile(out, msg, msglen, &w, 0);
    msglen = 0;
}
static void put(const char *s) { while (*s && msglen < sizeof(msg) - 3) msg[msglen++] = *s++; }
static void putw(const WCHAR *s)
{
    int room = (int)(sizeof(msg) - 3 - msglen), n;
    if (room <= 0 || !*s) return;
    n = WideCharToMultiByte(CP_UTF8, 0, s, (int)wlen(s), msg + msglen, room, 0, 0);
    if (n > 0) msglen += (DWORD)n; else put("?");
}
static void putn(DWORD v)
{
    char d[12]; int n = 0;
    do { d[n++] = (char)('0' + v % 10); v /= 10; } while (v);
    while (n) { char c[2] = { d[--n], 0 }; put(c); }
}
static void puthex(DWORD v)
{
    char c[11]; int i;
    c[0] = '0'; c[1] = 'x';
    for (i = 0; i < 8; i++) c[2 + i] = "0123456789abcdef"[(v >> (28 - 4 * i)) & 15];
    c[10] = 0; put(c);
}
static void line_error(DWORD line, const char *why)
{
    put("[usos-reg] ERROR line "); putn(line); put(": "); put(why); flush();
}

/* ---- parsing --------------------------------------------------------- */
static int hexdigit(WCHAR c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static const char *parse_dword(const WCHAR *s, DWORD *v)
{
    DWORD r = 0; int n = 0;
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
        for (s += 2; *s; s++, n++) {
            int d = hexdigit(*s);
            if (d < 0) return "dword: bad hex digit";
            if (n == 8) return "dword: more than 8 hex digits";
            r = (r << 4) | (DWORD)d;
        }
        if (!n) return "dword: empty hex number";
    } else {
        for (; *s; s++, n++) {
            DWORD d;
            if (*s < '0' || *s > '9') return "dword: not a decimal or 0x hex number";
            d = (DWORD)(*s - '0');
            if (r > 429496729u || (r == 429496729u && d > 5)) return "dword: larger than 4294967295";
            r = r * 10 + d;
        }
        if (!n) return "dword: empty number";
    }
    *v = r;
    return 0;
}

static const char *parse_binary(const WCHAR *s, struct ent *e)
{
    e->binoff = binused; e->binlen = 0;
    if (!*s) return 0;
    for (;;) {
        int hi = hexdigit(s[0]), lo;
        if (hi < 0) return "binary: expected hex bytes like ff,00,01";
        lo = hexdigit(s[1]);
        if (lo >= 0) { hi = hi * 16 + lo; s += 2; } else s += 1;
        if (binused >= MAX_BIN) return "binary: too much binary data in the set file";
        bin[binused++] = (BYTE)hi; e->binlen++;
        if (!*s) return 0;
        if (*s != ',' || !s[1]) return "binary: expected hex bytes like ff,00,01";
        s++;
    }
}

/* s: one line (NUL-terminated, no CR/LF). Returns an error text or 0. */
static const char *parse_line(WCHAR *s, struct ent *e)
{
    WCHAR *f[4], *p, *key;
    int n = 1;
    f[0] = s;
    for (p = s; *p; p++)
        if (*p == '|') { if (n == 4) return "more than 4 fields (ROOT\\Key|Name|type|data)"; *p = 0; f[n++] = p + 1; }
    if (n != 4) return "expected 4 fields separated by '|' (ROOT\\Key|Name|type|data)";
    for (key = f[0]; *key && *key != '\\'; key++) ;
    if (!*key) return "first field must be ROOT\\Key\\Path";
    *key++ = 0;
    if (wieq(f[0], L"HKLM")) e->root = R_HKLM;
    else if (wieq(f[0], L"DEFAULT")) e->root = R_DEFAULT;
    else if (wieq(f[0], L"USER")) e->root = R_USER;
    else return "root must be HKLM, USER or DEFAULT";
    if (!*key) return "empty key path";
    for (p = key; *p; p++)
        if (*p == '\\' && (p[1] == '\\' || !p[1])) return "empty key path component";
    if (wlen(key) > 1000) return "key path too long";
    if (wlen(f[1]) > 16383) return "value name too long";
    e->key = key; e->name = f[1]; e->data = f[3];
    if (weq(f[2], L"dword")) { e->type = T_DWORD; return parse_dword(f[3], &e->dword); }
    if (weq(f[2], L"sz")) { e->type = T_SZ; return 0; }
    if (weq(f[2], L"expand_sz")) { e->type = T_EXPAND_SZ; return 0; }
    if (weq(f[2], L"binary")) { e->type = T_BINARY; return parse_binary(f[3], e); }
    if (weq(f[2], L"del")) { e->type = T_DEL; return *f[3] ? "del takes no data" : 0; }
    return "type must be dword, sz, expand_sz, binary or del";
}

static int read_setfile(const WCHAR *name)
{
    HANDLE h = CreateFileW(name, GENERIC_READ, FILE_SHARE_READ, 0, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
    DWORD hi = 0, size, got = 0, i, line = 0, start = 0, nw;
    char *p = raw; int bad = 0;
    if (h == INVALID_HANDLE_VALUE) {
        put("[usos-reg] ERROR cannot open the set file "); putw(name); put(" error="); putn(GetLastError()); flush();
        return 0;
    }
    size = GetFileSize(h, &hi);
    if (size == 0xFFFFFFFFu || hi || size > MAX_FILE) {
        CloseHandle(h);
        put("[usos-reg] ERROR set file unreadable or larger than 512 KiB"); flush();
        return 0;
    }
    if (size && (!ReadFile(h, raw, size, &got, 0) || got != size)) {
        CloseHandle(h);
        put("[usos-reg] ERROR cannot read the set file error="); putn(GetLastError()); flush();
        return 0;
    }
    CloseHandle(h);
    if (size >= 3 && (BYTE)raw[0] == 0xEF && (BYTE)raw[1] == 0xBB && (BYTE)raw[2] == 0xBF) { p += 3; size -= 3; }
    for (i = 0; i < size; i++)
        if (!p[i]) { line_error(1, "NUL byte in the set file (UTF-16 is not accepted; use UTF-8)"); return 0; }
    nw = size ? (DWORD)MultiByteToWideChar(CP_UTF8, 0, p, (int)size, text, MAX_FILE) : 0;
    if (size && !nw) { put("[usos-reg] ERROR set file is not valid UTF-8"); flush(); return 0; }
    text[nw] = 0;
    for (i = 0; i <= nw; i++) {
        WCHAR *s; DWORD end, j;
        if (i < nw && text[i] != '\n') continue;
        line++;
        end = i;
        if (end > start && text[end - 1] == '\r') end--;
        text[end] = 0;
        s = text + start;
        start = i + 1;
        for (j = 0; s[j] == ' ' || s[j] == '\t'; j++) ;
        if (!s[j] || s[j] == ';' || s[j] == '#') continue;
        for (j = 0; s[j]; j++)
            if (s[j] == '\r') { line_error(line, "stray carriage return"); bad = 1; break; }
        if (s[j]) continue;
        if (nents == MAX_ENTRY) { line_error(line, "more than 8192 entries"); return 0; }
        ents[nents].line = line;
        {
            const char *why = parse_line(s, &ents[nents]);
            if (why) { line_error(line, why); bad = 1; continue; }
        }
        nents++;
    }
    if (bad) { put("[usos-reg] set file rejected, nothing written"); flush(); return 0; }
    return 1;
}

/* ---- labels ---------------------------------------------------------- */
static const char *root_label(int root)
{
    return root == R_HKLM ? "HKLM" : root == R_DEFAULT ? "DEFAULT" : "USER";
}
static const char *type_label(int type)
{
    static const char *t[] = { "", "dword", "sz", "expand_sz", "binary", "del" };
    return t[type];
}
static void put_target(const char *label, const struct ent *e)
{
    put(label); put("\\"); putw(e->key); put("|"); putw(e->name);
}

/* ---- registry -------------------------------------------------------- */
static LONG apply_one(HKEY base, const WCHAR *prefix, const struct ent *e)
{
    HKEY k; LONG r; DWORD disp;
    path[0] = 0;
    if (prefix) { wcopy(path, prefix); wcat(path, L"\\"); }
    wcat(path, e->key);
    if (e->type == T_DEL) {
        r = RegOpenKeyExW(base, path, 0, KEY_SET_VALUE | wow, &k);
        if (r == ERROR_FILE_NOT_FOUND) return ERROR_SUCCESS; /* nothing to delete */
        if (r != ERROR_SUCCESS) return r;
        r = RegDeleteValueW(k, e->name);
        RegCloseKey(k);
        return r == ERROR_FILE_NOT_FOUND ? ERROR_SUCCESS : r;
    }
    r = RegCreateKeyExW(base, path, 0, 0, REG_OPTION_NON_VOLATILE, KEY_SET_VALUE | wow, 0, &k, &disp);
    if (r != ERROR_SUCCESS) return r;
    switch (e->type) {
    case T_DWORD:
        r = RegSetValueExW(k, e->name, 0, REG_DWORD, (const BYTE *)&e->dword, 4);
        break;
    case T_SZ: case T_EXPAND_SZ:
        r = RegSetValueExW(k, e->name, 0, e->type == T_SZ ? REG_SZ : REG_EXPAND_SZ,
                           (const BYTE *)e->data, (wlen(e->data) + 1) * sizeof(WCHAR));
        break;
    default:
        r = RegSetValueExW(k, e->name, 0, REG_BINARY, bin + e->binoff, e->binlen);
        break;
    }
    RegCloseKey(k);
    return r;
}

static void report(const char *label, const struct ent *e, LONG r)
{
    if (r == ERROR_SUCCESS) { okcount++; put("[usos-reg] OK "); put_target(label, e); }
    else { failcount++; put("[usos-reg] FAIL "); put_target(label, e); put(" error="); putn((DWORD)r); }
    flush();
}

static int query_string(HKEY k, const WCHAR *name, WCHAR *outbuf, DWORD chars)
{
    DWORD type, cb = (chars - 1) * sizeof(WCHAR);
    if (RegQueryValueExW(k, name, 0, &type, (BYTE *)outbuf, &cb) != ERROR_SUCCESS) return 0;
    if (type != REG_SZ && type != REG_EXPAND_SZ) return 0;
    outbuf[cb / sizeof(WCHAR)] = 0;
    return outbuf[0] != 0;
}

static int expand(const WCHAR *in, WCHAR *outbuf, DWORD chars)
{
    DWORD n = ExpandEnvironmentStringsW(in, outbuf, chars);
    return n && n <= chars;
}

/* The Default User hive: Vista+ ProfileList\Default; 2000/XP/2003
 * ProfilesDirectory\DefaultUserProfile ("Default User"); NT 4.0 neither:
 * %SystemRoot%\Profiles\Default User. */
static int default_hive(WCHAR *outbuf)
{
    static WCHAR dir[MAX_PATH*2], user[MAX_PATH];
    HKEY k; int found = 0;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\ProfileList",
                      0, KEY_QUERY_VALUE | wow, &k) == ERROR_SUCCESS) {
        if (query_string(k, L"Default", dir, MAX_PATH)) found = 1;
        else if (query_string(k, L"ProfilesDirectory", dir, MAX_PATH)) {
            if (!query_string(k, L"DefaultUserProfile", user, MAX_PATH)) wcopy(user, L"Default User");
            wcat(dir, L"\\"); wcat(dir, user);
            found = 1;
        }
        RegCloseKey(k);
    }
    if (!found) wcopy(dir, L"%SystemRoot%\\Profiles\\Default User");
    wcat(dir, L"\\NTUSER.DAT");
    return expand(dir, outbuf, MAX_PATH*2);
}

static int enable_privileges(void)
{
    struct { DWORD count; LUID_AND_ATTRIBUTES p[2]; } tp;
    HANDLE t; int ok;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &t)) return 0;
    tp.count = 2;
    ok = LookupPrivilegeValueW(0, L"SeRestorePrivilege", &tp.p[0].Luid)
      && LookupPrivilegeValueW(0, L"SeBackupPrivilege", &tp.p[1].Luid);
    tp.p[0].Attributes = tp.p[1].Attributes = SE_PRIVILEGE_ENABLED;
    if (ok) ok = AdjustTokenPrivileges(t, FALSE, (TOKEN_PRIVILEGES *)&tp, 0, 0, 0) && GetLastError() == ERROR_SUCCESS;
    CloseHandle(t);
    return ok;
}

/* 1: the process user is LocalSystem (S-1-5-18) or cannot be determined. */
static int is_local_system(void)
{
    static DWORD buf[64];
    HANDLE t; DWORD n = 0; const BYTE *sid; int sys = 1;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &t)) return 1;
    if (GetTokenInformation(t, TokenUser, buf, sizeof(buf), &n)) {
        sid = (const BYTE *)((TOKEN_USER *)buf)->User.Sid;
        sys = sid[0] == 1 && sid[1] == 1 && sid[2] == 0 && sid[3] == 0 && sid[4] == 0 && sid[5] == 0
           && sid[6] == 0 && sid[7] == 5 && *(const DWORD *)(sid + 8) == 18;
    }
    CloseHandle(t);
    return sys;
}

static void detect_wow64(void)
{
    typedef BOOL (WINAPI *wow_fn)(HANDLE, PBOOL);
    HMODULE k = GetModuleHandleW(L"kernel32.dll");
    wow_fn f = k ? (wow_fn)GetProcAddress(k, "IsWow64Process") : 0;
    BOOL w = FALSE;
    if (f && f(GetCurrentProcess(), &w) && w) wow = WOW64_64KEY;
}

static void make_hive_name(void)
{
    DWORD pid = GetCurrentProcessId(), d[12], n = 0, i = 7;
    wcopy(hivename, L"USOSREG");
    do { d[n++] = pid % 10; pid /= 10; } while (pid);
    while (n) hivename[i++] = (WCHAR)('0' + d[--n]);
    hivename[i] = 0;
}

/* ---- command line ---------------------------------------------------- */
static int split_args(WCHAR *s)
{
    int n = 0;
    while (*s) {
        WCHAR *o; int q = 0;
        while (*s == ' ' || *s == '\t') s++;
        if (!*s) break;
        if (n == 16) return -1;
        argv[n++] = o = s;
        while (*s && (q || (*s != ' ' && *s != '\t'))) {
            if (*s == '"') { q = !q; s++; continue; }
            *o++ = *s++;
        }
        if (*s) s++;
        *o = 0;
    }
    return n;
}

static void usage(void)
{
    put("usage: usos-reg.exe [--log FILE] [--dry-run] [--hive NTUSER.DAT] SETFILE"); flush();
    put(NOTICE); flush();
}

void entry(void)
{
    static WCHAR cmd[4096];
    const WCHAR *log = 0, *setfile = 0, *hive = 0;
    int argc, i, dry = 0, hkcu, hive_loaded = 0, want_user = 0;
    DWORD e;
    const WCHAR *c = GetCommandLineW();
    if (wlen(c) >= 4096) { out = GetStdHandle(STD_OUTPUT_HANDLE); usage(); ExitProcess(1); }
    wcopy(cmd, c);
    out = GetStdHandle(STD_OUTPUT_HANDLE);
    argc = split_args(cmd);
    for (i = 1; i < argc; i++) {
        if (weq(argv[i], L"--dry-run")) dry = 1;
        else if (weq(argv[i], L"--log") && i + 1 < argc) log = argv[++i];
        else if (weq(argv[i], L"--hive") && i + 1 < argc) hive = argv[++i];
        else if (argv[i][0] == '-' && argv[i][1] == '-') { usage(); ExitProcess(1); }
        else if (!setfile) setfile = argv[i];
        else { usage(); ExitProcess(1); }
    }
    if (argc < 0 || !setfile) { usage(); ExitProcess(1); }
    if (log) {
        HANDLE h = CreateFileW(log, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, 0, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
        if (h == INVALID_HANDLE_VALUE) {
            put("[usos-reg] ERROR cannot open the log file "); putw(log); put(" error="); putn(GetLastError()); flush();
            ExitProcess(1);
        }
        SetFilePointer(h, 0, 0, FILE_END);
        out = h;
    }
    put("[usos-reg] set file "); putw(setfile); if (dry) put(" (dry run)"); flush();
    if (!read_setfile(setfile)) ExitProcess(1);
    for (e = 0; e < nents; e++) if (ents[e].root == R_USER) want_user = 1;
    detect_wow64();
    hkcu = !hive && !is_local_system();
    if (want_user) {
        if (hive ? expand(hive, hivepath, MAX_PATH*2) : default_hive(hivepath)) {
            put("[usos-reg] default user hive "); putw(hivepath); flush();
        } else {
            hivepath[0] = 0;
            put("[usos-reg] default user hive path not resolved"); flush();
        }
        if (hkcu) { put("[usos-reg] USER entries also go to HKEY_CURRENT_USER"); flush(); }
    }
    if (wow) { put("[usos-reg] WOW64: using the 64-bit registry view"); flush(); }

    if (dry) {
        for (e = 0; e < nents; e++) {
            const struct ent *x = &ents[e];
            put("[usos-reg] DRY line "); putn(x->line); put(" "); put_target(root_label(x->root), x);
            put(" "); put(type_label(x->type));
            if (x->type == T_DWORD) { put(" "); puthex(x->dword); put(" ("); putn(x->dword); put(")"); }
            else if (x->type == T_SZ || x->type == T_EXPAND_SZ) {
                DWORD n = wlen(x->data);
                if (n > 64) { put(" ("); putn(n); put(" chars)"); }
                else { put(" \""); putw(x->data); put("\""); }
            } else if (x->type == T_BINARY) { put(" ("); putn(x->binlen); put(" bytes)"); }
            flush();
        }
        put("[usos-reg] dry run: "); putn(nents); put(" entries parsed, nothing written"); flush();
        ExitProcess(0);
    }

    if (want_user && hivepath[0]) {
        LONG r;
        if (!enable_privileges()) { put("[usos-reg] note: SeRestorePrivilege/SeBackupPrivilege not enabled"); flush(); }
        make_hive_name();
        if (GetFileAttributesW(hivepath) == 0xFFFFFFFFu) {
            put("[usos-reg] FAIL default user hive missing error="); putn(GetLastError()); flush();
        } else if ((r = RegLoadKeyW(HKEY_USERS, hivename, hivepath)) == ERROR_SUCCESS) {
            hive_loaded = 1;
            put("[usos-reg] loaded the default user hive as HKEY_USERS\\"); putw(hivename); flush();
        } else {
            put("[usos-reg] FAIL cannot load the default user hive error="); putn((DWORD)r);
            if (r == ERROR_SHARING_VIOLATION) put(" (hive in use)");
            flush();
        }
    }
    for (e = 0; e < nents; e++) {
        const struct ent *x = &ents[e];
        if (x->root == R_HKLM) report("HKLM", x, apply_one(HKEY_LOCAL_MACHINE, 0, x));
        else if (x->root == R_DEFAULT) report("DEFAULT", x, apply_one(HKEY_USERS, L".DEFAULT", x));
        else {
            report("USER", x, hive_loaded ? apply_one(HKEY_USERS, hivename, x) : ERROR_FILE_NOT_FOUND);
            if (hkcu) report("HKCU", x, apply_one(HKEY_CURRENT_USER, 0, x));
        }
    }
    if (hive_loaded) {
        HKEY k; LONG r; int tries;
        if (RegOpenKeyExW(HKEY_USERS, hivename, 0, KEY_READ | wow, &k) == ERROR_SUCCESS) {
            RegFlushKey(k);
            RegCloseKey(k);
        }
        for (tries = 0; (r = RegUnLoadKeyW(HKEY_USERS, hivename)) != ERROR_SUCCESS && tries < 10; tries++) Sleep(200);
        if (r == ERROR_SUCCESS) { put("[usos-reg] default user hive saved and unloaded"); flush(); }
        else { failcount++; put("[usos-reg] FAIL cannot unload HKEY_USERS\\"); putw(hivename); put(" error="); putn((DWORD)r); flush(); }
    }
    put("[usos-reg] done: "); putn(okcount); put(" ok, "); putn(failcount); put(" failed"); flush();
    if (out != INVALID_HANDLE_VALUE && log) { FlushFileBuffers(out); CloseHandle(out); }
    ExitProcess(failcount ? 2 : 0);
}
