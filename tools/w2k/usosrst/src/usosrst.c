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
 *    VGA text buffer (B8000h), rows 5 to 7 (see the row list below).
 *
 * 2. Reset. The 2000 HALs restart through the 8042 keyboard controller,
 *    which these boards no longer have, so a restart hangs. While Setup
 *    runs (HKLM\SYSTEM\Setup SystemSetupInProgress = 1, every shutdown of
 *    GUI-mode Setup is a restart) a last-chance shutdown handler resets the
 *    machine itself: the FADT reset register when the firmware declares one
 *    (ACPI 2.0+, RESET_REG_SUP), then port CF9h (02h, 06h, then 0Eh), then
 *    the 8042 (FEh to port 64h). After Setup the handler is not registered,
 *    so a shutdown stays a power-off.
 *
 * 3. Text-mode restart. Text-mode Setup (setupdd.sys) restarts by calling
 *    HalReturnToFirmware(HalRebootRoutine) directly, without shutdown
 *    notifications, and the HAL then only pulses the 8042. When setupdd.sys
 *    is loaded (text mode only), this driver points setupdd.sys's import
 *    slot for HalReturnToFirmware, in memory, at its own routine: a reboot
 *    or restart request runs the same reset sequence as above; anything
 *    else (and a reset that did not happen) goes on to the HAL's routine.
 *    No Microsoft file is changed: only the import address in the running
 *    image is redirected, in the slot the loader itself filled in.
 *
 * 4. Heartbeat and AHCI stall watchdog (1.2, text-mode Setup only). A
 *    250 ms periodic kernel timer rewrites row 1: a tick counter, the
 *    seconds since boot (interrupt time), one hex digit per CPU that only
 *    moves when that CPU runs a DPC, and the live state of the most
 *    recently active AHCI port (PxCI, the last command from its command
 *    list, seconds since that command changed). The AHCI HBAs are found
 *    in PCI config space and their registers are only read (no driver
 *    state is touched), so this works whichever miniport serves the disk.
 *    A command slot that stays set for 2 s with the same command puts the
 *    port registers on rows 3-4. A moving row 1 with frozen AHCINT
 *    counters = an I/O stall; a frozen row 1 = the timer/DPC path (or the
 *    whole machine) is stuck.
 *
 * Screen rows: 0 AHCINT, 1 heartbeat, 2 load line, 3-4 stall snapshot,
 * 5-7 STOP, 8 a second AHCINT HBA.
 */
#include <ntddk.h>

/* Exported by every NT kernel since 3.1; ntddk.h does not declare it. */
__declspec(dllimport) extern ULONG KiBugCheckData[5];

/* Exported by every NT HAL (stdcall, one argument); the WDK 7.1 headers no
   longer declare it. Routine values as in the NT 4.0-2003 DDKs
   (FIRMWARE_REENTRY). */
#define USOS_HAL_RESTART_ROUTINE  2
#define USOS_HAL_REBOOT_ROUTINE   3
__declspec(dllimport) VOID NTAPI HalReturnToFirmware(IN ULONG Routine);

#define USOSRST_VERSION "usosrst 1.2"
#define ROW_HB          1
#define ROW_LOAD        2
#define ROW_STALL       3
#define ROW_STOP        5

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

typedef VOID (NTAPI *USOS_RETURN_TO_FIRMWARE)(IN ULONG Routine);
static USOS_RETURN_TO_FIRMWARE g_HalReturnToFirmware;  /* the HAL's routine */

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

    p = PutStr(line, end, "USOS: photograph this screen (rows 0-8) for the USOS issue report.");
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

/* FADT reset register, CF9h, 8042. Returns only if none of them reset the
   machine. */
static VOID
ResetMachine(VOID)
{
    ULONG i;

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
}

