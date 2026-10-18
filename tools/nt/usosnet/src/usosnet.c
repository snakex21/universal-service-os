/*
 * usosnet - USOS own Ethernet NDIS 5.0 miniport: shared NDIS core.
 *
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Written from the public NDIS 5.0 miniport documentation (Windows 2000 /
 * Windows 98 DDK docs, WDK 7.1 ndis.h). Chip programming lives in the
 * backends (usosnet_igb.c). See usosnet.h for the rules that keep this one
 * binary loadable by the Windows 98 / Me NDIS.VXD as well as by NDIS.SYS on
 * Windows 2000 / XP.
 *
 * Data path (copy based, simple and the same on every OS):
 *   TX  MiniportSend copies the packet into a pre-allocated 2 KiB DMA
 *       buffer of the next free descriptor and returns SUCCESS at once;
 *   RX  every descriptor owns a 2 KiB DMA buffer; MiniportHandleInterrupt
 *       indicates each frame with NdisMEthIndicateReceive (the full frame
 *       is the lookahead, MiniportTransferData copies from the same
 *       buffer while the indication runs) and hands the buffer back.
 */
#include "usosnet.h"
#include "usosnet_irq.h"

#pragma warning(disable:4054 4055 4152 4201 4214)

long __cdecl _InterlockedExchange(long volatile *Target, long Value);
long __cdecl _InterlockedOr(long volatile *Target, long Value);
unsigned char __inbyte(unsigned short Port);
void __outbyte(unsigned short Port, unsigned char Data);
#pragma intrinsic(_InterlockedExchange, _InterlockedOr, __inbyte, __outbyte)

/* NdisQueryBuffer is a macro over the MDL on NT builds; 9x NDIS buffers are
 * no MDLs, so call the function NDIS.SYS / NDIS.VXD export. */
#undef NdisQueryBuffer
EXPORT VOID NdisQueryBuffer(IN PNDIS_BUFFER Buffer, OUT PVOID *VirtualAddress OPTIONAL, OUT PUINT Length);

NDIS_HANDLE g_Wrapper;

/* counters of the last halted adapter, written as UsosnetLast* at the next
 * start (Device Manager: disable + enable the card, then DIAG.BAT) */
enum { LS_ISRCALLS, LS_ISR, LS_RX, LS_RXTIMER, LS_TX, LS_TXDONE, LS_HWRX, LS_HWTX, LS_FLAGS, LS_COUNT };
static ULONG g_Last[LS_COUNT];
static BOOLEAN g_LastValid;

static const USOSNET_CHIP g_Chips[] = {
    { 0x8086, 0x1539, CHIP_IGB_I210 | CHIP_IGB_I211, "Intel I211", &IgbOps },
    { 0x8086, 0x1533, CHIP_IGB_I210, "Intel I210", &IgbOps },
    { 0x8086, 0x1536, CHIP_IGB_I210, "Intel I210 (fiber)", &IgbOps },
    { 0x8086, 0x1537, CHIP_IGB_I210, "Intel I210 (SerDes)", &IgbOps },
    { 0x8086, 0x1538, CHIP_IGB_I210, "Intel I210 (SGMII)", &IgbOps },
    { 0x8086, 0x157B, CHIP_IGB_I210, "Intel I210 (flashless)", &IgbOps },
    { 0x8086, 0x157C, CHIP_IGB_I210, "Intel I210 (SerDes, flashless)", &IgbOps },
    { 0x8086, 0x10C9, CHIP_IGB_82576, "Intel 82576", &IgbOps },
    { 0x8086, 0x10E6, CHIP_IGB_82576, "Intel 82576 (fiber)", &IgbOps },
    { 0x8086, 0x10E7, CHIP_IGB_82576, "Intel 82576 (SerDes)", &IgbOps },
    { 0x8086, 0x10E8, CHIP_IGB_82576, "Intel 82576 (quad)", &IgbOps },
    { 0x8086, 0x1526, CHIP_IGB_82576, "Intel 82576 (quad ET2)", &IgbOps },
};

static const NDIS_OID g_Oids[] = {
    OID_GEN_SUPPORTED_LIST, OID_GEN_HARDWARE_STATUS, OID_GEN_MEDIA_SUPPORTED,
    OID_GEN_MEDIA_IN_USE, OID_GEN_MAXIMUM_LOOKAHEAD, OID_GEN_MAXIMUM_FRAME_SIZE,
    OID_GEN_LINK_SPEED, OID_GEN_TRANSMIT_BUFFER_SPACE, OID_GEN_RECEIVE_BUFFER_SPACE,
    OID_GEN_TRANSMIT_BLOCK_SIZE, OID_GEN_RECEIVE_BLOCK_SIZE, OID_GEN_VENDOR_ID,
    OID_GEN_VENDOR_DESCRIPTION, OID_GEN_CURRENT_PACKET_FILTER, OID_GEN_CURRENT_LOOKAHEAD,
    OID_GEN_DRIVER_VERSION, OID_GEN_MAXIMUM_TOTAL_SIZE, OID_GEN_MAC_OPTIONS,
    OID_GEN_MEDIA_CONNECT_STATUS, OID_GEN_MAXIMUM_SEND_PACKETS, OID_GEN_VENDOR_DRIVER_VERSION,
    OID_GEN_XMIT_OK, OID_GEN_RCV_OK, OID_GEN_XMIT_ERROR, OID_GEN_RCV_ERROR, OID_GEN_RCV_NO_BUFFER,
    OID_GEN_RCV_CRC_ERROR,
    OID_802_3_PERMANENT_ADDRESS, OID_802_3_CURRENT_ADDRESS, OID_802_3_MULTICAST_LIST,
    OID_802_3_MAXIMUM_LIST_SIZE, OID_802_3_RCV_ERROR_ALIGNMENT, OID_802_3_XMIT_ONE_COLLISION,
    OID_802_3_XMIT_MORE_COLLISIONS,
    OID_PNP_CAPABILITIES, OID_PNP_SET_POWER, OID_PNP_QUERY_POWER,
};

static const char g_VendorDesc[] = "USOS Ethernet (usosnet)";

/* ------------------------------------------------------------------ */
/* helpers without imports                                             */

void UsZero(void *D, ULONG N)
{
    volatile UCHAR *p = (volatile UCHAR *)D;
    while (N--) *p++ = 0;
}

