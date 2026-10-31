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
 *                            micro-Linux, so Setup does not ask again; any
 *                            disk setting of the answer is replaced, a UTF-16
 *                            answer is converted: tools/windows_installto.h).
 *   failed                   Setup failed: the staging partition becomes active
 *                            again (the next boot of the disk retries).
 *   target <out>             after Setup: <out> = "<letter>: <NT major.minor>"
 *                            of the installed Windows (a letter is given to
 *                            its volume when it has none), for the offline
 *                            USB 3 step of usos-x86-csmwrap.cmd.
 *   disks                    read-only: every PhysicalDrive (bus, removable,
 *                            size, partition style, MBR signature) and the
 *                            expected signature; "before" logs the same, any
 *                            other mode only when the disk is not found.
 *   lowmem                   NVMe target: when this WinPE has RAM above 4 GiB,
 *                            truncatememory 0x100000000 in the staging BCD
 *                            (exit 10: the cmd restarts the WinPE once).
 *   samefile <a> <b>         read-only: exit 0 when both files exist and have
 *                            the same bytes, 1 otherwise (this WinPE has no
 *                            fc.exe; the usosmpart copy readback of the cmd).
 *   stick                    read-only: logs the dirty bit of every volume on
 *                            a USB / removable disk (the USOS stick).
 *   hideesp                  after Setup: the installed system's offline
 *                            SYSTEM hive gets a "no drive letter" entry for
 *                            the CSMWrap ESP (MBR type 0xEF at esp_start,
 *                            tools/windows_csmwrap_hide.h); never fatal for
 *                            the flow (exit 0 written / present, else 11).
 *   display                  after Setup: when the micro-Linux staged
 *                            \USOS\NT6\USOSRES.EXE, the installed system's
 *                            Default user hive gets its Run value (every
 *                            answer, also none: windows_display_register.h);
 *                            never fatal (exit 0 done / not staged, else 11).
 *   faststartup              after Setup: Windows 8 / 8.1 / 10 get
 *                            HiberbootEnabled=0 in the installed system's
 *                            offline SYSTEM hive (tools/windows_fast_startup.h),
 *                            so a shutdown leaves a clean NTFS volume: the
 *                            disk moves between computers. An empty
 *                            DATA\Systems\Windows\<version>\Unattended\
 *                            fast-startup-on.txt keeps Windows' setting;
 *                            never fatal (exit 0 done / not applicable, else 11).
 *   after                    the Windows partition holds bootmgr and
 *                            Windows\System32\winload.exe and is the only active
 *                            one; the staging entry is removed; a notice says to
 *                            remove the stick (closes itself after 2 minutes).
 *   after poweroff           the same checks; the notice (Polish) says the
 *                            computer powers off and is to be started with the
 *                            power button (closes itself after 15 seconds); the
 *                            .cmd then runs wpeutil shutdown (8 / 8.1 / 10).
 * Disk and partition identities come from IOCTLs and the MBR, never letters.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winioctl.h>
#include <shellapi.h>
#include <winver.h>
#include <stddef.h>

static WCHAR base[MAX_PATH], scratch[MAX_PATH];
static BYTE buffer[65536];
static DWORD signature, disk = 0xffffffff, windows_number;
static ULONGLONG staging_start, staging_sectors, windows_start, windows_sectors, esp_start;

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
    { const char *es = ini_value(text, "esp_start"); esp_start = es ? parse_decimal(es) : 0; }
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
/* ---- disk inventory for the log (X470 2026-10-13, B261013-184439) -------
 * Windows 7 x86 to an NVMe disk stopped with "the prepared disk was not found
 * exactly once" and "disks with the prepared MBR signature=0": the log did
 * not say which PhysicalDrives this WinPE saw. Every PhysicalDrive that opens
 * (or fails with anything but "not present") is described; read-only. */
static void hex8(char *out, DWORD v) { for (int i = 7; i >= 0; i--) { DWORD d = v & 15; out[i] = (char)(d < 10 ? '0' + d : 'a' + d - 10); v >>= 4; } out[8] = 0; }
static void logx(const char *text, DWORD v) { char d[12]; hex8(d, v); say("[X86_CSMWRAP] "); say(text); say("0x"); say(d); say("\r\n"); }
static void sayn(DWORD v) { char d[24]; decimal(d, v); say(d); }
static const char *bus_name(DWORD bus) {
    static const char *names[] = {"unknown", "SCSI", "ATAPI", "ATA", "1394", "SSA", "Fibre", "USB", "RAID", "iSCSI", "SAS", "SATA", "SD", "MMC", "Virtual", "FileBackedVirtual", "Spaces", "NVMe", "SCM", "UFS"};
    return bus < sizeof(names) / sizeof(names[0]) ? names[bus] : "other";
}
/* A descriptor string (vendor / product / serial): printable ASCII only. */
static void say_field(const BYTE *out, DWORD got, DWORD offset) {
    char text[48]; int n = 0;
    if (offset && offset < got) for (DWORD i = offset; i < got && out[i] && n < 47; i++) if (out[i] >= 32 && out[i] < 127 && out[i] != '"') text[n++] = (char)out[i];
    while (n && text[n - 1] == ' ') n--;
    text[n] = 0;
    { char *t = text; while (*t == ' ') t++; say(t); }
}
static void describe_disk(DWORD n, HANDLE h) {
    STORAGE_PROPERTY_QUERY q = {StorageDeviceProperty, PropertyStandardQuery}; static BYTE out[1024]; DWORD got = 0;
    say("[X86_CSMWRAP] PhysicalDrive"); sayn(n);
    if (DeviceIoControl(h, IOCTL_STORAGE_QUERY_PROPERTY, &q, sizeof(q), out, sizeof(out), &got, 0) && got >= sizeof(STORAGE_DEVICE_DESCRIPTOR)) {
        STORAGE_DEVICE_DESCRIPTOR *d = (void *)out;
        say(" bus="); say(bus_name((DWORD)d->BusType)); say("("); sayn((DWORD)d->BusType); say(")");
        say(" removable="); sayn(d->RemovableMedia ? 1 : 0);
        say(" vendor=\""); say_field(out, got, d->VendorIdOffset); say("\" product=\""); say_field(out, got, d->ProductIdOffset);
        say("\" serial=\""); say_field(out, got, d->SerialNumberOffset); say("\"");
    } else { say(" descriptor-error="); sayn(GetLastError()); }
    GET_LENGTH_INFORMATION length;
    if (DeviceIoControl(h, IOCTL_DISK_GET_LENGTH_INFO, 0, 0, &length, sizeof(length), &got, 0)) { say(" size_mib="); sayn((DWORD)((ULONGLONG)length.Length.QuadPart >> 20)); }
    else { say(" size-error="); sayn(GetLastError()); }
    if (DeviceIoControl(h, IOCTL_DISK_GET_DRIVE_LAYOUT_EX, 0, 0, buffer, sizeof(buffer), &got, 0) && got >= offsetof(DRIVE_LAYOUT_INFORMATION_EX, PartitionEntry)) {
        DRIVE_LAYOUT_INFORMATION_EX *layout = (void *)buffer; char d[12];
        if (layout->PartitionStyle == PARTITION_STYLE_MBR) { hex8(d, layout->Mbr.Signature); say(" style=MBR signature=0x"); say(d); }
        else say(layout->PartitionStyle == PARTITION_STYLE_GPT ? " style=GPT" : " style=RAW");
        say(" partition_entries="); sayn(layout->PartitionCount);
    } else { say(" layout-error="); sayn(GetLastError()); }
    say("\r\n");
}

