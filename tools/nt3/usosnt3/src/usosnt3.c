/*
 * usosnt3.c - USOS post-install helper for Windows NT 3.51.
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
 *   usosnt3.exe [/setup]   register the usosnt3 service (GUI Setup runs this
 *                          as [GuiUnattended] !DetachedProgram)
 *   usosnt3.exe /service   the service itself (started by the SCM)
 *   usosnt3.exe /post      the post-install work by hand, no restart
 *   usosnt3.exe /polish    only the answer-profile part (accounts, automatic
 *                          logon, locale / keyboard / code pages, no Display
 *                          Settings at logon); NT 3.1 POST.CMD runs this
 *
 * NT 3.51 has no RunOnce, no CMDLINES.TXT and no REGEDIT4 import, so the
 * NT 4.0 POST.CMD + .REG files cannot be used. GUI Setup starts this
 * program early (INITIAL.INF StartDetachedProcess); it only writes the
 * Services\usosnt3 key (own-process Win32 service, automatic, LocalSystem).
 * At the first start of the installed system the service:
 *   1. copies C:\USOS\NT3\{AHCINT,USOSRST,USOSUSB}.SYS to system32\drivers
 *      (+ USOSNVME.SYS for an NVMe target, when the target script staged it);
 *   2. writes their Services keys (the values of the NT 4.0 DRIVERS.REG) and
 *      Kbdclass/Mouclass ConnectMultiplePorts = 1;
 *   3. turns atdisk, atapi and (when installed) amsint off (the real machine
 *      has no legacy IDE ports; the VM's IDE/SCSI disk is not needed any more);
 *   4. writes VERSION.TXT and DRIVERS.TXT (values read back), turns itself
 *      off (Start = 4) and writes DONE.TXT;
 *   5. applies the answer profile (polish(): ACCOUNT.TXT, INTL.TXT) and
 *      removes GraphicsDrivers\DetectDisplay;
 *   6. restarts the system (InitiateSystemShutdown, then NtShutdownSystem),
 *      which ends the install VM (-no-reboot).
 * Every step is logged to C:\USOS\NT3\POST.LOG (SETUP.LOG for /setup).
 * No C runtime; only kernel32 and advapi32 functions of NT 3.1.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#ifndef DIR
#define DIR "C:\\USOS\\NT3\\"
#endif
#define SVC_NAME "usosnt3"
#define SVC_KEY "SYSTEM\\CurrentControlSet\\Services\\"

typedef LONG (NTAPI *NT_SHUTDOWN_SYSTEM)(int Action);

static HANDLE g_log = INVALID_HANDLE_VALUE;
static SERVICE_STATUS_HANDLE g_status_handle;
static SERVICE_STATUS g_status;
static int g_post_failed;
static char g_text[4096];

static int len(const char *s)
{
    int n = 0;
    while (s[n])
        n++;
    return n;
}

static void say(const char *s)
{
    DWORD n;
    if (g_log != INVALID_HANDLE_VALUE)
        WriteFile(g_log, s, len(s), &n, NULL);
}

static char *hex(char *p, DWORD v)
{
    int i;
    for (i = 7; i >= 0; i--) {
        DWORD d = (v >> (i * 4)) & 15;
        *p++ = (char)(d < 10 ? '0' + d : 'a' + d - 10);
    }
    *p = 0;
    return p;
}

static void say_hex(const char *label, DWORD v)
{
    char b[16];
    say(label);
    hex(b, v);
    say(b);
    say("\r\n");
}

static void open_log(const char *name)
{
    char path[MAX_PATH];
    lstrcpyA(path, DIR);
    lstrcatA(path, name);
    g_log = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (g_log != INVALID_HANDLE_VALUE)
        SetFilePointer(g_log, 0, NULL, FILE_END);
}

static void write_file(const char *name, const char *text)
{
    char path[MAX_PATH];
    DWORD n;
    HANDLE h;
    lstrcpyA(path, DIR);
    lstrcatA(path, name);
    h = CreateFileA(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) {
        say("cannot write ");
        say(name);
        say("\r\n");
        return;
    }
    WriteFile(h, text, len(text), &n, NULL);
    CloseHandle(h);
}

static int write_file_checked(const char *name, const char *text)
{
    char path[MAX_PATH];
    DWORD n = 0, size = (DWORD)len(text);
    HANDLE h;
    int ok;
    lstrcpyA(path, DIR); lstrcatA(path, name);
    h = CreateFileA(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return 0;
    ok = WriteFile(h, text, size, &n, NULL) && n == size && FlushFileBuffers(h);
    if (!CloseHandle(h)) ok = 0;
    return ok;
}

/* HKLM\SYSTEM\CurrentControlSet\Services\<svc>[\<sub>] opened for writing. */
static LONG open_service_key(const char *svc, const char *sub, HKEY *h)
{
    char key[256];
    DWORD disp;
    lstrcpyA(key, SVC_KEY);
    lstrcatA(key, svc);
    if (sub) {
        lstrcatA(key, "\\");
        lstrcatA(key, sub);
    }
    return RegCreateKeyExA(HKEY_LOCAL_MACHINE, key, 0, "", REG_OPTION_NON_VOLATILE, KEY_ALL_ACCESS, NULL, h, &disp);
}

static void set_dword(const char *svc, const char *sub, const char *name, DWORD v)
{
    HKEY h;
    LONG rc = open_service_key(svc, sub, &h);
    if (rc == ERROR_SUCCESS) {
        rc = RegSetValueExA(h, name, 0, REG_DWORD, (const BYTE *)&v, sizeof v);
        RegCloseKey(h);
    }
    say(svc);
    if (sub) {
        say("\\");
        say(sub);
    }
    say(" ");
    say(name);
    say_hex(rc == ERROR_SUCCESS ? " = " : " FAILED rc ", rc == ERROR_SUCCESS ? v : (DWORD)rc);
}

static void set_sz(const char *svc, const char *name, DWORD type, const char *v)
{
    HKEY h;
    LONG rc = open_service_key(svc, NULL, &h);
    if (rc == ERROR_SUCCESS) {
        rc = RegSetValueExA(h, name, 0, type, (const BYTE *)v, len(v) + 1);
        RegCloseKey(h);
    }
    say(svc);
    say(" ");
    say(name);
    say(rc == ERROR_SUCCESS ? " = " : " FAILED: ");
    say(v);
    say("\r\n");
}

/* Appends "<name>=<value>\r\n" for a value of HKLM\<key> (string or DWORD). */
static void dump_value(char *out, const char *key, const char *name)
{
    HKEY h;
    DWORD type, size;
    BYTE data[260];
    char *p = out + len(out);

    if (p - out > (int)sizeof g_text - 400)
        return;
    lstrcpyA(p, name);
    lstrcatA(p, "=");
    p += len(p);
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, key, 0, KEY_READ, &h) != ERROR_SUCCESS) {
        lstrcpyA(p, "(no key)\r\n");
        return;
    }
    size = sizeof data - 1;
    if (RegQueryValueExA(h, name, NULL, &type, data, &size) != ERROR_SUCCESS) {
        lstrcpyA(p, "(none)\r\n");
    } else if (type == REG_DWORD) {
        *p++ = '0';
        *p++ = 'x';
        p = hex(p, *(DWORD *)data);
        lstrcpyA(p, "\r\n");
    } else if (type == REG_SZ || type == REG_EXPAND_SZ) {
        data[size] = 0;
        lstrcpyA(p, (char *)data);
        lstrcatA(p, "\r\n");
    } else if (type == REG_MULTI_SZ) {
        DWORD i;
        data[size] = 0;
        for (i = 0; i + 1 < size; i++)           /* "a\0b\0\0" -> "a,b" */
            if (!data[i] && data[i + 1]) data[i] = ',';
        lstrcpyA(p, (char *)data);
        lstrcatA(p, "\r\n");
    } else {
        lstrcpyA(p, "(other type)\r\n");
    }
    RegCloseKey(h);
}

static void enable_shutdown_privilege(void)
{
    HANDLE token;
    TOKEN_PRIVILEGES tp;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &token))
        return;
    tp.PrivilegeCount = 1;
    tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
    if (LookupPrivilegeValueA(NULL, "SeShutdownPrivilege", &tp.Privileges[0].Luid))
        AdjustTokenPrivileges(token, FALSE, &tp, 0, NULL, NULL);
    CloseHandle(token);
}

static void restart(void)
{
    NT_SHUTDOWN_SYSTEM nt_shutdown;
    HMODULE ntdll;
    enable_shutdown_privilege();
    say("restart\r\n");
    if (InitiateSystemShutdownA(NULL, NULL, 0, TRUE, TRUE))
        return;
    say_hex("InitiateSystemShutdown failed, error ", GetLastError());
    ntdll = GetModuleHandleA("ntdll.dll");
    nt_shutdown = ntdll ? (NT_SHUTDOWN_SYSTEM)GetProcAddress(ntdll, "NtShutdownSystem") : NULL;
    if (nt_shutdown != NULL)
        nt_shutdown(1);
    say("NtShutdownSystem failed\r\n");
}

/* ------------------------------------------------------------------------
 * Answer profile (docs/nt3-polish-2026-10-14.md): accounts, automatic logon,
 * locale / keyboard / code pages. nt4_csmwrap_target.sh writes
 *   ACCOUNT.TXT  user=, password=, autologon=0|1 (deleted after use: it
 *                holds the password; DefaultPassword keeps it only when the
 *                profile asks for the automatic logon, as on every Windows)
 *   INTL.TXT     locale=0000LLLL, keyboard=KKKKKKKK (hex, as in the registry)
 * Netapi and the newer kernel32 calls are looked up at run time: NT 3.1 has
 * NetLocalGroupAddMember but no GetLocaleInfoA.
 * ---------------------------------------------------------------------- */

typedef DWORD (WINAPI *NET_USER_SET_INFO)(LPCWSTR, LPCWSTR, DWORD, LPBYTE, LPDWORD);
typedef DWORD (WINAPI *NET_USER_ADD)(LPCWSTR, DWORD, LPBYTE, LPDWORD);
typedef DWORD (WINAPI *NET_LOCALGROUP_ADD_MEMBER)(LPCWSTR, LPCWSTR, PSID);
typedef int (WINAPI *GET_LOCALE_INFO_W)(LCID, DWORD, LPWSTR, int);
typedef LONG (WINAPI *REG_SET_VALUE_EX_W)(HKEY, LPCWSTR, DWORD, DWORD, const BYTE *, DWORD);

/* USER_INFO_1 (lmaccess.h). */
struct usos_user_info_1 {
    LPWSTR name, password;
    DWORD password_age, priv;
    LPWSTR home_dir, comment;
    DWORD flags;
    LPWSTR script_path;
};
#define USOS_USER_PRIV_USER 1
#define USOS_UF_SCRIPT 0x0001
#define USOS_UF_DONT_EXPIRE_PASSWD 0x10000

static void enable_privilege(const char *name)
{
    HANDLE token;
    TOKEN_PRIVILEGES tp;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &token))
        return;
    tp.PrivilegeCount = 1;
    tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
    if (LookupPrivilegeValueA(NULL, name, &tp.Privileges[0].Luid))
        AdjustTokenPrivileges(token, FALSE, &tp, 0, NULL, NULL);
    CloseHandle(token);
}

/* DIR<name> into buf (NUL-terminated); -1 when missing. */
static int read_text(const char *name, char *buf, int cap)
{
    char path[MAX_PATH];
    DWORD n = 0;
    HANDLE h;
    lstrcpyA(path, DIR);
    lstrcatA(path, name);
    h = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE)
        return -1;
    if (!ReadFile(h, buf, (DWORD)cap - 1, &n, NULL))
        n = 0;
    CloseHandle(h);
    buf[n] = 0;
    return (int)n;
}

/* Overwrites DIR<name> with zeros, then deletes it. */
static void wipe_file(const char *name, int size)
{
    char path[MAX_PATH];
    static char zero[512];
    DWORD n;
    HANDLE h;
    lstrcpyA(path, DIR);
    lstrcatA(path, name);
    h = CreateFileA(path, GENERIC_WRITE, 0, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h != INVALID_HANDLE_VALUE) {
        while (size > 0) {
            WriteFile(h, zero, size > (int)sizeof zero ? (DWORD)sizeof zero : (DWORD)size, &n, NULL);
            size -= (int)sizeof zero;
        }
        FlushFileBuffers(h);
        CloseHandle(h);
    }
    say(DeleteFileA(path) ? "deleted " : "DELETE FAILED ");
    say(name);
    say("\r\n");
}

/* The value of a "key=value" line of text ("" when absent). */
static void text_value(const char *text, const char *key, char *out, int cap)
{
    const char *p = text;
    int k = len(key), n = 0;
    out[0] = 0;
    while (*p) {
        int i = 0;
        while (i < k && p[i] && (p[i] | 32) == (key[i] | 32))
            i++;
        if (i == k && p[k] == '=') {
            p += k + 1;
            while (*p && *p != '\r' && *p != '\n' && n < cap - 1)
                out[n++] = *p++;
            out[n] = 0;
            return;
        }
        while (*p && *p != '\n')
            p++;
        if (*p)
            p++;
    }
}

static DWORD hex_value(const char *s)
{
    DWORD v = 0;
    for (; *s; s++) {
        char c = *s;
        if (c >= '0' && c <= '9')
            v = v * 16 + (DWORD)(c - '0');
        else if ((c | 32) >= 'a' && (c | 32) <= 'f')
            v = v * 16 + (DWORD)((c | 32) - 'a' + 10);
        else
            break;
    }
    return v;
}

static void dec(char *out, DWORD v)
{
    char t[12];
    int n = 0, i = 0;
    do {
        t[n++] = (char)('0' + v % 10);
        v /= 10;
    } while (v);
    while (n)
        out[i++] = t[--n];
    out[i] = 0;
}

/* <root>\<key> <name> = <v> (REG_SZ), logged (secret: value not logged). */
static void put_sz(HKEY root, const char *root_name, const char *key, const char *name, const char *v, int secret)
{
    HKEY h;
    DWORD disp;
    LONG rc = RegCreateKeyExA(root, key, 0, "", REG_OPTION_NON_VOLATILE, KEY_ALL_ACCESS, NULL, &h, &disp);
    if (rc == ERROR_SUCCESS) {
        rc = RegSetValueExA(h, name, 0, REG_SZ, (const BYTE *)v, len(v) + 1);
        RegCloseKey(h);
    }
    say(root_name);
    say("\\");
    say(key);
    say(" ");
    say(name);
    say(rc == ERROR_SUCCESS ? " = " : " FAILED: ");
    say(secret ? "(not logged)" : v);
    say("\r\n");
}

static void to_wide(const char *s, WCHAR *w, int cap)
{
    if (!MultiByteToWideChar(CP_ACP, 0, s, -1, w, cap))
        w[0] = 0;
}

