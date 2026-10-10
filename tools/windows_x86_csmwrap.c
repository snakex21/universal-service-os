/* WinPE helper for 32-bit Windows 8.1 / 10 without firmware CSM (profile
 * win-x86-uefi-csmwrap; docs/design/csmwrap-integration.md section 11).
 * The ISO's own x86 WinPE was booted in BIOS mode through CSMWrap from the
 * staging partition that tools/vista_csmwrap_target.sh (X86_SELF=1) wrote to
 * the target disk; usos-csmwrap-target.ini beside this executable names that
 * disk (MBR signature) and its partitions. No C runtime.
 *
 *   before <answer|-> <out>  finds the prepared disk (exactly one internal MBR
 *                            disk with the signature), removes the WinPE
 *                            letters of its volumes, makes the prepared Windows
 *                            partition the active one and hides the staging
 *                            partition (type 0x17, inactive), then writes
 *                            <out>: the answer file (or a new one) with
 *                            ImageInstall/OSImage/InstallTo = that disk and
 *                            partition (the user confirmed this disk in
 *                            micro-Linux, so Setup does not ask again).
 *   failed                   Setup failed: the staging partition becomes active
 *                            again (the next boot of the disk retries).
 *   after                    the Windows partition holds bootmgr and
 *                            Windows\System32\winload.exe and is the only active
 *                            one; the staging entry is removed; a notice says to
 *                            remove the stick (closes itself after 2 minutes).
 * Disk and partition identities come from IOCTLs and the MBR, never letters.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winioctl.h>
#include <shellapi.h>
#include <stddef.h>

static WCHAR base[MAX_PATH], scratch[MAX_PATH];
static BYTE buffer[65536];
static DWORD signature, disk = 0xffffffff, windows_number;
static ULONGLONG staging_start, staging_sectors, windows_start, windows_sectors;

void *memcpy(void *d, const void *s, size_t n) { volatile BYTE *p = d; const BYTE *q = s; while (n--) *p++ = *q++; return d; }
void *memset(void *d, int v, size_t n) { volatile BYTE *p = d; while (n--) *p++ = (BYTE)v; return d; }
static BOOL same(const void *a, const void *b, DWORD n) { const BYTE *x = a, *y = b; while (n--) if (*x++ != *y++) return FALSE; return TRUE; }
static void say(const char *p) { DWORD n = 0, w; while (p[n]) n++; WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), p, n, &w, 0); }
static void decimal(char *out, DWORD v) { char d[24]; int n = 0; do { d[n++] = (char)('0' + v % 10); v /= 10; } while (v); while (n) *out++ = d[--n]; *out = 0; }
static void wdecimal(WCHAR *out, DWORD v) { char d[24]; decimal(d, v); int i = 0; while (d[i]) { out[i] = d[i]; i++; } out[i] = 0; }
static void logn(const char *text, DWORD v) { char d[24]; decimal(d, v); say("[X86_CSMWRAP] "); say(text); say(d); say("\r\n"); }
static void path(WCHAR *out, const WCHAR *tail) { lstrcpyW(out, base); lstrcatW(out, tail); }

static ULONGLONG parse_decimal(const char *s) { ULONGLONG v = 0; for (; *s >= '0' && *s <= '9'; s++) v = v * 10 + (ULONGLONG)(*s - '0'); return v; }
static const char *ini_value(const char *text, const char *key) {
    for (const char *p = text; *p; ) {
        const char *k = key, *q = p;
        while (*k && *q == *k) { k++; q++; }
        if (!*k && *q == '=') return q + 1;
        while (*p && *p != '\n') p++;
        if (*p) p++;
    }
    return 0;
}
static BOOL load_target(void) {
    static char text[1024]; DWORD got = 0;
    path(scratch, L"usos-csmwrap-target.ini");
    HANDLE h = CreateFileW(scratch, GENERIC_READ, FILE_SHARE_READ, 0, OPEN_EXISTING, 0, 0);
    if (h == INVALID_HANDLE_VALUE) { logn("usos-csmwrap-target.ini missing, error=", GetLastError()); return FALSE; }
    BOOL ok = ReadFile(h, text, sizeof(text) - 1, &got, 0); CloseHandle(h);
    if (!ok) return FALSE;
    text[got] = 0;
    const char *sig = ini_value(text, "disk_signature"), *ss = ini_value(text, "staging_start"), *sn = ini_value(text, "staging_sectors"),
               *ws = ini_value(text, "windows_start"), *wn = ini_value(text, "windows_sectors");
    if (!sig || !ss || !sn || !ws || !wn) return FALSE;
    DWORD v = 0;
    for (int i = 0; i < 8; i++) {
        char c = sig[i];
        if (c >= '0' && c <= '9') v = v * 16 + (DWORD)(c - '0');
        else if ((c | 32) >= 'a' && (c | 32) <= 'f') v = v * 16 + (DWORD)((c | 32) - 'a' + 10);
        else return FALSE;
    }
    signature = v; staging_start = parse_decimal(ss); staging_sectors = parse_decimal(sn); windows_start = parse_decimal(ws); windows_sectors = parse_decimal(wn);
    return signature && staging_start && staging_sectors && windows_start && windows_sectors;
}
static HANDLE disk_handle(DWORD number, DWORD access) {
    WCHAR name[40] = L"\\\\.\\PhysicalDrive"; wdecimal(name + lstrlenW(name), number);
    return CreateFileW(name, access, FILE_SHARE_READ | FILE_SHARE_WRITE, 0, OPEN_EXISTING, (access & GENERIC_WRITE) ? FILE_FLAG_WRITE_THROUGH : 0, 0);
}
static BOOL internal(HANDLE h) {
    STORAGE_PROPERTY_QUERY q = {StorageDeviceProperty, PropertyStandardQuery}; BYTE out[1024]; DWORD got = 0;
    if (!DeviceIoControl(h, IOCTL_STORAGE_QUERY_PROPERTY, &q, sizeof(q), out, sizeof(out), &got, 0) || got < sizeof(STORAGE_DEVICE_DESCRIPTOR)) return FALSE;
    STORAGE_DEVICE_DESCRIPTOR *d = (void *)out;
    return d->BusType != BusTypeUsb && !d->RemovableMedia;
}
/* The one internal MBR disk with the signature, and the partition number
 * Windows gave the prepared Windows partition (its start and length). */