/* The one internal MBR disk with the signature, and the partition number
 * Windows gave the prepared Windows partition (its start and length).
 * verbose: every PhysicalDrive is described in the log (see above). */
static BOOL find_disk(BOOL verbose) {
    DWORD found = 0, absent = 0;
    disk = 0xffffffff; windows_number = 0;
    if (verbose) {
        logx("expected MBR signature=", signature);
        logn("expected Windows partition start LBA (low 32 bits)=", (DWORD)windows_start);
        logn("expected Windows partition sectors (low 32 bits)=", (DWORD)windows_sectors);
    }
    for (DWORD n = 0; n < 64; n++) {
        HANDLE h = disk_handle(n, GENERIC_READ);
        if (h == INVALID_HANDLE_VALUE) {
            DWORD error = GetLastError();
            if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) absent++;
            else if (verbose) { say("[X86_CSMWRAP] PhysicalDrive"); sayn(n); say(" open failed, error="); sayn(error); say("\r\n"); }
            continue;
        }
        if (verbose) describe_disk(n, h);
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
    if (verbose) logn("PhysicalDrive numbers 0-63 not present=", absent);
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

/* ---- answer file: InstallTo (tools/windows_installto.h) ---------------- */
#include "windows_installto.h"
static char xml_in[1 << 20], xml_utf8[(1 << 20) + 64], xml_scratch[(1 << 20) + 64], xml_out[(1 << 20) + 8192];
static int modern_setup; /* Setup 6.2+ (8.x / 10): windows_installto.h usos_it_key */
/* NVMe target, Setup 6.0 / 6.1 (Vista / 2008 / 7 x86 under the PE10 donor):
 * the folder with usosnvme.inf / .sys (USOS_NVME_DRIVERS, set by
 * usos-x86-csmwrap.cmd). Setup refuses a disk whose controller driver (the
 * donor's stornvme) the new system lacks ("Windows needs the driver for
 * [Standard NVM Express controller]", QEMU 2026-10-12) unless a driver for
 * it was loaded: Microsoft-Windows-PnpCustomizationsWinPE DriverPaths
 * (docs/nvme-nt6-2026-10-12.md). */
static char nvme_drivers[MAX_PATH];
static DWORD nvme_component(const char *in, DWORD n, char *out, DWORD cap) {
    static const char pe[] = "<settings pass=\"windowsPE\">";
    static const char head[] = "<component name=\"Microsoft-Windows-PnpCustomizationsWinPE\" processorArchitecture=\"x86\" publicKeyToken=\"31bf3856ad364e35\" language=\"neutral\" versionScope=\"nonSxS\" xmlns:wcm=\"http://schemas.microsoft.com/WMIConfig/2002/State\"><DriverPaths><PathAndCredentials wcm:action=\"add\" wcm:keyValue=\"1\"><Path>";
    static const char tail[] = "</Path></PathAndCredentials></DriverPaths></component>";
    long at = usos_it_find(in, n, 0, pe);
    if (at < 0 || usos_it_find(in, n, 0, "Microsoft-Windows-PnpCustomizationsWinPE") >= 0) return 0;
    DWORD split = (DWORD)at + sizeof(pe) - 1, path = usos_it_len(nvme_drivers);
    if (n + sizeof(head) + path + sizeof(tail) > cap) return 0;
    DWORD o = 0;
    memcpy(out, in, split); o = split;
    memcpy(out + o, head, sizeof(head) - 1); o += sizeof(head) - 1;
    memcpy(out + o, nvme_drivers, path); o += path;
    memcpy(out + o, tail, sizeof(tail) - 1); o += sizeof(tail) - 1;
    memcpy(out + o, in + split, n - split); o += n - split;
    return o;
}
static BOOL write_answer(const WCHAR *input, const WCHAR *output) {
    DWORD got = 0, len = 0; const char *text = 0, *note = "";
    if (lstrcmpW(input, L"-") != 0) {
        HANDLE h = CreateFileW(input, GENERIC_READ, FILE_SHARE_READ, 0, OPEN_EXISTING, 0, 0);
        if (h == INVALID_HANDLE_VALUE) return FALSE;
        BOOL ok = ReadFile(h, xml_in, sizeof(xml_in), &got, 0); CloseHandle(h);
        if (!ok || got == 0 || got == sizeof(xml_in)) return FALSE;
        text = xml_in; len = got;
        if (got >= 2 && (BYTE)xml_in[0] == 0xff && (BYTE)xml_in[1] == 0xfe) {
            len = usos_it_utf16_to_utf8((const BYTE *)xml_in, got, xml_utf8, sizeof(xml_utf8));
            if (!len) return FALSE;
            text = xml_utf8;
            say("[X86_CSMWRAP] answer: UTF-16 file converted to UTF-8\r\n");
        } else if (got >= 3 && (BYTE)xml_in[0] == 0xef && (BYTE)xml_in[1] == 0xbb && (BYTE)xml_in[2] == 0xbf) { text += 3; len -= 3; }
    }
    DWORD n = usos_installto_answer(text, len, xml_scratch, sizeof(xml_scratch), xml_out, sizeof(xml_out), disk, windows_number, "x86", modern_setup, &note);
    if (!n) return FALSE;
    say("[X86_CSMWRAP] answer: "); say(note); say("\r\n");
    if (nvme_drivers[0]) {
        DWORD m = nvme_component(xml_out, n, xml_scratch, sizeof(xml_scratch));
        if (m) { memcpy(xml_out, xml_scratch, m); n = m; say("[X86_CSMWRAP] answer: NVMe driver path added (PnpCustomizationsWinPE): "); say(nvme_drivers); say("\r\n"); }
        else say("[X86_CSMWRAP] answer: NVMe driver path NOT added (no windowsPE settings or already present)\r\n");
    }
    HANDLE h = CreateFileW(output, GENERIC_WRITE, 0, 0, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    if (h == INVALID_HANDLE_VALUE) return FALSE;
    DWORD wrote = 0; BOOL ok = WriteFile(h, xml_out, n, &wrote, 0) && wrote == n && FlushFileBuffers(h);
    CloseHandle(h);
    return ok;
}

static BOOL exists_on_partition(const WCHAR *tail) {
    WCHAR name[MAX_PATH] = L"\\\\?\\GLOBALROOT\\Device\\Harddisk";
    wdecimal(name + lstrlenW(name), disk); lstrcatW(name, L"\\Partition"); wdecimal(name + lstrlenW(name), windows_number); lstrcatW(name, tail);
    DWORD a = GetFileAttributesW(name);
    return a != INVALID_FILE_ATTRIBUTES && !(a & FILE_ATTRIBUTE_DIRECTORY);
}
/* ---- target <out>: letter + NT version of the installed Windows ---------
 * For the USB 3 step of usos-x86-csmwrap.cmd (offline DISM needs a drive
 * letter): the volume that starts at the prepared Windows partition of the
 * prepared disk keeps its letter, or gets the first free one. <out> receives
 * "<L>: <major>.<minor>" from the version of Windows\System32\ntoskrnl.exe. */
static WCHAR target_root[4];
static BOOL target_letter(void) {
    WCHAR volume[64], names[256]; DWORD got = 0;
    HANDLE f = FindFirstVolumeW(volume, 64);
    if (f == INVALID_HANDLE_VALUE) return FALSE;
    BOOL found = FALSE;
    do {
        int len = lstrlenW(volume);
        if (len < 2 || volume[len - 1] != L'\\') continue;
        volume[len - 1] = 0;
        HANDLE h = CreateFileW(volume, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, 0, OPEN_EXISTING, 0, 0);
        volume[len - 1] = L'\\';
        if (h == INVALID_HANDLE_VALUE) continue;
        VOLUME_DISK_EXTENTS e;
        BOOL match = DeviceIoControl(h, IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS, 0, 0, &e, sizeof(e), &got, 0) && e.NumberOfDiskExtents == 1 &&
                     e.Extents[0].DiskNumber == disk && (ULONGLONG)e.Extents[0].StartingOffset.QuadPart == windows_start * 512;
        CloseHandle(h);
        if (!match) continue;
        found = TRUE;
        if (GetVolumePathNamesForVolumeNameW(volume, names, 256, &got)) {
            for (WCHAR *p = names; *p; p += lstrlenW(p) + 1)
                if (p[1] == L':' && p[2] == L'\\' && !p[3]) { target_root[0] = p[0]; target_root[1] = L':'; target_root[2] = L'\\'; target_root[3] = 0; break; }
        }
        if (!target_root[0]) {
            DWORD used = GetLogicalDrives();
            for (DWORD i = 2; i < 26 && !target_root[0]; i++) if (!(used & (1u << i))) {
                WCHAR root[4] = {(WCHAR)(L'A' + i), L':', L'\\', 0};
                if (SetVolumeMountPointW(root, volume)) { lstrcpyW(target_root, root); logn("letter given to the Windows partition (ASCII)=", (DWORD)root[0]); }
            }
        }
        break;
    } while (FindNextVolumeW(f, volume, 64));
    FindVolumeClose(f);
    return found && target_root[0];
}
static DWORD file_build; /* build of the last file_version() */
static BOOL file_version(const WCHAR *file, DWORD *major, DWORD *minor) {
    DWORD unused = 0, n = GetFileVersionInfoSizeW(file, &unused);
    if (!n || n > sizeof(buffer)) return FALSE;
    VS_FIXEDFILEINFO *v = 0; UINT size = 0;
    if (!GetFileVersionInfoW(file, 0, n, buffer) || !VerQueryValueW(buffer, L"\\", (void **)&v, &size) || size < sizeof(*v)) return FALSE;
    *major = HIWORD(v->dwFileVersionMS); *minor = LOWORD(v->dwFileVersionMS); file_build = HIWORD(v->dwFileVersionLS);
    return TRUE;
}
static BOOL target_version(DWORD *major, DWORD *minor) {
    WCHAR file[MAX_PATH]; lstrcpyW(file, target_root); lstrcatW(file, L"Windows\\System32\\ntoskrnl.exe");
    return file_version(file, major, minor);
}
static BOOL write_target(const WCHAR *output) {
    DWORD major = 0, minor = 0;
    if (!target_letter()) { say("[X86_CSMWRAP] the installed Windows volume has no drive letter\r\n"); return FALSE; }
    if (!target_version(&major, &minor)) { say("[X86_CSMWRAP] the installed Windows has no readable ntoskrnl.exe version\r\n"); return FALSE; }
    char line[32], d[24]; int at = 0;
    line[at++] = (char)target_root[0]; line[at++] = ':'; line[at++] = ' ';
    decimal(d, major); for (int i = 0; d[i]; i++) line[at++] = d[i];
    line[at++] = '.';
    decimal(d, minor); for (int i = 0; d[i]; i++) line[at++] = d[i];
    line[at++] = ' '; /* third token: the build (6002 = Vista / 2008 SP2: OOBE gate) */
    decimal(d, file_build); for (int i = 0; d[i]; i++) line[at++] = d[i];
    line[at++] = '\r'; line[at++] = '\n'; line[at] = 0;
    say("[X86_CSMWRAP] installed Windows: "); say(line);
    HANDLE h = CreateFileW(output, GENERIC_WRITE, 0, 0, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    if (h == INVALID_HANDLE_VALUE) return FALSE;
    DWORD wrote = 0; BOOL ok = WriteFile(h, line, (DWORD)at, &wrote, 0) && wrote == (DWORD)at;
    CloseHandle(h);
    return ok;
}

/* ---- stick: read-only dirty check of USB / removable volumes -------------
 * X470 2026-10-11: Windows 10 x86 phase 2 ran "Scanning and repairing drive"
 * on the USOS stick (a micro-Linux session restarted with the ESP still
 * mounted rw, tools/stick_release.sh). Only logs FSCTL_IS_VOLUME_DIRTY of
 * every volume on a USB or removable disk; nothing is written to them. */
static void stick_report(void) {
    WCHAR volume[64]; DWORD got = 0, checked = 0;
    HANDLE f = FindFirstVolumeW(volume, 64);
    if (f == INVALID_HANDLE_VALUE) return;
    do {
        int len = lstrlenW(volume);
        if (len < 2 || volume[len - 1] != L'\\') continue;
        WCHAR fs[16] = {0}; DWORD serial = 0;
        GetVolumeInformationW(volume, 0, 0, &serial, 0, 0, fs, 16);
        volume[len - 1] = 0;
        HANDLE h = CreateFileW(volume, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, 0, OPEN_EXISTING, 0, 0);
        volume[len - 1] = L'\\';
        if (h == INVALID_HANDLE_VALUE) continue;
        VOLUME_DISK_EXTENTS e; BOOL usb = FALSE; DWORD number = 0xffffffff;
        if (DeviceIoControl(h, IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS, 0, 0, &e, sizeof(e), &got, 0) && e.NumberOfDiskExtents == 1) {
            number = e.Extents[0].DiskNumber;
            HANDLE d = disk_handle(number, 0);
            if (d != INVALID_HANDLE_VALUE) { usb = !internal(d); CloseHandle(d); }
        }
        if (usb) {
            ULONG dirty = 0; checked++;
            /* FSCTL_IS_VOLUME_DIRTY needs a read handle (no lock, no write). */
            volume[len - 1] = 0;
            HANDLE r = CreateFileW(volume, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, 0, OPEN_EXISTING, 0, 0);
            volume[len - 1] = L'\\';
            BOOL ok = r != INVALID_HANDLE_VALUE && DeviceIoControl(r, FSCTL_IS_VOLUME_DIRTY, 0, 0, &dirty, sizeof(dirty), &got, 0);
            DWORD error = ok ? 0 : GetLastError();
            if (r != INVALID_HANDLE_VALUE) CloseHandle(r);
            char name[16]; int i = 0; for (; fs[i] && i < 15; i++) name[i] = (char)fs[i]; name[i] = 0;
            say("[X86_CSMWRAP] stick volume fs="); say(i ? name : "?"); say("\r\n");
            logn("  on disk=", number);
            logn("  volume serial (decimal)=", serial);
            logn(ok ? "  dirty bit (1 = Windows would run autochk on it)=" : "  dirty bit query failed, error=", ok ? (dirty & VOLUME_IS_DIRTY) : error);
        }
        CloseHandle(h);
    } while (FindNextVolumeW(f, volume, 64));
    FindVolumeClose(f);
    logn("USB / removable volumes checked=", checked);
}

/* ---- nodump: crash-dump stack off in this WinPE (NVMe target) ------------
 * The donor PE booted from the NVMe staging partition, so its crash-dump
 * stack (dump_stornvme) is armed for that controller. When Setup installs
 * usosnvme for the controller (PnpCustomizationsWinPE, the only way Vista /
 * 7 Setup accepts a disk without an inbox driver), the swap bugchecked in
 * dump_stornvme.sys (KMODE_EXCEPTION_NOT_HANDLED, QEMU 2026-10-12). Turn the
 * dump off and let the kernel re-read CrashControl, as the System applet
 * does (SystemCrashDumpStateInformation). */
static DWORD no_dump_stack(void) {
    HKEY k; DWORD zero = 0, result = 0;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SYSTEM\\CurrentControlSet\\Control\\CrashControl", 0, KEY_SET_VALUE, &k) == ERROR_SUCCESS) {
        RegSetValueExW(k, L"CrashDumpEnabled", 0, REG_DWORD, (const BYTE *)&zero, 4);
        RegSetValueExW(k, L"AutoReboot", 0, REG_DWORD, (const BYTE *)&zero, 4);
        RegCloseKey(k);
    } else result |= 1;
    HANDLE token;
    if (OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES, &token)) {
        TOKEN_PRIVILEGES tp = {1}; tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
        if (LookupPrivilegeValueW(0, L"SeCreatePagefilePrivilege", &tp.Privileges[0].Luid)) AdjustTokenPrivileges(token, FALSE, &tp, 0, 0, 0);
        CloseHandle(token);
    }
    typedef LONG (WINAPI *set_info_t)(ULONG, PVOID, ULONG);
    set_info_t set_info = (set_info_t)(void *)GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtSetSystemInformation");
    LONG status = -1; ULONG state = 0;
    if (set_info) status = set_info(34 /* SystemCrashDumpStateInformation */, &state, sizeof(state));
    logn("crash dump off: registry=", (result & 1) ? 0 : 1);
    logn("crash dump state re-read NTSTATUS=", (DWORD)status);
    return 0;
}

/* ---- lowmem: the PE10 donor without RAM above 4 GiB (NVMe target) --------
 * Windows 7 SP1 x86 Setup in the PAE PE10 x86 donor wrote a corrupt image to
 * an NVMe disk (stornvme) when the PE had RAM above 4 GiB: 0x80070570 /
 * 0x80070003 during the apply with 4 and 8 GiB guest RAM, clean with 3 GiB
 * (QEMU 2026-10-13, docs/nvme-nt6-2026-10-12.md section 10). The X470 has
 * 32 GiB. When the PE sees memory above 4 GiB, the staging BCD's boot entry
 * gets truncatememory 0x100000000 (BcdLibraryInteger_TruncatePhysicalMemory,
 * element 15000007) and the cmd restarts the PE once; the disk is still in
 * its prepared state (this runs before "before"). Only the staging BCD is
 * changed: the installed Windows gets its own BCD from Setup and the staging
 * partition is removed afterwards.
 * Exit: 0 nothing to do (no RAM above 4 GiB, or the entry already has the
 * limit), 10 limit written (restart now), 1 error (logged; the flow goes on). */
static ULONGLONG ram_top(void) {
    static BYTE data[16384]; HKEY k; DWORD type = 0, size = sizeof(data);
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"HARDWARE\\RESOURCEMAP\\System Resources\\Physical Memory", 0, KEY_QUERY_VALUE, &k) != ERROR_SUCCESS) return 0;
    LONG r = RegQueryValueExW(k, L".Translated", 0, &type, data, &size); RegCloseKey(k);
    if (r != ERROR_SUCCESS || size < 4) return 0;
    /* CM_RESOURCE_LIST: Count, then per list InterfaceType, BusNumber,
     * Version/Revision, Count and 16-byte partial descriptors (Type 3 memory,
     * 7 large memory; Flags 0x200/0x400/0x800 scale Length by 2^8/16/32). */
    ULONGLONG top = 0; DWORD lists, o = 4; memcpy(&lists, data, 4);
    for (DWORD l = 0; l < lists && o + 16 <= size; l++) {
        DWORD count; memcpy(&count, data + o + 12, 4); o += 16;
        for (DWORD i = 0; i < count && o + 16 <= size; i++, o += 16) {
            BYTE t = data[o]; WORD flags; ULONGLONG start, length; DWORD len;
            memcpy(&flags, data + o + 2, 2); memcpy(&start, data + o + 4, 8); memcpy(&len, data + o + 12, 4);
            if (t != 3 && t != 7) continue;
            length = len;
            if (t == 7 && (flags & 0x200)) length <<= 8;
            else if (t == 7 && (flags & 0x400)) length <<= 16;
            else if (t == 7 && (flags & 0x800)) length <<= 32;
            if (start + length > top) top = start + length;
        }
    }
    return top;
}
static void privilege(const WCHAR *name) {
    HANDLE token;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES, &token)) return;
    TOKEN_PRIVILEGES tp = {1}; tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
    if (LookupPrivilegeValueW(0, name, &tp.Privileges[0].Luid)) AdjustTokenPrivileges(token, FALSE, &tp, 0, 0, 0);
    CloseHandle(token);
}
static DWORD staging_number(void) {
    HANDLE h = disk_handle(disk, GENERIC_READ); DWORD got = 0, number = 0;
    if (h == INVALID_HANDLE_VALUE) return 0;
    if (DeviceIoControl(h, IOCTL_DISK_GET_DRIVE_LAYOUT_EX, 0, 0, buffer, sizeof(buffer), &got, 0)) {
        DRIVE_LAYOUT_INFORMATION_EX *layout = (void *)buffer;
        for (DWORD i = 0; i < layout->PartitionCount; i++) {
            PARTITION_INFORMATION_EX *p = &layout->PartitionEntry[i];
            if (p->PartitionNumber && (ULONGLONG)p->StartingOffset.QuadPart == staging_start * 512) number = p->PartitionNumber;
        }
    }
    CloseHandle(h);
    return number;
}
static DWORD low_memory(void) {
    ULONGLONG top = ram_top();
    logn("WinPE RAM top (MiB)=", (DWORD)(top >> 20));
    if (top <= 0x100000000ULL) { say("[X86_CSMWRAP] lowmem: no RAM above 4 GiB in this WinPE\r\n"); return 0; }
    DWORD part = staging_number();
    if (!part) { say("[X86_CSMWRAP] lowmem: staging partition not found\r\n"); return 1; }
    WCHAR file[MAX_PATH] = L"\\\\?\\GLOBALROOT\\Device\\Harddisk";
    wdecimal(file + lstrlenW(file), disk); lstrcatW(file, L"\\Partition"); wdecimal(file + lstrlenW(file), part); lstrcatW(file, L"\\boot\\bcd");
    privilege(L"SeRestorePrivilege"); privilege(L"SeBackupPrivilege");
    const WCHAR *root = L"USOS_BCD"; BOOL loaded = FALSE;
    LONG r = RegLoadKeyW(HKEY_LOCAL_MACHINE, root, file);
    if (r == ERROR_SUCCESS) loaded = TRUE;
    else {
        /* The system store of a WinPE started from a disk is that disk's
         * \boot\bcd (HKLM\BCD00000000); edit it there when it is in use. */
        logn("lowmem: staging BCD not loadable as a hive, error=", (DWORD)r);
        root = L"BCD00000000";
    }
    WCHAR key[160]; lstrcpyW(key, root); lstrcatW(key, L"\\Objects\\{9dea862c-5cdd-4e70-acc1-f32b344d4795}\\Elements\\23000003");
    WCHAR guid[64] = {0}; DWORD type = 0, size = sizeof(guid) - sizeof(WCHAR); HKEY k; DWORD result = 1;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, key, 0, KEY_QUERY_VALUE, &k) == ERROR_SUCCESS) {
        if (RegQueryValueExW(k, L"Element", 0, &type, (BYTE *)guid, &size) != ERROR_SUCCESS || type != REG_SZ || lstrlenW(guid) != 38) guid[0] = 0;
        RegCloseKey(k);
    }
    if (!guid[0]) say("[X86_CSMWRAP] lowmem: the BCD has no default boot entry\r\n");
    else {
        lstrcpyW(key, root); lstrcatW(key, L"\\Objects\\"); lstrcatW(key, guid); lstrcatW(key, L"\\Elements\\15000007");
        ULONGLONG limit = 0, want = 0x100000000ULL; size = sizeof(limit);
        if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, key, 0, KEY_QUERY_VALUE, &k) == ERROR_SUCCESS) {
            if (RegQueryValueExW(k, L"Element", 0, &type, (BYTE *)&limit, &size) != ERROR_SUCCESS) limit = 0;
            RegCloseKey(k);
        }
        if (limit) { logn("lowmem: the boot entry already has truncatememory (MiB)=", (DWORD)(limit >> 20)); result = 0; }
        else if (RegCreateKeyExW(HKEY_LOCAL_MACHINE, key, 0, 0, 0, KEY_SET_VALUE, 0, &k, 0) == ERROR_SUCCESS) {
            r = RegSetValueExW(k, L"Element", 0, REG_BINARY, (const BYTE *)&want, sizeof(want));
            RegFlushKey(k); RegCloseKey(k);
            if (r == ERROR_SUCCESS) { say("[X86_CSMWRAP] lowmem: truncatememory 0x100000000 set in the staging BCD; restarting the WinPE\r\n"); result = 10; }
            else logn("lowmem: cannot write truncatememory, error=", (DWORD)r);
        } else say("[X86_CSMWRAP] lowmem: cannot create the truncatememory element\r\n");
    }
    if (loaded) { r = RegUnLoadKeyW(HKEY_LOCAL_MACHINE, L"USOS_BCD"); if (r != ERROR_SUCCESS) logn("lowmem: BCD unload error=", (DWORD)r); }
    return result;
}