/* Administrator password, an own account in Administrators, automatic logon. */
static void account(void)
{
    static const char winlogon[] = "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon";
    static WCHAR admin[] = { 'A', 'd', 'm', 'i', 'n', 'i', 's', 't', 'r', 'a', 't', 'o', 'r', 0 };
    static WCHAR admins[] = { 'A', 'd', 'm', 'i', 'n', 'i', 's', 't', 'r', 'a', 't', 'o', 'r', 's', 0 };
    char text[1024], user[64], password[128], autologon[8], domain[64];
    WCHAR wuser[64], wpassword[128];
    HMODULE net;
    NET_USER_SET_INFO set_info;
    NET_USER_ADD add;
    NET_LOCALGROUP_ADD_MEMBER add_member;
    int size = read_text("ACCOUNT.TXT", text, sizeof text);
    DWORD rc, parm, cb_sid, cb_domain;
    BYTE sid[128];
    SID_NAME_USE use;
    const char *logon_user;

    if (size < 0) {
        say(GetFileAttributesA(DIR "ACCOUNT.SET") != 0xFFFFFFFF
            ? "ACCOUNT.TXT: already applied during GUI Setup (SETUP.LOG)\r\n"
            : "ACCOUNT.TXT: none (Administrator, blank password)\r\n");
        return;
    }
    text_value(text, "user", user, sizeof user);
    text_value(text, "password", password, sizeof password);
    text_value(text, "autologon", autologon, sizeof autologon);
    wipe_file("ACCOUNT.TXT", size);
    if (lstrcmpiA(user, "Administrator") == 0 || lstrcmpiA(user, "Guest") == 0)
        user[0] = 0;
    to_wide(password, wpassword, 128);
    net = LoadLibraryA("netapi32.dll");
    set_info = net ? (NET_USER_SET_INFO)GetProcAddress(net, "NetUserSetInfo") : NULL;
    add = net ? (NET_USER_ADD)GetProcAddress(net, "NetUserAdd") : NULL;
    add_member = net ? (NET_LOCALGROUP_ADD_MEMBER)GetProcAddress(net, "NetLocalGroupAddMember") : NULL;
    if (password[0]) {
        LPWSTR info = wpassword; /* USER_INFO_1003 */
        rc = set_info ? set_info(NULL, admin, 1003, (LPBYTE)&info, &parm) : 0xFFFFFFFF;
        say_hex(rc ? "Administrator password FAILED " : "Administrator password set ", rc);
    }
    if (user[0]) {
        struct usos_user_info_1 ui;
        to_wide(user, wuser, 64);
        ui.name = wuser;
        ui.password = wpassword;
        ui.password_age = 0;
        ui.priv = USOS_USER_PRIV_USER;
        ui.home_dir = NULL;
        ui.comment = NULL;
        ui.flags = USOS_UF_SCRIPT | USOS_UF_DONT_EXPIRE_PASSWD;
        ui.script_path = NULL;
        rc = add ? add(NULL, 1, (LPBYTE)&ui, &parm) : 0xFFFFFFFF;
        say("account ");
        say(user);
        say_hex(rc ? " NetUserAdd FAILED " : " created ", rc);
        cb_sid = sizeof sid;
        cb_domain = sizeof domain;
        if (LookupAccountNameA(NULL, user, (PSID)sid, &cb_sid, domain, &cb_domain, &use)) {
            rc = add_member ? add_member(NULL, admins, (PSID)sid) : 0xFFFFFFFF;
            say_hex(rc ? "Administrators membership FAILED " : "Administrators membership ", rc);
        } else {
            say_hex("LookupAccountName FAILED ", GetLastError());
        }
    }
    logon_user = user[0] ? user : "Administrator";
    /* The logon domain: on a domain controller (ProductType LanmanNt, NT
       3.1 Advanced Server) the account domain LookupAccountName reports;
       elsewhere the computer name Setup configured (Control\ComputerName\
       ComputerName): during NT 3.1 GUI Setup the account domain is still
       "MACHINENAME" (QEMU 2026-10-14), renamed only at the next start. */
    domain[0] = 0;
    {
        HKEY h;
        DWORD type, size = sizeof domain;
        char product[32];
        DWORD psize = sizeof product;
        product[0] = 0;
        if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, "SYSTEM\\CurrentControlSet\\Control\\ProductOptions", 0, KEY_READ, &h) == ERROR_SUCCESS) {
            if (RegQueryValueExA(h, "ProductType", NULL, &type, (BYTE *)product, &psize) != ERROR_SUCCESS)
                product[0] = 0;
            RegCloseKey(h);
        }
        if (lstrcmpiA(product, "LanmanNt") == 0) {
            cb_sid = sizeof sid;
            cb_domain = sizeof domain;
            if (!LookupAccountNameA(NULL, logon_user, (PSID)sid, &cb_sid, domain, &cb_domain, &use))
                domain[0] = 0;
        } else if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, "SYSTEM\\CurrentControlSet\\Control\\ComputerName\\ComputerName", 0, KEY_READ, &h) == ERROR_SUCCESS) {
            if (RegQueryValueExA(h, "ComputerName", NULL, &type, (BYTE *)domain, &size) != ERROR_SUCCESS)
                domain[0] = 0;
            RegCloseKey(h);
        }
    }
    put_sz(HKEY_LOCAL_MACHINE, "HKLM", winlogon, "DefaultUserName", logon_user, 0);
    if (domain[0])
        put_sz(HKEY_LOCAL_MACHINE, "HKLM", winlogon, "DefaultDomainName", domain, 0);
    if (autologon[0] == '1') {
        put_sz(HKEY_LOCAL_MACHINE, "HKLM", winlogon, "DefaultPassword", password, 1);
        put_sz(HKEY_LOCAL_MACHINE, "HKLM", winlogon, "AutoAdminLogon", "1", 0);
    }
    if (net)
        FreeLibrary(net);
}

/* Code pages of a locale (the values of the NT 3.51 LANGUAGE.INF [Options]
   rows): ANSI, OEM, Mac. Locales not listed keep the CD's code pages. */
struct usos_cp {
    WORD lang;
    WORD acp, oemcp, maccp;
};
static const struct usos_cp g_cps[] = {
    { 0x0405, 1250, 852, 10029 }, { 0x040e, 1250, 852, 10029 }, { 0x0415, 1250, 852, 10029 },
    { 0x041b, 1250, 852, 10029 }, { 0x0424, 1250, 852, 10029 }, { 0x041a, 1250, 852, 10029 },
    { 0x0418, 1250, 852, 10029 }, { 0x0419, 1251, 866, 10007 }, { 0x0402, 1251, 866, 10007 },
    { 0x0408, 1253, 737, 10006 }, { 0x041f, 1254, 857, 10081 },
};

/* The ANSI code page's bitmap font names end in this letter. */
static const char *font_suffix(DWORD acp)
{
    switch (acp) {
    case 1250: return "e";
    case 1251: return "r";
    case 1253: return "g";
    case 1254: return "t";
    default: return "";
    }
}

/* system32\<file>, or for a font system\ or system32\. */
static int unpacked(const char *path);

static int sys_file(const char *file, int font)
{
    char path[MAX_PATH];
    if (!GetWindowsDirectoryA(path, MAX_PATH))
        lstrcpyA(path, "C:\\WINNT");
    lstrcatA(path, font ? "\\system\\" : "\\system32\\");
    lstrcatA(path, file);
    if (unpacked(path))
        return 1;
    if (!font)
        return 0;
    if (!GetWindowsDirectoryA(path, MAX_PATH))
        lstrcpyA(path, "C:\\WINNT");
    lstrcatA(path, "\\system32\\");
    lstrcatA(path, file);
    return unpacked(path);
}

/* The file exists and is not a packed CD copy: an MSCF cabinet or an LZ
   "SZDD" file under its real name stops the next start (STOP 0x7F with a
   packed c_1250.nls as the ANSI code page, QEMU 2026-10-14). A file that
   cannot be opened but exists is in use, so it was loaded and is real. */
static int unpacked(const char *path)
{
    char head[4];
    DWORD n = 0;
    HANDLE h = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE)
        return GetFileAttributesA(path) != 0xFFFFFFFF;
    ReadFile(h, head, 4, &n, NULL);
    CloseHandle(h);
    if (n == 4 && head[0] == 'M' && head[1] == 'S' && head[2] == 'C' && head[3] == 'F')
        return 0;
    if (n == 4 && head[0] == 'S' && head[1] == 'Z' && head[2] == 'D' && head[3] == 'D')
        return 0;
    return 1;
}

/* "<base><suffix>.fon" / "c_<cp>.nls" into out. */
static char *name3(char *out, const char *a, const char *b, const char *c)
{
    lstrcpyA(out, a);
    lstrcatA(out, b);
    lstrcatA(out, c);
    return out;
}

/* A win.ini value; NT maps these sections to the registry (IniFileMapping). */
static void ini(const char *section, const char *key, const char *value)
{
    say(WriteProfileStringA(section, key, value) ? "win.ini [" : "win.ini FAILED [");
    say(section);
    say("] ");
    say(key);
    say(" = ");
    say(value);
    say("\r\n");
}

/* Locale and keyboard of one user hive (HKU\<sub>): what the International
   applet writes (Control Panel\International: Locale and the values of the
   locale data) and Keyboard Layout\Active. The locale values are read with
   GetLocaleInfoW and stored with RegSetValueExW: GetLocaleInfoA converts
   through the locale's ANSI code page and hung the service once c_1250.nls
   had just been installed (QEMU 2026-10-14). Both are looked up at run time
   (NT 3.1's kernel32 has no GetLocaleInfoA; values are skipped without the W
   calls). */
static void intl_user(const char *sub, LCID lcid, const char *locale, const char *keyboard)
{
    static const struct { const char *name; DWORD type; } items[] = {
        { "sLanguage", 0x03 }, { "sCountry", 0x06 }, { "iCountry", 0x05 }, { "sList", 0x0C },
        { "iMeasure", 0x0D }, { "sDecimal", 0x0E }, { "sThousand", 0x0F }, { "iDigits", 0x11 },
        { "iLZero", 0x12 }, { "sCurrency", 0x14 }, { "iCurrDigits", 0x19 }, { "iCurrency", 0x1B },
        { "iNegCurr", 0x1C }, { "sDate", 0x1D }, { "sTime", 0x1E }, { "sShortDate", 0x1F },
        { "sLongDate", 0x20 }, { "iDate", 0x21 }, { "iTime", 0x23 }, { "iTLZero", 0x25 },
        { "s1159", 0x28 }, { "s2359", 0x29 },
    };
    char key[160];
    WCHAR value[96], wname[32];
    GET_LOCALE_INFO_W get = (GET_LOCALE_INFO_W)GetProcAddress(GetModuleHandleA("kernel32.dll"), "GetLocaleInfoW");
    REG_SET_VALUE_EX_W set_w = (REG_SET_VALUE_EX_W)GetProcAddress(GetModuleHandleA("advapi32.dll"), "RegSetValueExW");
    HKEY h;
    DWORD disp;
    int i, n, written = 0;
    lstrcpyA(key, sub);
    lstrcatA(key, "\\Control Panel\\International");
    put_sz(HKEY_USERS, "HKU", key, "Locale", locale, 0);
    if (get && set_w && RegCreateKeyExA(HKEY_USERS, key, 0, "", REG_OPTION_NON_VOLATILE, KEY_ALL_ACCESS, NULL, &h, &disp) == ERROR_SUCCESS) {
        for (i = 0; i < (int)(sizeof items / sizeof items[0]); i++) {
            n = get(lcid, items[i].type, value, 96);
            if (n <= 0)
                continue;
            to_wide(items[i].name, wname, 32);
            if (set_w(h, wname, 0, REG_SZ, (const BYTE *)value, (DWORD)n * sizeof(WCHAR)) == ERROR_SUCCESS)
                written++;
        }
        RegCloseKey(h);
    }
    say(key);
    say_hex(": locale values written ", (DWORD)written);
    if (keyboard[0]) {
        lstrcpyA(key, sub);
        lstrcatA(key, "\\Keyboard Layout");
        put_sz(HKEY_USERS, "HKU", key, "Active", keyboard, 0);
    }
}

/* Code pages and the bitmap fonts that match them (what LANGUAGE.INF
   InstallOption does through MakeCodePageEntry and MakeFontEntries), only
   when every file is installed: text-mode Setup of the NT 3.51 CD copies the
   CE, Cyrillic, Greek and Turkish fonts; the NT 3.5 and 3.1 CDs have none,
   there only the locale and the keyboard change. */
static void code_pages(const struct usos_cp *c)
{
    static const char nls_cp[] = "SYSTEM\\CurrentControlSet\\Control\\Nls\\CodePage";
    static const char *const bases[] = { "vgasys", "vgafix", "sserife", "coure", "serife", "smalle" };
    static const char *const oem_kinds[] = { "app", "cga40", "cga80", "ega40", "ega80" };
    static const char *const oem_keys[] = { "woafont", "CGA40WOA.FON", "CGA80WOA.FON", "EGA40WOA.FON", "EGA80WOA.FON" };
    const char *sfx = font_suffix(c->acp);
    char acp[8], oem[8], mac[8], file[32];
    int i;

    dec(acp, c->acp);
    dec(oem, c->oemcp);
    dec(mac, c->maccp);
    if (!sys_file(name3(file, "c_", acp, ".nls"), 0) || !sys_file(name3(file, "c_", oem, ".nls"), 0) ||
        !sys_file(name3(file, "vga", oem, ".fon"), 1)) {
        say("missing ");
        say(file);
        say(": code pages unchanged\r\n");
        return;
    }
    for (i = 0; i < 6; i++) {
        if (!sys_file(name3(file, bases[i], sfx, ".fon"), 1)) {
            say("missing font ");
            say(file);
            say(": code pages unchanged\r\n");
            return;
        }
    }
    put_sz(HKEY_LOCAL_MACHINE, "HKLM", nls_cp, "ACP", acp, 0);
    put_sz(HKEY_LOCAL_MACHINE, "HKLM", nls_cp, "OEMCP", oem, 0);
    put_sz(HKEY_LOCAL_MACHINE, "HKLM", nls_cp, acp, name3(file, "c_", acp, ".nls"), 0);
    put_sz(HKEY_LOCAL_MACHINE, "HKLM", nls_cp, oem, name3(file, "c_", oem, ".nls"), 0);
    if (sys_file(name3(file, "c_", mac, ".nls"), 0)) {
        put_sz(HKEY_LOCAL_MACHINE, "HKLM", nls_cp, "MACCP", mac, 0);
        put_sz(HKEY_LOCAL_MACHINE, "HKLM", nls_cp, mac, file, 0);
    }
    put_sz(HKEY_LOCAL_MACHINE, "HKLM", nls_cp, "OEMHAL", name3(file, "vga", oem, ".fon"), 0);
    ini("GRE_Initialize", "OEMFONT.FON", file);
    WritePrivateProfileStringA("boot.description", "oemfonts.fon", file, "system.ini");
    for (i = 0; i < 5; i++) {
        if (sys_file(name3(file, oem_kinds[i], oem, ".fon"), 1))
            WritePrivateProfileStringA("386Enh", oem_keys[i], file, "system.ini");
    }
    ini("GRE_Initialize", "FIXEDFON.FON", name3(file, "vgafix", sfx, ".fon"));
    ini("GRE_Initialize", "FONTS.FON", name3(file, "vgasys", sfx, ".fon"));
    ini("FontSubstitutes", "MS Shell Dlg", "MS Sans Serif");
    ini("Fonts", "MS Sans Serif 8,10,12,14,18,24 (VGA res)", name3(file, "sserife", sfx, ".fon"));
    ini("Fonts", "Courier 10,12,15 (VGA res)", name3(file, "coure", sfx, ".fon"));
    ini("Fonts", "MS Serif 8,10,12,14,18,24 (VGA res)", name3(file, "serife", sfx, ".fon"));
    ini("Fonts", "Small Fonts (VGA res)", name3(file, "smalle", sfx, ".fon"));
    /* TrueType: the tagged face names applications ask for ("Arial CE"). */
    if (c->acp == 1250 || c->acp == 1251) {
        ini("FontSubstitutes", "Arial CE", "Arial");
        ini("FontSubstitutes", "Courier New CE", "Courier New");
        ini("FontSubstitutes", "Times New Roman CE", "Times New Roman");
        ini("FontSubstitutes", "Arial CYR", "Arial");
        ini("FontSubstitutes", "Courier New CYR", "Courier New");
        ini("FontSubstitutes", "Times New Roman CYR", "Times New Roman");
    }
}

