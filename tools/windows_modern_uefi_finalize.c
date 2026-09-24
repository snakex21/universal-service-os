/* WinPE-only guard and finalizer for Windows 10/11 Setup started natively from
 * UEFI (tools/windows_modern_uefi_startup.cmd). No C runtime.
 *
 *   before <disk>         inventory of the USOS stick's ESP (disk <disk>, the one
 *                         usos-source.exe --source-disk identified by GPT), a copy
 *                         of its EFI\BOOT files and the start time, beside this
 *                         executable in WinPE RAM.
 *   run-from "<exe>" ...  runs Windows Setup (with /noreboot) and records its exit code.
 *   after <disk>          1. finds the single Windows this Setup installed (on a disk
 *                            other than the stick; winload.efi plus a hive or Panther
 *                            log written after `before`);
 *                         2. makes sure its boot files and BCD are on an ESP of that
 *                            TARGET disk: kept when Setup wrote them there, otherwise
 *                            bcdboot <T>:\Windows /s <ESP> /f UEFI; an ESP is created
 *                            only in unallocated space (never by shrinking);
 *                         3. removes from the stick's ESP only what Setup added
 *                            (EFI\Microsoft\..., a new BCD) and restores EFI\BOOT files
 *                            it changed, then verifies the ESP equals the inventory
 *                            except EFI\USOS\Logs;
 *                         4. drops firmware boot entries for bootmgfw.efi on the stick
 *                            and checks one points at the target's ESP.
 *                         Any doubt stops before step 3: nothing is deleted from the
 *                         stick unless the target boots on its own.
 * Disk and partition identities come from IOCTLs, never from drive letters or labels.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winioctl.h>
#include <stddef.h>
#include "windows_setup_result.h"

#define MAX_ENTRIES 4096
#define MAX_VOLUMES 128
#define REL 260
typedef struct { WCHAR path[REL]; ULONGLONG size; FILETIME write; DWORD attr; } Entry;
typedef struct { DWORD magic, count, disk, nesps; FILETIME start; GUID esp_id; GUID esps[32]; Entry e[MAX_ENTRIES]; } Snapshot;
typedef struct { WCHAR name[MAX_PATH]; DWORD disk, part; int gpt; GUID type, id; } Volume;
static Snapshot before, now;
static Volume vols[MAX_VOLUMES];
static unsigned nvols;
static WCHAR base[MAX_PATH], a[1024], b[1024], line[2048];
static BYTE buffer[65536], other[65536];
static const GUID esp_type = {0xc12a7328, 0xf81f, 0x11d2, {0xba, 0x4b, 0, 0xa0, 0xc9, 0x3e, 0xc9, 0x3b}};
static const WCHAR efi_global[] = L"{8BE4DF61-93CA-11D2-AA0D-00E098032B8C}";

void *memcpy(void *dst, const void *src, size_t n) { volatile BYTE *p = dst; const BYTE *q = src; while (n--) *p++ = *q++; return dst; }
void *memset(void *dst, int c, size_t n) { volatile BYTE *p = dst; while (n--) *p++ = (BYTE)c; return dst; }
static void zero(void *v, unsigned n) { BYTE *p = v; while (n--) *p++ = 0; }
static int eq(const void *v, const void *w, unsigned n) { const BYTE *p = v, *q = w; while (n--) if (*p++ != *q++) return 0; return 1; }
static unsigned len(const WCHAR *p) { unsigned n = 0; while (p[n]) n++; return n; }
static void copy(WCHAR *p, const WCHAR *q) { while ((*p++ = *q++)); }
static void cat(WCHAR *p, const WCHAR *q) { copy(p + len(p), q); }
static WCHAR up(WCHAR c) { return c >= 'a' && c <= 'z' ? c - 32 : c; }
static int ieq(const WCHAR *p, const WCHAR *q) { while (*p && up(*p) == up(*q)) { p++; q++; } return up(*p) == up(*q); }
static int iprefix(const WCHAR *s, const WCHAR *prefix) { while (*prefix) { if (up(*s++) != up(*prefix++)) return 0; } return 1; }
static int icontains(const WCHAR *s, const WCHAR *needle) { for (; *s; s++) if (iprefix(s, needle)) return 1; return 0; }
static void say(const char *p) { DWORD n = 0, w; while (p[n]) n++; WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), p, n, &w, 0); }
static void sayw(const WCHAR *p) { char out[600]; unsigned i = 0; while (p[i] && i < sizeof(out) - 1) { out[i] = p[i] < 128 ? (char)p[i] : '?'; i++; } out[i] = 0; say(out); }
static void number(ULONGLONG n) { char s[24]; unsigned i = 23; s[i] = 0; do { s[--i] = (char)('0' + n % 10); n /= 10; } while (n); say(s + i); }
static void append_number(WCHAR *s, ULONGLONG n) { WCHAR d[24]; unsigned i = 0; do { d[i++] = (WCHAR)('0' + n % 10); n /= 10; } while (n); unsigned at = len(s); while (i) s[at++] = d[--i]; s[at] = 0; }
static void guid_text(WCHAR *out, const GUID *g) {
    static const char hex[] = "0123456789ABCDEF";
    const BYTE *p = (const BYTE *)g; const int order[16] = {3, 2, 1, 0, 5, 4, 7, 6, 8, 9, 10, 11, 12, 13, 14, 15};
    unsigned at = 0;
    for (unsigned i = 0; i < 16; i++) { if (i == 4 || i == 6 || i == 8 || i == 10) out[at++] = '-'; out[at++] = hex[p[order[i]] >> 4]; out[at++] = hex[p[order[i]] & 15]; }
    out[at] = 0;
}
static int fail(const char *p) { say("USOS ESP guard: "); say(p); say("\r\n"); return 1; }
static int later(const FILETIME *t, const FILETIME *start) {
    ULARGE_INTEGER x, y; x.LowPart = t->dwLowDateTime; x.HighPart = t->dwHighDateTime; y.LowPart = start->dwLowDateTime; y.HighPart = start->dwHighDateTime;
    return x.QuadPart > y.QuadPart;
}
static int attributes(const WCHAR *path, WIN32_FILE_ATTRIBUTE_DATA *d) { return GetFileAttributesExW(path, GetFileExInfoStandard, d); }

/* ------------------------------------------------------------------ volumes */
static int volumes(void) {
    nvols = 0;
    WCHAR name[64];
    HANDLE find = FindFirstVolumeW(name, 64);
    if (find == INVALID_HANDLE_VALUE) return 0;
    do {
        unsigned n = len(name);
        if (n < 5 || name[n - 1] != '\\' || nvols == MAX_VOLUMES) continue;
        copy(a, name); a[n - 1] = 0;
        HANDLE h = CreateFileW(a, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, 0, OPEN_EXISTING, 0, 0);
        if (h == INVALID_HANDLE_VALUE) continue;
        STORAGE_DEVICE_NUMBER number; PARTITION_INFORMATION_EX part; DWORD got = 0;
        int ok = DeviceIoControl(h, IOCTL_STORAGE_GET_DEVICE_NUMBER, 0, 0, &number, sizeof(number), &got, 0) && number.DeviceType == FILE_DEVICE_DISK;
        int gpt = ok && DeviceIoControl(h, IOCTL_DISK_GET_PARTITION_INFO_EX, 0, 0, &part, sizeof(part), &got, 0) && part.PartitionStyle == PARTITION_STYLE_GPT;
        CloseHandle(h);
        if (!ok) continue;
        Volume *v = &vols[nvols++]; zero(v, sizeof(*v));
        copy(v->name, name); v->disk = number.DeviceNumber; v->part = number.PartitionNumber; v->gpt = gpt;
        if (gpt) { v->type = part.Gpt.PartitionType; v->id = part.Gpt.PartitionId; }
    } while (FindNextVolumeW(find, name, 64));
    FindVolumeClose(find);
    return 1;
}
static Volume *esp_on(DWORD disk, unsigned *count) {
    Volume *found = 0; *count = 0;
    for (unsigned i = 0; i < nvols; i++) if (vols[i].disk == disk && vols[i].gpt && eq(&vols[i].type, &esp_type, sizeof(GUID))) { found = &vols[i]; (*count)++; }
    return found;
}
/* Drive letter root ("C:\") of a volume, mounting it at a free letter if needed. */
static WCHAR mounted[26];
static int letter_of(Volume *v, WCHAR *root) {
    DWORD got = 0;
    if (GetVolumePathNamesForVolumeNameW(v->name, line, 2048, &got)) {
        for (WCHAR *p = line; *p; p += len(p) + 1) if (len(p) == 3 && p[1] == ':' && p[2] == '\\') { copy(root, p); return 1; }
    }
    DWORD used = GetLogicalDrives();
    for (int i = 18; i < 26; i++) {
        if (used & (1u << i) || i == 'X' - 'A') continue;
        root[0] = (WCHAR)('A' + i); root[1] = ':'; root[2] = '\\'; root[3] = 0;
        if (SetVolumeMountPointW(root, v->name)) { mounted[i] = 1; return 1; }
    }
    return 0;
}
static void unmount_all(void) {
    for (int i = 0; i < 26; i++) if (mounted[i]) { WCHAR root[4] = {(WCHAR)('A' + i), ':', '\\', 0}; DeleteVolumeMountPointW(root); mounted[i] = 0; }
}