void UsCopy(void *D, const void *S, ULONG N)
{
    UCHAR *d = (UCHAR *)D;
    const UCHAR *s = (const UCHAR *)S;
    if (!(((ULONG_PTR)d | (ULONG_PTR)s) & 3)) {
        while (N >= 4) { *(ULONG *)d = *(const ULONG *)s; d += 4; s += 4; N -= 4; }
    }
    while (N--) *d++ = *s++;
}

BOOLEAN UsEqual(const void *A, const void *B, ULONG N)
{
    const UCHAR *a = (const UCHAR *)A, *b = (const UCHAR *)B;
    while (N--) if (*a++ != *b++) return FALSE;
    return TRUE;
}

/* ~1 us per read of the POST port 0x80 (ISA/LPC bus cycle); only a lower
 * bound is needed: every wait also polls a hardware condition. */
void UsStall(ULONG Us)
{
    while (Us--) (void)__inbyte(0x80);
}

static void PutC(PADAPTER A, char C)
{
    if (A && A->DebugPort) __outbyte((unsigned short)A->DebugPort, (unsigned char)C);
}

static void PutHex(PADAPTER A, ULONG V)
{
    int i;
    for (i = 28; i >= 0; i -= 4) PutC(A, "0123456789ABCDEF"[(V >> i) & 15]);
}

/* "USOSNET " + Fmt; %x prints V1 then V2 (8 hex digits) */
void UsLog(PADAPTER A, const char *Fmt, ULONG V1, ULONG V2)
{
    int n = 0;
    const char *p = "USOSNET ";
    if (!A || !A->DebugPort) return;
    while (*p) PutC(A, *p++);
    for (; *Fmt; Fmt++) {
        if (Fmt[0] == '%' && Fmt[1] == 'x') {
            PutHex(A, n++ ? V2 : V1);
            Fmt++;
        } else {
            PutC(A, *Fmt);
        }
    }
    PutC(A, '\n');
}

/* ------------------------------------------------------------------ */
/* registry                                                            */

static ULONG CfgInt(NDIS_HANDLE Cfg, NDIS_STRING *Key, ULONG Def)
{
    NDIS_STATUS st;
    PNDIS_CONFIGURATION_PARAMETER p = NULL;
    NdisReadConfiguration(&st, &p, Cfg, Key, NdisParameterInteger);
    if (st == NDIS_STATUS_SUCCESS && p && p->ParameterType == NdisParameterInteger)
        return p->ParameterData.IntegerData;
    NdisReadConfiguration(&st, &p, Cfg, Key, NdisParameterHexInteger);
    if (st == NDIS_STATUS_SUCCESS && p &&
        (p->ParameterType == NdisParameterHexInteger || p->ParameterType == NdisParameterInteger))
        return p->ParameterData.IntegerData;
    return Def;
}

static void CfgPut(NDIS_HANDLE Cfg, NDIS_STRING *Key, ULONG V)
{
    NDIS_STATUS st;
    NDIS_CONFIGURATION_PARAMETER p;
    UsZero(&p, sizeof(p));
    p.ParameterType = NdisParameterHexInteger;
    p.ParameterData.IntegerData = V;
    NdisWriteConfiguration(&st, Cfg, Key, &p);
}

static void WriteDiag(PADAPTER A, NDIS_HANDLE Cfg)
{
    NDIS_STRING kStage = NDIS_STRING_CONST("UsosnetStage");
    NDIS_STRING kError = NDIS_STRING_CONST("UsosnetError");
    NDIS_STRING kDev = NDIS_STRING_CONST("UsosnetDevice");
    NDIS_STRING kMmio = NDIS_STRING_CONST("UsosnetMmio");
    NDIS_STRING kIrq = NDIS_STRING_CONST("UsosnetIrq");
    NDIS_STRING kMacHi = NDIS_STRING_CONST("UsosnetMacHi");
    NDIS_STRING kMacLo = NDIS_STRING_CONST("UsosnetMacLo");
    NDIS_STRING kMacSrc = NDIS_STRING_CONST("UsosnetMacSource");
    NDIS_STRING kStatus = NDIS_STRING_CONST("UsosnetStatusReg");
    NDIS_STRING kCtrl = NDIS_STRING_CONST("UsosnetCtrlReg");
    NDIS_STRING kPhy = NDIS_STRING_CONST("UsosnetPhyBmsr");
    NDIS_STRING kPhyId = NDIS_STRING_CONST("UsosnetPhyId");
    NDIS_STRING kVer = NDIS_STRING_CONST("UsosnetVersion");
    NDIS_STRING kBarHi = NDIS_STRING_CONST("UsosnetBar0High");
    NDIS_STRING kPll = NDIS_STRING_CONST("UsosnetPllTries");
    if (!Cfg) return;
    CfgPut(Cfg, &kVer, (USOSNET_MAJOR << 16) | USOSNET_MINOR);
    CfgPut(Cfg, &kStage, A->Stage);
    CfgPut(Cfg, &kError, A->Error);
    CfgPut(Cfg, &kDev, ((ULONG)A->VendorId << 16) | A->DeviceId);
    CfgPut(Cfg, &kMmio, NdisGetPhysicalAddressLow(A->MmioPa));
    CfgPut(Cfg, &kIrq, (A->IrqLevel << 16) | (A->IrqVector & 0xFFFF));
    CfgPut(Cfg, &kMacHi, ((ULONG)A->CurAddr[0] << 16) | ((ULONG)A->CurAddr[1] << 8) | A->CurAddr[2]);
    CfgPut(Cfg, &kMacLo, ((ULONG)A->CurAddr[3] << 16) | ((ULONG)A->CurAddr[4] << 8) | A->CurAddr[5]);
    CfgPut(Cfg, &kMacSrc, A->MacSource);
    CfgPut(Cfg, &kStatus, A->StatusAtInit);
    CfgPut(Cfg, &kCtrl, A->CtrlAtInit);
    CfgPut(Cfg, &kPhy, A->PhyBmsr);
    CfgPut(Cfg, &kPhyId, A->PhyId);
    CfgPut(Cfg, &kBarHi, A->Bar0High);
    CfgPut(Cfg, &kPll, A->PllTries);
    if (g_LastValid) {
        NDIS_STRING k[LS_COUNT] = {
            NDIS_STRING_CONST("UsosnetLastIsrCalls"), NDIS_STRING_CONST("UsosnetLastIsr"),
            NDIS_STRING_CONST("UsosnetLastRx"), NDIS_STRING_CONST("UsosnetLastRxTimer"),
            NDIS_STRING_CONST("UsosnetLastTx"), NDIS_STRING_CONST("UsosnetLastTxDone"),
            NDIS_STRING_CONST("UsosnetLastHwRx"), NDIS_STRING_CONST("UsosnetLastHwTx"),
            NDIS_STRING_CONST("UsosnetLastFlags"),
        };
        ULONG i;
        for (i = 0; i < LS_COUNT; i++) CfgPut(Cfg, &k[i], g_Last[i]);
    }
}

