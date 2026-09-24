/* WinPE-less simulation of the Windows 10/11 ESP guard/finalizer
 * (tools/windows_modern_uefi_finalize.c), built and run on the host by
 * tools/tests/windows_native/test_modern_finalize.py. Directories under
 * argv[1] stand in for the USOS stick's ESP, the WinPE RAM folder and the
 * volumes; no disk, partition, firmware variable or BCD store is touched.
 *
 *  1. inventory + EFI\BOOT copy, then "Setup" adds EFI\Microsoft\Boot\{BCD,
 *     bootmgfw.efi}, overwrites EFI\BOOT\BOOTX64.EFI and USOS writes a log:
 *     restore removes Setup's files, restores BOOTX64.EFI, keeps the log, and
 *     the verification finds no difference;
 *  2. a changed file outside EFI\BOOT (no copy) is reported, not hidden;
 *  3. the new Windows is the single volume off the USOS disk with winload.efi
 *     and a hive written after `before`; an older installation is ignored;
 *  4. EFI_LOAD_OPTION parsing: only bootmgfw.efi on the given ESP matches.
 */
#define USOS_FINALIZE_TEST
#include "../../windows_modern_uefi_finalize.c"

static int failures;
static void check(int ok, const char *what) { say(ok ? "[PASS] " : "[FAIL] "); say(what); say("\r\n"); if (!ok) failures++; }
static WCHAR work[MAX_PATH];
static void join(WCHAR *out, const WCHAR *rel) { copy(out, work); cat(out, rel); }
static int put(const WCHAR *rel, const char *text) {
    WCHAR path[MAX_PATH]; join(path, rel); make_parents(path);
    SetFileAttributesW(path, FILE_ATTRIBUTE_NORMAL);
    HANDLE h = CreateFileW(path, GENERIC_WRITE, 0, 0, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    if (h == INVALID_HANDLE_VALUE) return 0;
    DWORD n = 0, w = 0; while (text[n]) n++; int ok = WriteFile(h, text, n, &w, 0) && w == n; CloseHandle(h); return ok;
}
static int content_is(const WCHAR *rel, const char *text) {
    WCHAR path[MAX_PATH]; join(path, rel);
    HANDLE h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, 0, OPEN_EXISTING, 0, 0);
    if (h == INVALID_HANDLE_VALUE) return 0;
    char got[256]; DWORD n = 0; int ok = ReadFile(h, got, sizeof(got) - 1, &n, 0); CloseHandle(h); got[n] = 0;
    unsigned i = 0; while (text[i] && got[i] == text[i]) i++; return ok && !text[i] && !got[i];
}
static int exists(const WCHAR *rel) { WCHAR path[MAX_PATH]; join(path, rel); return GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES; }

static void scenario_restore(void) {
    put(L"esp\\EFI\\BOOT\\BOOTX64.EFI", "shim");
    put(L"esp\\EFI\\BOOT\\grubx64.efi", "usos");
    put(L"esp\\EFI\\USOS\\build-info.ini", "build");
    put(L"esp\\EFI\\USOS\\Logs\\boot-timing.txt", "old log");
    Volume esp; zero(&esp, sizeof(esp)); join(esp.name, L"esp\\");
    join(base, L"ram\\"); CreateDirectoryW(base, 0);
    zero(&before, offsetof(Snapshot, e)); before.magic = 0x31505345; before.disk = 1;
    check(inventory(&before, &esp), "inventory of the stick ESP");
    unsigned saved = 0;
    check(backup_boot_files(&esp, &saved) && saved == 2, "EFI\\BOOT files kept in RAM (2)");
    Sleep(20);
    /* What Windows Setup / bcdboot may do to the firmware boot disk's ESP. */
    put(L"esp\\EFI\\Microsoft\\Boot\\BCD", "bcd");
    put(L"esp\\EFI\\Microsoft\\Boot\\bootmgfw.efi", "bootmgfw");
    put(L"esp\\EFI\\BOOT\\BOOTX64.EFI", "bootmgfw copy");
    /* USOS itself logs during Setup. */
    put(L"esp\\EFI\\USOS\\Logs\\WinSetup-1\\usos-startup.log", "new log");
    unsigned deleted = 0, restored = 0;
    check(restore_stick(&esp, &deleted, &restored), "restore reports a clean stick");
    check(deleted == 4 && restored == 1, "removed EFI\\Microsoft\\Boot\\{BCD,bootmgfw.efi}, Boot, Microsoft; restored BOOTX64.EFI");
    check(!exists(L"esp\\EFI\\Microsoft"), "EFI\\Microsoft is gone from the stick");
    check(content_is(L"esp\\EFI\\BOOT\\BOOTX64.EFI", "shim"), "BOOTX64.EFI is the shim again");
    check(exists(L"esp\\EFI\\USOS\\Logs\\WinSetup-1\\usos-startup.log"), "USOS logs written during Setup are kept");
    check(verify_stick(&esp), "verification: stick ESP equals the inventory except EFI\\USOS\\Logs");

    Sleep(20);
    put(L"esp\\EFI\\USOS\\build-info.ini", "changed by someone");
    check(!restore_stick(&esp, &deleted, &restored), "a changed file without a copy is reported");
    check(!verify_stick(&esp), "verification fails for it");
}