/* ------------------------------------------------------------ ESP inventory */
static int is_logs(const WCHAR *path) { return iprefix(path, L"EFI\\USOS\\Logs\\") || ieq(path, L"EFI\\USOS\\Logs"); }
/* One directory level; relative paths, no trailing backslash. */
static int list_dir(Snapshot *s, const WCHAR *root, const WCHAR *rel) {
    WIN32_FIND_DATAW f;
    copy(a, root); cat(a, rel); if (rel[0]) cat(a, L"\\"); cat(a, L"*");
    HANDLE h = FindFirstFileW(a, &f);
    if (h == INVALID_HANDLE_VALUE) return GetLastError() == ERROR_FILE_NOT_FOUND;
    int ok = 1;
    do {
        if ((f.cFileName[0] == '.' && !f.cFileName[1]) || (f.cFileName[0] == '.' && f.cFileName[1] == '.' && !f.cFileName[2])) continue;
        if (s->count == MAX_ENTRIES || len(rel) + len(f.cFileName) + 2 >= REL) { ok = 0; break; }
        Entry *e = &s->e[s->count++];
        copy(e->path, rel); if (rel[0]) cat(e->path, L"\\"); cat(e->path, f.cFileName);
        e->attr = f.dwFileAttributes; e->write = f.ftLastWriteTime;
        e->size = ((ULONGLONG)f.nFileSizeHigh << 32) | f.nFileSizeLow;
    } while (FindNextFileW(h, &f));
    FindClose(h);
    return ok;
}
/* Breadth-first over the entries already listed; EFI\USOS\Logs is recorded
 * but not entered (USOS writes its own logs there during Setup). */
