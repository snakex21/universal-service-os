/*
 * NVTEST.EXE - Windows 9x data check for the usosnvme.mpd QEMU tests
 * (tools/tests/run_w9x_nvme_qemu.py). Test asset only, never on the stick.
 *
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Started as the Windows shell (SYSTEM.INI [boot] shell=), so it runs in a
 * plain protected-mode Windows session without Explorer or the first-run
 * wizard. For the drive given on the command line (default: the first fixed
 * drive after C:), it writes NVT\Fnn.BIN files of fixed sizes filled by a
 * per-file generator (the host recomputes it, run_w9x_nvme_qemu.py), flushes,
 * reads every file back and compares, then optionally runs ScanDisk on the
 * drive and shuts Windows down. Every line also goes to port E9h (QEMU
 * -debugcon) and to C:\NVTEST.LOG.
 *
 * Built with the WDK 7.1 compiler, no C runtime, kernel32 + user32 imports
 * that Windows 95 has.
 */
#include <windows.h>

#define NV_FILES 12
static const DWORD g_sizes[NV_FILES] = {
    512, 4096, 4608, 65536, 131072, 131584, 200704, 1048576 + 4096,
    4194304, 8388608 + 512, 16777216, 33554432
};

static HANDLE g_log = INVALID_HANDLE_VALUE;
static BYTE g_buf[262144];
static BYTE g_rd[262144];

static DWORD Len(const char *s) { DWORD n = 0; while (s[n]) n++; return n; }

static void E9(const char *s)
{
    while (*s) {
        char c = *s++;
        __asm {
            mov al, c
            out 0E9h, al
        }
    }
}

static void Out(const char *s)
{
    DWORD w;
    E9(s);
    if (g_log != INVALID_HANDLE_VALUE) WriteFile(g_log, s, Len(s), &w, NULL);
}

static char *Cat(char *d, const char *s) { while (*s) *d++ = *s++; *d = 0; return d; }

static char *Dec(char *d, DWORD v)
{
    char t[12];
    int n = 0;
    do { t[n++] = (char)('0' + v % 10); v /= 10; } while (v);
    while (n) *d++ = t[--n];
    *d = 0;
    return d;
}

static char *Hex(char *d, DWORD v)
{
    static const char h[] = "0123456789ABCDEF";
    int i;
    for (i = 7; i >= 0; i--) *d++ = h[(v >> (i * 4)) & 15];
    *d = 0;
    return d;
}

/* xorshift32, seeded per file: (index + 1) * 0x9E3779B9 */
static DWORD g_x;
static void Seed(DWORD idx) { g_x = (idx + 1) * 0x9E3779B9UL; if (!g_x) g_x = 1; }
static DWORD Next(void) { g_x ^= g_x << 13; g_x ^= g_x >> 17; g_x ^= g_x << 5; return g_x; }

static void Fill(BYTE *p, DWORD n)
{
    DWORD i, v;
    for (i = 0; i + 4 <= n; i += 4) { v = Next(); p[i] = (BYTE)v; p[i + 1] = (BYTE)(v >> 8); p[i + 2] = (BYTE)(v >> 16); p[i + 3] = (BYTE)(v >> 24); }
}

static void Name(char *d, char drive, DWORD idx)
{
    d[0] = drive; d[1] = ':'; d[2] = '\\';
    d = Cat(d + 3, "NVT\\F");
    *d++ = (char)('0' + idx / 10);
    *d++ = (char)('0' + idx % 10);
    Cat(d, ".BIN");
}