static void scenario_target(void) {
    nvols = 0;
    Volume *stick = &vols[nvols++]; zero(stick, sizeof(*stick)); stick->disk = 1; join(stick->name, L"stick\\");
    Volume *fresh = &vols[nvols++]; zero(fresh, sizeof(*fresh)); fresh->disk = 0; fresh->part = 3; join(fresh->name, L"new\\");
    Volume *old = &vols[nvols++]; zero(old, sizeof(*old)); old->disk = 2; old->part = 2; join(old->name, L"old\\");
    Volume *data = &vols[nvols++]; zero(data, sizeof(*data)); data->disk = 0; data->part = 4; join(data->name, L"data\\");
    put(L"old\\Windows\\System32\\winload.efi", "x");
    put(L"old\\Windows\\System32\\config\\SYSTEM", "old hive");
    put(L"stick\\Windows\\System32\\winload.efi", "x");
    put(L"stick\\Windows\\System32\\config\\SYSTEM", "x");
    put(L"data\\notes.txt", "x");
    Sleep(20);
    GetSystemTimeAsFileTime(&before.start); before.disk = 1;
    Sleep(20);
    put(L"new\\Windows\\System32\\winload.efi", "x");
    put(L"new\\Windows\\System32\\config\\SYSTEM", "new hive");
    put(L"stick\\Windows\\System32\\config\\SYSTEM", "touched");
    unsigned count = 0; Volume *found = target_windows(&count);
    for (unsigned i = 0; i < nvols; i++) {
        WIN32_FILE_ATTRIBUTE_DATA d; copy(a, vols[i].name); cat(a, L"Windows\\System32\\config\\SYSTEM");
        say("  "); sayw(vols[i].name + len(work)); say(" disk="); number(vols[i].disk);
        say(attributes(a, &d) ? (later(&d.ftLastWriteTime, &before.start) ? " hive=new" : " hive=old") : " hive=none"); say("\r\n");
    }
    say("  fresh volumes found: "); number(count); say(found == fresh ? " (new)" : found == old ? " (old)" : " (other)"); say("\r\n");
    check(count == 1 && found == fresh, "the new Windows is the single fresh one off the USOS disk");
}

static void scenario_load_option(void) {
    static const GUID target = {0x11111111, 0x2222, 0x3333, {1, 2, 3, 4, 5, 6, 7, 8}};
    static const GUID stick = {0x44444444, 0x5555, 0x6666, {8, 7, 6, 5, 4, 3, 2, 1}};
    BYTE option[512]; zero(option, sizeof(option)); DWORD at = 0;
    const WCHAR *desc = L"Windows Boot Manager", *file = L"\\EFI\\Microsoft\\Boot\\bootmgfw.efi";
    at = 6; for (unsigned i = 0; desc[i]; i++) { option[at++] = (BYTE)desc[i]; option[at++] = 0; } at += 2;
    DWORD list = at;
    option[at] = 4; option[at + 1] = 1; option[at + 2] = 42; memcpy(option + at + 24, &target, 16); option[at + 40] = 2; option[at + 41] = 2; at += 42;
    unsigned flen = (len(file) + 1) * 2; option[at] = 4; option[at + 1] = 4; option[at + 2] = (BYTE)(4 + flen);
    for (unsigned i = 0; file[i]; i++) { option[at + 4 + 2 * i] = (BYTE)file[i]; } at += 4 + flen;
    option[at] = 0x7f; option[at + 1] = 0xff; option[at + 2] = 4; at += 4;
    *(WORD *)(option + 4) = (WORD)(at - list);
    check(option_points(option, at, &target), "bootmgfw.efi on the target ESP is recognized");
    check(!option_points(option, at, &stick), "the same entry does not match the USOS stick");
    /* USOS's own entry: \EFI\BOOT\BOOTX64.EFI on the stick is never removed. */
    const WCHAR *shim = L"\\EFI\\BOOT\\BOOTX64.EFI  "; DWORD fnode = list + 42;
    for (unsigned i = 0; i < 22; i++) option[fnode + 4 + 2 * i] = (BYTE)shim[i];
    memcpy(option + list + 24, &stick, 16);
    check(!option_points(option, at, &stick), "USOS's shim entry on the stick is not a Windows Boot Manager entry");
}

void test_entry(void) {
    unsigned n = GetEnvironmentVariableW(L"USOS_FINALIZE_WORK", work, MAX_PATH);
    if (!n || n > MAX_PATH - 64) ExitProcess(2);
    if (work[n - 1] != '\\') { work[n++] = '\\'; work[n] = 0; }
    scenario_restore();
    scenario_target();
    scenario_load_option();
    say(failures ? "[RESULT] FAIL\r\n" : "[RESULT] PASS\r\n");
    ExitProcess(failures ? 1 : 0);
}