/* ------------------------------------------------------------------ */
/* DMA memory                                                          */

static BOOLEAN DmaAlloc(PADAPTER A, DMAMEM *M, ULONG Len, ULONG Align)
{
    ULONG pa, off, tries;
    /* exactly Len first (4 KiB pages stay one page); pad only if misaligned */
    for (tries = 0; tries < 2; tries++) {
        M->AllocLen = tries ? Len + Align : Len;
        NdisMAllocateSharedMemory(A->Handle, M->AllocLen, FALSE, &M->AllocVa, &M->AllocPa);
        if (!M->AllocVa) { M->AllocLen = 0; return FALSE; }
        if (NdisGetPhysicalAddressHigh(M->AllocPa) != 0) return FALSE;  /* freed by FreeAll */
        pa = NdisGetPhysicalAddressLow(M->AllocPa);
        off = (Align - (pa & (Align - 1))) & (Align - 1);
        if (!off || tries) break;
        NdisMFreeSharedMemory(A->Handle, M->AllocLen, FALSE, M->AllocVa, M->AllocPa);
        M->AllocVa = NULL;
    }
    UsZero(M->AllocVa, M->AllocLen);
    M->Va = (PUCHAR)M->AllocVa + off;
    M->Pa = pa + off;
    return TRUE;
}

static void DmaFree(PADAPTER A, DMAMEM *M)
{
    if (M->AllocVa) NdisMFreeSharedMemory(A->Handle, M->AllocLen, FALSE, M->AllocVa, M->AllocPa);
    M->AllocVa = NULL;
    M->AllocLen = 0;
}

static BOOLEAN AllocRings(PADAPTER A)
{
    ULONG i, j;
    if (!DmaAlloc(A, &A->RxRing, RX_COUNT * 16, 128)) return FALSE;
    if (!DmaAlloc(A, &A->TxRing, TX_COUNT * 16, 128)) return FALSE;
    for (i = 0; i < RX_COUNT / BUFS_PER_PAGE; i++) {
        if (!DmaAlloc(A, &A->RxPage[i], BUF_SIZE * BUFS_PER_PAGE, 64)) return FALSE;
        for (j = 0; j < BUFS_PER_PAGE; j++) {
            A->RxBuf[i * BUFS_PER_PAGE + j] = A->RxPage[i].Va + j * BUF_SIZE;
            A->RxBufPa[i * BUFS_PER_PAGE + j] = A->RxPage[i].Pa + j * BUF_SIZE;
        }
    }
    for (i = 0; i < TX_COUNT / BUFS_PER_PAGE; i++) {
        if (!DmaAlloc(A, &A->TxPage[i], BUF_SIZE * BUFS_PER_PAGE, 64)) return FALSE;
        for (j = 0; j < BUFS_PER_PAGE; j++) {
            A->TxBuf[i * BUFS_PER_PAGE + j] = A->TxPage[i].Va + j * BUF_SIZE;
            A->TxBufPa[i * BUFS_PER_PAGE + j] = A->TxPage[i].Pa + j * BUF_SIZE;
        }
    }
    return TRUE;
}

static VOID MpShutdown(PVOID Ctx)
{
    /* stop DMA before the warm reboot / power-off (no NDIS calls here) */
    PADAPTER A = (PADAPTER)Ctx;
    if (A->Mmio) { A->Chip->Ops->IrqDisable(A); A->Chip->Ops->Stop(A); }
}

static void FreeAll(PADAPTER A)
{
    ULONG i;
    BOOLEAN cancelled;
    if (A->Shutdown) NdisMDeregisterAdapterShutdownHandler(A->Handle);
    A->Shutdown = FALSE;
    if (A->TimerInit) NdisMCancelTimer(&A->Timer, &cancelled);
    A->TimerInit = FALSE;
    if (A->IrqRegistered) NdisMDeregisterInterrupt(&A->Interrupt);
    A->IrqRegistered = FALSE;
    DmaFree(A, &A->RxRing);
    DmaFree(A, &A->TxRing);
    for (i = 0; i < RX_COUNT / BUFS_PER_PAGE; i++) DmaFree(A, &A->RxPage[i]);
    for (i = 0; i < TX_COUNT / BUFS_PER_PAGE; i++) DmaFree(A, &A->TxPage[i]);
    if (A->MapRegs) NdisMFreeMapRegisters(A->Handle);
    A->MapRegs = FALSE;
    if (A->Mmio) NdisMUnmapIoSpace(A->Handle, (PVOID)A->Mmio, A->MmioLen);
    A->Mmio = NULL;
    NdisFreeMemory(A, sizeof(ADAPTER), 0);
}

/* ------------------------------------------------------------------ */
/* link                                                                */

static BOOLEAN CheckLink(PADAPTER A)
{
    BOOLEAN up = FALSE, full = FALSE;
    ULONG mbps = 0;
    A->Chip->Ops->LinkState(A, &up, &mbps, &full);
    if (A->LinkReported && up == A->LinkUp && mbps == A->LinkMbps) return FALSE;
    A->LinkUp = up;
    A->LinkMbps = mbps;
    A->FullDuplex = full;
    A->LinkChanges++;
    UsLog(A, "link %x speed %x", up, mbps);
    NdisMIndicateStatus(A->Handle, up ? NDIS_STATUS_MEDIA_CONNECT : NDIS_STATUS_MEDIA_DISCONNECT, NULL, 0);
    NdisMIndicateStatusComplete(A->Handle);
    return TRUE;
}

/* ------------------------------------------------------------------ */
/* runtime diagnostics: NdisWriteErrorLogEntry (Windows 9x NDIS.VXD:
 * C:\WINDOWS\NDISLOG.TXT; Windows 2000 / XP: System event log, source
 * USOSNET). Every round = 3 entries of 10 values, tagged USN1..USN3
 * (0x55534E31..), the first round also USN4. See README.md. */

#define EV_PERIODIC     0
#define EV_IRQ_POLL     1       /* IRQ watchdog switched to timer polling */
#define EV_TX_STALL     2       /* TX descriptors pending 3 s without completion */
#define EV_LINK         3

