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
 *   5. restarts the system (InitiateSystemShutdown, then NtShutdownSystem),
 *      which ends the install VM (-no-reboot).
 * Every step is logged to C:\USOS\NT3\POST.LOG (SETUP.LOG for /setup).
 * No C runtime; only kernel32 and advapi32 functions of NT 3.1.
 */
#include <windows.h>

#define DIR "C:\\USOS\\NT3\\"
#define SVC_NAME "usosnt3"
#define SVC_KEY "SYSTEM\\CurrentControlSet\\Services\\"

typedef LONG (NTAPI *NT_SHUTDOWN_SYSTEM)(int Action);

static HANDLE g_log = INVALID_HANDLE_VALUE;
static SERVICE_STATUS_HANDLE g_status_handle;
static SERVICE_STATUS g_status;
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

static void vesa(void);
static void post(void)
{
    static const char *const drivers[] = { "AHCINT", "USOSRST", "USOSUSB" };
    static const char *const keys[] = { "ahcint", "usosnvme", "usosrst", "usosusb", "atdisk", "atapi", "i8042prt",
                                        "Kbdclass", "Mouclass", "vga", "VgaSave", "amsint", "Scsidisk" };
    static const char ver[] = "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion";
    char sys[MAX_PATH], src[MAX_PATH], dst[MAX_PATH], key[128];
    int i, j;

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
    vesa();
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
    post();
    /* Once only: the service turns itself off before DONE.TXT. */
    set_dword(SVC_NAME, NULL, "Start", SERVICE_DISABLED);
    write_file("DONE.TXT", "done\r\n");
    say("done\r\n");
    /* Let the other services finish starting (their failures reach the
       event log), then restart: the install VM ends there (-no-reboot). */
    Sleep(30000);
    restart();
    g_status.dwCurrentState = SERVICE_STOPPED;
    if (g_status_handle)
        SetServiceStatus(g_status_handle, &g_status);
}

static void setup(void)
{
    char image[MAX_PATH];
    open_log("SETUP.LOG");
    say("USOS NT 3.51 setup: registering the usosnt3 service\r\n");
    lstrcpyA(image, DIR);
    lstrcatA(image, "USOSNT3.EXE /service");
    set_dword(SVC_NAME, NULL, "Type", SERVICE_WIN32_OWN_PROCESS);
    set_dword(SVC_NAME, NULL, "Start", SERVICE_AUTO_START);
    set_dword(SVC_NAME, NULL, "ErrorControl", SERVICE_ERROR_IGNORE);
    set_sz(SVC_NAME, "ImagePath", REG_EXPAND_SZ, image);
    set_sz(SVC_NAME, "ObjectName", REG_SZ, "LocalSystem");
    set_sz(SVC_NAME, "DisplayName", REG_SZ, "USOS post-install");
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
    char opt[16];

    first_option(GetCommandLineA(), opt);
    if (lstrcmpA(opt, "service") == 0) {
        if (!StartServiceCtrlDispatcherA(table)) {
            open_log("POST.LOG");
            say_hex("StartServiceCtrlDispatcher failed, error ", GetLastError());
            ExitProcess(2);
        }
        ExitProcess(0);
    }
    if (lstrcmpA(opt, "post") == 0) {
        open_log("POST.LOG");
        post();
        ExitProcess(0);
    }
    /* "/setup" or nothing: what GUI Setup runs ([GuiUnattended] !DetachedProgram). */
    setup();
    ExitProcess(0);
}
