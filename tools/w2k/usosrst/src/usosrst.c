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
 * 5. Clock diagnostics (1.3, text-mode Setup only). Rows 9-10 show, once
 *    at load, what drives the system clock: the TSC rate, the HPET (general
 *    configuration with the LegacyReplacement bit, timer 0, whether its
 *    counter runs), the 8254 PIT channel 0 status, the I/O APIC
 *    redirection entries of pins 0, 2, 8 and 9, the local APIC timer and
 *    LINT0/LINT1 entries, and the CMOS RTC registers A/B, century and year.
 *    Row 1 also gets "w:", seconds since load from the TSC, next to the
 *    clock-interrupt seconds "t:". If t: lags w:, clock interrupts are
 *    being lost.
 *
 * 6. Experiment (off by default): with "USOSHPETLEGOFF" in the load
 *    options (text mode, TXTSETUP [SetupData] OsLoadOptions) or the
 *    Parameters value HpetLegacyOff = 1 (later boots), the driver clears
 *    HPET LegacyReplacement (general configuration bit 1) when it is set.
 *    The 8254 PIT and the RTC then drive IRQ 0 and IRQ 8 again, as the
 *    pre-ACPI HALs expect. Row 9 shows "leg:1>0" when this was done.
 *
 * 7. Experiment (1.4, off by default): with "USOSRTCFIX" in the load
 *    options or the Parameters value RtcFix = 1, the driver reads the CMOS
 *    clock itself (register B: binary or BCD, 12 or 24 hours; century from
 *    the FADT CENTURY byte) and redirects ntoskrnl's import slots for
 *    HalQueryRealTimeClock (to this decode, the HAL's routine as the
 *    fallback) and HalSetRealTimeClock (to a no-op, so the CMOS clock is
 *    never written), then sets the system time with ZwSetSystemTime. On the
 *    X470 the HAL's decode gave a year of about 14773 and, in GUI Setup, a
 *    negative system time. The raw registers, both decodes and the system
 *    time before and after go to Parameters\RtcDiag (REG_BINARY,
 *    USOS_RTC_DIAG) for offline reading; the load line shows "rtco" (fixed)
 *    or "rtcx" (failed).
 *
 * Screen rows: 0 AHCINT, 1 heartbeat, 2 load line, 3-4 stall snapshot,
 * 5-7 STOP, 8 a second AHCINT HBA, 9-10 clock.
 */
#include <ntddk.h>

#ifdef USOSRST_NT351
/* NT 3.51 build (build-nt351.cmd, also USOSRST_NT4): the NT 3.51 kernel
   exports no KiBugCheckData, no KeSetTimerEx and no ZwSetSystemTime. The
   STOP rows show zeros, the heartbeat timer is re-armed by its DPC, and
   the clock fix only redirects the HAL RTC routines (the system time keeps
   the value the kernel read at boot). */
static ULONG g_NoBugCheckData[5];
#define USOS_BUGCHECK_DATA g_NoBugCheckData
#else
/* Exported by every NT kernel since 4.0; ntddk.h does not declare it. */
__declspec(dllimport) extern ULONG KiBugCheckData[5];
#define USOS_BUGCHECK_DATA KiBugCheckData
#endif

/* Compiler intrinsics (WDK 7.1 x86 has no intrin.h; __rdtsc is in ntddk.h). */
unsigned __int64 __readmsr(unsigned long Register);
void __cdecl _disable(void);
void __cdecl _enable(void);
#pragma intrinsic(__readmsr, _disable, _enable)

/* Exported by every NT HAL (stdcall, one argument); the WDK 7.1 headers no
   longer declare it. Routine values as in the NT 4.0-2003 DDKs
   (FIRMWARE_REENTRY). */
#define USOS_HAL_POWERDOWN_ROUTINE 1
#define USOS_HAL_RESTART_ROUTINE  2
#define USOS_HAL_REBOOT_ROUTINE   3
__declspec(dllimport) VOID NTAPI HalReturnToFirmware(IN ULONG Routine);

#ifdef USOSRST_NT4
/* NT 4.0 build (build-nt4.cmd): three kernel routines this driver uses
   came with Windows 2000, so the NT 4.0 build replaces them.
   KeQueryInterruptTime: the interrupt time the kernel keeps in the shared
   user data page (KSYSTEM_TIME, read until both high parts agree).
   KeQueryActiveProcessors: NT 4.0 numbers its processors 0..n-1, so the
   mask follows from KeNumberProcessors. IoRegisterLastChanceShutdownNotification
   does not exist; see RedirectKernelRestart instead. */
static ULONGLONG
UsosInterruptTime(VOID)
{
    LARGE_INTEGER t;

    do {
        t.HighPart = SharedUserData->InterruptTime.High1Time;
        t.LowPart = SharedUserData->InterruptTime.LowPart;
    } while (t.HighPart != SharedUserData->InterruptTime.High2Time);
    return (ULONGLONG)t.QuadPart;
}
#define KeQueryInterruptTime() UsosInterruptTime()

static KAFFINITY
UsosActiveProcessors(VOID)
{
    CCHAR n = KeNumberProcessors;

    if (n <= 0) return 1;
    if (n >= (CCHAR)(sizeof(KAFFINITY) * 8)) return (KAFFINITY)-1;
    return ((KAFFINITY)1 << n) - 1;
}
#define KeQueryActiveProcessors() UsosActiveProcessors()
#ifdef USOSRST_NT351
#if defined(USOSRST_NT31)
#define USOSRST_VERSION "usosrst 1.6-nt31"
#elif defined(USOSRST_NT35)
/* NT 3.5 (1.7-nt35, native NT 3.5 round 2026-10-30): the NT 3.51 1.7/1.8
   restart path (shutdown log, NVMe/xHCI/NIC quiesce, CF9h full reset), the
   RAM marker page, and the NT 4.0 1.9-1.11 power-off (ACPI S5 for
   HalPowerDownRoutine: the NT 3.5 Winlogon has PowerdownAfterShutdown and
   "Shutdown and Power off"). The kernel import slot is redirected as on
   NT 3.51 (MDL write; NT 3.5 maps the kernel with small pages); when that
   finds no slot, the jmp at the start of the HAL's HalReturnToFirmware
   takes over (handler=inl). */
#define USOSRST_VERSION "usosrst 1.7-nt35"
#define USOSRST_SHUTLOG 1
#define USOSRST_RAMLOG 1
#define USOSRST_POWEROFF 1
#define USOSRST_INLINE 1
#else
#define USOSRST_VERSION "usosrst 1.8-nt351"
/* NT 3.51 only (1.7): shutdown log, device quiesce and full reset (below). */
#define USOSRST_SHUTLOG 1
/* NT 3.51 only (1.8): stage letters + STOP code in the RAM marker page. */
#define USOSRST_RAMLOG 1
#endif
#elif defined(USOSRST_NT4N)
/* Native NT 4.0 (build-nt4n.cmd, bin/nt4n): the NT 3.51 1.7/1.8 restart
   path (shutdown log, NVMe/xHCI/NIC quiesce, CF9h full reset) and the RAM
   marker page for the USOS pre-boot logger. On the MPS multiprocessor HAL
   the quiesce runs at DISPATCH_LEVEL on the restarting processor only;
   the full reset follows within milliseconds. The VM-path NT 4.0 build
   (bin/nt4, 1.5-nt4) is unchanged. */
#define USOSRST_VERSION "usosrst 1.11-nt4n"
#define USOSRST_SHUTLOG 1
#define USOSRST_RAMLOG 1
/* 1.9: power-off (HalPowerDownRoutine) through ACPI S5, see AcpiPowerOff. */
/* 1.10: the NT 4.0 kernel import slot is written through its physical
   address (large kernel pages: handler=off in 1.9), wake sources cleared
   before S5 (GPE, PM1, RTC alarm, PCI PME), longer registry load line. */
/* 1.11: handler=off again with 1.10: when the kernel import slot cannot be
   redirected, a jmp at the start of the HAL's HalReturnToFirmware takes
   restart/power-off (handler=inl); load line k+/k- and the slot result. */
#define USOSRST_POWEROFF 1
#define USOSRST_INLINE 1
#else
#define USOSRST_VERSION "usosrst 1.5-nt4"
#endif
#else
#define USOSRST_VERSION "usosrst 1.4"
#endif
#define ROW_HB          1
#define ROW_LOAD        2
#define ROW_STALL       3
#define ROW_STOP        5
#define ROW_CLOCK       9

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
static ULONG g_HpetTable;           /* physical address of the HPET table */
static ULONG g_MadtTable;           /* physical address of the MADT ("APIC") */
static UCHAR g_CenturyIndex;        /* FADT CENTURY: CMOS index of the century byte, 0 = none */
#ifdef USOSRST_POWEROFF
static ULONG g_Pm1aCnt, g_Pm1bCnt;  /* FADT PM1a/PM1b_CNT_BLK (I/O ports), 0 = none */
static ULONG g_Pm1aEvt, g_Pm1bEvt;  /* FADT PM1a/PM1b_EVT_BLK: PM1 status at the start */
static ULONG g_Gpe0, g_Gpe1;        /* FADT GPE0/GPE1_BLK (I/O ports), 0 = none */
static UCHAR g_Pm1EvtLen, g_Gpe0Len, g_Gpe1Len; /* FADT PM1_EVT_LEN, GPE0/GPE1_BLK_LEN */
static UCHAR g_S5a, g_S5b;          /* SLP_TYPa / SLP_TYPb from the DSDT's \_S5 package */
static CHAR g_S5State = '-';        /* load line: o found, - no FADT/DSDT, x no _S5 */
#endif
#ifdef USOSRST_INLINE
static ULONG g_KernelFound;         /* load line k+/k- */
static LONG g_KernelPatch = -2;     /* PatchImports result: slots, 0 none matched, -1 bad image or write */
static BOOLEAN g_InlineHook;        /* load line handler=inl */
#endif

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

#ifdef USOSRST_NT4
/* Boot-screen rows (NT 4.0 / 3.x builds, 2026-10-30): the white rows (load
   line, heartbeat, clock, the text-mode restart note) only on a boot whose
   load options carry /SOS (the BOOT.INI entry "[USOS /SOS]"); the red rows
   (STOP, stall, a heartbeat that saw stalls) always, they appear only when
   something is wrong. The registry LoadLine and the disk/RAM logs are not
   affected. SystemStartOptions is written by the kernel (CmInitSystem1)
   before the boot drivers start; no value = no /SOS. */
static BOOLEAN g_Sos;

static BOOLEAN
BootHasSos(VOID)
{
    UNICODE_STRING key, name;
    OBJECT_ATTRIBUTES oa;
    HANDLE h;
    ULONG buf[130], got = 0, n, i;
    PWCHAR s;
    BOOLEAN sos = FALSE;

    RtlInitUnicodeString(&key, L"\\Registry\\Machine\\System\\CurrentControlSet\\Control");
    RtlInitUnicodeString(&name, L"SystemStartOptions");
    InitializeObjectAttributes(&oa, &key, OBJ_CASE_INSENSITIVE, NULL, NULL);
    if (!NT_SUCCESS(ZwOpenKey(&h, KEY_READ, &oa))) return FALSE;
    if (NT_SUCCESS(ZwQueryValueKey(h, &name, KeyValuePartialInformation, buf, sizeof(buf) - 4, &got)) &&
        (buf[1] == REG_SZ || buf[1] == REG_EXPAND_SZ)) {
        s = (PWCHAR)&buf[3];
        n = buf[2] / 2;
        if (n > 250) n = 250;
        for (i = 0; i + 3 <= n; i++) {
            if ((s[i] | 0x20) == 's' && (s[i + 1] | 0x20) == 'o' && (s[i + 2] | 0x20) == 's' &&
                (i == 0 || s[i - 1] == ' ' || s[i - 1] == '/') &&
                (i + 3 == n || s[i + 3] == ' ' || s[i + 3] == '/' || s[i + 3] == 0)) {
                sos = TRUE;
                break;
            }
        }
    }
    ZwClose(h);
    return sos;
}
#endif

