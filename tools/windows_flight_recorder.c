/* USOSFLT.EXE: flight recorder ("czarna skrzynka") for the installed 32-bit
 * Windows 8 / 8.1 / 10 on the win-x86-uefi-csmwrap route (diagnostic phase,
 * docs/nvme-nt6-2026-10-12.md section 21.2). No C runtime.
 *
 * X470 2026-10-31: the installed Windows 10 x86 resets silently ~30 s into
 * its first boot (specialize). This Win32 service (USOSFLT, own process,
 * LocalSystem, auto start, group "Event Log"), registered OFFLINE by
 * "usos-x86-csmwrap faststartup" (tools/windows_flight_register.h), appends
 * one compact line per second to <SystemDrive>\USOS\FLIGHT.LOG for the first
 * 10 minutes of every boot, then one per 10 s, and stops itself after 30
 * minutes, 30 s after OOBE completes, or after 2 minutes in a boot that is
 * not a Setup boot. Every write is FILE_FLAG_WRITE_THROUGH + FlushFileBuffers,
 * so the last line survives a hard reset.
 *
 * Lines (every line starts with the boot number and the uptime in ms):
 *   BOOT / INFO / BCD   at service start: boot counter (FLIGHT.CNT), kernel
 *                       boot time, SystemStartOptions, bcdedit /enum {current}
 *   =DEV <id>           device instances present at service start
 *   T ...               per tick: wall time, devices, PCI functions, GPP
 *                       bridge 1022:1483 at 00:03.1 (br), GPU 1002:67EF
 *                       (gpu), HDMI audio 1002:AAE0 (aud) as 1 / 0 / 1!<CM
 *                       problem>, drivers, processes, memory load, commit,
 *                       Panther setupact.log sizes, HKLM\SYSTEM\Setup
 *                       SystemSetupInProgress/OOBEInProgress/SetupType, the
 *                       probe round time
 *   +DEV/-DEV, +DRV/-DRV, +PROC/-PROC   changes since the previous tick
 *   N ENUM/START/REMOVE <id>            CM_Register_Notification, at once
 *   SA / GC <text>      the new last line of Windows\Panther\setupact.log /
 *                       Windows\Panther\UnattendGC\setupact.log
 *   W STALL <probe> <ms> the watchdog: the probe round is late (a hung CM /
 *                       PSAPI call never stops the 1 s lines)
 *   END <reason>        the service stops itself / SCM stop / shutdown
 *
 *   USOSFLT.EXE                      service mode (SCM)
 *   USOSFLT.EXE /console <log> [s]   console run for s seconds (default 20)
 *                                    with <log> and <log>.cnt (host test)
 *   USOSFLT.EXE /remove              deletes the USOSFLT service
 */
#define WINVER 0x0602
#define _WIN32_WINNT 0x0602
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <cfgmgr32.h>
#include <tlhelp32.h>
#include <psapi.h>
#include <shellapi.h>
#include <stddef.h>

#define USOSFLT_VERSION "usosflt 1"
#define FAST_PHASE_MS (10u * 60u * 1000u)
#define MAX_RUN_MS (30u * 60u * 1000u)
#define NORMAL_BOOT_MS (2u * 60u * 1000u)
#define AFTER_OOBE_MS (30u * 1000u)
#define MAX_LOG_BYTES (32u * 1024u * 1024u)

void *memcpy(void *d, const void *s, size_t n) { volatile BYTE *p = d; const BYTE *q = s; while (n--) *p++ = *q++; return d; }
void *memset(void *d, int v, size_t n) { volatile BYTE *p = d; while (n--) *p++ = (BYTE)v; return d; }

static WCHAR log_path[MAX_PATH], cnt_path[MAX_PATH], root[4] = L"C:\\";
static HANDLE logf = INVALID_HANDLE_VALUE, stop_event, go_event;
static CRITICAL_SECTION lock;
static char pending[32768];
static int pending_len;
static DWORD boot_no, console_seconds;
static BOOL console_mode;
static ULONGLONG start_tick;
static volatile ULONGLONG round_done_tick, probe_since;
static volatile const char *probe_name = "start";
static volatile LONG setup_in_progress = -1, oobe_in_progress = -1;

static ULONGLONG now_tick(void) { return GetTickCount64(); }
static int slen(const char *s) { int n = 0; while (s[n]) n++; return n; }
static void w2a(char *out, const WCHAR *in, int max) {
    int i = 0;
    for (; in && in[i] && i < max - 1; i++) out[i] = in[i] >= 32 && in[i] < 127 ? (char)in[i] : '?';
    out[i] = 0;
}
static BOOL wprefix(const WCHAR *s, const char *p) {
    for (; *p; p++, s++) { WCHAR c = *s; if (c >= L'a' && c <= L'z') c -= 32; if (c != (WCHAR)*p) return FALSE; }
    return TRUE;
}
static DWORD whash(const WCHAR *s) {
    DWORD h = 2166136261u;
    for (; *s; s++) { WCHAR c = *s; if (c >= L'a' && c <= L'z') c -= 32; h = (h ^ c) * 16777619u; }
    return h;
}
static DWORD ahash(const char *s) { DWORD h = 2166136261u; for (; *s; s++) h = (h ^ (BYTE)*s) * 16777619u; return h; }

