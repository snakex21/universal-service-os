/* No drive letter for the CSMWrap ESP in an installed Windows Vista or later
 * (docs/csmwrap-esp-letter-2026-10-22.md). Shared by tools/windows_x86_csmwrap.c
 * (32-bit Vista / 7 / 2008 / 8.1 / 10) and tools/windows_vista_install.c
 * (Vista / 2008 x64), run in the WinPE after Setup and before the first boot
 * of the installed system. No C runtime.
 *
 * The CSMWrap ESP is MBR type 0xEF (the UEFI firmware boots
 * \EFI\BOOT\BOOTX64.EFI from it; tools/xp_csmwrap_esp.sh). NT 5 hides
 * partitions of unrecognised types (ftdisk: !IsRecognizedPartition ->
 * hidden), and 0xEF is not one of them there; NT 6+ counts 0xEF
 * (PARTITION_SYSTEM) as recognised, so the mount manager gave the FAT16
 * volume a letter on the first boot (X470 2026-10-22: Windows 10 x86 and
 * Embedded 8.1 x86, label CSMWRAP in Explorer).
 *
 * The mount manager keeps "no drive letter" in MountedDevices as a value whose
 * name starts with '#' and whose data is the volume's unique ID (for an MBR
 * partition: the 4-byte disk signature + the 8-byte byte offset); mountvol
 * X: /D and Disk Management's "Remove" write exactly that. A volume that
 * arrives with such an entry gets no letter (host check 2026-10-22, Windows
 * 10 19045, document above). This writes the entry into the installed
 * system's offline SYSTEM hive and removes a \DosDevices\X: value that maps a
 * letter to the same ID, so the ESP never gets a letter. The MBR, the
 * partition type and the ESP contents stay unchanged.
 *
 * Result: USOS_HIDE_WRITTEN (marker added), USOS_HIDE_PRESENT (already
 * there), or an error code >= USOS_HIDE_ERR_LOAD; *letters = how many
 * \DosDevices values for the ESP were removed. Never touches anything else. */
#define USOS_HIDE_WRITTEN 0
#define USOS_HIDE_PRESENT 1
#define USOS_HIDE_ERR_LOAD 100
#define USOS_HIDE_ERR_KEY 101
#define USOS_HIDE_ERR_WRITE 102
#define USOS_HIDE_ERR_READBACK 103
#define USOS_HIDE_ERR_UNLOAD 104

static void usos_hide_privilege(const WCHAR *name) {
    HANDLE token;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES, &token)) return;
    TOKEN_PRIVILEGES tp = {1}; tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
    if (LookupPrivilegeValueW(0, name, &tp.Privileges[0].Luid)) AdjustTokenPrivileges(token, FALSE, &tp, 0, 0, 0);
    CloseHandle(token);
}
static void usos_hide_hex(WCHAR *out, ULONGLONG v, int digits) {
    for (int i = digits - 1; i >= 0; i--) { int d = (int)(v & 15); out[i] = (WCHAR)(d < 10 ? L'0' + d : L'a' + d - 10); v >>= 4; }
}
static BOOL usos_hide_same(const BYTE *a, const BYTE *b, DWORD n) { while (n--) if (*a++ != *b++) return FALSE; return TRUE; }
/* "#{55534f53-4353-4d57-<sig hi>-<sig lo><lba low 32>}": "USOS" "CSMW", so
 * the entry is recognisable in the hive; the mount manager only reads the
 * leading '#' and the data. */
static void usos_hide_name(WCHAR name[41], DWORD signature, ULONGLONG lba) {
    static const WCHAR head[] = L"#{55534f53-4353-4d57-";
    for (int i = 0; i < 21; i++) name[i] = head[i];
    usos_hide_hex(name + 21, signature >> 16, 4); name[25] = L'-';
    usos_hide_hex(name + 26, signature & 0xffff, 4); usos_hide_hex(name + 30, lba & 0xffffffffu, 8);
    name[38] = L'}'; name[39] = 0;
}
/* The edit on an open MountedDevices key (the host test runs it on a scratch
 * key under HKCU: tools/tests/test_csmwrap_esp_hide.py). */
static DWORD usos_hide_esp_in_key(HKEY k, DWORD signature, ULONGLONG esp_lba, DWORD *letters) {
    BYTE id[12]; ULONGLONG offset = esp_lba * 512;
    for (int i = 0; i < 4; i++) id[i] = (BYTE)(signature >> (8 * i));
    for (int i = 0; i < 8; i++) id[4 + i] = (BYTE)(offset >> (8 * i));
    *letters = 0;
    static WCHAR drop[8][16]; DWORD drops = 0, result; BOOL marker = FALSE;
    for (DWORD i = 0;; i++) {
        WCHAR name[256]; BYTE data[64]; DWORD chars = 256, size = sizeof(data), type = 0;
        LONG r = RegEnumValueW(k, i, name, &chars, 0, &type, data, &size);
        if (r == ERROR_NO_MORE_ITEMS) break;
        if (r != ERROR_SUCCESS || type != REG_BINARY || size != 12 || !usos_hide_same(data, id, 12)) continue;
        if (name[0] == L'#') marker = TRUE;
        /* \DosDevices\X: */
        else if (chars == 14 && name[0] == L'\\' && name[11] == L'\\' && name[13] == L':' && drops < 8) {
            for (int c = 0; c < 15; c++) drop[drops][c] = name[c];
            drops++;
        }
    }
    for (DWORD i = 0; i < drops; i++) if (RegDeleteValueW(k, drop[i]) == ERROR_SUCCESS) (*letters)++;
    if (marker) result = USOS_HIDE_PRESENT;
    else {
        WCHAR name[41]; BYTE check[16]; DWORD size = sizeof(check), type = 0;
        usos_hide_name(name, signature, esp_lba);
        if (RegSetValueExW(k, name, 0, REG_BINARY, id, 12) != ERROR_SUCCESS) result = USOS_HIDE_ERR_WRITE;
        else if (RegQueryValueExW(k, name, 0, &type, check, &size) != ERROR_SUCCESS || type != REG_BINARY || size != 12 || !usos_hide_same(check, id, 12)) result = USOS_HIDE_ERR_READBACK;
        else result = USOS_HIDE_WRITTEN;
    }
    RegFlushKey(k);
    return result;
}
/* The installed system's SYSTEM hive file, loaded as HKLM\USOS_HIDE_ESP. */
static DWORD usos_hide_esp_letter(const WCHAR *system_hive, DWORD signature, ULONGLONG esp_lba, DWORD *letters) {
    static const WCHAR root[] = L"USOS_HIDE_ESP";
    *letters = 0;
    usos_hide_privilege(L"SeRestorePrivilege"); usos_hide_privilege(L"SeBackupPrivilege");
    if (RegLoadKeyW(HKEY_LOCAL_MACHINE, root, system_hive) != ERROR_SUCCESS) return USOS_HIDE_ERR_LOAD;
    DWORD result = USOS_HIDE_ERR_KEY; HKEY k;
    if (RegCreateKeyExW(HKEY_LOCAL_MACHINE, L"USOS_HIDE_ESP\\MountedDevices", 0, 0, 0, KEY_QUERY_VALUE | KEY_SET_VALUE, 0, &k, 0) == ERROR_SUCCESS) {
        result = usos_hide_esp_in_key(k, signature, esp_lba, letters);
        RegCloseKey(k);
    }
    if (RegUnLoadKeyW(HKEY_LOCAL_MACHINE, root) != ERROR_SUCCESS && result < USOS_HIDE_ERR_LOAD) result = USOS_HIDE_ERR_UNLOAD;
    return result;
}
