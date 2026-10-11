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
 *    min(MDTS, 128 KiB); FLUSH for SYNCHRONIZE CACHE, SRB flush/shutdown;
 *  - only namespaces with 512-byte LBAs and no metadata are exposed; any
 *    other format is refused (no disk) with an event-log entry and a line
 *    in the VGA text buffer.
 */
#include "usosnvme.h"

__declspec(dllimport) PVOID __stdcall MmMapIoSpace(IN PHYSICAL_ADDRESS PhysicalAddress,
                                                   IN ULONG NumberOfBytes, IN ULONG CacheType);

ULONG DriverEntry(IN PVOID DriverObject, IN PVOID Argument2);
static ULONG NvmeFindAdapter(IN PVOID DeviceExtension, IN PVOID Context, IN PVOID BusInformation,
                             IN PCHAR ArgumentString, IN OUT PPORT_CONFIGURATION_INFORMATION ConfigInfo,
                             OUT PBOOLEAN Again);
static BOOLEAN NvmeHwInitialize(IN PVOID DeviceExtension);
static BOOLEAN NvmeStartIo(IN PVOID DeviceExtension, IN PSCSI_REQUEST_BLOCK Srb);
static BOOLEAN NvmeInterrupt(IN PVOID DeviceExtension);
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

static VOID NvmeShowLine(PHW_DEVICE_EXTENSION Ext, NVME_LINE *l, BOOLEAN Error)
{
    PHYSICAL_ADDRESS vga;
    ULONG i;
    USHORT attr = Error ? 0x4F00 : 0x1F00;

    if (Ext->Vga == NULL) {
        vga.LowPart = 0xB8000;
        vga.HighPart = 0;
        Ext->Vga = (PUSHORT)MmMapIoSpace(vga, 80 * 25 * 2, 0 /* non-cached */);
        if (Ext->Vga == NULL) return;
    }
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

#ifdef USOSNVME_NT351
/* NT 3.x: the USOS NT 3.x MBR may hide the PCI BIOS from NTDETECT (boards
   whose PCI BIOS reports a last bus >= 8), so the HAL can have no PCI bus
   handler. Configuration mechanism 1 through ports CF8h / CFCh instead. */
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

static VOID NvmeCfgSelect(ULONG Bus, ULONG Slot, ULONG Offset)
{
    PCI_SLOT_NUMBER slot;
    slot.u.AsULONG = Slot;
    ScsiPortWritePortUlong((PULONG)NvmeCfgPorts,
                           0x80000000UL | ((Bus & 0xFF) << 16) |
                           ((ULONG)slot.u.bits.DeviceNumber << 11) |
                           ((ULONG)slot.u.bits.FunctionNumber << 8) | (Offset & 0xFC));
}

static ULONG NvmeCfgRead32(ULONG Bus, ULONG Slot, ULONG Offset)
{
    NvmeCfgSelect(Bus, Slot, Offset);
    return ScsiPortReadPortUlong((PULONG)(NvmeCfgPorts + 4));
}

static VOID NvmeCfgWrite16(ULONG Bus, ULONG Slot, ULONG Offset, USHORT Value)
{
    NvmeCfgSelect(Bus, Slot, Offset);
    ScsiPortWritePortUshort((PUSHORT)(NvmeCfgPorts + 4 + (Offset & 2)), Value);
}
#endif

/* FALSE for an empty slot; *BusMissing when the bus does not exist */
static BOOLEAN NvmeReadPci(PHW_DEVICE_EXTENSION Ext, ULONG Bus, ULONG Slot,
                           PPCI_COMMON_CONFIG Cfg, PBOOLEAN BusMissing)
{
#ifdef USOSNVME_NT351
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
#ifdef USOSNVME_NT351
    NvmeCfgWrite16(Bus, Slot, 0x04, Command);
#else
    ScsiPortSetBusDataByOffset(Ext, PCIConfiguration, Bus, Slot, &Command, 0x04, sizeof(USHORT));
#endif
}

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

    Cmd->Cdw0 = (Cmd->Cdw0 & 0x0000FFFF) | (cid << 16);
    for (i = 0; i < sizeof(NVME_SQE) / 4; i++) dst[i] = src[i];
    Q->SqTail++;
    if (Q->SqTail == Q->Depth) Q->SqTail = 0;
    NvmeWr(Ext, Q->SqDoorbell, Q->SqTail);
    return cid;
}