static ULONG DiagFlags(PADAPTER A, ULONG Event)
{
    return (A->PollMode & 3) | (A->LinkUp ? 4UL : 0) | (A->FullDuplex ? 8UL : 0) |
           ((Event & 0xFF) << 8) | ((A->LinkMbps & 0xFFFF) << 16);
}

static void DiagLog(PADAPTER A, ULONG Event, ULONG Sec)
{
    ULONG r[DIAG_REGS], pci = 0;
    if (A->LogCount >= LOG_MAX) return;
    A->LogCount++;
    A->Chip->Ops->Diag(A, r);
    NdisReadPciSlotInformation(A->Handle, 0, 4, &pci, 4);   /* bit 19 = PCI status INTx pending */
    NdisWriteErrorLogEntry(A->Handle, NDIS_ERROR_CODE_DRIVER_FAILURE, 10, 0x55534E31UL, Sec,
                           DiagFlags(A, Event), A->IsrCalls, A->IsrCount, A->DpcCount,
                           A->RxOk, A->RxByTimer, A->TxOk, A->TxDone);
    NdisWriteErrorLogEntry(A->Handle, NDIS_ERROR_CODE_DRIVER_FAILURE, 10, 0x55534E32UL, Sec,
                           A->TxErr, A->TxFull, A->RxErr, A->HwTpr, A->HwGprc, A->HwGptc,
                           A->HwMpc, A->HwRnbc);
    NdisWriteErrorLogEntry(A->Handle, NDIS_ERROR_CODE_DRIVER_FAILURE, 10, 0x55534E33UL, Sec,
                           r[DR_STATUS], r[DR_IMS], r[DR_RDH], r[DR_RDT], r[DR_TDH], r[DR_TDT],
                           pci, r[DR_RCTL]);
    if (A->LogCount == 1)
        NdisWriteErrorLogEntry(A->Handle, NDIS_ERROR_CODE_DRIVER_FAILURE, 10, 0x55534E34UL,
                               (A->IrqLevel << 16) | (A->IrqVector & 0xFFFF), A->RxRing.Pa, A->TxRing.Pa,
                               r[DR_CTRL], r[DR_TCTL], r[DR_RXDCTL], r[DR_TXDCTL], A->HwCrc,
                               (USOSNET_MAJOR << 16) | USOSNET_MINOR);
}

/* once a second: link, chip counters, IRQ and TX watchdogs, log schedule */
static void TimerSecond(PADAPTER A)
{
    ULONG sec = A->TimerCount / TICKS_PER_SEC;
    BOOLEAN linkChanged = CheckLink(A);

    A->Chip->Ops->Stats(A);
    if (!A->PollMode && UsosnetIrqBroken(sec, A->IsrCount, A->RxByTimer, A->LinkUp)) {
        /* INTx does not reach us: mask the chip so the pin is released, poll */
        A->PollMode = 2;
        A->Chip->Ops->IrqDisable(A);
        UsLog(A, "irq watchdog: poll, rx by timer %x", A->RxByTimer, 0);
        DiagLog(A, EV_IRQ_POLL, sec);
    }
    if (A->TxBusy && A->TxDone == A->TxLastClean) {
        if (++A->TxStallSec == 3) { A->TxStalls++; DiagLog(A, EV_TX_STALL, sec); }
    } else {
        A->TxStallSec = 0;
    }
    A->TxLastClean = A->TxDone;
    if (linkChanged && sec) DiagLog(A, EV_LINK, sec);
    if (sec == 3 || sec == 10 || sec == 30 || sec == 60 || (sec && sec % 300 == 0))
        DiagLog(A, EV_PERIODIC, sec);
}

static VOID TimerFn(PVOID S1, PVOID Ctx, PVOID S2, PVOID S3)
{
    PADAPTER A = (PADAPTER)Ctx;
    ULONG rx = A->RxOk;
    UNREFERENCED_PARAMETER(S1); UNREFERENCED_PARAMETER(S2); UNREFERENCED_PARAMETER(S3);
    A->TimerCount++;
    /* serialized miniport: the timer never runs beside MpSend / the DPC */
    A->Chip->Ops->RxPoll(A);
    if (!A->PollMode) A->RxByTimer += A->RxOk - rx;
    A->Chip->Ops->TxReclaim(A);
    if (A->TimerCount % TICKS_PER_SEC == 0) TimerSecond(A);
}

/* ------------------------------------------------------------------ */
/* RX indication (called by the backend from RxPoll)                   */

void UsIndicateRx(PADAPTER A, PUCHAR Frame, ULONG Len)
{
    if (Len < ETH_HDR || Len > ETH_MAX_FRAME + 4) { A->RxErr++; return; }
    if (!A->PacketFilter) return;
    A->CurRx = Frame;
    A->CurRxLen = Len;
    A->RxOk++;
    NdisMEthIndicateReceive(A->Handle, (NDIS_HANDLE)A, (PCHAR)Frame, ETH_HDR,
                            Frame + ETH_HDR, Len - ETH_HDR, Len - ETH_HDR);
    A->CurRx = NULL;
}

/* ------------------------------------------------------------------ */
/* miniport handlers                                                   */