static VOID
ShowRow(ULONG Row, PCHAR Text, ULONG Length, USHORT Attr)
{
    ULONG i;
    PUSHORT row;

    if (g_Vga == NULL) return;
#ifdef USOSRST_NT4
    if (!g_Sos && Attr != 0x4F00) return;
#endif
    row = g_Vga + Row * 80;
    for (i = 0; i < 80; i++) row[i] = (USHORT)(Attr | (UCHAR)(i < Length ? Text[i] : ' '));
}

#ifdef USOSRST_RAMLOG
/* ------------------------------------------------------------------ */
/* NT 3.51: RAM marker page (1.8)                                      */
/* ------------------------------------------------------------------ */
/*
 * The USOS NT pre-boot logger (tools/nt_bootlog, \EFI\BOOT\BOOTX64.EFI of
 * the disk's CSMWrap ESP, started before CSMWrap on every boot) prepares the
 * page at physical 50000000h ("USOSPRE1", boot number, its complement) and,
 * on the next boot, logs what it finds there into \USOS\BOOTLOG.TXT. The
 * page lies above /MAXMEM=1024 (BOOT.INI of the USOS NT 3.51 install; the
 * 3.51 osloader drops every memory descriptor above it), so NT never uses
 * it; this driver writes it only when the logger's header is valid, mapped
 * non-cached so each letter is in DRAM at once. When the RAM survives a
 * warm reset, the record tells the last stage reached (and the STOP code)
 * even when no disk write happened. Layout (tools/nt_bootlog/decode.zig):
 *   +40h "USOSNT35"  +48h boot number (copied)  +4Ch stage count
 *   +50h 64 stage letters  +90h bugcheck count  +94h 5 bugcheck words
 *   +A8h seconds since load at the last letter
 * Letters: L loaded, then the shutdown log letters (R P S F digit Z), Q the
 * devices are quiesced, C the CF9h full reset is written next, K a bugcheck
 * callback ran. NT 3.51 exports no KiBugCheckData; its address is taken from
 * the five consecutive absolute stores at the start of KeBugCheckEx (the
 * NT 3.5 behaviour: code and parameters stored before the callbacks run);
 * when that pattern is not found the bugcheck words stay zero.
 */
#define RM_ADDRESS      0x50000000UL
static volatile UCHAR *g_Rm;
static LONG g_RmCount;
static PULONG g_RmBugData;
static LARGE_INTEGER g_RmT0;

static VOID
RmStage(CHAR Stage)
{
    LONG i;
    LARGE_INTEGER now;

    if (g_Rm == NULL) return;
    i = InterlockedIncrement(&g_RmCount) - 1;
    if (i < 0 || i >= 64) return;
    g_Rm[0x50 + i] = (UCHAR)Stage;
    *(volatile ULONG *)(g_Rm + 0x4C) = (ULONG)(i + 1);
    KeQuerySystemTime(&now);
    *(volatile ULONG *)(g_Rm + 0xA8) = (ULONG)((now.QuadPart - g_RmT0.QuadPart) / 10000000LL);
}

/* KiBugCheckData: five absolute stores (A3 moffs32 / 89 modrm=00rrr101
   disp32) to X, X+4 .. X+16 in the first 200h bytes of KeBugCheckEx. */
static PULONG
RmFindBugCheckData(VOID)
{
    PUCHAR code = (PUCHAR)(ULONG_PTR)KeBugCheckEx;
    ULONG disp[48], n = 0, i, j, k, hits;

    if (!MmIsAddressValid(code) || !MmIsAddressValid(code + 0x1FF)) return NULL;
    for (i = 0; i < 0x1F0 && n < 48; i++) {
        if (code[i] == 0xA3) disp[n++] = *(ULONG UNALIGNED *)(code + i + 1);
        else if (code[i] == 0x89 && (code[i + 1] & 0xC7) == 0x05) disp[n++] = *(ULONG UNALIGNED *)(code + i + 2);
    }
    for (i = 0; i < n; i++) {
        if (disp[i] < 0x80000000UL || (disp[i] & 3)) continue;
        hits = 0;
        for (k = 1; k < 5; k++)
            for (j = 0; j < n; j++)
                if (disp[j] == disp[i] + 4 * k) { hits++; break; }
        if (hits == 4 && MmIsAddressValid((PVOID)disp[i]) && MmIsAddressValid((PVOID)(disp[i] + 19)))
            return (PULONG)disp[i];
    }
    return NULL;
}

static VOID
RmInit(VOID)
{
    PHYSICAL_ADDRESS pa;
    volatile UCHAR *page;
    ULONG boot, i;

    pa.QuadPart = RM_ADDRESS;
    page = (volatile UCHAR *)MmMapIoSpace(pa, 0x1000, MmNonCached);
    if (page == NULL) return;
    boot = *(volatile ULONG *)(page + 8);
    if (*(volatile ULONG *)page != 0x534F5355UL || *(volatile ULONG *)(page + 4) != 0x31455250UL ||
        *(volatile ULONG *)(page + 12) != ~boot) {
        MmUnmapIoSpace((PVOID)page, 0x1000);   /* no logger this boot: never write */
        return;
    }
    for (i = 0x40; i < 0x100; i++) page[i] = 0;
    *(volatile ULONG *)(page + 0x48) = boot;
    *(volatile ULONG *)(page + 0x40) = 0x534F5355UL;   /* "USOS" */
    *(volatile ULONG *)(page + 0x44) = 0x3533544EUL;   /* "NT35" */
    KeQuerySystemTime(&g_RmT0);
    g_RmBugData = RmFindBugCheckData();
    g_Rm = page;
    RmStage('L');
}

/* Bugcheck callback (any IRQL, interrupts off): count, STOP words, K. */
static VOID
RmBugCheck(VOID)
{
    ULONG i;

    if (g_Rm == NULL) return;
    *(volatile ULONG *)(g_Rm + 0x90) += 1;
    if (g_RmBugData != NULL)
        for (i = 0; i < 5; i++) *(volatile ULONG *)(g_Rm + 0x94 + 4 * i) = g_RmBugData[i];
    RmStage('K');
}
#else
#define RmStage(c) ((VOID)0)
#endif

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
#ifdef USOSRST_RAMLOG
    RmBugCheck();
#endif

    p = PutStr(line, end, "USOS: STOP 0x");
    p = PutHex(p, end, USOS_BUGCHECK_DATA[0], 8);
    p = PutStr(p, end, " (");
    for (i = 1; i <= 4; i++) {
        p = PutStr(p, end, "0x");
        p = PutHex(p, end, USOS_BUGCHECK_DATA[i], 8);
        p = PutStr(p, end, i < 4 ? "," : ")");
    }
    ShowRow(ROW_STOP, line, (ULONG)(p - line), 0x4F00);

    p = PutStr(line, end, "USOS: in");
    for (i = 1; i <= 4; i++) p = PutModule(p, end, USOS_BUGCHECK_DATA[i]);
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

#ifdef USOSRST_POWEROFF
/* One AML integer of the \_S5 package: ZeroOp, OneOp, BytePrefix. */
static BOOLEAN
AmlSmallInt(PUCHAR p, PUCHAR end, PUCHAR *next, PUCHAR value)
{
    if (p >= end) return FALSE;
    if (*p == 0x00 || *p == 0x01) { *value = *p; *next = p + 1; return TRUE; }
    if (*p == 0x0A && p + 1 < end) { *value = p[1]; *next = p + 2; return TRUE; }
    return FALSE;
}

/* SLP_TYPa/SLP_TYPb of the sleeping state S5 (soft off): the DSDT's
   Name (_S5, Package () { a, b, ... }), AML NameOp 08h, the name "_S5_"
   (optionally after the root prefix "\"), PackageOp 12h, PkgLength (1-4
   bytes, the top two bits of the first byte count the extra bytes),
   NumElements, then the elements. TRUE when both values were found. */
static BOOLEAN
FindS5(ULONG Dsdt)
{
    PUCHAR hdr, aml, p, end, q;
    ULONG length, i;
    BOOLEAN found = FALSE;

    hdr = MapPhys(Dsdt, 36);
    if (hdr == NULL) return FALSE;
    length = (hdr[0] == 'D' && hdr[1] == 'S' && hdr[2] == 'D' && hdr[3] == 'T') ? *(PULONG)(hdr + 4) : 0;
    MmUnmapIoSpace(hdr, 36);
    if (length < 36 + 8 || length > 0x200000) return FALSE;
    aml = MapPhys(Dsdt, length);
    if (aml == NULL) return FALSE;
    end = aml + length;
    for (i = 36; i + 8 < length && !found; i++) {
        p = aml + i;
        if (p[0] != '_' || p[1] != 'S' || p[2] != '5' || p[3] != '_') continue;
        if (!(p[-1] == 0x08 || (p[-1] == 0x5C && p[-2] == 0x08))) continue;
        q = p + 4;
        if (*q != 0x12) continue;
        q += 1 + 1 + (q[1] >> 6);           /* PackageOp, PkgLength */
        q++;                                /* NumElements */
        if (AmlSmallInt(q, end, &q, &g_S5a) && AmlSmallInt(q, end, &q, &g_S5b)) found = TRUE;
    }
    MmUnmapIoSpace(aml, length);
    return found;
}

#endif

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
        if (hdr[0] == 'F' && hdr[1] == 'A' && hdr[2] == 'C' && hdr[3] == 'P' && fadtAddr == 0) fadtAddr = addr;
        if (hdr[0] == 'H' && hdr[1] == 'P' && hdr[2] == 'E' && hdr[3] == 'T' && g_HpetTable == 0) g_HpetTable = addr;
        if (hdr[0] == 'A' && hdr[1] == 'P' && hdr[2] == 'I' && hdr[3] == 'C' && g_MadtTable == 0) g_MadtTable = addr;
        MmUnmapIoSpace(hdr, 36);
    }
    MmUnmapIoSpace(sdt, sdtLen);
    if (fadtAddr == 0) return;

    fadt = MapPhys(fadtAddr, 129);
    if (fadt == NULL) return;
    /* CENTURY (CMOS index of the century byte) at 108, ACPI 1.0+ */
    if (*(PULONG)(fadt + 4) >= 109) g_CenturyIndex = fadt[108];
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
#ifdef USOSRST_POWEROFF
    /* ACPI 1.0 FADT: DSDT at 40, PM1a/PM1b_EVT_BLK at 56/60, PM1a/PM1b_CNT_BLK
       at 64/68 (32-bit I/O port numbers). */
    if (*(PULONG)(fadt + 4) >= 72 && *(PULONG)(fadt + 64) != 0 && *(PULONG)(fadt + 64) < 0x10000) {
        ULONG dsdt = *(PULONG)(fadt + 40);
        g_Pm1aEvt = *(PULONG)(fadt + 56);
        g_Pm1bEvt = *(PULONG)(fadt + 60);
        g_Pm1aCnt = *(PULONG)(fadt + 64);
        g_Pm1bCnt = *(PULONG)(fadt + 68);
        if (g_Pm1aEvt >= 0x10000) g_Pm1aEvt = 0;
        if (g_Pm1bEvt >= 0x10000) g_Pm1bEvt = 0;
        if (g_Pm1bCnt >= 0x10000) g_Pm1bCnt = 0;
        /* GPE0_BLK 80, GPE1_BLK 84, PM1_EVT_LEN 88, GPE0_BLK_LEN 92, GPE1_BLK_LEN 93 */
        if (*(PULONG)(fadt + 4) >= 94) {
            g_Gpe0 = *(PULONG)(fadt + 80);
            g_Gpe1 = *(PULONG)(fadt + 84);
            g_Pm1EvtLen = fadt[88];
            g_Gpe0Len = fadt[92];
            g_Gpe1Len = fadt[93];
            if (g_Gpe0 >= 0x10000 || g_Gpe0Len > 64) g_Gpe0 = 0;
            if (g_Gpe1 >= 0x10000 || g_Gpe1Len > 64) g_Gpe1 = 0;
        }
        MmUnmapIoSpace(fadt, 129);
        g_S5State = 'x';
        if (dsdt != 0 && FindS5(dsdt)) g_S5State = 'o';
        return;
    }