/* The files GUI Setup would copy for the locale (LANGUAGE.INF / LAYOUT.INF
   from the CD; text-mode Setup copies only the chosen keyboard layout and a
   few code pages): nt4_csmwrap_target.sh nt3_stage_intl puts the CD's
   copies in DIR\INTL under their expanded names. The NT 3.5 / 3.51 CDs
   compress with MSCF cabinets (lz32's LZCopy only copies those: QEMU
   2026-10-14, a 1510-byte c_1250.nls and STOP 0x7F at the next start), the
   NT 3.1 CD with LZ: the system's own expand.exe (system32, every NT 3.x)
   takes both; LZCopy stays as the fallback. Destination: system (fonts) or
   system32, unless the file is there already. */
typedef INT (WINAPI *LZ_OPEN_FILE_A)(LPSTR, LPOFSTRUCT, WORD);
typedef LONG (WINAPI *LZ_COPY)(INT, INT);
typedef VOID (WINAPI *LZ_CLOSE)(INT);

/* expand.exe <src> <dst>, waited for (at most a minute). */
static int run_expand(const char *src, const char *dst)
{
    char cmd[3 * MAX_PATH];
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    DWORD code = 1;
    int i;
    if (!GetSystemDirectoryA(cmd, MAX_PATH))
        lstrcpyA(cmd, "C:\\WINNT\\system32");
    lstrcatA(cmd, "\\expand.exe ");
    lstrcatA(cmd, src);
    lstrcatA(cmd, " ");
    lstrcatA(cmd, dst);
    for (i = 0; i < (int)sizeof si; i++) /* volatile: no memset (no C runtime) */
        ((volatile char *)&si)[i] = 0;
    si.cb = sizeof si;
    if (!CreateProcessA(NULL, cmd, NULL, NULL, FALSE, DETACHED_PROCESS, NULL, NULL, &si, &pi))
        return 0;
    WaitForSingleObject(pi.hProcess, 60000);
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return GetFileAttributesA(dst) != 0xFFFFFFFF;
}

/* The first bytes of a file are "MSCF" (a cabinet). */
static int is_cabinet(const char *path)
{
    char head[4];
    DWORD n = 0;
    HANDLE h = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE)
        return 0;
    ReadFile(h, head, 4, &n, NULL);
    CloseHandle(h);
    return n == 4 && head[0] == 'M' && head[1] == 'S' && head[2] == 'C' && head[3] == 'F';
}

static void install_intl_files(void)
{
    char src[MAX_PATH], dst[MAX_PATH];
    const char *base, *how;
    WIN32_FIND_DATAA fd;
    OFSTRUCT of_src, of_dst;
    HANDLE find;
    HMODULE lz = LoadLibraryA("lz32.dll");
    LZ_OPEN_FILE_A lz_open = lz ? (LZ_OPEN_FILE_A)GetProcAddress(lz, "LZOpenFileA") : NULL;
    LZ_COPY lz_copy = lz ? (LZ_COPY)GetProcAddress(lz, "LZCopy") : NULL;
    LZ_CLOSE lz_close = lz ? (LZ_CLOSE)GetProcAddress(lz, "LZClose") : NULL;
    int n = 0, i, ok;

    find = FindFirstFileA(DIR "INTL\\*", &fd);
    if (find == INVALID_HANDLE_VALUE)
        return;
    do {
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)
            continue;
        lstrcpyA(src, DIR "INTL\\");
        lstrcatA(src, fd.cFileName);
        base = fd.cFileName;
        if (!GetWindowsDirectoryA(dst, MAX_PATH))
            lstrcpyA(dst, "C:\\WINNT");
        i = len(base);
        lstrcatA(dst, i > 4 && lstrcmpiA(base + i - 4, ".fon") == 0 ? "\\system\\" : "\\system32\\");
        lstrcatA(dst, base);
        if (GetFileAttributesA(dst) != 0xFFFFFFFF)
            continue;
        how = "expand.exe";
        ok = run_expand(src, dst);
        if (!ok && !is_cabinet(src) && lz_open && lz_copy && lz_close) {
            INT a = lz_open(src, &of_src, OF_READ);
            INT b = a < 0 ? -1 : lz_open(dst, &of_dst, OF_CREATE);
            ok = a >= 0 && b >= 0 && lz_copy(a, b) >= 0;
            if (a >= 0)
                lz_close(a);
            if (b >= 0)
                lz_close(b);
            how = "LZCopy";
        }
        if (!ok)
            DeleteFileA(dst); /* never a packed file under the real name */
        say(ok ? "installed " : "INSTALL FAILED ");
        say(dst);
        say(" (");
        say(how);
        say(")\r\n");
        n += ok;
    } while (FindNextFileA(find, &fd));
    FindClose(find);
    say_hex("locale files installed: ", (DWORD)n);
}

static void intl(void)
{
    static const char nls_lang[] = "SYSTEM\\CurrentControlSet\\Control\\Nls\\Language";
    char text[256], locale[16], keyboard[16], file[32], lang[8], hive[MAX_PATH];
    LCID lcid;
    LONG rc;
    int i;

    if (read_text("INTL.TXT", text, sizeof text) < 0) {
        say("INTL.TXT: none (the CD's locale and keyboard)\r\n");
        return;
    }
    text_value(text, "locale", locale, sizeof locale);
    text_value(text, "keyboard", keyboard, sizeof keyboard);
    lcid = (LCID)hex_value(locale);
    if (len(locale) != 8 || !lcid) {
        say("INTL.TXT: no locale\r\n");
        return;
    }
    if (len(keyboard) != 8)
        keyboard[0] = 0;
    install_intl_files();
    /* The layout DLL: HKLM Keyboard Layout maps the id to it (LAYOUT.INF
       MakeLayoutEntry); text-mode Setup writes only the chosen layout, so
       the staged one (keyboard_dll=) is added. */
    if (keyboard[0]) {
        HKEY h;
        DWORD type, size = sizeof file;
        char dll[32];
        file[0] = 0;
        if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, "SYSTEM\\CurrentControlSet\\Control\\Keyboard Layout", 0, KEY_READ, &h) == ERROR_SUCCESS) {
            if (RegQueryValueExA(h, keyboard, NULL, &type, (BYTE *)file, &size) != ERROR_SUCCESS)
                file[0] = 0;
            RegCloseKey(h);
        }
        text_value(text, "keyboard_dll", dll, sizeof dll);
        if (!file[0] && dll[0] && sys_file(dll, 0)) {
            put_sz(HKEY_LOCAL_MACHINE, "HKLM", "SYSTEM\\CurrentControlSet\\Control\\Keyboard Layout", keyboard, dll, 0);
            lstrcpyA(file, dll);
        }
        if (!file[0] || !sys_file(file, 0)) {
            say("keyboard ");
            say(keyboard);
            say(" has no layout DLL here: keyboard unchanged\r\n");
            keyboard[0] = 0;
        }
    }
    for (i = 0; i < (int)(sizeof g_cps / sizeof g_cps[0]); i++)
        if (g_cps[i].lang == (WORD)lcid)
            code_pages(&g_cps[i]);
    /* System locale (MakeLanguageEntry). */
    for (i = 0; i < 4; i++)
        lang[i] = locale[4 + i];
    lang[4] = 0;
    put_sz(HKEY_LOCAL_MACHINE, "HKLM", nls_lang, "Default", lang, 0);
    if (sys_file("l_intl.nls", 0))
        put_sz(HKEY_LOCAL_MACHINE, "HKLM", nls_lang, lang, "l_intl.nls", 0);
    /* The logon desktop (.DEFAULT), then the Default User hive the way GUI
       Setup made it (INITIAL.INF SaveHive .DEFAULT -> config\UserDef):
       winlogon copies config\userdef for every new profile. Writing into a
       RegLoadKey-ed userdef did not reach the file winlogon copies (QEMU
       2026-10-14: the values stayed in userdef.LOG). The old file is kept
       as userdef.sav until the new one is saved. */
    intl_user(".DEFAULT", lcid, locale, keyboard);
    enable_privilege("SeBackupPrivilege");
    if (!GetWindowsDirectoryA(hive, MAX_PATH))
        lstrcpyA(hive, "C:\\WINNT");
    lstrcatA(hive, "\\system32\\config\\userdef");
    {
        char saved[MAX_PATH], log[MAX_PATH];
        lstrcpyA(saved, hive);
        lstrcatA(saved, ".sav");
        lstrcpyA(log, hive);
        lstrcatA(log, ".log");
        DeleteFileA(saved);
        if (!MoveFileA(hive, saved)) {
            say_hex("userdef not replaced (rename), error ", GetLastError());
            return;
        }
        {
            HKEY def;
            rc = RegOpenKeyExA(HKEY_USERS, ".DEFAULT", 0, KEY_READ, &def);
            if (rc == ERROR_SUCCESS) {
                rc = RegSaveKeyA(def, hive, NULL);
                RegCloseKey(def);
            }
        }
        if (rc == ERROR_SUCCESS) {
            DeleteFileA(saved);
            DeleteFileA(log);
            say("userdef saved from .DEFAULT\r\n");
        } else {
            DeleteFileA(hive);
            MoveFileA(saved, hive);
            say_hex("userdef save FAILED (old one kept), rc ", rc);
        }
    }
}

/* GUI Setup without its display page leaves GraphicsDrivers\DetectDisplay;
   userinit then opens "Display Settings" at every logon until the applet
   confirms a mode (NT 3.5x userinit.exe / display.cpl). */
static void display_confirmed(void)
{
    LONG rc = RegDeleteKeyA(HKEY_LOCAL_MACHINE, "SYSTEM\\CurrentControlSet\\Control\\GraphicsDrivers\\DetectDisplay");
    say_hex("GraphicsDrivers\\DetectDisplay removed, rc ", rc);
}

/* What the answer profile asks for (/service after post(); NT 3.1: /polish). */
static void polish(void)
{
    say("USOS answer profile: account, locale\r\n");
    account();
    intl();
    display_confirmed();
}

static void vesa(void);
static int net351_dword(HKEY h, const char *name, DWORD value)
{
    DWORD type, size = sizeof(DWORD), got = 0;
    return RegSetValueExA(h, name, 0, REG_DWORD, (const BYTE *)&value, sizeof value) == ERROR_SUCCESS &&
        RegQueryValueExA(h, name, NULL, &type, (BYTE *)&got, &size) == ERROR_SUCCESS &&
        type == REG_DWORD && size == sizeof(DWORD) && got == value;
}

static int net351_has_binding(HKEY h)
{
    char data[1024];
    DWORD type, size = sizeof data;
    int i = 0;
    if (RegQueryValueExA(h, "Bind", NULL, &type, (BYTE *)data, &size) != ERROR_SUCCESS ||
        type != REG_MULTI_SZ || size < 2 || size > sizeof data || data[size-1] || data[size-2]) return 0;
    while (i < (int)size-1 && data[i]) {
        if (!lstrcmpiA(data+i, "\\Device\\NDISLoop1")) return 1;
        i += len(data+i)+1;
    }
    return 0;
}

static int net351_equal_files(const char *source, const char *target)
{
    HANDLE a, b;
    char x[1024], y[1024];
    DWORD na, nb, i, total = 0;
    int equal = 0;
    a = CreateFileA(source, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    b = CreateFileA(target, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    if (a != INVALID_HANDLE_VALUE && b != INVALID_HANDLE_VALUE) {
        for (;;) {
            if (!ReadFile(a,x,sizeof x,&na,NULL) || !ReadFile(b,y,sizeof y,&nb,NULL) || na != nb) break;
            if (!na) { equal = total != 0; break; }
            for (i=0;i<na;i++) if (x[i] != y[i]) break;
            if (i != na) break;
            total += na;
        }
    }
    if (a != INVALID_HANDLE_VALUE) CloseHandle(a);
    if (b != INVALID_HANDLE_VALUE) CloseHandle(b);
    return equal;
}

/* Does the HAL have a PCI bus? NTDETECT records the PCI BIOS as a
   MultifunctionAdapter entry with Identifier "PCI"; the NT 3.x MBR hides
   the PCI BIOS on machines with more than 8 buses (the X470), and then the
   HAL has no PCI bus handler (docs/nt351-native-net-2026-10-28.md). */
static int net351_hal_pci(void)
{
    HKEY root, sub;
    char name[4], id[16];
    DWORD i, type, size;
    int found = 0;
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, "HARDWARE\\DESCRIPTION\\System\\MultifunctionAdapter", 0, KEY_READ, &root))
        return 0;
    /* subkeys 0, 1, ... (RegOpenKeyExA only: the NT 3.1 import set) */
    for (i = 0; !found && i < 10; i++) {
        name[0] = (char)('0' + i);
        name[1] = 0;
        if (RegOpenKeyExA(root, name, 0, KEY_READ, &sub)) continue;
        size = sizeof id - 1;
        if (!RegQueryValueExA(sub, "Identifier", NULL, &type, (BYTE *)id, &size) && type == REG_SZ) {
            id[size < sizeof id ? size : sizeof id - 1] = 0;
            if (!lstrcmpiA(id, "PCI")) found = 1;
        }
        RegCloseKey(sub);
    }
    RegCloseKey(root);
    return found;
}

static int nt351_network(void)
{
    static const char image[] = "\\SystemRoot\\System32\\drivers\\usosnet351.sys";
    HKEY svc = NULL, params = NULL, tcp = NULL, linkage = NULL, dhcp = NULL;
    char sys[MAX_PATH], dst[MAX_PATH], previous[MAX_PATH], got[MAX_PATH], meta[768];
    DWORD version, type, size, medium, enabled, bus_type;
    DWORD (WINAPI *get_version)(void);
    int ok = 0, meta_len;
    meta_len = read_text("NET351.ON", meta, sizeof meta);
    if (meta_len <= 0) { /* Preserve87f599: missing/empty must never enter takeover. */
        DWORD error;
        if (meta_len == 0 || GetFileAttributesA(DIR "NET351.ON") != 0xffffffff) return 0;
        error = GetLastError();
        return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND ? 1 : 0;
    }
    if (meta_len >= sizeof meta - 1) return 0;
    get_version = (DWORD (WINAPI *)(void))GetProcAddress(GetModuleHandleA("kernel32.dll"),"GetVersion");
    if (!get_version) return 0;
    version = get_version();
    if ((version & 0x80000000) || (version & 0xff) != 3 || ((version >> 8) & 0xff) != 51) {
        say("NET351 refused: actual Windows version is not3.51\r\n"); return 0;
    }
    say("NET351: configuring existing original TCP/IP DHCP binding\r\n");
    /* Only take over the exact original Ethernet LOOP binding. Missing or
       unexpected system configuration is a failure, never a new fake card. */
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE,SVC_KEY "NDISLoop",0,KEY_READ|KEY_WRITE,&svc) ||
        RegOpenKeyExA(HKEY_LOCAL_MACHINE,SVC_KEY "NDISLoop1\\Parameters",0,KEY_READ|KEY_WRITE,&params) ||
        RegOpenKeyExA(HKEY_LOCAL_MACHINE,SVC_KEY "NDISLoop1\\Parameters\\Tcpip",0,KEY_READ,&tcp) ||
        RegOpenKeyExA(HKEY_LOCAL_MACHINE,SVC_KEY "Tcpip\\Linkage",0,KEY_READ,&linkage) ||
        RegOpenKeyExA(HKEY_LOCAL_MACHINE,SVC_KEY "Dhcp",0,KEY_READ,&dhcp)) goto done;
    size=sizeof medium;
    if (RegQueryValueExA(params,"Medium",NULL,&type,(BYTE *)&medium,&size) || type!=REG_DWORD ||
        size!=sizeof medium || medium!=0) goto done;
    size=sizeof enabled;
    if (RegQueryValueExA(tcp,"EnableDHCP",NULL,&type,(BYTE *)&enabled,&size) || type!=REG_DWORD ||
        size!=sizeof enabled || enabled!=1 || !net351_has_binding(linkage)) goto done;
    size=sizeof previous-1;
    if (RegQueryValueExA(svc,"ImagePath",NULL,&type,(BYTE *)previous,&size) ||
        (type!=REG_SZ && type!=REG_EXPAND_SZ)) goto done;
    previous[size]=0;
    if (len(previous)<8 || (lstrcmpiA(previous+len(previous)-8,"loop.sys") && lstrcmpiA(previous,image))) goto done;
    if (!GetSystemDirectoryA(sys,sizeof sys) || len(sys)>MAX_PATH-32) goto done;
    lstrcpyA(dst,sys);lstrcatA(dst,"\\drivers\\usosnet351.sys");
    if (!CopyFileA(DIR "USOSNET351.SYS",dst,FALSE) || !net351_equal_files(DIR "USOSNET351.SYS",dst)) goto done;
    /* BusType 5 (PCI) with a HAL PCI bus (VM, small machines); without one
       NDIS can neither translate nor connect a PCI resource: BusType 1 (Isa,
       bus 0) maps BAR0 and takes the 8259 line, usosnet351 reads the
       configuration space through CF8h/CFCh and polls when the line is unset. */
    bus_type = net351_hal_pci() ? 5 : 1;
    say(bus_type == 5 ? "NET351: HAL PCI bus present, BusType 5\r\n" :
        "NET351: no HAL PCI bus (PCI BIOS hidden), BusType 1 + CF8h/CFCh in usosnet351\r\n");
    if (!net351_dword(params,"BusType",bus_type) || (bus_type == 1 && !net351_dword(params,"BusNumber",0)) ||
        !net351_dword(params,"PollMode",0) ||
        !net351_dword(params,"SkipPhy",0) || !net351_dword(params,"DebugPort",0) ||
        !net351_dword(svc,"Type",1) || !net351_dword(svc,"Start",2)) goto done;
    /* Commit the new image only after byte-for-byte copy and configuration
       readback. The existing NDISLoop1 TCP/IP/NetBT linkage stays intact. */
    if (RegSetValueExA(svc,"ImagePath",0,REG_EXPAND_SZ,(const BYTE *)image,sizeof image)) goto done;
    size=sizeof got;
    if (RegQueryValueExA(svc,"ImagePath",NULL,&type,(BYTE *)got,&size) ||
        type!=REG_EXPAND_SZ || size!=sizeof image || lstrcmpiA(got,image)) goto done;
    ok=1;
