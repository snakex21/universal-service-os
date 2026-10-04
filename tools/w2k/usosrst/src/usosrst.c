/*
 * usosrst.sys - USOS helper driver for Windows 2000 on boards without a
 * keyboard controller (diagnostic build).
 *
 * Universal Service OS (USOS)
 * Copyright (C) 2026 Maksymilian and the USOS Authors (see NOTICE)
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Own implementation, written for USOS (no third-party code). It does two
 * things:
 *
 * 1. STOP screen. Windows 2000 draws its STOP screen through bootvid; on the
 *    X470 without CSM (CSMWrap) only a black text screen with a blinking
 *    cursor is left. A bugcheck callback writes the STOP code, the four
 *    parameters and the modules the parameters point into straight into the
 *    VGA text buffer (B8000h), rows 3 to 6. AHCINT usos3 uses rows 0 and 1,
 *    this driver's load line is row 2.
 *
 * 2. Reset. The 2000 HALs restart through the 8042 keyboard controller,
 *    which these boards no longer have, so a restart hangs. While Setup
 *    runs (HKLM\SYSTEM\Setup SystemSetupInProgress = 1, every shutdown of
 *    GUI-mode Setup is a restart) a last-chance shutdown handler resets the
 *    machine itself: the FADT reset register when the firmware declares one
 *    (ACPI 2.0+, RESET_REG_SUP), then port CF9h (02h, 06h, then 0Eh), then
 *    the 8042 (FEh to port 64h). After Setup the handler is not registered,
 *    so a shutdown stays a power-off. Text-mode Setup restarts through
 *    HalReturnToFirmware directly, without shutdown notifications; that
 *    restart is not covered (it would need a change to Microsoft's HAL).
 */
#include <ntddk.h>

/* Exported by every NT kernel since 3.1; ntddk.h does not declare it. */
__declspec(dllimport) extern ULONG KiBugCheckData[5];

#define USOSRST_VERSION "usosrst 1.0-diag"
#define ROW_LOAD        2
#define ROW_STOP        3

static PUSHORT g_Vga;
static KBUGCHECK_CALLBACK_RECORD g_BugCheckRecord;
static UCHAR g_Component[] = "USOSRST";
static PVOID g_OwnEntry;            /* our LDR_DATA_TABLE_ENTRY */
static BOOLEAN g_InSetup;
static ULONG g_ResetSpace;          /* 0 none, 1 system I/O, 2 memory */
static ULONG g_ResetAddress;
static UCHAR g_ResetValue;
static PUCHAR g_ResetMapped;
static ULONG g_AcpiRevision = 0xFF;    /* RSDP revision, FFh = no RSDP found */

/* ------------------------------------------------------------------ */
/* Text buffer                                                         */
/* ------------------------------------------------------------------ */

static PCHAR
PutStr(PCHAR p, PCHAR end, const char *s)
{
    while (*s && p < end) *p++ = *s++;
    return p;
}

static PCHAR
PutHex(PCHAR p, PCHAR end, ULONG v, ULONG digits)
{
    static const char hex[] = "0123456789ABCDEF";
    LONG shift;
    for (shift = (LONG)(digits * 4) - 4; shift >= 0 && p < end; shift -= 4) *p++ = hex[(v >> shift) & 0xF];
    return p;
}

static VOID
ShowRow(ULONG Row, PCHAR Text, ULONG Length, USHORT Attr)
{
    ULONG i;
    PUSHORT row;

    if (g_Vga == NULL) return;
    row = g_Vga + Row * 80;
    for (i = 0; i < 80; i++) row[i] = (USHORT)(Attr | (UCHAR)(i < Length ? Text[i] : ' '));
}

/* ------------------------------------------------------------------ */
/* STOP screen                                                         */
/* ------------------------------------------------------------------ */

/* x86 LDR_DATA_TABLE_ENTRY offsets (stable from NT 4.0 to 2003) */
#define LDR_DLLBASE         24
#define LDR_SIZEOFIMAGE     32
#define LDR_BASENAME        44

/* Name and offset of the loaded module that contains Address, walking the
   loaded-module list from our own entry (PsLoadedModuleList is not
   exported on 2000). Every pointer is checked before it is read. */