/* Status: 0 = success, 0xFFFFFFFF = timeout, else (SCT << 8) | SC */
#define NVME_TIMEOUT_STATUS 0xFFFFFFFFUL

static ULONG NvmeWait(PHW_DEVICE_EXTENSION Ext, PNVME_QUEUE Q, ULONG Cid, PULONG Dw0, ULONG TimeoutUs)
{
    ULONG waited = 0, spins = 0;

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
                return (dw3 >> 17) & 0x7FF;   /* SC 7:0, SCT 10:8 */
            }
            continue;   /* a stale completion; keep looking for ours */
        }
        if (waited >= TimeoutUs) return NVME_TIMEOUT_STATUS;
        if ((++spins & 0x3FF) == 0 && NvmeControllerDead(Ext)) return NVME_TIMEOUT_STATUS;
        ScsiPortStallExecution(2);
        waited += 2;
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
    Q->SqPhys = Ext->UncachedPhys;
    Q->SqPhys.LowPart += SqPage * NVME_PAGE;
    Q->CqPhys = Ext->UncachedPhys;
    Q->CqPhys.LowPart += CqPage * NVME_PAGE;
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
    ULONG status, cc, mdts, nsid, flbas, lbaf, ms, lbads;

    Ext->ControllerUp = FALSE;
    Ext->NamespaceReady = FALSE;
    Ext->NeedRestart = FALSE;
    Ext->InitStage = 1;

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
    Ext->MaxChunkBytes = NVME_MAX_TRANSFER;
    if (mdts != 0 && mdts < 16 && (NVME_PAGE << mdts) < Ext->MaxChunkBytes) Ext->MaxChunkBytes = NVME_PAGE << mdts;

    /* 5. one I/O queue pair (Number of Queues first; some controllers want it) */
    Ext->InitStage = 6;
    NvmeZero(&c, sizeof(c));
    c.Cdw0 = NVME_ADM_SET_FEATURE;
    c.Cdw10 = NVME_FEAT_NUM_QUEUES;
    c.Cdw11 = 0;                         /* 1 SQ, 1 CQ (0-based) */
    (VOID)NvmeExec(Ext, &Ext->Admin, &c, NVME_ADMIN_TIMEOUT_US, NULL);

    NvmeQueueInit(Ext, &Ext->Io, 1, NVME_PG_IOSQ, NVME_PG_IOCQ, NVME_IO_DEPTH);
    NvmeZero(&c, sizeof(c));
    c.Cdw0 = NVME_ADM_CREATE_CQ;
    c.Prp1Lo = Ext->Io.CqPhys.LowPart;
    c.Prp1Hi = Ext->Io.CqPhys.HighPart;
    c.Cdw10 = ((NVME_IO_DEPTH - 1UL) << 16) | 1;
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
    c.Cdw10 = ((NVME_IO_DEPTH - 1UL) << 16) | 1;
    c.Cdw11 = (1UL << 16) | 1;           /* CQ 1, physically contiguous */
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
    init.HwInterrupt = NvmeInterrupt;
    init.HwFindAdapter = NvmeFindAdapter;
    init.HwResetBus = NvmeResetBus;
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
    if (bar.LowPart == 0 && bar.HighPart == 0) return SP_RETURN_ERROR;

    /* memory decode + bus master on; INTx off (the driver polls) */
    cmd = (USHORT)(cfg.Command | 0x0006 | 0x0400);
    NvmeWritePciCommand(ext, bus, slot, cmd);

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
    ConfigInfo->InterruptMode = LevelSensitive;
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
    ext->UncachedPhys = pa;
    ext->UncachedPhys.LowPart += i;
    ext->Ident = ext->Uncached + NVME_PG_IDENT * NVME_PAGE;
    ext->IdentPhys = ext->UncachedPhys;
    ext->IdentPhys.LowPart += NVME_PG_IDENT * NVME_PAGE;
    ext->PrpList = (PULONG)(ext->Uncached + NVME_PG_PRPLIST * NVME_PAGE);
    ext->PrpListPhys = ext->UncachedPhys;
    ext->PrpListPhys.LowPart += NVME_PG_PRPLIST * NVME_PAGE;
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