static NDIS_STATUS MpInitialize(PNDIS_STATUS OpenErrorStatus, PUINT SelectedMediumIndex,
                                PNDIS_MEDIUM MediumArray, UINT MediumArraySize,
                                NDIS_HANDLE MiniportAdapterHandle, NDIS_HANDLE WrapperConfigurationContext)
{
    NDIS_STATUS st;
    PADAPTER A = NULL;
    NDIS_HANDLE cfg = NULL;
    NDIS_PHYSICAL_ADDRESS hi;
    UINT i;
    ULONG cfg32, bar0 = 0, bar0hi = 0;
    BOOLEAN memFound = FALSE;
    UCHAR resBuf[sizeof(NDIS_RESOURCE_LIST) + 12 * sizeof(CM_PARTIAL_RESOURCE_DESCRIPTOR)];
    PNDIS_RESOURCE_LIST res = (PNDIS_RESOURCE_LIST)resBuf;
    UINT resLen = sizeof(resBuf);
    PVOID netAddr;
    UINT netAddrLen;
    NDIS_STRING kPoll = NDIS_STRING_CONST("PollMode");
    NDIS_STRING kDbg = NDIS_STRING_CONST("DebugPort");
    NDIS_STRING kSkipPhy = NDIS_STRING_CONST("SkipPhy");

    UNREFERENCED_PARAMETER(OpenErrorStatus);

    for (i = 0; i < MediumArraySize; i++)
        if (MediumArray[i] == NdisMedium802_3) break;
    if (i == MediumArraySize) return NDIS_STATUS_UNSUPPORTED_MEDIA;
    *SelectedMediumIndex = i;

    NdisSetPhysicalAddressHigh(hi, 0);
    NdisSetPhysicalAddressLow(hi, 0xFFFFFFFF);
    st = NdisAllocateMemory((PVOID *)&A, sizeof(ADAPTER), 0, hi);
    if (st != NDIS_STATUS_SUCCESS || !A) return NDIS_STATUS_RESOURCES;
    UsZero(A, sizeof(ADAPTER));
    A->Handle = MiniportAdapterHandle;
    A->Stage = ST_ENTRY;
    A->PacketFilter = 0;
    A->Lookahead = ETH_MAX_DATA;

    NdisOpenConfiguration(&st, &cfg, WrapperConfigurationContext);
    if (st != NDIS_STATUS_SUCCESS) cfg = NULL;
    if (cfg) {
        A->PollMode = CfgInt(cfg, &kPoll, 0);
        A->DebugPort = CfgInt(cfg, &kDbg, 0) & 0xFFFF;
        A->SkipPhy = CfgInt(cfg, &kSkipPhy, 0);
    }
    A->Stage = ST_CONFIG;
    UsLog(A, "init v%x poll %x", (USOSNET_MAJOR << 16) | USOSNET_MINOR, A->PollMode);

    NdisMSetAttributesEx(MiniportAdapterHandle, (NDIS_HANDLE)A, 0,
                         NDIS_ATTRIBUTE_BUS_MASTER, NdisInterfacePci);

    /* PCI identity; memory decode + bus master on, INTx not disabled */
    cfg32 = 0;
    NdisReadPciSlotInformation(MiniportAdapterHandle, 0, 0, &cfg32, 4);
    A->VendorId = (USHORT)(cfg32 & 0xFFFF);
    A->DeviceId = (USHORT)(cfg32 >> 16);
    NdisReadPciSlotInformation(MiniportAdapterHandle, 0, 8, &cfg32, 4);
    A->RevId = (UCHAR)cfg32;
    for (i = 0; i < sizeof(g_Chips) / sizeof(g_Chips[0]); i++)
        if (g_Chips[i].Vendor == A->VendorId && g_Chips[i].Device == A->DeviceId) A->Chip = &g_Chips[i];
    UsLog(A, "pci %x rev %x", cfg32 = ((ULONG)A->VendorId << 16) | A->DeviceId, A->RevId);
    if (!A->Chip) { st = NDIS_STATUS_ADAPTER_NOT_FOUND; goto fail; }
    NdisReadPciSlotInformation(MiniportAdapterHandle, 0, 4, &cfg32, 4);
    cfg32 = (cfg32 & 0xFFFF) | 0x0006;
    cfg32 &= ~0x0400UL;
    NdisWritePciSlotInformation(MiniportAdapterHandle, 0, 4, &cfg32, 2);
    NdisReadPciSlotInformation(MiniportAdapterHandle, 0, 0x10, &bar0, 4);
    A->Stage = ST_PCI;

    /* BAR0 (CSR, 128 KiB) from config space; a 64-bit BAR has its high half at 0x14 */
    bar0hi = 0;
    if ((bar0 & 7) == 4) NdisReadPciSlotInformation(MiniportAdapterHandle, 0, 0x14, &bar0hi, 4);
    A->Bar0High = bar0hi;

    /* resources: the memory range at BAR0; else the first one of >= 128 KiB */
    NdisMQueryAdapterResources(&st, WrapperConfigurationContext, res, &resLen);
    if (st == NDIS_STATUS_SUCCESS) {
        for (i = 0; i < res->Count; i++) {
            PCM_PARTIAL_RESOURCE_DESCRIPTOR d = &res->PartialDescriptors[i];
            if (d->Type == CmResourceTypeMemory && d->u.Memory.Length >= 0x20000 &&
                NdisGetPhysicalAddressLow(d->u.Memory.Start) == (bar0 & ~0xFUL) &&
                (ULONG)NdisGetPhysicalAddressHigh(d->u.Memory.Start) == bar0hi) {
                A->MmioPa = d->u.Memory.Start;
                A->MmioLen = d->u.Memory.Length;
                memFound = TRUE;
            } else if (d->Type == CmResourceTypeInterrupt && !A->IrqVector && !A->IrqLevel) {
                A->IrqLevel = d->u.Interrupt.Level;
                A->IrqVector = d->u.Interrupt.Vector;
            }
        }
        for (i = 0; !memFound && i < res->Count; i++) {
            PCM_PARTIAL_RESOURCE_DESCRIPTOR d = &res->PartialDescriptors[i];
            if (d->Type == CmResourceTypeMemory && d->u.Memory.Length >= 0x20000) {
                A->MmioPa = d->u.Memory.Start;
                A->MmioLen = d->u.Memory.Length;
                memFound = TRUE;
            }
        }
    }
    if (!memFound && (bar0 & ~0xFUL) && !(bar0 & 1)) {
        /* no list (should not happen with PnP): BAR0 from config space */
        NdisSetPhysicalAddressHigh(A->MmioPa, bar0hi);
        NdisSetPhysicalAddressLow(A->MmioPa, bar0 & ~0xFUL);
        A->MmioLen = 0x20000;
    }
    if (!A->IrqLevel && !A->IrqVector) {
        NdisReadPciSlotInformation(MiniportAdapterHandle, 0, 0x3C, &cfg32, 4);
        A->IrqLevel = A->IrqVector = cfg32 & 0xFF;
    }
    UsLog(A, "bar0 %x irq %x", NdisGetPhysicalAddressLow(A->MmioPa), A->IrqVector);
    A->Stage = ST_RESOURCES;
    if (!A->MmioLen) { st = NDIS_STATUS_RESOURCE_CONFLICT; goto fail; }
    /* 32-bit only (9x cannot map above 4 GiB): firmware "Above 4G decoding" must be off */
    if (NdisGetPhysicalAddressHigh(A->MmioPa) != 0 || bar0hi) {
        UsLog(A, "bar0 above 4 GiB, high %x", bar0hi, 0);
        st = NDIS_STATUS_RESOURCE_CONFLICT;
        goto fail;
    }
    if (A->MmioLen > 0x20000) A->MmioLen = 0x20000;

    st = NdisMMapIoSpace((PVOID *)&A->Mmio, MiniportAdapterHandle, A->MmioPa, A->MmioLen);
    if (st != NDIS_STATUS_SUCCESS || !A->Mmio) { A->Mmio = NULL; st = NDIS_STATUS_RESOURCES; goto fail; }
    A->Stage = ST_MMIO;

    st = A->Chip->Ops->Reset(A);
    if (st != NDIS_STATUS_SUCCESS) goto fail;
    A->Stage = ST_RESET;

    if (!A->Chip->Ops->ReadMac(A, A->PermAddr)) { st = NDIS_STATUS_FAILURE; goto fail; }
    UsCopy(A->CurAddr, A->PermAddr, ETH_ALEN);
    if (cfg) {
        NdisReadNetworkAddress(&st, &netAddr, &netAddrLen, cfg);
        if (st == NDIS_STATUS_SUCCESS && netAddrLen == ETH_ALEN && !(((PUCHAR)netAddr)[0] & 1)) {
            UsCopy(A->CurAddr, netAddr, ETH_ALEN);
            A->MacSource |= 0x10;
        }
    }
    A->Chip->Ops->SetMac(A, A->CurAddr);
    UsLog(A, "mac %x%x", ((ULONG)A->CurAddr[0] << 24) | ((ULONG)A->CurAddr[1] << 16) |
          ((ULONG)A->CurAddr[2] << 8) | A->CurAddr[3], ((ULONG)A->CurAddr[4] << 24) | ((ULONG)A->CurAddr[5] << 16));
    A->Stage = ST_MAC;

    st = NdisMAllocateMapRegisters(MiniportAdapterHandle, 0, NDIS_DMA_32BITS, 1, BUF_SIZE);
    if (st != NDIS_STATUS_SUCCESS) goto fail;
    A->MapRegs = TRUE;
    if (!AllocRings(A)) { st = NDIS_STATUS_RESOURCES; goto fail; }
    A->Stage = ST_DMA;

    A->Chip->Ops->Start(A);
    A->Stage = ST_RINGS;

    if (!A->PollMode) {
        st = NdisMRegisterInterrupt(&A->Interrupt, MiniportAdapterHandle, A->IrqVector, A->IrqLevel,
                                    TRUE, TRUE, NdisInterruptLevelSensitive);
        if (st != NDIS_STATUS_SUCCESS) goto fail;
        A->IrqRegistered = TRUE;
    }
    A->Stage = ST_IRQ;

    if (!A->SkipPhy) A->Chip->Ops->PhyInit(A);
    A->Stage = ST_PHY;

    A->Chip->Ops->SetFilter(A);
    /* initial link state: OID_GEN_MEDIA_CONNECT_STATUS answers from it, the
     * timer indicates every later change */
    A->Chip->Ops->LinkState(A, &A->LinkUp, &A->LinkMbps, &A->FullDuplex);
    A->LinkReported = TRUE;
    if (!A->PollMode) A->Chip->Ops->IrqEnable(A);
    NdisMInitializeTimer(&A->Timer, MiniportAdapterHandle, TimerFn, A);
    A->TimerInit = TRUE;
    NdisMSetPeriodicTimer(&A->Timer, TICK_MS);
    NdisMRegisterAdapterShutdownHandler(MiniportAdapterHandle, A, MpShutdown);
    A->Shutdown = TRUE;
    A->Started = TRUE;
    A->Stage = ST_STARTED;
    UsLog(A, "started stage %x status %x", A->Stage, A->StatusAtInit);
    if (cfg) { WriteDiag(A, cfg); NdisCloseConfiguration(cfg); }
    return NDIS_STATUS_SUCCESS;

fail:
    A->Error = st;
    UsLog(A, "init failed stage %x status %x", A->Stage, st);
    if (A->Mmio) A->Chip->Ops->Stop(A);
    if (cfg) { WriteDiag(A, cfg); NdisCloseConfiguration(cfg); }
    FreeAll(A);
    return st;
}