static PCHAR
PutModule(PCHAR p, PCHAR end, ULONG Address)
{
    PLIST_ENTRY entry;
    ULONG n;

    if (g_OwnEntry == NULL || Address < 0x80000000) return p;
    entry = (PLIST_ENTRY)g_OwnEntry;
    for (n = 0; n < 1024; n++) {
        PUCHAR e = (PUCHAR)entry;
        if (!MmIsAddressValid(e) || !MmIsAddressValid(e + LDR_BASENAME + 7)) return p;
        {
            ULONG base = *(PULONG)(e + LDR_DLLBASE);
            ULONG size = *(PULONG)(e + LDR_SIZEOFIMAGE);
            USHORT len = *(PUSHORT)(e + LDR_BASENAME);
            PWCHAR name = *(PWCHAR *)(e + LDR_BASENAME + 4);
            if (base >= 0x80000000 && size != 0 && size < 0x10000000 &&
                Address >= base && Address - base < size &&
                len != 0 && len < 128 && MmIsAddressValid(name) && MmIsAddressValid((PUCHAR)name + len - 1)) {
                ULONG i;
                p = PutStr(p, end, " ");
                for (i = 0; i < (ULONG)(len / 2) && p < end; i++) *p++ = (CHAR)(name[i] < 0x80 ? name[i] : '?');
                p = PutStr(p, end, "+");
                return PutHex(p, end, Address - base, 5);
            }
        }
        entry = entry->Flink;
        if (entry == (PLIST_ENTRY)g_OwnEntry) return p;
    }
    return p;
}

static VOID
BugCheckCallback(IN PVOID Buffer, IN ULONG Length)
{
    CHAR line[80];
    PCHAR p, end = line + 80;
    ULONG i;

    UNREFERENCED_PARAMETER(Buffer);
    UNREFERENCED_PARAMETER(Length);

    p = PutStr(line, end, "USOS: STOP 0x");
    p = PutHex(p, end, KiBugCheckData[0], 8);
    p = PutStr(p, end, " (");
    for (i = 1; i <= 4; i++) {
        p = PutStr(p, end, "0x");
        p = PutHex(p, end, KiBugCheckData[i], 8);
        p = PutStr(p, end, i < 4 ? "," : ")");
    }
    ShowRow(ROW_STOP, line, (ULONG)(p - line), 0x4F00);

    p = PutStr(line, end, "USOS: in");
    for (i = 1; i <= 4; i++) p = PutModule(p, end, KiBugCheckData[i]);
    ShowRow(ROW_STOP + 1, line, (ULONG)(p - line), 0x4F00);

    p = PutStr(line, end, "USOS: photograph this screen (rows 0-5) for the USOS issue report.");
    ShowRow(ROW_STOP + 2, line, (ULONG)(p - line), 0x4F00);
}

/* ------------------------------------------------------------------ */
/* ACPI: the FADT reset register                                       */
/* ------------------------------------------------------------------ */

static PUCHAR
MapPhys(ULONG Address, ULONG Length)
{
    PHYSICAL_ADDRESS pa;
    pa.QuadPart = Address;
    return (PUCHAR)MmMapIoSpace(pa, Length, MmCached);
}

static BOOLEAN
Checksum(PUCHAR p, ULONG Length)
{
    UCHAR sum = 0;
    ULONG i;
    for (i = 0; i < Length; i++) sum = (UCHAR)(sum + p[i]);
    return (BOOLEAN)(sum == 0);
}

static ULONG
FindRsdpIn(ULONG Base, ULONG Length)
{
    PUCHAR m = MapPhys(Base, Length);
    ULONG off, found = 0;

    if (m == NULL) return 0;
    for (off = 0; off + 20 <= Length; off += 16) {
        if (m[off] == 'R' && m[off + 1] == 'S' && m[off + 2] == 'D' && m[off + 3] == ' ' &&
            m[off + 4] == 'P' && m[off + 5] == 'T' && m[off + 6] == 'R' && m[off + 7] == ' ' &&
            Checksum(m + off, 20)) {
            found = Base + off;
            break;
        }
    }
    MmUnmapIoSpace(m, Length);
    return found;
}

/* The FADT behind the RSDT (32-bit entries) or XSDT (64-bit entries, only
   those below 4 GB). */