done:
    if (dhcp) RegCloseKey(dhcp);
    if (linkage) RegCloseKey(linkage);
    if (tcp) RegCloseKey(tcp);
    if (params) RegCloseKey(params);
    if (svc) RegCloseKey(svc);
    say(ok ? "NET351: exact staged driver copy/configuration readback verified; next boot required\r\n" :
        "NET351 FAILED: original binding or copy/configuration readback; network is unproven\r\n");
    lstrcpyA(g_text,meta);
    lstrcatA(g_text,ok ? "staged_copy_readback=match\r\nconfiguration_readback=match\r\ninstalled_runtime_pass=false\r\n" :
        "staged_copy_readback=unconfirmed\r\nconfiguration_readback=failed\r\ninstalled_runtime_pass=false\r\n");
    if (!write_file_checked("NET351.STATUS",g_text)) return 0;
    return ok ? 2 : 0; /* 1=not selected,2=verified takeover,0=refusal */
}

static int net35_decimal(const char *text, const char *key, DWORD *out)
{
    const char *p=text;
    DWORD value=0;
    int found=0, k=len(key);
    while (*p) {
        int i=0, digits=0;
        while (i<k && p[i] && (p[i]|32)==(key[i]|32)) i++;
        if (i==k && p[k]=='=') {
            if (found++) return 0;
            p+=k+1;value=0;
            while (*p>='0' && *p<='9') {
                if (++digits>3) return 0;
                value=value*10+(*p++-'0');
            }
            if (!digits || value>255 || (*p && *p!='\r' && *p!='\n')) return 0;
        }
        while (*p && *p!='\n') p++;
        if (*p) p++;
    }
    if (found!=1) return 0;
    *out=value;
    return 1;
}

static int nt35_network(void)
{
    static const char image[] = "\\SystemRoot\\System32\\drivers\\usosnet35.sys";
    HKEY svc = NULL, params = NULL, tcp = NULL, linkage = NULL, dhcp = NULL;
    char sys[MAX_PATH], dst[MAX_PATH], previous[MAX_PATH], got[MAX_PATH], meta[768];
    DWORD version, type, size, medium, enabled, bus, slot;
    DWORD (WINAPI *get_version)(void);
    int ok = 0, meta_len;
    meta_len=read_text("NET35.ON", meta, sizeof meta);
    if (meta_len<0) {
        DWORD error;
        if (GetFileAttributesA(DIR "NET35.ON") != 0xffffffff) return 0;
        error=GetLastError();
        return error==ERROR_FILE_NOT_FOUND || error==ERROR_PATH_NOT_FOUND;
    }
    if (!meta_len || meta_len>=sizeof meta-1 ||
        !net35_decimal(meta,"bus",&bus) || !net35_decimal(meta,"slot",&slot)) return 0;
    get_version = (DWORD (WINAPI *)(void))GetProcAddress(GetModuleHandleA("kernel32.dll"),"GetVersion");
    if (!get_version) return 0;
    version = get_version();
    if ((version & 0xff) != 3 || ((version >> 8) & 0xff) != 50) {
        say("NET35 refused: actual Windows version is not3.5\r\n"); return 0;
    }
    say("NET35: configuring existing original TCP/IP DHCP binding\r\n");
    /* Only take over the exact original Ethernet LOOP binding. Missing or
       unexpected system configuration is a failure, never a new fake card. */
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE,SVC_KEY "NDISLoop",0,KEY_READ|KEY_WRITE,&svc) ||
        RegOpenKeyExA(HKEY_LOCAL_MACHINE,SVC_KEY "NDISLoop1\\Parameters",0,KEY_READ|KEY_WRITE,&params) ||
        RegOpenKeyExA(HKEY_LOCAL_MACHINE,SVC_KEY "NDISLoop1\\Parameters\\Tcpip",0,KEY_READ,&tcp) ||
        RegOpenKeyExA(HKEY_LOCAL_MACHINE,SVC_KEY "Tcpip\\Linkage",0,KEY_READ,&linkage) ||
        RegOpenKeyExA(HKEY_LOCAL_MACHINE,SVC_KEY "Dhcp",0,KEY_READ,&dhcp)) goto done;
    size=sizeof medium;
    if (RegQueryValueExA(params,"Medium",NULL,&type,(BYTE *)&medium,&size) || type!=REG_DWORD ||
        size!=sizeof medium || medium!=0) goto done;
    size=sizeof enabled;
    if (RegQueryValueExA(tcp,"EnableDHCP",NULL,&type,(BYTE *)&enabled,&size) || type!=REG_DWORD ||
        size!=sizeof enabled || enabled!=1 || !net351_has_binding(linkage)) goto done;
    size=sizeof previous-1;
    if (RegQueryValueExA(svc,"ImagePath",NULL,&type,(BYTE *)previous,&size) ||
        (type!=REG_SZ && type!=REG_EXPAND_SZ)) goto done;
    previous[size]=0;
    if (len(previous)<8 || (lstrcmpiA(previous+len(previous)-8,"loop.sys") && lstrcmpiA(previous,image))) goto done;
    if (!GetSystemDirectoryA(sys,sizeof sys) || len(sys)>MAX_PATH-32) goto done;
    lstrcpyA(dst,sys);lstrcatA(dst,"\\drivers\\usosnet35.sys");
    if (!CopyFileA(DIR "USOSNET35.SYS",dst,FALSE) || !net351_equal_files(DIR "USOSNET35.SYS",dst)) goto done;
    if (!net351_dword(params,"BusType",5) || !net351_dword(params,"BusNumber",bus) ||
        !net351_dword(params,"UsosPciSlot",slot) || !net351_dword(params,"PollMode",0) ||
        !net351_dword(params,"SkipPhy",0) || !net351_dword(params,"DebugPort",0) ||
        !net351_dword(svc,"Type",1) || !net351_dword(svc,"Start",2)) goto done;
    /* Commit the new image only after byte-for-byte copy and configuration
       readback. The existing NDISLoop1 TCP/IP/NetBT linkage stays intact. */
    if (RegSetValueExA(svc,"ImagePath",0,REG_EXPAND_SZ,(const BYTE *)image,sizeof image)) goto done;
    size=sizeof got;
    if (RegQueryValueExA(svc,"ImagePath",NULL,&type,(BYTE *)got,&size) ||
        type!=REG_EXPAND_SZ || size!=sizeof image || lstrcmpiA(got,image)) goto done;
    ok=1;
done:
    if (dhcp) RegCloseKey(dhcp);
    if (linkage) RegCloseKey(linkage);
    if (tcp) RegCloseKey(tcp);
    if (params) RegCloseKey(params);
    if (svc) RegCloseKey(svc);
    say(ok ? "NET35: exact staged driver copy/configuration readback verified; next boot required\r\n" :
        "NET35 FAILED: original binding or copy/configuration readback; network is unproven\r\n");
    lstrcpyA(g_text,meta);
    lstrcatA(g_text,ok ? "staged_copy_readback=match\r\nconfiguration_readback=match\r\ninstalled_runtime_pass=false\r\n" :
        "staged_copy_readback=unconfirmed\r\nconfiguration_readback=failed\r\ninstalled_runtime_pass=false\r\n");
    write_file("NET35.STATUS",g_text);
    return ok ? 2 : 0; /* 1=not selected, 2=verified takeover, 0=refusal */
}

#include "client_prepare.h"

static void display_profile(void)
{
    /* The install VM must not select its own VBE modes for the real board.
       This separate service stays automatic until the first hardware boot. */
    if (GetFileAttributesA(DIR "DISPLAY.TXT") == 0xFFFFFFFF ||
        GetFileAttributesA(DIR "USOSRES.EXE") == 0xFFFFFFFF) return;
    set_sz("usosdisplay", "ImagePath", REG_SZ, DIR "USOSRES.EXE service");
    set_sz("usosdisplay", "DisplayName", REG_SZ, "USOS display profile");
    set_dword("usosdisplay", NULL, "Type", 0x110);
    set_dword("usosdisplay", NULL, "ErrorControl", 0);
    set_dword("usosdisplay", NULL, "Start", 2);
    say("DISPLAY hardware service registered (VM defers)\r\n");
}
static void net351_native_post(void);

static int post(void)
{
    static const char *const drivers[] = { "AHCINT", "USOSRST", "USOSUSB" };
    static const char *const keys[] = { "ahcint", "usosnvme", "usosrst", "usosusb", "atdisk", "atapi", "i8042prt",
                                        "Kbdclass", "Mouclass", "vga", "VgaSave", "amsint", "Scsidisk" };
    static const char ver[] = "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion";
    char sys[MAX_PATH], src[MAX_PATH], dst[MAX_PATH], key[128];
    int i, j, network351_state, network35_state, selected_state;

    if (!client_request()) return 0;
    say("USOS NT 3.51 post\r\n");
    if (!GetSystemDirectoryA(sys, sizeof sys))
        lstrcpyA(sys, "C:\\WINNT\\system32");
    for (i = 0; i < (int)(sizeof drivers / sizeof drivers[0]); i++) {
        lstrcpyA(src, DIR);
        lstrcatA(src, drivers[i]);
        lstrcatA(src, ".SYS");
        lstrcpyA(dst, sys);
        lstrcatA(dst, "\\drivers\\");
        j = len(dst);
        lstrcatA(dst, drivers[i]);
        lstrcatA(dst, ".sys");
        for (; dst[j]; j++)
            if (dst[j] >= 'A' && dst[j] <= 'Z')
                dst[j] = (char)(dst[j] + 32);
        say(CopyFileA(src, dst, FALSE) ? "copied " : "COPY FAILED ");
        say(dst);
        say("\r\n");
    }
    /* NVMe target (docs/nvme-nt-2026-10-11.md): usosnvme (NT351 build, PCI
       config through CF8h/CFCh) next to AHCINT, only when
       nt4_csmwrap_target.sh staged it (a SATA install never gets it). */
    lstrcpyA(src, DIR "USOSNVME.SYS");
    if (GetFileAttributesA(src) != 0xFFFFFFFF) {
        lstrcpyA(dst, sys);
        lstrcatA(dst, "\\drivers\\usosnvme.sys");
        say(CopyFileA(src, dst, FALSE) ? "copied " : "COPY FAILED ");
        say(dst);
        say("\r\n");
        set_dword("usosnvme", NULL, "Type", 1);
        set_dword("usosnvme", NULL, "Start", 0);
        set_dword("usosnvme", NULL, "ErrorControl", 1);
        set_sz("usosnvme", "Group", REG_SZ, "SCSI miniport");
    }
    /* The values of the NT 4.0 DRIVERS.REG (tools/nt4_csmwrap_target.sh). */
    set_dword("ahcint", NULL, "Type", 1);
    set_dword("ahcint", NULL, "Start", 0);
    set_dword("ahcint", NULL, "ErrorControl", 1);
    set_sz("ahcint", "Group", REG_SZ, "SCSI miniport");
    set_dword("usosrst", NULL, "Type", 1);
    set_dword("usosrst", NULL, "Start", 0);
    set_dword("usosrst", NULL, "ErrorControl", 0);
    set_sz("usosrst", "Group", REG_SZ, "System Bus Extender");
    set_dword("usosrst", "Parameters", "HpetLegacyOff", 1);
    set_dword("usosrst", "Parameters", "RtcFix", 1);
    set_dword("usosusb", NULL, "Type", 1);
    set_dword("usosusb", NULL, "Start", 1);
    set_dword("usosusb", NULL, "ErrorControl", 0);
    set_sz("usosusb", "Group", REG_SZ, "Keyboard Port");
    set_dword("Kbdclass", "Parameters", "ConnectMultiplePorts", 1);
    set_dword("Mouclass", "Parameters", "ConnectMultiplePorts", 1);
    /* IDE: the VM's disk only; the real machine boots through AHCINT. */
    set_dword("atdisk", NULL, "Start", 4);
    set_dword("atapi", NULL, "Start", 4);
    /* The disk class driver must start with AHCINT (boot): NT 3.5 Setup on
       the VM's IDE disk (atdisk) leaves Scsidisk at Start 1, and the system
       stops with 0x7B (QEMU 2026-10-09). NT 3.51 (SCSI VM disk) has 0 already. */
    set_dword("Scsidisk", NULL, "Start", 0);
    /* The install VM's SCSI adapter (QEMU am53c974 -> amsint.sys, used
       because atdisk overflows a kernel stack in QEMU): off when installed. */
    {
        HKEY h;
        if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, SVC_KEY "amsint", 0, KEY_READ, &h) == ERROR_SUCCESS) {
            RegCloseKey(h);
            set_dword("amsint", NULL, "Start", 4);
        }
    }

    g_text[0] = 0;
    dump_value(g_text, ver, "CurrentVersion");
    dump_value(g_text, ver, "CurrentBuildNumber");
    dump_value(g_text, ver, "CurrentType");
    dump_value(g_text, ver, "CSDVersion");
    dump_value(g_text, "SYSTEM\\CurrentControlSet\\Control\\Windows", "CSDVersion");
    write_file("VERSION.TXT", g_text);

    g_text[0] = 0;
    for (i = 0; i < (int)(sizeof keys / sizeof keys[0]); i++) {
        lstrcatA(g_text, "[");
        lstrcatA(g_text, keys[i]);
        lstrcatA(g_text, "]\r\n");
        lstrcpyA(key, SVC_KEY);
        lstrcatA(key, keys[i]);
        dump_value(g_text, key, "Start");
        dump_value(g_text, key, "Group");
    }
    write_file("DRIVERS.TXT", g_text);
    network351_state = nt351_network();
    network35_state = nt35_network();
    if (!network351_state || !network35_state) {
        if (g_client_requested) client_fail("selected network takeover refused");
        return 0;
    }
    selected_state = g_client_config && g_client_config->minor == 51 ? network351_state : network35_state;
    if (!client_prepare(selected_state)) return 0;
    if (network351_state == 2) net351_native_post();
    vesa();
    display_profile();
    return 1;
}