static int inventory(Snapshot *s, const Volume *esp) {
    s->count = 0; s->esp_id = esp->id;
    if (!list_dir(s, esp->name, L"")) return 0;
    for (unsigned i = 0; i < s->count; i++) {
        if (!(s->e[i].attr & FILE_ATTRIBUTE_DIRECTORY) || is_logs(s->e[i].path)) continue;
        static WCHAR rel[REL]; copy(rel, s->e[i].path);
        if (!list_dir(s, esp->name, rel)) return 0;
    }
    return 1;
}
static Entry *find(Snapshot *s, const WCHAR *path) { for (unsigned i = 0; i < s->count; i++) if (ieq(s->e[i].path, path)) return &s->e[i]; return 0; }
static int is_backed_up(const WCHAR *path) { return iprefix(path, L"EFI\\BOOT\\"); }
static int state_file(int write) {
    copy(a, base); cat(a, L"esp-before.bin");
    HANDLE h = CreateFileW(a, write ? GENERIC_WRITE : GENERIC_READ, FILE_SHARE_READ, 0, write ? CREATE_ALWAYS : OPEN_EXISTING, 0, 0);
    if (h == INVALID_HANDLE_VALUE) return 0;
    DWORD n = 0; int ok = write ? WriteFile(h, &before, sizeof(before), &n, 0) : ReadFile(h, &before, sizeof(before), &n, 0);
    if (write) ok = ok && FlushFileBuffers(h);
    CloseHandle(h);
    return ok && n == sizeof(before) && before.magic == 0x31505345 && before.count <= MAX_ENTRIES;
}
static int same_file(const WCHAR *p, const WCHAR *q) {
    HANDLE x = CreateFileW(p, GENERIC_READ, FILE_SHARE_READ, 0, OPEN_EXISTING, 0, 0), y = CreateFileW(q, GENERIC_READ, FILE_SHARE_READ, 0, OPEN_EXISTING, 0, 0);
    int ok = x != INVALID_HANDLE_VALUE && y != INVALID_HANDLE_VALUE;
    LARGE_INTEGER xs, ys; if (ok) ok = GetFileSizeEx(x, &xs) && GetFileSizeEx(y, &ys) && xs.QuadPart == ys.QuadPart;
    while (ok) { DWORD xn = 0, yn = 0; ok = ReadFile(x, buffer, sizeof(buffer), &xn, 0) && ReadFile(y, other, sizeof(other), &yn, 0) && xn == yn && eq(buffer, other, xn); if (!xn) break; }
    if (x != INVALID_HANDLE_VALUE) CloseHandle(x); if (y != INVALID_HANDLE_VALUE) CloseHandle(y);
    return ok;
}
static void backup_path(WCHAR *out, const WCHAR *rel) { copy(out, base); cat(out, L"esp-backup\\"); cat(out, rel); }
static int make_parents(WCHAR *path) {
    for (unsigned i = 3; path[i]; i++) if (path[i] == '\\') { path[i] = 0; if (!CreateDirectoryW(path, 0) && GetLastError() != ERROR_ALREADY_EXISTS) { path[i] = '\\'; return 0; } path[i] = '\\'; }
    return 1;
}
/* EFI\BOOT (shim, grubx64, mmx64, ...) is the part of the stick's ESP that
 * Windows Setup/bcdboot could overwrite; its files are kept in WinPE RAM. */
static int backup_boot_files(const Volume *esp, unsigned *saved) {
    *saved = 0;
    for (unsigned i = 0; i < before.count; i++) {
        Entry *e = &before.e[i];
        if ((e->attr & FILE_ATTRIBUTE_DIRECTORY) || !is_backed_up(e->path)) continue;
        copy(a, esp->name); cat(a, e->path); backup_path(b, e->path);
        if (!make_parents(b) || !CopyFileW(a, b, FALSE) || !same_file(a, b)) return 0;
        (*saved)++;
    }
    return 1;
}
static const Volume *stick_esp(DWORD disk) {
    unsigned count = 0; Volume *v = esp_on(disk, &count);
    if (count != 1) { say("USOS ESP guard: ESP partitions on the USOS disk="); number(count); say("\r\n"); return 0; }
    return v;
}

/* ---------------------------------------------------------------- commands */
static int run_child(WCHAR *command, const WCHAR *exe) {
    STARTUPINFOW si; PROCESS_INFORMATION pi; zero(&si, sizeof(si)); zero(&pi, sizeof(pi)); si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES; si.hStdInput = GetStdHandle(STD_INPUT_HANDLE); si.hStdOutput = si.hStdError = GetStdHandle(STD_OUTPUT_HANDLE);
    if (!CreateProcessW(exe, command, 0, 0, TRUE, CREATE_NO_WINDOW, 0, 0, &si, &pi)) return -1;
    DWORD code = 1; WaitForSingleObject(pi.hProcess, INFINITE); GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
    return (int)code;
}
static int system_tool(const WCHAR *name, WCHAR *exe) {
    unsigned n = GetSystemDirectoryW(exe, MAX_PATH); if (!n || n > MAX_PATH - 20) return 0;
    cat(exe, L"\\"); cat(exe, name);
    return GetFileAttributesW(exe) != INVALID_FILE_ATTRIBUTES;
}