static VOID
FindResetRegister(VOID)
{
    PUCHAR bda, rsdp, sdt, hdr, fadt;
    ULONG rsdpAddr = 0, ebda, sdtAddr, sdtLen, entrySize, i, fadtAddr = 0;

    bda = MapPhys(0x400, 0x100);
    if (bda != NULL) {
        ebda = (ULONG)(*(PUSHORT)(bda + 0x0E)) << 4;
        MmUnmapIoSpace(bda, 0x100);
        if (ebda >= 0x80000 && ebda < 0xA0000) rsdpAddr = FindRsdpIn(ebda, 0x400);
    }
    if (rsdpAddr == 0) rsdpAddr = FindRsdpIn(0xE0000, 0x20000);
    if (rsdpAddr == 0) return;

    rsdp = MapPhys(rsdpAddr, 36);
    if (rsdp == NULL) return;
    g_AcpiRevision = rsdp[15];
    if (rsdp[15] >= 2 && *(PULONG)(rsdp + 24) != 0 && *(PULONG)(rsdp + 28) == 0) {
        sdtAddr = *(PULONG)(rsdp + 24);
        entrySize = 8;
    } else {
        sdtAddr = *(PULONG)(rsdp + 16);
        entrySize = 4;
    }
    MmUnmapIoSpace(rsdp, 36);
    if (sdtAddr == 0) return;

    hdr = MapPhys(sdtAddr, 36);
    if (hdr == NULL) return;
    sdtLen = *(PULONG)(hdr + 4);
    MmUnmapIoSpace(hdr, 36);
    if (sdtLen < 36 || sdtLen > 0x10000) return;
    sdt = MapPhys(sdtAddr, sdtLen);
    if (sdt == NULL) return;
    for (i = 36; i + entrySize <= sdtLen; i += entrySize) {
        ULONG addr = *(PULONG)(sdt + i);
        if (entrySize == 8 && *(PULONG)(sdt + i + 4) != 0) continue;
        hdr = MapPhys(addr, 36);
        if (hdr == NULL) continue;
        if (hdr[0] == 'F' && hdr[1] == 'A' && hdr[2] == 'C' && hdr[3] == 'P') fadtAddr = addr;
        MmUnmapIoSpace(hdr, 36);
        if (fadtAddr) break;
    }
    MmUnmapIoSpace(sdt, sdtLen);
    if (fadtAddr == 0) return;

    fadt = MapPhys(fadtAddr, 129);
    if (fadt == NULL) return;
    /* ACPI 2.0+: Flags at 112 (bit 10 RESET_REG_SUP), RESET_REG (GAS) at
       116, RESET_VALUE at 128 */
    if (*(PULONG)(fadt + 4) >= 129 && (*(PULONG)(fadt + 112) & (1UL << 10)) &&
        *(PULONG)(fadt + 124) == 0 && *(PULONG)(fadt + 120) != 0) {
        g_ResetAddress = *(PULONG)(fadt + 120);
        g_ResetValue = fadt[128];
        if (fadt[116] == 1 && g_ResetAddress < 0x10000) {
            g_ResetSpace = 1;
        } else if (fadt[116] == 0) {
            g_ResetMapped = (PUCHAR)MmMapIoSpace(*(PPHYSICAL_ADDRESS)(fadt + 120), 1, MmNonCached);
            if (g_ResetMapped != NULL) g_ResetSpace = 2;
        }
    }
    MmUnmapIoSpace(fadt, 129);
}

/* ------------------------------------------------------------------ */
/* Reset                                                               */
/* ------------------------------------------------------------------ */

static VOID
StallMs(ULONG Ms)
{
    while (Ms--) KeStallExecutionProcessor(1000);
}

static NTSTATUS
ShutdownDispatch(IN PDEVICE_OBJECT DeviceObject, IN PIRP Irp)
{
    ULONG i;

    UNREFERENCED_PARAMETER(DeviceObject);

    /* Every disk has been flushed (last-chance handlers run after the file
       systems). */
    if (g_ResetSpace == 1) {
        WRITE_PORT_UCHAR((PUCHAR)g_ResetAddress, g_ResetValue);
        StallMs(500);
    } else if (g_ResetSpace == 2) {
        WRITE_REGISTER_UCHAR(g_ResetMapped, g_ResetValue);
        StallMs(500);
    }
    WRITE_PORT_UCHAR((PUCHAR)0xCF9, 0x02);
    KeStallExecutionProcessor(50);
    WRITE_PORT_UCHAR((PUCHAR)0xCF9, 0x06);
    StallMs(500);
    WRITE_PORT_UCHAR((PUCHAR)0xCF9, 0x0E);
    StallMs(500);
    for (i = 0; i < 100 && (READ_PORT_UCHAR((PUCHAR)0x64) & 0x02); i++) KeStallExecutionProcessor(1000);
    WRITE_PORT_UCHAR((PUCHAR)0x64, 0xFE);
    StallMs(500);

    /* Still here: let Windows try its own way. */
    Irp->IoStatus.Status = STATUS_SUCCESS;
    Irp->IoStatus.Information = 0;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return STATUS_SUCCESS;
}