static BOOLEAN NvmeInterrupt(IN PVOID DeviceExtension)
{
    (VOID)DeviceExtension;
    return FALSE;        /* polled; INTx disabled, INTMS masked */
}

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

/* One READ / WRITE command for Blocks blocks at Va (dword aligned). */
static ULONG NvmeRw(PHW_DEVICE_EXTENSION Ext, PSCSI_REQUEST_BLOCK Srb, BOOLEAN Write, PUCHAR Va,
                    ULONG LbaLo, ULONG LbaHi, ULONG Blocks, BOOLEAN Fua)
{
    NVME_SQE c;
    SCSI_PHYSICAL_ADDRESS pa;
    ULONG len, bytes = Blocks << 9, first, rest, n;
    PUCHAR next;

    NvmeZero(&c, sizeof(c));
    c.Cdw0 = Write ? NVME_NVM_WRITE : NVME_NVM_READ;
    c.Nsid = Ext->Nsid;
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
    c.Cdw10 = LbaLo;
    c.Cdw11 = LbaHi;
    c.Cdw12 = (Blocks - 1) | (Fua ? (1UL << 30) : 0);
    return NvmeExec(Ext, &Ext->Io, &c, NVME_IO_TIMEOUT_US, NULL);
}

static ULONG NvmeFlush(PHW_DEVICE_EXTENSION Ext)
{
    NVME_SQE c;
    NvmeZero(&c, sizeof(c));
    c.Cdw0 = NVME_NVM_FLUSH;
    c.Nsid = Ext->Nsid;
    Ext->Flushes++;
    return NvmeExec(Ext, &Ext->Io, &c, NVME_IO_TIMEOUT_US, NULL);
}

static VOID NvmeIoFailed(PHW_DEVICE_EXTENSION Ext, PSCSI_REQUEST_BLOCK Srb, ULONG Status, BOOLEAN Write)
{
    Ext->Errors++;
    Ext->LastStatus = Status;
    if (Status == NVME_TIMEOUT_STATUS) {
        Ext->Timeouts++;
        Ext->NeedRestart = TRUE;          /* re-create the queues before the next command */
        NvmeLog(Ext, NVME_LOG_IO_TIMEOUT);
        NvmeReport(Ext, "I/O timeout, controller restarted; CSTS", NvmeRd(Ext, NVME_REG_CSTS), TRUE);
        NvmeSetSense(Ext, Srb, SCSI_SENSE_ABORTED_COMMAND, 0, 0);
        return;
    }
    NvmeLog(Ext, NVME_LOG_IO_ERROR);
    if (((Status >> 8) & 7) == 0 && (Status & 0xFF) == 0x80)       /* LBA out of range */
        NvmeSetSense(Ext, Srb, SCSI_SENSE_ILLEGAL_REQUEST, 0x21, 0);
    else if (((Status >> 8) & 7) == 2)                               /* media errors */
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
        status = NvmeFlush(Ext);
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
    case SRB_FUNCTION_SHUTDOWN:
        if (ext->ControllerUp && ext->NamespaceReady && !ext->NeedRestart) (VOID)NvmeFlush(ext);
        Srb->SrbStatus = SRB_STATUS_SUCCESS;
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
    ScsiPortNotification(RequestComplete, ext, Srb);
    ScsiPortNotification(NextRequest, ext, NULL);
    return TRUE;
}