/* ESP partitions on every disk except the USOS stick, as NT device paths
 * (\Device\HarddiskN\PartitionM) with their GPT identities. */
typedef struct { GUID id; WCHAR device[64]; } EspPart;
static EspPart esp_parts[32];
static unsigned esp_count;
static int internal_esps(DWORD skip_disk) {
    esp_count = 0;
    for (DWORD disk = 0; disk < 64; disk++) {
        if (disk == skip_disk) continue;
        copy(a, L"\\\\.\\PhysicalDrive"); append_number(a, disk);
        HANDLE h = CreateFileW(a, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, 0, OPEN_EXISTING, 0, 0);
        if (h == INVALID_HANDLE_VALUE) continue;
        DWORD got = 0; int ok = DeviceIoControl(h, IOCTL_DISK_GET_DRIVE_LAYOUT_EX, 0, 0, other, sizeof(other), &got, 0); CloseHandle(h);
        if (!ok || got < offsetof(DRIVE_LAYOUT_INFORMATION_EX, PartitionEntry)) continue;
        DRIVE_LAYOUT_INFORMATION_EX *layout = (void *)other;
        if (layout->PartitionStyle != PARTITION_STYLE_GPT) continue;
        for (DWORD i = 0; i < layout->PartitionCount; i++) {
            PARTITION_INFORMATION_EX *p = &layout->PartitionEntry[i];
            if (p->PartitionStyle != PARTITION_STYLE_GPT || !eq(&p->Gpt.PartitionType, &esp_type, sizeof(GUID)) || p->PartitionLength.QuadPart <= 0) continue;
            if (esp_count == 32) return 0;
            EspPart *e = &esp_parts[esp_count++]; e->id = p->Gpt.PartitionId;
            copy(e->device, L"\\Device\\Harddisk"); append_number(e->device, disk); cat(e->device, L"\\Partition"); append_number(e->device, p->PartitionNumber);
        }
    }
    return 1;
}
/* bcdedit /sysstore: the volatile system-store hint for this WinPE session
 * (the same technique as windows7_uefi_finalize.c). Booted through wimboot,
 * WinPE has no firmware system device Setup can resolve ("GetSystemDiskNTPath:
 * Unable to get required buffer size for system disk from BCD APIs"), so Setup
 * rejects even the ESP it just created and fails (seen in QEMU: 0xC0000005 in
 * WinSetup.dll after "Couldn't find any system volumes on this EFI-based
 * computer"). Pointing the hint at the unique ESP of a non-USOS disk lets Setup
 * put its boot files there. No partition or file is written by this. */
static WCHAR bcdedit_path[MAX_PATH];
static GUID store_id;
static int have_store;
static int set_temporary_store(const WCHAR *device) {
    DWORD letters = GetLogicalDrives(); if (!letters) return 0;
    WCHAR alias[3] = {0, ':', 0}; for (int i = 25; i >= 3; i--) if (!(letters & (1u << i))) { alias[0] = (WCHAR)('A' + i); break; }
    if (!alias[0]) return 0;
    if (!DefineDosDeviceW(DDD_RAW_TARGET_PATH | DDD_NO_BROADCAST_SYSTEM, alias, device)) return 0;
    WCHAR command[MAX_PATH + 48]; copy(command, L"\""); cat(command, bcdedit_path); cat(command, L"\" /sysstore "); cat(command, alias);
    STARTUPINFOW si; PROCESS_INFORMATION pi; zero(&si, sizeof(si)); zero(&pi, sizeof(pi)); si.cb = sizeof(si); DWORD result = 1;
    int ok = CreateProcessW(bcdedit_path, command, 0, 0, FALSE, CREATE_NO_WINDOW, 0, 0, &si, &pi);
    if (ok) { ok = WaitForSingleObject(pi.hProcess, INFINITE) == WAIT_OBJECT_0 && GetExitCodeProcess(pi.hProcess, &result); CloseHandle(pi.hThread); CloseHandle(pi.hProcess); }
    int removed = DefineDosDeviceW(DDD_REMOVE_DEFINITION | DDD_EXACT_MATCH_ON_REMOVE | DDD_RAW_TARGET_PATH | DDD_NO_BROADCAST_SYSTEM, alias, device);
    return ok && result == 0 && removed;
}
static void refresh_system_store(void) {
    if (!internal_esps(before.disk)) return;
    EspPart *candidate = 0; unsigned count = 0;
    if (esp_count == 1) { candidate = &esp_parts[0]; count = 1; }
    else for (unsigned i = 0; i < esp_count; i++) {
        int old = 0; for (unsigned j = 0; j < before.nesps; j++) if (eq(&esp_parts[i].id, &before.esps[j], sizeof(GUID))) old = 1;
        if (!old) { candidate = &esp_parts[i]; count++; }
    }
    if (count != 1 || !candidate || (have_store && eq(&candidate->id, &store_id, sizeof(GUID)))) return;
    if (!set_temporary_store(candidate->device)) return;
    store_id = candidate->id; have_store = 1;
    say("USOS ESP guard: system store for this WinPE session -> "); sayw(candidate->device); say(" (not the USOS stick)\r\n");
}