/* samefile: byte compare of two files (exit 0 equal, 1 different or unreadable). */
static BOOL same_file(const WCHAR *a, const WCHAR *b) {
    static BYTE other[65536];
    HANDLE x = CreateFileW(a, GENERIC_READ, FILE_SHARE_READ, 0, OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, 0);
    if (x == INVALID_HANDLE_VALUE) return FALSE;
    HANDLE y = CreateFileW(b, GENERIC_READ, FILE_SHARE_READ, 0, OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, 0);
    if (y == INVALID_HANDLE_VALUE) { CloseHandle(x); return FALSE; }
    BOOL equal = TRUE;
    for (;;) {
        DWORD got_x = 0, got_y = 0;
        if (!ReadFile(x, buffer, sizeof(buffer), &got_x, 0) || !ReadFile(y, other, sizeof(other), &got_y, 0) || got_x != got_y || !same(buffer, other, got_x)) { equal = FALSE; break; }
        if (!got_x) break;
    }
    CloseHandle(x); CloseHandle(y);
    return equal;
}

/* ---- hideesp: no drive letter for the CSMWrap ESP (windows_csmwrap_hide.h) */
#include "windows_csmwrap_hide.h"
static DWORD hide_esp(const BYTE *s) {
    if (!esp_start) { say("[X86_CSMWRAP] hideesp: esp_start missing in usos-csmwrap-target.ini; skipped\r\n"); return 11; }
    BOOL esp = FALSE;
    for (int i = 0; i < 4; i++) { const BYTE *e = s + 446 + 16 * i; DWORD first; memcpy(&first, e + 8, 4); if (e[4] == 0xEF && first == esp_start) esp = TRUE; }
    if (!esp) { logn("hideesp: no MBR type 0xEF entry at esp_start (LBA low 32 bits)=", (DWORD)esp_start); return 11; }
    if (!target_letter()) { say("[X86_CSMWRAP] hideesp: the installed Windows volume has no drive letter; skipped\r\n"); return 11; }
    WCHAR hive[MAX_PATH]; lstrcpyW(hive, target_root); lstrcatW(hive, L"Windows\\System32\\config\\SYSTEM");
    DWORD letters = 0, r = usos_hide_esp_letter(hive, signature, esp_start, &letters);
    logn("hideesp: drive letters of the CSMWrap ESP removed from MountedDevices=", letters);
    logn(r == USOS_HIDE_WRITTEN ? "hideesp: no-drive-letter entry for the CSMWrap ESP written, LBA (low 32 bits)=" :
         r == USOS_HIDE_PRESENT ? "hideesp: no-drive-letter entry already present, LBA (low 32 bits)=" : "hideesp: FAILED (code in the next line), LBA (low 32 bits)=", (DWORD)esp_start);
    if (r >= USOS_HIDE_ERR_LOAD) { logn("hideesp: error code=", r); return 11; }
    return 0;
}

