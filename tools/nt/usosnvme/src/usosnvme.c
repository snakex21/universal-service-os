/*
 * usosnvme - NVM Express SCSIPORT miniport for Windows NT 3.1 to
 * Windows Server 2003 (x86), part of Universal Service OS (USOS).
 *
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Clean-room implementation from the NVM Express Base Specification and the
 * public SCSI miniport documentation (see usosnvme.h).
 *
 * Design:
 *  - one controller = one ScsiPort adapter; its first active namespace is
 *    target 0, LUN 0 (a SCSI direct-access device);
 *  - one admin queue pair and one I/O queue pair (depth 16 / 32) in the
 *    uncached extension, physically contiguous;
 *  - polled: every command is submitted and completed inside HwStartIo or
 *    HwInitialize, interrupts are masked (INTMS, PCI INTx disable, I/O CQ
 *    created with IEN = 0), so the driver runs with no interrupt at all
 *    (NT 3.x / 4.0 under CSMWrap have no usable PCI interrupt routing);
 *  - READ / WRITE through PRP1 / PRP2 / one PRP list page, split at
 *    min(MDTS, 128 KiB); FLUSH for SYNCHRONIZE CACHE and SRB flush, sent
 *    only when a WRITE happened since the last good flush and the
 *    controller has a volatile write cache; SRB shutdown (NT6) / the 9x exit:
 *    flush + CC.SHN normal shutdown notification;
 *  - diagnostics (flush durations and NVMe status, error counters) through
 *    IOCTL_SCSI_MINIPORT signature "USOSNVME" (usosnvme_diag.h);
 *  - only namespaces with 512-byte LBAs and no metadata are exposed; any
 *    other format is refused (no disk) with an event-log entry and a line
 *    in the VGA text buffer.
 *
 * USOSNVME_NT6 (Windows Vista / 7 / 2008 and the Windows 10 x86 WinPE, built
 * from src/2KXP): no HwInterrupt at all, so ScsiPort connects no interrupt
 * object (its "adapter has no interrupt" path). In that WinPE the driver
 * runs as the stornvme service under stornvme.inf, which asks PnP for
 * MSI-X (MSISupported = 1); connecting the message resource through
 * ScsiPort's line-based IoConnectInterrupt failed the start (X470,
 * 2026-10-14: Problem 10, 0xC000000D). The message vectors are masked at
 * the function instead (MSI-X Function Mask, MSI Enable off).
 * Provenance: the diagnosis (ScsiPort's interrupt connect for a miniport
 * with / without HwInterrupt) was informed by reading the Windows Server
 * 2003 scsiport source supplied by the user as a reference; this variant
 * is our own code, not derived from that source.
 */
#include "usosnvme.h"

#ifndef USOSNVME_W9X
#ifdef _WIN64
__declspec(dllimport) PVOID MmMapIoSpace(IN PHYSICAL_ADDRESS PhysicalAddress,
                                      IN SIZE_T NumberOfBytes, IN ULONG CacheType);
#else
__declspec(dllimport) PVOID __stdcall MmMapIoSpace(IN PHYSICAL_ADDRESS PhysicalAddress,
                                                   IN ULONG NumberOfBytes, IN ULONG CacheType);
#endif
#else
static BOOLEAN NvmeAdapterState(IN PVOID DeviceExtension, IN PVOID Context, IN BOOLEAN SaveState);
#endif
static ULONG NvmeFlush(PHW_DEVICE_EXTENSION Ext, ULONG Source);

ULONG DriverEntry(IN PVOID DriverObject, IN PVOID Argument2);
static ULONG NvmeFindAdapter(IN PVOID DeviceExtension, IN PVOID Context, IN PVOID BusInformation,
                             IN PCHAR ArgumentString, IN OUT PPORT_CONFIGURATION_INFORMATION ConfigInfo,
                             OUT PBOOLEAN Again);
static BOOLEAN NvmeHwInitialize(IN PVOID DeviceExtension);
static BOOLEAN NvmeStartIo(IN PVOID DeviceExtension, IN PSCSI_REQUEST_BLOCK Srb);
#ifndef USOSNVME_NT6
static BOOLEAN NvmeInterrupt(IN PVOID DeviceExtension);
#endif
static BOOLEAN NvmeResetBus(IN PVOID DeviceExtension, IN ULONG PathId);

/* ------------------------------------------------------------------ */
/* small helpers (no CRT: NT 3.1 exports no memset/memcpy)             */
/* ------------------------------------------------------------------ */

static VOID NvmeZero(PVOID Buffer, ULONG Length)
{
    /* volatile: keeps the optimiser from turning the loop into a memset call */
    volatile UCHAR *p = (volatile UCHAR *)Buffer;
    while (Length--) *p++ = 0;
}

static VOID NvmeCopy(PVOID Dest, const VOID *Src, ULONG Length)
{
    volatile UCHAR *d = (volatile UCHAR *)Dest;
    const UCHAR *s = (const UCHAR *)Src;
    while (Length--) *d++ = *s++;
}

/* Physical byte offset, including carry across a 4 GiB boundary. Keep the
   split arithmetic so NT 3.x builds still need no 64-bit CRT helper. */
static SCSI_PHYSICAL_ADDRESS NvmePhysAdd(SCSI_PHYSICAL_ADDRESS Pa, ULONG Bytes)
{
    ULONG low = Pa.LowPart + Bytes;
    if (low < Pa.LowPart) Pa.HighPart++;
    Pa.LowPart = low;
    return Pa;
}

/* ------------------------------------------------------------------ */
/* Windows 9x: VMM service and port I/O (the MPD runs in ring 0 under   */
/* VMM; SCSIPORT.PDR has no MmMapIoSpace and no HAL port routines)      */
/* ------------------------------------------------------------------ */

#ifdef USOSNVME_W9X
/* VxD service call: INT 20h followed by the service ordinal and the VxD id
   (VMM = 0001h, _MapPhysToLinear = 006Ch, a C-convention service; KB
   Q169584 for its use from a SCSI miniport). VMM patches the six bytes into
   an indirect call on first use. Returns the linear address or NULL. */
static PVOID NvmeMapPhys(ULONG Phys, ULONG Bytes)
{
    ULONG lin;
    __asm {
        push 0
        push Bytes
        push Phys
        int 20h
        _emit 06Ch
        _emit 000h
        _emit 001h
        _emit 000h
        add esp, 12
        mov lin, eax
    }
    return lin == 0xFFFFFFFFUL ? NULL : (PVOID)lin;
}

static VOID NvmeOut32(ULONG Port, ULONG Value)
{
    __asm {
        mov edx, Port
        mov eax, Value
        out dx, eax
    }
}

static ULONG NvmeIn32(ULONG Port)
{
    ULONG v;
    __asm {
        mov edx, Port
        in eax, dx
        mov v, eax
    }
    return v;
}

static VOID NvmeOut16(ULONG Port, USHORT Value)
{
    __asm {
        mov edx, Port
        mov ax, Value
        out dx, ax
    }
}

/* Bochs / QEMU debug console (-debugcon): port E9h reads back E9h there and
   FFh on real hardware, where nothing is written. */
static LONG NvmeE9 = -1;

static VOID NvmeDbgStr(const CHAR *s)
{
    if (NvmeE9 < 0) {
        UCHAR v;
        __asm {
            in al, 0E9h
            mov v, al
        }
        NvmeE9 = (v == 0xE9) ? 1 : 0;
    }
    if (!NvmeE9) return;
    while (*s) {
        CHAR c = *s++;
        __asm {
            mov al, c
            out 0E9h, al
        }
    }
}
#endif

static ULONG NvmeRd(PHW_DEVICE_EXTENSION Ext, ULONG Offset)
{
    return ScsiPortReadRegisterUlong((PULONG)(Ext->Regs + Offset));
}

static VOID NvmeWr(PHW_DEVICE_EXTENSION Ext, ULONG Offset, ULONG Value)
{
    ScsiPortWriteRegisterUlong((PULONG)(Ext->Regs + Offset), Value);
}

static ULONG NvmeGetUlong(const UCHAR *p)
{
    return (ULONG)p[0] | ((ULONG)p[1] << 8) | ((ULONG)p[2] << 16) | ((ULONG)p[3] << 24);
}

static VOID NvmePutBe32(PUCHAR p, ULONG v)
{
    p[0] = (UCHAR)(v >> 24); p[1] = (UCHAR)(v >> 16); p[2] = (UCHAR)(v >> 8); p[3] = (UCHAR)v;
}

static ULONG NvmeGetBe32(const UCHAR *p)
{
    return ((ULONG)p[0] << 24) | ((ULONG)p[1] << 16) | ((ULONG)p[2] << 8) | (ULONG)p[3];
}

/* ------------------------------------------------------------------ */
/* VGA text status line (row 9; AHCINT uses 0 and 8, usosrst 1-7)       */
/* ------------------------------------------------------------------ */

#define NVME_VGA_ROW 9

typedef struct _NVME_LINE {
    CHAR Text[81];
    ULONG Len;
} NVME_LINE;

static VOID LineStr(NVME_LINE *l, const CHAR *s)
{
    while (*s && l->Len < 80) l->Text[l->Len++] = *s++;
}

static VOID LineHex(NVME_LINE *l, ULONG v, ULONG digits)
{
    static const CHAR hex[] = "0123456789ABCDEF";
    while (digits-- && l->Len < 80) l->Text[l->Len++] = hex[(v >> (digits * 4)) & 0xF];
}

static VOID LineDec(NVME_LINE *l, ULONG v)
{
    CHAR tmp[11];
    ULONG n = 0;
    do { tmp[n++] = (CHAR)('0' + (v % 10)); v /= 10; } while (v && n < 10);
    while (n && l->Len < 80) l->Text[l->Len++] = tmp[--n];
}

#ifdef USOSNVME_NT4
/* Boot-screen line (2026-10-30, NT 4.0 / 3.x builds): the white line only
   when the boot's SystemStartOptions carry SOS (BOOT.INI "[USOS /SOS]");
   error lines (red) always. The kernel writes the value before the boot
   drivers start; read once in NvmeFindAdapter (PASSIVE_LEVEL). Own minimal
   structures: miniport.h declares no registry services. */
typedef struct { USHORT Length, MaximumLength; PWSTR Buffer; } NVME_USTR;
typedef struct { ULONG Length; PVOID RootDirectory; NVME_USTR *ObjectName; ULONG Attributes;
                 PVOID SecurityDescriptor, SecurityQualityOfService; } NVME_OATTR;
__declspec(dllimport) LONG __stdcall ZwOpenKey(OUT PVOID *KeyHandle, IN ULONG DesiredAccess, IN NVME_OATTR *Attributes);
__declspec(dllimport) LONG __stdcall ZwQueryValueKey(IN PVOID KeyHandle, IN NVME_USTR *ValueName, IN ULONG Class,
                                                     OUT PVOID Info, IN ULONG Length, OUT PULONG ResultLength);
__declspec(dllimport) LONG __stdcall ZwClose(IN PVOID Handle);
static BOOLEAN g_NvmeSos, g_NvmeSosRead;