#endif
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

#ifdef USOSRST_SHUTLOG
/* ------------------------------------------------------------------ */
/* NT 3.51: shutdown log, device quiesce, full reset (1.7)             */
/* ------------------------------------------------------------------ */
/*
 * Why: on the X470 a restart of native NT 3.51 took long and froze, and
 * the boot after a restart crashed early (0x0A, a zeroed working-set list)
 * while a boot after a power cycle worked. NT 3.51's NtShutdownSystem runs
 * (behaviour as in the NT 3.5 sources supplied by the user, read for the
 * order only): I/O shutdown phase 0 (every IoRegisterShutdownNotification
 * driver, the last registered first, each IRP waited for without a
 * timeout), the registry and memory manager shutdown, I/O phase 1 (every
 * disk file system flushes its volumes), then
 * HalReturnToFirmware(HalRebootRoutine). The Standard HAL then pulses the
 * 8042 (none on these boards) and halts with interrupts off; this driver
 * already takes that call over (RedirectKernelRestart), but its reset left
 * the NVMe controller enabled (usosnvme only flushes at SRB_FUNCTION_SHUTDOWN
 * on NT 3.x), the xHCI controllers running, and used the FADT reset
 * (CF9h = 06h on AMD, a hard reset) first.
 *
 * Shutdown log: disk sector 4 of the USOS NT 3.x disk (layout in
 * src/platform/bios/nt3/nt3_e820_mbr.S; the MBR starts each boot's trail
 * with "B" and keeps 7 previous boots). Stage letters appended here:
 *   R  usosrst found the log disk (45 s after load; Windows is running)
 *   P  shutdown phase 0 started (a notification registered at R, so it runs
 *      first of all phase 0 handlers)
 *   S  shutdown phase 0 ended (registered at load, so it runs last)
 *   F  HalReturnToFirmware(restart / reboot) reached: phase 1 (file
 *      systems) is done; the routine number follows as a digit
 *   Z  the quiesce and full reset come next (nothing can be logged after:
 *      the disk controller is shut down)
 * The trail of the boot before tells where the restart stopped: no P = in
 * user mode (Winlogon, services), P without S = in a phase 0 handler, S
 * without F = registry / memory manager / file system flush, Z = the reset
 * itself or the firmware after it. The disk is the one whose sectors 1 and 3
 * carry "U3" and "Q3" and whose sector 4 already is a log ("USOSSHUT"); it is
 * written only at PASSIVE_LEVEL, to the disk device below every file system
 * (IoGetDeviceObjectPointer on \Device\HarddiskN\Partition0), each request
 * waited for at most 3 s. After a timeout the log is off for that boot.
 *
 * Quiesce and full reset (restart / reboot only, any IRQL, so also the
 * restart after a bugcheck): at DISPATCH_LEVEL (uniprocessor: usosusb's
 * polling thread cannot run in between) every NVMe controller gets the
 * CC.SHN normal shutdown notification (CSTS.SHST complete waited for at most
 * 2 s), then CC.EN = 0 (CSTS.RDY = 0 at most 1 s); every xHCI controller
 * USBCMD R/S = 0 (USBSTS.HCH at most 100 ms), then HCRST (at most 200 ms);
 * every NVMe, xHCI and network function then loses PCI Bus Master Enable, so
 * nothing can DMA into memory any more. Then CF9h 0Ah, 0Eh: the full reset
 * (FullRst: the power planes are cycled and every device is reset, as with
 * a power cycle), and only if the machine still runs, the old order (FADT
 * reset register, CF9h 02h/06h/0Eh, 8042).
 */
#define SL_LBA          4
#define SL_TRAIL        16
#define SL_TRAIL_END    48
#define SL_TIMES        48
#define SL_MAX_DEV      12
#define SL_NVME         1
#define SL_XHCI         2
#define SL_BUSMASTER    3

typedef struct _SL_DEV {
    ULONG Cfg;                      /* CF8h address of the function */
    UCHAR Kind;
    PUCHAR Regs;                    /* BAR0, 4 KiB, NVMe / xHCI only */
} SL_DEV;

static __declspec(align(64)) UCHAR g_SlBuf[512];
static PDEVICE_OBJECT g_SlDisk;     /* the disk device (Partition0), via g_SlFile */
static PFILE_OBJECT g_SlFile;
static PDEVICE_OBJECT g_SlFirstDev, g_SlLastDev;
static KEVENT g_SlEvent;
static IO_STATUS_BLOCK g_SlIosb;
static LONG g_SlBusy;
static LARGE_INTEGER g_SlT0;
static SL_DEV g_SlDev[SL_MAX_DEV];
static ULONG g_SlDevs;

static ULONG
SlCfgRead(ULONG Cfg, ULONG Reg)
{
    WRITE_PORT_ULONG((PULONG)0xCF8, Cfg | (Reg & 0xFC));
    return READ_PORT_ULONG((PULONG)0xCFC);
}

/* One sector of the log disk into / from g_SlBuf; the caller holds g_SlBusy. */
static NTSTATUS
SlIo(UCHAR Major, ULONG Lba)
{
    LARGE_INTEGER off, timeout;
    PIRP irp;
    NTSTATUS st;

    if (g_SlDisk == NULL) return STATUS_UNSUCCESSFUL;
    KeInitializeEvent(&g_SlEvent, NotificationEvent, FALSE);
    off.QuadPart = (LONGLONG)Lba * 512;
    irp = IoBuildSynchronousFsdRequest(Major, g_SlDisk, g_SlBuf, 512, &off, &g_SlEvent, &g_SlIosb);
    if (irp == NULL) return STATUS_INSUFFICIENT_RESOURCES;
    IoGetNextIrpStackLocation(irp)->Flags |= SL_OVERRIDE_VERIFY_VOLUME;
    st = IoCallDriver(g_SlDisk, irp);
    if (st == STATUS_PENDING) {
        timeout.QuadPart = -30000000LL;                         /* 3 s */
        if (KeWaitForSingleObject(&g_SlEvent, Executive, KernelMode, FALSE, &timeout) == STATUS_TIMEOUT) {
            g_SlDisk = NULL;        /* the IRP still owns the event: log off */
            return STATUS_IO_TIMEOUT;
        }
        st = g_SlIosb.Status;
    }
    return st;
}

static BOOLEAN
SlIsLog(VOID)
{
    return (BOOLEAN)(*(PULONG)g_SlBuf == 0x534F5355UL && *(PULONG)(g_SlBuf + 4) == 0x54554853UL);
}

static BOOLEAN
SlSigned(ULONG Lba, USHORT Signature)
{
    return (BOOLEAN)(NT_SUCCESS(SlIo(IRP_MJ_READ, Lba)) && *(PUSHORT)(g_SlBuf + 510) == Signature);
}

/* The USOS NT 3.x disk: "U3" in sector 1, "Q3" in sector 3, a log in 4. */
static VOID
SlFindDisk(VOID)
{
    WCHAR name[] = L"\\Device\\Harddisk0\\Partition0";
    UNICODE_STRING us;
    PFILE_OBJECT fo;
    PDEVICE_OBJECT dev;
    ULONG n;

    for (n = 0; n < 8 && g_SlFile == NULL; n++) {
        name[16] = (WCHAR)(L'0' + n);
        RtlInitUnicodeString(&us, name);
        if (!NT_SUCCESS(IoGetDeviceObjectPointer(&us, FILE_READ_ATTRIBUTES, &fo, &dev))) continue;
        g_SlDisk = fo->DeviceObject;
        if (SlSigned(1, 0x3355) && SlSigned(3, 0x3351) && NT_SUCCESS(SlIo(IRP_MJ_READ, SL_LBA)) && SlIsLog()) {
            g_SlFile = fo;
            return;
        }
        if (g_SlDisk == NULL) {     /* a request timed out: keep the reference, stop */
            g_SlFile = fo;
            return;
        }
        g_SlDisk = NULL;
        ObDereferenceObject(fo);
    }
}

/* Appends one stage letter (and, for the first 8, its time) to the current
   record. */
static VOID
SlStage(CHAR Stage)
{
    ULONG i, secs;
    LARGE_INTEGER now;

    RmStage(Stage);                 /* RAM marker: any IRQL, no disk */
    if (g_SlDisk == NULL || KeGetCurrentIrql() != PASSIVE_LEVEL) return;
    if (InterlockedExchange(&g_SlBusy, 1) != 0) return;
    if (NT_SUCCESS(SlIo(IRP_MJ_READ, SL_LBA)) && SlIsLog()) {
        for (i = SL_TRAIL; i < SL_TRAIL_END - 1 && g_SlBuf[i] != 0; i++) ;
        if (g_SlBuf[i] == 0) {
            g_SlBuf[i] = (UCHAR)Stage;
            if (i - SL_TRAIL < 8) {
                KeQuerySystemTime(&now);
                secs = (ULONG)((now.QuadPart - g_SlT0.QuadPart) / 10000000LL);
                ((PUSHORT)(g_SlBuf + SL_TIMES))[i - SL_TRAIL] = (USHORT)(secs > 0xFFFF ? 0xFFFF : secs);
            }
            (VOID)SlIo(IRP_MJ_WRITE, SL_LBA);
        }
    } else {
        g_SlDisk = NULL;            /* not a log (any more): never write */
    }
    InterlockedExchange(&g_SlBusy, 0);
}

static NTSTATUS
SlShutdownDispatch(IN PDEVICE_OBJECT DeviceObject, IN PIRP Irp)
{
    SlStage((CHAR)(DeviceObject == g_SlFirstDev ? 'P' : 'S'));
    Irp->IoStatus.Status = STATUS_SUCCESS;
    Irp->IoStatus.Information = 0;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return STATUS_SUCCESS;
}

static VOID
SlThread(IN PVOID Context)
{
    LARGE_INTEGER delay;

    UNREFERENCED_PARAMETER(Context);
    delay.QuadPart = -450000000LL;                              /* 45 s */
    KeDelayExecutionThread(KernelMode, FALSE, &delay);
    SlFindDisk();
    SlStage('R');
    if (g_SlFirstDev != NULL) (VOID)IoRegisterShutdownNotification(g_SlFirstDev);
    PsTerminateSystemThread(STATUS_SUCCESS);
}

/* At load: every NVMe (010802h), xHCI (0C0330h) and network (02h) function
   behind CF8h/CFCh (the 3.51 HAL may have no PCI bus), BAR0 mapped for the
   first two (a memory BAR below 4 GB). */
static VOID
SlScanPci(VOID)
{
    ULONG bus, dev, fn, cfg, id, cls, hdr, bar;
    UCHAR kind;
    PHYSICAL_ADDRESS pa;
    SL_DEV *e;

    for (bus = 0; bus < 256; bus++) {
        for (dev = 0; dev < 32; dev++) {
            for (fn = 0; fn < 8; fn++) {
                cfg = 0x80000000UL | (bus << 16) | (dev << 11) | (fn << 8);
                id = SlCfgRead(cfg, 0);
                if (id == 0xFFFFFFFF || (id & 0xFFFF) == 0xFFFF || id == 0) {
                    if (fn == 0) break;
                    continue;
                }
                cls = SlCfgRead(cfg, 8) >> 8;
                hdr = (SlCfgRead(cfg, 0x0C) >> 16) & 0xFF;
                kind = 0;
                if ((hdr & 0x7F) == 0) {
                    if (cls == 0x010802) kind = SL_NVME;
                    else if (cls == 0x0C0330) kind = SL_XHCI;
                    else if ((cls >> 16) == 0x02) kind = SL_BUSMASTER;
                }
                if (kind && g_SlDevs < SL_MAX_DEV) {
                    e = &g_SlDev[g_SlDevs++];
                    e->Cfg = cfg;
                    e->Kind = kind;
                    e->Regs = NULL;
                    bar = SlCfgRead(cfg, 0x10);
                    if (kind != SL_BUSMASTER && !(bar & 1) && (bar & ~0xFUL) != 0 &&
                        ((bar & 6) != 4 || SlCfgRead(cfg, 0x14) == 0)) {
                        pa.QuadPart = bar & ~0xFUL;
                        e->Regs = (PUCHAR)MmMapIoSpace(pa, 0x1000, MmNonCached);
                    }
                }
                if (fn == 0 && !(hdr & 0x80)) break;
            }
        }
    }
    WRITE_PORT_ULONG((PULONG)0xCF8, 0);
}