/* ---- display: USOSRES for every answer (windows_display_register.h) ---- */
#include "windows_display_register.h"
static DWORD display_register(void) {
    if (!target_letter()) { say("[X86_CSMWRAP] display: the installed Windows volume has no drive letter; skipped\r\n"); return 11; }
    DWORD acl = 0, r = usos_display_register(target_root, &acl);
    if (r == USOS_DREG_NOT_STAGED) { say("[X86_CSMWRAP] display: \\USOS\\NT6 not staged (user answer with its own <Display>, or staging failed); Windows keeps its mode\r\n"); return 0; }
    logn("display: \\USOS\\NT6 DACL set on objects (of 3)=", acl);
    logn(r == USOS_DREG_WRITTEN ? "display: USOSRES registered in the Default user's Run (first sign-in), code=" :
         r == USOS_DREG_PRESENT ? "display: USOSRES already in the Default user's Run, code=" : "display: FAILED, Default user hive code=", r);
    return r >= USOS_DREG_ERR_LOAD ? 11 : 0;
}

/* ---- faststartup: Fast Startup off in the installed Windows 8 / 8.1 / 10 ----
 * (tools/windows_fast_startup.h). The disk moves between computers, and a
 * hibernated volume is only safe on the machine that wrote it, so every
 * USOS-installed 8 / 8.1 / 10 starts with a full boot. The opt-out file is
 * the one documented for DATA (Systems\Windows\<version>\Unattended). */