/* VESA display (docs/nt3-vesa-2026-10-14.md): usosvbe.sys (own miniport,
   NT 3.x build) + the CD's own framebuf.dll. Text-mode Setup of NT 3.5/3.51
   installs framebuf.dll ([files.video]); otherwise the CD's FRAMEBUF.DL_
   staged by nt4_csmwrap_target.sh is expanded with NT's own expand.exe.
   Without the miniport or framebuf.dll the system stays on VGA. The values
   are those of VIDEO.INF for a frame buffer driver (VgaCompatible 0) and the
   NT 4.0 VESA.REG defaults (1024x768, 16 bpp, 60 Hz). VgaStart (NT 3.51)
   is turned off like in VESA.REG; VgaSave stays: it serves full-screen
   consoles and the [VGA mode] (/basevideo) entry, where usosvbe does not
   start. */
static void vesa(void)
{
    static const WCHAR drivers[] = L"framebuf\0";
    static const char *const dwords[] = { "DefaultSettings.BitsPerPel", "DefaultSettings.XResolution",
                                          "DefaultSettings.YResolution", "DefaultSettings.VRefresh",
                                          "DefaultSettings.Interlaced", "DefaultSettings.Flags", "VgaCompatible" };
    static const DWORD values[] = { 16, 1024, 768, 60, 0, 0, 0 };
    char sys[MAX_PATH], fb[MAX_PATH], cmd[3 * MAX_PATH], dst[MAX_PATH];
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    HKEY h;
    LONG rc;
    int i;

    if (GetFileAttributesA(DIR "USOSVBE.SYS") == 0xFFFFFFFF) {
        say("vesa off: no USOSVBE.SYS, VGA stays\r\n");
        return;
    }
    if (!GetSystemDirectoryA(sys, sizeof sys))
        lstrcpyA(sys, "C:\\WINNT\\system32");
    lstrcpyA(fb, sys);
    lstrcatA(fb, "\\framebuf.dll");
    if (GetFileAttributesA(fb) == 0xFFFFFFFF && GetFileAttributesA(DIR "FRAMEBUF.DL_") != 0xFFFFFFFF) {
        lstrcpyA(cmd, sys);
        lstrcatA(cmd, "\\expand.exe " DIR "FRAMEBUF.DL_ ");
        lstrcatA(cmd, fb);
        say("run ");
        say(cmd);
        say("\r\n");
        for (i = 0; i < (int)sizeof si; i++)   /* volatile: no memset (no C runtime) */
            ((volatile char *)&si)[i] = 0;
        si.cb = sizeof si;
        if (CreateProcessA(NULL, cmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) {
            WaitForSingleObject(pi.hProcess, 60000);
            CloseHandle(pi.hThread);
            CloseHandle(pi.hProcess);
        } else {
            say_hex("CreateProcess failed, error ", GetLastError());
        }
    }
    if (GetFileAttributesA(fb) == 0xFFFFFFFF) {
        say("vesa off: no framebuf.dll, VGA stays\r\n");
        return;
    }
    lstrcpyA(dst, sys);
    lstrcatA(dst, "\\drivers\\usosvbe.sys");
    if (!CopyFileA(DIR "USOSVBE.SYS", dst, FALSE)) {
        say("vesa off: COPY FAILED ");
        say(dst);
        say("\r\n");
        return;
    }
    say("copied ");
    say(dst);
    say("\r\n");
    set_dword("usosvbe", NULL, "Type", 1);
    set_dword("usosvbe", NULL, "Start", 1);
    set_dword("usosvbe", NULL, "ErrorControl", 0);
    set_sz("usosvbe", "Group", REG_SZ, "Video");
    rc = open_service_key("usosvbe", "Device0", &h);
    if (rc == ERROR_SUCCESS) {
        rc = RegSetValueExW(h, L"InstalledDisplayDrivers", 0, REG_MULTI_SZ, (const BYTE *)drivers, sizeof drivers);
        RegCloseKey(h);
    }
    say(rc == ERROR_SUCCESS ? "usosvbe\\Device0 InstalledDisplayDrivers = framebuf\r\n"
                            : "usosvbe\\Device0 InstalledDisplayDrivers FAILED\r\n");
    for (i = 0; i < (int)(sizeof values / sizeof values[0]); i++)
        set_dword("usosvbe", "Device0", dwords[i], values[i]);
    /* NT 3.51 also has VgaStart (Group "Video Init", loads before "Video"):
       it would be \Device\Video0 and win (QEMU 2026-10-14: 640x480 with
       usosvbe registered). Off, as in the NT 4.0 VESA.REG. */
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, SVC_KEY "VgaStart", 0, KEY_READ, &h) == ERROR_SUCCESS) {
        RegCloseKey(h);
        set_dword("VgaStart", NULL, "Start", 4);
    }
    say("vesa on\r\n");
}

static int native_install(void);
static void boot_ini_finish(void);
static int pagefile_cap(void);
static void logon_notice(int on);
static void notice_start(void);
static void notice_stop(void);
static void notice_main(void);

static void WINAPI handler(DWORD control)
{
    (void)control;
    if (g_status_handle)
        SetServiceStatus(g_status_handle, &g_status);
}

static void WINAPI service_main(DWORD argc, LPSTR *argv)
{
    (void)argc;
    (void)argv;
    g_status_handle = RegisterServiceCtrlHandlerA(SVC_NAME, handler);
    g_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
    g_status.dwCurrentState = SERVICE_RUNNING;
    g_status.dwControlsAccepted = 0;
    if (g_status_handle)
        SetServiceStatus(g_status_handle, &g_status);
    open_log("POST.LOG");
    notice_start();                 /* native: the desktop notice (until the restart) */
    /* Native: before post(), so a refused post (e.g. NET351 after a GUI
       Setup network failure) still leaves /MAXMEM in BOOT.INI and the
       small pagefile (X470 2026-10-28: post refused, BOOT.INI kept Setup's
       entry without options, the next start ran on 3 GB and stopped with
       0x0A in the 3.51 system working-set list growth). */
    if (native_install()) {
        pagefile_cap();
        boot_ini_finish();
    }
    if (!post()) goto failed;
    polish();
    /* Once only: the service turns itself off before DONE.TXT. */
    if (g_client_requested) {
        if (!client_commit_installer()) goto failed;
    } else {
        set_dword(SVC_NAME, NULL, "Start", SERVICE_DISABLED);
        write_file("DONE.TXT", "done\r\n");
    }
    logon_notice(0);
    say("done\r\n");
    /* Let the other services finish starting (their failures reach the
       event log), then restart: the install VM ends there (-no-reboot). */
    Sleep(30000);
    restart();
    goto stopped;
failed:
    g_post_failed = 1;
    logon_notice(0);
    notice_stop();
    say("POST refused: no DONE/restart; inspect own local records\r\n");
    g_status.dwWin32ExitCode = ERROR_GEN_FAILURE;
stopped:
    g_status.dwCurrentState = SERVICE_STOPPED;
    if (g_status_handle)
        SetServiceStatus(g_status_handle, &g_status);
}

/* ------------------------------------------------------------------------
 * Native install (docs/nt-native-plan.md, NATIVE.TXT written by
 * nt4_csmwrap_target.sh only on the native path): no install VM, so the
 * VM flow's finish step (nt4_qemu_install.sh nt4_vm_finish) never runs on
 * this disk. usosnt3 does its two parts that matter on the PC:
 *   - usb_early(): /setup (GUI Setup) already copies usosusb.sys and writes
 *     its service, so the FIRST start of the installed system has the USB
 *     keyboard and mouse (X470 2026-10-28: the first start only had PS/2,
 *     usosusb came with post() and needed one more restart);
 *   - boot_ini_finish(): BOOT.INI as nt4_boot_ini writes it (timeout=5, no
 *     "C:\" entry for the saved syslinux boot sector, the boot options on
 *     every entry, [USOS /SOS] / [VGA mode] after the default) and the
 *     Setup leftovers on C:\ removed.
 */
static int native_install(void)
{
    return GetFileAttributesA(DIR "NATIVE.TXT") != 0xFFFFFFFF;
}

/* Reads at most size - 1 bytes of a file into buf (NUL-terminated); returns the length or -1. */
static int read_small(const char *path, char *buf, int size)
{
    HANDLE h = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    DWORD n = 0;
    if (h == INVALID_HANDLE_VALUE)
        return -1;
    if (!ReadFile(h, buf, (DWORD)size - 1, &n, NULL))
        n = 0;
    CloseHandle(h);
    buf[n] = 0;
    return (int)n;
}

/* No C runtime: an own byte copy (the compiler must not turn it into memcpy). */
static void copy_bytes(char *d, const char *s, int n)
{
    volatile char *vd = d;
    int i;
    for (i = 0; i < n; i++)
        vd[i] = s[i];
}