#define SL_RD(p, o)     READ_REGISTER_ULONG((PULONG)((p) + (o)))
#define SL_WR(p, o, v)  WRITE_REGISTER_ULONG((PULONG)((p) + (o)), (v))

static VOID
SlQuiesce(VOID)
{
    ULONG d, i, cc, cmd;
    PUCHAR r, op;

    for (d = 0; d < g_SlDevs; d++) {
        r = g_SlDev[d].Regs;
        if (g_SlDev[d].Kind == SL_NVME && r != NULL) {
            cc = SL_RD(r, 0x14);
            if (cc != 0xFFFFFFFF && (cc & 1)) {
                if ((SL_RD(r, 0x1C) & 3) == 1) {            /* RDY, no CFS */
                    if (((cc >> 14) & 3) == 0) SL_WR(r, 0x14, cc | (1UL << 14));
                    for (i = 0; i < 2000 && ((SL_RD(r, 0x1C) >> 2) & 3) != 2; i++) KeStallExecutionProcessor(1000);
                }
                SL_WR(r, 0x14, SL_RD(r, 0x14) & ~1UL);
                for (i = 0; i < 1000 && (SL_RD(r, 0x1C) & 1); i++) KeStallExecutionProcessor(1000);
            }
        } else if (g_SlDev[d].Kind == SL_XHCI && r != NULL) {
            op = r + READ_REGISTER_UCHAR(r);                /* CAPLENGTH */
            cmd = SL_RD(op, 0);
            if (cmd != 0xFFFFFFFF) {
                SL_WR(op, 0, cmd & ~5UL);                       /* R/S, INTE off */
                for (i = 0; i < 100 && !(SL_RD(op, 4) & 1); i++) KeStallExecutionProcessor(1000);
                SL_WR(op, 0, 2);                                /* HCRST */
                for (i = 0; i < 200 && (SL_RD(op, 0) & 2); i++) KeStallExecutionProcessor(1000);
            }
        }
        /* PCI command register: Bus Master Enable (bit 2) off */
        cmd = SlCfgRead(g_SlDev[d].Cfg, 4);
        WRITE_PORT_ULONG((PULONG)0xCF8, g_SlDev[d].Cfg | 4);
        WRITE_PORT_USHORT((PUSHORT)0xCFC, (USHORT)(cmd & 0xFFFB));
    }
    WRITE_PORT_ULONG((PULONG)0xCF8, 0);
}

/* Restart / reboot: log, quiesce, full reset; returns only if no reset
   happened (the caller then goes on with the old order). */
static VOID
SlRestart(ULONG Routine)
{
    KIRQL old = PASSIVE_LEVEL;
    BOOLEAN raised = FALSE;

    SlStage('F');
    SlStage((CHAR)('0' + (Routine & 7)));
    SlStage('Z');
    StallMs(1000);          /* as the HAL: writes the disk is still completing */
    if (KeGetCurrentIrql() < DISPATCH_LEVEL) {
        KeRaiseIrql(DISPATCH_LEVEL, &old);
        raised = TRUE;
    }
    SlQuiesce();
    RmStage('Q');
    RmStage('C');
    WRITE_PORT_UCHAR((PUCHAR)0xCF9, 0x0A);
    KeStallExecutionProcessor(50);
    WRITE_PORT_UCHAR((PUCHAR)0xCF9, 0x0E);
    StallMs(500);
    if (raised) KeLowerIrql(old);
}
#endif

#ifndef USOSRST_NT4
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
#endif

/* ------------------------------------------------------------------ */
/* Text-mode Setup restart                                             */
/* ------------------------------------------------------------------ */

#ifdef USOSRST_POWEROFF
/* One GPE block: the first half status (write 1 to clear), the second
   half enable. */
static VOID
AcpiGpeOff(ULONG Block, UCHAR Length)
{
    ULONG i, half = Length / 2;
    if (Block == 0 || half == 0) return;
    for (i = 0; i < half; i++) WRITE_PORT_UCHAR((PUCHAR)(Block + half + i), 0);
    for (i = 0; i < half; i++) WRITE_PORT_UCHAR((PUCHAR)(Block + i), 0xFF);
}

/* PM1 event block: PM1_STS at the start, PM1_EN at PM1_EVT_LEN / 2. */
static VOID
AcpiPm1Off(ULONG Block)
{
    if (Block == 0) return;
    if (g_Pm1EvtLen >= 4) WRITE_PORT_USHORT((PUSHORT)(Block + g_Pm1EvtLen / 2), 0x0100);   /* PWRBTN_EN only */
    WRITE_PORT_USHORT((PUSHORT)Block, 0xC731);
}

/* PCI power management capability of every quiesced device (NVMe, xHCI,
   NIC, found by SlScanPci): PMCSR PME_En (bit 8) off, PME_Status (bit 15,
   write 1 to clear) cleared, power state bits kept. */
static VOID
PciPmeOff(VOID)
{
    ULONG d, cap, n, id;
    for (d = 0; d < g_SlDevs; d++) {
        if (!(SlCfgRead(g_SlDev[d].Cfg, 4) & 0x00100000)) continue;     /* no capability list */
        cap = SlCfgRead(g_SlDev[d].Cfg, 0x34) & 0xFC;
        for (n = 0; cap >= 0x40 && n < 48; n++) {
            id = SlCfgRead(g_SlDev[d].Cfg, cap);
            if ((id & 0xFF) == 0x01) {
                ULONG pmcsr = SlCfgRead(g_SlDev[d].Cfg, cap + 4) & 0xFFFF;
                WRITE_PORT_ULONG((PULONG)0xCF8, g_SlDev[d].Cfg | (cap + 4));
                WRITE_PORT_USHORT((PUSHORT)0xCFC, (USHORT)((pmcsr & ~0x0100UL) | 0x8000UL));
                break;
            }
            cap = (id >> 8) & 0xFC;
        }
    }
    WRITE_PORT_ULONG((PULONG)0xCF8, 0);
}

/* HalPowerDownRoutine (NT 4.0 NtShutdownSystem(ShutdownPowerOff), after the
   file systems and disks are flushed): the shutdown log, the device quiesce
   (NVMe shutdown notification, xHCI halt), then S5 the ACPI way: WAK_STS
   cleared in PM1 status, SLP_TYP = \_S5 value and SLP_EN in PM1a_CNT (and
   PM1b_CNT when the FADT has one), SCI_EN and the other bits kept. The NT
   4.0 HALs have no ACPI power-off (the machine only stops with "It is now
   safe to turn off your computer"). Returns only if the machine still runs:
   the caller then goes on to the HAL. */
static VOID
AcpiPowerOff(VOID)
{
    KIRQL old = PASSIVE_LEVEL;
    BOOLEAN raised = FALSE;
    USHORT cnt;

    if (g_S5State != 'o' || g_Pm1aCnt == 0) return;
    SlStage('F');
    SlStage('5');
    SlStage('Z');
    StallMs(1000);          /* as for a restart: writes the disk is still completing */
    if (KeGetCurrentIrql() < DISPATCH_LEVEL) {
        KeRaiseIrql(DISPATCH_LEVEL, &old);
        raised = TRUE;
    }
    SlQuiesce();
    RmStage('Q');
    RmStage('O');
    /* As Linux's acpi_enter_sleep_state / hw_legacy_sleep for S5, nothing
       left to wake the machine (X470 2026-10-29: it came straight back):
       every GPE disabled and its status cleared, the fixed events disabled
       except the power button, every fixed status cleared (TMR, BM, GBL,
       PWRBTN, SLPBTN, RTC, PCIEXP_WAKE, WAK), the RTC alarm interrupt off,
       PME_En off and PME_Status cleared on the quiesced PCI devices. */
    AcpiGpeOff(g_Gpe0, g_Gpe0Len);
    AcpiGpeOff(g_Gpe1, g_Gpe1Len);
    AcpiPm1Off(g_Pm1aEvt);
    AcpiPm1Off(g_Pm1bEvt);
    WRITE_PORT_UCHAR((PUCHAR)0x70, 0x0B);
    WRITE_PORT_UCHAR((PUCHAR)0x71, (UCHAR)(READ_PORT_UCHAR((PUCHAR)0x71) & ~0x20));
    WRITE_PORT_UCHAR((PUCHAR)0x70, 0x0C);
    (VOID)READ_PORT_UCHAR((PUCHAR)0x71);                         /* clears the RTC flags */
    PciPmeOff();
    if (g_Pm1bCnt) {
        cnt = READ_PORT_USHORT((PUSHORT)g_Pm1bCnt);
        cnt = (USHORT)((cnt & ~(USHORT)(7 << 10)) | ((g_S5b & 7) << 10));
        WRITE_PORT_USHORT((PUSHORT)g_Pm1bCnt, cnt);
        WRITE_PORT_USHORT((PUSHORT)g_Pm1bCnt, (USHORT)(cnt | (1 << 13)));
    }
    cnt = READ_PORT_USHORT((PUSHORT)g_Pm1aCnt);
    cnt = (USHORT)((cnt & ~(USHORT)(7 << 10)) | ((g_S5a & 7) << 10));
    WRITE_PORT_USHORT((PUSHORT)g_Pm1aCnt, cnt);
    WRITE_PORT_USHORT((PUSHORT)g_Pm1aCnt, (USHORT)(cnt | (1 << 13)));
    StallMs(2000);
    if (raised) KeLowerIrql(old);
}
#endif

/* setupdd.sys calls this instead of the HAL's HalReturnToFirmware (see
   RedirectSetupRestart). */
static VOID NTAPI
SetupReturnToFirmware(IN ULONG Routine)
{
    static CHAR text[] = "usosrst: text-mode Setup restart (FADT reset register, CF9h, 8042)";

    if (Routine == USOS_HAL_REBOOT_ROUTINE || Routine == USOS_HAL_RESTART_ROUTINE) {
        ShowRow(ROW_STOP, text, sizeof(text) - 1, 0x1F00);
#ifdef USOSRST_SHUTLOG
        SlRestart(Routine);         /* log, quiesce, full reset (NT 3.51) */
#else
        /* A pause before the reset, as the HAL has before its 8042 pulse,
           for writes the disk is still completing. */
        StallMs(1000);
#endif
        ResetMachine();
    }
#ifdef USOSRST_POWEROFF
    if (Routine == USOS_HAL_POWERDOWN_ROUTINE) AcpiPowerOff();
#endif
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
#ifndef USOSRST_NT4N
    PMDL mdl;
#endif
    PULONG writable;

#ifdef USOSRST_NT4N
    /* NT 4.0 maps the kernel image with large (4 MB) pages: there is no PTE
       behind the kernel's import slots, so MmBuildMdlForNonPagedPool cannot
       find their page (X470 2026-10-29: handler=off, every restart went the
       HAL's way and ended in a triple fault; power-off too). The physical
       address comes from MmGetPhysicalAddress, which walks large pages, and
       a second (cached, as the image) mapping takes the write. */
    {
        PHYSICAL_ADDRESS pa = MmGetPhysicalAddress(Slot);
        if (pa.QuadPart == 0) return FALSE;
        writable = (PULONG)MmMapIoSpace(pa, sizeof(ULONG), MmCached);
        if (writable == NULL) return FALSE;
        InterlockedExchange((PLONG)writable, (LONG)Value);
        MmUnmapIoSpace(writable, sizeof(ULONG));
        return (BOOLEAN)(*Slot == Value);
    }
#else
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
#endif
}