static NTSTATUS
ShutdownDispatch(IN PDEVICE_OBJECT DeviceObject, IN PIRP Irp)
{
    UNREFERENCED_PARAMETER(DeviceObject);

    /* Every disk has been flushed (last-chance handlers run after the file
       systems). */
    ResetMachine();

    /* Still here: let Windows try its own way. */
    Irp->IoStatus.Status = STATUS_SUCCESS;
    Irp->IoStatus.Information = 0;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return STATUS_SUCCESS;
}

/* ------------------------------------------------------------------ */
/* Text-mode Setup restart                                             */
/* ------------------------------------------------------------------ */

/* setupdd.sys calls this instead of the HAL's HalReturnToFirmware (see
   RedirectSetupRestart). */
static VOID NTAPI
SetupReturnToFirmware(IN ULONG Routine)
{
    static CHAR text[] = "usosrst: text-mode Setup restart (FADT reset register, CF9h, 8042)";

    if (Routine == USOS_HAL_REBOOT_ROUTINE || Routine == USOS_HAL_RESTART_ROUTINE) {
        ShowRow(ROW_STOP, text, sizeof(text) - 1, 0x1F00);
        /* A pause before the reset, as the HAL has before its 8042 pulse,
           for writes the disk is still completing. */
        StallMs(1000);
        ResetMachine();
    }
    g_HalReturnToFirmware(Routine);
}

/* Case-insensitive compare of a counted UTF-16 module name with ASCII. */
static BOOLEAN
NameIs(PWCHAR Name, USHORT Bytes, const char *Want)
{
    ULONG i, n = Bytes / 2;

    for (i = 0; i < n; i++) {
        WCHAR c = Name[i];
        CHAR w = Want[i];
        if (w == 0) return FALSE;
        if (c >= 'A' && c <= 'Z') c = (WCHAR)(c + 32);
        if (w >= 'A' && w <= 'Z') w = (CHAR)(w + 32);
        if (c != (WCHAR)(UCHAR)w) return FALSE;
    }
    return (BOOLEAN)(Want[n] == 0);
}

/* The image base of a loaded module, walking the loaded-module list from our
   own entry; NULL if it is not loaded. */
static PUCHAR
FindModule(const char *Name)
{
    PLIST_ENTRY entry;
    ULONG n;

    if (g_OwnEntry == NULL) return NULL;
    entry = (PLIST_ENTRY)g_OwnEntry;
    for (n = 0; n < 1024; n++) {
        PUCHAR e = (PUCHAR)entry;
        if (!MmIsAddressValid(e) || !MmIsAddressValid(e + LDR_BASENAME + 7)) return NULL;
        {
            ULONG base = *(PULONG)(e + LDR_DLLBASE);
            USHORT len = *(PUSHORT)(e + LDR_BASENAME);
            PWCHAR name = *(PWCHAR *)(e + LDR_BASENAME + 4);
            if (base >= 0x80000000 && len != 0 && len < 128 && MmIsAddressValid(name) &&
                MmIsAddressValid((PUCHAR)name + len - 1) && NameIs(name, len, Name)) {
                return (PUCHAR)base;
            }
        }
        entry = entry->Flink;
        if (entry == (PLIST_ENTRY)g_OwnEntry) return NULL;
    }
    return NULL;
}

/* Writes one import slot through a second, writable mapping of its page
   (the image section may be mapped read-only). */
static BOOLEAN
WriteSlot(PULONG Slot, ULONG Value)
{
    PMDL mdl;
    PULONG writable;

    mdl = IoAllocateMdl(Slot, sizeof(ULONG), FALSE, FALSE, NULL);
    if (mdl == NULL) return FALSE;
    MmBuildMdlForNonPagedPool(mdl);
    writable = (PULONG)MmMapLockedPages(mdl, KernelMode);
    if (writable == NULL) {
        IoFreeMdl(mdl);
        return FALSE;
    }
    InterlockedExchange((PLONG)writable, (LONG)Value);
    MmUnmapLockedPages(writable, mdl);
    IoFreeMdl(mdl);
    return (BOOLEAN)(*Slot == Value);
}