/* ---- log: lines are queued under the lock, commit writes and flushes ---- */
static void commit_locked(void) {
    DWORD w;
    if (pending_len && logf != INVALID_HANDLE_VALUE) {
        WriteFile(logf, pending, (DWORD)pending_len, &w, 0);
        FlushFileBuffers(logf);
    }
    if (pending_len && console_mode) WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), pending, (DWORD)pending_len, &w, 0);
    pending_len = 0;
}
static void line_locked(const char *fmt, va_list ap) {
    char text[1100];
    int n = wsprintfA(text, "%lu %lu ", boot_no, (DWORD)now_tick());
    n += wvsprintfA(text + n, fmt, ap);
    if (n > 1020) n = 1020;
    text[n++] = '\r'; text[n++] = '\n';
    if (pending_len + n > (int)sizeof(pending)) commit_locked();
    memcpy(pending + pending_len, text, (size_t)n);
    pending_len += n;
}
static void line(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    EnterCriticalSection(&lock); line_locked(fmt, ap); LeaveCriticalSection(&lock);
    va_end(ap);
}
static void commit(void) { EnterCriticalSection(&lock); commit_locked(); LeaveCriticalSection(&lock); }
static void line_now(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    EnterCriticalSection(&lock); line_locked(fmt, ap); commit_locked(); LeaveCriticalSection(&lock);
    va_end(ap);
}

/* ---- boot counter: <cnt_path>, ASCII decimal, written through ---- */
static DWORD next_boot_number(void) {
    char text[16] = {0}; DWORD got = 0, v = 0, w;
    HANDLE h = CreateFileW(cnt_path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ, 0, OPEN_ALWAYS, FILE_FLAG_WRITE_THROUGH, 0);
    if (h == INVALID_HANDLE_VALUE) return 0;
    ReadFile(h, text, sizeof(text) - 1, &got, 0);
    for (DWORD i = 0; i < got && text[i] >= '0' && text[i] <= '9'; i++) v = v * 10 + (DWORD)(text[i] - '0');
    v++;
    SetFilePointer(h, 0, 0, FILE_BEGIN);
    w = (DWORD)wsprintfA(text, "%lu\r\n", v);
    WriteFile(h, text, w, &w, 0);
    SetEndOfFile(h);
    FlushFileBuffers(h);
    CloseHandle(h);
    return v;
}

static BOOL open_log(void) {
    LARGE_INTEGER size;
    WCHAR old[MAX_PATH];
    HANDLE h = CreateFileW(log_path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, 0, OPEN_EXISTING, 0, 0);
    if (h != INVALID_HANDLE_VALUE) {
        BOOL big = GetFileSizeEx(h, &size) && size.QuadPart > MAX_LOG_BYTES;
        CloseHandle(h);
        if (big && lstrlenW(log_path) < MAX_PATH - 8) { lstrcpyW(old, log_path); lstrcatW(old, L".old"); MoveFileExW(log_path, old, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH); }
    }
    logf = CreateFileW(log_path, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_DELETE, 0, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH, 0);
    if (logf == INVALID_HANDLE_VALUE) return FALSE;
    SetFilePointer(logf, 0, 0, FILE_END);
    return TRUE;
}

/* ---- registry helpers ---- */
static DWORD reg_dword(const WCHAR *key, const WCHAR *name, DWORD missing) {
    HKEY k; DWORD v = missing, type = 0, size = sizeof(v);
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, key, 0, KEY_QUERY_VALUE, &k) != ERROR_SUCCESS) return missing;
    if (RegQueryValueExW(k, name, 0, &type, (BYTE *)&v, &size) != ERROR_SUCCESS || type != REG_DWORD) v = missing;
    RegCloseKey(k);
    return v;
}
static void reg_text(const WCHAR *key, const WCHAR *name, char *out, int max) {
    HKEY k; WCHAR v[512]; DWORD type = 0, size = sizeof(v) - sizeof(WCHAR);
    out[0] = '-'; out[1] = 0;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, key, 0, KEY_QUERY_VALUE, &k) != ERROR_SUCCESS) return;
    if (RegQueryValueExW(k, name, 0, &type, (BYTE *)v, &size) == ERROR_SUCCESS && (type == REG_SZ || type == REG_EXPAND_SZ)) {
        v[size / sizeof(WCHAR)] = 0; w2a(out, v, max);
    }
    RegCloseKey(k);
}

