/* USOSRES registration for an installed Windows Vista or later, written in
 * the WinPE after Setup and before the first boot (docs/display-policy.md,
 * user decision 2026-10-22: automatic resolution on every install, also
 * without a USOS answer). Shared by tools/windows_x86_csmwrap.c (32-bit
 * Vista / 7 / 2008 / 8 / 8.1 / 10, win-x86-uefi-csmwrap) and
 * tools/windows_vista_install.c (Vista / 2008 SP2 x64 CSMWrap). No C runtime.
 *
 * The micro-Linux (vista_csmwrap_target.sh 2b) staged \USOS\NT6\USOSRES.EXE
 * and DISPLAY.TXT on the Windows partition before Setup. A USOS answer also
 * registers it in specialize; without one nothing would start it. This adds
 * the same registration offline:
 *
 *   - Users\Default\NTUSER.DAT (the Default user hive) gets
 *     Software\Microsoft\Windows\CurrentVersion\Run USOSDisplay =
 *     %SystemDrive%\USOS\NT6\USOSRES.EXE (REG_EXPAND_SZ). Every profile
 *     created later (the OOBE account, the built-in Administrator of a user
 *     answer, later users) copies it. USOSRES removes its own HKCU value
 *     without elevation (display_compat.h usos_display_user_run); later
 *     users exit at DISPLAY.DONE and remove theirs. No HKLM Run / RunOnce:
 *     the first sign-in has the filtered UAC token and could not delete an
 *     HKLM value. The USOS answer's own specialize command writes the same
 *     value name again (REG_SZ, drive expanded): harmless.
 *   - \USOS\NT6 and its two files get an explicit DACL (SYSTEM and
 *     Administrators full, Authenticated Users modify), so USOSRES (no
 *     manifest, run by a standard or filtered token) writes USOSRES.LOG,
 *     DISPLAY.BAK and DISPLAY.DONE in place; the USOS answer's
 *     "icacls /reset" in specialize replaces it by the inherited ACL later.
 *
 * Result: USOS_DREG_WRITTEN, USOS_DREG_PRESENT (the same value was there),
 * USOS_DREG_NOT_STAGED (no USOSRES.EXE / DISPLAY.TXT: nothing done), or an
 * error >= USOS_DREG_ERR_LOAD. Never fatal for the installation; the caller
 * logs it. */
#include <sddl.h>
#define USOS_DREG_WRITTEN 0
#define USOS_DREG_PRESENT 1
#define USOS_DREG_NOT_STAGED 2
#define USOS_DREG_ERR_LOAD 100
#define USOS_DREG_ERR_KEY 101
#define USOS_DREG_ERR_WRITE 102
#define USOS_DREG_ERR_READBACK 103
#define USOS_DREG_ERR_UNLOAD 104