/* 'o': redirected; '-': no setupdd.sys (not text mode); 'x': setupdd.sys
   without a matching import slot, or the write failed. Every import address
   table of setupdd.sys is searched for the HAL's HalReturnToFirmware
   address (the value our own import of it holds), so no import names or
   hint tables are needed. */
/* Points every import slot of the image at Base that holds Target at
   Replacement. Returns the number of slots changed, or -1 when the image
   headers are unusable or a write failed. */
static LONG
PatchImports(PUCHAR Base, ULONG Target, ULONG Replacement)
{
    PUCHAR nt;
    ULONG size, rva, dir, dirSize, i;
    LONG found = 0;

    if (!MmIsAddressValid(Base + 0x3C)) return -1;
    nt = Base + *(PULONG)(Base + 0x3C);
    if (!MmIsAddressValid(nt) || !MmIsAddressValid(nt + 0x87) || *(PULONG)nt != 0x00004550) return -1;
    size = *(PULONG)(nt + 0x50);                  /* SizeOfImage */
    dir = *(PULONG)(nt + 0x80);                   /* import directory */
    dirSize = *(PULONG)(nt + 0x84);
    if (dir == 0 || dirSize < 20 || dir >= size || dirSize > size - dir) return -1;
    for (i = 0; i + 20 <= dirSize; i += 20) {
        PUCHAR desc = Base + dir + i;
        PULONG slot;
        if (!MmIsAddressValid(desc) || !MmIsAddressValid(desc + 19)) break;
        rva = *(PULONG)(desc + 16);               /* FirstThunk */
        if (rva == 0 && *(PULONG)(desc + 12) == 0) break;
        if (rva == 0 || rva >= size) continue;
        for (slot = (PULONG)(Base + rva); (PUCHAR)slot + 4 <= Base + size && MmIsAddressValid(slot) && *slot != 0; slot++) {
            if (*slot != Target) continue;
            if (!WriteSlot(slot, Replacement)) return -1;
            found++;
        }
    }
    return found;
}

static CHAR
RedirectSetupRestart(VOID)
{
    PUCHAR base;
    LONG n;

    base = FindModule("setupdd.sys");
    if (base == NULL) return '-';
    g_HalReturnToFirmware = (USOS_RETURN_TO_FIRMWARE)(ULONG)HalReturnToFirmware;
    n = PatchImports(base, (ULONG)HalReturnToFirmware, (ULONG)SetupReturnToFirmware);
    return (CHAR)(n > 0 ? 'o' : 'x');
}

#ifdef USOSRST_NT4
/* NT 4.0 has no last-chance shutdown notification. Its kernel restarts by
   calling HalReturnToFirmware(HalRebootRoutine) after the file systems and
   disks are flushed, so the kernel's import slot for it is pointed at the
   same routine as setupdd.sys's: reboot/restart run the reset sequence,
   every other routine (and a reset that did not happen) goes on to the
   HAL. Unlike the 2000 handler this stays on after Setup: only restarts
   are taken over, and the NT 4.0 HALs restart through the 8042 alone.
   TRUE when at least one slot was redirected. */
static BOOLEAN
RedirectKernelRestart(VOID)
{
    static const char *kernels[2] = { "ntoskrnl.exe", "ntkrnlmp.exe" };
    PUCHAR kernel = NULL;
    ULONG i;

    for (i = 0; i < 2 && kernel == NULL; i++) kernel = FindModule(kernels[i]);
    if (kernel == NULL) return FALSE;
    g_HalReturnToFirmware = (USOS_RETURN_TO_FIRMWARE)(ULONG)HalReturnToFirmware;
#ifdef USOSRST_INLINE
    g_KernelFound = 1;
    g_KernelPatch = PatchImports(kernel, (ULONG)HalReturnToFirmware, (ULONG)SetupReturnToFirmware);
    return (BOOLEAN)(g_KernelPatch > 0);
#else
    return (BOOLEAN)(PatchImports(kernel, (ULONG)HalReturnToFirmware, (ULONG)SetupReturnToFirmware) > 0);
#endif
}

#ifdef USOSRST_INLINE
/* The HAL's own HalReturnToFirmware, entered through the jump HookHalInline
   puts at its start (the kernel's import slot could not be redirected:
   X470 2026-10-29, handler=off with 1.9 and 1.10, every restart and the
   power-off ended in the HAL's triple fault). The HAL routine is gone
   then, so every routine is handled here: restart/reboot the full reset,
   power-down ACPI S5, halt and anything else stop the processor (power-off
   first for HalHaltRoutine is not wanted: NT 4.0 only uses it on request). */
static VOID NTAPI
InlineReturnToFirmware(IN ULONG Routine)
{
    if (Routine == USOS_HAL_POWERDOWN_ROUTINE) {
        AcpiPowerOff();
    } else if (Routine != 0) {
        SlRestart(Routine);
        ResetMachine();
    }
    _disable();
    for (;;) {
        __asm hlt
    }
}

/* A 5-byte jmp rel32 over the first bytes of the HAL's HalReturnToFirmware
   (its address is our own import of it). Written byte by byte, the jump
   opcode last, through each byte's physical address (the HAL may sit in a
   large page or a read-only one); nothing calls the routine while the
   boot drivers load. TRUE when the jump reads back. */
static BOOLEAN
HookHalInline(VOID)
{
    PUCHAR f = (PUCHAR)(ULONG)HalReturnToFirmware;
    UCHAR code[5];
    LONG rel;
    ULONG i;
    if (!MmIsAddressValid(f) || !MmIsAddressValid(f + 4)) return FALSE;
    rel = (LONG)((ULONG)InlineReturnToFirmware - ((ULONG)f + 5));
    code[0] = 0xE9;
    RtlCopyMemory(code + 1, &rel, 4);
    for (i = 5; i-- > 0; ) {
        PHYSICAL_ADDRESS pa = MmGetPhysicalAddress(f + i);
        PUCHAR w;
        if (pa.QuadPart == 0) return FALSE;
        w = (PUCHAR)MmMapIoSpace(pa, 1, MmCached);
        if (w == NULL) return FALSE;
        *(volatile UCHAR *)w = code[i];
        MmUnmapIoSpace(w, 1);
    }
    return (BOOLEAN)(RtlCompareMemory(f, code, 5) == 5);
}
#endif

/* VGA window (1.5). CSMWrap's E820 map marks A0000h-FFFFFh as reserved;
   the NT 4.0 loader passes that on and the kernel puts it under
   HARDWARE\RESOURCEMAP\System Resources\Reserved as device-exclusive
   memory. videoprt then gets a conflict for the VGA window (A0000h,
   128 KB) that vga.sys claims, VgaStart/VgaSave fail to start and Win32k
   stops with C0000143 "DISPLAY DRIVER.DLL". On SeaBIOS proper the window
   is not in the map at all. A0000h-BFFFFh is never RAM or firmware, so
   it is cut out of every memory range in the .Translated and .Raw lists
   of that key, before the video drivers load (this driver is a boot
   driver). Returns 'o' when a range was cut, '-' when none overlapped,
   'x' on an error. */
#define USOS_VGA_LOW   0xA0000
#define USOS_VGA_HIGH  0xC0000
static UCHAR g_ResIn[1024], g_ResOut[1024 + 64 * sizeof(CM_PARTIAL_RESOURCE_DESCRIPTOR)];

static CHAR
CutVgaFromList(HANDLE Key, PCWSTR ValueName)
{
    UNICODE_STRING name;
    PKEY_VALUE_PARTIAL_INFORMATION info = (PKEY_VALUE_PARTIAL_INFORMATION)g_ResIn;
    PUCHAR in, inEnd, out, outEnd;
    ULONG length, full, fullCount, part, partCount, cuts = 0;
    PCM_FULL_RESOURCE_DESCRIPTOR fin, fout;
    PCM_PARTIAL_RESOURCE_DESCRIPTOR pin, pout;

    RtlInitUnicodeString(&name, ValueName);
    if (!NT_SUCCESS(ZwQueryValueKey(Key, &name, KeyValuePartialInformation, info, sizeof(g_ResIn), &length)))
        return '-';
    if (info->Type != REG_RESOURCE_LIST || info->DataLength < sizeof(ULONG)) return 'x';
    in = info->Data;
    inEnd = in + info->DataLength;
    out = g_ResOut;
    outEnd = g_ResOut + sizeof(g_ResOut);
    fullCount = ((PCM_RESOURCE_LIST)in)->Count;
    *(PULONG)out = fullCount;
    in += sizeof(ULONG);
    out += sizeof(ULONG);
    for (full = 0; full < fullCount; full++) {
        ULONG header = FIELD_OFFSET(CM_FULL_RESOURCE_DESCRIPTOR, PartialResourceList.PartialDescriptors);
        if (in + header > inEnd || out + header > outEnd) return 'x';
        fin = (PCM_FULL_RESOURCE_DESCRIPTOR)in;
        fout = (PCM_FULL_RESOURCE_DESCRIPTOR)out;
        RtlCopyMemory(fout, fin, header);
        partCount = fin->PartialResourceList.Count;
        in += header;
        out += header;
        fout->PartialResourceList.Count = 0;
        for (part = 0; part < partCount; part++) {
            ULONG start, end;
            pin = (PCM_PARTIAL_RESOURCE_DESCRIPTOR)in;
            if (in + sizeof(*pin) > inEnd || out + 2 * sizeof(*pin) > outEnd) return 'x';
            in += sizeof(*pin);
            start = pin->u.Memory.Start.LowPart;
            end = start + pin->u.Memory.Length;
            if (pin->Type != CmResourceTypeMemory || pin->u.Memory.Start.HighPart != 0 ||
                end <= USOS_VGA_LOW || start >= USOS_VGA_HIGH) {
                RtlCopyMemory(out, pin, sizeof(*pin));
                out += sizeof(*pin);
                fout->PartialResourceList.Count++;
                continue;
            }
            cuts++;
            if (start < USOS_VGA_LOW) {          /* the part below A0000h */
                pout = (PCM_PARTIAL_RESOURCE_DESCRIPTOR)out;
                RtlCopyMemory(pout, pin, sizeof(*pin));
                pout->u.Memory.Length = USOS_VGA_LOW - start;
                out += sizeof(*pin);
                fout->PartialResourceList.Count++;
            }
            if (end > USOS_VGA_HIGH) {           /* the part from C0000h up */
                pout = (PCM_PARTIAL_RESOURCE_DESCRIPTOR)out;
                RtlCopyMemory(pout, pin, sizeof(*pin));
                pout->u.Memory.Start.LowPart = USOS_VGA_HIGH;
                pout->u.Memory.Length = end - USOS_VGA_HIGH;
                out += sizeof(*pin);
                fout->PartialResourceList.Count++;
            }
        }
    }
    if (cuts == 0) return '-';
    if (!NT_SUCCESS(ZwSetValueKey(Key, &name, 0, REG_RESOURCE_LIST, g_ResOut, (ULONG)(out - g_ResOut))))
        return 'x';
    return 'o';
}

static CHAR
FreeVgaWindow(VOID)
{
    UNICODE_STRING keyName;
    OBJECT_ATTRIBUTES oa;
    HANDLE key;
    CHAR t, r;

    RtlInitUnicodeString(&keyName, L"\\Registry\\Machine\\HARDWARE\\RESOURCEMAP\\System Resources\\Reserved");
    InitializeObjectAttributes(&oa, &keyName, OBJ_CASE_INSENSITIVE, NULL, NULL);
    if (!NT_SUCCESS(ZwOpenKey(&key, KEY_QUERY_VALUE | KEY_SET_VALUE, &oa))) return '-';
    t = CutVgaFromList(key, L".Translated");
    r = CutVgaFromList(key, L".Raw");
    ZwClose(key);
    if (t == 'x' || r == 'x') return 'x';
    return (CHAR)(t == 'o' || r == 'o' ? 'o' : '-');
}
#endif

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
/* Clock diagnostics and the HPET LegacyReplacement experiment         */
/* ------------------------------------------------------------------ */