static int WriteAll(char drive, DWORD *bytes)
{
    DWORD i, left, n, w;
    char path[64], line[160], *p;
    HANDLE h;

    path[0] = drive; path[1] = ':'; path[2] = '\\';
    Cat(path + 3, "NVT");
    CreateDirectoryA(path, NULL);
    for (i = 0; i < NV_FILES; i++) {
        Name(path, drive, i);
        h = CreateFileA(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (h == INVALID_HANDLE_VALUE) {
            p = Cat(line, "NVTEST create failed "); p = Cat(p, path); p = Cat(p, " err "); p = Dec(p, GetLastError()); Cat(p, "\r\n");
            Out(line);
            return 0;
        }
        Seed(i);
        left = g_sizes[i];
        while (left) {
            /* odd chunk sizes so the requests are not all page sized */
            n = left < 196608 + 512 ? left : 196608 + 512;
            Fill(g_buf, n);
            if (!WriteFile(h, g_buf, n, &w, NULL) || w != n) {
                CloseHandle(h);
                p = Cat(line, "NVTEST write failed "); p = Cat(p, path); Cat(p, "\r\n");
                Out(line);
                return 0;
            }
            left -= n;
            *bytes += n;
        }
        FlushFileBuffers(h);
        CloseHandle(h);
    }
    return 1;
}

static int CompareAll(char drive, DWORD *bytes)
{
    DWORD i, left, n, r, j;
    char path[64], line[160], *p;
    HANDLE h;
    int ok = 1;

    for (i = 0; i < NV_FILES; i++) {
        Name(path, drive, i);
        h = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
        if (h == INVALID_HANDLE_VALUE) {
            p = Cat(line, "NVTEST open failed "); p = Cat(p, path); Cat(p, "\r\n");
            Out(line);
            return 0;
        }
        if (GetFileSize(h, NULL) != g_sizes[i]) ok = 0;
        Seed(i);
        left = g_sizes[i];
        while (left) {
            n = left < 196608 + 512 ? left : 196608 + 512;
            Fill(g_buf, n);
            if (!ReadFile(h, g_rd, n, &r, NULL) || r != n) { ok = 0; break; }
            for (j = 0; j < n; j++) if (g_rd[j] != g_buf[j]) break;
            if (j != n) {
                p = Cat(line, "NVTEST MISMATCH "); p = Cat(p, path); p = Cat(p, " at ");
                p = Dec(p, g_sizes[i] - left + j); Cat(p, "\r\n");
                Out(line);
                ok = 0;
                break;
            }
            left -= n;
            *bytes += n;
        }
        CloseHandle(h);
        if (!ok) return 0;
    }
    return ok;
}

static void Scandisk(char drive)
{
    char cmd[96], line[96], *p;
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    DWORD code = 0xFFFFFFFF, i;
    volatile BYTE *z = (volatile BYTE *)&si;

    for (i = 0; i < sizeof(si); i++) z[i] = 0;
    si.cb = sizeof(si);
    p = Cat(cmd, "C:\\WINDOWS\\SCANDSKW.EXE ");
    p[0] = drive; p[1] = ':'; p[2] = 0;
    Cat(p + 2, " /N");
    if (CreateProcessA(NULL, cmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) {
        if (WaitForSingleObject(pi.hProcess, 600000) == WAIT_OBJECT_0) GetExitCodeProcess(pi.hProcess, &code);
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    }
    p = Cat(line, "NVTEST scandisk exit "); p = Hex(p, code); Cat(p, "\r\n");
    Out(line);
}

/* "nvtest [d] [/s] [/q]": d = drive letter, /s ScanDisk, /q shut down after */
void __cdecl NvMain(void)
{
    char *cmd = GetCommandLineA(), line[200], *p, drive = 0, root[4];
    int scan = 0, quit = 0, ok;
    DWORD wb = 0, rb = 0, t0, t1, t2;
    UINT type;

    if (*cmd == '"') { cmd++; while (*cmd && *cmd != '"') cmd++; if (*cmd) cmd++; }
    else while (*cmd && *cmd != ' ') cmd++;
    while (*cmd) {
        while (*cmd == ' ') cmd++;
        if (cmd[0] == '/' && (cmd[1] == 's' || cmd[1] == 'S')) scan = 1;
        else if (cmd[0] == '/' && (cmd[1] == 'q' || cmd[1] == 'Q')) quit = 1;
        else if (*cmd && cmd[0] != '/') drive = (char)(cmd[0] & ~0x20);
        while (*cmd && *cmd != ' ') cmd++;
    }
    g_log = CreateFileA("C:\\NVTEST.LOG", GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    Out("NVTEST start\r\n");
    root[1] = ':'; root[2] = '\\'; root[3] = 0;
    for (root[0] = 'C'; root[0] <= 'H'; root[0]++) {
        type = GetDriveTypeA(root);
        p = Cat(line, "NVTEST drive "); *p++ = root[0]; *p = 0; p = Cat(p, ": type "); p = Dec(p, type); Cat(p, "\r\n");
        Out(line);
        if (!drive && root[0] != 'C' && type == DRIVE_FIXED) drive = root[0];
    }
    if (!drive) {
        Out("NVTEST RESULT=FAIL no drive\r\n");
    } else {
        t0 = GetTickCount();
        /* C:\USOS9X\NVTEST.VFY: compare only (a later start reads the disk, not the cache) */
        if (GetFileAttributesA("C:\\USOS9X\\NVTEST.VFY") != 0xFFFFFFFF) { Out("NVTEST verify only\r\n"); ok = 1; }
        else ok = WriteAll(drive, &wb);
        t1 = GetTickCount();
        if (ok) ok = CompareAll(drive, &rb);
        t2 = GetTickCount();
        p = Cat(line, "NVTEST drive "); *p++ = drive; *p = 0;
        p = Cat(p, ": wrote "); p = Dec(p, wb); p = Cat(p, " B in "); p = Dec(p, t1 - t0);
        p = Cat(p, " ms, read+compared "); p = Dec(p, rb); p = Cat(p, " B in "); p = Dec(p, t2 - t1); Cat(p, " ms\r\n");
        Out(line);
        if (scan) Scandisk(drive);
        Out(ok ? "NVTEST RESULT=PASS\r\n" : "NVTEST RESULT=FAIL\r\n");
    }
    if (g_log != INVALID_HANDLE_VALUE) { FlushFileBuffers(g_log); CloseHandle(g_log); g_log = INVALID_HANDLE_VALUE; }
    if (quit) {
        E9("NVTEST shutdown\r\n");
        ExitWindowsEx(EWX_SHUTDOWN | EWX_FORCE, 0);
        Sleep(600000);
    }
    ExitProcess(0);
}