/* ---- start record ---- */
static void time_text(char *out, const SYSTEMTIME *t) {
    wsprintfA(out, "%04u-%02u-%02u %02u:%02u:%02u.%03u", t->wYear, t->wMonth, t->wDay, t->wHour, t->wMinute, t->wSecond, t->wMilliseconds);
}
static void start_record(void) {
    FILETIME ft; ULARGE_INTEGER u; SYSTEMTIME st, lt; char a[40], b[40], text[600];
    ULONGLONG up = now_tick();
    GetSystemTimeAsFileTime(&ft);
    u.LowPart = ft.dwLowDateTime; u.HighPart = ft.dwHighDateTime;
    FileTimeToSystemTime(&ft, &st); GetLocalTime(&lt);
    time_text(a, &st); time_text(b, &lt);
    line("BOOT %s %s pid=%lu uptime_at_start_ms=%lu now_utc=%s now_local=%s", USOSFLT_VERSION, console_mode ? "console" : "service", GetCurrentProcessId(), (DWORD)up, a, b);
    u.QuadPart -= up * 10000u;
    ft.dwLowDateTime = u.LowPart; ft.dwHighDateTime = u.HighPart;
    FileTimeToSystemTime(&ft, &st); time_text(a, &st);
    line("INFO kernel_boot_utc=%s (now minus GetTickCount64)", a);
    reg_text(L"SYSTEM\\CurrentControlSet\\Control", L"SystemStartOptions", text, sizeof(text)); line("INFO SystemStartOptions=%s", text);
    reg_text(L"SYSTEM\\CurrentControlSet\\Control", L"SystemBootDevice", text, sizeof(text)); line("INFO SystemBootDevice=%s", text);
    reg_text(L"SYSTEM\\CurrentControlSet\\Control", L"FirmwareBootDevice", text, sizeof(text)); line("INFO FirmwareBootDevice=%s", text);
    reg_text(L"SYSTEM\\Setup", L"CmdLine", text, sizeof(text)); line("INFO Setup CmdLine=%s", text);
    line("INFO setup SystemSetupInProgress=%lu OOBEInProgress=%lu SetupType=%lu (4294967295 = missing)",
         reg_dword(L"SYSTEM\\Setup", L"SystemSetupInProgress", 0xFFFFFFFF), reg_dword(L"SYSTEM\\Setup", L"OOBEInProgress", 0xFFFFFFFF), reg_dword(L"SYSTEM\\Setup", L"SetupType", 0xFFFFFFFF));
    line("INFO CrashControl AutoReboot=%lu CrashDumpEnabled=%lu", reg_dword(L"SYSTEM\\CurrentControlSet\\Control\\CrashControl", L"AutoReboot", 0xFFFFFFFF),
         reg_dword(L"SYSTEM\\CurrentControlSet\\Control\\CrashControl", L"CrashDumpEnabled", 0xFFFFFFFF));
    commit();
}

/* bcdedit /enum {current} into <log>.bcd (own thread, at most 8 s), then
 * its lines as "BCD ..." (UTF-16 or OEM text, ASCII kept). */
static DWORD WINAPI bcd_thread(LPVOID unused) {
    WCHAR out[MAX_PATH], cmd[MAX_PATH + 64], sys[MAX_PATH];
    SECURITY_ATTRIBUTES sa = {sizeof(sa), 0, TRUE};
    STARTUPINFOW si; PROCESS_INFORMATION pi;
    static BYTE text[16384]; DWORD got = 0;
    (void)unused;
    if (lstrlenW(log_path) > MAX_PATH - 8 || !GetSystemDirectoryW(sys, MAX_PATH - 40)) return 0;
    lstrcpyW(out, log_path); lstrcatW(out, L".bcd");
    HANDLE h = CreateFileW(out, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa, CREATE_ALWAYS, 0, 0);
    if (h == INVALID_HANDLE_VALUE) { line_now("BCD cannot create %s", "the output file"); return 0; }
    memset(&si, 0, sizeof(si)); si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES; si.hStdOutput = h; si.hStdError = h; si.hStdInput = 0;
    lstrcatW(sys, L"\\bcdedit.exe");
    /* A 32-bit process on a 64-bit host (the console test) sees SysWOW64,
     * which has no bcdedit: Sysnative then. */
    if (GetFileAttributesW(sys) == INVALID_FILE_ATTRIBUTES && GetWindowsDirectoryW(sys, MAX_PATH - 40)) lstrcatW(sys, L"\\Sysnative\\bcdedit.exe");
    lstrcpyW(cmd, L"\""); lstrcatW(cmd, sys); lstrcatW(cmd, L"\" /enum {current}");
    if (!CreateProcessW(0, cmd, 0, 0, TRUE, CREATE_NO_WINDOW, 0, 0, &si, &pi)) { line_now("BCD bcdedit not started, error=%lu", GetLastError()); CloseHandle(h); return 0; }
    if (WaitForSingleObject(pi.hProcess, 8000) == WAIT_TIMEOUT) { line_now("BCD bcdedit still running after 8 s; not waited for"); CloseHandle(pi.hThread); CloseHandle(pi.hProcess); CloseHandle(h); return 0; }
    DWORD code = 0; GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
    SetFilePointer(h, 0, 0, FILE_BEGIN);
    ReadFile(h, text, sizeof(text) - 2, &got, 0);
    CloseHandle(h);
    DeleteFileW(out);
    {
        char row[200]; int n = 0;
        for (DWORD i = 0; i <= got; i++) {
            BYTE c = i < got ? text[i] : 10;
            if (c == 0 || c == 13) continue;
            if (c == 10) { row[n] = 0; if (n) line("BCD %s", row); n = 0; continue; }
            if (n < (int)sizeof(row) - 1) row[n++] = c >= 32 && c < 127 ? (char)c : '?';
        }
        line("BCD bcdedit exit code=%lu", code);
        commit();
    }
    return code;
}

