/* mpcheck - guest-side check for the usosmpart QEMU test (Windows 2000+).
 *
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 *   mpcheck            list disks (bus, removable, hotplug info, partition
 *                      count) and volumes C:..Z: (type, label, disk/partition
 *                      number); also appended to C:\mpcheck.log
 *   mpcheck w D        write D:\mpw.bin (1 MiB pattern), flush, read back
 *   mpcheck r D        read D:\mpw.bin back and compare
 *
 * Test-only tool (tools/tests/run_usosmpart_qemu.py); no CRT.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winioctl.h>

#ifndef IOCTL_STORAGE_GET_HOTPLUG_INFO
#define IOCTL_STORAGE_GET_HOTPLUG_INFO CTL_CODE(IOCTL_STORAGE_BASE, 0x0305, METHOD_BUFFERED, FILE_ANY_ACCESS)
#endif

void *memset(void *p, int v, size_t n) { volatile BYTE *b = p; while (n--) *b++ = (BYTE)v; return p; }

static HANDLE out, logf;
static void put(const char *s)
{
    DWORD n;
    WriteFile(out, s, lstrlenA(s), &n, 0);
    if (logf != INVALID_HANDLE_VALUE) WriteFile(logf, s, lstrlenA(s), &n, 0);
}
static void putf(const char *fmt, ...)
{
    char b[512];
    va_list a;
    va_start(a, fmt);
    wvsprintfA(b, fmt, a);
    va_end(a);
    put(b);
}

typedef struct { ULONG DeviceType, Characteristics; } FSDEV;
typedef struct { LONG Status; ULONG_PTR Information; } IOSB;
__declspec(dllimport) LONG __stdcall NtQueryVolumeInformationFile(HANDLE, IOSB *, PVOID, ULONG, ULONG);
/* FILE_REMOVABLE_MEDIA = 1 (FileFsDeviceInformation = 4) */
static ULONG devchar(HANDLE h)
{
    FSDEV fs; IOSB io;
    fs.Characteristics = 0xFFFFFFFF;
    NtQueryVolumeInformationFile(h, &io, &fs, sizeof(fs), 4);
    return fs.Characteristics;
}

typedef struct { DWORD Size; BOOLEAN MediaRemovable, MediaHotplug, DeviceHotplug, WriteCacheEnableOverride; } HOTPLUG;

static void disks(void)
{
    int i;
    for (i = 0; i < 16; i++) {
        char name[32];
        HANDLE h;
        static BYTE buf[4096];
        DWORD n = 0;
        STORAGE_PROPERTY_QUERY q;
        wsprintfA(name, "\\\\.\\PhysicalDrive%d", i);
        h = CreateFileA(name, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, 0, OPEN_EXISTING, 0, 0);
        if (h == INVALID_HANDLE_VALUE) continue;
        putf("disk%d:", i);
        memset(&q, 0, sizeof(q));
        q.PropertyId = StorageDeviceProperty;
        q.QueryType = PropertyStandardQuery;
        memset(buf, 0, sizeof(buf));
        if (DeviceIoControl(h, IOCTL_STORAGE_QUERY_PROPERTY, &q, sizeof(q), buf, sizeof(buf), &n, 0)) {
            STORAGE_DEVICE_DESCRIPTOR *d = (STORAGE_DEVICE_DESCRIPTOR *)buf;
            putf(" bus=%d rmb=%d", (int)d->BusType, (int)d->RemovableMedia);
        } else putf(" query-property-error=%lu", GetLastError());
        {
            HOTPLUG hp;
            memset(&hp, 0, sizeof(hp));
            if (DeviceIoControl(h, IOCTL_STORAGE_GET_HOTPLUG_INFO, 0, 0, &hp, sizeof(hp), &n, 0))
                putf(" hp(mrem=%d mhot=%d DEVHOT=%d wco=%d)",
                     hp.MediaRemovable, hp.MediaHotplug, hp.DeviceHotplug, hp.WriteCacheEnableOverride);
            else putf(" hotplug-error=%lu", GetLastError());
        }
        {
            DISK_GEOMETRY g;
            if (DeviceIoControl(h, IOCTL_DISK_GET_DRIVE_GEOMETRY, 0, 0, &g, sizeof(g), &n, 0))
                putf(" media=%d", (int)g.MediaType);
        }
        {
            ULONG ch = devchar(h);
            putf(" chr=%lx", ch);
        }
        memset(buf, 0, sizeof(buf));
        if (DeviceIoControl(h, IOCTL_DISK_GET_DRIVE_LAYOUT, 0, 0, buf, sizeof(buf), &n, 0)) {
            DRIVE_LAYOUT_INFORMATION *l = (DRIVE_LAYOUT_INFORMATION *)buf;
            DWORD k, used = 0;
            for (k = 0; k < l->PartitionCount; k++) if (l->PartitionEntry[k].PartitionType) used++;
            putf(" parts=%lu/%lu", used, l->PartitionCount);
        } else putf(" layout-err=%lu", GetLastError());
        put("\r\n");
        CloseHandle(h);
    }
}