static PCHAR PutDec(PCHAR p, PCHAR end, ULONG v, ULONG digits);

static ULONGLONG g_Tsc0;            /* TSC at load */
static ULONG g_TscPer100ms;         /* TSC cycles in 100 ms (KeStallExecutionProcessor) */
static ULONG g_HpetCfg = 0xFFFFFFFF, g_HpetT0 = 0xFFFFFFFF, g_HpetBase;
static BOOLEAN g_HpetRuns, g_HpetLegCleared, g_HpetWanted;

/* Option Want (upper case) in the load options, or the Parameters value
   Value = 1. */
static BOOLEAN
OptionWanted(IN PUNICODE_STRING RegistryPath, IN const WCHAR *Want, IN PCWSTR Value)
{
    ULONG wantLen = 0;
    UNICODE_STRING name;
    OBJECT_ATTRIBUTES oa;
    HANDLE key;
    UCHAR buffer[sizeof(KEY_VALUE_PARTIAL_INFORMATION) + 512];
    PKEY_VALUE_PARTIAL_INFORMATION info = (PKEY_VALUE_PARTIAL_INFORMATION)buffer;
    ULONG length, i, j, n;
    BOOLEAN result = FALSE;

    while (Want[wantLen]) wantLen++;
    RtlInitUnicodeString(&name, L"\\Registry\\Machine\\SYSTEM\\CurrentControlSet\\Control");
    InitializeObjectAttributes(&oa, &name, OBJ_CASE_INSENSITIVE, NULL, NULL);
    if (NT_SUCCESS(ZwOpenKey(&key, KEY_READ, &oa))) {
        RtlInitUnicodeString(&name, L"SystemStartOptions");
        if (NT_SUCCESS(ZwQueryValueKey(key, &name, KeyValuePartialInformation, info, sizeof(buffer) - 2, &length)) &&
            info->Type == REG_SZ) {
            PWCHAR text = (PWCHAR)info->Data;
            n = info->DataLength / 2;
            for (i = 0; i + wantLen <= n && !result; i++) {
                for (j = 0; j < wantLen; j++) {
                    WCHAR c = text[i + j];
                    if (c >= 'a' && c <= 'z') c = (WCHAR)(c - 32);
                    if (c != Want[j]) break;
                }
                if (j == wantLen) result = TRUE;
            }
        }
        ZwClose(key);
    }
    if (result || RegistryPath == NULL) return result;
    {
        WCHAR path[256];
        UNICODE_STRING full;
        full.Buffer = path;
        full.Length = 0;
        full.MaximumLength = sizeof(path);
        if (!NT_SUCCESS(RtlAppendUnicodeStringToString(&full, RegistryPath)) ||
            !NT_SUCCESS(RtlAppendUnicodeToString(&full, L"\\Parameters"))) return FALSE;
        InitializeObjectAttributes(&oa, &full, OBJ_CASE_INSENSITIVE, NULL, NULL);
        if (!NT_SUCCESS(ZwOpenKey(&key, KEY_READ, &oa))) return FALSE;
        RtlInitUnicodeString(&name, Value);
        if (NT_SUCCESS(ZwQueryValueKey(key, &name, KeyValuePartialInformation, info, sizeof(buffer), &length)) &&
            info->Type == REG_DWORD && info->DataLength == sizeof(ULONG) && *(PULONG)info->Data == 1) result = TRUE;
        ZwClose(key);
    }
    return result;
}

/* HPET: general configuration, timer 0, a running counter; clears
   LegacyReplacement when asked. */
static VOID
ProbeHpet(BOOLEAN ClearLegacy)
{
    PUCHAR t, h;
    PHYSICAL_ADDRESS pa;
    ULONG c0, c1;

    if (g_HpetTable == 0) return;
    t = MapPhys(g_HpetTable, 56);
    if (t == NULL) return;
    if (*(PULONG)(t + 4) >= 56 && t[40] == 0 && *(PULONG)(t + 48) == 0) g_HpetBase = *(PULONG)(t + 44);
    MmUnmapIoSpace(t, 56);
    if (g_HpetBase == 0) return;
    pa.QuadPart = g_HpetBase;
    h = (PUCHAR)MmMapIoSpace(pa, 0x400, MmNonCached);
    if (h == NULL) return;
    g_HpetCfg = READ_REGISTER_ULONG((PULONG)(h + 0x10));
    g_HpetT0 = READ_REGISTER_ULONG((PULONG)(h + 0x100));
    c0 = READ_REGISTER_ULONG((PULONG)(h + 0xF0));
    KeStallExecutionProcessor(100);
    c1 = READ_REGISTER_ULONG((PULONG)(h + 0xF0));
    g_HpetRuns = (BOOLEAN)(c0 != c1);
    if (ClearLegacy && (g_HpetCfg & 2)) {
        WRITE_REGISTER_ULONG((PULONG)(h + 0x10), g_HpetCfg & ~2UL);
        g_HpetLegCleared = (BOOLEAN)((READ_REGISTER_ULONG((PULONG)(h + 0x10)) & 2) == 0);
    }
    MmUnmapIoSpace(h, 0x400);
}

/* I/O APIC redirection entry (low dword, bits 0-16) of Pin of the I/O APIC
   with GSI base 0, from the MADT. FFFFFFFF: not found. */
static ULONG g_IoApic;
static VOID
FindIoApic(VOID)
{
    PUCHAR m;
    ULONG len, off;

    if (g_MadtTable == 0) return;
    m = MapPhys(g_MadtTable, 8);
    if (m == NULL) return;
    len = *(PULONG)(m + 4);
    MmUnmapIoSpace(m, 8);
    if (len < 44 || len > 0x4000) return;
    m = MapPhys(g_MadtTable, len);
    if (m == NULL) return;
    for (off = 44; off + 2 <= len && m[off + 1] >= 2 && off + m[off + 1] <= len; off += m[off + 1]) {
        if (m[off] == 1 && m[off + 1] >= 12 && *(PULONG)(m + off + 8) == 0) {
            g_IoApic = *(PULONG)(m + off + 4);
            break;
        }
    }
    MmUnmapIoSpace(m, len);
}

static VOID
ReadIoApic(PULONG Rte, const UCHAR *Pins, ULONG Count)
{
    PHYSICAL_ADDRESS pa;
    volatile ULONG *io;
    ULONG i;

    for (i = 0; i < Count; i++) Rte[i] = 0xFFFFFFFF;
    if (g_IoApic == 0) return;
    pa.QuadPart = g_IoApic;
    io = (volatile ULONG *)MmMapIoSpace(pa, 0x20, MmNonCached);
    if (io == NULL) return;
    _disable();
    for (i = 0; i < Count; i++) {
        io[0] = 0x10 + 2 * Pins[i];
        Rte[i] = io[4] & 0x1FFFF;
    }
    _enable();
    MmUnmapIoSpace((PVOID)io, 0x20);
}

static UCHAR
CmosRead(UCHAR Index)
{
    WRITE_PORT_UCHAR((PUCHAR)0x70, Index);
    return READ_PORT_UCHAR((PUCHAR)0x71);
}

/* Rows 9-10, once at load (text mode). */
static VOID
ShowClock(VOID)
{
    static const UCHAR pins[4] = { 0, 2, 8, 9 };
    CHAR line[80];
    PCHAR p, end = line + 80;
    ULONG rte[4], i, lvtT = 0xFFFFFFFF, lint0 = 0xFFFFFFFF, lint1 = 0xFFFFFFFF, lapicInit = 0;
    UCHAR pitStatus, rA, rB, cen, yr;
    USHORT pit0, pit1;
    PHYSICAL_ADDRESS pa;
    ULONGLONG apicBase;
    volatile ULONG *lapic;

    /* PIT channel 0: read-back status, then the count twice */
    _disable();
    WRITE_PORT_UCHAR((PUCHAR)0x43, 0xE2);
    pitStatus = READ_PORT_UCHAR((PUCHAR)0x40);
    WRITE_PORT_UCHAR((PUCHAR)0x43, 0x00);
    pit0 = READ_PORT_UCHAR((PUCHAR)0x40);
    pit0 |= (USHORT)(READ_PORT_UCHAR((PUCHAR)0x40) << 8);
    KeStallExecutionProcessor(50);
    WRITE_PORT_UCHAR((PUCHAR)0x43, 0x00);
    pit1 = READ_PORT_UCHAR((PUCHAR)0x40);
    pit1 |= (USHORT)(READ_PORT_UCHAR((PUCHAR)0x40) << 8);
    rA = CmosRead(0x0A);
    rB = CmosRead(0x0B);
    cen = CmosRead(0x32);
    yr = CmosRead(0x09);
    _enable();

    FindIoApic();
    ReadIoApic(rte, pins, 4);

    apicBase = __readmsr(0x1B);
    if (apicBase & 0x800) {
        pa.QuadPart = (LONGLONG)(apicBase & 0xFFFFF000);
        lapic = (volatile ULONG *)MmMapIoSpace(pa, 0x400, MmNonCached);
        if (lapic != NULL) {
            lvtT = lapic[0x320 / 4];
            lint0 = lapic[0x350 / 4];
            lint1 = lapic[0x360 / 4];
            lapicInit = lapic[0x380 / 4];
            MmUnmapIoSpace((PVOID)lapic, 0x400);
        }
    }

    p = PutStr(line, end, "CLK tsc:");
    p = PutDec(p, end, g_TscPer100ms / 100000, 4);
    p = PutStr(p, end, "MHz hpet:");
    if (g_HpetBase) {
        p = PutHex(p, end, g_HpetBase, 8);
        p = PutStr(p, end, " cfg:");
        p = PutHex(p, end, g_HpetCfg, 8);
        p = PutStr(p, end, " t0:");
        p = PutHex(p, end, g_HpetT0, 8);
        p = PutStr(p, end, g_HpetRuns ? " run" : " stop");
        p = PutStr(p, end, " leg:");
        p = PutHex(p, end, (g_HpetCfg >> 1) & 1, 1);
        p = PutStr(p, end, g_HpetLegCleared ? ">0" : g_HpetWanted ? ">?" : "");
    } else {
        p = PutStr(p, end, g_HpetTable ? "nobase" : "none");
    }
    p = PutStr(p, end, " io:");
    p = PutHex(p, end, g_IoApic, 8);
    ShowRow(ROW_CLOCK, line, (ULONG)(p - line), 0x1F00);

    p = PutStr(line, end, "CLK pit:");
    p = PutHex(p, end, pitStatus, 2);
    p = PutStr(p, end, pit0 != pit1 ? "+" : "=");          /* counting or not */
    p = PutStr(p, end, " rte:");
    for (i = 0; i < 4; i++) {
        if (i) p = PutStr(p, end, " ");
        p = PutHex(p, end, rte[i], 5);
    }
    p = PutStr(p, end, " lvt:");
    p = PutHex(p, end, lvtT, 5);
    p = PutStr(p, end, " ");
    p = PutHex(p, end, lint0, 5);
    p = PutStr(p, end, " ");
    p = PutHex(p, end, lint1, 5);
    p = PutStr(p, end, lapicInit ? " lt+" : " lt0");
    p = PutStr(p, end, " rtc:");
    p = PutHex(p, end, rA, 2);
    p = PutStr(p, end, " ");
    p = PutHex(p, end, rB, 2);
    p = PutStr(p, end, " ");
    p = PutHex(p, end, cen, 2);
    p = PutHex(p, end, yr, 2);
    ShowRow(ROW_CLOCK + 1, line, (ULONG)(p - line), 0x1F00);
}