/* ---- devices ---- */
#define MAX_DEV 4096
static WCHAR *dev_list[2];
static ULONG dev_cap[2];
static DWORD dev_hash[2][MAX_DEV], dev_off[2][MAX_DEV], dev_count[2];
static int dev_cur;
static BOOL dev_first = TRUE;
static DWORD pci_count;
static char br_text[16], gpu_text[16], aud_text[16];

static void dev_state(const WCHAR *id, char *out) {
    DEVINST dn; ULONG st = 0, prob = 0;
    if (CM_Locate_DevNodeW(&dn, (DEVINSTID_W)id, CM_LOCATE_DEVNODE_NORMAL) != CR_SUCCESS) { lstrcpyA(out, "1?"); return; }
    if (CM_Get_DevNode_Status(&st, &prob, dn, 0) == CR_SUCCESS && (st & DN_HAS_PROBLEM)) wsprintfA(out, "1!%lu", prob);
    else lstrcpyA(out, "1");
}
static BOOL is_bridge_031(const WCHAR *id) {
    DEVINST dn; ULONG bus = 0xFFFFFFFF, addr = 0xFFFFFFFF, size = sizeof(bus), type = 0;
    if (CM_Locate_DevNodeW(&dn, (DEVINSTID_W)id, CM_LOCATE_DEVNODE_NORMAL) != CR_SUCCESS) return FALSE;
    CM_Get_DevNode_Registry_PropertyW(dn, CM_DRP_BUSNUMBER, &type, &bus, &size, 0);
    size = sizeof(addr);
    CM_Get_DevNode_Registry_PropertyW(dn, CM_DRP_ADDRESS, &type, &addr, &size, 0);
    return bus == 0 && addr == ((3u << 16) | 1u);
}
static BOOL dev_fetch(int slot) {
    ULONG len = 0;
    for (int tries = 0; tries < 3; tries++) {
        if (CM_Get_Device_ID_List_SizeW(&len, 0, CM_GETIDLIST_FILTER_PRESENT) != CR_SUCCESS) return FALSE;
        len += 1024;
        if (len > dev_cap[slot]) {
            if (dev_list[slot]) HeapFree(GetProcessHeap(), 0, dev_list[slot]);
            dev_list[slot] = HeapAlloc(GetProcessHeap(), 0, len * sizeof(WCHAR));
            dev_cap[slot] = dev_list[slot] ? len : 0;
            if (!dev_list[slot]) return FALSE;
        }
        if (CM_Get_Device_ID_ListW(0, dev_list[slot], dev_cap[slot], CM_GETIDLIST_FILTER_PRESENT) == CR_SUCCESS) return TRUE;
    }
    return FALSE;
}
static BOOL in_list(DWORD h, int slot) { for (DWORD i = 0; i < dev_count[slot]; i++) if (dev_hash[slot][i] == h) return TRUE; return FALSE; }
static void probe_devices(void) {
    int s = dev_cur ^ 1;
    char id[400];
    if (!dev_fetch(s)) { lstrcpyA(br_text, "?"); lstrcpyA(gpu_text, "?"); lstrcpyA(aud_text, "?"); return; }
    dev_count[s] = 0; pci_count = 0;
    lstrcpyA(br_text, "0"); lstrcpyA(gpu_text, "0"); lstrcpyA(aud_text, "0");
    for (WCHAR *p = dev_list[s]; *p && dev_count[s] < MAX_DEV; p += lstrlenW(p) + 1) {
        dev_hash[s][dev_count[s]] = whash(p); dev_off[s][dev_count[s]] = (DWORD)(p - dev_list[s]); dev_count[s]++;
        if (wprefix(p, "PCI\\")) pci_count++;
        if (wprefix(p, "PCI\\VEN_1022&DEV_1483") && br_text[0] == '0' && is_bridge_031(p)) dev_state(p, br_text);
        if (wprefix(p, "PCI\\VEN_1002&DEV_67EF") && gpu_text[0] == '0') dev_state(p, gpu_text);
        if (wprefix(p, "PCI\\VEN_1002&DEV_AAE0") && aud_text[0] == '0') dev_state(p, aud_text);
    }
    if (dev_first) {
        for (DWORD i = 0; i < dev_count[s]; i++) { w2a(id, dev_list[s] + dev_off[s][i], sizeof(id)); line("=DEV %s", id); }
        dev_first = FALSE;
    } else {
        int o = dev_cur;
        for (DWORD i = 0; i < dev_count[s]; i++) if (!in_list(dev_hash[s][i], o)) { w2a(id, dev_list[s] + dev_off[s][i], sizeof(id)); line("+DEV %s", id); }
        for (DWORD i = 0; i < dev_count[o]; i++) if (!in_list(dev_hash[o][i], s)) { w2a(id, dev_list[o] + dev_off[o][i], sizeof(id)); line("-DEV %s", id); }
    }
    dev_cur = s;
}