static char lower(char c)
{
    return (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c;
}

/* 1 when line (length n) contains the lower-case word w, case-insensitively. */
static int has_ci(const char *line, int n, const char *w)
{
    int i, k, wl = len(w);
    for (i = 0; i + wl <= n; i++) {
        for (k = 0; k < wl && lower(line[i + k]) == w[k]; k++)
            ;
        if (k == wl)
            return 1;
    }
    return 0;
}

static void usb_early(void)
{
    char sys[MAX_PATH], dst[MAX_PATH];
    if (!GetSystemDirectoryA(sys, sizeof sys))
        lstrcpyA(sys, "C:\\WINNT\\system32");
    lstrcpyA(dst, sys);
    lstrcatA(dst, "\\drivers\\usosusb.sys");
    if (!CopyFileA(DIR "USOSUSB.SYS", dst, FALSE)) {
        say_hex("usb early: COPY FAILED, error ", GetLastError());
        return;
    }
    say("usb early: copied ");
    say(dst);
    say("\r\n");
    set_dword("usosusb", NULL, "Type", 1);
    set_dword("usosusb", NULL, "Start", 1);
    set_dword("usosusb", NULL, "ErrorControl", 0);
    set_sz("usosusb", "Group", REG_SZ, "Keyboard Port");
    set_dword("Kbdclass", "Parameters", "ConnectMultiplePorts", 1);
    set_dword("Mouclass", "Parameters", "ConnectMultiplePorts", 1);
}

/* Native install: a small fixed pagefile. GUI Setup's VIRTUAL.INF
 * (DoVirtual / ConfigureVirtual -> REGISTRY.INF SetPagingFiles) sizes it
 * RAM in MiB + 12, capped at the drive's free space, near the END of GUI
 * Setup; on the X470 it saw the full RAM and filled the 2000 MiB FAT16 C:
 * with an 1816 MiB pagefile.sys. Written at /setup it would be overwritten
 * there, so the first-start service writes it: "C:\pagefile.sys 64 128"
 * (MiB; SMSS parses "<path> <min> <max>"). On the next start SMSS creates
 * the paging file again (NtCreatePagingFile opens it FILE_SUPERSEDE with the
 * minimum as allocation size), so the large file shrinks to 64 MiB.
 *
 * Every control set (X470 2026-10-29, B261029-185936 hive: the service
 * wrote 64 128 into CurrentControlSet = ControlSet001 = Select Default, the
 * next normal start's set, while the LastKnownGood copy ControlSet002 kept
 * GUI Setup's "C:\pagefile.sys 1031"; a Last Known Good start would bring
 * the large file back). The return value reports a change in the current
 * set only (setup_watch).
 */
static int pagefile_cap_at(const char *key, int current);

static int pagefile_cap(void)
{
    static const char sets[][16] = { "ControlSet001", "ControlSet002", "ControlSet003", "ControlSet004" };
    char key[128];
    int i, changed;
    changed = pagefile_cap_at("SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Memory Management", 1);
    for (i = 0; i < (int)(sizeof sets / sizeof sets[0]); i++) {
        lstrcpyA(key, "SYSTEM\\");
        lstrcatA(key, sets[i]);
        lstrcatA(key, "\\Control\\Session Manager\\Memory Management");
        pagefile_cap_at(key, 0);
    }
    return changed;
}

static int pagefile_cap_at(const char *key, int current)
{
    char sys[MAX_PATH], value[64], old[300];
    HKEY h;
    DWORD type, size = sizeof old - 2;
    LONG rc;
    int n;
    if (!GetSystemDirectoryA(sys, sizeof sys) || sys[1] != ':')
        lstrcpyA(sys, "C:");
    value[0] = sys[0];
    value[1] = 0;
    lstrcatA(value, ":\\pagefile.sys 64 128");
    n = len(value);
    value[n + 1] = 0;                   /* REG_MULTI_SZ: second NUL */
    rc = RegOpenKeyExA(HKEY_LOCAL_MACHINE, key, 0, KEY_ALL_ACCESS, &h);
    if (rc != ERROR_SUCCESS) {
        if (current)                    /* ControlSet00N: absent is normal */
            say_hex("pagefile: cannot open Memory Management, rc ", (DWORD)rc);
        return 0;
    }
    old[0] = 0;
    if (RegQueryValueExA(h, "PagingFiles", NULL, &type, (BYTE *)old, &size) == ERROR_SUCCESS)
        old[size < sizeof old - 1 ? size : sizeof old - 1] = 0;
    else
        old[0] = 0;
    if (!lstrcmpiA(old, value)) {
        if (current) {
            say("pagefile: already ");
            say(value);
            say("\r\n");
        }
    } else {
        rc = RegSetValueExA(h, "PagingFiles", 0, REG_MULTI_SZ, (const BYTE *)value, (DWORD)n + 2);
        if (!current) {
            say(key + 7);               /* "ControlSet00N\..." */
            say(": ");
        }
        say("pagefile: was \"");
        say(old);
        say(rc == ERROR_SUCCESS ? "\", now " : "\", WRITE FAILED: ");
        say(value);
        say(rc == ERROR_SUCCESS ? " (MiB, applied at the next start)\r\n" : "\r\n");
        if (rc == ERROR_SUCCESS) {
            /* the hive must hold it even if GUI Setup ends right after */
            typedef LONG (APIENTRY *REG_FLUSH_KEY)(HKEY);
            HMODULE adv = GetModuleHandleA("advapi32.dll");
            REG_FLUSH_KEY flush = adv ? (REG_FLUSH_KEY)GetProcAddress(adv, "RegFlushKey") : NULL;
            if (flush)
                flush(h);
            RegCloseKey(h);
            return 1;
        }
    }
    RegCloseKey(h);
    return 0;
}

/* Native install: a large topmost notice on the desktop while the service
 * works (X470 2026-10-29: the first desktop sat there for 1-3 minutes, then
 * the system restarted by itself). The service starts "usosnt3.exe /notice"
 * on the interactive desktop (STARTUPINFO lpDesktop WinSta0\Default; a
 * LocalSystem service may open it), detached (no console window), and
 * does not wait for it. The notice is a full-screen WS_EX_TOPMOST popup:
 * three lines of text and, below them, the last line of POST.LOG
 * (refreshed every 2 s), no buttons, no input. It ends with the restart
 * (WM_ENDSESSION) or, when post() gives up and no restart follows, by
 * TerminateProcess from the service. ASCII only, as the logon notice: the
 * first start still runs on the CD's code pages. user32 / gdi32 through
 * GetProcAddress: the static imports stay the NT 3.1 kernel32/advapi32 set. */
static struct {
    ATOM (WINAPI *RegisterClassA)(const WNDCLASSA *);
    HWND (WINAPI *CreateWindowExA)(DWORD, LPCSTR, LPCSTR, DWORD, int, int, int, int, HWND, HMENU, HINSTANCE, LPVOID);
    BOOL (WINAPI *ShowWindow)(HWND, int);
    BOOL (WINAPI *UpdateWindow)(HWND);
    BOOL (WINAPI *GetMessageA)(LPMSG, HWND, UINT, UINT);
    LRESULT (WINAPI *DispatchMessageA)(const MSG *);
    LRESULT (WINAPI *DefWindowProcA)(HWND, UINT, WPARAM, LPARAM);
    HDC (WINAPI *BeginPaint)(HWND, LPPAINTSTRUCT);
    BOOL (WINAPI *EndPaint)(HWND, const PAINTSTRUCT *);
    BOOL (WINAPI *GetClientRect)(HWND, LPRECT);
    int (WINAPI *DrawTextA)(HDC, LPCSTR, int, LPRECT, UINT);
    UINT_PTR (WINAPI *SetTimer)(HWND, UINT_PTR, UINT, TIMERPROC);
    BOOL (WINAPI *InvalidateRect)(HWND, const RECT *, BOOL);
    int (WINAPI *GetSystemMetrics)(int);
    int (WINAPI *FillRect)(HDC, const RECT *, HBRUSH);
    COLORREF (WINAPI *SetTextColor)(HDC, COLORREF);
    int (WINAPI *SetBkMode)(HDC, int);
    HFONT (WINAPI *CreateFontA)(int, int, int, int, int, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, LPCSTR);
    HGDIOBJ (WINAPI *SelectObject)(HDC, HGDIOBJ);
    HBRUSH (WINAPI *CreateSolidBrush)(COLORREF);
} g_ui;

static const char *const g_ui_names[] = {
    "RegisterClassA", "CreateWindowExA", "ShowWindow", "UpdateWindow", "GetMessageA", "DispatchMessageA",
    "DefWindowProcA", "BeginPaint", "EndPaint", "GetClientRect", "DrawTextA", "SetTimer", "InvalidateRect",
    "GetSystemMetrics", "FillRect", "SetTextColor", "SetBkMode", "CreateFontA", "SelectObject", "CreateSolidBrush",
};
#define UI_USER32_COUNT 15          /* the first 15 names are user32, the rest gdi32 */

static HANDLE g_notice_process;
static int g_notice_pl;
static char g_notice_step[160];
static HFONT g_notice_big, g_notice_text, g_notice_small;
static HBRUSH g_notice_brush;

static int notice_load(void)
{
    HMODULE user32 = LoadLibraryA("user32.dll"), gdi32 = LoadLibraryA("gdi32.dll");
    FARPROC *slot = (FARPROC *)&g_ui;
    int i;
    if (!user32 || !gdi32)
        return 0;
    for (i = 0; i < (int)(sizeof g_ui_names / sizeof g_ui_names[0]); i++) {
        slot[i] = GetProcAddress(i < UI_USER32_COUNT ? user32 : gdi32, g_ui_names[i]);
        if (!slot[i])
            return 0;
    }
    return 1;
}

/* The last complete line of POST.LOG (what the service is doing now). */
static void notice_read_step(void)
{
    static char tail[512];
    DWORD size, got = 0;
    HANDLE h;
    int end, start, i;
    h = CreateFileA(DIR "POST.LOG", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING,
                    FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE)
        return;
    size = SetFilePointer(h, 0, NULL, FILE_END);
    if (size != 0xFFFFFFFF) {
        SetFilePointer(h, size > sizeof tail ? (LONG)(size - sizeof tail) : 0, NULL, FILE_BEGIN);
        if (!ReadFile(h, tail, sizeof tail, &got, NULL))
            got = 0;
    }
    CloseHandle(h);
    end = (int)got;
    while (end > 0 && (tail[end - 1] == '\r' || tail[end - 1] == '\n'))
        end--;
    start = end;
    while (start > 0 && tail[start - 1] != '\n')
        start--;
    if (end - start >= (int)sizeof g_notice_step)
        start = end - (int)sizeof g_notice_step + 1;
    for (i = 0; start + i < end; i++) {
        char c = tail[start + i];
        g_notice_step[i] = (char)(c >= 32 && c < 127 ? c : ' ');
    }
    g_notice_step[i] = 0;
}

static void notice_line(HDC dc, RECT *area, HFONT font, int height, const char *text)
{
    RECT r = *area;
    r.bottom = r.top + height;
    g_ui.SelectObject(dc, font);
    g_ui.DrawTextA(dc, text, -1, &r, DT_CENTER | DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX);
    area->top += height;
}

static LRESULT CALLBACK notice_proc(HWND w, UINT msg, WPARAM wp, LPARAM lp)
{
    PAINTSTRUCT ps;
    RECT r;
    HDC dc;
    int h;
    switch (msg) {
    case WM_PAINT:
        dc = g_ui.BeginPaint(w, &ps);
        g_ui.GetClientRect(w, &r);
        g_ui.FillRect(dc, &r, g_notice_brush);
        g_ui.SetBkMode(dc, TRANSPARENT);
        g_ui.SetTextColor(dc, RGB(255, 255, 255));
        h = r.bottom / 8;
        r.top = r.bottom / 4;
        notice_line(dc, &r, g_notice_big, h, g_notice_pl ? "USOS konczy instalacje" : "USOS is finishing the installation");
        notice_line(dc, &r, g_notice_text, h / 2, g_notice_pl
                    ? "Trwa dogrywanie sterownikow i ustawien. Nie wylaczaj komputera."
                    : "Drivers and settings are being installed. Do not turn off the computer.");
        notice_line(dc, &r, g_notice_text, h / 2, g_notice_pl
                    ? "Komputer uruchomi sie ponownie automatycznie."
                    : "The computer will restart automatically.");
        r.top += h / 2;
        notice_line(dc, &r, g_notice_small, h / 3, g_notice_step);
        g_ui.EndPaint(w, &ps);
        return 0;
    case WM_TIMER:
        notice_read_step();
        g_ui.InvalidateRect(w, NULL, FALSE);
        return 0;
    case WM_ERASEBKGND:
        return 1;
    case WM_CLOSE:
        return 0;                   /* no way to close it: it ends with the restart */
    case WM_QUERYENDSESSION:
        return TRUE;
    case WM_ENDSESSION:
        if (wp)
            ExitProcess(0);
        return 0;
    }
    return g_ui.DefWindowProcA(w, msg, wp, lp);
}

static int notice_language_pl(void)
{
    static char intl_txt[256];
    int n = read_small(DIR "INTL.TXT", intl_txt, sizeof intl_txt);
    return n > 0 && has_ci(intl_txt, n, "locale=00000415");
}

/* usosnt3.exe /notice */
static void notice_main(void)
{
    WNDCLASSA wc;
    MSG m;
    HWND w;
    int cx, cy;
    if (!notice_load())
        ExitProcess(2);
    g_notice_pl = notice_language_pl();
    notice_read_step();
    cx = g_ui.GetSystemMetrics(SM_CXSCREEN);
    cy = g_ui.GetSystemMetrics(SM_CYSCREEN);
    g_notice_brush = g_ui.CreateSolidBrush(RGB(0, 0, 128));
    g_notice_big = g_ui.CreateFontA(-(cy / 12), 0, 0, 0, FW_BOLD, 0, 0, 0, ANSI_CHARSET, 0, 0, 0,
                                    VARIABLE_PITCH | FF_SWISS, "Arial");
    g_notice_text = g_ui.CreateFontA(-(cy / 26), 0, 0, 0, FW_NORMAL, 0, 0, 0, ANSI_CHARSET, 0, 0, 0,
                                     VARIABLE_PITCH | FF_SWISS, "Arial");
    g_notice_small = g_ui.CreateFontA(-(cy / 40), 0, 0, 0, FW_NORMAL, 0, 0, 0, ANSI_CHARSET, 0, 0, 0,
                                      FIXED_PITCH | FF_MODERN, "Courier New");
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = notice_proc;
    wc.cbClsExtra = 0;
    wc.cbWndExtra = 0;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.hIcon = NULL;
    wc.hCursor = NULL;
    wc.hbrBackground = NULL;
    wc.lpszMenuName = NULL;
    wc.lpszClassName = "UsosNt3Notice";
    if (!g_ui.RegisterClassA(&wc))
        ExitProcess(3);
    w = g_ui.CreateWindowExA(WS_EX_TOPMOST, wc.lpszClassName, "USOS", WS_POPUP | WS_VISIBLE, 0, 0, cx, cy,
                             NULL, NULL, wc.hInstance, NULL);
    if (!w)
        ExitProcess(4);
    g_ui.ShowWindow(w, SW_SHOW);
    g_ui.UpdateWindow(w);
    g_ui.SetTimer(w, 1, 2000, NULL);
    while (g_ui.GetMessageA(&m, NULL, 0, 0) > 0)
        g_ui.DispatchMessageA(&m);
    ExitProcess(0);
}

/* Service side: start the notice, never wait for it. */
static void notice_start(void)
{
    typedef DWORD (WINAPI *GET_MODULE_FILE_NAME)(HMODULE, LPSTR, DWORD);
    GET_MODULE_FILE_NAME get_name =
        (GET_MODULE_FILE_NAME)GetProcAddress(GetModuleHandleA("kernel32.dll"), "GetModuleFileNameA");
    static char exe[MAX_PATH], cmd[MAX_PATH + 16];
    static char desktop[] = "WinSta0\\Default";
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    char *p;
    if (!native_install() || !get_name || !get_name(NULL, exe, MAX_PATH))
        return;
    lstrcpyA(cmd, "\"");
    lstrcatA(cmd, exe);
    lstrcatA(cmd, "\" /notice");
    for (p = (char *)&si; p < (char *)&si + sizeof si; p++)
        *p = 0;
    si.cb = sizeof si;
    si.lpDesktop = desktop;
    if (CreateProcessA(exe, cmd, NULL, NULL, FALSE, DETACHED_PROCESS, NULL, NULL, &si, &pi)) {
        g_notice_process = pi.hProcess;
        CloseHandle(pi.hThread);
        say("notice: on the desktop\r\n");
    } else {
        say_hex("notice: CreateProcess failed, error ", GetLastError());
    }
}

/* post() gave up: no restart follows, so the notice must not stay. */
static void notice_stop(void)
{
    typedef BOOL (WINAPI *TERMINATE_PROCESS)(HANDLE, UINT);
    TERMINATE_PROCESS terminate =
        (TERMINATE_PROCESS)GetProcAddress(GetModuleHandleA("kernel32.dll"), "TerminateProcess");
    if (g_notice_process && terminate)
        terminate(g_notice_process, 0);
    if (g_notice_process)
        CloseHandle(g_notice_process);
    g_notice_process = NULL;
}

/* Native install: a logon screen notice while the first-start service is
 * still working (X470 2026-10-29: the logon screen refused the profile's
 * user until post() had run, then the system restarted by itself).
 * Winlogon shows LegalNoticeCaption / LegalNoticeText before the logon
 * dialog (NT 3.5 WINLOGON\LOGON.C GetLegalNotices; both values exist,
 * empty, in the installed 3.51 SOFTWARE hive). Set at /setup, emptied by
 * the service when it finishes or gives up. ASCII only: the first start
 * still runs on the CD's code pages (intl() switches them in post()). */
static void logon_notice(int on)
{
    static const char winlogon[] = "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon";
    static char intl_txt[256];
    int n, pl;
    if (!native_install())
        return;
    n = read_small(DIR "INTL.TXT", intl_txt, sizeof intl_txt);
    pl = n > 0 && has_ci(intl_txt, n, "locale=00000415");
    put_sz(HKEY_LOCAL_MACHINE, "HKLM", winlogon, "LegalNoticeCaption",
           !on ? "" : pl ? "USOS konczy instalacje" : "USOS is finishing the installation", 0);
    put_sz(HKEY_LOCAL_MACHINE, "HKLM", winlogon, "LegalNoticeText",
           !on ? "" : pl ? "Poczekaj na automatyczny restart (okolo 1-2 minuty). Po restarcie zaloguj sie."
                       : "Wait for the automatic restart (about 1-2 minutes), then log on.", 0);
}

/* Native install, /setup: GUI Setup's virtual_config (INITIAL.INF ->
 * VIRTUAL.INF ConfigureVirtual -> REGISTRY.INF SetPagingFiles) writes
 * PagingFiles = "C:\pagefile.sys <RAM in MiB + 12>" near its end; SMSS then
 * allocated an 1814 MiB file on the 2000 MiB FAT16 C: at the first start
 * (X470 2026-10-28, prime suspect for the first-start STOP 0x0A). This
 * process stays alive beside GUI Setup, watches the Memory Management key
 * (RegNotifyChangeKeyValue, through GetProcAddress; 5 s polling without
 * it) and puts "C:\pagefile.sys 64 128" back, flushed, every time someone
 * else changes PagingFiles. The service's pagefile_cap() stays the
 * fallback. The same INITIAL.INF runs SetAccountDomainSid and
 * setuplocalaccount (WaitOnEvent SAM_SERVICE_STARTED,
 * ChangeLocalUserPassword Administrator) before virtual_config, so once
 * Setup's own PagingFiles write is seen the SAM is final: account() runs
 * then, and the first logon screen already knows the profile's user and
 * password. GUI Setup's restart ends this process. */
static void setup_watch(void)
{
    static const char key[] = "SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Memory Management";
    typedef LONG (APIENTRY *REG_NOTIFY)(HKEY, BOOL, DWORD, HANDLE, BOOL);
    HMODULE adv = GetModuleHandleA("advapi32.dll");
    REG_NOTIFY notify = adv ? (REG_NOTIFY)GetProcAddress(adv, "RegNotifyChangeKeyValue") : NULL;
    HKEY h = NULL;
    int first = 1, account_done = 0;
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, key, 0, KEY_NOTIFY | KEY_QUERY_VALUE, &h) != ERROR_SUCCESS)
        h = NULL;
    say(notify && h ? "pagefile watch: RegNotifyChangeKeyValue\r\n" : "pagefile watch: polling every 5 s\r\n");
    for (;;) {
        if (pagefile_cap() && !first && !account_done) {
            /* GUI Setup itself wrote PagingFiles: virtual_config ran */
            say("pagefile watch: GUI Setup wrote PagingFiles, answer-profile account now\r\n");
            account();
            write_file("ACCOUNT.SET", "done\r\n");
            account_done = 1;
        }
        first = 0;
        if (notify && h) {
            if (notify(h, FALSE, REG_NOTIFY_CHANGE_LAST_SET, NULL, FALSE) != ERROR_SUCCESS)
                notify = NULL;
        } else {
            Sleep(5000);
        }
    }
}

/* X470 2026-10-29 (B261029-185936): GUI Setup wrote "C:\pagefile.sys 1031"
 * and the first start's service still found it: the watch, started only
 * after setup()'s 20 s BOOT.INI wait, did not run before GUI Setup's
 * PagingFiles write (the service redid the BOOT.INI step too). The watch
 * now runs in its own thread from the start of /setup; the BOOT.INI step
 * keeps its wait on the main thread. CreateThread through GetProcAddress
 * as dhcp_setup_hold_start. */
static int g_watch_thread;

static DWORD WINAPI setup_watch_main(LPVOID unused)
{
    (void)unused;
    setup_watch();
    return 0;
}

static void setup_watch_start(void)
{
    typedef HANDLE (WINAPI *WATCH_CREATE)(LPSECURITY_ATTRIBUTES, DWORD, LPTHREAD_START_ROUTINE, LPVOID, DWORD, LPDWORD);
    WATCH_CREATE create = (WATCH_CREATE)GetProcAddress(GetModuleHandleA("kernel32.dll"), "CreateThread");
    DWORD id;
    HANDLE t = create ? create(NULL, 0, setup_watch_main, NULL, 0, &id) : NULL;
    if (t) {
        CloseHandle(t);
        g_watch_thread = 1;
        say("pagefile watch thread started\r\n");
    } else {
        say("pagefile watch: CreateThread failed, runs after the BOOT.INI step\r\n");
    }
}

