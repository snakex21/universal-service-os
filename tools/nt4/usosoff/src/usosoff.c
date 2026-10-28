/*
 * usosoff.c - reboot / shut down / power off Windows NT 4.0 from a script.
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
 *   usosoff.exe [/r | /s | /p]
 *
 * /r (default) reboots, /s shuts down, /p powers off; always forced.
 * Enables SeShutdownPrivilege, calls ExitWindowsEx and falls back to
 * ntdll!NtShutdownSystem. Exit code 0 on success, 1 on a bad argument,
 * 2 when both calls fail. No C runtime; imports only kernel32, advapi32
 * and user32 functions present in NT 4.0 RTM.
 */
#include <windows.h>

typedef LONG (NTAPI *NT_SHUTDOWN_SYSTEM)(int Action);

#define SHUTDOWN_NO_REBOOT 0
#define SHUTDOWN_REBOOT    1
#define SHUTDOWN_POWER_OFF 2

static void say(const char *s)
{
    DWORD n = 0, len = 0;
    HANDLE h = GetStdHandle(STD_OUTPUT_HANDLE);
    while (s[len])
        len++;
    if (h != NULL && h != INVALID_HANDLE_VALUE)
        WriteFile(h, s, len, &n, NULL);
}

static void enable_shutdown_privilege(void)
{
    HANDLE token;
    TOKEN_PRIVILEGES tp;

    if (!OpenProcessToken(GetCurrentProcess(),
                          TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &token))
        return;
    tp.PrivilegeCount = 1;
    tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
    if (LookupPrivilegeValueA(NULL, "SeShutdownPrivilege",
                              &tp.Privileges[0].Luid))
        AdjustTokenPrivileges(token, FALSE, &tp, 0, NULL, NULL);
    CloseHandle(token);
}

/* Returns 'r', 's', 'p', or 0 for an unknown argument. */
static char parse_mode(const char *p)
{
    char c;

    /* skip the program name (quoted or not) */
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
    if (*p == 0)
        return 'r';
    if (*p != '/' && *p != '-')
        return 0;
    c = p[1] | 0x20;
    if (c != 'r' && c != 's' && c != 'p')
        return 0;
    if (p[2] != 0 && p[2] != ' ' && p[2] != '\t')
        return 0;
    return c;
}

void __stdcall entry(void)
{
    UINT flags;
    int action;
    NT_SHUTDOWN_SYSTEM nt_shutdown;
    HMODULE ntdll;
    char mode = parse_mode(GetCommandLineA());

    switch (mode) {
    case 'r': flags = EWX_REBOOT;   action = SHUTDOWN_REBOOT;    break;
    case 's': flags = EWX_SHUTDOWN; action = SHUTDOWN_NO_REBOOT; break;
    case 'p': flags = EWX_POWEROFF; action = SHUTDOWN_POWER_OFF; break;
    default:
        say("usage: usosoff [/r | /s | /p]\r\n");
        ExitProcess(1);
    }

    enable_shutdown_privilege();
    if (ExitWindowsEx(flags | EWX_FORCE, 0))
        ExitProcess(0);

    ntdll = GetModuleHandleA("ntdll.dll");
    nt_shutdown = ntdll ? (NT_SHUTDOWN_SYSTEM)GetProcAddress(ntdll, "NtShutdownSystem") : NULL;
    if (nt_shutdown != NULL && nt_shutdown(action) >= 0)
        ExitProcess(0);

    say("usosoff: ExitWindowsEx and NtShutdownSystem failed\r\n");
    ExitProcess(2);
}