/* ---- kernel drivers ---- */
#define MAX_DRV 1024
static LPVOID drv_addr[2][MAX_DRV];
static char drv_name[2][MAX_DRV][32];
static DWORD drv_count[2];
static int drv_cur;
static BOOL drv_first = TRUE;
static void probe_drivers(void) {
    int s = drv_cur ^ 1, o = drv_cur; DWORD need = 0;
    if (!EnumDeviceDrivers(drv_addr[s], sizeof(drv_addr[s]), &need)) return;
    drv_count[s] = need / sizeof(LPVOID); if (drv_count[s] > MAX_DRV) drv_count[s] = MAX_DRV;
    for (DWORD i = 0; i < drv_count[s]; i++) {
        BOOL known = FALSE;
        for (DWORD j = 0; j < drv_count[o]; j++) if (drv_addr[o][j] == drv_addr[s][i]) { lstrcpyA(drv_name[s][i], drv_name[o][j]); known = TRUE; break; }
        if (!known) {
            if (!GetDeviceDriverBaseNameA(drv_addr[s][i], drv_name[s][i], sizeof(drv_name[s][i]))) lstrcpyA(drv_name[s][i], "?");
            if (!drv_first) line("+DRV %s", drv_name[s][i]);
        }
    }
    if (!drv_first)
        for (DWORD j = 0; j < drv_count[o]; j++) {
            BOOL still = FALSE;
            for (DWORD i = 0; i < drv_count[s]; i++) if (drv_addr[s][i] == drv_addr[o][j]) { still = TRUE; break; }
            if (!still) line("-DRV %s", drv_name[o][j]);
        }
    else { char row[1000]; int n = 0; row[0] = 0;
        for (DWORD i = 0; i < drv_count[s]; i++) {
            int l = slen(drv_name[s][i]);
            if (n + l + 2 > (int)sizeof(row) - 8) { row[n] = 0; line("=DRV %s", row); n = 0; }
            memcpy(row + n, drv_name[s][i], (size_t)l); n += l; row[n++] = ' ';
        }
        row[n] = 0; if (n) line("=DRV %s", row);
    }
    drv_first = FALSE; drv_cur = s;
}

/* ---- processes ---- */
#define MAX_PROC 1024
static DWORD proc_id[2][MAX_PROC], proc_h[2][MAX_PROC];
static char proc_name[2][MAX_PROC][32];
static DWORD proc_count[2];
static int proc_cur;
static BOOL proc_first = TRUE;
static void probe_processes(void) {
    int s = proc_cur ^ 1, o = proc_cur;
    PROCESSENTRY32W pe; pe.dwSize = sizeof(pe);
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return;
    proc_count[s] = 0;
    if (Process32FirstW(snap, &pe)) do {
        DWORD i = proc_count[s];
        if (i >= MAX_PROC) break;
        proc_id[s][i] = pe.th32ProcessID; w2a(proc_name[s][i], pe.szExeFile, 32); proc_h[s][i] = ahash(proc_name[s][i]) ^ pe.th32ProcessID;
        proc_count[s]++;
    } while (Process32NextW(snap, &pe));
    CloseHandle(snap);
    if (proc_first) {
        char row[1000]; int n = 0;
        for (DWORD i = 0; i < proc_count[s]; i++) {
            char item[48]; int l = wsprintfA(item, "%s(%lu) ", proc_name[s][i], proc_id[s][i]);
            if (n + l > (int)sizeof(row) - 8) { row[n] = 0; line("=PROC %s", row); n = 0; }
            memcpy(row + n, item, (size_t)l); n += l;
        }
        row[n] = 0; if (n) line("=PROC %s", row);
    } else {
        for (DWORD i = 0; i < proc_count[s]; i++) { BOOL f = FALSE; for (DWORD j = 0; j < proc_count[o]; j++) if (proc_h[o][j] == proc_h[s][i]) { f = TRUE; break; } if (!f) line("+PROC %s(%lu)", proc_name[s][i], proc_id[s][i]); }
        for (DWORD j = 0; j < proc_count[o]; j++) { BOOL f = FALSE; for (DWORD i = 0; i < proc_count[s]; i++) if (proc_h[s][i] == proc_h[o][j]) { f = TRUE; break; } if (!f) line("-PROC %s(%lu)", proc_name[o][j], proc_id[o][j]); }
    }
    proc_first = FALSE; proc_cur = s;
}

