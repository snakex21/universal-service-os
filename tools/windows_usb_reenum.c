/* usos-usbreenum: USB mass-storage device nodes after Windows Setup.
 *
 * X470 2026-10-14 (Windows 7 SP1 x86 via CSMWrap, build B261014-195920): the
 * USOS stick, plugged in during the whole installation, was not visible in
 * the installed Windows, not even after a restart; one unplug / replug made it
 * appear (every partition, usosmpart) and from then on it came up at every
 * boot. A boot rebuilds every device stack, a replug in addition creates the
 * device node again and installs it, so the state that survived the restart
 * lived in the device node (install / problem flags), not in a stack.
 *
 * Run once as SYSTEM after Setup (SetupComplete.cmd written by
 * usos-x86-csmwrap.cmd :usbfix), no window, never fatal:
 *   1. waits for the PnP installs Setup left running;
 *   2. logs every present USB\ and USBSTOR\ device node (status, problem
 *      code, ConfigFlags, service) and every USB disk (removable media,
 *      partitions, offline attribute) and the volumes;
 *   3. a USB\ or USBSTOR\ node with an install problem (CM_PROB 1 / 18 / 28,
 *      CONFIGFLAG_REINSTALL / FAILEDINSTALL) is removed, as an unplug does,
 *      and the device tree is re-enumerated with "retry installation", so
 *      the device comes back as new and is installed again (a replug);
 *   4. a USB\ or USBSTOR\ node with any other problem (except "disabled" =
 *      the user's choice) and every working USBSTOR\ node is restarted
 *      (DIF_PROPERTYCHANGE / DICS_PROPCHANGE: the disk stack, class filters
 *      included, is built again);
 *   5. logs the state again.
 * Log: %SystemDrive%\USOS\Logs\usos-usbreenum.log, and a copy in
 * EFI\USOS\Logs of the USOS stick when its first partition holds that folder.
 *
 *   usos-usbreenum.exe          the run above
 *   usos-usbreenum.exe report   steps 1, 2 only, to stdout (read-only, no
 *                               log file)
 *
 * Own code (GPL-3.0-or-later, Copyright (C) 2026 Maksymilian and the USOS
 * Authors), documented SetupAPI / CfgMgr32 calls only. No C runtime.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winioctl.h>
#include <setupapi.h>
#include <cfgmgr32.h>

void *memset(void *p, int value, size_t count) { volatile BYTE *b = p; while (count--) *b++ = (BYTE)value; return p; }
void *memcpy(void *d, const void *s, size_t n) { volatile BYTE *p = d; const BYTE *q = s; while (n--) *p++ = *q++; return d; }

static char logbuf[262144];
static DWORD loglen;
static void say(const char *s) {
    DWORD n = 0, w;
    while (s[n]) n++;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), s, n, &w, 0);
    for (DWORD i = 0; i < n && loglen < sizeof(logbuf) - 1; i++) logbuf[loglen++] = s[i];
}
static void num(ULONG v) { char d[12]; int n = 0; do { d[n++] = (char)('0' + v % 10); v /= 10; } while (v); char o[13]; int i = 0; while (n) o[i++] = d[--n]; o[i] = 0; say(o); }
static void hex(ULONG v) { char o[11] = "0x"; for (int i = 0; i < 8; i++) { int x = (v >> (28 - 4 * i)) & 15; o[2 + i] = (char)(x < 10 ? '0' + x : 'a' + x - 10); } o[10] = 0; say(o); }
static void wide(const WCHAR *s) { static char b[2048]; int n = WideCharToMultiByte(CP_ACP, 0, s, -1, b, sizeof(b), 0, 0); if (n > 0) say(b); }
static BOOL prefix(const WCHAR *s, const WCHAR *p) {
    for (; *p; s++, p++) { WCHAR a = *s, b = *p; if (a >= 'a' && a <= 'z') a -= 32; if (b >= 'a' && b <= 'z') b -= 32; if (a != b) return FALSE; }
    return TRUE;
}

#ifndef CONFIGFLAG_REINSTALL
#define CONFIGFLAG_REINSTALL 0x00000020
#endif
#ifndef CONFIGFLAG_FAILEDINSTALL
#define CONFIGFLAG_FAILEDINSTALL 0x00000040
#endif

typedef DWORD (WINAPI *wait_fn)(DWORD);
static void wait_installs(const char *when) {
    /* CMP_WaitNoPendingInstallEvents: cfgmgr32 (Vista+) or setupapi (XP). */
    wait_fn wait = 0;
    HMODULE m = LoadLibraryW(L"cfgmgr32.dll");
    if (m) wait = (wait_fn)GetProcAddress(m, "CMP_WaitNoPendingInstallEvents");
    if (!wait && (m = LoadLibraryW(L"setupapi.dll")) != 0) wait = (wait_fn)GetProcAddress(m, "CMP_WaitNoPendingInstallEvents");
    if (!wait) { say("[USBREENUM] no CMP_WaitNoPendingInstallEvents; waiting 15 s\r\n"); Sleep(15000); return; }
    DWORD r = wait(180000);
    say("[USBREENUM] pending PnP installs "); say(when); say(": wait result="); num(r); say(r == WAIT_OBJECT_0 ? " (none left)\r\n" : " (timeout / error)\r\n");
}