#include "windows_fast_startup.h"
static DWORD fast_startup(void) {
    WCHAR kernel[MAX_PATH], file[MAX_PATH];
    DWORD major = 0, minor = 0, r;
    const WCHAR *folder, *folder2;
    if (!target_letter()) { say("[X86_CSMWRAP] faststartup: the installed Windows volume has no drive letter; skipped\r\n"); return 11; }
    lstrcpyW(kernel, target_root); lstrcatW(kernel, L"Windows\\System32\\ntoskrnl.exe");
    if (!file_version(kernel, &major, &minor)) { say("[X86_CSMWRAP] faststartup: cannot read the installed kernel version; skipped\r\n"); return 11; }
    logn("faststartup: installed NT version major=", major); logn("faststartup: minor=", minor);
    if (major < 6 || (major == 6 && minor < 2)) { say("[X86_CSMWRAP] faststartup: Vista / 7 have no Fast Startup; nothing to do\r\n"); return 0; }
    folder = L"Windows 10";
    folder2 = 0;
    if (major == 6 && minor == 2) folder = L"Windows 8";
    /* 6.3: Windows 8.1, or Embedded 8.1 Industry with its own DATA folder
     * (the WinPE cannot tell them apart; either folder's file counts). */
    else if (major == 6 && minor == 3) { folder = L"Windows 8.1"; folder2 = L"Windows Embedded 8.1 Industry"; }
    /* The documented opt-out: DATA\Systems\Windows\<version>\Unattended\
     * fast-startup-on.txt on any volume but the installed one. */
    for (WCHAR letter = L'C'; letter <= L'Z'; letter++) {
        if (letter == target_root[0]) continue;
        for (int i = 0; i < 2; i++) {
            const WCHAR *name = i ? folder2 : folder;
            if (!name) continue;
            file[0] = letter; lstrcpyW(file + 1, L":\\Systems\\Windows\\");
            lstrcatW(file, name); lstrcatW(file, L"\\Unattended\\fast-startup-on.txt");
            if (GetFileAttributesW(file) != INVALID_FILE_ATTRIBUTES && usos_fs_hiberboot) {
                say("[X86_CSMWRAP] faststartup: fast-startup-on.txt on DATA; Windows keeps its own setting\r\n");
                usos_fs_hiberboot = FALSE;
            }
        }
    }
    r = usos_fast_startup(target_root);
    logn(r == USOS_FS_WRITTEN ? "faststartup: HiberbootEnabled=0 written in the installed SYSTEM hive, code=" :
         r == USOS_FS_PRESENT ? "faststartup: HiberbootEnabled was already 0, code=" :
         r == USOS_FS_SKIPPED ? "faststartup: HiberbootEnabled not changed (fast-startup-on.txt), code=" : "faststartup: FAILED, hive code=", r);
    /* DIAGNOSTIC (windows_fast_startup.h): AutoReboot=0 in the same load. */
    if (r != USOS_FS_ERR_LOAD && r != USOS_FS_ERR_UNLOAD) {
        logn(usos_fs_autoreboot == USOS_FS_WRITTEN ? "faststartup: DIAGNOSTIC CrashControl AutoReboot=0 written (a bugcheck stays on screen), code=" :
             usos_fs_autoreboot == USOS_FS_PRESENT ? "faststartup: DIAGNOSTIC CrashControl AutoReboot was already 0, code=" : "faststartup: DIAGNOSTIC CrashControl AutoReboot NOT written, code=", usos_fs_autoreboot);
        logn("faststartup: CrashControl CrashDumpEnabled as found, unchanged (4294967295 = missing)=", usos_fs_crashdump);
    }
    /* Not fatal: the hive unload writes the value as well (logged for the
     * X470 report; see windows_fast_startup.h). */
    if (r == USOS_FS_WRITTEN && usos_fs_flush_error != ERROR_SUCCESS) logn("faststartup: RegFlushKey failed (unload still commits), Win32 code=", (DWORD)usos_fs_flush_error);
    return r >= USOS_FS_ERR_LOAD ? 11 : 0;
}