/* ---- Panther setupact.log tails ---- */
struct tail { const WCHAR *rel; const char *tag; DWORD size; DWORD hash; };
static struct tail tails[2] = { { L"Windows\\Panther\\setupact.log", "SA", 0, 0 }, { L"Windows\\Panther\\UnattendGC\\setupact.log", "GC", 0, 0 } };
static void probe_tail(struct tail *t) {
    WCHAR p[MAX_PATH]; static BYTE raw[2048]; char last[400]; DWORD got = 0; LARGE_INTEGER size, pos;
    lstrcpyW(p, root); lstrcatW(p, t->rel);
    HANDLE h = CreateFileW(p, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, 0, OPEN_EXISTING, 0, 0);
    if (h == INVALID_HANDLE_VALUE) { t->size = 0; return; }
    if (!GetFileSizeEx(h, &size)) size.QuadPart = 0;
    t->size = (DWORD)size.QuadPart;
    pos.QuadPart = size.QuadPart > (LONGLONG)sizeof(raw) ? size.QuadPart - (LONGLONG)sizeof(raw) : 0;
    SetFilePointerEx(h, pos, 0, FILE_BEGIN);
    ReadFile(h, raw, sizeof(raw), &got, 0);
    CloseHandle(h);
    /* Last non-empty line; NUL bytes (UTF-16 text) are dropped. */
    int end = (int)got, n = 0;
    while (end > 0 && (raw[end - 1] == '\n' || raw[end - 1] == '\r' || raw[end - 1] == 0)) end--;
    int start = end;
    while (start > 0 && raw[start - 1] != '\n') start--;
    for (int i = start; i < end && n < (int)sizeof(last) - 1; i++) if (raw[i]) last[n++] = raw[i] >= 32 && raw[i] < 127 ? (char)raw[i] : '?';
    last[n] = 0;
    DWORD hsh = ahash(last);
    if (n && hsh != t->hash) { t->hash = hsh; line("%s %s", t->tag, last); }
}

/* ---- tick ---- */
struct slowness { const char *name; DWORD skip; };
static struct slowness slow[4] = { {"devices", 0}, {"drivers", 0}, {"processes", 0}, {"tails", 0} };
static void timed(int i, void (*fn)(void)) {
    if (slow[i].skip) { slow[i].skip--; return; }
    ULONGLONG t0 = now_tick();
    probe_name = slow[i].name; probe_since = t0;
    fn();
    DWORD ms = (DWORD)(now_tick() - t0);
    if (ms > 400) { slow[i].skip = 5; line("SLOW %s %lu ms; skipped for 5 rounds", slow[i].name, ms); }
}
static void tails_both(void) { probe_tail(&tails[0]); probe_tail(&tails[1]); }
static DWORD WINAPI probe_thread(LPVOID unused) {
    (void)unused;
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);
    HANDLE waits[2] = { stop_event, go_event };
    for (;;) {
        ULONGLONG t0 = now_tick();
        SYSTEMTIME lt; MEMORYSTATUSEX ms; ms.dwLength = sizeof(ms);
        timed(0, probe_devices);
        timed(1, probe_drivers);
        timed(2, probe_processes);
        timed(3, tails_both);
        probe_name = "registry"; probe_since = now_tick();
        DWORD ssip = reg_dword(L"SYSTEM\\Setup", L"SystemSetupInProgress", 0xFFFFFFFF), oobe = reg_dword(L"SYSTEM\\Setup", L"OOBEInProgress", 0xFFFFFFFF),
              stype = reg_dword(L"SYSTEM\\Setup", L"SetupType", 0xFFFFFFFF);
        setup_in_progress = (LONG)(ssip == 1); oobe_in_progress = (LONG)(oobe == 1);
        GlobalMemoryStatusEx(&ms);
        GetLocalTime(&lt);
        line("T %02u:%02u:%02u.%03u dev=%lu pci=%lu br=%s gpu=%s aud=%s drv=%lu proc=%lu mem=%lu%% commit=%lu/%luM sa=%lu gc=%lu setup=%ld/%ld/%ld round=%lums",
             lt.wHour, lt.wMinute, lt.wSecond, lt.wMilliseconds, dev_count[dev_cur], pci_count, br_text, gpu_text, aud_text, drv_count[drv_cur], proc_count[proc_cur],
             ms.dwMemoryLoad, (DWORD)((ms.ullTotalPageFile - ms.ullAvailPageFile) >> 20), (DWORD)(ms.ullTotalPageFile >> 20), tails[0].size, tails[1].size,
             (LONG)ssip, (LONG)oobe, (LONG)stype, (DWORD)(now_tick() - t0));
        commit();
        probe_name = "idle"; round_done_tick = now_tick();
        if (WaitForMultipleObjects(2, waits, FALSE, INFINITE) == WAIT_OBJECT_0) return 0;
    }
}