static int cmd_before(DWORD disk) {
    if (!volumes()) return fail("cannot enumerate volumes");
    const Volume *esp = stick_esp(disk); if (!esp) return fail("the USOS stick's ESP is not unique; Setup was not started");
    zero(&before, offsetof(Snapshot, e)); before.magic = 0x31505345; before.disk = disk;
    GetSystemTimeAsFileTime(&before.start);
    if (!inventory(&before, esp)) return fail("cannot list the USOS stick's ESP");
    if (!internal_esps(disk)) return fail("cannot list the ESPs of the other disks");
    before.nesps = esp_count; for (unsigned i = 0; i < esp_count; i++) before.esps[i] = esp_parts[i].id;
    unsigned saved = 0;
    if (!backup_boot_files(esp, &saved)) return fail("cannot keep a copy of the ESP boot files in WinPE RAM");
    WCHAR id[40]; guid_text(id, &before.esp_id);
    say("USOS ESP guard: USOS disk "); number(disk); say(", ESP {"); sayw(id); say("}, entries="); number(before.count); say(", EFI\\BOOT copies="); number(saved); say("\r\n");
    return state_file(1) ? 0 : fail("cannot save the ESP inventory");
}

static int cmd_run(const WCHAR *executable, const WCHAR *arguments) {
    if (!state_file(0)) return fail("no ESP inventory; Setup was not started");
    if (!system_tool(L"bcdedit.exe", bcdedit_path)) return fail("bcdedit.exe is missing in WinPE");
    static WCHAR command[8192]; if (len(executable) + len(arguments) + 4 >= 8192) return 1;
    copy(command, L"\""); cat(command, executable); cat(command, L"\" "); cat(command, arguments);
    refresh_system_store();
    STARTUPINFOW si; PROCESS_INFORMATION pi; zero(&si, sizeof(si)); zero(&pi, sizeof(pi)); si.cb = sizeof(si);
    if (!CreateProcessW(executable, command, 0, 0, FALSE, 0, 0, 0, &si, &pi)) return fail("cannot launch Windows Setup");
    CloseHandle(pi.hThread);
    DWORD wait, result = 1;
    while ((wait = WaitForSingleObject(pi.hProcess, 100)) == WAIT_TIMEOUT) refresh_system_store();
    int ok = wait == WAIT_OBJECT_0 && GetExitCodeProcess(pi.hProcess, &result);
    CloseHandle(pi.hProcess);
    if (ok) usos_record_setup_result(result);
    say("USOS ESP guard: Windows Setup exit code "); number(result); say("\r\n");
    return ok ? (int)result : 1;
}

/* The Windows this Setup run installed: not on the USOS disk, winload.efi,
 * and its SYSTEM hive or Panther log written after `before`. */
static Volume *target_windows(unsigned *count) {
    Volume *found = 0; *count = 0;
    for (unsigned i = 0; i < nvols; i++) {
        Volume *v = &vols[i];
        if (v->disk == before.disk) continue;
        WIN32_FILE_ATTRIBUTE_DATA d;
        copy(a, v->name); cat(a, L"Windows\\System32\\winload.efi");
        if (!attributes(a, &d)) continue;
        int fresh = 0;
        copy(a, v->name); cat(a, L"Windows\\System32\\config\\SYSTEM");
        if (attributes(a, &d) && later(&d.ftLastWriteTime, &before.start)) fresh = 1;
        copy(a, v->name); cat(a, L"Windows\\Panther\\setupact.log");
        if (attributes(a, &d) && later(&d.ftLastWriteTime, &before.start)) fresh = 1;
        if (!fresh) continue;
        found = v; (*count)++;
    }
    return found;
}

/* Largest unallocated GPT region of disk `disk`, in bytes. */
static ULONGLONG largest_gap(DWORD disk, int *gpt) {
    copy(a, L"\\\\.\\PhysicalDrive"); append_number(a, disk);
    HANDLE h = CreateFileW(a, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, 0, OPEN_EXISTING, 0, 0);
    if (h == INVALID_HANDLE_VALUE) return 0;
    DWORD got = 0; int ok = DeviceIoControl(h, IOCTL_DISK_GET_DRIVE_LAYOUT_EX, 0, 0, buffer, sizeof(buffer), &got, 0); CloseHandle(h);
    if (!ok || got < offsetof(DRIVE_LAYOUT_INFORMATION_EX, PartitionEntry)) return 0;
    DRIVE_LAYOUT_INFORMATION_EX *layout = (void *)buffer;
    *gpt = layout->PartitionStyle == PARTITION_STYLE_GPT; if (!*gpt) return 0;
    ULONGLONG first = layout->Gpt.StartingUsableOffset.QuadPart, end = first + layout->Gpt.UsableLength.QuadPart, best = 0;
    for (ULONGLONG cursor = first;;) {
        ULONGLONG next = end, next_end = end;
        for (DWORD i = 0; i < layout->PartitionCount; i++) {
            PARTITION_INFORMATION_EX *p = &layout->PartitionEntry[i];
            if (!p->PartitionLength.QuadPart) continue;
            ULONGLONG s = p->StartingOffset.QuadPart, e = s + p->PartitionLength.QuadPart;
            if (e <= cursor) continue;
            if (s <= cursor) { cursor = e; next = cursor; next_end = cursor; i = (DWORD)-1; continue; }
            if (s < next) { next = s; next_end = e; }
        }
        if (next > cursor && next - cursor > best) best = next - cursor;
        if (next >= end) break;
        cursor = next_end;
    }
    return best;
}

