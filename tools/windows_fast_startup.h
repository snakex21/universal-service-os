/* Fast Startup (hiberboot) off in an installed Windows 8 / 8.1 / 10
 * (docs/ds-fast-startup-2026-10-22.md). Shared by tools/windows_x86_csmwrap.c
 * (32-bit 8 / 8.1 / 10 through CSMWrap), run in the WinPE after Setup and
 * before the first boot of the installed system. No C runtime.
 *
 * Windows 8's Fast Startup is a partial hibernation: shutdown writes the
 * kernel session and the loaded drivers into hiberfil.sys and the next start
 * resumes that image instead of booting. The NTFS volume is left in the
 * "hibernated" state, which is correct for the machine that hibernated and
 * risky for another one: USOS installs move between computers (the disk is
 * carried to the target), so every USOS-installed 8 / 8.1 / 10 starts with a
 * full boot. The value Windows itself writes in the Shutdown settings page:
 *
 *   HKLM\SYSTEM\<CurrentControlSet>\Control\Session Manager\Power
 *       HiberbootEnabled = 0 (REG_DWORD)
 *
 * CurrentControlSet is not a real key in an offline hive: Select\Current
 * names the ControlSet00N that the next boot uses, so that is the one edited.
 *
 * Result: USOS_FS_WRITTEN, USOS_FS_PRESENT (already 0), or an error >=
 * USOS_FS_ERR_LOAD. Never fatal for the installation; the caller logs it. */

#define USOS_FS_WRITTEN 0
#define USOS_FS_PRESENT 1
#define USOS_FS_ERR_LOAD 100
#define USOS_FS_ERR_KEY 101
#define USOS_FS_ERR_WRITE 102
#define USOS_FS_ERR_READBACK 103
#define USOS_FS_ERR_UNLOAD 104

static const WCHAR usos_fs_power[] = L"Control\\Session Manager\\Power";
/* RegFlushKey's result of the last edit (ERROR_SUCCESS when not reached).
 * WinPE on an NVMe target returned ERROR_REGISTRY_IO_FAILED (1016) there
 * (tools/windows_nvme_modern.c commit_hive, X470 B261022); the unload still
 * writes the hive, so a failed flush is logged by the caller, never fatal. */
static LONG usos_fs_flush_error;
static const WCHAR usos_fs_name[] = L"HiberbootEnabled";

static void usos_fs_privilege(const WCHAR *name) {
    HANDLE token;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES, &token)) return;
    TOKEN_PRIVILEGES tp = {1}; tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
    if (LookupPrivilegeValueW(0, name, &tp.Privileges[0].Luid)) AdjustTokenPrivileges(token, FALSE, &tp, 0, 0, 0);
    CloseHandle(token);
}
static BOOL usos_fs_same(HKEY k) {
    DWORD value = 1, type = 0, size = sizeof(value);
    if (RegQueryValueExW(k, usos_fs_name, 0, &type, (BYTE *)&value, &size) != ERROR_SUCCESS) return FALSE;
    return type == REG_DWORD && size == sizeof(value) && value == 0;
}
/* The value on an open Power key (the host test runs it on a scratch key
 * under HKCU: tools/tests/test_windows_fast_startup.py). */
static DWORD usos_fs_in_key(HKEY power) {
    DWORD value = 0, result;
    if (usos_fs_same(power)) return USOS_FS_PRESENT;
    if (RegSetValueExW(power, usos_fs_name, 0, REG_DWORD, (const BYTE *)&value, sizeof(value)) != ERROR_SUCCESS) result = USOS_FS_ERR_WRITE;
    else result = usos_fs_same(power) ? USOS_FS_WRITTEN : USOS_FS_ERR_READBACK;
    usos_fs_flush_error = RegFlushKey(power);
    return result;
}
/* Select\Current -> "ControlSet00N" in OUT[15]; 1 when unreadable. */
static void usos_fs_control_set(HKEY system, WCHAR out[15]) {
    DWORD current = 1, type = 0, size = sizeof(current);
    HKEY select;
    lstrcpyW(out, L"ControlSet001");
    if (RegOpenKeyExW(system, L"Select", 0, KEY_QUERY_VALUE, &select) == ERROR_SUCCESS) {
        if (RegQueryValueExW(select, L"Current", 0, &type, (BYTE *)&current, &size) != ERROR_SUCCESS || type != REG_DWORD) current = 1;
        RegCloseKey(select);
    }
    if (current < 1 || current > 999) current = 1;
    out[10] = (WCHAR)(L'0' + current / 100);
    out[11] = (WCHAR)(L'0' + (current / 10) % 10);
    out[12] = (WCHAR)(L'0' + current % 10);
}
/* The whole edit on an open SYSTEM hive root key (the host test passes a
 * scratch key under HKCU). */
static DWORD usos_fast_startup_in_system(HKEY system) {
    WCHAR key[64];
    HKEY power;
    DWORD result = USOS_FS_ERR_KEY;
    usos_fs_control_set(system, key);
    lstrcatW(key, L"\\"); lstrcatW(key, usos_fs_power);
    if (RegCreateKeyExW(system, key, 0, 0, 0, KEY_QUERY_VALUE | KEY_SET_VALUE, 0, &power, 0) != ERROR_SUCCESS) return result;
    result = usos_fs_in_key(power);
    RegCloseKey(power);
    return result;
}
/* ROOT = the installed volume, "X:\" (with the trailing backslash). */
static DWORD usos_fast_startup(const WCHAR *root) {
    static const WCHAR mount[] = L"USOS_FASTSTARTUP";
    WCHAR hive[MAX_PATH];
    HKEY system;
    DWORD result = USOS_FS_ERR_KEY;
    if (lstrlenW(root) > MAX_PATH - 48) return USOS_FS_ERR_LOAD;
    lstrcpyW(hive, root); lstrcatW(hive, L"Windows\\System32\\config\\SYSTEM");
    usos_fs_privilege(L"SeRestorePrivilege"); usos_fs_privilege(L"SeBackupPrivilege");
    if (RegLoadKeyW(HKEY_LOCAL_MACHINE, mount, hive) != ERROR_SUCCESS) return USOS_FS_ERR_LOAD;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, mount, 0, KEY_QUERY_VALUE | KEY_CREATE_SUB_KEY, &system) == ERROR_SUCCESS) {
        result = usos_fast_startup_in_system(system);
        RegCloseKey(system);
    }
    /* A hive left loaded would block the later SYSTEM edits (mpart, hideesp):
     * retry a busy unload like windows_usos_reg.c does. */
    LONG unload;
    for (int tries = 0; (unload = RegUnLoadKeyW(HKEY_LOCAL_MACHINE, mount)) != ERROR_SUCCESS && tries < 10; tries++) Sleep(200);
    if (unload != ERROR_SUCCESS && result < USOS_FS_ERR_LOAD) result = USOS_FS_ERR_UNLOAD;
    return result;
}
