/* Offline registration of the USOSFLT flight recorder service
 * (tools/windows_flight_recorder.c) in an installed 32-bit Windows' SYSTEM
 * hive. Included by tools/windows_fast_startup.h, so it runs in the same
 * hive load as HiberbootEnabled / AutoReboot ("usos-x86-csmwrap
 * faststartup"). OPT-IN diagnostic (docs/nvme-nt6-2026-10-12.md section
 * 21.2): only when usos_fs_flight is TRUE, i.e. the helper found
 * flight-recorder.txt on DATA and copied USOSFLT.EXE to
 * <target>\Windows\System32. No C runtime.
 *
 *   <ControlSet>\Services\USOSFLT
 *       Type = 0x10 (own process), Start = 2 (auto), ErrorControl = 0,
 *       ImagePath = %SystemRoot%\System32\USOSFLT.EXE (REG_EXPAND_SZ),
 *       ObjectName = LocalSystem, Group = "Event Log" (the first Win32
 *       service group in ServiceGroupOrder: starts as early as a user-mode
 *       service can), DisplayName, Description.
 *
 * Removal in the installed system: "USOSFLT.EXE /remove" (or sc delete
 * USOSFLT), then delete System32\USOSFLT.EXE and \USOS\FLIGHT.*. */

static BOOL usos_fs_flight;                         /* register USOSFLT in this load */
static DWORD usos_fs_flight_result = USOS_FS_ERR_KEY;
static const WCHAR usos_flt_image[] = L"%SystemRoot%\\System32\\USOSFLT.EXE";

static BOOL usos_flt_dword(HKEY k, const WCHAR *name, DWORD want) {
    DWORD v = 0, type = 0, size = sizeof(v);
    return RegQueryValueExW(k, name, 0, &type, (BYTE *)&v, &size) == ERROR_SUCCESS && type == REG_DWORD && v == want;
}
static BOOL usos_flt_text(HKEY k, const WCHAR *name, const WCHAR *want, DWORD want_type) {
    WCHAR v[128]; DWORD type = 0, size = sizeof(v) - sizeof(WCHAR);
    if (RegQueryValueExW(k, name, 0, &type, (BYTE *)v, &size) != ERROR_SUCCESS || type != want_type) return FALSE;
    v[size / sizeof(WCHAR)] = 0;
    return lstrcmpiW(v, want) == 0;
}
static LONG usos_flt_set_text(HKEY k, const WCHAR *name, const WCHAR *text, DWORD type) {
    return RegSetValueExW(k, name, 0, type, (const BYTE *)text, (DWORD)((lstrlenW(text) + 1) * sizeof(WCHAR)));
}
static BOOL usos_flt_complete(HKEY k) {
    return usos_flt_dword(k, L"Type", 0x10) && usos_flt_dword(k, L"Start", 2) && usos_flt_dword(k, L"ErrorControl", 0) &&
           usos_flt_text(k, L"ImagePath", usos_flt_image, REG_EXPAND_SZ) && usos_flt_text(k, L"ObjectName", L"LocalSystem", REG_SZ) &&
           usos_flt_text(k, L"Group", L"Event Log", REG_SZ);
}
/* SET = "ControlSet00N" (Select\Current). Result USOS_FS_WRITTEN /
 * USOS_FS_PRESENT / USOS_FS_ERR_*. */
static DWORD usos_flt_register_in_system(HKEY system, const WCHAR *set) {
    WCHAR key[64]; HKEY k; DWORD one = 0x10, two = 2, zero = 0, result;
    lstrcpyW(key, set); lstrcatW(key, L"\\Services\\USOSFLT");
    if (RegCreateKeyExW(system, key, 0, 0, 0, KEY_QUERY_VALUE | KEY_SET_VALUE, 0, &k, 0) != ERROR_SUCCESS) return USOS_FS_ERR_KEY;
    if (usos_flt_complete(k)) { RegCloseKey(k); return USOS_FS_PRESENT; }
    if (RegSetValueExW(k, L"Type", 0, REG_DWORD, (const BYTE *)&one, 4) != ERROR_SUCCESS ||
        RegSetValueExW(k, L"Start", 0, REG_DWORD, (const BYTE *)&two, 4) != ERROR_SUCCESS ||
        RegSetValueExW(k, L"ErrorControl", 0, REG_DWORD, (const BYTE *)&zero, 4) != ERROR_SUCCESS ||
        usos_flt_set_text(k, L"ImagePath", usos_flt_image, REG_EXPAND_SZ) != ERROR_SUCCESS ||
        usos_flt_set_text(k, L"ObjectName", L"LocalSystem", REG_SZ) != ERROR_SUCCESS ||
        usos_flt_set_text(k, L"Group", L"Event Log", REG_SZ) != ERROR_SUCCESS ||
        usos_flt_set_text(k, L"DisplayName", L"USOS flight recorder (diagnostic)", REG_SZ) != ERROR_SUCCESS ||
        usos_flt_set_text(k, L"Description", L"USOS diagnostic: one line per second to \\USOS\\FLIGHT.LOG during Setup boots; remove with USOSFLT.EXE /remove", REG_SZ) != ERROR_SUCCESS)
        result = USOS_FS_ERR_WRITE;
    else result = usos_flt_complete(k) ? USOS_FS_WRITTEN : USOS_FS_ERR_READBACK;
    RegFlushKey(k);
    RegCloseKey(k);
    return result;
}