static BOOL usb_node(const WCHAR *id) { return prefix(id, L"USB\\") || prefix(id, L"USBSTOR\\"); }

static BOOL restart(HDEVINFO set, SP_DEVINFO_DATA *dev) {
    SP_PROPCHANGE_PARAMS pc;
    memset(&pc, 0, sizeof(pc));
    pc.ClassInstallHeader.cbSize = sizeof(SP_CLASSINSTALL_HEADER);
    pc.ClassInstallHeader.InstallFunction = DIF_PROPERTYCHANGE;
    pc.StateChange = DICS_PROPCHANGE;
    pc.Scope = DICS_FLAG_CONFIGSPECIFIC;
    pc.HwProfile = 0;
    if (!SetupDiSetClassInstallParamsW(set, dev, &pc.ClassInstallHeader, sizeof(pc))) return FALSE;
    BOOL ok = SetupDiCallClassInstaller(DIF_PROPERTYCHANGE, set, dev);
    SetupDiSetClassInstallParamsW(set, dev, 0, 0);
    return ok;
}

/* One pass over the present USB\ and USBSTOR\ nodes; act = FALSE: log only. */
static BOOL nodes(BOOL act) {
    BOOL reenumerate = FALSE;
    HDEVINFO set = SetupDiGetClassDevsW(0, 0, 0, DIGCF_ALLCLASSES | DIGCF_PRESENT);
    if (set == INVALID_HANDLE_VALUE) { say("[USBREENUM] SetupDiGetClassDevs failed, error="); num(GetLastError()); say("\r\n"); return FALSE; }
    SP_DEVINFO_DATA dev;
    dev.cbSize = sizeof(dev);
    for (DWORD i = 0; SetupDiEnumDeviceInfo(set, i, &dev); i++) {
        static WCHAR id[512], service[128];
        memset(id, 0, sizeof(id));
        if (!SetupDiGetDeviceInstanceIdW(set, &dev, id, 511, 0) || !usb_node(id)) continue;
        memset(service, 0, sizeof(service));
        SetupDiGetDeviceRegistryPropertyW(set, &dev, SPDRP_SERVICE, 0, (BYTE *)service, sizeof(service) - sizeof(WCHAR), 0);
        DWORD flags = 0, type = 0;
        BOOL have_flags = SetupDiGetDeviceRegistryPropertyW(set, &dev, SPDRP_CONFIGFLAGS, &type, (BYTE *)&flags, sizeof(flags), 0);
        ULONG status = 0, problem = 0;
        CONFIGRET cr = CM_Get_DevNode_Status(&status, &problem, dev.DevInst, 0);
        BOOL has_problem = cr == CR_SUCCESS && (status & DN_HAS_PROBLEM);
        say("[USBREENUM] node "); wide(id);
        say(" service="); wide(service[0] ? service : L"-");
        say(" status="); if (cr == CR_SUCCESS) hex(status); else { say("cr"); num(cr); }
        say(" started="); say(cr == CR_SUCCESS && (status & DN_STARTED) ? "1" : "0");
        say(" problem="); num(has_problem ? problem : 0);
        say(" configflags="); if (have_flags) hex(flags); else say("-");
        say("\r\n");
        if (!act) continue;
        BOOL install_problem = (has_problem && (problem == CM_PROB_NOT_CONFIGURED || problem == CM_PROB_REINSTALL || problem == CM_PROB_FAILED_INSTALL))
                               || (have_flags && (flags & (CONFIGFLAG_REINSTALL | CONFIGFLAG_FAILEDINSTALL)));
        if (install_problem) {
            /* As an unplug: the node goes; the re-enumeration below finds the
             * device again and installs it as new. */
            if (have_flags) {
                DWORD nf = (flags & ~(DWORD)CONFIGFLAG_FAILEDINSTALL) | CONFIGFLAG_REINSTALL;
                SetupDiSetDeviceRegistryPropertyW(set, &dev, SPDRP_CONFIGFLAGS, (BYTE *)&nf, sizeof(nf));
            }
            BOOL ok = SetupDiCallClassInstaller(DIF_REMOVE, set, &dev);
            say("[USBREENUM]   install problem: removed for a fresh install = "); say(ok ? "ok" : "FAILED"); if (!ok) { say(" error="); hex(GetLastError()); } say("\r\n");
            reenumerate = TRUE;
        } else if (has_problem && problem != CM_PROB_DISABLED) {
            BOOL ok = restart(set, &dev);
            say("[USBREENUM]   problem "); num(problem); say(": restart = "); say(ok ? "ok" : "FAILED"); if (!ok) { say(" error="); hex(GetLastError()); } say("\r\n");
            reenumerate = TRUE;
        } else if (!has_problem && prefix(id, L"USBSTOR\\")) {
            BOOL ok = restart(set, &dev);
            say("[USBREENUM]   USBSTOR disk node restart = "); say(ok ? "ok" : "FAILED"); if (!ok) { say(" error="); hex(GetLastError()); } say("\r\n");
        }
    }
    SetupDiDestroyDeviceInfoList(set);
    return reenumerate;
}