static VOID MpHalt(NDIS_HANDLE Ctx)
{
    PADAPTER A = (PADAPTER)Ctx;
    BOOLEAN cancelled;
    UsLog(A, "halt rx %x tx %x", A->RxOk, A->TxOk);
    A->Chip->Ops->Stats(A);
    g_Last[LS_ISRCALLS] = A->IsrCalls;
    g_Last[LS_ISR] = A->IsrCount;
    g_Last[LS_RX] = A->RxOk;
    g_Last[LS_RXTIMER] = A->RxByTimer;
    g_Last[LS_TX] = A->TxOk;
    g_Last[LS_TXDONE] = A->TxDone;
    g_Last[LS_HWRX] = A->HwGprc;
    g_Last[LS_HWTX] = A->HwGptc;
    g_Last[LS_FLAGS] = DiagFlags(A, 0) | (A->TxStalls << 4);
    g_LastValid = TRUE;
    if (A->TimerInit) NdisMCancelTimer(&A->Timer, &cancelled);
    A->TimerInit = FALSE;
    A->Chip->Ops->IrqDisable(A);
    A->Chip->Ops->Stop(A);
    FreeAll(A);
}

static NDIS_STATUS MpReset(PBOOLEAN AddressingReset, NDIS_HANDLE Ctx)
{
    PADAPTER A = (PADAPTER)Ctx;
    UsLog(A, "reset %x", 0, 0);
    A->Chip->Ops->IrqDisable(A);
    A->Chip->Ops->Stop(A);
    if (A->Chip->Ops->Reset(A) != NDIS_STATUS_SUCCESS) return NDIS_STATUS_HARD_ERRORS;
    A->Chip->Ops->SetMac(A, A->CurAddr);
    A->Chip->Ops->Start(A);
    if (!A->SkipPhy) A->Chip->Ops->PhyInit(A);
    A->Chip->Ops->SetFilter(A);
    if (!A->PollMode) A->Chip->Ops->IrqEnable(A);
    *AddressingReset = TRUE;
    return NDIS_STATUS_SUCCESS;
}

static BOOLEAN MpCheckForHang(NDIS_HANDLE Ctx)
{
    UNREFERENCED_PARAMETER(Ctx);
    return FALSE;
}

static VOID MpIsr(PBOOLEAN Recognized, PBOOLEAN QueueDpc, NDIS_HANDLE Ctx)
{
    PADAPTER A = (PADAPTER)Ctx;
    ULONG cause;
    A->IsrCalls++;
    cause = A->Chip->Ops->IrqRead(A);         /* masks the chip when ours */
    if (!cause) { *Recognized = FALSE; *QueueDpc = FALSE; return; }
    _InterlockedOr(&A->PendingIrq, (long)cause);
    A->IsrCount++;
    *Recognized = TRUE;
    *QueueDpc = TRUE;
}