static BOOLEAN
SetupInProgress(VOID)
{
    UNICODE_STRING keyName, valueName;
    OBJECT_ATTRIBUTES oa;
    HANDLE key;
    UCHAR buffer[sizeof(KEY_VALUE_PARTIAL_INFORMATION) + sizeof(ULONG)];
    PKEY_VALUE_PARTIAL_INFORMATION info = (PKEY_VALUE_PARTIAL_INFORMATION)buffer;
    ULONG length;
    BOOLEAN result = FALSE;

    RtlInitUnicodeString(&keyName, L"\\Registry\\Machine\\SYSTEM\\Setup");
    RtlInitUnicodeString(&valueName, L"SystemSetupInProgress");
    InitializeObjectAttributes(&oa, &keyName, OBJ_CASE_INSENSITIVE, NULL, NULL);
    if (!NT_SUCCESS(ZwOpenKey(&key, KEY_READ, &oa))) return FALSE;
    if (NT_SUCCESS(ZwQueryValueKey(key, &valueName, KeyValuePartialInformation, info, sizeof(buffer), &length)) &&
        info->Type == REG_DWORD && info->DataLength == sizeof(ULONG) && *(PULONG)info->Data == 1) {
        result = TRUE;
    }
    ZwClose(key);
    return result;
}

/* ------------------------------------------------------------------ */
/* DriverEntry                                                         */
/* ------------------------------------------------------------------ */

NTSTATUS
DriverEntry(IN PDRIVER_OBJECT DriverObject, IN PUNICODE_STRING RegistryPath)
{
    PHYSICAL_ADDRESS vga;
    PDEVICE_OBJECT device = NULL;
    BOOLEAN shutdownHandler = FALSE;
    CHAR line[80];
    PCHAR p, end = line + 80;

    UNREFERENCED_PARAMETER(RegistryPath);

    g_OwnEntry = DriverObject->DriverSection;
    vga.QuadPart = 0xB8000;
    g_Vga = (PUSHORT)MmMapIoSpace(vga, 80 * 50 * 2, MmNonCached);
    KeInitializeCallbackRecord(&g_BugCheckRecord);
    KeRegisterBugCheckCallback(&g_BugCheckRecord, BugCheckCallback, NULL, 0, g_Component);

    g_InSetup = SetupInProgress();
    FindResetRegister();
    if (g_InSetup && NT_SUCCESS(IoCreateDevice(DriverObject, 0, NULL, FILE_DEVICE_UNKNOWN, 0, FALSE, &device))) {
        DriverObject->MajorFunction[IRP_MJ_SHUTDOWN] = ShutdownDispatch;
        if (NT_SUCCESS(IoRegisterLastChanceShutdownNotification(device))) {
            shutdownHandler = TRUE;
        } else {
            IoDeleteDevice(device);
        }
    }

    /* The load line: shows that the driver ran and what it found. */
    p = PutStr(line, end, USOSRST_VERSION " rsdp-rev=");
    p = PutHex(p, end, g_AcpiRevision, 2);
    p = PutStr(p, end, g_ResetSpace == 1 ? " reset=io:" : g_ResetSpace == 2 ? " reset=mem:" : " reset=cf9");
    if (g_ResetSpace) {
        p = PutHex(p, end, g_ResetAddress, g_ResetSpace == 1 ? 4 : 8);
        p = PutStr(p, end, "=");
        p = PutHex(p, end, g_ResetValue, 2);
        p = PutStr(p, end, "+cf9");
    }
    p = PutStr(p, end, "+8042 setup=");
    p = PutStr(p, end, g_InSetup ? "1" : "0");
    p = PutStr(p, end, shutdownHandler ? " handler=on" : " handler=off");
    ShowRow(ROW_LOAD, line, (ULONG)(p - line), 0x1F00);

    return STATUS_SUCCESS;
}