static BOOLEAN NvmeBootSos(VOID)
{
    static WCHAR key[] = L"\\Registry\\Machine\\System\\CurrentControlSet\\Control";
    static WCHAR name[] = L"SystemStartOptions";
    NVME_USTR k, v;
    NVME_OATTR oa;
    PVOID h;
    ULONG buf[130], got = 0, n, i;
    PWCHAR s;
    BOOLEAN sos = FALSE;

    k.Buffer = key; k.Length = sizeof(key) - 2; k.MaximumLength = sizeof(key);
    v.Buffer = name; v.Length = sizeof(name) - 2; v.MaximumLength = sizeof(name);
    oa.Length = sizeof(oa); oa.RootDirectory = NULL; oa.ObjectName = &k; oa.Attributes = 0x40;
    oa.SecurityDescriptor = NULL; oa.SecurityQualityOfService = NULL;
    if (ZwOpenKey(&h, 0x20019, &oa) < 0) return FALSE;
    if (ZwQueryValueKey(h, &v, 2, buf, sizeof(buf) - 4, &got) >= 0 && (buf[1] == 1 || buf[1] == 2)) {
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

static VOID NvmeShowLine(PHW_DEVICE_EXTENSION Ext, NVME_LINE *l, BOOLEAN Error)
{
    PHYSICAL_ADDRESS vga;
    ULONG i;
    USHORT attr = Error ? 0x4F00 : 0x1F00;

#ifdef USOSNVME_NT4
    if (!Error && !g_NvmeSos) return;
#endif
#ifdef USOSNVME_W9X
    l->Text[l->Len < 80 ? l->Len : 80] = 0;
    NvmeDbgStr(l->Text);
    NvmeDbgStr("\n");
    (VOID)vga;
    if (Ext->Vga == NULL) {
        Ext->Vga = (PUSHORT)NvmeMapPhys(0xB8000, 80 * 25 * 2);
        if (Ext->Vga == NULL) return;
    }
#else
    if (Ext->Vga == NULL) {
        vga.LowPart = 0xB8000;
        vga.HighPart = 0;
        Ext->Vga = (PUSHORT)MmMapIoSpace(vga, 80 * 25 * 2, 0 /* non-cached */);
        if (Ext->Vga == NULL) return;
    }
#endif
    for (i = 0; i < 80; i++) {
        UCHAR c = (UCHAR)(i < l->Len ? l->Text[i] : ' ');
        Ext->Vga[NVME_VGA_ROW * 80 + i] = (USHORT)(attr | c);
    }
}

static VOID NvmeLog(PHW_DEVICE_EXTENSION Ext, ULONG UniqueId)
{
    ScsiPortLogError(Ext, NULL, 0, 0, 0, SP_INTERNAL_ADAPTER_ERROR, UniqueId);
}

static VOID NvmeReport(PHW_DEVICE_EXTENSION Ext, const CHAR *Msg, ULONG Value, BOOLEAN Error)
{
    NVME_LINE l;
    l.Len = 0;
    LineStr(&l, "USOSNVME " USOSNVME_VERSION " ");
    LineHex(&l, Ext->PciId & 0xFFFF, 4);
    LineStr(&l, ":");
    LineHex(&l, Ext->PciId >> 16, 4);
    LineStr(&l, " ");
    LineStr(&l, Msg);
    if (Value != 0xFFFFFFFF) {
        LineStr(&l, " ");
        LineHex(&l, Value, 8);
    }
    NvmeShowLine(Ext, &l, Error);
}

/* ------------------------------------------------------------------ */
/* PCI configuration space                                              */
/* ------------------------------------------------------------------ */

#define NVME_PCI_HEADER 64

#ifdef USOSNVME_CF8
/* NT 3.x: the USOS NT 3.x MBR may hide the PCI BIOS from NTDETECT (boards
   whose PCI BIOS reports a last bus >= 8), so the HAL can have no PCI bus
   handler. Windows 9x: SCSIPORT.PDR's bus-data calls are not relied on.
   Configuration mechanism 1 through ports CF8h / CFCh instead. */
static ULONG NvmeCfgAddress(ULONG Bus, ULONG Slot, ULONG Offset)
{
    PCI_SLOT_NUMBER slot;
    slot.u.AsULONG = Slot;
    return 0x80000000UL | ((Bus & 0xFF) << 16) | ((ULONG)slot.u.bits.DeviceNumber << 11) |
           ((ULONG)slot.u.bits.FunctionNumber << 8) | (Offset & 0xFC);
}

#ifdef USOSNVME_W9X
static BOOLEAN NvmeCfgMap(PHW_DEVICE_EXTENSION Ext)
{
    (VOID)Ext;
    return TRUE;
}

static ULONG NvmeCfgRead32(ULONG Bus, ULONG Slot, ULONG Offset)
{
    ULONG v;
    _asm pushfd
    _asm cli
    NvmeOut32(0xCF8, NvmeCfgAddress(Bus, Slot, Offset));
    v = NvmeIn32(0xCFC);
    _asm popfd
    return v;
}

static VOID NvmeCfgWrite16(ULONG Bus, ULONG Slot, ULONG Offset, USHORT Value)
{
    _asm pushfd
    _asm cli
    NvmeOut32(0xCF8, NvmeCfgAddress(Bus, Slot, Offset));
    NvmeOut16(0xCFC + (Offset & 2), Value);
    _asm popfd
}
#else
static PUCHAR NvmeCfgPorts;

static BOOLEAN NvmeCfgMap(PHW_DEVICE_EXTENSION Ext)
{
    SCSI_PHYSICAL_ADDRESS ports;
    if (NvmeCfgPorts == NULL) {
        ports.LowPart = 0xCF8;
        ports.HighPart = 0;
        NvmeCfgPorts = (PUCHAR)ScsiPortGetDeviceBase(Ext, Isa, 0, ports, 8, TRUE);
    }
    return (BOOLEAN)(NvmeCfgPorts != NULL);
}

static ULONG NvmeCfgRead32(ULONG Bus, ULONG Slot, ULONG Offset)
{
    ScsiPortWritePortUlong((PULONG)NvmeCfgPorts, NvmeCfgAddress(Bus, Slot, Offset));
    return ScsiPortReadPortUlong((PULONG)(NvmeCfgPorts + 4));
}

static VOID NvmeCfgWrite16(ULONG Bus, ULONG Slot, ULONG Offset, USHORT Value)
{
    ScsiPortWritePortUlong((PULONG)NvmeCfgPorts, NvmeCfgAddress(Bus, Slot, Offset));
    ScsiPortWritePortUshort((PUSHORT)(NvmeCfgPorts + 4 + (Offset & 2)), Value);
}
#endif
#endif

/* FALSE for an empty slot; *BusMissing when the bus does not exist */
static BOOLEAN NvmeReadPci(PHW_DEVICE_EXTENSION Ext, ULONG Bus, ULONG Slot,
                           PPCI_COMMON_CONFIG Cfg, PBOOLEAN BusMissing)
{
#ifdef USOSNVME_CF8
    ULONG i;
    if (BusMissing) *BusMissing = FALSE;
    if (Bus > 0xFF || !NvmeCfgMap(Ext)) return FALSE;
    ((PULONG)Cfg)[0] = NvmeCfgRead32(Bus, Slot, 0);
    if (Cfg->VendorID == 0xFFFF || Cfg->VendorID == 0) return FALSE;
    for (i = 1; i < NVME_PCI_HEADER / 4; i++) ((PULONG)Cfg)[i] = NvmeCfgRead32(Bus, Slot, i * 4);
    return TRUE;
#else
    ULONG got = ScsiPortGetBusData(Ext, PCIConfiguration, Bus, Slot, Cfg, NVME_PCI_HEADER);
    if (BusMissing) *BusMissing = (BOOLEAN)(got == 0);
    if (got < NVME_PCI_HEADER) return FALSE;
    if (Cfg->VendorID == 0xFFFF || Cfg->VendorID == 0) return FALSE;
    return TRUE;
#endif
}

static VOID NvmeWritePciCommand(PHW_DEVICE_EXTENSION Ext, ULONG Bus, ULONG Slot, USHORT Command)
{
#ifdef USOSNVME_CF8
    NvmeCfgWrite16(Bus, Slot, 0x04, Command);
#else
    ScsiPortSetBusDataByOffset(Ext, PCIConfiguration, Bus, Slot, &Command, 0x04, sizeof(USHORT));
#endif
}

#ifdef USOSNVME_NT6
/* MSI-X: Function Mask on (vectors stay allocated, nothing is sent);
   MSI: Enable off. INTx is already off (PCI Command bit 10). */
static VOID NvmeMaskMessages(PHW_DEVICE_EXTENSION Ext, ULONG Bus, ULONG Slot)
{
    UCHAR cfg[256];
    ULONG got, ptr, guard;
    USHORT ctl;

    got = ScsiPortGetBusData(Ext, PCIConfiguration, Bus, Slot, cfg, sizeof(cfg));
    if (got < 0x40 || !(cfg[0x06] & 0x10)) return;     /* no capability list */
    ptr = cfg[0x34] & 0xFC;
    for (guard = 0; ptr >= 0x40 && ptr + 4 <= got && guard < 48; guard++) {
        ctl = (USHORT)(cfg[ptr + 2] | ((USHORT)cfg[ptr + 3] << 8));
        if (cfg[ptr] == 0x11 && !(ctl & 0x4000)) {
            ctl |= 0x4000;
            ScsiPortSetBusDataByOffset(Ext, PCIConfiguration, Bus, Slot, &ctl, ptr + 2, sizeof(ctl));
        } else if (cfg[ptr] == 0x05 && (ctl & 0x0001)) {
            ctl &= (USHORT)~0x0001;
            ScsiPortSetBusDataByOffset(Ext, PCIConfiguration, Bus, Slot, &ctl, ptr + 2, sizeof(ctl));
        }
        ptr = cfg[ptr + 1] & 0xFC;
    }
}
#endif

static BOOLEAN NvmeIsNvme(PPCI_COMMON_CONFIG Cfg)
{
    /* class 01h (mass storage), subclass 08h (NVM), prog-if 02h (NVMe) */
    return (BOOLEAN)(Cfg->BaseClass == 0x01 && Cfg->SubClass == 0x08 && Cfg->ProgIf == 0x02);
}

#ifdef USOSNVME_NT4
/* Non-PnP ScsiPort: the miniport finds its controllers itself. */
#define NVME_MAX_CLAIMED 8
static ULONG NvmeClaimed[NVME_MAX_CLAIMED];
static ULONG NvmeClaimedCount;

static BOOLEAN NvmeIsClaimed(ULONG Bus, ULONG Slot)
{
    ULONG i, key = (Bus << 16) | (Slot & 0xFFFF);
    for (i = 0; i < NvmeClaimedCount; i++) if (NvmeClaimed[i] == key) return TRUE;
    return FALSE;
}

static VOID NvmeClaim(ULONG Bus, ULONG Slot)
{
    if (NvmeClaimedCount < NVME_MAX_CLAIMED) NvmeClaimed[NvmeClaimedCount++] = (Bus << 16) | (Slot & 0xFFFF);
}

static BOOLEAN NvmeScan(PHW_DEVICE_EXTENSION Ext, PULONG FoundBus, PULONG FoundSlot, PPCI_COMMON_CONFIG Cfg)
{
    PCI_SLOT_NUMBER slot;
    ULONG bus, dev, fn;
    BOOLEAN missing, multi;

    for (bus = 0; bus < 256; bus++) {
        for (dev = 0; dev < 32; dev++) {
            multi = FALSE;
            for (fn = 0; fn < 8; fn++) {
                if (fn > 0 && !multi) break;
                slot.u.AsULONG = 0;
                slot.u.bits.DeviceNumber = dev;
                slot.u.bits.FunctionNumber = fn;
                if (!NvmeReadPci(Ext, bus, slot.u.AsULONG, Cfg, &missing)) {
                    if (missing && dev == 0 && fn == 0) return FALSE;  /* HAL numbers buses contiguously */
                    if (fn == 0) break;
                    continue;
                }
                if (fn == 0) multi = (BOOLEAN)((Cfg->HeaderType & 0x80) != 0);
                if (NvmeIsNvme(Cfg) && !NvmeIsClaimed(bus, slot.u.AsULONG)) {
                    *FoundBus = bus;
                    *FoundSlot = slot.u.AsULONG;
                    return TRUE;
                }
            }
        }
    }
    return FALSE;
}
#endif

/* ------------------------------------------------------------------ */
/* Queues and commands                                                  */
/* ------------------------------------------------------------------ */

static BOOLEAN NvmeControllerDead(PHW_DEVICE_EXTENSION Ext)
{
    ULONG csts = NvmeRd(Ext, NVME_REG_CSTS);
    return (BOOLEAN)(csts == 0xFFFFFFFF || (csts & NVME_CSTS_CFS));
}

static ULONG NvmeSubmit(PHW_DEVICE_EXTENSION Ext, PNVME_QUEUE Q, PNVME_SQE Cmd)
{
    ULONG cid = (++Ext->CommandId) & 0xFFFF;
    PULONG dst = (PULONG)&Q->Sq[Q->SqTail];
    PULONG src = (PULONG)Cmd;
    ULONG i;

    /* CID FFFFh is reserved (the error log's "not specific to a command") */
    if (cid == 0xFFFF) cid = (++Ext->CommandId) & 0xFFFF;
    Cmd->Cdw0 = (Cmd->Cdw0 & 0x0000FFFF) | (cid << 16);
    for (i = 0; i < sizeof(NVME_SQE) / 4; i++) dst[i] = src[i];
    Q->SqTail++;
    if (Q->SqTail == Q->Depth) Q->SqTail = 0;
    NvmeWr(Ext, Q->SqDoorbell, Q->SqTail);
    return cid;
}

/* Status: 0 = success, 0xFFFFFFFF = timeout, else (SCT << 8) | SC */
#define NVME_TIMEOUT_STATUS 0xFFFFFFFFUL

/* The time is the sum of the ScsiPortStallExecution steps: 2 us for the
   first 200 us (most commands complete there), 10 us up to 2 ms, then
   50 us. usosnvme <= B261022 stalled 2 us per step throughout and counted
   only the stall: the call and CQ-read overhead of each step was missing,
   so its "30 s" limit could run far longer in real time (X470 Micron,
   Win10 x86: a ~55-60 s black screen at shutdown). With 50 us steps that
   overhead is a few per cent of a long wait. The duration of the last
   command is left in Ext->LastWaitUs. */
static ULONG NvmeWait(PHW_DEVICE_EXTENSION Ext, PNVME_QUEUE Q, ULONG Cid, PULONG Dw0, ULONG TimeoutUs)
{
    ULONG waited = 0, spins = 0, step;

    for (;;) {
        volatile ULONG *e = (volatile ULONG *)&Q->Cq[Q->CqHead];
        ULONG dw3 = e[3];
        if (((dw3 >> 16) & 1) == Q->Phase) {
            ULONG d0 = e[0];
            Q->CqHead++;
            if (Q->CqHead == Q->Depth) {
                Q->CqHead = 0;
                Q->Phase ^= 1;
            }
            NvmeWr(Ext, Q->CqDoorbell, Q->CqHead);
            if ((dw3 & 0xFFFF) == Cid) {
                if (Dw0) *Dw0 = d0;
                Ext->LastWaitUs = waited;
                Ext->Diag.LastCqeDw3 = dw3;
                return (dw3 >> 17) & 0x7FF;   /* SC 7:0, SCT 10:8 */
            }
            continue;   /* a stale completion; keep looking for ours */
        }
        if (waited >= TimeoutUs ||
            ((++spins & 0xFF) == 0 && NvmeControllerDead(Ext))) {
            Ext->LastWaitUs = waited;
            return NVME_TIMEOUT_STATUS;
        }
        step = waited < 200 ? 2 : (waited < 2000 ? 10 : 50);
        ScsiPortStallExecution(step);
        waited += step;
    }
}

static ULONG NvmeExec(PHW_DEVICE_EXTENSION Ext, PNVME_QUEUE Q, PNVME_SQE Cmd, ULONG TimeoutUs, PULONG Dw0)
{
    ULONG cid = NvmeSubmit(Ext, Q, Cmd);
    return NvmeWait(Ext, Q, cid, Dw0, TimeoutUs);
}

static VOID NvmeQueueInit(PHW_DEVICE_EXTENSION Ext, PNVME_QUEUE Q, ULONG Qid, ULONG SqPage, ULONG CqPage, ULONG Depth)
{
    Q->Sq = (PNVME_SQE)(Ext->Uncached + SqPage * NVME_PAGE);
    Q->Cq = (PNVME_CQE)(Ext->Uncached + CqPage * NVME_PAGE);
    Q->SqPhys = NvmePhysAdd(Ext->UncachedPhys, SqPage * NVME_PAGE);
    Q->CqPhys = NvmePhysAdd(Ext->UncachedPhys, CqPage * NVME_PAGE);
    Q->Depth = Depth;
    Q->SqTail = 0;
    Q->CqHead = 0;
    Q->Phase = 1;
    Q->SqDoorbell = NVME_REG_DOORBELL + (2 * Qid) * Ext->DoorbellStride;
    Q->CqDoorbell = NVME_REG_DOORBELL + (2 * Qid + 1) * Ext->DoorbellStride;
    NvmeZero(Q->Sq, NVME_PAGE);
    NvmeZero(Q->Cq, NVME_PAGE);
}

static BOOLEAN NvmeWaitReady(PHW_DEVICE_EXTENSION Ext, BOOLEAN Ready)
{
    ULONG ms;
    for (ms = 0; ms <= Ext->ReadyTimeoutMs; ms++) {
        ULONG csts = NvmeRd(Ext, NVME_REG_CSTS);
        if (csts == 0xFFFFFFFF) return FALSE;
        if (Ready && (csts & NVME_CSTS_CFS)) return FALSE;
        if (((csts & NVME_CSTS_RDY) != 0) == Ready) return TRUE;
        ScsiPortStallExecution(1000);
    }
    return FALSE;
}

static ULONG NvmeIdentify(PHW_DEVICE_EXTENSION Ext, ULONG Cns, ULONG Nsid)
{
    NVME_SQE c;
    NvmeZero(&c, sizeof(c));
    NvmeZero(Ext->Ident, NVME_PAGE);
    c.Cdw0 = NVME_ADM_IDENTIFY;
    c.Nsid = Nsid;
    c.Prp1Lo = Ext->IdentPhys.LowPart;
    c.Prp1Hi = Ext->IdentPhys.HighPart;
    c.Cdw10 = Cns;
    return NvmeExec(Ext, &Ext->Admin, &c, NVME_ADMIN_TIMEOUT_US, NULL);
}

static VOID NvmeTrimCopy(PUCHAR Dest, const UCHAR *Src, ULONG Len)
{
    ULONG i;
    for (i = 0; i < Len; i++) {
        UCHAR ch = Src[i];
        Dest[i] = (UCHAR)((ch < 0x20 || ch > 0x7E) ? ' ' : ch);
    }
}

/* Full (re)initialisation: disable, admin queue, enable, identify, I/O
   queue pair, namespace. Safe to call again after a timeout. */
static BOOLEAN NvmeStartController(PHW_DEVICE_EXTENSION Ext)
{
    NVME_SQE c;
    ULONG status, cc, mdts, nsid, flbas, lbaf, ms, lbads, qs = 0;

    Ext->ControllerUp = FALSE;
    Ext->NamespaceReady = FALSE;
    Ext->NeedRestart = FALSE;
    Ext->Dirty = TRUE;               /* unknown: the first flush is always sent */
    Ext->InitStage = 1;
    Ext->Diag.Starts++;

    Ext->CapLo = NvmeRd(Ext, NVME_REG_CAP_LO);
    Ext->CapHi = NvmeRd(Ext, NVME_REG_CAP_HI);
    Ext->Version = NvmeRd(Ext, NVME_REG_VS);
    if (Ext->CapLo == 0xFFFFFFFF) {
        NvmeReport(Ext, "registers read FFFFFFFF (BAR not decoded)", 0xFFFFFFFF, TRUE);
        return FALSE;
    }
    Ext->DoorbellStride = 4UL << (Ext->CapHi & 0xF);
    Ext->ReadyTimeoutMs = ((Ext->CapLo >> 24) & 0xFF) * 500;
    if (Ext->ReadyTimeoutMs < 500) Ext->ReadyTimeoutMs = 500;
    if (Ext->ReadyTimeoutMs > 60000) Ext->ReadyTimeoutMs = 60000;
    if (((Ext->CapHi >> 16) & 0xF) != 0) {          /* MPSMIN > 4 KiB */
        NvmeReport(Ext, "controller needs pages > 4 KiB; CAP.HI", Ext->CapHi, TRUE);
        NvmeLog(Ext, NVME_LOG_PAGE_SIZE);
        return FALSE;
    }
    if (NVME_REG_DOORBELL + 4 * Ext->DoorbellStride > NVME_BAR_MAP_SIZE) {
        NvmeReport(Ext, "doorbell stride too large; CAP.HI", Ext->CapHi, TRUE);
        return FALSE;
    }

    /* 1. disable (the firmware, e.g. SeaBIOS in CSMWrap, left it running) */
    Ext->InitStage = 2;
    cc = NvmeRd(Ext, NVME_REG_CC);
    if (cc & NVME_CC_EN) NvmeWr(Ext, NVME_REG_CC, cc & ~NVME_CC_EN);
    if (!NvmeWaitReady(Ext, FALSE)) {
        NvmeReport(Ext, "controller did not stop; CSTS", NvmeRd(Ext, NVME_REG_CSTS), TRUE);
        NvmeLog(Ext, NVME_LOG_NO_READY);
        return FALSE;
    }

    /* 2. admin queue */
    Ext->InitStage = 3;
    NvmeQueueInit(Ext, &Ext->Admin, 0, NVME_PG_ASQ, NVME_PG_ACQ, NVME_ADMIN_DEPTH);
    NvmeWr(Ext, NVME_REG_AQA, ((NVME_ADMIN_DEPTH - 1UL) << 16) | (NVME_ADMIN_DEPTH - 1UL));
    NvmeWr(Ext, NVME_REG_ASQ_LO, Ext->Admin.SqPhys.LowPart);
    NvmeWr(Ext, NVME_REG_ASQ_HI, (ULONG)Ext->Admin.SqPhys.HighPart);
    NvmeWr(Ext, NVME_REG_ACQ_LO, Ext->Admin.CqPhys.LowPart);
    NvmeWr(Ext, NVME_REG_ACQ_HI, (ULONG)Ext->Admin.CqPhys.HighPart);

    /* 3. enable: NVM command set, 4 KiB pages, round robin, 64/16-byte entries */
    Ext->InitStage = 4;
    NvmeWr(Ext, NVME_REG_CC, NVME_CC_IOCQES_16 | NVME_CC_IOSQES_64 | NVME_CC_EN);
    if (!NvmeWaitReady(Ext, TRUE)) {
        NvmeReport(Ext, "controller not ready after enable; CSTS", NvmeRd(Ext, NVME_REG_CSTS), TRUE);
        NvmeLog(Ext, NVME_LOG_NO_READY);
        return FALSE;
    }
    /* polled driver: mask the pin-based / single MSI vector 0 */
    NvmeWr(Ext, NVME_REG_INTMS, 0xFFFFFFFF);

    /* 4. identify controller */
    Ext->InitStage = 5;
    status = NvmeIdentify(Ext, 1, 0);
    if (status != 0) {
        NvmeReport(Ext, "IDENTIFY controller failed; status", status, TRUE);
        NvmeLog(Ext, NVME_LOG_ADMIN_FAIL);
        return FALSE;
    }
    NvmeTrimCopy(Ext->Serial, Ext->Ident + 4, 20);
    NvmeTrimCopy(Ext->Model, Ext->Ident + 24, 40);
    NvmeTrimCopy(Ext->Firmware, Ext->Ident + 64, 8);
    mdts = Ext->Ident[77];
    Ext->VolatileCache = (BOOLEAN)((Ext->Ident[525] & 1) != 0);
    Ext->Diag.Vwc = Ext->Ident[525];
    Ext->Diag.Rtd3eUs = NvmeGetUlong(Ext->Ident + 88);
    Ext->ShutdownMs = Ext->Diag.Rtd3eUs / 1000;
    if (Ext->ShutdownMs == 0) Ext->ShutdownMs = NVME_SHN_DEFAULT_MS;
    if (Ext->ShutdownMs < NVME_SHN_MIN_MS) Ext->ShutdownMs = NVME_SHN_MIN_MS;
    if (Ext->ShutdownMs > NVME_SHN_MAX_MS) Ext->ShutdownMs = NVME_SHN_MAX_MS;
    Ext->MaxChunkBytes = NVME_MAX_TRANSFER;
    if (mdts != 0 && mdts < 16 && (NVME_PAGE << mdts) < Ext->MaxChunkBytes) Ext->MaxChunkBytes = NVME_PAGE << mdts;

    /* 5. one I/O queue pair (Number of Queues first; some controllers want it) */
    Ext->InitStage = 6;
    NvmeZero(&c, sizeof(c));
    c.Cdw0 = NVME_ADM_SET_FEATURE;
    c.Cdw10 = NVME_FEAT_NUM_QUEUES;
    /* NVME_IO_QID SQs and CQs (0-based; NT: 1 + 1, Cdw11 = 0) */
    c.Cdw11 = ((NVME_IO_QID - 1UL) << 16) | (NVME_IO_QID - 1UL);
    status = NvmeExec(Ext, &Ext->Admin, &c, NVME_ADMIN_TIMEOUT_US, &qs);
    Ext->IoQid = NVME_IO_QID;
#if NVME_IO_QID > 1
    if (status != 0 || (qs & 0xFFFF) < NVME_IO_QID - 1UL || (qs >> 16) < NVME_IO_QID - 1UL)
        Ext->IoQid = 1;
#else
    (VOID)qs;
#endif

    NvmeQueueInit(Ext, &Ext->Io, Ext->IoQid, NVME_PG_IOSQ, NVME_PG_IOCQ, NVME_IO_DEPTH);
    NvmeZero(&c, sizeof(c));
    c.Cdw0 = NVME_ADM_CREATE_CQ;
    c.Prp1Lo = Ext->Io.CqPhys.LowPart;
    c.Prp1Hi = Ext->Io.CqPhys.HighPart;
    c.Cdw10 = ((NVME_IO_DEPTH - 1UL) << 16) | Ext->IoQid;
    c.Cdw11 = 1;                         /* physically contiguous, IEN = 0 */
    status = NvmeExec(Ext, &Ext->Admin, &c, NVME_ADMIN_TIMEOUT_US, NULL);
    if (status != 0) {
        NvmeReport(Ext, "CREATE I/O CQ failed; status", status, TRUE);
        NvmeLog(Ext, NVME_LOG_ADMIN_FAIL);
        return FALSE;
    }
    NvmeZero(&c, sizeof(c));
    c.Cdw0 = NVME_ADM_CREATE_SQ;
    c.Prp1Lo = Ext->Io.SqPhys.LowPart;
    c.Prp1Hi = Ext->Io.SqPhys.HighPart;
    c.Cdw10 = ((NVME_IO_DEPTH - 1UL) << 16) | Ext->IoQid;
    c.Cdw11 = (Ext->IoQid << 16) | 1;    /* its CQ, physically contiguous */
    status = NvmeExec(Ext, &Ext->Admin, &c, NVME_ADMIN_TIMEOUT_US, NULL);
    if (status != 0) {
        NvmeReport(Ext, "CREATE I/O SQ failed; status", status, TRUE);
        NvmeLog(Ext, NVME_LOG_ADMIN_FAIL);
        return FALSE;
    }
    Ext->ControllerUp = TRUE;

    /* 6. namespace: the first active one (CNS 02h, NVMe 1.1+), else NSID 1 */
    Ext->InitStage = 7;
    nsid = 1;
    if (NvmeIdentify(Ext, 2, 0) == 0) {
        ULONG first = NvmeGetUlong(Ext->Ident);
        if (first == 0) {
            NvmeReport(Ext, "no active namespace", 0xFFFFFFFF, TRUE);
            NvmeLog(Ext, NVME_LOG_NO_NS);
            return TRUE;
        }
        nsid = first;
    }
    status = NvmeIdentify(Ext, 0, nsid);
    if (status != 0) {
        NvmeReport(Ext, "IDENTIFY namespace failed; status", status, TRUE);
        NvmeLog(Ext, NVME_LOG_ADMIN_FAIL);
        return TRUE;
    }
    Ext->Nsid = nsid;
    Ext->NsBlocksLo = NvmeGetUlong(Ext->Ident + 0);
    Ext->NsBlocksHi = NvmeGetUlong(Ext->Ident + 4);
    flbas = Ext->Ident[26] & 0x0F;
    lbaf = NvmeGetUlong(Ext->Ident + 128 + 4 * flbas);
    ms = lbaf & 0xFFFF;
    lbads = (lbaf >> 16) & 0xFF;
    if (Ext->NsBlocksLo == 0 && Ext->NsBlocksHi == 0) {
        NvmeReport(Ext, "namespace is empty; NSID", nsid, TRUE);
        NvmeLog(Ext, NVME_LOG_NO_NS);
        return TRUE;
    }
    if (lbads != 9 || ms != 0) {
        NVME_LINE l;
        l.Len = 0;
        LineStr(&l, "USOSNVME: NVMe namespace ");
        LineDec(&l, nsid);
        LineStr(&l, " uses ");
        LineDec(&l, lbads < 32 ? (1UL << lbads) : 0);
        LineStr(&l, "-byte sectors");
        if (ms) { LineStr(&l, " + "); LineDec(&l, ms); LineStr(&l, " B metadata"); }
        LineStr(&l, "; only 512-byte sectors are supported");
        NvmeShowLine(Ext, &l, TRUE);
        NvmeLog(Ext, NVME_LOG_NOT_512);
        return TRUE;
    }
    Ext->LbaShift = 9;
    Ext->NamespaceReady = TRUE;
    Ext->InitStage = 8;
    {
        NVME_LINE l;
        l.Len = 0;
        LineStr(&l, "USOSNVME " USOSNVME_VERSION " ");
        LineHex(&l, Ext->PciId & 0xFFFF, 4);
        LineStr(&l, ":");
        LineHex(&l, Ext->PciId >> 16, 4);
        LineStr(&l, " NS");
        LineDec(&l, nsid);
        LineStr(&l, " ");
        /* MiB = blocks >> 11, without 64-bit helpers */
        LineDec(&l, (Ext->NsBlocksLo >> 11) | (Ext->NsBlocksHi << 21));
        LineStr(&l, " MiB x512 chunk ");
        LineDec(&l, Ext->MaxChunkBytes >> 10);
        LineStr(&l, "K VWC ");
        LineDec(&l, Ext->VolatileCache ? 1 : 0);
        LineStr(&l, " VS ");
        LineHex(&l, Ext->Version, 8);
        LineStr(&l, " OK");
        NvmeShowLine(Ext, &l, FALSE);
    }
    return TRUE;
}

/* ------------------------------------------------------------------ */
/* DriverEntry                                                          */
/* ------------------------------------------------------------------ */

ULONG DriverEntry(IN PVOID DriverObject, IN PVOID Argument2)
{
    HW_INITIALIZATION_DATA init;

    NvmeZero(&init, sizeof(init));
#ifdef USOSNVME_NT4
    /* NT 4.0 / 3.5x ScsiPort refuse a size above their own structure
       (everything before HwAdapterControl); NT 3.1 takes exactly 0x40. */
    init.HwInitializationDataSize = FIELD_OFFSET(HW_INITIALIZATION_DATA, HwAdapterControl);
#ifdef USOSNVME_NT31
    init.HwInitializationDataSize = 0x40;
#endif
#else
    init.HwInitializationDataSize = sizeof(HW_INITIALIZATION_DATA);
#endif
    init.HwInitialize = NvmeHwInitialize;
    init.HwStartIo = NvmeStartIo;
#ifdef USOSNVME_NT6
    init.HwInterrupt = NULL;             /* polled, no interrupt object */
#else
    init.HwInterrupt = NvmeInterrupt;
#endif
    init.HwFindAdapter = NvmeFindAdapter;
    init.HwResetBus = NvmeResetBus;
#ifdef USOSNVME_W9X
    /* SCSIPORT.PDR reports "Init Failure" without HwAdapterState */
    init.HwAdapterState = NvmeAdapterState;
    NvmeDbgStr("USOSNVME " USOSNVME_VERSION " 9x: DriverEntry\n");
#endif
    init.DeviceExtensionSize = sizeof(HW_DEVICE_EXTENSION);
#ifdef USOSNVME_NT351
    init.AdapterInterfaceType = Isa;     /* see NvmeCfgMap */
#else
    init.AdapterInterfaceType = PCIBus;
#endif
    init.NumberOfAccessRanges = 1;
    init.MapBuffers = TRUE;
    init.NeedPhysicalAddresses = TRUE;
    init.AutoRequestSense = TRUE;
    init.MultipleRequestPerLu = FALSE;
    return ScsiPortInitialize(DriverObject, Argument2, &init, NULL);
}

/* ------------------------------------------------------------------ */
/* HwFindAdapter                                                        */
/* ------------------------------------------------------------------ */

static ULONG NvmeFindAdapter(IN PVOID DeviceExtension, IN PVOID Context, IN PVOID BusInformation,
                             IN PCHAR ArgumentString, IN OUT PPORT_CONFIGURATION_INFORMATION ConfigInfo,
                             OUT PBOOLEAN Again)
{
    PHW_DEVICE_EXTENSION ext = (PHW_DEVICE_EXTENSION)DeviceExtension;
    PCI_COMMON_CONFIG cfg;
    PACCESS_RANGE ranges = *ConfigInfo->AccessRanges;
    SCSI_PHYSICAL_ADDRESS bar;
    ULONG bus, slot, len, mapSize, i;
    PUCHAR va;
    SCSI_PHYSICAL_ADDRESS pa;
    USHORT cmd;
    BOOLEAN found = FALSE;

    (VOID)Context;
    (VOID)BusInformation;
    (VOID)ArgumentString;
    *Again = FALSE;
#ifdef USOSNVME_NT4
    if (!g_NvmeSosRead) { g_NvmeSos = NvmeBootSos(); g_NvmeSosRead = TRUE; }
#endif
    if (ext->Regs != NULL) return SP_RETURN_FOUND;

    bus = ConfigInfo->SystemIoBusNumber;
#ifdef USOSNVME_NT31
    slot = 0;      /* the NT 3.1 PORT_CONFIGURATION_INFORMATION has no SlotNumber */
#else
    slot = ConfigInfo->SlotNumber;
#endif

#ifdef USOSNVME_NT4
    if (NvmeReadPci(ext, bus, slot, &cfg, NULL) && NvmeIsNvme(&cfg) && !NvmeIsClaimed(bus, slot)) found = TRUE;
    if (!found) found = NvmeScan(ext, &bus, &slot, &cfg);
    if (!found) return SP_RETURN_NOT_FOUND;
    NvmeClaim(bus, slot);
#else
    /* PnP (2000 / XP / 2003): only the function we were started for */
    if (!NvmeReadPci(ext, bus, slot, &cfg, NULL) || !NvmeIsNvme(&cfg)) return SP_RETURN_NOT_FOUND;
    found = TRUE;
#endif

    ext->PciBus = bus;
    ext->PciSlot = slot;
    ext->PciId = (ULONG)cfg.VendorID | ((ULONG)cfg.DeviceID << 16);

    /* BAR0 (+ BAR1 for a 64-bit BAR); a memory BAR */
    bar.LowPart = cfg.u.type0.BaseAddresses[0];
    bar.HighPart = 0;
    if (bar.LowPart & 1) return SP_RETURN_ERROR;
    if ((bar.LowPart & 0x6) == 0x4) bar.HighPart = (LONG)cfg.u.type0.BaseAddresses[1];
    bar.LowPart &= 0xFFFFFFF0;
    mapSize = NVME_BAR_MAP_SIZE;
#ifdef USOSNVME_W9X
    {
        NVME_LINE l;
        l.Len = 0;
        LineStr(&l, "USOSNVME 9x: ");
        LineHex(&l, ext->PciId & 0xFFFF, 4);
        LineStr(&l, ":");
        LineHex(&l, ext->PciId >> 16, 4);
        LineStr(&l, " bus ");
        LineDec(&l, bus);
        LineStr(&l, " slot ");
        LineHex(&l, slot, 4);
        LineStr(&l, " BAR ");
        LineHex(&l, (ULONG)bar.HighPart, 8);
        LineHex(&l, bar.LowPart, 8);
        LineStr(&l, " given ");
        LineDec(&l, ConfigInfo->SystemIoBusNumber);
        LineStr(&l, "/");
        LineHex(&l, ConfigInfo->SlotNumber, 4);
        LineStr(&l, " IRQ ");
        LineDec(&l, ConfigInfo->BusInterruptLevel);
        LineStr(&l, " ranges ");
        LineDec(&l, ConfigInfo->NumberOfAccessRanges);
        l.Text[l.Len] = 0;
        NvmeDbgStr(l.Text);
        NvmeDbgStr("\n");
    }
    /* VMM maps 32-bit physical addresses only (and 98 / Me VMM mishandle
       memory above 4 GiB): a BAR placed there is refused, the disk stays on
       the BIOS (MS-DOS compatibility mode). Firmware: Above 4G Decoding off. */
    if (bar.HighPart != 0) {
        NvmeReport(ext, "BAR above 4 GiB, not used (Above 4G Decoding off); BAR high", (ULONG)bar.HighPart, TRUE);
        NvmeLog(ext, NVME_LOG_BAR_HIGH);
        return SP_RETURN_NOT_FOUND;
    }
#else
    if (ranges != NULL) {
        for (i = 0; i < ConfigInfo->NumberOfAccessRanges; i++) {
            if (ranges[i].RangeInMemory &&
                (ranges[i].RangeStart.LowPart != 0 || ranges[i].RangeStart.HighPart != 0)) {
                /* PnP gave us the translated range of BAR0: use it */
                bar = ranges[i].RangeStart;
                if (ranges[i].RangeLength != 0 && ranges[i].RangeLength < mapSize) mapSize = ranges[i].RangeLength;
                break;
            }
        }
    }
#endif
    if (bar.LowPart == 0 && bar.HighPart == 0) return SP_RETURN_ERROR;

    /* memory decode + bus master on; INTx off (the driver polls) */
    cmd = (USHORT)(cfg.Command | 0x0006 | 0x0400);
    NvmeWritePciCommand(ext, bus, slot, cmd);
#ifdef USOSNVME_NT6
    NvmeMaskMessages(ext, bus, slot);
#endif

#ifdef USOSNVME_NT4
    /* non-PnP: report the range so ScsiPort claims it */
    if (ranges != NULL && ConfigInfo->NumberOfAccessRanges > 0) {
        ranges[0].RangeStart = bar;
        ranges[0].RangeLength = mapSize;
        ranges[0].RangeInMemory = TRUE;
    }
#endif

#ifdef USOSNVME_NT351
    ext->Regs = (PUCHAR)ScsiPortGetDeviceBase(ext, Isa, 0, bar, mapSize, FALSE);
    if (ext->Regs == NULL) ext->Regs = (PUCHAR)ScsiPortGetDeviceBase(ext, Internal, 0, bar, mapSize, FALSE);
    {
        /* As an Isa master the 3.x HAL wants map registers; report a 32-bit
           PCI (3.51) / EISA (3.1) bus master instead. Without a HAL PCI bus
           handler a PCIBus resource report fails, so the range is dropped. */
        USHORT vendor = 0;
        if (ScsiPortGetBusData(ext, PCIConfiguration, 0, 0, &vendor, sizeof(vendor)) == 0 &&
            ranges != NULL && ConfigInfo->NumberOfAccessRanges > 0) {
            ranges[0].RangeStart.LowPart = 0;
            ranges[0].RangeStart.HighPart = 0;
            ranges[0].RangeLength = 0;
        }
#ifdef USOSNVME_NT31
        ConfigInfo->AdapterInterfaceType = Eisa;
#else
        ConfigInfo->AdapterInterfaceType = PCIBus;
#endif
    }
    *Again = TRUE;
#elif defined(USOSNVME_W9X)
    ext->Regs = (PUCHAR)NvmeMapPhys(bar.LowPart, mapSize);
#else
    ext->Regs = (PUCHAR)ScsiPortGetDeviceBase(ext, ConfigInfo->AdapterInterfaceType, bus, bar, mapSize, FALSE);
    if (ext->Regs == NULL && ConfigInfo->AdapterInterfaceType != PCIBus)
        ext->Regs = (PUCHAR)ScsiPortGetDeviceBase(ext, PCIBus, bus, bar, mapSize, FALSE);
#endif
    if (ext->Regs == NULL) return SP_RETURN_ERROR;

    ConfigInfo->SystemIoBusNumber = bus;
#ifndef USOSNVME_NT31
    ConfigInfo->SlotNumber = slot;
#endif
#ifdef USOSNVME_NT4
    /* no interrupt object: every command completes in HwStartIo */
    ConfigInfo->BusInterruptLevel = 0;
    ConfigInfo->BusInterruptVector = 0;
#endif
#ifndef USOSNVME_NT6
    ConfigInfo->InterruptMode = LevelSensitive;
#endif
    ConfigInfo->Master = TRUE;
    ConfigInfo->Dma32BitAddresses = TRUE;
#if !defined(USOSNVME_NT4) && defined(SCSI_DMA64_MINIPORT_SUPPORTED)
    ConfigInfo->Dma64BitAddresses = SCSI_DMA64_MINIPORT_SUPPORTED;
#endif
    ConfigInfo->ScatterGather = TRUE;
    ConfigInfo->CachesData = TRUE;
    ConfigInfo->AlignmentMask = 3;
    ConfigInfo->MaximumTransferLength = NVME_MAX_TRANSFER;
    ConfigInfo->NumberOfPhysicalBreaks = NVME_MAX_BREAKS;
    ConfigInfo->NumberOfBuses = 1;
#ifndef USOSNVME_NT31
    ConfigInfo->MaximumNumberOfTargets = 2;
#endif
    ConfigInfo->InitiatorBusId[0] = 1;

    /* queues, identify buffer and the PRP list: one aligned uncached block */
    va = (PUCHAR)ScsiPortGetUncachedExtension(ext, ConfigInfo, (NVME_PAGES + 1) * NVME_PAGE);
    if (va == NULL) return SP_RETURN_ERROR;
    pa = ScsiPortGetPhysicalAddress(ext, NULL, va, &len);
    i = (NVME_PAGE - (pa.LowPart & (NVME_PAGE - 1))) & (NVME_PAGE - 1);
    ext->Uncached = va + i;
    ext->UncachedPhys = NvmePhysAdd(pa, i);
    ext->Ident = ext->Uncached + NVME_PG_IDENT * NVME_PAGE;
    ext->IdentPhys = NvmePhysAdd(ext->UncachedPhys, NVME_PG_IDENT * NVME_PAGE);
    ext->PrpList = (PULONG)(ext->Uncached + NVME_PG_PRPLIST * NVME_PAGE);
    ext->PrpListPhys = NvmePhysAdd(ext->UncachedPhys, NVME_PG_PRPLIST * NVME_PAGE);
#ifdef USOSNVME_W9X
    /* the queues need physically contiguous pages */
    for (i = 1; i < NVME_PAGES; i++) {
        SCSI_PHYSICAL_ADDRESS p2 = ScsiPortGetPhysicalAddress(ext, NULL, ext->Uncached + i * NVME_PAGE, &len);
        if (p2.LowPart != ext->UncachedPhys.LowPart + i * NVME_PAGE || p2.HighPart != ext->UncachedPhys.HighPart) {
            NvmeReport(ext, "uncached extension not contiguous; page", i, TRUE);
            return SP_RETURN_ERROR;
        }
    }
#endif
    (VOID)found;
    return SP_RETURN_FOUND;
}

static BOOLEAN NvmeHwInitialize(IN PVOID DeviceExtension)
{
    PHW_DEVICE_EXTENSION ext = (PHW_DEVICE_EXTENSION)DeviceExtension;
    (VOID)NvmeStartController(ext);
    /* TRUE even on failure: the disk is then simply absent and the reason
       is on screen and in the event log. */
    return TRUE;
}

#ifdef USOSNVME_W9X
static VOID NvmeDbgCounters(PHW_DEVICE_EXTENSION Ext, const CHAR *Why)
{
    NVME_LINE l;
    l.Len = 0;
    LineStr(&l, "USOSNVME 9x: ");
    LineStr(&l, Why);
    LineStr(&l, " srb ");
    LineDec(&l, Ext->Srbs);
    LineStr(&l, " rd ");
    LineDec(&l, Ext->Reads);
    LineStr(&l, " wr ");
    LineDec(&l, Ext->Writes);
    LineStr(&l, " fl ");
    LineDec(&l, Ext->Flushes);
    LineStr(&l, " err ");
    LineDec(&l, Ext->Errors);
    LineStr(&l, " to ");
    LineDec(&l, Ext->Timeouts);
    LineStr(&l, " qid ");
    LineDec(&l, Ext->IoQid);
    l.Text[l.Len] = 0;
    NvmeDbgStr(l.Text);
    NvmeDbgStr("\n");
}
#endif

#if defined(USOSNVME_W9X) || defined(USOSNVME_NT6)
/* Flush (if anything is unflushed) and the CC.SHN normal shutdown
   notification: the controller commits its volatile cache and metadata
   (stornvme does the same at shutdown). The notification is sent even when
   the controller needs a restart (a timed-out command), as long as it is
   enabled and ready, and waited for at most RTD3E clamped to 1-10 s.
   NT6: SRB_FUNCTION_SHUTDOWN. The controller stays enabled; ControllerUp
   is cleared, so an I/O after the shutdown request re-initialises it.
   Windows 9x: Windows exits to real mode (shut down, restart, MS-DOS mode).
   The controller is then left disabled. Its admin queue was replaced at our
   init, so SeaBIOS NVMe in CSMWrap 3.1.2-usos9+ re-arms its own queues on
   its next INT 13h call (98's WIN.COM /z power-off; older CSMWrap timed out
   there); it refuses a controller that still runs our queues. The next I/O
   from Windows re-initialises it. */
static VOID NvmeShutdown(PHW_DEVICE_EXTENSION Ext)
{
    ULONG cc, csts, ms, limit;

    if (Ext->Regs == NULL || NvmeControllerDead(Ext)) return;
    if (Ext->ControllerUp && Ext->NamespaceReady && !Ext->NeedRestart)
        (VOID)NvmeFlush(Ext, USOSNVME_FLUSH_SHUTDOWN);
    cc = NvmeRd(Ext, NVME_REG_CC);
    csts = NvmeRd(Ext, NVME_REG_CSTS);
    if ((cc & NVME_CC_EN) && (csts & NVME_CSTS_RDY)) {
        limit = Ext->ShutdownMs ? Ext->ShutdownMs : NVME_SHN_DEFAULT_MS;
        NvmeWr(Ext, NVME_REG_CC, (cc & ~(3UL << 14)) | NVME_CC_SHN_NORMAL);
        for (ms = 0; ms < limit; ms++) {
            csts = NvmeRd(Ext, NVME_REG_CSTS);
            if (csts == 0xFFFFFFFF || (csts & NVME_CSTS_SHST_MASK) == NVME_CSTS_SHST_DONE) break;
            ScsiPortStallExecution(1000);
        }
        Ext->Diag.Shutdowns++;
        Ext->Diag.LastShutdownUs = ms * 1000;
        Ext->Diag.LastShutdownCsts = csts;
    }
#ifdef USOSNVME_W9X
    cc = NvmeRd(Ext, NVME_REG_CC);
    if (cc & NVME_CC_EN) {
        NvmeWr(Ext, NVME_REG_CC, cc & ~NVME_CC_EN);
        (VOID)NvmeWaitReady(Ext, FALSE);
    }
#endif
    Ext->ControllerUp = FALSE;
}
#endif

#ifdef USOSNVME_W9X
static BOOLEAN NvmeAdapterState(IN PVOID DeviceExtension, IN PVOID Context, IN BOOLEAN SaveState)
{
    PHW_DEVICE_EXTENSION ext = (PHW_DEVICE_EXTENSION)DeviceExtension;
    (VOID)Context;
    NvmeDbgCounters(ext, SaveState ? "AdapterState save" : "AdapterState restore");
    if (!SaveState) NvmeShutdown(ext);
    return TRUE;
}
#endif

#ifndef USOSNVME_NT6
static BOOLEAN NvmeInterrupt(IN PVOID DeviceExtension)
{
    (VOID)DeviceExtension;
    return FALSE;        /* polled; INTx disabled, INTMS masked */
}
#endif

static BOOLEAN NvmeResetBus(IN PVOID DeviceExtension, IN ULONG PathId)
{
    PHW_DEVICE_EXTENSION ext = (PHW_DEVICE_EXTENSION)DeviceExtension;
    ScsiPortCompleteRequest(ext, (UCHAR)PathId, SP_UNTAGGED, SP_UNTAGGED, SRB_STATUS_BUS_RESET);
    return TRUE;
}

/* ------------------------------------------------------------------ */
/* SCSI translation                                                     */
/* ------------------------------------------------------------------ */

static VOID NvmeSetSense(PHW_DEVICE_EXTENSION Ext, PSCSI_REQUEST_BLOCK Srb, UCHAR Key, UCHAR Asc, UCHAR Ascq)
{
    Ext->SenseKey = Key;
    Ext->Asc = Asc;
    Ext->Ascq = Ascq;
    Srb->ScsiStatus = SCSISTAT_CHECK_CONDITION;
    Srb->SrbStatus = SRB_STATUS_ERROR;
    if (Srb->SenseInfoBuffer != NULL && Srb->SenseInfoBufferLength != 0 &&
        !(Srb->SrbFlags & SRB_FLAGS_DISABLE_AUTOSENSE)) {
        UCHAR s[18];
        ULONG n = Srb->SenseInfoBufferLength < 18 ? Srb->SenseInfoBufferLength : 18;
        NvmeZero(s, sizeof(s));
        s[0] = 0x70;
        s[2] = Key;
        s[7] = 10;
        s[12] = Asc;
        s[13] = Ascq;
        NvmeCopy(Srb->SenseInfoBuffer, s, n);
        Srb->SrbStatus |= SRB_STATUS_AUTOSENSE_VALID;
    }
}

static VOID NvmeReturnData(PSCSI_REQUEST_BLOCK Srb, const UCHAR *Data, ULONG Len, ULONG Alloc)
{
    ULONG n = Len;
    if (n > Alloc) n = Alloc;
    if (n > Srb->DataTransferLength) n = Srb->DataTransferLength;
    if (Srb->DataBuffer != NULL && n) NvmeCopy(Srb->DataBuffer, Data, n);
    Srb->DataTransferLength = n;
    Srb->SrbStatus = SRB_STATUS_SUCCESS;
    Srb->ScsiStatus = SCSISTAT_GOOD;
}

static VOID NvmeInquiry(PHW_DEVICE_EXTENSION Ext, PSCSI_REQUEST_BLOCK Srb)
{
    UCHAR d[64];
    PUCHAR cdb = Srb->Cdb;
    ULONG alloc = ((ULONG)cdb[3] << 8) | cdb[4];
    ULONG i;

    NvmeZero(d, sizeof(d));
    if (cdb[1] & 1) {                     /* EVPD */
        if (cdb[2] == 0x00) {
            d[1] = 0x00; d[3] = 2; d[4] = 0x00; d[5] = 0x80;
            NvmeReturnData(Srb, d, 6, alloc);
        } else if (cdb[2] == 0x80) {
            d[1] = 0x80; d[3] = 20;
            NvmeCopy(d + 4, Ext->Serial, 20);
            NvmeReturnData(Srb, d, 24, alloc);
        } else {
            NvmeSetSense(Ext, Srb, SCSI_SENSE_ILLEGAL_REQUEST, 0x24, 0);
        }
        return;
    }
    d[0] = 0x00;                          /* direct-access device */
    d[1] = 0x00;                          /* not removable */
    d[2] = 0x02;                          /* SCSI-2 (oldest class drivers) */
    d[3] = 0x02;
    d[4] = 31;
    NvmeCopy(d + 8, "NVMe    ", 8);
    for (i = 0; i < 16; i++) d[16 + i] = Ext->Model[i];
    /* firmware revision: the first 4 characters */
    for (i = 0; i < 4; i++) d[32 + i] = Ext->Firmware[i];
    NvmeReturnData(Srb, d, 36, alloc);
}

static VOID NvmeReadCapacity(PHW_DEVICE_EXTENSION Ext, PSCSI_REQUEST_BLOCK Srb, BOOLEAN Long)
{
    UCHAR d[32];
    ULONG lastLo = Ext->NsBlocksLo - 1;
    ULONG lastHi = Ext->NsBlocksHi - (Ext->NsBlocksLo == 0 ? 1 : 0);

    NvmeZero(d, sizeof(d));
    if (!Long) {
        NvmePutBe32(d, lastHi ? 0xFFFFFFFF : lastLo);
        NvmePutBe32(d + 4, 512);
        NvmeReturnData(Srb, d, 8, 8);
    } else {
        ULONG alloc = NvmeGetBe32(Srb->Cdb + 10);
        NvmePutBe32(d, lastHi);
        NvmePutBe32(d + 4, lastLo);
        NvmePutBe32(d + 8, 512);
        NvmeReturnData(Srb, d, 32, alloc);
    }
}

static VOID NvmeModeSense(PHW_DEVICE_EXTENSION Ext, PSCSI_REQUEST_BLOCK Srb, BOOLEAN Ten)
{
    UCHAR d[64];
    PUCHAR cdb = Srb->Cdb;
    UCHAR page = (UCHAR)(cdb[2] & 0x3F);
    UCHAR pc = (UCHAR)(cdb[2] >> 6);
    ULONG hdr = Ten ? 8 : 4;
    ULONG len = hdr;
    ULONG alloc = Ten ? (((ULONG)cdb[7] << 8) | cdb[8]) : cdb[4];

    NvmeZero(d, sizeof(d));
    if (page != 0x08 && page != 0x3F && page != 0x00) {
        NvmeSetSense(Ext, Srb, SCSI_SENSE_ILLEGAL_REQUEST, 0x24, 0);
        return;
    }
    if (page == 0x08 || page == 0x3F) {
        d[len] = 0x08;                     /* caching page */
        d[len + 1] = 0x12;
        if (pc == 1) {                     /* changeable values: none */
        } else if (Ext->VolatileCache) {
            d[len + 2] = 0x04;             /* WCE */
        }
        len += 20;
    }
    if (Ten) {
        d[0] = (UCHAR)((len - 2) >> 8);
        d[1] = (UCHAR)(len - 2);
        d[3] = 0x10;                       /* DPOFUA, not write protected */
    } else {
        d[0] = (UCHAR)(len - 1);
        d[2] = 0x10;
    }
    NvmeReturnData(Srb, d, len, alloc);
}

#ifdef USOSNVME_W9X
/* Windows 9x: SCSIPORT.PDR maps an IOS request whose physical fragments
   need not line up with the pages of its linear buffer (QEMU 98 SE: a
   linear offset 0E00h on a page-aligned physical fragment gave "PRP Offset
   Invalid"). The PRPs follow the physical fragments: PRP1 any dword offset,
   every later entry page aligned, every entry but the last ending on a page
   boundary. Returns how many of Blocks (from Va) one command can take, the
   PRPs in Ext->Prp9x; 0 when even the first 512 bytes do not fit. */
static ULONG NvmeRwPrps9x(PHW_DEVICE_EXTENSION Ext, PSCSI_REQUEST_BLOCK Srb, PUCHAR Va, ULONG Blocks)
{
    ULONG want = Blocks << 9, done = 0, n = 0, len, seg, off, used;
    ULONG starts[NVME_PRP9X_MAX];
    SCSI_PHYSICAL_ADDRESS pa;

    while (done < want && n < NVME_PRP9X_MAX) {
        len = 0;
        pa = ScsiPortGetPhysicalAddress(Ext, Srb, Va + done, &len);
        off = pa.LowPart & (NVME_PAGE - 1);
        if (n == 0 && (off & 3)) return 0;
        if (n > 0 && off != 0) break;
        seg = NVME_PAGE - off;
        if (len != 0 && len < seg) seg = len;
        if (seg > want - done) seg = want - done;
        Ext->Prp9x[n] = pa;
        starts[n] = done;
        n++;
        done += seg;
        if (((pa.LowPart + seg) & (NVME_PAGE - 1)) != 0) break;   /* must be the last entry */
    }
    done &= ~511UL;
    for (used = 0; used < n && starts[used] < done; used++) ;
    Ext->Prp9xCount = used;
    return done >> 9;
}
#endif

/* NvmeRw status for a request whose data address ScsiPort could not give
   in a form the PRPs can carry: nothing was sent to the controller. */
#define NVME_BADPA_STATUS 0xFFFFFFFEUL

#if defined(_WIN64) && !defined(USOSNVME_W9X)
/* amd64 (Vista / Server 2008 x64, RAM above 4 GiB). The miniport declares
   Dma64BitAddresses, so ScsiPort hands out full 64-bit data addresses; they
   go into the PRPs unmodified (both dwords). Before anything reaches the
   controller every entry is checked, so a value the PRP model cannot carry
   fails the request (event log NVME_LOG_BAD_PA) instead of becoming a DMA
   to a wrong address:
     - ScsiPort's "no address" value (SP_UNINITIALIZED_VALUE, all ones) or a
       zero length (the address lies outside the request's S/G list);
     - an address beyond 2^52 (no x64 RAM there);
     - PRP1 not dword aligned, any later entry not page aligned;
     - a contiguous run that ends inside a page while data continues there
       (the PRP model cannot express a break inside a page);
     - more entries than one PRP list page holds.
   The x86 builds keep their unchanged, hardware-tested inline code below.
   Returns 0, else the 1-based number of the refused entry. *Above4G is set
   when any entry lies above 4 GiB. */
static BOOLEAN NvmePaUsable(SCSI_PHYSICAL_ADDRESS Pa, ULONG Len, ULONG Need, ULONG AlignMask)
{
    if (Len == 0 || Len < Need) return FALSE;
    if (Pa.LowPart == 0xFFFFFFFFUL && Pa.HighPart == -1) return FALSE;
    if (((ULONG)Pa.HighPart & 0xFFF00000UL) != 0) return FALSE;
    if ((Pa.LowPart & AlignMask) != 0) return FALSE;
    return TRUE;
}

static ULONG NvmeBuildPrps(PHW_DEVICE_EXTENSION Ext, PSCSI_REQUEST_BLOCK Srb, PUCHAR Va, ULONG Bytes,
                           PNVME_SQE C, PBOOLEAN Above4G)
{
    SCSI_PHYSICAL_ADDRESS pa, list[2 * (NVME_MAX_TRANSFER / NVME_PAGE) + 2];
    ULONG len = 0, first, rest, n = 0, i;
    PUCHAR next;

    *Above4G = FALSE;
    if (Bytes == 0) return 1;
    pa = ScsiPortGetPhysicalAddress(Ext, Srb, Va, &len);
    first = NVME_PAGE - (pa.LowPart & (NVME_PAGE - 1));
    if (!NvmePaUsable(pa, len, first < Bytes ? first : Bytes, 3)) return 1;
    if (pa.HighPart != 0) *Above4G = TRUE;
    C->Prp1Lo = pa.LowPart;
    C->Prp1Hi = (ULONG)pa.HighPart;
    C->Prp2Lo = 0;
    C->Prp2Hi = 0;
    if (Bytes <= first) return 0;
    rest = Bytes - first;
    next = Va + first;
    while (rest) {
        if (n >= sizeof(list) / sizeof(list[0]) || n >= NVME_PAGE / 8) return n + 2;
        len = 0;
        pa = ScsiPortGetPhysicalAddress(Ext, Srb, next, &len);
        if (!NvmePaUsable(pa, len, rest < NVME_PAGE ? rest : NVME_PAGE, NVME_PAGE - 1)) return n + 2;
        if (pa.HighPart != 0) *Above4G = TRUE;
        list[n++] = pa;
        next += NVME_PAGE;
        rest = rest > NVME_PAGE ? rest - NVME_PAGE : 0;
    }
    if (n == 1) {
        C->Prp2Lo = list[0].LowPart;
        C->Prp2Hi = (ULONG)list[0].HighPart;
        return 0;
    }
    for (i = 0; i < n; i++) {
        Ext->PrpList[2 * i] = list[i].LowPart;
        Ext->PrpList[2 * i + 1] = (ULONG)list[i].HighPart;
    }
    C->Prp2Lo = Ext->PrpListPhys.LowPart;
    C->Prp2Hi = (ULONG)Ext->PrpListPhys.HighPart;
    return 0;
}
#endif

/* One READ / WRITE command for Blocks blocks at Va (dword aligned). */
static ULONG NvmeRw(PHW_DEVICE_EXTENSION Ext, PSCSI_REQUEST_BLOCK Srb, BOOLEAN Write, PUCHAR Va,
                    ULONG LbaLo, ULONG LbaHi, ULONG Blocks, BOOLEAN Fua)
{
    NVME_SQE c;
    ULONG status;
#if defined(_WIN64) && !defined(USOSNVME_W9X)
    ULONG bytes = Blocks << 9, refused;
    BOOLEAN above4g = FALSE;
#else
    SCSI_PHYSICAL_ADDRESS pa;
    ULONG len, bytes = Blocks << 9, first, rest, n;
    PUCHAR next;
#endif

    NvmeZero(&c, sizeof(c));
    c.Cdw0 = Write ? NVME_NVM_WRITE : NVME_NVM_READ;
    c.Nsid = Ext->Nsid;
#ifdef USOSNVME_W9X
    /* PRPs from NvmeRwPrps9x (called just before for exactly Blocks) */
    c.Prp1Lo = Ext->Prp9x[0].LowPart;
    c.Prp1Hi = (ULONG)Ext->Prp9x[0].HighPart;
    if (Ext->Prp9xCount == 2) {
        c.Prp2Lo = Ext->Prp9x[1].LowPart;
        c.Prp2Hi = (ULONG)Ext->Prp9x[1].HighPart;
    } else if (Ext->Prp9xCount > 2) {
        for (n = 1; n < Ext->Prp9xCount; n++) {
            Ext->PrpList[2 * (n - 1)] = Ext->Prp9x[n].LowPart;
            Ext->PrpList[2 * (n - 1) + 1] = (ULONG)Ext->Prp9x[n].HighPart;
        }
        c.Prp2Lo = Ext->PrpListPhys.LowPart;
        c.Prp2Hi = Ext->PrpListPhys.HighPart;
    }
#elif defined(_WIN64)
    refused = NvmeBuildPrps(Ext, Srb, Va, bytes, &c, &above4g);
    if (refused != 0) {
        Ext->LastStatus = refused;
        return NVME_BADPA_STATUS;
    }
    if (above4g && !Ext->DmaHighLogged) {
        /* once per boot: proof in the System log that data DMA
           above 4 GiB was used (the run continues normally) */
        Ext->DmaHighLogged = TRUE;
        NvmeLog(Ext, NVME_LOG_DMA_HIGH);
    }
#else
    pa = ScsiPortGetPhysicalAddress(Ext, Srb, Va, &len);
    c.Prp1Lo = pa.LowPart;
    c.Prp1Hi = pa.HighPart;
    first = NVME_PAGE - (pa.LowPart & (NVME_PAGE - 1));
    if (bytes > first) {
        rest = bytes - first;
        next = Va + first;
        if (rest <= NVME_PAGE) {
            pa = ScsiPortGetPhysicalAddress(Ext, Srb, next, &len);
            c.Prp2Lo = pa.LowPart;
            c.Prp2Hi = pa.HighPart;
        } else {
            n = 0;
            while (rest) {
                pa = ScsiPortGetPhysicalAddress(Ext, Srb, next, &len);
                Ext->PrpList[2 * n] = pa.LowPart;
                Ext->PrpList[2 * n + 1] = (ULONG)pa.HighPart;
                n++;
                next += NVME_PAGE;
                rest = rest > NVME_PAGE ? rest - NVME_PAGE : 0;
            }
            c.Prp2Lo = Ext->PrpListPhys.LowPart;
            c.Prp2Hi = Ext->PrpListPhys.HighPart;
        }
    }
#endif
    c.Cdw10 = LbaLo;
    c.Cdw11 = LbaHi;
    c.Cdw12 = (Blocks - 1) | (Fua ? (1UL << 30) : 0);
    if (Write) Ext->Dirty = TRUE;    /* FUA too: conservative */
    status = NvmeExec(Ext, &Ext->Io, &c, NVME_IO_TIMEOUT_US, NULL);
    if (Ext->LastWaitUs > Ext->Diag.MaxIoUs) Ext->Diag.MaxIoUs = Ext->LastWaitUs;
    return status;
}

/* FLUSH of our namespace (NSID FFFFFFFFh is valid only when Identify VWC
   bits 2:1 = 11b). Windows asks often and twice in a row (the disk class:
   SYNCHRONIZE CACHE, then SRB_FUNCTION_FLUSH because the adapter reports
   CachesData; at shutdown SYNCHRONIZE CACHE + SRB_FUNCTION_SHUTDOWN). No
   command when nothing was written since the last good flush, none when the
   controller has no volatile write cache (the FLUSH has no effect there).
   Every request is counted and the last eight kept (diagnostics ring); a
   failure goes to the event log with its NVMe status. A timeout marks the
   controller for re-initialisation before the next command. */
static ULONG NvmeFlush(PHW_DEVICE_EXTENSION Ext, ULONG Source)
{
    NVME_SQE c;
    PUSOSNVME_DIAG d = &Ext->Diag;
    USOSNVME_FLUSH_REC *r;
    ULONG status = 0, us = 0, how = USOSNVME_FLUSH_SENT;

    d->FlushRequests++;
    if (!Ext->VolatileCache) {
        how = USOSNVME_FLUSH_NO_VWC;
        d->FlushSkipped++;
    } else if (!Ext->Dirty) {
        how = USOSNVME_FLUSH_CLEAN;
        d->FlushSkipped++;
    } else {
        NvmeZero(&c, sizeof(c));
        c.Cdw0 = NVME_NVM_FLUSH;
        c.Nsid = Ext->Nsid;
        Ext->Flushes++;
        d->FlushSent++;
        status = NvmeExec(Ext, &Ext->Io, &c, NVME_FLUSH_TIMEOUT_US, NULL);
        us = Ext->LastWaitUs;
        /* Invalid Field / Invalid Namespace for our NSID: once more for all
           namespaces when the controller supports that */
        if ((status == 0x002 || status == 0x00B) && (d->Vwc & 6) == 6) {
            NvmeZero(&c, sizeof(c));
            c.Cdw0 = NVME_NVM_FLUSH;
            c.Nsid = 0xFFFFFFFFUL;
            d->FlushSent++;
            how = USOSNVME_FLUSH_ALL_NS;
            status = NvmeExec(Ext, &Ext->Io, &c, NVME_FLUSH_TIMEOUT_US, NULL);
            us += Ext->LastWaitUs;
        }
        d->LastFlushUs = us;
        if (us > d->MaxFlushUs) d->MaxFlushUs = us;
        /* sub-ms flushes add up: carry the microsecond remainder */
        Ext->FlushUsCarry += us % 1000;
        d->TotalFlushMs += us / 1000 + Ext->FlushUsCarry / 1000;
        Ext->FlushUsCarry %= 1000;
        d->LastFlushStatus = status;
        if (status == 0) {
            d->FlushOk++;
            Ext->Dirty = FALSE;
        } else {
            d->FlushErrors++;
            d->LastIoStatus = status;
            d->LastFailCsts = NvmeRd(Ext, NVME_REG_CSTS);
            if (status == NVME_TIMEOUT_STATUS) {
                d->FlushTimeouts++;
                Ext->NeedRestart = TRUE;
            }
            NvmeLog(Ext, NVME_LOG_FLUSH_BASE | (status == NVME_TIMEOUT_STATUS ? 0xFFFUL : (status & 0x7FFUL)));
            if (status == NVME_TIMEOUT_STATUS) NvmeReport(Ext, "FLUSH timeout; CSTS", d->LastFailCsts, TRUE);
            else NvmeReport(Ext, "FLUSH failed; status", status, TRUE);
        }
    }
    d->FlushSeq++;
    r = &d->Ring[d->FlushSeq % USOSNVME_DIAG_RING];
    r->Seq = d->FlushSeq;
    r->Source = Source | how;
    r->Us = us;
    r->Status = status;
    return status;
}

static VOID NvmeIoFailed(PHW_DEVICE_EXTENSION Ext, PSCSI_REQUEST_BLOCK Srb, ULONG Status, BOOLEAN Write)
{
    ULONG sct, sc;

    Ext->Errors++;
#if defined(_WIN64) && !defined(USOSNVME_W9X)
    if (Status == NVME_BADPA_STATUS) {
        /* nothing reached the controller; LastStatus = refused PRP entry */
        Ext->BadPa++;
        NvmeLog(Ext, NVME_LOG_BAD_PA);
        NvmeReport(Ext, "unusable data address from ScsiPort, request failed; PRP entry", Ext->LastStatus, TRUE);
        NvmeSetSense(Ext, Srb, SCSI_SENSE_HARDWARE_ERROR, 0x44, 0);
        return;
    }
#endif
    Ext->LastStatus = Status;
    Ext->Diag.LastIoStatus = Status;
    Ext->Diag.LastFailCsts = NvmeRd(Ext, NVME_REG_CSTS);
    if (Status == NVME_TIMEOUT_STATUS) {
        Ext->Timeouts++;
        Ext->NeedRestart = TRUE;          /* re-create the queues before the next command */
        NvmeLog(Ext, NVME_LOG_IO_TIMEOUT);
        NvmeReport(Ext, "I/O timeout, controller restarted; CSTS", NvmeRd(Ext, NVME_REG_CSTS), TRUE);
        NvmeSetSense(Ext, Srb, SCSI_SENSE_ABORTED_COMMAND, 0, 0);
        return;
    }
    NvmeLog(Ext, NVME_LOG_IO_ERROR);
    /* Generic status codes: a refused command is an ILLEGAL REQUEST (the
       disk class then stops sending an unsupported SYNCHRONIZE CACHE instead
       of failing the flush as a device error), a busy or interrupted one is
       retried; anything else stays a hardware error. */
    sct = (Status >> 8) & 7;
    sc = Status & 0xFF;
    if (sct == 0 && sc == 0x80)                                    /* LBA out of range */
        NvmeSetSense(Ext, Srb, SCSI_SENSE_ILLEGAL_REQUEST, 0x21, 0);
    else if (sct == 0 && sc == 0x01)                               /* invalid opcode */
        NvmeSetSense(Ext, Srb, SCSI_SENSE_ILLEGAL_REQUEST, 0x20, 0);
    else if (sct == 0 && (sc == 0x02 || sc == 0x0B))               /* invalid field / namespace */
        NvmeSetSense(Ext, Srb, SCSI_SENSE_ILLEGAL_REQUEST, 0x24, 0);
    else if (sct == 0 && sc == 0x82)                               /* namespace not ready */
        NvmeSetSense(Ext, Srb, SCSI_SENSE_NOT_READY, 0x04, 0x01);
    else if (sct == 0 && (sc == 0x07 || sc == 0x08 || sc == 0x21)) /* aborted / interrupted */
        NvmeSetSense(Ext, Srb, SCSI_SENSE_ABORTED_COMMAND, 0, 0);
    else if (sct == 2)                                             /* media errors */
        NvmeSetSense(Ext, Srb, SCSI_SENSE_MEDIUM_ERROR, Write ? 0x0C : 0x11, 0);
    else
        NvmeSetSense(Ext, Srb, SCSI_SENSE_HARDWARE_ERROR, 0x44, 0);
}

static VOID NvmeReadWrite(PHW_DEVICE_EXTENSION Ext, PSCSI_REQUEST_BLOCK Srb, BOOLEAN Write)
{
    PUCHAR cdb = Srb->Cdb;
    ULONG lbaLo, lbaHi = 0, blocks, chunk, status, endLo, endHi;
    BOOLEAN fua = FALSE;
    PUCHAR va = (PUCHAR)Srb->DataBuffer;

    switch (cdb[0]) {
    case SCSIOP_READ6:
    case SCSIOP_WRITE6:
        lbaLo = ((ULONG)(cdb[1] & 0x1F) << 16) | ((ULONG)cdb[2] << 8) | cdb[3];
        blocks = cdb[4] ? cdb[4] : 256;
        break;
    case 0x88:  /* READ(16) */
    case 0x8A:  /* WRITE(16) */
        lbaHi = NvmeGetBe32(cdb + 2);
        lbaLo = NvmeGetBe32(cdb + 6);
        blocks = NvmeGetBe32(cdb + 10);
        fua = (BOOLEAN)((cdb[1] & 0x08) != 0);
        break;
    case 0xA8:  /* READ(12) */
    case 0xAA:  /* WRITE(12) */
        lbaLo = NvmeGetBe32(cdb + 2);
        blocks = NvmeGetBe32(cdb + 6);
        fua = (BOOLEAN)((cdb[1] & 0x08) != 0);
        break;
    default:    /* READ(10) / WRITE(10) */
        lbaLo = NvmeGetBe32(cdb + 2);
        blocks = ((ULONG)cdb[7] << 8) | cdb[8];
        fua = (BOOLEAN)((cdb[1] & 0x08) != 0);
        break;
    }
    if (blocks == 0) {
        Srb->DataTransferLength = 0;
        Srb->SrbStatus = SRB_STATUS_SUCCESS;
        Srb->ScsiStatus = SCSISTAT_GOOD;
        return;
    }
    /* range check: lba + blocks <= NSZE */
    endLo = lbaLo + blocks;
    endHi = lbaHi + (endLo < lbaLo ? 1 : 0);
    if (endHi > Ext->NsBlocksHi || (endHi == Ext->NsBlocksHi && endLo > Ext->NsBlocksLo)) {
        NvmeSetSense(Ext, Srb, SCSI_SENSE_ILLEGAL_REQUEST, 0x21, 0);
        return;
    }
    if (blocks > (Srb->DataTransferLength >> 9) || va == NULL || ((ULONG_PTR)va & 3)) {
        NvmeSetSense(Ext, Srb, SCSI_SENSE_ILLEGAL_REQUEST, 0x24, 0);
        return;
    }
    while (blocks) {
        chunk = Ext->MaxChunkBytes >> 9;
        if (chunk > blocks) chunk = blocks;
#ifdef USOSNVME_W9X
        /* the run of the buffer that one PRP set can describe (may be fewer
           blocks than asked); 0 = a fragment not on a 512-byte boundary */
        chunk = NvmeRwPrps9x(Ext, Srb, va, chunk);
        if (chunk == 0) {
            Ext->Errors++;
            NvmeReport(Ext, "buffer fragment not 512-byte aligned; VA", (ULONG)va, TRUE);
            NvmeSetSense(Ext, Srb, SCSI_SENSE_ILLEGAL_REQUEST, 0x24, 0);
            return;
        }
#endif
        status = NvmeRw(Ext, Srb, Write, va, lbaLo, lbaHi, chunk, fua);
        if (status != 0) {
            NvmeIoFailed(Ext, Srb, status, Write);
            return;
        }
        if (Write) Ext->Writes++; else Ext->Reads++;
        va += chunk << 9;
        blocks -= chunk;
        if (lbaLo + chunk < lbaLo) lbaHi++;
        lbaLo += chunk;
    }
    Srb->SrbStatus = SRB_STATUS_SUCCESS;
    Srb->ScsiStatus = SCSISTAT_GOOD;
}

static VOID NvmeExecuteScsi(PHW_DEVICE_EXTENSION Ext, PSCSI_REQUEST_BLOCK Srb)
{
    PUCHAR cdb = Srb->Cdb;
    ULONG status;

    switch (cdb[0]) {
    case SCSIOP_INQUIRY:
        NvmeInquiry(Ext, Srb);
        break;
    case SCSIOP_TEST_UNIT_READY:
    case SCSIOP_START_STOP_UNIT:
    case SCSIOP_MEDIUM_REMOVAL:
    case SCSIOP_RESERVE_UNIT:
    case SCSIOP_RELEASE_UNIT:
    case SCSIOP_VERIFY:
    case 0x8F:  /* VERIFY(16) */
    case SCSIOP_SEEK:
    case SCSIOP_REZERO_UNIT:
    case SCSIOP_MODE_SELECT:
    case SCSIOP_MODE_SELECT10:
        Srb->DataTransferLength = 0;
        Srb->SrbStatus = SRB_STATUS_SUCCESS;
        Srb->ScsiStatus = SCSISTAT_GOOD;
        break;
    case SCSIOP_READ_CAPACITY:
        NvmeReadCapacity(Ext, Srb, FALSE);
        break;
    case 0x9E:  /* SERVICE ACTION IN(16) */
        if ((cdb[1] & 0x1F) == 0x10) NvmeReadCapacity(Ext, Srb, TRUE);
        else NvmeSetSense(Ext, Srb, SCSI_SENSE_ILLEGAL_REQUEST, 0x24, 0);
        break;
    case SCSIOP_MODE_SENSE:
        NvmeModeSense(Ext, Srb, FALSE);
        break;
    case SCSIOP_MODE_SENSE10:
        NvmeModeSense(Ext, Srb, TRUE);
        break;
    case SCSIOP_REQUEST_SENSE: {
        UCHAR s[18];
        NvmeZero(s, sizeof(s));
        s[0] = 0x70;
        s[2] = Ext->SenseKey;
        s[7] = 10;
        s[12] = Ext->Asc;
        s[13] = Ext->Ascq;
        Ext->SenseKey = Ext->Asc = Ext->Ascq = 0;
        NvmeReturnData(Srb, s, 18, cdb[4]);
        break;
    }
    case SCSIOP_READ6:
    case SCSIOP_READ:
    case 0xA8:
    case 0x88:
        NvmeReadWrite(Ext, Srb, FALSE);
        break;
    case SCSIOP_WRITE6:
    case SCSIOP_WRITE:
    case 0xAA:
    case 0x8A:
        NvmeReadWrite(Ext, Srb, TRUE);
        break;
    case SCSIOP_SYNCHRONIZE_CACHE:
    case 0x91:  /* SYNCHRONIZE CACHE(16) */
        status = NvmeFlush(Ext, USOSNVME_FLUSH_SYNC_CACHE);
        if (status != 0) NvmeIoFailed(Ext, Srb, status, TRUE);
        else {
            Srb->DataTransferLength = 0;
            Srb->SrbStatus = SRB_STATUS_SUCCESS;
            Srb->ScsiStatus = SCSISTAT_GOOD;
        }
        break;
    default:
        NvmeSetSense(Ext, Srb, SCSI_SENSE_ILLEGAL_REQUEST, 0x20, 0);
        break;
    }
}

/* IOCTL_SCSI_MINIPORT, signature "USOSNVME", code USOSNVME_DIAG_CODE: a copy
   of the diagnostics block after the SRB_IO_CONTROL header. Any other
   signature or code is refused. Nothing is sent to the controller. */
static VOID NvmeIoControl(PHW_DEVICE_EXTENSION Ext, PSCSI_REQUEST_BLOCK Srb)
{
    PUSOSNVME_SRB_IO_CONTROL h = (PUSOSNVME_SRB_IO_CONTROL)Srb->DataBuffer;
    static const CHAR sig[8] = { 'U', 'S', 'O', 'S', 'N', 'V', 'M', 'E' };
    PUSOSNVME_DIAG d = &Ext->Diag;
    ULONG i;

    Srb->SrbStatus = SRB_STATUS_INVALID_REQUEST;
    if (h == NULL || Srb->DataTransferLength < sizeof(*h) || h->HeaderLength != sizeof(*h)) return;
    for (i = 0; i < 8; i++) if (h->Signature[i] != (UCHAR)sig[i]) return;
    if (h->ControlCode != USOSNVME_DIAG_CODE || h->Length < sizeof(USOSNVME_DIAG) ||
        Srb->DataTransferLength - sizeof(*h) < sizeof(USOSNVME_DIAG)) {
        h->ReturnCode = 1;
        return;
    }
    d->Version = USOSNVME_DIAG_VERSION;
    d->Size = sizeof(USOSNVME_DIAG);
    d->PciId = Ext->PciId;
    d->NvmeVersion = Ext->Version;
    d->Nsid = Ext->Nsid;
    d->State = (Ext->ControllerUp ? 1UL : 0) | (Ext->NamespaceReady ? 2UL : 0) |
               (Ext->NeedRestart ? 4UL : 0) | (Ext->Dirty ? 8UL : 0);
    d->Reads = Ext->Reads;
    d->Writes = Ext->Writes;
    d->Errors = Ext->Errors;
    d->Timeouts = Ext->Timeouts;
    NvmeCopy((PUCHAR)h + sizeof(*h), d, sizeof(USOSNVME_DIAG));
    h->ReturnCode = 0;
    h->Length = sizeof(USOSNVME_DIAG);
    Srb->SrbStatus = SRB_STATUS_SUCCESS;
}

static BOOLEAN NvmeStartIo(IN PVOID DeviceExtension, IN PSCSI_REQUEST_BLOCK Srb)
{
    PHW_DEVICE_EXTENSION ext = (PHW_DEVICE_EXTENSION)DeviceExtension;

    switch (Srb->Function) {
    case SRB_FUNCTION_EXECUTE_SCSI:
        if (Srb->PathId != 0 || Srb->TargetId != 0 || Srb->Lun != 0) {
            Srb->SrbStatus = SRB_STATUS_SELECTION_TIMEOUT;
            break;
        }
        if (!ext->ControllerUp || ext->NeedRestart) (VOID)NvmeStartController(ext);
        if (!ext->ControllerUp || !ext->NamespaceReady) {
            Srb->SrbStatus = SRB_STATUS_SELECTION_TIMEOUT;
            break;
        }
        NvmeExecuteScsi(ext, Srb);
        break;
    case SRB_FUNCTION_FLUSH:
        /* the SYNCHRONIZE CACHE just before carries any error; after a good
           one this is answered without a command (NvmeFlush) */
        if (ext->ControllerUp && ext->NamespaceReady && !ext->NeedRestart)
            (VOID)NvmeFlush(ext, USOSNVME_FLUSH_SRB_FLUSH);
        Srb->SrbStatus = SRB_STATUS_SUCCESS;
        break;
    case SRB_FUNCTION_SHUTDOWN:
#ifdef USOSNVME_NT6
        NvmeShutdown(ext);
#else
        if (ext->ControllerUp && ext->NamespaceReady && !ext->NeedRestart)
            (VOID)NvmeFlush(ext, USOSNVME_FLUSH_SHUTDOWN);
#endif
        Srb->SrbStatus = SRB_STATUS_SUCCESS;
        break;
    case SRB_FUNCTION_IO_CONTROL:
        NvmeIoControl(ext, Srb);
        break;
    case SRB_FUNCTION_ABORT_COMMAND:
    case SRB_FUNCTION_RESET_BUS:
    case SRB_FUNCTION_RESET_DEVICE:
    case SRB_FUNCTION_TERMINATE_IO:
    case SRB_FUNCTION_RELEASE_RECOVERY:
        Srb->SrbStatus = SRB_STATUS_SUCCESS;
        break;
    default:
        Srb->SrbStatus = SRB_STATUS_INVALID_REQUEST;
        break;
    }
#ifdef USOSNVME_W9X
    ext->Srbs++;
    if (Srb->Function == SRB_FUNCTION_EXECUTE_SCSI) {
        UCHAR op = Srb->Cdb[0];
        BOOLEAN rw = (BOOLEAN)(op == SCSIOP_READ || op == SCSIOP_WRITE || op == SCSIOP_READ6 || op == SCSIOP_WRITE6 ||
                               op == 0xA8 || op == 0xAA || op == 0x88 || op == 0x8A);
        if ((!rw || Srb->SrbStatus != SRB_STATUS_SUCCESS) && ext->DbgNonRw < 64) {
            NVME_LINE l;
            ext->DbgNonRw++;
            l.Len = 0;
            LineStr(&l, "USOSNVME 9x: cdb ");
            LineHex(&l, op, 2);
            if (!rw) {
                LineStr(&l, " t");
                LineDec(&l, Srb->TargetId);
                LineStr(&l, " l");
                LineDec(&l, Srb->Lun);
            }
            LineStr(&l, " len ");
            LineDec(&l, Srb->DataTransferLength);
            LineStr(&l, " srb ");
            LineHex(&l, Srb->SrbStatus, 2);
            if (rw) {
                LineStr(&l, " lba ");
                LineHex(&l, NvmeGetBe32(Srb->Cdb + 2), 8);
                LineStr(&l, " buf ");
                LineHex(&l, (ULONG)Srb->DataBuffer, 8);
                LineStr(&l, " sk ");
                LineHex(&l, ext->SenseKey, 1);
                LineStr(&l, "/");
                LineHex(&l, ext->Asc, 2);
                LineStr(&l, " st ");
                LineHex(&l, ext->LastStatus, 4);
            }
            l.Text[l.Len] = 0;
            NvmeDbgStr(l.Text);
            NvmeDbgStr("\n");
        }
    } else if (Srb->Function == SRB_FUNCTION_SHUTDOWN || Srb->Function == SRB_FUNCTION_FLUSH) {
        NvmeDbgCounters(ext, Srb->Function == SRB_FUNCTION_SHUTDOWN ? "shutdown" : "flush");
    }
    if ((ext->Srbs & 0x3FF) == 0) NvmeDbgCounters(ext, "io");
#endif
    ScsiPortNotification(RequestComplete, ext, Srb);
    ScsiPortNotification(NextRequest, ext, NULL);
    return TRUE;
}