static VOID MpHandleInterrupt(NDIS_HANDLE Ctx)
{
    PADAPTER A = (PADAPTER)Ctx;
    ULONG cause = (ULONG)_InterlockedExchange(&A->PendingIrq, 0);
    UNREFERENCED_PARAMETER(cause);
    A->DpcCount++;
    A->Chip->Ops->RxPoll(A);
    A->Chip->Ops->TxReclaim(A);
    if (!A->PollMode) A->Chip->Ops->IrqEnable(A);
}

static VOID MpDisableInterrupt(NDIS_HANDLE Ctx)
{
    PADAPTER A = (PADAPTER)Ctx;
    A->Chip->Ops->IrqDisable(A);
}

static VOID MpEnableInterrupt(NDIS_HANDLE Ctx)
{
    PADAPTER A = (PADAPTER)Ctx;
    if (!A->PollMode) A->Chip->Ops->IrqEnable(A);
}

static NDIS_STATUS MpSend(NDIS_HANDLE Ctx, PNDIS_PACKET Packet, UINT Flags)
{
    PADAPTER A = (PADAPTER)Ctx;
    PNDIS_BUFFER b;
    PVOID va;
    UINT len;
    ULONG total = 0;
    PUCHAR dst;
    UNREFERENCED_PARAMETER(Flags);

    /* no busy wait: the timer and the DPC reclaim too; a full ring drops */
    A->Chip->Ops->TxReclaim(A);
    if (A->TxBusy >= TX_COUNT - 1) { A->TxFull++; A->TxErr++; return NDIS_STATUS_SUCCESS; }

    dst = A->TxBuf[A->TxNext];
    for (b = Packet->Private.Head; b; b = b->Next) {
        va = NULL; len = 0;
        NdisQueryBuffer(b, &va, &len);
        if (!va || !len) continue;
        if (total + len > ETH_MAX_FRAME) { A->TxErr++; return NDIS_STATUS_SUCCESS; }
        UsCopy(dst + total, va, len);
        total += len;
    }
    if (total < ETH_HDR) { A->TxErr++; return NDIS_STATUS_SUCCESS; }
    if (total < 60) { UsZero(dst + total, 60 - total); total = 60; }
    if (!A->Chip->Ops->Transmit(A, total)) { A->TxErr++; return NDIS_STATUS_SUCCESS; }
    A->TxOk++;
    return NDIS_STATUS_SUCCESS;
}

static NDIS_STATUS MpTransferData(PNDIS_PACKET Packet, PUINT BytesTransferred, NDIS_HANDLE Ctx,
                                  NDIS_HANDLE ReceiveContext, UINT ByteOffset, UINT BytesToTransfer)
{
    PADAPTER A = (PADAPTER)ReceiveContext;
    PNDIS_BUFFER b;
    PVOID va;
    UINT len, n, done = 0;
    PUCHAR src;
    ULONG avail;
    UNREFERENCED_PARAMETER(Ctx);
    *BytesTransferred = 0;
    if (!A->CurRx) return NDIS_STATUS_FAILURE;
    avail = A->CurRxLen - ETH_HDR;
    if (ByteOffset >= avail) return NDIS_STATUS_SUCCESS;
    if (BytesToTransfer > avail - ByteOffset) BytesToTransfer = avail - ByteOffset;
    src = A->CurRx + ETH_HDR + ByteOffset;
    for (b = Packet->Private.Head; b && done < BytesToTransfer; b = b->Next) {
        va = NULL; len = 0;
        NdisQueryBuffer(b, &va, &len);
        if (!va) continue;
        n = BytesToTransfer - done;
        if (n > len) n = len;
        UsCopy(va, src + done, n);
        done += n;
    }
    *BytesTransferred = done;
    return NDIS_STATUS_SUCCESS;
}

static NDIS_STATUS MpQuery(NDIS_HANDLE Ctx, NDIS_OID Oid, PVOID Buf, ULONG BufLen,
                           PULONG Written, PULONG Needed)
{
    PADAPTER A = (PADAPTER)Ctx;
    ULONG v = 0;
    ULONG v64[2];
    const void *src = &v;
    ULONG len = 4;
    USHORT ver = 0x0500;   /* NDIS 5.0 */
    NDIS_HARDWARE_STATUS hw = NdisHardwareStatusReady;
    NDIS_MEDIUM med = NdisMedium802_3;
    BOOLEAN counter = FALSE;

    *Written = 0;
    *Needed = 0;
    switch (Oid) {
    case OID_GEN_SUPPORTED_LIST: src = g_Oids; len = sizeof(g_Oids); break;
    case OID_GEN_HARDWARE_STATUS: src = &hw; len = sizeof(hw); break;
    case OID_GEN_MEDIA_SUPPORTED:
    case OID_GEN_MEDIA_IN_USE: src = &med; len = sizeof(med); break;
    case OID_GEN_CURRENT_LOOKAHEAD: v = A->Lookahead; break;
    case OID_GEN_MAXIMUM_LOOKAHEAD:
    case OID_GEN_MAXIMUM_FRAME_SIZE: v = ETH_MAX_DATA; break;
    case OID_GEN_MAXIMUM_TOTAL_SIZE:
    case OID_GEN_TRANSMIT_BLOCK_SIZE:
    case OID_GEN_RECEIVE_BLOCK_SIZE: v = ETH_MAX_FRAME; break;
    case OID_GEN_LINK_SPEED: v = (A->LinkUp ? A->LinkMbps : 1000) * 10000; break;
    case OID_GEN_TRANSMIT_BUFFER_SPACE: v = TX_COUNT * BUF_SIZE; break;
    case OID_GEN_RECEIVE_BUFFER_SPACE: v = RX_COUNT * BUF_SIZE; break;
    case OID_GEN_VENDOR_ID: v = A->PermAddr[0] | ((ULONG)A->PermAddr[1] << 8) | ((ULONG)A->PermAddr[2] << 16); break;
    case OID_GEN_VENDOR_DESCRIPTION: src = g_VendorDesc; len = sizeof(g_VendorDesc); break;
    case OID_GEN_CURRENT_PACKET_FILTER: v = A->PacketFilter; break;
    case OID_GEN_DRIVER_VERSION: src = &ver; len = sizeof(ver); break;
    case OID_GEN_VENDOR_DRIVER_VERSION: v = (USOSNET_MAJOR << 16) | USOSNET_MINOR; break;
    case OID_GEN_MAC_OPTIONS:
        v = NDIS_MAC_OPTION_COPY_LOOKAHEAD_DATA | NDIS_MAC_OPTION_TRANSFERS_NOT_PEND |
            NDIS_MAC_OPTION_NO_LOOPBACK;
        break;
    case OID_GEN_MEDIA_CONNECT_STATUS:
        v = A->LinkUp ? NdisMediaStateConnected : NdisMediaStateDisconnected; break;
    case OID_GEN_MAXIMUM_SEND_PACKETS: v = 1; break;
    case OID_GEN_XMIT_OK: v = A->TxOk; counter = TRUE; break;
    case OID_GEN_RCV_OK: v = A->RxOk; counter = TRUE; break;
    case OID_GEN_XMIT_ERROR: v = A->TxErr; counter = TRUE; break;
    case OID_GEN_RCV_ERROR: v = A->RxErr; counter = TRUE; break;
    case OID_GEN_RCV_NO_BUFFER: v = A->RxNoBuf; counter = TRUE; break;
    case OID_GEN_RCV_CRC_ERROR: v = A->RxCrcErr; counter = TRUE; break;
    case OID_802_3_RCV_ERROR_ALIGNMENT:
    case OID_802_3_XMIT_ONE_COLLISION:
    case OID_802_3_XMIT_MORE_COLLISIONS: v = 0; counter = TRUE; break;
    case OID_802_3_PERMANENT_ADDRESS: src = A->PermAddr; len = ETH_ALEN; break;
    case OID_802_3_CURRENT_ADDRESS: src = A->CurAddr; len = ETH_ALEN; break;
    case OID_802_3_MULTICAST_LIST: src = A->McList; len = A->McCount * ETH_ALEN; break;
    case OID_802_3_MAXIMUM_LIST_SIZE: v = MAX_MCAST; break;
    case OID_PNP_QUERY_POWER: len = 0; break;
    default:
        return NDIS_STATUS_NOT_SUPPORTED;   /* OID_PNP_CAPABILITIES too: no wake-up */
    }
    if (counter && BufLen >= 8) {
        v64[0] = v; v64[1] = 0;
        src = v64; len = 8;
    }
    if (len > BufLen) { *Needed = len; return NDIS_STATUS_INVALID_LENGTH; }
    UsCopy(Buf, src, len);
    *Written = len;
    return NDIS_STATUS_SUCCESS;
}