static int create_esp(DWORD disk) {
    int gpt = 0; ULONGLONG gap = largest_gap(disk, &gpt);
    if (!gpt) return fail("the target disk is not GPT; UEFI cannot start Windows from it");
    say("USOS ESP guard: largest unallocated region on the target disk = "); number(gap >> 20); say(" MiB\r\n");
    if (gap < 300ull * 1024 * 1024) return fail("the target disk has no ESP and no unallocated space for one (260 MB); nothing was changed on the USOS stick");
    copy(a, base); cat(a, L"usos-create-esp.txt");
    HANDLE h = CreateFileW(a, GENERIC_WRITE, 0, 0, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    if (h == INVALID_HANDLE_VALUE) return fail("cannot write the diskpart script");
    char script[160]; unsigned at = 0; const char *parts[] = {"select disk ", 0, "\r\ncreate partition efi size=260\r\nformat quick fs=fat32 label=\"System\"\r\nexit\r\n"};
    for (const char *p = parts[0]; *p;) script[at++] = *p++;
    { char d[12]; unsigned i = 11; d[i] = 0; DWORD n = disk; do { d[--i] = (char)('0' + n % 10); n /= 10; } while (n); for (char *p = d + i; *p;) script[at++] = *p++; }
    for (const char *p = parts[2]; *p;) script[at++] = *p++;
    DWORD w = 0; int ok = WriteFile(h, script, at, &w, 0) && w == at; CloseHandle(h);
    if (!ok) return fail("cannot write the diskpart script");
    WCHAR exe[MAX_PATH]; if (!system_tool(L"diskpart.exe", exe)) return fail("diskpart.exe is missing in WinPE");
    copy(line, L"\""); cat(line, exe); cat(line, L"\" /s \""); cat(line, a); cat(line, L"\"");
    say("USOS ESP guard: creating a 260 MB ESP in unallocated space of the target disk\r\n");
    if (run_child(line, exe) != 0) return fail("diskpart could not create the ESP on the target disk");
    return 0;
}

/* Firmware boot entries (EFI_LOAD_OPTION): remove those that start bootmgfw.efi
 * from the stick's ESP; report whether one starts it from the target ESP. */
static int enable_privilege(void) {
    HANDLE token; TOKEN_PRIVILEGES tp;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &token)) return 0;
    int ok = LookupPrivilegeValueW(0, L"SeSystemEnvironmentPrivilege", &tp.Privileges[0].Luid);
    tp.PrivilegeCount = 1; tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
    ok = ok && AdjustTokenPrivileges(token, FALSE, &tp, 0, 0, 0) && GetLastError() == ERROR_SUCCESS;
    CloseHandle(token); return ok;
}
static void boot_name(WCHAR *out, unsigned n) { static const char hex[] = "0123456789ABCDEF"; copy(out, L"Boot0000"); for (int i = 0; i < 4; i++) out[7 - i] = hex[(n >> (4 * i)) & 15]; }
/* 1 = HD(signature = id) node plus a file path containing bootmgfw.efi. */
static int option_points(const BYTE *p, DWORD size, const GUID *id) {
    if (size < 6) return 0;
    WORD list = *(const WORD *)(p + 4); DWORD at = 6;
    while (at + 1 < size && (p[at] | p[at + 1] << 8)) at += 2;
    at += 2; if (at + list > size) return 0;
    int disk = 0, file = 0; DWORD end = at + list;
    while (at + 4 <= end) {
        BYTE type = p[at], sub = p[at + 1]; WORD n = *(const WORD *)(p + at + 2);
        if (n < 4 || at + n > end) break;
        if (type == 0x7f) break;
        if (type == 4 && sub == 1 && n >= 42 && p[at + 41] == 2 && eq(p + at + 24, id, 16)) disk = 1;
        if (type == 4 && sub == 4) { WCHAR path[260]; unsigned c = 0; for (DWORD i = at + 4; i + 1 < at + n && c < 259; i += 2) path[c++] = p[i] | p[i + 1] << 8; path[c] = 0; if (icontains(path, L"bootmgfw.efi")) file = 1; }
        at += n;
    }
    return disk && file;
}
static int firmware_entries(const GUID *stick, const GUID *target) {
    if (!enable_privilege()) { say("USOS ESP guard: WARNING no firmware-variable privilege; boot entries not checked\r\n"); return 1; }
    WORD order[128]; DWORD got = GetFirmwareEnvironmentVariableW(L"BootOrder", efi_global, order, sizeof(order));
    if (!got || got % 2) { say("USOS ESP guard: WARNING BootOrder unreadable\r\n"); return 1; }
    unsigned count = got / 2, kept = 0, target_first = 0, target_any = 0, removed = 0;
    WORD out[128];
    for (unsigned i = 0; i < count; i++) {
        WCHAR name[9]; boot_name(name, order[i]);
        DWORD n = GetFirmwareEnvironmentVariableW(name, efi_global, buffer, sizeof(buffer));
        if (n && option_points(buffer, n, stick)) {
            SetFirmwareEnvironmentVariableW(name, efi_global, 0, 0);
            say("USOS ESP guard: removed firmware entry "); sayw(name); say(" (bootmgfw.efi on the USOS stick)\r\n"); removed++;
            continue;
        }
        if (n && option_points(buffer, n, target)) { target_any = 1; if (kept == 0) target_first = 1; }
        out[kept++] = order[i];
    }
    if (removed && !SetFirmwareEnvironmentVariableW(L"BootOrder", efi_global, out, kept * 2)) say("USOS ESP guard: WARNING BootOrder could not be rewritten\r\n");
    say("USOS ESP guard: Windows Boot Manager on the target ESP: "); say(target_any ? (target_first ? "first in BootOrder\r\n" : "present (not first)\r\n") : "MISSING\r\n");
    return target_any;
}

