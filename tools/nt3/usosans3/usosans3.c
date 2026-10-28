/*
 * USOSANS3.EXE - GUI-mode Setup page recorder for a native Windows NT 3.5 /
 * 3.51 / 4.0 install (docs/nt-native-plan.md). Win32, no window, no C runtime.
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 *
 * Started by USOSNT3.EXE /setup (GUI Setup's [GuiUnattended]
 * !DetachedProgram) when the target script staged it. NT 4.0 GUI Setup has
 * no DetachedProgram key (its syssetup.dll knows none): there the $OEM$
 * CMDLINES.TXT starts "USOSANS3.EXE /detach", which starts a second copy
 * detached and returns at once (CMDLINES waits for every command), so only
 * the pages from CMDLINES.TXT on are recorded. It runs on GUI
 * Setup's desktop for the rest of GUI-mode Setup. Once a second it lists the
 * visible top-level windows and their child controls; whenever that list
 * changes it appends it to USOSANS.TXT in the program's own folder
 * (C:\USOS\NT3 or C:\USOS\NT4; C:\USOS\NT3\USOSANS.TXT when the path is
 * unknown), flushed:
 *
 *   --- t=<seconds since start>
 *   top <hwnd> class="<class>" title="<title>" enabled=<0|1>
 *     id=<control id> class="<class>" text="<text>" vis=<0|1> en=<0|1>
 *
 * so the first hardware run shows every page GUI Setup put up, also when
 * one stays (the target C: is read afterwards, offline). The text of Edit
 * controls is never logged (only its length): a page may hold a password.
 * This version only records; it presses nothing (the log says
 * "mode=record"). Answer rules come from the recorded pages.
 * Ends after 6 hours, at 1 MiB of log, or with GUI Setup's restart.
 */
#include <windows.h>

#define LOG_PATH "C:\\USOS\\NT3\\USOSANS.TXT"
#define DUMP_MAX 49152
#define LOG_MAX (1024L * 1024L)
#define MAX_CHILDREN 80

static char g_log[MAX_PATH + 16] = LOG_PATH;
static char g_dump[DUMP_MAX];
static char g_last[DUMP_MAX];
static int g_len;
static int g_children;
static long g_logged;

static void copy(char *d, const char *s, int n)
{
    while (n-- > 0)
        *d++ = *s++;
}

static void log_str(const char *s);

static void put(const char *s)
{
    int n = lstrlenA(s);
    if (g_len + n >= DUMP_MAX - 1)
        n = DUMP_MAX - 1 - g_len;
    if (n <= 0)
        return;
    copy(g_dump + g_len, s, n);
    g_len += n;
    g_dump[g_len] = 0;
}

/* Printable ASCII only, quotes and control characters become '_'. */
static void put_text(const char *s, int max)
{
    char buf[128];
    int i;
    for (i = 0; s[i] && i < max && i < (int)sizeof buf - 1; i++) {
        unsigned char c = (unsigned char)s[i];
        buf[i] = (c < 32 || c > 126 || c == '"') ? '_' : (char)c;
    }
    buf[i] = 0;
    put(buf);
}

static void write_log(const char *s, int n)
{
    HANDLE h;
    DWORD done;
    if (g_logged + n > LOG_MAX)
        return;
    h = CreateFileA(g_log, GENERIC_WRITE, FILE_SHARE_READ, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE)
        return;
    SetFilePointer(h, 0, NULL, FILE_END);
    WriteFile(h, s, (DWORD)n, &done, NULL);
    FlushFileBuffers(h);
    CloseHandle(h);
    g_logged += n;
}

static void log_str(const char *s)
{
    write_log(s, lstrlenA(s));
}

static BOOL CALLBACK child_proc(HWND w, LPARAM unused)
{
    char cls[64], text[128], line[96];
    (void)unused;
    if (++g_children > MAX_CHILDREN)
        return FALSE;
    cls[0] = text[0] = 0;
    GetClassNameA(w, cls, sizeof cls);
    wsprintfA(line, "  id=%d class=\"", GetDlgCtrlID(w));
    put(line);
    put_text(cls, 40);
    if (lstrcmpiA(cls, "Edit") == 0) {
        wsprintfA(line, "\" textlen=%d", GetWindowTextLengthA(w));
        put(line);
    } else {
        GetWindowTextA(w, text, sizeof text);
        put("\" text=\"");
        put_text(text, 80);
        put("\"");
    }
    wsprintfA(line, " vis=%d en=%d\r\n", IsWindowVisible(w) ? 1 : 0, IsWindowEnabled(w) ? 1 : 0);
    put(line);
    return TRUE;
}