static BOOL find_disk(void) {
    DWORD found = 0;
    for (DWORD n = 0; n < 64; n++) {
        HANDLE h = disk_handle(n, GENERIC_READ);
        if (h == INVALID_HANDLE_VALUE) continue;
        DWORD got = 0;
        BOOL ok = internal(h) && DeviceIoControl(h, IOCTL_DISK_GET_DRIVE_LAYOUT_EX, 0, 0, buffer, sizeof(buffer), &got, 0) && got >= offsetof(DRIVE_LAYOUT_INFORMATION_EX, PartitionEntry);
        CloseHandle(h);
        if (!ok) continue;
        DRIVE_LAYOUT_INFORMATION_EX *layout = (void *)buffer;
        if (layout->PartitionStyle != PARTITION_STYLE_MBR || layout->Mbr.Signature != signature) continue;
        found++; disk = n; windows_number = 0;
        for (DWORD i = 0; i < layout->PartitionCount; i++) {
            PARTITION_INFORMATION_EX *p = &layout->PartitionEntry[i];
            if (p->PartitionNumber && (ULONGLONG)p->StartingOffset.QuadPart == windows_start * 512 && (ULONGLONG)p->PartitionLength.QuadPart == windows_sectors * 512) windows_number = p->PartitionNumber;
        }
    }
    logn("disks with the prepared MBR signature=", found);
    if (found != 1 || !windows_number) { logn("Windows partition number=", windows_number); return FALSE; }
    logn("target physical disk=", disk);
    logn("Windows partition number=", windows_number);
    return TRUE;
}
static BOOL mbr_io(BYTE sector[512], BOOL write) {
    HANDLE h = disk_handle(disk, GENERIC_READ | (write ? GENERIC_WRITE : 0));
    if (h == INVALID_HANDLE_VALUE) return FALSE;
    DWORD got = 0; BOOL ok;
    if (write) { ok = WriteFile(h, sector, 512, &got, 0) && got == 512 && FlushFileBuffers(h); if (ok) DeviceIoControl(h, IOCTL_DISK_UPDATE_PROPERTIES, 0, 0, 0, 0, &got, 0); }
    else ok = ReadFile(h, sector, 512, &got, 0) && got == 512;
    CloseHandle(h);
    return ok && (write || (sector[510] == 0x55 && sector[511] == 0xAA && same(sector + 440, &signature, 4)));
}
static int slot_of(const BYTE *s, ULONGLONG first_lba, ULONGLONG count, BOOL staging) {
    for (int i = 0; i < 4; i++) {
        const BYTE *e = s + 446 + 16 * i; DWORD first, n;
        memcpy(&first, e + 8, 4); memcpy(&n, e + 12, 4);
        BOOL type = staging ? (e[4] == 0x07 || e[4] == 0x17) : e[4] == 0x07;
        if (type && first == first_lba && n == count) return i;
    }
    return -1;
}
static BOOL write_mbr(BYTE s[512], const char *what) {
    BYTE check[512];
    if (!mbr_io(s, TRUE) || !mbr_io(check, FALSE) || !same(s, check, 512)) { logn("MBR write/readback failed, error=", GetLastError()); return FALSE; }
    say("[X86_CSMWRAP] "); say(what); say("\r\n");
    return TRUE;
}
/* Setup keeps WinPE letters of existing volumes (the staging C: would push
 * the new Windows to D:, Vista QEMU 2026-09-27): drop them all for this disk. */