/* TSC rate against KeStallExecutionProcessor (the HAL calibrates it with
   the PIT counter, without interrupts). */
static VOID
CalibrateTsc(VOID)
{
    ULONGLONG t1;
    ULONG i;

    g_Tsc0 = __rdtsc();
    for (i = 0; i < 2; i++) KeStallExecutionProcessor(50000);
    t1 = __rdtsc();
    g_TscPer100ms = (ULONG)(t1 - g_Tsc0);
}

/* Seconds since load from the TSC. */
static ULONG
WallSeconds(VOID)
{
    ULONG div = (ULONG)(((ULONGLONG)g_TscPer100ms * 10) >> 16);
    if (div == 0) return 0;
    return (ULONG)((__rdtsc() - g_Tsc0) >> 16) / div;
}

/* ------------------------------------------------------------------ */
/* RTC fix (1.4, opt-in: USOSRTCFIX / Parameters\RtcFix = 1)           */
/* ------------------------------------------------------------------ */

/* Exported by every NT HAL and kernel; the WDK 7.1 headers do not declare
   them for drivers. */
__declspec(dllimport) BOOLEAN NTAPI HalQueryRealTimeClock(OUT PTIME_FIELDS TimeFields);
__declspec(dllimport) BOOLEAN NTAPI HalSetRealTimeClock(IN PTIME_FIELDS TimeFields);
#ifndef USOSRST_NT351
NTSYSAPI NTSTATUS NTAPI ZwSetSystemTime(IN PLARGE_INTEGER SystemTime, OUT PLARGE_INTEGER PreviousTime OPTIONAL);
#endif

typedef BOOLEAN (NTAPI *USOS_RTC_ROUTINE)(IN OUT PTIME_FIELDS TimeFields);
static USOS_RTC_ROUTINE g_HalQueryRtc;  /* the HAL's routine (fallback) */
static volatile LONG g_RtcQueries, g_RtcWritesSkipped;
static CHAR g_RtcState = '-';           /* load line: '-' off, 'o' fixed, 'x' failed */

#pragma pack(push, 1)
typedef struct _USOS_RTC_DIAG {
    ULONG Version;                      /* 0x00000104 */
    UCHAR Raw[7];                       /* CMOS 0,2,4,6,7,8,9: s m h wday day month year */
    UCHAR RegA, RegB, CenturyIndex, CenturyByte, HalOk, OwnOk, Pad;
    TIME_FIELDS Hal;                    /* what HalQueryRealTimeClock returned */
    TIME_FIELDS Own;                    /* our decode */
    LARGE_INTEGER Before;               /* system time at load */
    LARGE_INTEGER After;                /* system time after the fix */
    LONG QuerySlots, SetSlots;          /* ntoskrnl import slots redirected */
    NTSTATUS SetStatus;                 /* ZwSetSystemTime */
} USOS_RTC_DIAG;
#pragma pack(pop)

static ULONG
RtcBcd(UCHAR RegB, UCHAR v)
{
    return (RegB & 0x04) ? v : (ULONG)((v >> 4) * 10 + (v & 0x0F));
}

/* Reads the CMOS clock and decodes it by register B (binary or BCD, 12 or
   24 hours). The century comes from the FADT CENTURY byte when it holds a
   plausible value, else 19xx/20xx by the year. Raw (12 bytes, optional)
   receives the registers. FALSE: no stable read or an impossible date. */
static BOOLEAN
ReadRtc(OUT PTIME_FIELDS Time, OUT PUCHAR Raw OPTIONAL)
{
    static const UCHAR idx[7] = { 0x00, 0x02, 0x04, 0x06, 0x07, 0x08, 0x09 };
    UCHAR a[7], b[7], rA = 0, rB = 0, cen = 0xFF;
    ULONG tries, i, year, hour, c;
    BOOLEAN stable = FALSE;

    for (tries = 0; tries < 100 && !stable; tries++) {
        _disable();
        rA = CmosRead(0x0A);
        if (rA & 0x80) {                        /* update in progress (< 2 ms) */
            _enable();
            KeStallExecutionProcessor(100);
            continue;
        }
        for (i = 0; i < 7; i++) a[i] = CmosRead(idx[i]);
        rB = CmosRead(0x0B);
        if (g_CenturyIndex >= 0x0E && g_CenturyIndex < 0x80) cen = CmosRead(g_CenturyIndex);
        for (i = 0; i < 7; i++) b[i] = CmosRead(idx[i]);
        _enable();
        stable = (BOOLEAN)(RtlCompareMemory(a, b, 7) == 7);
    }
    if (Raw != NULL) {
        for (i = 0; i < 7; i++) Raw[i] = a[i];
        Raw[7] = rA;
        Raw[8] = rB;
        Raw[9] = g_CenturyIndex;
        Raw[10] = cen;
    }
    if (!stable) return FALSE;

    year = RtcBcd(rB, a[6]);
    c = (cen != 0xFF) ? RtcBcd(rB, cen) : 0;
    if (c < 19 || c > 21) c = (year < 80) ? 20 : 19;
    if (rB & 0x02) {
        hour = RtcBcd(rB, a[2]);
    } else {                                    /* 12-hour mode, bit 7 = PM */
        hour = RtcBcd(rB, (UCHAR)(a[2] & 0x7F)) % 12;
        if (a[2] & 0x80) hour += 12;
    }
    Time->Year = (CSHORT)(c * 100 + year);
    Time->Month = (CSHORT)RtcBcd(rB, a[5]);
    Time->Day = (CSHORT)RtcBcd(rB, a[4]);
    Time->Hour = (CSHORT)hour;
    Time->Minute = (CSHORT)RtcBcd(rB, a[1]);
    Time->Second = (CSHORT)RtcBcd(rB, a[0]);
    Time->Milliseconds = 0;
    Time->Weekday = (CSHORT)((RtcBcd(rB, a[3]) + 6) % 7);  /* CMOS 1 = Sunday */
    return (BOOLEAN)(year <= 99 && Time->Month >= 1 && Time->Month <= 12 && Time->Day >= 1 && Time->Day <= 31 &&
                     hour <= 23 && Time->Minute <= 59 && Time->Second <= 59);
}

/* ntoskrnl calls these instead of the HAL's routines once FixRtc ran. */
static BOOLEAN NTAPI
UsosQueryRtc(OUT PTIME_FIELDS Time)
{
    InterlockedIncrement(&g_RtcQueries);
    if (ReadRtc(Time, NULL)) return TRUE;
    return g_HalQueryRtc(Time);
}

/* The CMOS clock is never written while the fix is active: the HAL would
   encode it the same wrong way it decodes it. */
static BOOLEAN NTAPI
UsosSetRtc(IN PTIME_FIELDS Time)
{
    UNREFERENCED_PARAMETER(Time);
    InterlockedIncrement(&g_RtcWritesSkipped);
    return TRUE;
}

static VOID
FixRtc(IN PUNICODE_STRING RegistryPath)
{
    static const char *kernels[4] = { "ntoskrnl.exe", "ntkrnlmp.exe", "ntkrnlpa.exe", "ntkrpamp.exe" };
    USOS_RTC_DIAG d;
    UCHAR raw[11];
    LARGE_INTEGER local, utc;
    PUCHAR kernel = NULL;
    ULONG i;

    RtlZeroMemory(&d, sizeof(d));
    d.Version = 0x104;
    d.SetStatus = STATUS_NOT_SUPPORTED;
    KeQuerySystemTime(&d.Before);
    g_HalQueryRtc = (USOS_RTC_ROUTINE)(ULONG)HalQueryRealTimeClock;
    d.HalOk = HalQueryRealTimeClock(&d.Hal);
    d.OwnOk = ReadRtc(&d.Own, raw);
    for (i = 0; i < 7; i++) d.Raw[i] = raw[i];
    d.RegA = raw[7];
    d.RegB = raw[8];
    d.CenturyIndex = raw[9];
    d.CenturyByte = raw[10];

    for (i = 0; i < 4 && kernel == NULL; i++) kernel = FindModule(kernels[i]);
    if (kernel != NULL && d.OwnOk) {
        d.SetSlots = PatchImports(kernel, (ULONG)HalSetRealTimeClock, (ULONG)UsosSetRtc);
        if (d.SetSlots > 0) {
            d.QuerySlots = PatchImports(kernel, (ULONG)HalQueryRealTimeClock, (ULONG)UsosQueryRtc);
            /* Only with the CMOS write redirected: ZwSetSystemTime also
               writes the RTC through HalSetRealTimeClock. */
            if (RtlTimeFieldsToTime(&d.Own, &local)) {
                ExLocalTimeToSystemTime(&local, &utc);
#ifdef USOSRST_NT351
                d.SetStatus = STATUS_NOT_IMPLEMENTED;
#else
                d.SetStatus = ZwSetSystemTime(&utc, NULL);
#endif
            }
        }
    }
    KeQuerySystemTime(&d.After);
    g_RtcState = (CHAR)(NT_SUCCESS(d.SetStatus) && d.QuerySlots > 0 ? 'o' : 'x');

    /* Parameters\RtcDiag: read back offline from the SYSTEM hive. */
    if (RegistryPath != NULL) {
        WCHAR path[256];
        UNICODE_STRING full, name;
        OBJECT_ATTRIBUTES oa;
        HANDLE key;
        full.Buffer = path;
        full.Length = 0;
        full.MaximumLength = sizeof(path);
        if (NT_SUCCESS(RtlAppendUnicodeStringToString(&full, RegistryPath)) &&
            NT_SUCCESS(RtlAppendUnicodeToString(&full, L"\\Parameters"))) {
            InitializeObjectAttributes(&oa, &full, OBJ_CASE_INSENSITIVE, NULL, NULL);
            if (NT_SUCCESS(ZwCreateKey(&key, KEY_WRITE, &oa, 0, NULL, REG_OPTION_NON_VOLATILE, NULL))) {
                RtlInitUnicodeString(&name, L"RtcDiag");
                ZwSetValueKey(key, &name, 0, REG_BINARY, &d, sizeof(d));
                ZwClose(key);
            }
        }
    }
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
    p = PutHex(p, end, g_Tick, 6);
    p = PutStr(p, end, " t:");
    p = PutDec(p, end, (ULONG)(now >> 7) / 78125, 5);      /* 100 ns units -> s */
    p = PutStr(p, end, " w:");
    p = PutDec(p, end, WallSeconds(), 5);
    p = PutStr(p, end, " S:");
    p = PutHex(p, end, g_Stalls > 0xF ? 0xF : g_Stalls, 1);
    if (best != NULL) {
        p = PutStr(p, end, " ");
        p = PutName(p, end, best);
        p = PutStr(p, end, " C:");
        p = PutHex(p, end, bestCi, 8);
        p = PutStr(p, end, " L:");
        p = PutHex(p, end, best->Op, best->Op > 0xFF ? 4 : 2);
        p = PutStr(p, end, " ");
        p = PutHex(p, end, best->Lba, 8);
        p = PutStr(p, end, "+");
        p = PutHex(p, end, best->Count, 4);
        p = PutStr(p, end, " a:");
        p = PutDec(p, end, (g_Tick - best->Changed) * HB_PERIOD_MS / 1000, 4);
    } else {
        p = PutStr(p, end, g_Watches ? " ahci:no-cmd" : " ahci:none");
    }
    p = PutStr(p, end, " cpu:");
    for (i = 0; i < g_Cpus; i++) p = PutHex(p, end, g_CpuTicks[i], 1);
    ShowRow(ROW_HB, line, (ULONG)(p - line), (USHORT)(busyAny && g_Stalls ? 0x4F00 : 0x1F00));
}

#ifdef USOSRST_NT351
/* NT 3.51: PCI configuration space through ports CF8h/CFCh. On boards whose
   PCI BIOS reports a last bus >= 8 the USOS NT 3.x MBR hides the PCI BIOS
   from NTDETECT (the 3.51 HAL bridge scan loops forever otherwise), so the
   HAL has no PCI bus handler and HalGetBusData finds nothing. */