/* ------------------------------------------------------------------------
 * Native NT 3.51 LAN (NET351.ON), GUI Setup: no DHCP wait.
 * OEMNXPTC.INF sets EnableDHCPFlag = 1 whenever STF_GUI_UNATTENDED is YES
 * and creates the DHCP client (services.exe share service, automatic,
 * group "TDI"). NTLANMAN.INF then starts the network with NCPA STARTSVC
 * LanmanWorkstation, which depends on the TDI group; the SCM starts every
 * member of a group a service depends on (not only automatic ones) and
 * treats the group as not started while a member is START_PENDING
 * (NT 3.5 SC\SERVER\DEPEND.C ScGetCurrentGroupState). The DHCP client
 * stays START_PENDING through its first lease attempt (CLIENT\NEWNT\DHCP.C:
 * DhcpInitialize before SERVICE_RUNNING, wait hint 25 s), and the only
 * adapter during GUI Setup is the MS Loopback adapter, which never gets an
 * answer. A disabled member fails at once (ERROR_SERVICE_DISABLED) and the
 * group counts as started through NetBT / Afd. So while GUI Setup runs,
 * this thread waits for the DHCP service to exist and disables it through
 * the SCM (its database record, not only the registry: the service was
 * created in this boot); post() turns it back on for the boot that runs
 * usosnet351 (EnableDHCP of the adapter is untouched). ChangeServiceConfigA
 * has the NT 3.5 (11 argument) form: only called on 3.51. */
typedef SC_HANDLE (WINAPI *SCM_OPEN)(LPCSTR, LPCSTR, DWORD);
typedef SC_HANDLE (WINAPI *SVC_OPEN)(SC_HANDLE, LPCSTR, DWORD);
typedef BOOL (WINAPI *SVC_CHANGE)(SC_HANDLE, DWORD, DWORD, DWORD, LPCSTR, LPCSTR, LPDWORD, LPCSTR, LPCSTR, LPCSTR, LPCSTR);
typedef BOOL (WINAPI *SVC_CLOSE)(SC_HANDLE);
typedef HANDLE (WINAPI *THREAD_CREATE)(LPSECURITY_ATTRIBUTES, DWORD, LPTHREAD_START_ROUTINE, LPVOID, DWORD, LPDWORD);

static int net351_version(void)
{
    DWORD (WINAPI *get_version)(void) =
        (DWORD (WINAPI *)(void))GetProcAddress(GetModuleHandleA("kernel32.dll"), "GetVersion");
    DWORD v;
    if (!get_version) return 0;
    v = get_version();
    return !(v & 0x80000000) && (v & 0xff) == 3 && ((v >> 8) & 0xff) == 51;
}

static int net351_native_selected(void)
{
    return native_install() && GetFileAttributesA(DIR "NET351.ON") != 0xFFFFFFFF && net351_version();
}

static DWORD WINAPI dhcp_setup_hold(LPVOID unused)
{
    HMODULE adv = GetModuleHandleA("advapi32.dll");
    SCM_OPEN scm_open = adv ? (SCM_OPEN)GetProcAddress(adv, "OpenSCManagerA") : NULL;
    SVC_OPEN svc_open = adv ? (SVC_OPEN)GetProcAddress(adv, "OpenServiceA") : NULL;
    SVC_CHANGE svc_change = adv ? (SVC_CHANGE)GetProcAddress(adv, "ChangeServiceConfigA") : NULL;
    SVC_CLOSE svc_close = adv ? (SVC_CLOSE)GetProcAddress(adv, "CloseServiceHandle") : NULL;
    DWORD i, error = 0, last = 0;
    (void)unused;
    if (!scm_open || !svc_open || !svc_change || !svc_close) {
        say("dhcp hold: no SCM functions\r\n");
        return 0;
    }
    /* 500 ms steps, at most 3 h; GUI Setup's restart ends the process. */
    for (i = 0; i < 21600; i++) {
        SC_HANDLE scm = scm_open(NULL, NULL, SC_MANAGER_CONNECT), svc = NULL;
        int ok = 0;
        if (scm) {
            svc = svc_open(scm, "DHCP", SERVICE_CHANGE_CONFIG);
            if (svc) {
                ok = svc_change(svc, SERVICE_NO_CHANGE, SERVICE_DISABLED, SERVICE_NO_CHANGE,
                                NULL, NULL, NULL, NULL, NULL, NULL, NULL) != 0;
                if (!ok) error = GetLastError();
                svc_close(svc);
            } else {
                error = GetLastError();
            }
            svc_close(scm);
        } else {
            error = GetLastError();
        }
        if (ok) {
            say("dhcp hold: DHCP client disabled for GUI Setup (no lease wait on the Loopback adapter)\r\n");
            write_file_checked("DHCP.OFF", "dhcp=disabled during GUI Setup\r\nrestore=post\r\n");
            return 0;
        }
        if (error != last) {
            say_hex("dhcp hold: waiting for the DHCP service, error ", error);
            last = error;
        }
        Sleep(500);
    }
    return 0;
}

static void dhcp_setup_hold_start(void)
{
    THREAD_CREATE create = (THREAD_CREATE)GetProcAddress(GetModuleHandleA("kernel32.dll"), "CreateThread");
    DWORD id;
    HANDLE t;
    if (!net351_native_selected()) return;
    t = create ? create(NULL, 0, dhcp_setup_hold, NULL, 0, &id) : NULL;
    if (t) {
        CloseHandle(t);
        say("dhcp hold: watching for the DHCP service\r\n");
    } else {
        say("dhcp hold: CreateThread failed\r\n");
    }
}

/* post(), after a verified NET351 takeover on the native path: the DHCP
 * client automatic again (the next boot runs usosnet351, lease in ~11 s
 * on the X470 2026-10-29) and the one-shot connectivity check registered
 * (usosnetc, USOSNT3.EXE /netcheck -> NETCHECK.TXT). Registry only: post()
 * restarts the system right after. */
static void net351_native_post(void)
{
    HKEY h;
    DWORD start = 0, type, size = sizeof start;
    if (!native_install()) return;
    /* EnableDHCP 1 is required by the takeover: the client is automatic
       (GUI Setup's own value) whether or not the hold above caught it. */
    set_dword("DHCP", NULL, "Start", SERVICE_AUTO_START);
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, SVC_KEY "DHCP", 0, KEY_READ, &h) == ERROR_SUCCESS) {
        if (RegQueryValueExA(h, "Start", NULL, &type, (BYTE *)&start, &size) || type != REG_DWORD) start = 0;
        RegCloseKey(h);
    }
    say(start == SERVICE_AUTO_START ? "NET351: DHCP client automatic again (readback)\r\n"
                                    : "NET351: DHCP client Start readback FAILED\r\n");
    set_sz("usosnetc", "ImagePath", REG_EXPAND_SZ, DIR "USOSNT3.EXE /netcheck");
    set_sz("usosnetc", "ObjectName", REG_SZ, "LocalSystem");
    set_sz("usosnetc", "DisplayName", REG_SZ, "USOS network check");
    set_dword("usosnetc", NULL, "Type", SERVICE_WIN32_OWN_PROCESS);
    set_dword("usosnetc", NULL, "ErrorControl", SERVICE_ERROR_IGNORE);
    set_dword("usosnetc", NULL, "Start", SERVICE_AUTO_START);
}

/* ------------------------------------------------------------------------
 * usosnetc (USOSNT3.EXE /netcheck): one silent record of the first boot
 * with usosnet351. Waits up to 120 s for the DHCP lease of NDISLoop1
 * (Parameters\Tcpip DhcpIPAddress, the NT 3.5 DHCP client's value names),
 * writes the lease values and the usosnet351 alive record, then an ICMP
 * echo to the DHCP gateway (icmp.dll IcmpSendEcho) and a TCP connect to
 * 1.1.1.1:80 (wsock32), both through LoadLibrary / GetProcAddress, to
 * C:\USOS\NT3\NETCHECK.TXT and turns itself off. */
#define NC_TCP SVC_KEY "NDISLoop1\\Parameters\\Tcpip"
typedef HANDLE (WINAPI *ICMP_CREATE)(void);
typedef DWORD (WINAPI *ICMP_SEND)(HANDLE, DWORD, LPVOID, WORD, LPVOID, LPVOID, DWORD, DWORD);
typedef BOOL (WINAPI *ICMP_CLOSE)(HANDLE);
typedef int (WINAPI *WSA_STARTUP)(WORD, LPVOID);
typedef int (WINAPI *WSA_CLEANUP)(void);
typedef int (WINAPI *WSA_ERROR)(void);
typedef UINT_PTR (WINAPI *WS_SOCKET)(int, int, int);
typedef int (WINAPI *WS_CONNECT)(UINT_PTR, const void *, int);
typedef int (WINAPI *WS_CLOSE)(UINT_PTR);

static SERVICE_STATUS_HANDLE g_nc_handle;
static SERVICE_STATUS g_nc_status;
static BYTE g_nc_buf[1024];

/* Dotted quad -> IPv4 in network byte order (in_addr layout); 0 if not one. */
static DWORD nc_ipv4(const char *s)
{
    DWORD v = 0, part;
    int i, digits;
    for (i = 0; i < 4; i++) {
        part = 0;
        digits = 0;
        while (*s >= '0' && *s <= '9' && digits < 3) {
            part = part * 10 + (DWORD)(*s++ - '0');
            digits++;
        }
        if (!digits || part > 255) return 0;
        v |= part << (8 * i);
        if (i < 3) {
            if (*s != '.') return 0;
            s++;
        }
    }
    return (*s == 0 || *s == ',' || *s == '\r') ? v : 0;
}

/* HKLM\<key> <name> as text ("" when missing); REG_MULTI_SZ: first string. */
static void nc_value(const char *key, const char *name, char *out, DWORD cap)
{
    HKEY h;
    DWORD type, size = cap - 1;
    out[0] = 0;
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, key, 0, KEY_READ, &h) != ERROR_SUCCESS) return;
    if (RegQueryValueExA(h, name, NULL, &type, (BYTE *)out, &size) != ERROR_SUCCESS ||
        (type != REG_SZ && type != REG_MULTI_SZ && type != REG_EXPAND_SZ))
        size = 0;
    out[size < cap ? size : cap - 1] = 0;
    RegCloseKey(h);
}

static void nc_line(const char *a, const char *b)
{
    if (len(g_text) + len(a) + len(b) + 3 >= (int)sizeof g_text) return;
    lstrcatA(g_text, a);
    lstrcatA(g_text, b);
    lstrcatA(g_text, "\r\n");
}

static void nc_line_dec(const char *a, DWORD v)
{
    char b[12];
    dec(b, v);
    nc_line(a, b);
}

static void nc_ping(DWORD addr)
{
    HMODULE icmp = LoadLibraryA("icmp.dll");
    ICMP_CREATE create = icmp ? (ICMP_CREATE)GetProcAddress(icmp, "IcmpCreateFile") : NULL;
    ICMP_SEND echo = icmp ? (ICMP_SEND)GetProcAddress(icmp, "IcmpSendEcho") : NULL;
    ICMP_CLOSE icmp_close = icmp ? (ICMP_CLOSE)GetProcAddress(icmp, "IcmpCloseHandle") : NULL;
    static char data[32] = "USOS netcheck";
    HANDLE h;
    int i, ok = 0;
    if (!create || !echo || !icmp_close) {
        nc_line("gateway_ping=", "unavailable (icmp.dll)");
        if (icmp) FreeLibrary(icmp);
        return;
    }
    h = create();
    if (h == INVALID_HANDLE_VALUE || !h) {
        nc_line_dec("gateway_ping=failed IcmpCreateFile error ", GetLastError());
        FreeLibrary(icmp);
        return;
    }
    for (i = 0; i < 3 && !ok; i++) {
        /* ICMP_ECHO_REPLY: Address, Status, RoundTripTime, ... */
        DWORD n = echo(h, addr, data, sizeof data, NULL, g_nc_buf, sizeof g_nc_buf, 2000);
        if (n && ((DWORD *)g_nc_buf)[1] == 0) {
            ok = 1;
            nc_line_dec("gateway_ping=ok rtt_ms=", ((DWORD *)g_nc_buf)[2]);
        }
    }
    if (!ok) nc_line_dec("gateway_ping=failed status ", ((DWORD *)g_nc_buf)[1]);
    icmp_close(h);
    FreeLibrary(icmp);
}

static void nc_tcp(const char *label, DWORD addr, WORD port)
{
    HMODULE ws = LoadLibraryA("wsock32.dll");
    WSA_STARTUP startup = ws ? (WSA_STARTUP)GetProcAddress(ws, "WSAStartup") : NULL;
    WSA_CLEANUP cleanup = ws ? (WSA_CLEANUP)GetProcAddress(ws, "WSACleanup") : NULL;
    WSA_ERROR error = ws ? (WSA_ERROR)GetProcAddress(ws, "WSAGetLastError") : NULL;
    WS_SOCKET ws_socket = ws ? (WS_SOCKET)GetProcAddress(ws, "socket") : NULL;
    WS_CONNECT ws_connect = ws ? (WS_CONNECT)GetProcAddress(ws, "connect") : NULL;
    WS_CLOSE ws_close = ws ? (WS_CLOSE)GetProcAddress(ws, "closesocket") : NULL;
    BYTE sa[16];
    UINT_PTR s;
    int i;
    if (!startup || !cleanup || !error || !ws_socket || !ws_connect || !ws_close) {
        nc_line(label, "unavailable (wsock32.dll)");
        if (ws) FreeLibrary(ws);
        return;
    }
    if (startup(0x0101, g_nc_buf)) {
        nc_line(label, "failed WSAStartup");
        FreeLibrary(ws);
        return;
    }
    s = ws_socket(2, 1, 6);                  /* AF_INET, SOCK_STREAM, IPPROTO_TCP */
    if (s == (UINT_PTR)~0) {
        nc_line(label, "failed socket");
    } else {
        for (i = 0; i < (int)sizeof sa; i++) ((volatile BYTE *)sa)[i] = 0;
        sa[0] = 2;                           /* sin_family AF_INET */
        sa[2] = (BYTE)(port >> 8);           /* sin_port, network order */
        sa[3] = (BYTE)port;
        *(DWORD *)(sa + 4) = addr;
        if (ws_connect(s, sa, sizeof sa) == 0) {
            nc_line(label, "ok");
        } else {
            char b[48];
            lstrcpyA(b, "failed WSA error ");
            dec(b + len(b), (DWORD)error());
            nc_line(label, b);
        }
        ws_close(s);
    }
    cleanup();
    FreeLibrary(ws);
}

static void netcheck(void)
{
    static const char params[] = SVC_KEY "NDISLoop1\\Parameters";
    static const char *const alive[] = { "UsosnetAliveSec", "UsosnetAliveRx", "UsosnetAliveTx",
                                         "UsosnetAliveFlags", "UsosnetAliveRxErr", "UsosnetAliveTxErr",
                                         "UsosnetBcPoint", "UsosnetBcError" };
    char ip[64], gw[128];
    DWORD waited = 0, gateway;
    int i;
    lstrcpyA(g_text, "USOS NT 3.51 network check\r\nstate=waiting for the DHCP lease\r\n");
    write_file_checked("NETCHECK.TXT", g_text);
    for (;;) {
        nc_value(NC_TCP, "DhcpIPAddress", ip, sizeof ip);
        if ((ip[0] && lstrcmpA(ip, "0.0.0.0")) || waited >= 120) break;
        Sleep(2000);
        waited += 2;
    }
    lstrcpyA(g_text, "USOS NT 3.51 network check\r\n");
    nc_line("lease=", ip[0] && lstrcmpA(ip, "0.0.0.0") ? "yes" : "no");
    nc_line_dec("waited_s=", waited);
    dump_value(g_text, NC_TCP, "EnableDHCP");
    dump_value(g_text, NC_TCP, "DhcpIPAddress");
    dump_value(g_text, NC_TCP, "DhcpSubnetMask");
    dump_value(g_text, NC_TCP, "DhcpDefaultGateway");
    dump_value(g_text, NC_TCP, "DhcpServer");
    dump_value(g_text, NC_TCP, "Lease");
    dump_value(g_text, NC_TCP, "LeaseObtainedTime");
    dump_value(g_text, NC_TCP, "LeaseTerminatesTime");
    dump_value(g_text, SVC_KEY "Tcpip\\Parameters", "DhcpNameServer");
    dump_value(g_text, SVC_KEY "DHCP", "Start");
    for (i = 0; i < (int)(sizeof alive / sizeof alive[0]); i++)
        dump_value(g_text, params, alive[i]);
    write_file_checked("NETCHECK.TXT", g_text);
    if (ip[0] && lstrcmpA(ip, "0.0.0.0")) {
        nc_value(NC_TCP, "DhcpDefaultGateway", gw, sizeof gw);
        gateway = nc_ipv4(gw);
        if (gateway) nc_ping(gateway);
        else nc_line("gateway_ping=", "no gateway");
        nc_tcp("tcp_1.1.1.1_80=", 0x01010101, 80);
    } else {
        nc_line("gateway_ping=", "skipped (no lease)");
        nc_line("tcp_1.1.1.1_80=", "skipped (no lease)");
    }
    nc_line("done=", "1");
    write_file_checked("NETCHECK.TXT", g_text);
}