static BOOL CALLBACK top_proc(HWND w, LPARAM unused)
{
    char cls[64], title[128], line[64];
    (void)unused;
    if (!IsWindowVisible(w))
        return TRUE;
    cls[0] = title[0] = 0;
    GetClassNameA(w, cls, sizeof cls);
    GetWindowTextA(w, title, sizeof title);
    wsprintfA(line, "top %08lx class=\"", (unsigned long)(DWORD)w);
    put(line);
    put_text(cls, 40);
    put("\" title=\"");
    put_text(title, 80);
    wsprintfA(line, "\" enabled=%d\r\n", IsWindowEnabled(w) ? 1 : 0);
    put(line);
    g_children = 0;
    EnumChildWindows(w, child_proc, 0);
    return TRUE;
}

/* USOSANS.TXT in the folder of this program. */
static void log_next_to_exe(void)
{
    char path[MAX_PATH];
    DWORD n = GetModuleFileNameA(NULL, path, MAX_PATH);
    int cut = -1, i;
    if (n == 0 || n >= MAX_PATH)
        return;
    for (i = 0; i < (int)n; i++)
        if (path[i] == '\\')
            cut = i;
    if (cut < 0)
        return;
    copy(g_log, path, cut + 1);
    copy(g_log + cut + 1, "USOSANS.TXT", 12);
}

/* "/detach" anywhere on the command line: start this program again without
   arguments as a detached process and return (NT 4.0 CMDLINES.TXT). */
static int detach_requested(void)
{
    static const char word[] = "detach";
    const char *c = GetCommandLineA();
    int i;
    for (; c && *c; c++) {
        if (*c != '/')
            continue;
        for (i = 0; word[i] && (c[1 + i] | 0x20) == word[i]; i++)
            ;
        if (!word[i] && (c[1 + i] == 0 || c[1 + i] == ' ' || c[1 + i] == '"'))
            return 1;
    }
    return 0;
}

static void detach(void)
{
    char path[MAX_PATH];
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    char *p = (char *)&si;
    int i;
    DWORD n = GetModuleFileNameA(NULL, path, MAX_PATH);
    for (i = 0; i < (int)sizeof si; i++)
        p[i] = 0;
    si.cb = sizeof si;
    if (n == 0 || n >= MAX_PATH) {
        log_str("USOSANS3 /detach: no module path\r\n");
        return;
    }
    if (CreateProcessA(path, NULL, NULL, NULL, FALSE, DETACHED_PROCESS, NULL, NULL, &si, &pi)) {
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        log_str("USOSANS3 /detach: recorder started\r\n");
    } else {
        log_str("USOSANS3 /detach: CreateProcess FAILED\r\n");
    }
}

void entry(void)
{
    DWORD start = GetTickCount();
    char head[96];
    log_next_to_exe();
    if (detach_requested()) {
        detach();
        ExitProcess(0);
    }
    /* One recorder (both $OEM$ CMDLINES.TXT copies may run on NT 4.0). */
    CreateMutexA(NULL, TRUE, "USOSANS3");
    if (GetLastError() == ERROR_ALREADY_EXISTS)
        ExitProcess(0);
    log_str("USOSANS3 1.0 mode=record (GUI-mode Setup page recorder, presses nothing)\r\n");
    for (;;) {
        DWORD now = GetTickCount() - start;
        if (now > 6UL * 3600UL * 1000UL || g_logged >= LOG_MAX)
            break;
        g_len = 0;
        g_dump[0] = 0;
        EnumWindows(top_proc, 0);
        if (lstrcmpA(g_dump, g_last) != 0) {
            int n = wsprintfA(head, "--- t=%lu\r\n", (unsigned long)(now / 1000UL));
            write_log(head, n);
            write_log(g_dump, g_len);
            copy(g_last, g_dump, g_len + 1);
        }
        Sleep(1000);
    }
    log_str("USOSANS3 end\r\n");
    ExitProcess(0);
}