static ULONG
PciCfgHeader351(ULONG Bus, ULONG Slot, PPCI_COMMON_CONFIG Cfg)
{
    PCI_SLOT_NUMBER slot;
    ULONG i, base;

    slot.u.AsULONG = Slot;
    base = 0x80000000UL | ((Bus & 0xFF) << 16) | ((ULONG)slot.u.bits.DeviceNumber << 11) |
           ((ULONG)slot.u.bits.FunctionNumber << 8);
    for (i = 0; i < PCI_COMMON_HDR_LENGTH / 4; i++) {
        WRITE_PORT_ULONG((PULONG)0xCF8, base | (i * 4));
        ((PULONG)Cfg)[i] = READ_PORT_ULONG((PULONG)0xCFC);
        if (i == 0 && (Cfg->VendorID == 0xFFFF || Cfg->VendorID == 0)) break;
    }
    return PCI_COMMON_HDR_LENGTH;     /* buses may be sparse: never "no such bus" */
}
#endif

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
#ifdef USOSRST_NT351
                got = PciCfgHeader351(bus, slot.u.AsULONG, &cfg);
#else
                got = HalGetBusData(PCIConfiguration, bus, slot.u.AsULONG, &cfg, PCI_COMMON_HDR_LENGTH);
#endif
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

#ifdef USOSRST_NT351
/* NT 3.51 has no periodic timers (KeSetTimerEx): the DPC re-arms. */
static VOID
HeartbeatDpc351(IN PKDPC Dpc, IN PVOID Context, IN PVOID Arg1, IN PVOID Arg2)
{
    LARGE_INTEGER due;

    HeartbeatDpc(Dpc, Context, Arg1, Arg2);
    due.QuadPart = -10000LL * HB_PERIOD_MS;
    KeSetTimer(&g_HbTimer, due, &g_HbDpc);
}
#endif

static VOID
StartHeartbeat(VOID)
{
    LARGE_INTEGER due;
    KAFFINITY active = KeQueryActiveProcessors();
    ULONG i;

    FindAhci();
#ifdef USOSRST_NT35
    /* NT 3.5 exports neither KeSetTargetProcessorDpc nor KeSetImportanceDpc:
       one DPC on the processor that queues it (the NT 3.x path installs
       the uniprocessor kernel and the Standard PC HAL). */
    UNREFERENCED_PARAMETER(active);
    KeInitializeDpc(&g_CpuDpc[0], CpuDpc, (PVOID)(ULONG_PTR)0);
    i = 1;
#else
    for (i = 0; i < HB_MAX_CPUS && (active & ((KAFFINITY)1 << i)); i++) {
        KeInitializeDpc(&g_CpuDpc[i], CpuDpc, (PVOID)(ULONG_PTR)i);
        KeSetTargetProcessorDpc(&g_CpuDpc[i], (CCHAR)i);
        KeSetImportanceDpc(&g_CpuDpc[i], HighImportance);
    }
#endif
    g_Cpus = i;
    KeInitializeTimer(&g_HbTimer);
    due.QuadPart = -10000LL * HB_PERIOD_MS;
#ifdef USOSRST_NT351
    KeInitializeDpc(&g_HbDpc, HeartbeatDpc351, NULL);
    KeSetTimer(&g_HbTimer, due, &g_HbDpc);
#else
    KeInitializeDpc(&g_HbDpc, HeartbeatDpc, NULL);
    KeSetTimerEx(&g_HbTimer, due, HB_PERIOD_MS, &g_HbDpc);
#endif
}

/* ------------------------------------------------------------------ */
/* DriverEntry                                                         */
/* ------------------------------------------------------------------ */

NTSTATUS
DriverEntry(IN PDRIVER_OBJECT DriverObject, IN PUNICODE_STRING RegistryPath)
{
    PHYSICAL_ADDRESS vga;
#ifndef USOSRST_NT4
    PDEVICE_OBJECT device = NULL;
#endif
    BOOLEAN shutdownHandler = FALSE;
    CHAR restart;
#ifdef USOSRST_NT4
    CHAR vgaWindow;
#endif
#ifdef USOSRST_POWEROFF
    CHAR line[160];                 /* the registry copy has the whole line */
    PCHAR p, end = line + 160;
#else
    CHAR line[80];
    PCHAR p, end = line + 80;
#endif

    g_OwnEntry = DriverObject->DriverSection;
#ifdef USOSRST_NT4
    g_Sos = BootHasSos();
#endif
    vga.QuadPart = 0xB8000;
    g_Vga = (PUSHORT)MmMapIoSpace(vga, 80 * 50 * 2, MmNonCached);
    KeInitializeCallbackRecord(&g_BugCheckRecord);
#ifndef USOSRST_NT31
    /* NT 3.1 (build-nt31.cmd) exports no KeRegisterBugCheckCallback. */
    KeRegisterBugCheckCallback(&g_BugCheckRecord, BugCheckCallback, NULL, 0, g_Component);
#endif

    g_InSetup = SetupInProgress();
    FindResetRegister();
    restart = RedirectSetupRestart();
    /* The experiment applies to every boot that asks for it; the clock
       rows and the heartbeat are text-mode Setup only (a graphics desktop
       must not get text-buffer writes). */
    g_HpetWanted = OptionWanted(RegistryPath, L"USOSHPETLEGOFF", L"HpetLegacyOff");
    if (OptionWanted(RegistryPath, L"USOSRTCFIX", L"RtcFix")) FixRtc(RegistryPath);
    if (restart != '-') CalibrateTsc();
    ProbeHpet(g_HpetWanted);
    if (restart != '-') {
        ShowClock();
        StartHeartbeat();
    }
#ifdef USOSRST_NT4
    shutdownHandler = RedirectKernelRestart();
#ifdef USOSRST_INLINE
    if (!shutdownHandler) g_InlineHook = HookHalInline();
#endif
    vgaWindow = FreeVgaWindow();
#ifdef USOSRST_RAMLOG
    RmInit();
#endif
#ifdef USOSRST_SHUTLOG
    KeQuerySystemTime(&g_SlT0);
    SlScanPci();
    DriverObject->MajorFunction[IRP_MJ_SHUTDOWN] = SlShutdownDispatch;
    /* "S": registered now, so it runs last in phase 0; "P" (registered by
       the thread 45 s later) runs first. */
    if (NT_SUCCESS(IoCreateDevice(DriverObject, 0, NULL, FILE_DEVICE_UNKNOWN, 0, FALSE, &g_SlLastDev)) &&
        !NT_SUCCESS(IoRegisterShutdownNotification(g_SlLastDev))) {
        IoDeleteDevice(g_SlLastDev);
        g_SlLastDev = NULL;
    }
    if (!NT_SUCCESS(IoCreateDevice(DriverObject, 0, NULL, FILE_DEVICE_UNKNOWN, 0, FALSE, &g_SlFirstDev)))
        g_SlFirstDev = NULL;
    {
        HANDLE th;
        if (NT_SUCCESS(PsCreateSystemThread(&th, THREAD_ALL_ACCESS, NULL, NULL, NULL, SlThread, NULL)))
            ZwClose(th);
    }
#endif
#else
    if (g_InSetup && NT_SUCCESS(IoCreateDevice(DriverObject, 0, NULL, FILE_DEVICE_UNKNOWN, 0, FALSE, &device))) {
        DriverObject->MajorFunction[IRP_MJ_SHUTDOWN] = ShutdownDispatch;
        if (NT_SUCCESS(IoRegisterLastChanceShutdownNotification(device))) {
            shutdownHandler = TRUE;
        } else {
            IoDeleteDevice(device);
        }
    }
#endif

    /* The load line: shows that the driver ran and what it found. */
#ifdef USOSRST_NT4
    p = PutStr(line, end, USOSRST_VERSION " vga");
    *p++ = vgaWindow;
    p = PutStr(p, end, " rsdp=");
#else
    p = PutStr(line, end, USOSRST_VERSION " rsdp=");
#endif
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
#ifdef USOSRST_INLINE
    p = PutStr(p, end, shutdownHandler ? " handler=on" : g_InlineHook ? " handler=inl" : " handler=off");
    p = PutStr(p, end, g_KernelFound ? " k+" : " k-");
    p = PutStr(p, end, g_KernelPatch < 0 ? (g_KernelPatch == -1 ? "x" : "?") : g_KernelPatch == 0 ? "0" : "n");
#else
    p = PutStr(p, end, shutdownHandler ? " handler=on" : " handler=off");
#endif
    p = PutStr(p, end, restart == 'o' ? " txt=on" : restart == '-' ? " txt=no" : " txt=err");
    p = PutStr(p, end, " rtc");
    p = PutStr(p, end, g_RtcState == 'o' ? "o" : g_RtcState == 'x' ? "x" : "-");
#ifdef USOSRST_SHUTLOG
    p = PutStr(p, end, " q");
    p = PutHex(p, end, g_SlDevs, 1);
#ifdef USOSRST_RAMLOG
    p = PutStr(p, end, g_Rm == NULL ? " m-" : g_RmBugData == NULL ? " m+" : " mk");
#endif
#endif
#ifdef USOSRST_POWEROFF
    p = PutStr(p, end, " s5");
    *p++ = g_S5State;
    p = PutStr(p, end, " typ=");
    p = PutHex(p, end, g_S5a, 1);
    p = PutStr(p, end, "/");
    p = PutHex(p, end, g_S5b, 1);
    p = PutStr(p, end, " pm1=");
    p = PutHex(p, end, g_Pm1aEvt, 4);
    p = PutStr(p, end, "/");
    p = PutHex(p, end, g_Pm1aCnt, 4);
    p = PutStr(p, end, " gpe=");
    p = PutHex(p, end, g_Gpe0, 4);
    p = PutStr(p, end, "+");
    p = PutHex(p, end, g_Gpe0Len, 2);
#endif
#ifdef USOSRST_NT4
    p = PutStr(p, end, g_Sos ? " osd+" : " osd-");
#endif
    p = PutStr(p, end, " hb");
    p = PutHex(p, end, g_Hbas, 1);
    p = PutStr(p, end, "/");
    p = PutHex(p, end, g_Watches, 2);
#ifdef USOSRST_POWEROFF
    ShowRow(ROW_LOAD, line, (ULONG)(p - line) > 80 ? 80 : (ULONG)(p - line), 0x1F00);
#else
    ShowRow(ROW_LOAD, line, (ULONG)(p - line), 0x1F00);
#endif
#ifdef USOSRST_POWEROFF
    /* The load line also as Parameters\LoadLine (REG_BINARY, ASCII), read
       back offline from the SYSTEM hive: whether the kernel restart/power-off
       redirect took (handler=on) and what S5 the DSDT gave (s5o). The text
       row is gone under the graphical boot screen (X470 2026-10-29: NT 4.0
       restarts ended in a triple fault without the F stage). */
    if (RegistryPath != NULL) {
        WCHAR path[256];
        UNICODE_STRING full, name;
        OBJECT_ATTRIBUTES oa;
        HANDLE key;
        full.Buffer = path;
        full.Length = 0;
        full.MaximumLength = sizeof(path);
        if (NT_SUCCESS(RtlAppendUnicodeStringToString(&full, RegistryPath)) &&
            NT_SUCCESS(RtlAppendUnicodeToString(&full, L"\\Parameters"))) {
            InitializeObjectAttributes(&oa, &full, OBJ_CASE_INSENSITIVE, NULL, NULL);
            if (NT_SUCCESS(ZwCreateKey(&key, KEY_WRITE, &oa, 0, NULL, REG_OPTION_NON_VOLATILE, NULL))) {
                RtlInitUnicodeString(&name, L"LoadLine");
                ZwSetValueKey(key, &name, 0, REG_BINARY, line, (ULONG)(p - line));
                ZwClose(key);
            }
        }
    }
#endif

    return STATUS_SUCCESS;
}