static void drop_letters(void) {
    DWORD letters = GetLogicalDrives();
    for (DWORD i = 2; i < 26; i++) if (letters & (1u << i)) {
        WCHAR name[8] = L"\\\\.\\C:", root[4] = {(WCHAR)(L'A' + i), L':', L'\\', 0}; name[4] = (WCHAR)(L'A' + i); DWORD got = 0;
        HANDLE h = CreateFileW(name, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, 0, OPEN_EXISTING, 0, 0);
        if (h == INVALID_HANDLE_VALUE) continue;
        VOLUME_DISK_EXTENTS e;
        BOOL match = DeviceIoControl(h, IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS, 0, 0, &e, sizeof(e), &got, 0) && e.NumberOfDiskExtents == 1 && e.Extents[0].DiskNumber == disk;
        CloseHandle(h);
        if (match) logn("WinPE letter of a prepared volume removed (ASCII)=", DeleteVolumeMountPointW(root) ? (DWORD)(L'A' + i) : GetLastError());
    }
}

/* ---- answer file: InstallTo ------------------------------------------- */
static char xml_in[1 << 20], xml_out[(1 << 20) + 4096];
static DWORD out_len;
static void put(const char *p, DWORD n) { if (out_len + n < sizeof(xml_out)) { memcpy(xml_out + out_len, p, n); out_len += n; } else out_len = sizeof(xml_out); }
static void puts_(const char *p) { DWORD n = 0; while (p[n]) n++; put(p, n); }
static const char *find(const char *hay, DWORD hay_len, const char *needle) {
    DWORD n = 0; while (needle[n]) n++;
    for (DWORD i = 0; i + n <= hay_len; i++) if (same(hay + i, needle, n)) return hay + i;
    return 0;
}
static void install_to(void) {
    char d[24];
    puts_("<InstallTo><DiskID>"); decimal(d, disk); puts_(d); puts_("</DiskID><PartitionID>"); decimal(d, windows_number); puts_(d); puts_("</PartitionID></InstallTo>");
}
static void image_install(void) { puts_("<ImageInstall><OSImage>"); install_to(); puts_("<WillShowUI>OnError</WillShowUI></OSImage></ImageInstall>"); }
static const char setup_component[] = "<component name=\"Microsoft-Windows-Setup\" processorArchitecture=\"x86\" publicKeyToken=\"31bf3856ad364e35\" language=\"neutral\" versionScope=\"nonSxS\">";
static BOOL write_answer(const WCHAR *input, const WCHAR *output) {
    DWORD got = 0; out_len = 0;
    BOOL have = lstrcmpW(input, L"-") != 0;
    if (have) {
        HANDLE h = CreateFileW(input, GENERIC_READ, FILE_SHARE_READ, 0, OPEN_EXISTING, 0, 0);
        if (h == INVALID_HANDLE_VALUE) return FALSE;
        BOOL ok = ReadFile(h, xml_in, sizeof(xml_in), &got, 0); CloseHandle(h);
        if (!ok || got == 0 || got == sizeof(xml_in)) return FALSE;
    }
    const char *at;
    if (!have) {
        puts_("<?xml version=\"1.0\" encoding=\"utf-8\"?>\r\n<unattend xmlns=\"urn:schemas-microsoft-com:unattend\"><settings pass=\"windowsPE\">");
        puts_(setup_component); image_install(); puts_("</component></settings></unattend>\r\n");
        say("[X86_CSMWRAP] answer: none supplied; InstallTo only (Setup asks the rest)\r\n");
    } else if (got >= 2 && (BYTE)xml_in[0] == 0xff && (BYTE)xml_in[1] == 0xfe) {
        put(xml_in, got);
        say("[X86_CSMWRAP] answer: UTF-16 file kept as it is; the disk page stays manual\r\n");
    } else if (find(xml_in, got, "<InstallTo")) {
        put(xml_in, got);
        say("[X86_CSMWRAP] answer: the file names its own InstallTo; kept as it is\r\n");
    } else if ((at = find(xml_in, got, "<component name=\"Microsoft-Windows-Setup\"")) != 0) {
        const char *end = find(at, got - (DWORD)(at - xml_in), ">");
        if (!end) return FALSE;
        const char *os = find(end, got - (DWORD)(end - xml_in), "<OSImage>");
        const char *close = find(end, got - (DWORD)(end - xml_in), "</component>");
        if (os && close && os < close) {
            os += 9; put(xml_in, (DWORD)(os - xml_in)); install_to(); put(os, got - (DWORD)(os - xml_in));
        } else {
            end += 1; put(xml_in, (DWORD)(end - xml_in)); image_install(); put(end, got - (DWORD)(end - xml_in));
        }
        say("[X86_CSMWRAP] answer: InstallTo added to Microsoft-Windows-Setup\r\n");
    } else if ((at = find(xml_in, got, "<settings pass=\"windowsPE\">")) != 0) {
        at += 27; put(xml_in, (DWORD)(at - xml_in)); puts_(setup_component); image_install(); puts_("</component>"); put(at, got - (DWORD)(at - xml_in));
        say("[X86_CSMWRAP] answer: Microsoft-Windows-Setup with InstallTo added to windowsPE\r\n");
    } else if ((at = find(xml_in, got, "<unattend")) != 0 && (at = find(at, got - (DWORD)(at - xml_in), ">")) != 0) {
        at += 1; put(xml_in, (DWORD)(at - xml_in)); puts_("<settings pass=\"windowsPE\">"); puts_(setup_component); image_install(); puts_("</component></settings>"); put(at, got - (DWORD)(at - xml_in));
        say("[X86_CSMWRAP] answer: windowsPE settings with InstallTo added\r\n");
    } else return FALSE;
    if (out_len >= sizeof(xml_out)) return FALSE;
    HANDLE h = CreateFileW(output, GENERIC_WRITE, 0, 0, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    if (h == INVALID_HANDLE_VALUE) return FALSE;
    DWORD wrote = 0; BOOL ok = WriteFile(h, xml_out, out_len, &wrote, 0) && wrote == out_len && FlushFileBuffers(h);
    CloseHandle(h);
    return ok;
}

static BOOL exists_on_partition(const WCHAR *tail) {
    WCHAR name[MAX_PATH] = L"\\\\?\\GLOBALROOT\\Device\\Harddisk";
    wdecimal(name + lstrlenW(name), disk); lstrcatW(name, L"\\Partition"); wdecimal(name + lstrlenW(name), windows_number); lstrcatW(name, tail);
    DWORD a = GetFileAttributesW(name);
    return a != INVALID_FILE_ATTRIBUTES && !(a & FILE_ATTRIBUTE_DIRECTORY);
}
static DWORD WINAPI notice(LPVOID unused) {
    (void)unused;
    MessageBoxW(0, L"The first part of the Windows installation is complete.\n\nRemove the USOS stick now, then choose OK: the computer restarts and Windows continues from the disk through CSMWrap. If the stick stays connected, start this disk's UEFI entry from the firmware boot menu.\n\nThe computer restarts by itself in 2 minutes.",
                L"USOS - Windows without CSM", MB_OK | MB_ICONINFORMATION | MB_SETFOREGROUND | MB_TOPMOST | MB_SYSTEMMODAL);
    return 0;
}

static int arg_count;
static WCHAR **args;
void entry(void) {
    args = CommandLineToArgvW(GetCommandLineW(), &arg_count);
    DWORD n = GetModuleFileNameW(0, base, MAX_PATH);
    if (!args || arg_count < 2 || !n || n >= MAX_PATH - 64) ExitProcess(2);
    while (n && base[n - 1] != L'\\') n--;
    base[n] = 0;
    /* Host test of the answer edit only (tools/tests/test_windows_x86_csmwrap.py). */
    if (lstrcmpiW(args[1], L"answer-test") == 0 && arg_count == 6) {
        disk = (DWORD)args[4][0] - L'0'; windows_number = (DWORD)args[5][0] - L'0';
        ExitProcess(write_answer(args[2], args[3]) ? 0 : 7);
    }
    FIRMWARE_TYPE firmware;
    if (!GetFirmwareType(&firmware) || firmware != FirmwareTypeBios) { say("[X86_CSMWRAP] STOP: not booted in BIOS mode\r\n"); ExitProcess(2); }
    if (!load_target()) { say("[X86_CSMWRAP] STOP: usos-csmwrap-target.ini is invalid\r\n"); ExitProcess(3); }
    if (!find_disk()) { say("[X86_CSMWRAP] STOP: the prepared disk was not found exactly once\r\n"); ExitProcess(4); }
    BYTE s[512];
    if (!mbr_io(s, FALSE)) { logn("cannot read the target MBR, error=", GetLastError()); ExitProcess(5); }
    int staging = slot_of(s, staging_start, staging_sectors, TRUE), windows = slot_of(s, windows_start, windows_sectors, FALSE);
    if (staging < 0 || windows < 0) { logn("MBR entries not found (staging slot+1, windows slot+1)=", (DWORD)((staging + 1) * 10 + windows + 1)); ExitProcess(5); }
    BYTE *se = s + 446 + 16 * staging, *we = s + 446 + 16 * windows;
    if (lstrcmpiW(args[1], L"before") == 0 && arg_count == 4) {
        drop_letters();
        for (int i = 0; i < 4; i++) s[446 + 16 * i] = 0;
        we[0] = 0x80; se[4] = 0x17;
        if (!write_mbr(s, "Windows partition active, staging partition inactive and hidden")) ExitProcess(6);
        if (!write_answer(args[2], args[3])) { say("[X86_CSMWRAP] STOP: the answer file could not be prepared\r\n"); ExitProcess(7); }
        ExitProcess(0);
    }
    if (lstrcmpiW(args[1], L"failed") == 0) {
        for (int i = 0; i < 4; i++) s[446 + 16 * i] = 0;
        se[0] = 0x80; se[4] = 0x07;
        ExitProcess(write_mbr(s, "staging partition active again for a retry") ? 0 : 6);
    }
    if (lstrcmpiW(args[1], L"after") == 0) {
        BOOL bootmgr = exists_on_partition(L"\\bootmgr"), winload = exists_on_partition(L"\\Windows\\System32\\winload.exe");
        logn("bootmgr on the Windows partition=", bootmgr);
        logn("winload.exe on the Windows partition=", winload);
        int active = 0; for (int i = 0; i < 4; i++) if (s[446 + 16 * i] == 0x80) active++;
        if (!bootmgr || !winload || we[0] != 0x80 || active != 1) { say("[X86_CSMWRAP] STOP: the installed Windows partition is not ready to boot; staging kept\r\n"); ExitProcess(8); }
        memset(se, 0, 16);
        if (!write_mbr(s, "staging partition entry removed")) ExitProcess(6);
        HANDLE t = CreateThread(0, 0, notice, 0, 0, 0);
        if (t) { WaitForSingleObject(t, 120000); CloseHandle(t); }
        ExitProcess(0);
    }
    ExitProcess(2);
}
