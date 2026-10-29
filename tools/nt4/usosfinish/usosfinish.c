/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 USOS Authors
 * Reuse USOS's own BOOT.INI/USB/pagefile routines, not its NT3 service.
 * Native NT4 only. CMDLINES /early, POST.CMD /finish. No host execution.
 */
#define DIR "C:\\USOS\\NT4\\"
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
static int boot_valid(void);
static BOOL WINAPI finish_delete(LPCSTR path);
#define DeleteFileA finish_delete
#define entry unused_nt3_entry
#include "../../nt3/usosnt3/src/usosnt3.c"
#undef entry
#undef DeleteFileA

static int boot_valid(void)
{
    static char text[8192];
    int n = read_small("C:\\BOOT.INI", text, sizeof(text));
    return n>0 && has_ci(text,n,"timeout=5") && has_ci(text,n,"[usos /sos]") &&
        has_ci(text,n,"[vga mode]") && !has_ci(text,n,"c:\\\\=");
}

static BOOL WINAPI finish_delete(LPCSTR path)
{
    /* BOOT.INI must be durable and valid before the reused routine removes
     * its fixed syslinux/Setup leftovers. No source deletion on write error. */
    return boot_valid() ? DeleteFileA(path) : FALSE;
}

static int erase_tree(const char *path, int depth)
{
    WIN32_FIND_DATAA fd;
    HANDLE find;
    char pattern[MAX_PATH], child[MAX_PATH];
    int ok = 1;
    if (depth > 24 || len(path) > MAX_PATH - 4) return 0;
    if (GetFileAttributesA(path) == INVALID_FILE_ATTRIBUTES) return GetLastError() == ERROR_FILE_NOT_FOUND;
    if (GetFileAttributesA(path) & 0x400) return 0; /* never traverse a reparse point */
    lstrcpyA(pattern, path); lstrcatA(pattern, "\\*");
    find = FindFirstFileA(pattern, &fd);
    if (find == INVALID_HANDLE_VALUE) return 0;
    do {
        if (!lstrcmpA(fd.cFileName, ".") || !lstrcmpA(fd.cFileName, "..")) continue;
        if (len(path) + len(fd.cFileName) + 2 >= MAX_PATH || fd.dwFileAttributes & 0x400) { ok = 0; break; }
        lstrcpyA(child, path); lstrcatA(child, "\\"); lstrcatA(child, fd.cFileName);
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            if (!erase_tree(child, depth + 1)) ok = 0;
        } else {
            SetFileAttributesA(child, FILE_ATTRIBUTE_NORMAL);
            if (!DeleteFileA(child)) ok = 0;
        }
    } while (FindNextFileA(find, &fd));
    if (GetLastError() != ERROR_NO_MORE_FILES) ok = 0;
    FindClose(find);
    return ok && RemoveDirectoryA(path);
}

void __stdcall entry(void)
{
    OSVERSIONINFOA os;
    char opt[16];
    int ok, i;
    for (i = 0; i < sizeof(os); i++) ((volatile char *)&os)[i] = 0;
    os.dwOSVersionInfoSize = sizeof(os);
    if (!GetVersionExA(&os) || os.dwPlatformId != VER_PLATFORM_WIN32_NT || os.dwMajorVersion != 4 || os.dwMinorVersion != 0)
        ExitProcess(3);
    if (!native_install()) ExitProcess(3);
    first_option(GetCommandLineA(), opt);
    open_log("NATIVE.LOG");
    if (!lstrcmpA(opt, "early")) {
        usb_early();
        {
            char system[MAX_PATH];
            if (!GetSystemDirectoryA(system, sizeof(system))) ExitProcess(3);
            lstrcatA(system, "\\drivers\\usosusb.sys");
            if (!CopyFileA(DIR "USOSUSB.SYS", system, FALSE)) ExitProcess(3);
        }
        say("native NT4: USB registered before first installed-system boot\r\n");
        ExitProcess(0);
    }
    if (lstrcmpA(opt, "finish")) ExitProcess(3);
    /* Do not remove the source until POST.CMD has completed its copies/SP. */
    if (GetFileAttributesA(DIR "POST.OK") == INVALID_FILE_ATTRIBUTES) ExitProcess(3);
    if (!CopyFileA("C:\\BOOT.INI", DIR "BOOT.OLD", TRUE) && GetLastError() != ERROR_FILE_EXISTS) ExitProcess(3);
    pagefile_cap();
    boot_ini_finish();
    if (!boot_valid()) { say("BOOT.INI validation FAILED; source retained\r\n"); ExitProcess(3); }
    ok = erase_tree("C:\\$WIN_NT$.~BT", 0);
    if (!erase_tree("C:\\$WIN_NT$.~LS", 0)) ok = 0;
    say(ok ? "native finish complete\r\n" : "native finish cleanup FAILED\r\n");
    if (g_log != INVALID_HANDLE_VALUE) { FlushFileBuffers(g_log); CloseHandle(g_log); }
    ExitProcess(ok ? 0 : 3);
}