#ifndef IOCTL_DISK_GET_DISK_ATTRIBUTES
#define IOCTL_DISK_GET_DISK_ATTRIBUTES CTL_CODE(IOCTL_DISK_BASE, 0x003c, METHOD_BUFFERED, FILE_ANY_ACCESS)
typedef struct { DWORD Version; DWORD Reserved1; DWORDLONG Attributes; } GET_DISK_ATTRIBUTES;
#endif

static BYTE layout[16384];
static void disks(void) {
    for (DWORD n = 0; n < 32; n++) {
        WCHAR name[32] = L"\\\\.\\PhysicalDrive";
        WCHAR d[4]; int k = 0; DWORD v = n; if (v >= 10) d[k++] = (WCHAR)('0' + v / 10); d[k++] = (WCHAR)('0' + v % 10); d[k] = 0;
        lstrcatW(name, d);
        HANDLE h = CreateFileW(name, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, 0, OPEN_EXISTING, 0, 0);
        if (h == INVALID_HANDLE_VALUE) continue;
        STORAGE_PROPERTY_QUERY q; memset(&q, 0, sizeof(q));
        q.PropertyId = StorageDeviceProperty; q.QueryType = PropertyStandardQuery;
        static BYTE desc[1024]; DWORD got = 0;
        memset(desc, 0, sizeof(desc));
        if (DeviceIoControl(h, IOCTL_STORAGE_QUERY_PROPERTY, &q, sizeof(q), desc, sizeof(desc), &got, 0) && got >= sizeof(STORAGE_DEVICE_DESCRIPTOR) - 1) {
            STORAGE_DEVICE_DESCRIPTOR *sd = (STORAGE_DEVICE_DESCRIPTOR *)desc;
            if (sd->BusType == BusTypeUsb) {
                say("[USBREENUM] disk PhysicalDrive"); num(n);
                say(" usb removable="); num(sd->RemovableMedia);
                DWORD lg = 0;
                if (DeviceIoControl(h, IOCTL_DISK_GET_DRIVE_LAYOUT_EX, 0, 0, layout, sizeof(layout), &lg, 0)) {
                    DRIVE_LAYOUT_INFORMATION_EX *l = (DRIVE_LAYOUT_INFORMATION_EX *)layout;
                    DWORD used = 0;
                    for (DWORD p = 0; p < l->PartitionCount; p++) {
                        PARTITION_INFORMATION_EX *pe = &l->PartitionEntry[p];
                        if (pe->PartitionLength.QuadPart && (l->PartitionStyle != PARTITION_STYLE_MBR || pe->Mbr.PartitionType)) used++;
                    }
                    say(" style="); num(l->PartitionStyle); say(" partitions="); num(used);
                } else { say(" layout error="); num(GetLastError()); }
                GET_DISK_ATTRIBUTES a; memset(&a, 0, sizeof(a));
                if (DeviceIoControl(h, IOCTL_DISK_GET_DISK_ATTRIBUTES, 0, 0, &a, sizeof(a), &got, 0)) {
                    say(" offline="); num((ULONG)(a.Attributes & 1)); say(" readonly="); num((ULONG)((a.Attributes >> 1) & 1));
                }
                say("\r\n");
            }
        }
        CloseHandle(h);
    }
    WCHAR drives[256];
    DWORD len = GetLogicalDriveStringsW(255, drives);
    say("[USBREENUM] volumes:");
    for (WCHAR *p = drives; len && len < 255 && *p; ) {
        say(" "); wide(p); say("("); num(GetDriveTypeW(p)); say(")");
        while (*p) p++;
        p++;
    }
    say("\r\n");
}