static void volumes(void)
{
    char d;
    for (d = 'C'; d <= 'Z'; d++) {
        char root[4] = { d, ':', '\\', 0 }, dev[8] = { '\\', '\\', '.', '\\', d, ':', 0 };
        char label[64], fs[16];
        UINT t = GetDriveTypeA(root);
        HANDLE h;
        if (t == DRIVE_NO_ROOT_DIR || t == DRIVE_UNKNOWN) continue;
        label[0] = fs[0] = 0;
        GetVolumeInformationA(root, label, sizeof(label), 0, 0, 0, fs, sizeof(fs));
        putf("%c: type=%u %s %s", d, t, label, fs);
        h = CreateFileA(dev, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, 0, OPEN_EXISTING, 0, 0);
        if (h != INVALID_HANDLE_VALUE) {
            STORAGE_DEVICE_NUMBER sn;
            DWORD n;
            if (DeviceIoControl(h, IOCTL_STORAGE_GET_DEVICE_NUMBER, 0, 0, &sn, sizeof(sn), &n, 0))
                putf(" disk=%lu part=%lu", sn.DeviceNumber, sn.PartitionNumber);
            putf(" chr=%lx", devchar(h));
            CloseHandle(h);
        }
        put("\r\n");
    }
}

static BYTE pattern(DWORD i, char d) { return (BYTE)(i * 7 + (i >> 9) + d); }

static int rw(char d, int write)
{
    char path[] = "X:\\mpw.bin";
    static BYTE buf[65536];
    HANDLE h;
    DWORD i, n, chunk, bad = 0;
    path[0] = d;
    h = CreateFileA(path, write ? GENERIC_WRITE : GENERIC_READ, 0, 0, write ? CREATE_ALWAYS : OPEN_EXISTING, 0, 0);
    if (h == INVALID_HANDLE_VALUE) { putf("%c: open error %lu\r\n", d, GetLastError()); return 1; }
    for (chunk = 0; chunk < 16; chunk++) {
        if (write) {
            for (i = 0; i < sizeof(buf); i++) buf[i] = pattern(chunk * sizeof(buf) + i, d);
            if (!WriteFile(h, buf, sizeof(buf), &n, 0) || n != sizeof(buf)) { bad = 1; break; }
        } else {
            if (!ReadFile(h, buf, sizeof(buf), &n, 0) || n != sizeof(buf)) { bad = 1; break; }
            for (i = 0; i < sizeof(buf); i++) if (buf[i] != pattern(chunk * sizeof(buf) + i, d)) { bad = 1; break; }
        }
    }
    if (write && !FlushFileBuffers(h)) bad = 1;
    CloseHandle(h);
    if (write && !bad) return rw(d, 0);
    putf("%c: %s 1 MiB %s\r\n", d, write ? "write+verify" : "verify", bad ? "FAIL" : "OK");
    return bad;
}

void entry(void)
{
    char *cmd = GetCommandLineA(), *p;
    int rc = 0;
    out = GetStdHandle(STD_OUTPUT_HANDLE);
    logf = CreateFileA("C:\\mpcheck.log", FILE_APPEND_DATA, FILE_SHARE_READ, 0, OPEN_ALWAYS, 0, 0);
    if (logf != INVALID_HANDLE_VALUE) SetFilePointer(logf, 0, 0, FILE_END);
    /* skip the program name */
    p = cmd;
    if (*p == '"') { p++; while (*p && *p != '"') p++; if (*p) p++; }
    else while (*p && *p != ' ') p++;
    while (*p == ' ') p++;
    if ((p[0] == 'w' || p[0] == 'r') && p[1] == ' ') {
        char *d = p + 2;
        while (*d) {
            if (*d >= 'A' && *d <= 'Z') rc |= rw(*d, p[0] == 'w');
            else if (*d >= 'a' && *d <= 'z') rc |= rw((char)(*d - 32), p[0] == 'w');
            d++;
        }
    } else {
        put("== mpcheck ==\r\n");
        disks();
        volumes();
    }
    if (logf != INVALID_HANDLE_VALUE) CloseHandle(logf);
    ExitProcess(rc);
}