/* ---- CM notifications (Windows 8+, resolved at run time) ---- */
typedef CONFIGRET (WINAPI *cm_register_fn)(PCM_NOTIFY_FILTER, PVOID, PCM_NOTIFY_CALLBACK, PHCMNOTIFICATION);
typedef CONFIGRET (WINAPI *cm_unregister_fn)(HCMNOTIFICATION);
static HCMNOTIFICATION notify_handle;
static DWORD CALLBACK on_device(HCMNOTIFICATION h, PVOID ctx, CM_NOTIFY_ACTION action, PCM_NOTIFY_EVENT_DATA data, DWORD size) {
    char id[400];
    const char *what = action == CM_NOTIFY_ACTION_DEVICEINSTANCEENUMERATED ? "ENUM" : action == CM_NOTIFY_ACTION_DEVICEINSTANCESTARTED ? "START" :
                       action == CM_NOTIFY_ACTION_DEVICEINSTANCEREMOVED ? "REMOVE" : 0;
    (void)h; (void)ctx; (void)size;
    if (!what || !data || data->FilterType != CM_NOTIFY_FILTER_TYPE_DEVICEINSTANCE) return ERROR_SUCCESS;
    w2a(id, data->u.DeviceInstance.InstanceId, sizeof(id));
    line_now("N %s %s", what, id);
    return ERROR_SUCCESS;
}
static void register_notifications(void) {
    HMODULE m = GetModuleHandleW(L"cfgmgr32.dll");
    cm_register_fn reg = m ? (cm_register_fn)(void *)GetProcAddress(m, "CM_Register_Notification") : 0;
    CM_NOTIFY_FILTER f;
    if (!reg) { line("INFO CM_Register_Notification not available; tick diffs only"); return; }
    memset(&f, 0, sizeof(f));
    f.cbSize = sizeof(f); f.Flags = CM_NOTIFY_FILTER_FLAG_ALL_DEVICE_INSTANCES; f.FilterType = CM_NOTIFY_FILTER_TYPE_DEVICEINSTANCE;
    CONFIGRET r = reg(&f, 0, on_device, &notify_handle);
    line("INFO device-instance notifications registered, CONFIGRET=%lu", (DWORD)r);
}
static void unregister_notifications(void) {
    HMODULE m = GetModuleHandleW(L"cfgmgr32.dll");
    cm_unregister_fn un = m ? (cm_unregister_fn)(void *)GetProcAddress(m, "CM_Unregister_Notification") : 0;
    if (un && notify_handle) un(notify_handle);
    notify_handle = 0;
}

/* ---- run: the watchdog drives the schedule ---- */
static volatile LONG stop_reason;  /* 1 SCM stop, 2 shutdown, 3 console Ctrl */
static void run(void) {
    InitializeCriticalSection(&lock);
    stop_event = CreateEventW(0, TRUE, FALSE, 0);
    go_event = CreateEventW(0, FALSE, FALSE, 0);
    start_tick = now_tick();
    {   WCHAR dir[MAX_PATH]; lstrcpyW(dir, log_path);
        for (int i = lstrlenW(dir); i > 0; i--) if (dir[i - 1] == L'\\') { dir[i - 1] = 0; break; }
        CreateDirectoryW(dir, 0); }
    boot_no = next_boot_number();
    if (!open_log()) return;
    start_record();
    register_notifications();
    commit();
    HANDLE bcd = CreateThread(0, 0, bcd_thread, 0, 0, 0);
    if (bcd) CloseHandle(bcd);
    round_done_tick = now_tick();
    HANDLE probe = CreateThread(0, 0, probe_thread, 0, 0, 0);
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_HIGHEST);
    ULONGLONG next = now_tick() + 1000, oobe_done_at = 0;
    BOOL saw_setup = FALSE;
    const char *reason = "30 minutes";
    for (;;) {
        ULONGLONG t = now_tick();
        DWORD wait = next > t ? (DWORD)(next - t) : 0;
        if (WaitForSingleObject(stop_event, wait) == WAIT_OBJECT_0) { reason = stop_reason == 2 ? "system shutdown (SCM SHUTDOWN control)" : stop_reason == 3 ? "console stop" : "SCM stop"; break; }
        t = now_tick();
        DWORD run_ms = (DWORD)(t - start_tick);
        if (console_mode && run_ms >= console_seconds * 1000u) { reason = "console time limit"; break; }
        if (run_ms >= MAX_RUN_MS) break;
        if (setup_in_progress == 1 || oobe_in_progress == 1) saw_setup = TRUE;
        else if (setup_in_progress == 0 && oobe_in_progress == 0) {
            if (saw_setup && !oobe_done_at) { oobe_done_at = t; line_now("INFO Setup / OOBE finished (SystemSetupInProgress=0, OOBEInProgress=0); stopping in 30 s"); }
            if (!console_mode && saw_setup && t - oobe_done_at >= AFTER_OOBE_MS) { reason = "OOBE complete"; break; }
            if (!console_mode && !saw_setup && run_ms >= NORMAL_BOOT_MS) { reason = "not a Setup boot, 2 minutes recorded"; break; }
        }
        ULONGLONG late = t - round_done_tick;
        if (late > 1500 && probe_name[0] != 'i') line_now("W STALL in %s for %lu ms (round late %lu ms)", (const char *)probe_name, (DWORD)(t - probe_since), (DWORD)late);
        SetEvent(go_event);
        next += run_ms < FAST_PHASE_MS ? 1000 : 10000;
        if (next < t) next = t + 1000;
    }
    SetEvent(stop_event);
    if (probe) { WaitForSingleObject(probe, 3000); CloseHandle(probe); }
    unregister_notifications();
    line_now("END %s after %lu s", reason, (DWORD)(now_tick() - start_tick) / 1000u);
    CloseHandle(logf); logf = INVALID_HANDLE_VALUE;
}