/* Restore the stick's ESP to the inventory taken before Setup (logs excepted). */
static int restore_stick(const Volume *esp, unsigned *deleted, unsigned *restored) {
    zero(&now, offsetof(Snapshot, e)); now.magic = before.magic;
    if (!inventory(&now, esp)) return fail("cannot list the USOS stick's ESP after Setup");
    *deleted = *restored = 0; int ok = 1;
    for (unsigned i = now.count; i-- > 0;) {   /* children before parents */
        Entry *e = &now.e[i];
        if (is_logs(e->path) || find(&before, e->path)) continue;
        copy(a, esp->name); cat(a, e->path);
        SetFileAttributesW(a, FILE_ATTRIBUTE_NORMAL);
        int gone = (e->attr & FILE_ATTRIBUTE_DIRECTORY) ? RemoveDirectoryW(a) : DeleteFileW(a);
        say(gone ? "USOS ESP guard: removed from the USOS stick: " : "USOS ESP guard: CANNOT remove from the USOS stick: "); sayw(e->path); say("\r\n");
        if (gone) (*deleted)++; else ok = 0;
    }
    for (unsigned i = 0; i < before.count; i++) {
        Entry *e = &before.e[i], *n = find(&now, e->path);
        if (is_logs(e->path) || (e->attr & FILE_ATTRIBUTE_DIRECTORY)) continue;
        if (n && n->size == e->size && eq(&n->write, &e->write, sizeof(FILETIME))) continue;
        if (!is_backed_up(e->path)) { say("USOS ESP guard: CHANGED on the USOS stick (no copy to restore): "); sayw(e->path); say("\r\n"); ok = 0; continue; }
        copy(a, esp->name); cat(a, e->path); backup_path(b, e->path);
        SetFileAttributesW(a, FILE_ATTRIBUTE_NORMAL);
        if (!CopyFileW(b, a, FALSE) || !same_file(a, b)) { say("USOS ESP guard: CANNOT restore "); sayw(e->path); say("\r\n"); ok = 0; continue; }
        SetFileAttributesW(a, e->attr);
        say("USOS ESP guard: restored on the USOS stick: "); sayw(e->path); say("\r\n"); (*restored)++;
    }
    return ok;
}
/* Verification: every entry of the inventory is back (restored ones by content),
 * nothing else exists, logs excepted. */
static int verify_stick(const Volume *esp) {
    zero(&now, offsetof(Snapshot, e)); now.magic = before.magic;
    if (!inventory(&now, esp)) return 0;
    unsigned differences = 0;
    for (unsigned i = 0; i < now.count; i++) if (!is_logs(now.e[i].path) && !find(&before, now.e[i].path)) { say("USOS ESP guard: VERIFY extra "); sayw(now.e[i].path); say("\r\n"); differences++; }
    for (unsigned i = 0; i < before.count; i++) {
        Entry *e = &before.e[i], *n = find(&now, e->path);
        if (is_logs(e->path)) continue;
        if (!n) { say("USOS ESP guard: VERIFY missing "); sayw(e->path); say("\r\n"); differences++; continue; }
        if (e->attr & FILE_ATTRIBUTE_DIRECTORY) continue;
        if (n->size == e->size && eq(&n->write, &e->write, sizeof(FILETIME))) continue;
        copy(a, esp->name); cat(a, e->path); backup_path(b, e->path);
        if (is_backed_up(e->path) && same_file(a, b)) continue;
        say("USOS ESP guard: VERIFY changed "); sayw(e->path); say("\r\n"); differences++;
    }
    say("USOS ESP guard: USOS stick ESP after Setup: "); number(now.count); say(" entries, differences outside EFI\\USOS\\Logs = "); number(differences); say("\r\n");
    return differences == 0;
}