/* "after poweroff" (Windows 8 / 8.1 / 10 x86; the .cmd reads the installed
 * version with "target"): the WinPE powers the computer off (wpeutil
 * shutdown) instead of a warm restart. X470 2026-10-31 (B261031-195000):
 * after "wpeutil reboot" the installed Windows 10 x86 reset itself ~30 s
 * into its first boot, with the GPU PCIe port 00:03.1 missing; the interim
 * image route ended with a power-off and a cold boot and reached the desktop
 * (docs/nvme-nt6-2026-10-12.md section 21). Polish text (user request for
 * this diagnostic round), ASCII source with \u escapes; closes itself after
 * 15 seconds. */
#define USOS_POWEROFF_NOTICE_MS 15000
static DWORD WINAPI notice_poweroff(LPVOID unused) {
    (void)unused;
    MessageBoxW(0, L"Pierwsza część instalacji Windows została zakończona.\n\n"
                   L"Komputer zostanie teraz wyłączony. Wyjmij pendrive USOS, a następnie włącz komputer przyciskiem zasilania, aby kontynuować instalację Windows z dysku (przez CSMWrap). "
                   L"Jeśli pendrive zostanie podłączony, wybierz wpis UEFI tego dysku w menu rozruchowym firmware.\n\n"
                   L"Komputer wyłączy się sam za 15 sekund.",
                L"USOS - Windows bez CSM", MB_OK | MB_ICONINFORMATION | MB_SETFOREGROUND | MB_TOPMOST | MB_SYSTEMMODAL);
    return 0;
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
    if (lstrcmpiW(args[1], L"answer-test") == 0 && (arg_count == 6 || arg_count == 7)) {
        disk = (DWORD)args[4][0] - L'0'; windows_number = (DWORD)args[5][0] - L'0';
        modern_setup = arg_count == 7 && lstrcmpiW(args[6], L"modern") == 0;
        { char d[MAX_PATH]; DWORD dn = GetEnvironmentVariableA("USOS_NVME_DRIVERS", d, MAX_PATH); if (dn && dn < MAX_PATH) lstrcpyA(nvme_drivers, d); }
        ExitProcess(write_answer(args[2], args[3]) ? 0 : 7);
    }
    /* Host test of the MountedDevices edit only (tools/tests/test_csmwrap_esp_hide.py):
     * hideesp-test <HKCU key standing for MountedDevices> <signature hex> <esp LBA decimal>;
     * exit = result * 10 + letters removed (9990: the key does not open). */
    if (lstrcmpiW(args[1], L"hideesp-test") == 0 && arg_count == 5) {
        DWORD sig = 0; ULONGLONG lba = 0; HKEY k;
        for (const WCHAR *c = args[3]; *c; c++) sig = sig * 16 + (DWORD)(*c <= L'9' ? *c - L'0' : (*c | 32) - L'a' + 10);
        for (const WCHAR *c = args[4]; *c; c++) lba = lba * 10 + (ULONGLONG)(*c - L'0');
        if (RegOpenKeyExW(HKEY_CURRENT_USER, args[2], 0, KEY_QUERY_VALUE | KEY_SET_VALUE, &k) != ERROR_SUCCESS) ExitProcess(9990);
        DWORD letters = 0, r = usos_hide_esp_in_key(k, sig, lba, &letters);
        RegCloseKey(k);
        ExitProcess(r * 10 + letters);
    }
    /* Host test of the registration only (tools/tests/test_display_register.py):
     * display-test <folder standing for the volume root, with a trailing \>
     * <HKCU key standing for the Default hive root>; exit = staged * 1000 +
     * acl objects * 100 + result (9990: the key does not open). */
    if (lstrcmpiW(args[1], L"display-test") == 0 && arg_count == 4) {
        HKEY k; DWORD staged = usos_display_staged(args[2]), acl = staged ? usos_display_acl(args[2]) : 0, r = USOS_DREG_NOT_STAGED;
        if (RegCreateKeyExW(HKEY_CURRENT_USER, args[3], 0, 0, 0, KEY_CREATE_SUB_KEY | KEY_QUERY_VALUE | KEY_SET_VALUE, 0, &k, 0) != ERROR_SUCCESS) ExitProcess(9990);
        if (staged) r = usos_display_register_in_key(k);
        RegCloseKey(k);
        ExitProcess(staged * 1000 + acl * 100 + (r > 99 ? 99 : r));
    }
    if (lstrcmpiW(args[1], L"samefile") == 0 && arg_count == 4) ExitProcess(same_file(args[2], args[3]) ? 0 : 1);
    if (lstrcmpiW(args[1], L"stick") == 0) { stick_report(); ExitProcess(0); }
    if (lstrcmpiW(args[1], L"nodump") == 0) ExitProcess(no_dump_stack());
    /* disks: read-only inventory of every PhysicalDrive (find_disk verbose);
     * the expected signature from usos-csmwrap-target.ini when present.
     * For a manual check in a WinPE command prompt; exit 0. */
    if (lstrcmpiW(args[1], L"disks") == 0) { load_target(); find_disk(TRUE); ExitProcess(0); }
    /* Host test of the hive edit only (tools/tests/test_windows_fast_startup.py):
     * faststartup-test <key under HKCU standing for a SYSTEM hive root>;
     * exit code is the result code (0 written, 1 present, 100+ error). */
    if (lstrcmpiW(args[1], L"faststartup-test") == 0 && arg_count == 3) {
        HKEY k;
        DWORD r;
        if (RegOpenKeyExW(HKEY_CURRENT_USER, args[2], 0, KEY_QUERY_VALUE | KEY_CREATE_SUB_KEY, &k) != ERROR_SUCCESS) ExitProcess(99);
        r = usos_fast_startup_in_system(k);
        RegCloseKey(k);
        ExitProcess(r > 99 ? 99 : r);
    }
    /* setupver <setup.exe>: exit code = major * 10 + minor of the file version
     * (60 Vista / 2008, 61 Windows 7, 62 / 63 8.x, 100 Windows 10), 0 unknown.
     * usos-x86-csmwrap.cmd: NVMe target, Setup 6.0 / 6.1 only. */
    if (lstrcmpiW(args[1], L"setupver") == 0 && arg_count == 3) {
        DWORD major = 0, minor = 0;
        if (!file_version(args[2], &major, &minor) || major > 25 || minor > 9) ExitProcess(0);
        logn("Setup file version major=", major); logn("Setup file version minor=", minor);
        ExitProcess(major * 10 + minor);
    }
    FIRMWARE_TYPE firmware;
    if (!GetFirmwareType(&firmware) || firmware != FirmwareTypeBios) { say("[X86_CSMWRAP] STOP: not booted in BIOS mode\r\n"); ExitProcess(2); }
    if (!load_target()) { say("[X86_CSMWRAP] STOP: usos-csmwrap-target.ini is invalid\r\n"); ExitProcess(3); }
    /* "before" (the first call) describes every disk; a later call only when
     * it fails (the inventory is read-only, so it simply runs again). */
    BOOL verbose = lstrcmpiW(args[1], L"before") == 0;
    /* lowmem (NVMe target, first call in the WinPE, before nodump and the
     * Setup copy): the RAM top and the full disk inventory come first, so
     * the startup log shows whether the disk answered at all in this boot,
     * also when the limit cannot be written (X470 2026-10-13: size / layout
     * error 433, docs/nvme-nt6-2026-10-12.md section 15). */
    if (lstrcmpiW(args[1], L"lowmem") == 0) { logn("lowmem: WinPE RAM top before any disk access (MiB)=", (DWORD)(ram_top() >> 20)); verbose = TRUE; }
    if (!find_disk(verbose) && (verbose || !find_disk(TRUE))) { say("[X86_CSMWRAP] STOP: the prepared disk was not found exactly once\r\n"); ExitProcess(4); }
    BYTE s[512];
    if (!mbr_io(s, FALSE)) { logn("cannot read the target MBR, error=", GetLastError()); ExitProcess(5); }
    int staging = slot_of(s, staging_start, staging_sectors, TRUE), windows = slot_of(s, windows_start, windows_sectors, FALSE);
    if (staging < 0 || windows < 0) { logn("MBR entries not found (staging slot+1, windows slot+1)=", (DWORD)((staging + 1) * 10 + windows + 1)); ExitProcess(5); }
    BYTE *se = s + 446 + 16 * staging, *we = s + 446 + 16 * windows;
    if (lstrcmpiW(args[1], L"lowmem") == 0) ExitProcess(low_memory());
    if (lstrcmpiW(args[1], L"before") == 0 && (arg_count == 4 || arg_count == 5)) {
        DWORD major = 0, minor = 0;
        if (arg_count == 5 && file_version(args[4], &major, &minor)) {
            modern_setup = major > 6 || (major == 6 && minor >= 2);
            WCHAR drv[MAX_PATH]; DWORD dn = GetEnvironmentVariableW(L"USOS_NVME_DRIVERS", drv, MAX_PATH);
            if (major == 6 && minor <= 1 && dn && dn < MAX_PATH) {
                int i = 0; for (; drv[i] && i < MAX_PATH - 1; i++) nvme_drivers[i] = drv[i] < 128 ? (char)drv[i] : '_';
                nvme_drivers[i] = 0;
            }
            logn("Setup version major=", major); logn("Setup version minor=", minor);
        } else say("[X86_CSMWRAP] Setup version unknown; product key left as in the answer\r\n");
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
    if (lstrcmpiW(args[1], L"target") == 0 && arg_count == 3) ExitProcess(write_target(args[2]) ? 0 : 9);
    if (lstrcmpiW(args[1], L"hideesp") == 0) ExitProcess(hide_esp(s));
    if (lstrcmpiW(args[1], L"display") == 0) ExitProcess(display_register());
    if (lstrcmpiW(args[1], L"faststartup") == 0) ExitProcess(fast_startup());
    if (lstrcmpiW(args[1], L"after") == 0) {
        BOOL bootmgr = exists_on_partition(L"\\bootmgr"), winload = exists_on_partition(L"\\Windows\\System32\\winload.exe");
        logn("bootmgr on the Windows partition=", bootmgr);
        logn("winload.exe on the Windows partition=", winload);
        int active = 0; for (int i = 0; i < 4; i++) if (s[446 + 16 * i] == 0x80) active++;
        if (!bootmgr || !winload || we[0] != 0x80 || active != 1) { say("[X86_CSMWRAP] STOP: the installed Windows partition is not ready to boot; staging kept\r\n"); ExitProcess(8); }
        memset(se, 0, 16);
        if (!write_mbr(s, "staging partition entry removed")) ExitProcess(6);
        BOOL poweroff = arg_count == 3 && lstrcmpiW(args[2], L"poweroff") == 0;
        say(poweroff ? "[X86_CSMWRAP] after: power-off notice (15 s), then wpeutil shutdown\r\n" : "[X86_CSMWRAP] after: remove-the-stick notice (2 min), then wpeutil reboot\r\n");
        HANDLE t = CreateThread(0, 0, poweroff ? notice_poweroff : notice, 0, 0, 0);
        if (t) { WaitForSingleObject(t, poweroff ? USOS_POWEROFF_NOTICE_MS : 120000); CloseHandle(t); }
        ExitProcess(0);
    }
    ExitProcess(2);
}