/* ---- service / console ---- */
static SERVICE_STATUS_HANDLE status_handle;
static SERVICE_STATUS status;
static void report(DWORD state) {
    status.dwServiceType = SERVICE_WIN32_OWN_PROCESS; status.dwCurrentState = state;
    status.dwControlsAccepted = state == SERVICE_RUNNING ? SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN : 0;
    status.dwWin32ExitCode = NO_ERROR; status.dwWaitHint = 0;
    if (status_handle) SetServiceStatus(status_handle, &status);
}
static DWORD WINAPI control(DWORD code, DWORD type, LPVOID data, LPVOID ctx) {
    (void)type; (void)data; (void)ctx;
    if (code == SERVICE_CONTROL_STOP || code == SERVICE_CONTROL_SHUTDOWN) {
        stop_reason = code == SERVICE_CONTROL_SHUTDOWN ? 2 : 1;
        report(SERVICE_STOP_PENDING);
        if (code == SERVICE_CONTROL_SHUTDOWN) line_now("SHUTDOWN SCM shutdown control received (orderly shutdown / restart)");
        SetEvent(stop_event);
    }
    return NO_ERROR;
}
static void WINAPI service_main(DWORD argc, LPWSTR *argv) {
    (void)argc; (void)argv;
    status_handle = RegisterServiceCtrlHandlerExW(L"USOSFLT", control, 0);
    report(SERVICE_RUNNING);  /* at once: never delays the auto-start group */
    run();
    report(SERVICE_STOPPED);
}
static BOOL WINAPI console_ctrl(DWORD type) { (void)type; stop_reason = 3; if (stop_event) SetEvent(stop_event); return TRUE; }

void entry(void) {
    int argc = 0;
    WCHAR **argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    WCHAR win[MAX_PATH];
    if (GetWindowsDirectoryW(win, MAX_PATH) >= 3 && win[1] == L':') { root[0] = win[0]; }
    if (argv && argc >= 2 && lstrcmpiW(argv[1], L"/remove") == 0) {
        SC_HANDLE m = OpenSCManagerW(0, 0, SC_MANAGER_CONNECT), s = m ? OpenServiceW(m, L"USOSFLT", DELETE) : 0;
        BOOL ok = s && DeleteService(s);
        if (s) CloseServiceHandle(s);
        if (m) CloseServiceHandle(m);
        ExitProcess(ok ? 0 : 1);
    }
    if (argv && argc >= 3 && lstrcmpiW(argv[1], L"/console") == 0 && lstrlenW(argv[2]) < MAX_PATH - 8) {
        console_mode = TRUE;
        lstrcpyW(log_path, argv[2]);
        lstrcpyW(cnt_path, argv[2]); lstrcatW(cnt_path, L".cnt");
        console_seconds = 20;
        if (argc >= 4) { DWORD v = 0; for (const WCHAR *c = argv[3]; *c >= L'0' && *c <= L'9'; c++) v = v * 10 + (DWORD)(*c - L'0'); if (v) console_seconds = v; }
        SetConsoleCtrlHandler(console_ctrl, TRUE);
        run();
        ExitProcess(logf == INVALID_HANDLE_VALUE && boot_no ? 0 : 4);
    }
    lstrcpyW(log_path, root); lstrcatW(log_path, L"USOS\\FLIGHT.LOG");
    lstrcpyW(cnt_path, root); lstrcatW(cnt_path, L"USOS\\FLIGHT.CNT");
    SERVICE_TABLE_ENTRYW table[2] = { { (LPWSTR)L"USOSFLT", service_main }, { 0, 0 } };
    ExitProcess(StartServiceCtrlDispatcherW(table) ? 0 : 1);
}