static NDIS_STATUS MpSet(NDIS_HANDLE Ctx, NDIS_OID Oid, PVOID Buf, ULONG BufLen,
                         PULONG Read, PULONG Needed)
{
    PADAPTER A = (PADAPTER)Ctx;
    ULONG v;
    *Read = 0;
    *Needed = 0;
    switch (Oid) {
    case OID_GEN_CURRENT_PACKET_FILTER:
        if (BufLen < 4) { *Needed = 4; return NDIS_STATUS_INVALID_LENGTH; }
        UsCopy(&v, Buf, 4);
        if (v & ~(NDIS_PACKET_TYPE_DIRECTED | NDIS_PACKET_TYPE_MULTICAST | NDIS_PACKET_TYPE_ALL_MULTICAST |
                  NDIS_PACKET_TYPE_BROADCAST | NDIS_PACKET_TYPE_PROMISCUOUS))
            return NDIS_STATUS_NOT_SUPPORTED;
        A->PacketFilter = v;
        A->Chip->Ops->SetFilter(A);
        UsLog(A, "filter %x", v, 0);
        *Read = 4;
        return NDIS_STATUS_SUCCESS;
    case OID_GEN_CURRENT_LOOKAHEAD:
        if (BufLen < 4) { *Needed = 4; return NDIS_STATUS_INVALID_LENGTH; }
        UsCopy(&v, Buf, 4);
        A->Lookahead = v > ETH_MAX_DATA ? ETH_MAX_DATA : v;
        *Read = 4;
        return NDIS_STATUS_SUCCESS;
    case OID_802_3_MULTICAST_LIST:
        if (BufLen % ETH_ALEN) return NDIS_STATUS_INVALID_LENGTH;
        if (BufLen / ETH_ALEN > MAX_MCAST) return NDIS_STATUS_MULTICAST_FULL;
        A->McCount = BufLen / ETH_ALEN;
        UsCopy(A->McList, Buf, BufLen);
        A->Chip->Ops->SetFilter(A);
        *Read = BufLen;
        return NDIS_STATUS_SUCCESS;
    case OID_GEN_PROTOCOL_OPTIONS:
    case OID_PNP_SET_POWER:
    case OID_PNP_ADD_WAKE_UP_PATTERN:
    case OID_PNP_REMOVE_WAKE_UP_PATTERN:
    case OID_PNP_ENABLE_WAKE_UP:
        *Read = BufLen;
        return NDIS_STATUS_SUCCESS;
    default:
        return NDIS_STATUS_NOT_SUPPORTED;
    }
}

/* ------------------------------------------------------------------ */

NTSTATUS DriverEntry(PDRIVER_OBJECT DriverObject, PUNICODE_STRING RegistryPath);

NTSTATUS DriverEntry(PDRIVER_OBJECT DriverObject, PUNICODE_STRING RegistryPath)
{
    NDIS_STATUS st;
    NDIS_MINIPORT_CHARACTERISTICS mc;

    NdisMInitializeWrapper(&g_Wrapper, DriverObject, RegistryPath, NULL);
    if (!g_Wrapper) return NDIS_STATUS_FAILURE;
    UsZero(&mc, sizeof(mc));
    mc.MajorNdisVersion = 5;
    mc.MinorNdisVersion = 0;
    mc.CheckForHangHandler = MpCheckForHang;
    mc.DisableInterruptHandler = MpDisableInterrupt;
    mc.EnableInterruptHandler = MpEnableInterrupt;
    mc.HaltHandler = MpHalt;
    mc.HandleInterruptHandler = MpHandleInterrupt;
    mc.InitializeHandler = MpInitialize;
    mc.ISRHandler = MpIsr;
    mc.QueryInformationHandler = MpQuery;
    mc.ResetHandler = MpReset;
    mc.SendHandler = MpSend;
    mc.SetInformationHandler = MpSet;
    mc.TransferDataHandler = MpTransferData;
    st = NdisMRegisterMiniport(g_Wrapper, &mc, sizeof(mc));
    if (st != NDIS_STATUS_SUCCESS) {
        NdisTerminateWrapper(g_Wrapper, NULL);
        return st;
    }
    return NDIS_STATUS_SUCCESS;
}