static int cmd_after(DWORD disk) {
    if (!state_file(0) || before.disk != disk) return fail("no matching ESP inventory from before Setup");
    if (!volumes()) return fail("cannot enumerate volumes");
    const Volume *stick = stick_esp(disk); if (!stick || !eq(&stick->id, &before.esp_id, sizeof(GUID))) return fail("the USOS stick's ESP changed identity");
    unsigned count = 0; Volume *windows = target_windows(&count);
    say("USOS ESP guard: newly installed Windows volumes = "); number(count); say("\r\n");
    if (count != 1) return fail("expected exactly one new Windows installation; nothing was changed");
    DWORD target_disk = windows->disk;
    say("USOS ESP guard: target Windows on disk "); number(target_disk); say(" partition "); number(windows->part); say("\r\n");
    unsigned esps = 0; Volume *target = esp_on(target_disk, &esps);
    if (esps > 1) return fail("the target disk has more than one ESP; nothing was changed");
    if (!esps) {
        say("USOS ESP guard: Setup created no ESP on the target disk\r\n");
        if (create_esp(target_disk)) return 1;
        if (!volumes()) return fail("cannot enumerate volumes");
        windows = target_windows(&count); if (count != 1) return fail("the new Windows volume is no longer unique");
        target = esp_on(target_disk, &esps); if (esps != 1) return fail("the new ESP on the target disk was not found");
        stick = stick_esp(disk); if (!stick) return 1;
    }
    WIN32_FILE_ATTRIBUTE_DATA d; int fresh = 0;
    copy(a, target->name); cat(a, L"EFI\\Microsoft\\Boot\\BCD");
    if (attributes(a, &d) && later(&d.ftLastWriteTime, &before.start)) { copy(a, target->name); cat(a, L"EFI\\Microsoft\\Boot\\bootmgfw.efi"); fresh = attributes(a, &d); }
    copy(b, stick->name); cat(b, L"EFI\\Microsoft\\Boot\\BCD");
    int on_stick = !find(&before, L"EFI\\Microsoft\\Boot\\BCD") && attributes(b, &d);
    say("USOS ESP guard: boot files written by Setup: target ESP="); say(fresh ? "yes" : "no"); say(", USOS stick ESP="); say(on_stick ? "yes\r\n" : "no\r\n");
    if (!fresh) {
        WCHAR windows_root[4], esp_root[4], exe[MAX_PATH];
        if (!letter_of(windows, windows_root) || !letter_of(target, esp_root)) { unmount_all(); return fail("no drive letter for bcdboot"); }
        if (!system_tool(L"bcdboot.exe", exe)) { unmount_all(); return fail("bcdboot.exe is missing in WinPE"); }
        copy(line, L"\""); cat(line, exe); cat(line, L"\" "); cat(line, windows_root); cat(line, L"Windows /s "); esp_root[2] = 0; cat(line, esp_root); cat(line, L" /f UEFI");
        say("USOS ESP guard: "); sayw(line); say("\r\n");
        int code = run_child(line, exe);
        unmount_all();
        if (code != 0) return fail("bcdboot failed; the USOS stick was not changed");
        copy(a, target->name); cat(a, L"EFI\\Microsoft\\Boot\\BCD");
        copy(b, target->name); cat(b, L"EFI\\Microsoft\\Boot\\bootmgfw.efi");
        if (!attributes(a, &d) || !attributes(b, &d)) return fail("bcdboot reported success but the target ESP has no boot files");
    }
    say("USOS ESP guard: target ESP has EFI\\Microsoft\\Boot\\bootmgfw.efi and BCD\r\n");
    unsigned deleted = 0, restored = 0;
    int clean = restore_stick(stick, &deleted, &restored);
    say("USOS ESP guard: removed "); number(deleted); say(", restored "); number(restored); say(" entries on the USOS stick\r\n");
    int verified = verify_stick(stick);
    int entry = firmware_entries(&stick->id, &target->id);
    if (!clean || !verified) return fail("the USOS stick's ESP differs from before Setup (see above)");
    if (!entry) return fail("no firmware entry starts Windows from the target disk; use the firmware boot menu");
    say("USOS ESP guard: PASS target boots on its own; USOS stick ESP unchanged except EFI\\USOS\\Logs\r\n");
    return 0;
}

static DWORD parse_disk(const WCHAR *s) { DWORD n = 0; if (*s < '0' || *s > '9') return (DWORD)-1; while (*s >= '0' && *s <= '9') { n = n * 10 + (*s++ - '0'); if (n > 100000) return (DWORD)-1; } return *s ? (DWORD)-1 : n; }
#ifndef USOS_FINALIZE_TEST
void entry(void) {
    HKEY k; if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SYSTEM\\CurrentControlSet\\Control\\MiniNT", 0, KEY_READ, &k) != ERROR_SUCCESS) ExitProcess(1); RegCloseKey(k);
    unsigned n = GetModuleFileNameW(0, base, MAX_PATH); if (!n || n >= MAX_PATH - 64) ExitProcess(1); while (n && base[n - 1] != '\\') n--; base[n] = 0; if (!n) ExitProcess(1);
    const WCHAR *c = GetCommandLineW(); int quote = 0; while (*c) { if (*c == '"') quote = !quote; else if (*c == ' ' && !quote) break; c++; } while (*c == ' ') c++;
    if (iprefix(c, L"before ")) { DWORD d = parse_disk(c + 7); ExitProcess(d == (DWORD)-1 ? 2 : cmd_before(d)); }
    if (iprefix(c, L"after ")) { DWORD d = parse_disk(c + 6); ExitProcess(d == (DWORD)-1 ? 2 : cmd_after(d)); }
    if (iprefix(c, L"run-from \"")) {
        static WCHAR executable[MAX_PATH]; const WCHAR *start = c + 10; unsigned i = 0;
        while (start[i] && start[i] != '"' && i < MAX_PATH - 1) { executable[i] = start[i]; i++; }
        if (!i || start[i] != '"') ExitProcess(2); executable[i] = 0; c = start + i + 1; while (*c == ' ') c++;
        ExitProcess(cmd_run(executable, c));
    }
    ExitProcess(2);
}
#endif