static void save_to(const WCHAR *file) {
    HANDLE h = CreateFileW(file, FILE_APPEND_DATA, FILE_SHARE_READ, 0, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    if (h == INVALID_HANDLE_VALUE) return;
    DWORD w = 0;
    WriteFile(h, logbuf, loglen, &w, 0);
    FlushFileBuffers(h);
    CloseHandle(h);
}

static void save(void) {
    WCHAR dir[MAX_PATH], file[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"SystemDrive", dir, 8);
    if (!n || n >= 8) lstrcpyW(dir, L"C:");
    lstrcatW(dir, L"\\USOS"); CreateDirectoryW(dir, 0);
    lstrcatW(dir, L"\\Logs"); CreateDirectoryW(dir, 0);
    lstrcpyW(file, dir); lstrcatW(file, L"\\usos-usbreenum.log");
    save_to(file);
    /* The USOS stick: first partition (ESP) with EFI\USOS\Logs, reached by
     * device path (a fixed GPT disk gives the ESP no letter). Only an
     * existing folder is used; nothing is created on the stick. */
    for (DWORD d = 0; d < 32; d++) {
        WCHAR p[MAX_PATH] = L"\\\\?\\GLOBALROOT\\Device\\Harddisk";
        WCHAR t[4]; int k = 0; if (d >= 10) t[k++] = (WCHAR)('0' + d / 10); t[k++] = (WCHAR)('0' + d % 10); t[k] = 0;
        lstrcatW(p, t); lstrcatW(p, L"\\Partition1\\EFI\\USOS\\Logs");
        DWORD a = GetFileAttributesW(p);
        if (a == INVALID_FILE_ATTRIBUTES || !(a & FILE_ATTRIBUTE_DIRECTORY)) continue;
        lstrcatW(p, L"\\usos-usbreenum.log");
        save_to(p);
        break;
    }
}

void entry(void) {
    /* The first argument after the program name (quoted or not). */
    LPWSTR cmd = GetCommandLineW();
    if (*cmd == '"') { cmd++; while (*cmd && *cmd != '"') cmd++; if (*cmd) cmd++; }
    else while (*cmd && *cmd != ' ' && *cmd != '	') cmd++;
    while (*cmd == ' ' || *cmd == '	') cmd++;
    BOOL report = prefix(cmd, L"report");
    SYSTEMTIME st; GetLocalTime(&st);
    say("[USBREENUM] start "); num(st.wYear); say("-"); num(st.wMonth); say("-"); num(st.wDay); say(" "); num(st.wHour); say(":"); num(st.wMinute);
    say(report ? " mode=report\r\n" : " mode=fix\r\n");
    wait_installs("before");
    disks();
    BOOL again = nodes(!report);
    if (!report) {
        DEVINST root;
        if (CM_Locate_DevNodeW(&root, 0, CM_LOCATE_DEVNODE_NORMAL) == CR_SUCCESS) {
            CONFIGRET r = CM_Reenumerate_DevNode(root, CM_REENUMERATE_SYNCHRONOUS | CM_REENUMERATE_RETRY_INSTALLATION);
            say("[USBREENUM] re-enumerate the device tree (retry installation): cr="); num(r); say(again ? " (after changes)\r\n" : "\r\n");
        }
        wait_installs("after");
        Sleep(3000);
        say("[USBREENUM] state after:\r\n");
        nodes(FALSE);
        disks();
    }
    say("[USBREENUM] done\r\n");
    if (!report) save();
    ExitProcess(0);
}
