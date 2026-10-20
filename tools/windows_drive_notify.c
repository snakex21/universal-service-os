/* usos-drivenotify: tell Explorer about drive letters that appear without
 * Plug and Play, and log them.
 *
 * X470 2026-10-21 (Windows 7 SP1 x86 via CSMWrap, bundled usosusb 1.1-nt6,
 * build B261020-231029): USB keyboard and mouse worked, a FAT32 stick
 * plugged in on the desktop "did not appear". usosusb's own record
 * (Services\usosusb\Parameters\Msc) showed both attempts reached the mount
 * manager and got D: (`UsosUsbDisk0:0=D`, `UsosUsbDisk1:0=D`). usosusb is
 * a legacy (non-PnP) driver: its volumes have no device interface, so no
 * DBT_DEVICEARRIVAL is broadcast and the shell never adds the drive
 * (README: "a kernel driver cannot broadcast WM_DEVICECHANGE"). The letter
 * exists, Explorer just does not know.
 *
 * Started at every logon (HKLM ...\Run, value USOSDriveNotify, written
 * offline by usos-x86-csmwrap.cmd next to the usosusb service), no window,
 * one instance per session. Once a second it compares GetLogicalDrives():
 *   new letter    -> DBT_DEVICEARRIVAL (DBT_DEVTYP_VOLUME) to every top-level
 *                    window + SHChangeNotify(SHCNE_DRIVEADD); for removable
 *                    letters it also reads the volume label and file system
 *                    (which mounts it) and logs the result or the error;
 *   letter gone   -> DBT_DEVICEREMOVECOMPLETE + SHCNE_DRIVEREMOVED.
 * The broadcast for a letter that PnP already announced is harmless (the
 * shell refreshes the same drive again).
 *
 * Log (silent diagnostics for hardware runs): %SystemDrive%\USOS\Logs\
 * usos-drivenotify.log, appended, restarted above 256 KiB. At start and
 * after every change it also copies usosusb's Parameters\Diag / Conn / Msc
 * (they are rewritten at every boot, the log keeps the history).
 *
 * Own code (GPL-3.0-or-later, Copyright (C) 2026 Maksymilian and the USOS
 * Authors), documented Win32 calls only. No C runtime.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dbt.h>
#include <shlobj.h>

void *memset(void *p, int value, size_t count) { volatile BYTE *b = p; while (count--) *b++ = (BYTE)value; return p; }
void *memcpy(void *d, const void *s, size_t n) { volatile BYTE *p = d; const BYTE *q = s; while (n--) *p++ = *q++; return d; }

static HANDLE logf = INVALID_HANDLE_VALUE;
static WCHAR line[2048];

static void log_open(void)
{
    WCHAR path[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"SystemDrive", path, 8);
    if (!n || n > 7) lstrcpyW(path, L"C:");
    lstrcatW(path, L"\\USOS");
    CreateDirectoryW(path, 0);
    lstrcatW(path, L"\\Logs");
    CreateDirectoryW(path, 0);
    lstrcatW(path, L"\\usos-drivenotify.log");
    logf = CreateFileW(path, FILE_APPEND_DATA | FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE, 0, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    if (logf == INVALID_HANDLE_VALUE) {
        n = GetEnvironmentVariableW(L"PUBLIC", path, MAX_PATH - 32);
        if (!n || n >= MAX_PATH - 32) return;
        lstrcatW(path, L"\\usos-drivenotify.log");
        logf = CreateFileW(path, FILE_APPEND_DATA | FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE, 0, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
        if (logf == INVALID_HANDLE_VALUE) return;
    }
    if (GetFileSize(logf, 0) > 256 * 1024) {
        CloseHandle(logf);
        logf = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, 0, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    }
}

/* one line: "2026-10-21 01:35:42 <text>\r\n", ANSI */
static void say(const WCHAR *text)
{
    static char b[4096];
    static WCHAR full[2200];
    SYSTEMTIME t;
    DWORD w;
    int n;
    if (logf == INVALID_HANDLE_VALUE) return;
    GetLocalTime(&t);
    wsprintfW(full, L"%04u-%02u-%02u %02u:%02u:%02u ", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond);
    lstrcpynW(full + lstrlenW(full), text, 2048);
    lstrcatW(full, L"\r\n");
    n = WideCharToMultiByte(CP_ACP, 0, full, -1, b, sizeof(b), 0, 0);
    if (n > 1) WriteFile(logf, b, (DWORD)(n - 1), &w, 0);
}