static void WINAPI netcheck_handler(DWORD control)
{
    (void)control;
    if (g_nc_handle)
        SetServiceStatus(g_nc_handle, &g_nc_status);
}

static void WINAPI netcheck_main(DWORD argc, LPSTR *argv)
{
    (void)argc;
    (void)argv;
    g_nc_handle = RegisterServiceCtrlHandlerA("usosnetc", netcheck_handler);
    g_nc_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
    g_nc_status.dwCurrentState = SERVICE_RUNNING;
    g_nc_status.dwControlsAccepted = 0;
    if (g_nc_handle)
        SetServiceStatus(g_nc_handle, &g_nc_status);
    netcheck();
    /* one record only: the service turns itself off */
    {
        HKEY h;
        DWORD off = SERVICE_DISABLED;
        if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, SVC_KEY "usosnetc", 0, KEY_WRITE, &h) == ERROR_SUCCESS) {
            RegSetValueExA(h, "Start", 0, REG_DWORD, (const BYTE *)&off, sizeof off);
            RegCloseKey(h);
        }
    }
    g_nc_status.dwCurrentState = SERVICE_STOPPED;
    if (g_nc_handle)
        SetServiceStatus(g_nc_handle, &g_nc_status);
}

/* The boot options from NATIVE.TXT ("boot_options=/NUMPROC=2 /MAXMEM=1024"). */
static void native_options(char *opts, int size)
{
    static char buf[512];
    int i, n = read_small(DIR "NATIVE.TXT", buf, sizeof buf), o = 0;
    opts[0] = 0;
    for (i = 0; i < n; i++) {
        if ((i == 0 || buf[i - 1] == '\n') && i + 13 <= n && has_ci(buf + i, 13, "boot_options=")) {
            i += 13;
            while (i < n && buf[i] != '\r' && buf[i] != '\n' && o < size - 1)
                opts[o++] = buf[i++];
            opts[o] = 0;
            return;
        }
    }
}

static void out_add(char *out, int *o, int size, const char *s, int n)
{
    int i;
    for (i = 0; i < n && *o < size - 1; i++)
        out[(*o)++] = s[i];
    out[*o] = 0;
}

/* Removes " /MAXMEM=<digits>" (any case) from line[0..*n). */
static void drop_maxmem(char *line, int *n)
{
    int i, j;
    for (i = 0; i + 8 <= *n; i++) {
        if (line[i] == '/' && has_ci(line + i, 8, "/maxmem=")) {
            int s = i, e = i + 8;
            while (s > 0 && (line[s - 1] == ' ' || line[s - 1] == '\t'))
                s--;
            while (e < *n && line[e] >= '0' && line[e] <= '9')
                e++;
            for (j = 0; e + j < *n; j++)
                line[s + j] = line[e + j];
            *n -= e - s;
            i = s - 1;
        }
    }
}

static void boot_ini_finish(void)
{
    static char in[8192], out[12288], line[600];
    char opts[200];
    int n, i = 0, o = 0, sos = 0, vga = 0, first_end = -1;
    int arc_len = 0, desc_s = 0, desc_l = 0;
    char arc_line[600];
    const char *ini = "C:\\BOOT.INI";
    static const char *const leftovers[] = {
        "C:\\BOOTSECT.DOS", "C:\\LDLINUX.SYS", "C:\\LDLINUX.C32", "C:\\SYSLINUX.CFG", "C:\\CHAIN.C32",
        "C:\\LIBCOM32.C32", "C:\\LIBUTIL.C32", "C:\\$LDR$", "C:\\TXTSETUP.SIF", "C:\\WINNT.SIF"
    };
    DWORD attr, w;
    HANDLE h;

    native_options(opts, sizeof opts);
    n = read_small(ini, in, sizeof in);
    if (n <= 0) {
        say("boot.ini: cannot read C:\\BOOT.INI\r\n");
        return;
    }
    if (has_ci(in, n, "[usos /sos]")) {
        say("boot.ini: already finished\r\n");
    } else {
        while (i < n) {
            int l = 0, t = 0;
            while (i < n && in[i] != '\n') {
                if (in[i] != '\r' && l < (int)sizeof line - 200)
                    line[l++] = in[i];
                i++;
            }
            if (i < n)
                i++;
            while (t < l && (line[t] == ' ' || line[t] == '\t'))
                t++;
            if (l - t >= 7 && has_ci(line + t, 7, "timeout") && has_ci(line + t, l - t, "=")) {
                lstrcpyA(line, "timeout=5");
                l = 9;
            } else if (l - t >= 3 && lower(line[t]) == 'c' && line[t + 1] == ':' && line[t + 2] == '\\') {
                int k = t + 3;
                while (k < l && (line[k] == ' ' || line[k] == '\t'))
                    k++;
                if (k < l && line[k] == '=')
                    continue;           /* the "C:\" entry: Setup's copy of the syslinux boot sector */
            } else if (l - t >= 6 && has_ci(line + t, 6, "multi(")) {
                if (has_ci(line, l, "/basevideo"))
                    vga = 1;
                else if (has_ci(line, l, "/sos"))
                    sos = 1;
                else if (first_end < 0) {
                    int p, q;
                    for (p = 0; p + 1 < l && !(line[p] == '=' && line[p + 1] == '"'); p++)
                        ;
                    for (q = p + 2; q < l && line[q] != '"'; q++)
                        ;
                    if (p + 1 < l && q < l) {
                        arc_len = p;
                        desc_s = p + 2;
                        desc_l = q - desc_s;
                        copy_bytes(arc_line, line, l);
                        first_end = 1;
                    }
                }
                if (!has_ci(line, l, "/numproc")) {
                    drop_maxmem(line, &l);
                    while (l > 0 && (line[l - 1] == ' ' || line[l - 1] == '\t'))
                        l--;
                    if (opts[0]) {
                        line[l++] = ' ';
                        copy_bytes(line + l, opts, len(opts));
                        l += len(opts);
                    }
                }
                out_add(out, &o, sizeof out, line, l);
                out_add(out, &o, sizeof out, "\r\n", 2);
                if (first_end == 1) {
                    first_end = o;      /* the extra entries go right after this line */
                }
                continue;
            }
            out_add(out, &o, sizeof out, line, l);
            out_add(out, &o, sizeof out, "\r\n", 2);
        }
        if (first_end > 0 && (!sos || !vga)) {
            static char extra[1400], tail[12288];
            int e = 0, tl = o - first_end;
            copy_bytes(tail, out + first_end, tl);
            if (!sos) {
                out_add(extra, &e, sizeof extra, arc_line, arc_len);
                out_add(extra, &e, sizeof extra, "=\"", 2);
                out_add(extra, &e, sizeof extra, arc_line + desc_s, desc_l);
                out_add(extra, &e, sizeof extra, " [USOS /SOS]\" /SOS", 18);
                if (opts[0]) {
                    out_add(extra, &e, sizeof extra, " ", 1);
                    out_add(extra, &e, sizeof extra, opts, len(opts));
                }
                out_add(extra, &e, sizeof extra, "\r\n", 2);
            }
            if (!vga) {
                out_add(extra, &e, sizeof extra, arc_line, arc_len);
                out_add(extra, &e, sizeof extra, "=\"", 2);
                out_add(extra, &e, sizeof extra, arc_line + desc_s, desc_l);
                out_add(extra, &e, sizeof extra, " [VGA mode]\" /basevideo /sos", 28);
                if (opts[0]) {
                    out_add(extra, &e, sizeof extra, " ", 1);
                    out_add(extra, &e, sizeof extra, opts, len(opts));
                }
                out_add(extra, &e, sizeof extra, "\r\n", 2);
            }
            o = first_end;
            out_add(out, &o, sizeof out, extra, e);
            out_add(out, &o, sizeof out, tail, tl);
        }
        attr = GetFileAttributesA(ini);
        SetFileAttributesA(ini, FILE_ATTRIBUTE_NORMAL);
        h = CreateFileA(ini, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (h != INVALID_HANDLE_VALUE && WriteFile(h, out, (DWORD)o, &w, NULL) && w == (DWORD)o &&
            FlushFileBuffers(h)) {
            say("boot.ini: timeout=5, no C:\\ entry, options ");
            say(opts[0] ? opts : "(none)");
            say("\r\n");
        } else {
            say_hex("boot.ini: WRITE FAILED, error ", GetLastError());
        }
        if (h != INVALID_HANDLE_VALUE)
            CloseHandle(h);
        if (attr != 0xFFFFFFFF)
            SetFileAttributesA(ini, attr);
    }
    for (i = 0; i < (int)(sizeof leftovers / sizeof leftovers[0]); i++) {
        if (GetFileAttributesA(leftovers[i]) == 0xFFFFFFFF)
            continue;
        SetFileAttributesA(leftovers[i], FILE_ATTRIBUTE_NORMAL);
        say(DeleteFileA(leftovers[i]) ? "removed " : "CANNOT REMOVE ");
        say(leftovers[i]);
        say("\r\n");
    }
}

static void setup(void)
{
    char image[MAX_PATH];
    open_log("SETUP.LOG");
    say("USOS NT 3.51 setup: registering the usosnt3 service\r\n");
    if (native_install()) {
        usb_early();
        dhcp_setup_hold_start();
    }
    lstrcpyA(image, DIR);
    lstrcatA(image, "USOSNT3.EXE /service");
    set_dword(SVC_NAME, NULL, "Type", SERVICE_WIN32_OWN_PROCESS);
    set_dword(SVC_NAME, NULL, "Start", SERVICE_AUTO_START);
    set_dword(SVC_NAME, NULL, "ErrorControl", SERVICE_ERROR_IGNORE);
    set_sz(SVC_NAME, "ImagePath", REG_EXPAND_SZ, image);
    set_sz(SVC_NAME, "ObjectName", REG_SZ, "LocalSystem");
    set_sz(SVC_NAME, "DisplayName", REG_SZ, "USOS post-install");
    /* Native install (docs/nt-native-plan.md): the GUI Setup page recorder
       (tools/nt3/usosans3) runs next to GUI Setup on its desktop and logs
       every page to C:\USOS\NT3\USOSANS.TXT. Only when the target script
       staged it (native NT 3.5x); the install VM never gets the file. */
    if (GetFileAttributesA(DIR "USOSANS3.EXE") != 0xFFFFFFFF) {
        STARTUPINFOA si;
        PROCESS_INFORMATION pi;
        char cmd[MAX_PATH];
        int i;
        lstrcpyA(cmd, DIR "USOSANS3.EXE");
        for (i = 0; i < (int)sizeof si; i++)   /* volatile: no memset (no C runtime) */
            ((volatile char *)&si)[i] = 0;
        si.cb = sizeof si;
        if (CreateProcessA(NULL, cmd, NULL, NULL, FALSE, DETACHED_PROCESS, NULL, NULL, &si, &pi)) {
            CloseHandle(pi.hThread);
            CloseHandle(pi.hProcess);
            say("page recorder USOSANS3.EXE started\r\n");
        } else {
            say_hex("page recorder: CreateProcess failed, error ", GetLastError());
        }
    }
    /* Native: BOOT.INI with the boot options (/MAXMEM) from the first start
       of the installed system on, not only after the service's post()
       (X470 2026-10-28). INITIAL.INF runs "ChangeBootIniTimeout 30" right
       after it starts this DetachedProgram, so wait for that rewrite first;
       the service repeats the step if this one is lost ("[USOS /SOS]"). */
    if (native_install()) {
        logon_notice(1);
        setup_watch_start();
        Sleep(20000);
        boot_ini_finish();
        say("boot.ini step done\r\n");
        if (!g_watch_thread)
            setup_watch();
        for (;;)                        /* the watch thread runs until GUI Setup restarts */
            Sleep(60000);
    }
}

/* The first argument without its leading / or -, lower case, at most 15
   characters ("" when there is none). */
static void first_option(const char *p, char *out)
{
    int n = 0;
    if (*p == '"') {
        p++;
        while (*p && *p != '"')
            p++;
        if (*p == '"')
            p++;
    } else {
        while (*p && *p != ' ' && *p != '\t')
            p++;
    }
    while (*p == ' ' || *p == '\t')
        p++;
    if (*p == '/' || *p == '-')
        p++;
    while (*p && *p != ' ' && *p != '\t' && n < 15) {
        char c = *p++;
        out[n++] = (char)(c >= 'A' && c <= 'Z' ? c + 32 : c);
    }
    out[n] = 0;
}

void __stdcall entry(void)
{
    static SERVICE_TABLE_ENTRYA table[] = { { SVC_NAME, service_main }, { NULL, NULL } };
    static SERVICE_TABLE_ENTRYA netcheck_table[] = { { "usosnetc", netcheck_main }, { NULL, NULL } };
    char opt[16];

    first_option(GetCommandLineA(), opt);
    if (lstrcmpA(opt, "service") == 0) {
        if (!StartServiceCtrlDispatcherA(table)) {
            open_log("POST.LOG");
            say_hex("StartServiceCtrlDispatcher failed, error ", GetLastError());
            ExitProcess(2);
        }
        ExitProcess(g_post_failed ? 3 : 0);
    }
    /* usosnetc: the first boot with usosnet351 (net351_native_post) */
    if (lstrcmpA(opt, "netcheck") == 0) {
        if (!StartServiceCtrlDispatcherA(netcheck_table))
            netcheck();             /* by hand: the same record without the SCM */
        ExitProcess(0);
    }
    /* the desktop notice the service starts on a native install */
    if (lstrcmpA(opt, "notice") == 0)
        notice_main();
    if (lstrcmpA(opt, "post") == 0) {
        open_log("POST.LOG");
        ExitProcess(post() ? 0 : 3);
    }
    /* By hand on a native install that predates the early USB / BOOT.INI
       steps: what /setup and the service add on the native path. */
    if (lstrcmpA(opt, "finish") == 0) {
        open_log("POST.LOG");
        say("USOS native finish (by hand)\r\n");
        if (!native_install()) {
            say("no NATIVE.TXT: not a native install, nothing done\r\n");
            ExitProcess(3);
        }
        usb_early();
        pagefile_cap();
        boot_ini_finish();
        say("finish done\r\n");
        ExitProcess(0);
    }
    /* NT 3.1: POST.CMD at the end of GUI Setup (no usosnt3 service there). */
    if (lstrcmpA(opt, "polish") == 0) {
        open_log("POST.LOG");
        polish();
        ExitProcess(0);
    }
    /* "/setup" or nothing: what GUI Setup runs ([GuiUnattended] !DetachedProgram). */
    setup();
    ExitProcess(0);
}