/* 'o': redirected; '-': no setupdd.sys (not text mode); 'x': setupdd.sys
   without a matching import slot, or the write failed. Every import address
   table of setupdd.sys is searched for the HAL's HalReturnToFirmware
   address (the value our own import of it holds), so no import names or
   hint tables are needed. */
static CHAR
RedirectSetupRestart(VOID)
{
    PUCHAR base, nt;
    ULONG target = (ULONG)HalReturnToFirmware;
    ULONG size, rva, dir, dirSize, i, found = 0;

    base = FindModule("setupdd.sys");
    if (base == NULL) return '-';
    if (!MmIsAddressValid(base + 0x3C)) return 'x';
    nt = base + *(PULONG)(base + 0x3C);
    if (!MmIsAddressValid(nt) || !MmIsAddressValid(nt + 0x87) || *(PULONG)nt != 0x00004550) return 'x';
    size = *(PULONG)(nt + 0x50);                  /* SizeOfImage */
    dir = *(PULONG)(nt + 0x80);                   /* import directory */
    dirSize = *(PULONG)(nt + 0x84);
    if (dir == 0 || dirSize < 20 || dir >= size || dirSize > size - dir) return 'x';
    for (i = 0; i + 20 <= dirSize; i += 20) {
        PUCHAR desc = base + dir + i;
        PULONG slot;
        if (!MmIsAddressValid(desc) || !MmIsAddressValid(desc + 19)) break;
        rva = *(PULONG)(desc + 16);               /* FirstThunk */
        if (rva == 0 && *(PULONG)(desc + 12) == 0) break;
        if (rva == 0 || rva >= size) continue;
        for (slot = (PULONG)(base + rva); (PUCHAR)slot + 4 <= base + size && MmIsAddressValid(slot) && *slot != 0; slot++) {
            if (*slot != target) continue;
            g_HalReturnToFirmware = (USOS_RETURN_TO_FIRMWARE)target;
            if (!WriteSlot(slot, (ULONG)SetupReturnToFirmware)) return 'x';
            found++;
        }
    }
    return (CHAR)(found ? 'o' : 'x');
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
/* Heartbeat and AHCI stall watchdog (text-mode Setup only)            */
/* ------------------------------------------------------------------ */

#define HB_PERIOD_MS        250
#define HB_STALL_TICKS      8           /* 2 s */
#define HB_MAX_HBAS         4
#define HB_MAX_WATCH        16
#define HB_MAX_CPUS         8
#define HB_ABAR_MAP         0x1100      /* generic registers + 32 ports */
#define HB_CLB_MAP          0x400       /* 32 command headers */
#define HB_CT_MAP           0x50        /* command FIS + ATAPI command */

#define AHCI_GHC            0x04
#define AHCI_IS             0x08
#define AHCI_PI             0x0C
#define AHCI_GHC_IE         0x02
#define PX_CLB              0x00
#define PX_CLBU             0x04
#define PX_IS               0x10
#define PX_IE               0x14
#define PX_CMD              0x18
#define PX_TFD              0x20
#define PX_SSTS             0x28
#define PX_SERR             0x30
#define PX_SACT             0x34
#define PX_CI               0x38

typedef struct _HB_WATCH {
    PUCHAR  Abar;
    PUCHAR  Regs;               /* port registers */
    CHAR    Name[2];            /* HBA letter, port digit */
    ULONG   ClbLow, ClbHigh;
    PUCHAR  Clb;
    ULONG   CtLow, CtHigh;
    PUCHAR  Ct;
    ULONG   Op, Lba, Count;     /* the command in the slot read last */
    BOOLEAN Valid;
    ULONG   Changed;            /* tick the command last changed */
    ULONG   BusySince;          /* tick a busy slot was first seen, 0 idle */
    ULONG   BusyOp, BusyLba, BusyCount;
    BOOLEAN Reported;
} HB_WATCH, *PHB_WATCH;

static KTIMER g_HbTimer;
static KDPC g_HbDpc;
static KDPC g_CpuDpc[HB_MAX_CPUS];
static volatile ULONG g_CpuTicks[HB_MAX_CPUS];
static ULONG g_Cpus;
static ULONG g_Tick;
static ULONG g_Stalls;
static ULONG g_Hbas;
static ULONG g_Watches;
static HB_WATCH g_Watch[HB_MAX_WATCH];

#define RD(base, off) READ_REGISTER_ULONG((PULONG)((base) + (off)))

static PCHAR
PutDec(PCHAR p, PCHAR end, ULONG v, ULONG digits)
{
    CHAR tmp[9];
    ULONG i, max = 1;

    if (digits > 9) digits = 9;
    for (i = 0; i < digits; i++) max *= 10;
    if (v >= max) v = max - 1;
    for (i = 0; i < digits; i++) { tmp[i] = (CHAR)('0' + v % 10); v /= 10; }
    while (i-- > 0 && p < end) *p++ = tmp[i];
    return p;
}

/* Keeps one mapping of a physical range, remapped only when the address
   changes (the port's command list, the slot's command table). */
static PUCHAR
Remap(PUCHAR Old, ULONG OldLow, ULONG OldHigh, ULONG Low, ULONG High, ULONG Length)
{
    PHYSICAL_ADDRESS pa;

    if (Old != NULL && OldLow == Low && OldHigh == High) return Old;
    if (Old != NULL) MmUnmapIoSpace(Old, Length);
    if (Low == 0 && High == 0) return NULL;
    pa.LowPart = Low;
    pa.HighPart = (LONG)High;
    return (PUCHAR)MmMapIoSpace(pa, Length, MmNonCached);
}

/* The command in Slot of the port's command list (op: ATA command, or
   A000h | SCSI opcode for ATAPI). */
static VOID
ReadCommand(PHB_WATCH w, ULONG Slot)
{
    ULONG low = RD(w->Regs, PX_CLB) & ~0x3FFUL, high = RD(w->Regs, PX_CLBU);
    PUCHAR hdr, f;

    w->Clb = Remap(w->Clb, w->ClbLow, w->ClbHigh, low, high, HB_CLB_MAP);
    w->ClbLow = low;
    w->ClbHigh = high;
    w->Valid = FALSE;
    if (w->Clb == NULL) return;
    hdr = w->Clb + Slot * 32;
    low = *(PULONG)(hdr + 8) & ~0x7FUL;
    high = *(PULONG)(hdr + 12);
    w->Ct = Remap(w->Ct, w->CtLow, w->CtHigh, low, high, HB_CT_MAP);
    w->CtLow = low;
    w->CtHigh = high;
    if (w->Ct == NULL) return;
    f = w->Ct;
    if (f[0] != 0x27) return;                       /* not a host-to-device FIS */
    w->Op = (hdr[0] & 0x20) ? (0xA000UL | f[0x40]) : f[2];
    w->Lba = (ULONG)f[4] | ((ULONG)f[5] << 8) | ((ULONG)f[6] << 16) | ((ULONG)f[8] << 24);
    w->Count = (ULONG)f[12] | ((ULONG)f[13] << 8);
    w->Valid = TRUE;
}

static PCHAR
PutName(PCHAR p, PCHAR end, PHB_WATCH w)
{
    if (p < end) *p++ = w->Name[0];
    if (p < end) *p++ = w->Name[1];
    return p;
}

/* Rows 3-4: the port registers of a command slot busy for 2 s.
   RS STALL a2 CI:00000001 SACT:00000000 IS:00000000 SERR:00000000 TFD:000000D0
   CMD:0000C017 HIS:00000000 poll op:35 lba:06FBA408 n:0080 slot:00 busy:02s #01 */
static VOID
ShowStall(PHB_WATCH w, ULONG Ci, ULONG Sact, ULONG Slot)
{
    CHAR line[80];
    PCHAR p, end = line + 80;
    ULONG ghc = RD(w->Abar, AHCI_GHC), ie = RD(w->Regs, PX_IE);

    p = PutStr(line, end, "RS STALL ");
    p = PutName(p, end, w);
    p = PutStr(p, end, " CI:");   p = PutHex(p, end, Ci, 8);
    p = PutStr(p, end, " SACT:"); p = PutHex(p, end, Sact, 8);
    p = PutStr(p, end, " IS:");   p = PutHex(p, end, RD(w->Regs, PX_IS), 8);
    p = PutStr(p, end, " SERR:"); p = PutHex(p, end, RD(w->Regs, PX_SERR), 8);
    p = PutStr(p, end, " TFD:");  p = PutHex(p, end, RD(w->Regs, PX_TFD), 8);
    ShowRow(ROW_STALL, line, (ULONG)(p - line), 0x4F00);

    p = PutStr(line, end, "CMD:"); p = PutHex(p, end, RD(w->Regs, PX_CMD), 8);
    p = PutStr(p, end, " HIS:");  p = PutHex(p, end, RD(w->Abar, AHCI_IS), 8);
    p = PutStr(p, end, ((ghc & AHCI_GHC_IE) && ie) ? " irq " : " poll");
    p = PutStr(p, end, " op:");   p = PutHex(p, end, w->Op, w->Op > 0xFF ? 4 : 2);
    p = PutStr(p, end, " lba:");  p = PutHex(p, end, w->Lba, 8);
    p = PutStr(p, end, " n:");    p = PutHex(p, end, w->Count, 4);
    p = PutStr(p, end, " slot:"); p = PutDec(p, end, Slot, 2);
    p = PutStr(p, end, " busy:"); p = PutDec(p, end, (g_Tick - w->BusySince) * HB_PERIOD_MS / 1000, 2);
    p = PutStr(p, end, "s #");    p = PutDec(p, end, g_Stalls, 2);
    ShowRow(ROW_STALL + 1, line, (ULONG)(p - line), 0x4F00);
}

static VOID
CpuDpc(IN PKDPC Dpc, IN PVOID Context, IN PVOID Arg1, IN PVOID Arg2)
{
    UNREFERENCED_PARAMETER(Dpc);
    UNREFERENCED_PARAMETER(Arg1);
    UNREFERENCED_PARAMETER(Arg2);
    g_CpuTicks[(ULONG)(ULONG_PTR)Context]++;
}

/* Row 1, every 250 ms:
   HB 0000013A t:000123s S:0 a2 CI:00000000 L:25 06FBA408+0080 age:0037s cpu:3A */
static VOID
HeartbeatDpc(IN PKDPC Dpc, IN PVOID Context, IN PVOID Arg1, IN PVOID Arg2)
{
    CHAR line[80];
    PCHAR p, end = line + 80;
    PHB_WATCH best = NULL;
    ULONG i, bestBusy = 0, bestCi = 0, busyAny = 0;
    ULONGLONG now;

    UNREFERENCED_PARAMETER(Dpc);
    UNREFERENCED_PARAMETER(Context);
    UNREFERENCED_PARAMETER(Arg1);
    UNREFERENCED_PARAMETER(Arg2);

    g_Tick++;
    for (i = 0; i < g_Cpus; i++) KeInsertQueueDpc(&g_CpuDpc[i], NULL, NULL);

    for (i = 0; i < g_Watches; i++) {
        PHB_WATCH w = &g_Watch[i];
        ULONG ci, sact, busy, slot = 0;
        ULONG op = w->Op, lba = w->Lba, count = w->Count;
        BOOLEAN valid = w->Valid;

        if ((RD(w->Regs, PX_SSTS) & 0x0F) != 3) continue;
        ci = RD(w->Regs, PX_CI);
        sact = RD(w->Regs, PX_SACT);
        busy = ci | sact;
        if (busy) while (!(busy & (1UL << slot))) slot++;
        ReadCommand(w, slot);
        if (w->Valid && (!valid || op != w->Op || lba != w->Lba || count != w->Count)) w->Changed = g_Tick;
        if (busy) {
            busyAny = 1;
            if (w->BusySince == 0 || w->BusyOp != w->Op || w->BusyLba != w->Lba || w->BusyCount != w->Count) {
                w->BusySince = g_Tick;
                w->BusyOp = w->Op;
                w->BusyLba = w->Lba;
                w->BusyCount = w->Count;
                w->Reported = FALSE;
            } else if (g_Tick - w->BusySince >= HB_STALL_TICKS && !w->Reported) {
                w->Reported = TRUE;
                g_Stalls++;
                ShowStall(w, ci, sact, slot);
            }
        } else {
            w->BusySince = 0;
        }
        /* Shown: a busy port first, else the one whose command changed last */
        if (w->Valid && (best == NULL || (busy && !bestBusy) ||
                         ((busy != 0) == (bestBusy != 0) && w->Changed > best->Changed))) {
            best = w;
            bestBusy = busy;
            bestCi = ci;
        }
    }

    now = KeQueryInterruptTime();
    p = PutStr(line, end, "HB ");
    p = PutHex(p, end, g_Tick, 8);
    p = PutStr(p, end, " t:");
    p = PutDec(p, end, (ULONG)(now >> 7) / 78125, 6);      /* 100 ns units -> s */
    p = PutStr(p, end, "s S:");
    p = PutHex(p, end, g_Stalls > 0xF ? 0xF : g_Stalls, 1);
    if (best != NULL) {
        p = PutStr(p, end, " ");
        p = PutName(p, end, best);
        p = PutStr(p, end, " CI:");
        p = PutHex(p, end, bestCi, 8);
        p = PutStr(p, end, " L:");
        p = PutHex(p, end, best->Op, best->Op > 0xFF ? 4 : 2);
        p = PutStr(p, end, " ");
        p = PutHex(p, end, best->Lba, 8);
        p = PutStr(p, end, "+");
        p = PutHex(p, end, best->Count, 4);
        p = PutStr(p, end, " age:");
        p = PutDec(p, end, (g_Tick - best->Changed) * HB_PERIOD_MS / 1000, 4);
        p = PutStr(p, end, "s");
    } else {
        p = PutStr(p, end, g_Watches ? " ahci:no-cmd" : " ahci:none");
    }
    p = PutStr(p, end, " cpu:");
    for (i = 0; i < g_Cpus; i++) p = PutHex(p, end, g_CpuTicks[i], 1);
    ShowRow(ROW_HB, line, (ULONG)(p - line), (USHORT)(busyAny && g_Stalls ? 0x4F00 : 0x1F00));
}

/* PCI: every AHCI HBA (class 01h/06h/01h, or the AMD/Intel IDs AHCINT also
   takes), its BAR5 mapped, every implemented port watched. */
static VOID
FindAhci(VOID)
{
    PCI_COMMON_CONFIG cfg;
    PCI_SLOT_NUMBER slot;
    ULONG bus, dev, fn, got, abar, pi, port;
    PHYSICAL_ADDRESS pa;
    PUCHAR regs;

    for (bus = 0; bus < 256; bus++) {
        for (dev = 0; dev < 32; dev++) {
            for (fn = 0; fn < 8; fn++) {
                slot.u.AsULONG = 0;
                slot.u.bits.DeviceNumber = dev;
                slot.u.bits.FunctionNumber = fn;
                got = HalGetBusData(PCIConfiguration, bus, slot.u.AsULONG, &cfg, PCI_COMMON_HDR_LENGTH);
                if (got == 0 && dev == 0 && fn == 0) return;        /* no such bus */
                if (got < PCI_COMMON_HDR_LENGTH || cfg.VendorID == 0xFFFF || cfg.VendorID == 0) {
                    if (fn == 0) break;
                    continue;
                }
                if (((cfg.BaseClass == 1 && cfg.SubClass == 6 && cfg.ProgIf == 1) ||
                     (cfg.VendorID == 0x1022 && (cfg.DeviceID == 0x7901 || cfg.DeviceID == 0x43EB || cfg.DeviceID == 0x43C8)) ||
                     (cfg.VendorID == 0x8086 && (cfg.DeviceID == 0x2829 || cfg.DeviceID == 0x2828 ||
                                                 cfg.DeviceID == 0x2922 || cfg.DeviceID == 0x2681))) &&
                    g_Hbas < HB_MAX_HBAS) {
                    abar = cfg.u.type0.BaseAddresses[5];
                    if (!(abar & 1) && (abar & ~0xFUL) != 0) {
                        pa.QuadPart = abar & ~0xFUL;
                        regs = (PUCHAR)MmMapIoSpace(pa, HB_ABAR_MAP, MmNonCached);
                        if (regs != NULL) {
                            pi = RD(regs, AHCI_PI);
                            for (port = 0; port < 32 && g_Watches < HB_MAX_WATCH; port++) {
                                PHB_WATCH w;
                                if (!(pi & (1UL << port))) continue;
                                w = &g_Watch[g_Watches++];
                                w->Abar = regs;
                                w->Regs = regs + 0x100 + port * 0x80;
                                w->Name[0] = (CHAR)('a' + g_Hbas);
                                w->Name[1] = (CHAR)(port < 10 ? '0' + port : 'A' + port - 10);
                            }
                            g_Hbas++;
                        }
                    }
                }
                if (fn == 0 && !(cfg.HeaderType & 0x80)) break;
            }
        }
    }
}

static VOID
StartHeartbeat(VOID)
{
    LARGE_INTEGER due;
    KAFFINITY active = KeQueryActiveProcessors();
    ULONG i;

    FindAhci();
    for (i = 0; i < HB_MAX_CPUS && (active & ((KAFFINITY)1 << i)); i++) {
        KeInitializeDpc(&g_CpuDpc[i], CpuDpc, (PVOID)(ULONG_PTR)i);
        KeSetTargetProcessorDpc(&g_CpuDpc[i], (CCHAR)i);
        KeSetImportanceDpc(&g_CpuDpc[i], HighImportance);
    }
    g_Cpus = i;
    KeInitializeDpc(&g_HbDpc, HeartbeatDpc, NULL);
    KeInitializeTimer(&g_HbTimer);
    due.QuadPart = -10000LL * HB_PERIOD_MS;
    KeSetTimerEx(&g_HbTimer, due, HB_PERIOD_MS, &g_HbDpc);
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
    CHAR restart;
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
    restart = RedirectSetupRestart();
    /* Text-mode Setup only: the heartbeat writes the text buffer every
       250 ms, which a graphics desktop must not get. */
    if (restart != '-') StartHeartbeat();
    if (g_InSetup && NT_SUCCESS(IoCreateDevice(DriverObject, 0, NULL, FILE_DEVICE_UNKNOWN, 0, FALSE, &device))) {
        DriverObject->MajorFunction[IRP_MJ_SHUTDOWN] = ShutdownDispatch;
        if (NT_SUCCESS(IoRegisterLastChanceShutdownNotification(device))) {
            shutdownHandler = TRUE;
        } else {
            IoDeleteDevice(device);
        }
    }

    /* The load line: shows that the driver ran and what it found. */
    p = PutStr(line, end, USOSRST_VERSION " rsdp=");
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
    p = PutStr(p, end, restart == 'o' ? " txt=on" : restart == '-' ? " txt=no" : " txt=err");
    p = PutStr(p, end, " hb");
    p = PutHex(p, end, g_Hbas, 1);
    p = PutStr(p, end, "/");
    p = PutHex(p, end, g_Watches, 2);
    ShowRow(ROW_LOAD, line, (ULONG)(p - line), 0x1F00);

    return STATUS_SUCCESS;
}