static void usosusb_state(const WCHAR *when)
{
    static const WCHAR *names[3] = { L"Diag", L"Conn", L"Msc" };
    HKEY k;
    int i;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SYSTEM\\CurrentControlSet\\Services\\usosusb\\Parameters", 0, KEY_READ, &k) != ERROR_SUCCESS) {
        wsprintfW(line, L"[%s] usosusb Parameters: none", when);
        say(line);
        return;
    }
    for (i = 0; i < 3; i++) {
        static WCHAR v[1400];
        DWORD type = 0, size = sizeof(v) - sizeof(WCHAR);
        LONG r = RegQueryValueExW(k, names[i], 0, &type, (BYTE *)v, &size);
        if (r == ERROR_SUCCESS && type == REG_SZ) {
            v[size / sizeof(WCHAR)] = 0;
            wsprintfW(line, L"[%s] usosusb %s: %s", when, names[i], v);
        } else
            wsprintfW(line, L"[%s] usosusb %s: (r=%ld)", when, names[i], r);
        say(line);
    }
    RegCloseKey(k);
}

static void broadcast(DWORD event, DWORD mask)
{
    DEV_BROADCAST_VOLUME v;
    DWORD_PTR res;
    memset(&v, 0, sizeof(v));
    v.dbcv_size = sizeof(v);
    v.dbcv_devicetype = DBT_DEVTYP_VOLUME;
    v.dbcv_unitmask = mask;
    SendMessageTimeoutW(HWND_BROADCAST, WM_DEVICECHANGE, event, (LPARAM)&v, SMTO_ABORTIFHUNG, 2000, &res);
}

static void arrived(int i, DWORD mask)
{
    WCHAR root[4] = { (WCHAR)('A' + i), L':', L'\\', 0 };
    UINT type = GetDriveTypeW(root);
    if (type == DRIVE_REMOVABLE) {
        static WCHAR label[MAX_PATH + 1], fs[MAX_PATH + 1];
        DWORD serial = 0, maxlen = 0, flags = 0;
        ULARGE_INTEGER freeb, total, tfree;
        UINT old = SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOOPENFILEERRORBOX);
        label[0] = fs[0] = 0;
        if (GetVolumeInformationW(root, label, MAX_PATH + 1, &serial, &maxlen, &flags, fs, MAX_PATH + 1)) {
            total.QuadPart = 0;
            GetDiskFreeSpaceExW(root, &freeb, &total, &tfree);
            wsprintfW(line, L"%c: removable, fs=%s label=\"%s\" serial=%08lx size=%luM", 'A' + i, fs, label, serial,
                      (ULONG)(total.QuadPart >> 20));
        } else
            wsprintfW(line, L"%c: removable, volume not readable: error %lu", 'A' + i, GetLastError());
        SetErrorMode(old);
    } else
        wsprintfW(line, L"%c: new letter, drive type %u", 'A' + i, type);
    say(line);
    broadcast(DBT_DEVICEARRIVAL, mask);
    SHChangeNotify(SHCNE_DRIVEADD, SHCNF_PATHW | SHCNF_FLUSH, root, 0);
}

static void removed(int i, DWORD mask)
{
    WCHAR root[4] = { (WCHAR)('A' + i), L':', L'\\', 0 };
    wsprintfW(line, L"%c: letter removed", 'A' + i);
    say(line);
    broadcast(DBT_DEVICEREMOVECOMPLETE, mask);
    SHChangeNotify(SHCNE_DRIVEREMOVED, SHCNF_PATHW | SHCNF_FLUSH, root, 0);
}

void entry(void)
{
    DWORD last, now, i;
    WCHAR letters[27];
    int n = 0;
    CreateMutexW(0, TRUE, L"Local\\USOSDriveNotify");
    if (GetLastError() == ERROR_ALREADY_EXISTS) ExitProcess(0);
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOOPENFILEERRORBOX);
    log_open();
    last = GetLogicalDrives();
    for (i = 0; i < 26; i++)
        if (last & (1u << i)) letters[n++] = (WCHAR)('A' + i);
    letters[n] = 0;
    wsprintfW(line, L"usos-drivenotify 1.0 start, letters %s", letters);
    say(line);
    usosusb_state(L"logon");
    /* letters already there at logon: Explorer started after them and lists
       them, but a removable one is logged (mounted) for the diagnostics */
    for (i = 0; i < 26; i++)
        if ((last & (1u << i))) {
            WCHAR root[4] = { (WCHAR)('A' + i), L':', L'\\', 0 };
            if (GetDriveTypeW(root) == DRIVE_REMOVABLE) arrived((int)i, 1u << i);
        }
    for (;;) {
        DWORD add, gone;
        Sleep(1000);
        now = GetLogicalDrives();
        if (now == last) continue;
        add = now & ~last;
        gone = last & ~now;
        for (i = 0; i < 26; i++) {
            if (add & (1u << i)) arrived((int)i, 1u << i);
            if (gone & (1u << i)) removed((int)i, 1u << i);
        }
        last = now;
        usosusb_state(L"change");
    }
}