static const WCHAR usos_dreg_run[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
static const WCHAR usos_dreg_name[] = L"USOSDisplay";
static const WCHAR usos_dreg_data[] = L"%SystemDrive%\\USOS\\NT6\\USOSRES.EXE";

static void usos_dreg_privilege(const WCHAR *name) {
    HANDLE token;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES, &token)) return;
    TOKEN_PRIVILEGES tp = {1}; tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
    if (LookupPrivilegeValueW(0, name, &tp.Privileges[0].Luid)) AdjustTokenPrivileges(token, FALSE, &tp, 0, 0, 0);
    CloseHandle(token);
}
static void usos_dreg_path(WCHAR *out, const WCHAR *root, const WCHAR *tail) { lstrcpyW(out, root); lstrcatW(out, tail); }
static BOOL usos_dreg_file(const WCHAR *file) {
    DWORD a = GetFileAttributesW(file);
    return a != INVALID_FILE_ATTRIBUTES && !(a & FILE_ATTRIBUTE_DIRECTORY);
}
/* ROOT = the installed volume, "X:\" (with the trailing backslash). */
static BOOL usos_display_staged(const WCHAR *root) {
    WCHAR file[MAX_PATH];
    if (lstrlenW(root) > MAX_PATH - 64) return FALSE;
    usos_dreg_path(file, root, L"USOS\\NT6\\USOSRES.EXE"); if (!usos_dreg_file(file)) return FALSE;
    usos_dreg_path(file, root, L"USOS\\NT6\\DISPLAY.TXT"); return usos_dreg_file(file);
}
/* The folder's DACL, protected; returns how many of the three objects got it. */
static DWORD usos_display_acl(const WCHAR *root) {
    static const WCHAR *const names[3] = {L"USOS\\NT6", L"USOS\\NT6\\USOSRES.EXE", L"USOS\\NT6\\DISPLAY.TXT"};
    static const WCHAR *const sddl[2] = {L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1301bf;;;AU)",
                                         L"D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x1301bf;;;AU)"};
    WCHAR object[MAX_PATH]; DWORD done = 0;
    for (int i = 0; i < 3; i++) {
        PSECURITY_DESCRIPTOR sd = 0;
        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl[i ? 1 : 0], SDDL_REVISION_1, &sd, 0)) continue;
        usos_dreg_path(object, root, names[i]);
        if (SetFileSecurityW(object, DACL_SECURITY_INFORMATION, sd)) done++;
        LocalFree(sd);
    }
    return done;
}
/* The value as USOS writes it (REG_EXPAND_SZ, exactly usos_dreg_data). */
static BOOL usos_dreg_same(HKEY k) {
    WCHAR old[MAX_PATH]; DWORD type = 0, size = sizeof(old) - sizeof(WCHAR);
    if (RegQueryValueExW(k, usos_dreg_name, 0, &type, (BYTE *)old, &size) != ERROR_SUCCESS) return FALSE;
    if (type != REG_EXPAND_SZ || size != sizeof(usos_dreg_data)) return FALSE;
    old[size / sizeof(WCHAR)] = 0;
    return lstrcmpW(old, usos_dreg_data) == 0;
}
/* The Run value on the root key of a user hive (the host test runs it on a
 * scratch key under HKCU: tools/tests/test_display_register.py). */
static DWORD usos_display_register_in_key(HKEY user_root) {
    HKEY k; DWORD result;
    if (RegCreateKeyExW(user_root, usos_dreg_run, 0, 0, 0, KEY_QUERY_VALUE | KEY_SET_VALUE, 0, &k, 0) != ERROR_SUCCESS) return USOS_DREG_ERR_KEY;
    if (usos_dreg_same(k)) { RegCloseKey(k); return USOS_DREG_PRESENT; }
    if (RegSetValueExW(k, usos_dreg_name, 0, REG_EXPAND_SZ, (const BYTE *)usos_dreg_data, sizeof(usos_dreg_data)) != ERROR_SUCCESS) result = USOS_DREG_ERR_WRITE;
    else result = usos_dreg_same(k) ? USOS_DREG_WRITTEN : USOS_DREG_ERR_READBACK;
    RegFlushKey(k); RegCloseKey(k);
    return result;
}
/* The whole step on the installed volume ROOT ("X:\"): *acl = objects with
 * the DACL (0..3, 0 when not staged). */
static DWORD usos_display_register(const WCHAR *root, DWORD *acl) {
    static const WCHAR mount[] = L"USOS_DISPLAY_DEFAULT";
    WCHAR hive[MAX_PATH];
    *acl = 0;
    if (!usos_display_staged(root)) return USOS_DREG_NOT_STAGED;
    *acl = usos_display_acl(root);
    usos_dreg_path(hive, root, L"Users\\Default\\NTUSER.DAT");
    if (!usos_dreg_file(hive)) return USOS_DREG_ERR_LOAD;
    usos_dreg_privilege(L"SeRestorePrivilege"); usos_dreg_privilege(L"SeBackupPrivilege");
    if (RegLoadKeyW(HKEY_LOCAL_MACHINE, mount, hive) != ERROR_SUCCESS) return USOS_DREG_ERR_LOAD;
    HKEY k; DWORD result = USOS_DREG_ERR_KEY;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, mount, 0, KEY_CREATE_SUB_KEY | KEY_QUERY_VALUE | KEY_SET_VALUE, &k) == ERROR_SUCCESS) {
        result = usos_display_register_in_key(k);
        RegCloseKey(k);
    }
    if (RegUnLoadKeyW(HKEY_LOCAL_MACHINE, mount) != ERROR_SUCCESS && result < USOS_DREG_ERR_LOAD) result = USOS_DREG_ERR_UNLOAD;
    return result;
}
