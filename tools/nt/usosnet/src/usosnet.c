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
 *
 * 0.4: every frame in both directions is classified (usosnet_proto.h) into
 * a live statistics page (ARP / ICMP / UDP / DNS / TCP / HTTP counters, RX
 * drop reasons, checksum notes, MiniportTransferData calls, the last 32
 * frames, the last DNS frame per direction). Its address is in the
 * registry (UsosnetStatsVa / UsosnetStatsPa) for USOSLOG.
 */
#include "usosnet.h"
#include "usosnet_irq.h"
#ifndef USOSNET_NATIVE4
#define USOSNET_NATIVE4 0
#endif
#if USOSNET_NDIS3
#include "usosnet351_policy.h"
#endif

#pragma warning(disable:4054 4055 4152 4201 4214)

long __cdecl _InterlockedExchange(long volatile *Target, long Value);
long __cdecl _InterlockedOr(long volatile *Target, long Value);
unsigned char __inbyte(unsigned short Port);
void __outbyte(unsigned short Port, unsigned char Data);
#pragma intrinsic(_InterlockedExchange, _InterlockedOr, __inbyte, __outbyte)

#if USOSNET_NT351
/* Config space through ports CF8h / CFCh (usosnet.h, g_UsCf8Bus). Own code;
 * the mechanism #1 address layout is the PCI Local Bus specification's.
 * Each address + data pair runs with interrupts off on this CPU. */
unsigned short __inword(unsigned short Port);
void __outword(unsigned short Port, unsigned short Data);
unsigned long __indword(unsigned short Port);
void __outdword(unsigned short Port, unsigned long Data);
#pragma intrinsic(__inword, __outword, __indword, __outdword)
ULONG g_UsCf8Bus = 0xFFFFFFFFUL;

static ULONG Cf8Address(ULONG Bus, ULONG Slot, ULONG Off)
{
    /* NDIS slot number = device | function << 5 */
    return 0x80000000UL | ((Bus & 0xFF) << 16) | ((Slot & 0x1F) << 11) | (((Slot >> 5) & 7) << 8) | (Off & 0xFC);
}

static ULONG Cf8Read32(ULONG Bus, ULONG Slot, ULONG Off)
{
    ULONG v, a = Cf8Address(Bus, Slot, Off);
    __asm { pushfd }
    __asm { cli }
    __outdword(0xCF8, a);
    v = __indword(0xCFC);
    __asm { popfd }
    return v;
}

static void Cf8Write(ULONG Bus, ULONG Slot, ULONG Off, ULONG V, ULONG Width)
{
    ULONG a = Cf8Address(Bus, Slot, Off);
    __asm { pushfd }
    __asm { cli }
    __outdword(0xCF8, a);
    if (Width == 4) __outdword(0xCFC, V);
    else if (Width == 2) __outword((USHORT)(0xCFC + (Off & 2)), (USHORT)V);
    else __outbyte((USHORT)(0xCFC + (Off & 3)), (UCHAR)V);
    __asm { popfd }
}

ULONG UsPciRead(NDIS_HANDLE H, ULONG Slot, ULONG Off, PVOID Buf, ULONG Len)
{
    ULONG i;
    if (g_UsCf8Bus == 0xFFFFFFFFUL) return (NdisReadPciSlotInformation)(H, Slot, Off, Buf, Len);
    if (Off >= 256 || Len > 256 - Off) return 0;
    for (i = 0; i < Len; i++)
        ((PUCHAR)Buf)[i] = (UCHAR)(Cf8Read32(g_UsCf8Bus, Slot, Off + i) >> (((Off + i) & 3) * 8));
    return Len;
}

ULONG UsPciWrite(NDIS_HANDLE H, ULONG Slot, ULONG Off, PVOID Buf, ULONG Len)
{
    ULONG i = 0, o;
    PUCHAR b = (PUCHAR)Buf;
    if (g_UsCf8Bus == 0xFFFFFFFFUL) return (NdisWritePciSlotInformation)(H, Slot, Off, Buf, Len);
    if (Off >= 256 || Len > 256 - Off) return 0;
    while (i < Len) {
        o = Off + i;
        if (!(o & 3) && Len - i >= 4) {
            Cf8Write(g_UsCf8Bus, Slot, o, b[i] | ((ULONG)b[i + 1] << 8) | ((ULONG)b[i + 2] << 16) | ((ULONG)b[i + 3] << 24), 4);
            i += 4;
        } else if (!(o & 1) && Len - i >= 2) {
            Cf8Write(g_UsCf8Bus, Slot, o, b[i] | ((ULONG)b[i + 1] << 8), 2);
            i += 2;
        } else {
            Cf8Write(g_UsCf8Bus, Slot, o, b[i], 1);
            i++;
        }
    }
    return Len;
}
#endif

/* NdisQueryBuffer is a macro over the MDL on NT builds; 9x NDIS buffers are
 * no MDLs, so call the function NDIS.SYS / NDIS.VXD export. */
#undef NdisQueryBuffer
EXPORT VOID NdisQueryBuffer(IN PNDIS_BUFFER Buffer, OUT PVOID *VirtualAddress OPTIONAL, OUT PUINT Length);

#if USOSNET_NDIS4
/* NDIS 3.0 / 4.0 exports (NT4 SP6a NDIS.SYS, 95 OSR2 NDIS.VXD 4.0; still
 * exported by later NDIS.SYS), not declared by the WDK 7.1 ndis.h. */
EXPORT VOID EthFilterDprIndicateReceive(IN PETH_FILTER Filter, IN NDIS_HANDLE MacReceiveContext,
                                        IN PCHAR Address, IN PVOID HeaderBuffer, IN UINT HeaderBufferSize,
                                        IN PVOID LookaheadBuffer, IN UINT LookaheadBufferSize, IN UINT PacketSize);
EXPORT VOID EthFilterDprIndicateReceiveComplete(IN PETH_FILTER Filter);
EXPORT VOID NdisOverrideBusNumber(IN NDIS_HANDLE WrapperConfigurationContext,
                                  IN NDIS_HANDLE MiniportAdapterHandle OPTIONAL, IN ULONG BusNumber);
/* The Ethernet filter of the miniport block: 0xD8 in WDK 7.1 (FILTERDBS) and
 * the EthDB that the NDIS 3 macros of 95 OSR2 NE2000.SYS and NT4 SP6a
 * E100B.SYS pass to EthFilterDprIndicateReceive (checked by
 * tools/tests/test_usosnet.py on the built binary). The NDIS 5 handler
 * pointers behind it are not part of the 4.0 miniport block. */
#define USOSNET_ETHDB_OFFSET 0xD8
C_ASSERT(FIELD_OFFSET(NDIS_MINIPORT_BLOCK, EthDB) == USOSNET_ETHDB_OFFSET);
#define USOSNET_ETHDB(H) (((PNDIS_MINIPORT_BLOCK)(H))->EthDB)
/* MajorNdisVersion 4: the NDIS 3.0 part + ReturnPacket / SendPackets /
 * AllocateComplete; 95 OSR2 NDIS.VXD wants at least 0x48 bytes. */
#if USOSNET_NDIS30
/* Original NT351 SHA948d...ab1b RVA179D and NT35 SHAfa392...5543 RVA1BD0
 * accept3.0 and copy0x3C; NT35 internal RX188B/1896 also uses EthDBD8.
 * The NT351 routine copies
 * exactly 0x3C bytes. Inbox NE2000, ELNK3 and DC21X4 confirm EthDB+0xD8.
 * 95 RTM / OSR1: NDIS.VXD has neither NdisMSetAttributesEx nor
 * NdisMSetPeriodicTimer; the inbox NE2000.SYS of both registers 0x3C bytes
 * and uses EthDB+0xD8 (Codex, docs/win95-rtm-osr1-2026-10-23.md). */
#define USOSNET_CHARS_SIZE FIELD_OFFSET(NDIS_MINIPORT_CHARACTERISTICS, ReturnPacketHandler)
C_ASSERT(USOSNET_CHARS_SIZE == 0x3C);
C_ASSERT(FIELD_OFFSET(NDIS_MINIPORT_CHARACTERISTICS, CheckForHangHandler) == 0x08);
C_ASSERT(FIELD_OFFSET(NDIS_MINIPORT_CHARACTERISTICS, HaltHandler) == 0x14);
C_ASSERT(FIELD_OFFSET(NDIS_MINIPORT_CHARACTERISTICS, TransferDataHandler) == 0x38);
#undef NdisMSetAttributes
EXPORT VOID NdisMSetAttributes(IN NDIS_HANDLE MiniportAdapterHandle,
    IN NDIS_HANDLE MiniportAdapterContext, IN BOOLEAN BusMaster,
    IN NDIS_INTERFACE_TYPE AdapterType);
#if USOSNET_DRVTIMER
/* The one-shot NdisSetTimer takes the NDIS_TIMER prefix of the miniport timer. */
C_ASSERT(FIELD_OFFSET(NDIS_MINIPORT_TIMER, Timer) == 0);
C_ASSERT(FIELD_OFFSET(NDIS_MINIPORT_TIMER, Dpc) == FIELD_OFFSET(NDIS_TIMER, Dpc));
#endif
#else
#define USOSNET_CHARS_SIZE FIELD_OFFSET(NDIS_MINIPORT_CHARACTERISTICS, CoCreateVcHandler)
C_ASSERT(USOSNET_CHARS_SIZE == 0x48);
#endif
#else
#define USOSNET_CHARS_SIZE sizeof(NDIS_MINIPORT_CHARACTERISTICS)
#endif

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
#if !USOSNET_NDIS4
    OID_PNP_CAPABILITIES, OID_PNP_SET_POWER, OID_PNP_QUERY_POWER,
#endif
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

#if USOSNET_W95RTM
/* UsosBootBar0: hex digits as a registry string ("FC900000", optional 0x;
 * ANSI or UTF-16, the high bytes are skipped), else a DWORD read as
 * NdisParameterHexInteger. 0 = absent / unparsable. */
static ULONG CfgHexString(NDIS_HANDLE Cfg, NDIS_STRING *Key)
{
    NDIS_STATUS st;
    PNDIS_CONFIGURATION_PARAMETER p = NULL;
    ULONG v = 0, n = 0, i, d;
    const UCHAR *c;
    NdisReadConfiguration(&st, &p, Cfg, Key, NdisParameterString);
    if (st == NDIS_STATUS_SUCCESS && p && p->ParameterType == NdisParameterString &&
        p->ParameterData.StringData.Buffer) {
        c = (const UCHAR *)p->ParameterData.StringData.Buffer;
        for (i = 0; i < p->ParameterData.StringData.Length; i++) {
            if (!c[i]) continue;
            if (!n && c[i] == ' ') continue;
            if ((c[i] == 'x' || c[i] == 'X') && n == 1 && v == 0) { n = 0; continue; }
            if (c[i] >= '0' && c[i] <= '9') d = c[i] - '0';
            else if (c[i] >= 'A' && c[i] <= 'F') d = c[i] - 'A' + 10;
            else if (c[i] >= 'a' && c[i] <= 'f') d = c[i] - 'a' + 10;
            else break;
            if (n == 8) return 0;               /* more than 32 bits */
            v = (v << 4) | d;
            n++;
        }
        if (n) return v;
    }
    NdisReadConfiguration(&st, &p, Cfg, Key, NdisParameterHexInteger);
    if (st == NDIS_STATUS_SUCCESS && p &&
        (p->ParameterType == NdisParameterHexInteger || p->ParameterType == NdisParameterInteger))
        return p->ParameterData.IntegerData;
    return 0;
}
#endif

/* NT 3.51 (native CF8 build): NDIS.SYS 3.51 exports NdisWriteConfiguration;
 * the X470 2026-10-29 run failed (SCM 7000 NDISLoop %%31) without a trace.
 *
 * NDIS.SYS 3.51 (SHA948d...ab1b, RVA 3B48, own disassembly; no bytes
 * copied) does not take the NdisOpenConfiguration handle here: it reads
 * the service key name (a PWSTR) at handle + 5Ch and writes to
 * Services\<name>\Parameters with RtlWriteRegistryValue (RTL_REGISTRY_SERVICES).
 * NdisReadConfiguration of the same NDIS reads that name at
 * [handle] + 5Ch, [handle] = the WrapperConfigurationContext (its query
 * table). The NdisOpenConfiguration handle is an 8-byte block, so + 5Ch
 * was a read past it: X470 2026-10-29 STOP 0x1E C0000005 in wcslen(NULL)
 * (ntoskrnl 8013665B) in the driver-load worker thread. NT 3.51 therefore
 * passes the WrapperConfigurationContext (USOSNET_DIAG_HANDLE). Only
 * NdisParameterInteger (REG_DWORD) and the two string types are written;
 * NdisParameterHexInteger returns NDIS_STATUS_NOT_SUPPORTED. */
#if USOSNET_NT351
#define USOSNET_DIAG_HANDLE(Cfg, Wcc) (Wcc)
#define USOSNET_DIAG_TYPE NdisParameterInteger
#else
#define USOSNET_DIAG_HANDLE(Cfg, Wcc) (Cfg)
#define USOSNET_DIAG_TYPE NdisParameterHexInteger
#endif
#if !USOSNET_NDIS3 || USOSNET_NT351
static void CfgPut(NDIS_HANDLE Cfg, NDIS_STRING *Key, ULONG V)
{
    NDIS_STATUS st;
    NDIS_CONFIGURATION_PARAMETER p;
    UsZero(&p, sizeof(p));
    p.ParameterType = USOSNET_DIAG_TYPE;
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
    NDIS_STRING kSva = NDIS_STRING_CONST("UsosnetStatsVa");
    NDIS_STRING kSpa = NDIS_STRING_CONST("UsosnetStatsPa");
    NDIS_STRING kNdis = NDIS_STRING_CONST("UsosnetNdis");
    NDIS_STRING kLoc = NDIS_STRING_CONST("UsosnetPciLocation");
    NDIS_STRING kAsg = NDIS_STRING_CONST("UsosnetAssign");
    NDIS_STRING kIrqSt = NDIS_STRING_CONST("UsosnetIrqStatus");
    if (!Cfg) return;
    /* NDIS version the driver registered with (0x0400 / 0x0500); PCI
     * location 0x80000000 | bus << 8 | slot when found by the NT4 bus scan */
    CfgPut(Cfg, &kNdis, USOSNET_NDIS_MAJOR << 8);
    CfgPut(Cfg, &kLoc, A->Legacy ? 0x80000000UL | (A->PciBus << 8) | A->PciSlot : 0);
    CfgPut(Cfg, &kAsg, A->AssignStatus);
    CfgPut(Cfg, &kIrqSt, A->IrqStatus);
    CfgPut(Cfg, &kSva, A->Stats ? (ULONG)(ULONG_PTR)A->Stats : 0);
    CfgPut(Cfg, &kSpa, A->Stats ? A->StatsMem.Pa : 0);
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
#else
/* This variant persists no private diagnostics in the registry. */
#define WriteDiag(A, Cfg) ((void)0)
#endif

#if USOSNET_NT351
/* Durable breadcrumbs. X470 2026-10-29, second boot with NDISLoop Start=2
 * and the fixed WriteDiag: blue screen again, and nothing of that boot
 * reached the disk (hives, event logs, FAT times unchanged): registry
 * writes made through NDIS stay in memory until the lazy hive flush.
 * Here every point goes through ZwSetValueKey and is forced out with
 * ZwFlushKey (NT 3.51 ntoskrnl exports, tools/tests/data/nt351_exports.txt)
 * on Services\<adapter key>\Parameters. PASSIVE_LEVEL only: MpInitialize
 * calls BcPoint directly; after it returns, the 20 ms timer (DISPATCH)
 * queues AliveWorker as a work item at nominal 1, 2, 5 and 10 s. The last
 * UsosnetBcPoint / UsosnetAliveSec on disk tells how far the boot got. */
#pragma warning(push)
#pragma warning(disable:4996)
#define BC_VERSION 0x351B0001UL
static WCHAR g_BcKey[192];
static BOOLEAN g_BcReady;
static ULONG g_BcSeq;
static const ULONG g_AliveAt[] = { 1, 2, 5, 10 };

static void BcUs(PUNICODE_STRING U, PCWSTR S)
{
    USHORT n = 0;
    while (S[n]) n++;
    U->Buffer = (PWSTR)S;
    U->Length = (USHORT)(n * sizeof(WCHAR));
    U->MaximumLength = (USHORT)(U->Length + sizeof(WCHAR));
}

/* the adapter key name is the query table's [3].Name (WCC + 5Ch), the
 * same pointer NDIS.SYS 3.51 NdisWriteConfiguration uses */
static void BcInit(NDIS_HANDLE Wcc)
{
    static const WCHAR pre[] = L"\\Registry\\Machine\\System\\CurrentControlSet\\Services\\";
    static const WCHAR suf[] = L"\\Parameters";
    PCWSTR name = Wcc ? *(PCWSTR *)((PUCHAR)Wcc + 0x5C) : NULL;
    ULONG n = 0, i;
    if (!name || !name[0]) name = L"NDISLoop1";
    for (i = 0; pre[i]; i++) g_BcKey[n++] = pre[i];
    for (i = 0; name[i] && i < 64; i++) g_BcKey[n++] = name[i];
    for (i = 0; suf[i]; i++) g_BcKey[n++] = suf[i];
    g_BcKey[n] = 0;
    g_BcReady = TRUE;
}

static void BcWrite(const PCWSTR *Names, const ULONG *Vals, ULONG Count)
{
    UNICODE_STRING ks, vs;
    OBJECT_ATTRIBUTES oa;
    HANDLE h;
    ULONG i, v;
    if (!g_BcReady) return;
    BcUs(&ks, g_BcKey);
    InitializeObjectAttributes(&oa, &ks, OBJ_CASE_INSENSITIVE, NULL, NULL);
    if (!NT_SUCCESS(ZwOpenKey(&h, KEY_SET_VALUE, &oa))) return;
    for (i = 0; i < Count; i++) {
        v = Vals[i];
        BcUs(&vs, Names[i]);
        ZwSetValueKey(h, &vs, 0, REG_DWORD, &v, sizeof(v));
    }
    ZwFlushKey(h);
    ZwClose(h);
}

/* init points: 1 entry .. 0x12 about to return SUCCESS, 0x1F fail path */
static void BcPoint(PADAPTER A, ULONG Point)
{
    static const PCWSTR n[] = { L"UsosnetBcSeq", L"UsosnetBcPoint", L"UsosnetBcStage",
                                L"UsosnetBcError", L"UsosnetBcVersion" };
    ULONG v[5];
    v[0] = ++g_BcSeq; v[1] = Point; v[2] = A->Stage; v[3] = A->Error; v[4] = BC_VERSION;
    BcWrite(n, v, 5);
}

static VOID AliveWorker(PVOID Ctx)
{
    static const PCWSTR n[] = { L"UsosnetAliveSeq", L"UsosnetAliveSec", L"UsosnetAliveRx",
                                L"UsosnetAliveTx", L"UsosnetAliveOid", L"UsosnetAliveOidKind",
                                L"UsosnetAliveOidCount", L"UsosnetAliveTicks", L"UsosnetAliveFlags",
                                L"UsosnetAliveRxErr", L"UsosnetAliveTxErr" };
    PADAPTER A = (PADAPTER)Ctx;
    ULONG v[11];
    v[0] = ++g_BcSeq; v[1] = A->AliveSec; v[2] = A->RxOk; v[3] = A->TxOk;
    v[4] = A->LastOid; v[5] = A->LastOidKind; v[6] = A->OidCount; v[7] = A->TimerCount;
    v[8] = (A->PollMode & 3) | (A->LinkUp ? 4UL : 0) | (A->PacketFilter << 8);
    v[9] = A->RxErr; v[10] = A->TxErr;
    BcWrite(n, v, 11);
    _InterlockedExchange(&A->AlivePending, 0);
}

/* BAR0 mapping: NdisMMapIoSpace status as returned, how it was mapped */
static void BcMap(PADAPTER A)
{
    static const PCWSTR n[] = { L"UsosnetMapStatus", L"UsosnetMapHow", L"UsosnetMapVa",
                                L"UsosnetMapLen", L"UsosnetBar0Size", L"UsosnetMapPa" };
    ULONG v[6];
    v[0] = A->MapStatus; v[1] = A->MapHow; v[2] = (ULONG)(ULONG_PTR)A->Mmio;
    v[3] = A->MmioLen; v[4] = A->Bar0Size; v[5] = NdisGetPhysicalAddressLow(A->MmioPa);
    BcWrite(n, v, 6);
}

/* shared memory as NDIS / the HAL gave it (Standard HAL: an ISA-style
 * adapter object, common buffers below 16 MiB); DmaAlloc refuses any
 * address above 4 GiB, DmaEnd = highest Pa + length over every block */
static void BcDma(PADAPTER A)
{
    static const PCWSTR n[] = { L"UsosnetRxRingPa", L"UsosnetTxRingPa", L"UsosnetRxBuf0Pa",
                                L"UsosnetTxBuf0Pa", L"UsosnetDmaEnd", L"UsosnetStatsPa" };
    ULONG v[6], i, end = 0, e;
    const DMAMEM *m[2 + RX_COUNT / BUFS_PER_PAGE + TX_COUNT / BUFS_PER_PAGE + 1];
    ULONG k = 0;
    m[k++] = &A->RxRing; m[k++] = &A->TxRing;
    for (i = 0; i < RX_COUNT / BUFS_PER_PAGE; i++) m[k++] = &A->RxPage[i];
    for (i = 0; i < TX_COUNT / BUFS_PER_PAGE; i++) m[k++] = &A->TxPage[i];
    m[k++] = &A->StatsMem;
    for (i = 0; i < k; i++) {
        if (!m[i]->AllocVa) continue;
        e = NdisGetPhysicalAddressLow(m[i]->AllocPa) + m[i]->AllocLen;
        if (e > end) end = e;
    }
    v[0] = A->RxRing.Pa; v[1] = A->TxRing.Pa; v[2] = A->RxBufPa[0]; v[3] = A->TxBufPa[0];
    v[4] = end; v[5] = A->Stats ? A->StatsMem.Pa : 0;
    BcWrite(n, v, 6);
}

/* after the chip start: ring registers as read back, RX descriptor 0 */
static void BcRings(PADAPTER A)
{
    static const PCWSTR n[] = { L"UsosnetRdbal", L"UsosnetRdbah", L"UsosnetRdlen", L"UsosnetTdbal",
                                L"UsosnetTdbah", L"UsosnetTdlen", L"UsosnetRxDesc0", L"UsosnetHwStatus",
                                L"UsosnetHwCtrl", L"UsosnetHwRctl" };
    ULONG r[DIAG_REGS], v[10];
    UsZero(r, sizeof(r));
    A->Chip->Ops->Diag(A, r);
    v[0] = r[DR_RDBAL]; v[1] = r[DR_RDBAH]; v[2] = r[DR_RDLEN]; v[3] = r[DR_TDBAL];
    v[4] = r[DR_TDBAH]; v[5] = r[DR_TDLEN];
    v[6] = A->RxRing.Va ? *(volatile ULONG *)A->RxRing.Va : 0;
    v[7] = r[DR_STATUS]; v[8] = r[DR_CTRL]; v[9] = r[DR_RCTL];
    BcWrite(n, v, 10);
}

/* TimerFn, once a nominal second (DISPATCH_LEVEL): queue the next record */
static void AliveTick(PADAPTER A)
{
    ULONG sec = A->TimerCount / TICKS_PER_SEC;
    if (A->AliveIdx >= sizeof(g_AliveAt) / sizeof(g_AliveAt[0]) || sec < g_AliveAt[A->AliveIdx]) return;
    if (A->AlivePending) return;
    A->AliveIdx++;
    A->AliveSec = sec;
    A->AlivePending = 1;
    ExInitializeWorkItem(&A->AliveWi, AliveWorker, A);
    ExQueueWorkItem(&A->AliveWi, DelayedWorkQueue);
}

/* first receive indication returned (UsIndicateRx, DISPATCH_LEVEL): one
 * record from a work item. FirstIndTicks = 20 ms ticks since the timer was
 * armed, FirstIndDpc = MpHandleInterrupt runs so far (NdisMDpcTimer). */
static VOID FirstIndWorker(PVOID Ctx)
{
    static const PCWSTR n[] = { L"UsosnetFirstIndSeq", L"UsosnetFirstIndTicks", L"UsosnetFirstIndLen",
                                L"UsosnetFirstIndRx", L"UsosnetFirstIndDpc", L"UsosnetFirstIndFilter" };
    PADAPTER A = (PADAPTER)Ctx;
    ULONG v[6];
    v[0] = ++g_BcSeq; v[1] = A->FirstIndTicks; v[2] = A->FirstIndLen;
    v[3] = A->RxOk; v[4] = A->DpcCount; v[5] = A->PacketFilter;
    BcWrite(n, v, 6);
    _InterlockedExchange(&A->FirstIndPending, 0);
}

static void FirstIndTick(PADAPTER A, ULONG Len)
{
    if (A->FirstIndDone || A->Halted) return;
    A->FirstIndDone = TRUE;
    A->FirstIndTicks = A->TimerCount;
    A->FirstIndLen = Len;
    A->FirstIndPending = 1;
    ExInitializeWorkItem(&A->FirstIndWi, FirstIndWorker, A);
    ExQueueWorkItem(&A->FirstIndWi, DelayedWorkQueue);
}
#pragma warning(pop)
#define BC(A, P) BcPoint((A), (P))
#elif USOSNET_NATIVE4
#include "usosnet_nt4_bc.h"
#else
#define BC(A, P) ((void)0)
#endif

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
#if USOSNET_DRVTIMER
    BOOLEAN cancelled;
#endif
    if (A->Shutdown) NdisMDeregisterAdapterShutdownHandler(A->Handle);
    A->Shutdown = FALSE;
#if USOSNET_DRVTIMER
    if (A->TimerInit) NdisMCancelTimer(&A->Timer, &cancelled);
#endif
    A->TimerInit = FALSE;
    if (A->IrqRegistered) NdisMDeregisterInterrupt(&A->Interrupt);
    A->IrqRegistered = FALSE;
    if (A->Stats) A->Stats->Magic = 0;       /* readers check it first */
    A->Stats = NULL;
    DmaFree(A, &A->StatsMem);
    DmaFree(A, &A->RxRing);
    DmaFree(A, &A->TxRing);
    for (i = 0; i < RX_COUNT / BUFS_PER_PAGE; i++) DmaFree(A, &A->RxPage[i]);
    for (i = 0; i < TX_COUNT / BUFS_PER_PAGE; i++) DmaFree(A, &A->TxPage[i]);
    if (A->MapRegs) NdisMFreeMapRegisters(A->Handle);
    A->MapRegs = FALSE;
#if USOSNET_NT351
    if (A->Mmio && A->MmDirect) MmUnmapIoSpace((PVOID)A->Mmio, A->MmioLen);
    else
#endif
    if (A->Mmio) NdisMUnmapIoSpace(A->Handle, (PVOID)A->Mmio, A->MmioLen);
    A->Mmio = NULL;
#if USOSNET_NT351
    A->MmDirect = FALSE;
    if (A->Halted) return;
#endif
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
#define EV_REQUEST      4       /* USOSLOG asked (UDP broadcast to USNS_LOG_PORT) */
#define LOG_FORCED_MAX  100     /* such rounds per start, on top of LOG_MAX */

static ULONG DiagFlags(PADAPTER A, ULONG Event)
{
    return (A->PollMode & 3) | (A->LinkUp ? 4UL : 0) | (A->FullDuplex ? 8UL : 0) |
           ((Event & 0xFF) << 8) | ((A->LinkMbps & 0xFFFF) << 16);
}

/* NdisWriteErrorLogEntry within the NDIS.VXD budget (LOG_* in usosnet.h):
 * FALSE = entry skipped (counted in LogSkipped). */
static BOOLEAN LogBudget(PADAPTER A)
{
    ULONG now = A->TimerCount;
    if (now < LOG_QUIET_SEC * TICKS_PER_SEC) { A->LogSkipped++; return FALSE; }
    if (!A->LogWindowUsed || now - A->LogWindowStart >= LOG_WINDOW_SEC * TICKS_PER_SEC) {
        A->LogWindowStart = now;
        A->LogWindowUsed = 0;
    }
    if (A->LogWindowUsed >= LOG_WINDOW_MAX) { A->LogSkipped++; return FALSE; }
    A->LogWindowUsed++;
    return TRUE;
}

#define LOG10(tag, a, b, c, d, e, f, g, h, i) \
    do { if (LogBudget(A)) NdisWriteErrorLogEntry(A->Handle, NDIS_ERROR_CODE_DRIVER_FAILURE, 10, \
         (ULONG)(tag), (ULONG)(a), (ULONG)(b), (ULONG)(c), (ULONG)(d), (ULONG)(e), (ULONG)(f), \
         (ULONG)(g), (ULONG)(h), (ULONG)(i)); } while (0)

static void DiagLog(PADAPTER A, ULONG Event, ULONG Sec)
{
#if USOSNET_NDIS3
    /* Host captures this optional serial stream beside the VM artifacts. */
    UsLog(A, "diag nominal-sec %x event %x", Sec, Event);
    UsLog(A, "diag rx %x tx %x", A->RxOk, A->TxOk);
#else
    ULONG r[DIAG_REGS], pci = 0;
#if USOSNET_W95RTM
    /* nothing is written in the quiet time: do not use up a round (the X470
     * 95 RTM run lost the one-time USN4 to the IRQ watchdog round at 5 s) */
    if (A->TimerCount < LOG_QUIET_SEC * TICKS_PER_SEC) return;
#endif
    if (Event == EV_REQUEST) {
        if (A->ForcedLogs >= LOG_FORCED_MAX) return;
        A->ForcedLogs++;
    } else {
        if (A->LogCount >= LOG_MAX) return;
    }
    A->LogCount++;
    A->Chip->Ops->Diag(A, r);
    NdisReadPciSlotInformation(A->Handle, A->PciSlot, 4, &pci, 4);   /* bit 19 = PCI status INTx pending */
    LOG10(0x55534E31UL, Sec, DiagFlags(A, Event), A->IsrCalls, A->IsrCount, A->DpcCount,
          A->RxOk, A->RxByTimer, A->TxOk, A->TxDone);
    LOG10(0x55534E32UL, Sec, A->TxErr, A->TxFull, A->RxErr, A->HwTpr, A->HwGprc, A->HwGptc,
          A->HwMpc, A->HwRnbc);
    LOG10(0x55534E33UL, Sec, r[DR_STATUS], r[DR_IMS], r[DR_RDH], r[DR_RDT], r[DR_TDH], r[DR_TDT],
          pci, r[DR_RCTL]);
#if !USOSNET_W95RTM
    if (A->LogCount == 1)
        LOG10(0x55534E34UL, (A->IrqLevel << 16) | (A->IrqVector & 0xFFFF), A->RxRing.Pa, A->TxRing.Pa,
              r[DR_CTRL], r[DR_TCTL], r[DR_RXDCTL], r[DR_TXDCTL], A->HwCrc,
              (USOSNET_MAJOR << 16) | USOSNET_MINOR);
#endif
    if (A->Stats) {
        /* USN5: RX UDP, RX DNS, RX TCP, RX ICMP, TX UDP, TX DNS, UDP with L4E,
         * TransferData without a frame being indicated (the budget skips it
         * in the first round, which also has USN4) */
        USNS_BLOCK *S = A->Stats;
        LOG10(0x55534E35UL, Sec, S->Rx[5], S->Rx[7], S->Rx[6], S->Rx[4], S->Tx[5], S->Tx[7],
              S->Drop[USNS_N_L4E_UDP], S->Td[USNS_T_NO_FRAME]);
    }
#endif
}

#if USOSNET_W95RTM
/* 95 RTM: one init round at the end of the quiet time, the first four
 * entries of a fresh budget window, so none is skipped (README.md):
 * USN6 mapping / resources, USN7 MMIO probes / chip identity, USN8 ring
 * bases as read back, USN4 queue / interrupt setup. */
static void InitLog(PADAPTER A)
{
    ULONG r[DIAG_REGS], b0 = 0, il = 0;
    A->InitLogged = TRUE;
    A->Chip->Ops->Diag(A, r);
    NdisReadPciSlotInformation(A->Handle, A->PciSlot, 0x10, &b0, 4);
    NdisReadPciSlotInformation(A->Handle, A->PciSlot, 0x3C, &il, 4);
    LOG10(0x55534E36UL, A->Bar0Init, b0, NdisGetPhysicalAddressLow(A->MmioPa), (ULONG)(ULONG_PTR)A->Mmio,
          A->ResStatus, A->ResInfo | (A->MmioHow << 16), A->ResMemStart, A->ResMemLen,
          (A->IrqLevel << 16) | (A->IrqVector & 0xFFFF));
    LOG10(0x55534E37UL, A->ProbeMap, A->ProbeRestore, A->ProbeReset, A->BootBar0, A->OldBar0,
          A->CtrlAtInit, A->StatusAtInit, A->PhyId, A->PllTries | (A->MacSource << 16));
    LOG10(0x55534E38UL, r[DR_TDBAL], r[DR_TDBAH], r[DR_TDLEN], r[DR_RDBAL], r[DR_RDBAH], r[DR_RDLEN],
          A->TxRing.Pa, A->RxRing.Pa, (ULONG)(ULONG_PTR)A->TxRing.Va);
    LOG10(0x55534E34UL, r[DR_CTRL], r[DR_TCTL], r[DR_RXDCTL], r[DR_TXDCTL], r[DR_GPIE], r[DR_EIMS],
          r[DR_IVAR0], A->IrqStatus, ((il & 0xFFFF) << 16) | (USOSNET_MAJOR << 8) | USOSNET_MINOR);
}
#endif

/* once a second: the core counters into the statistics page */
static void StatsSecond(PADAPTER A, ULONG Sec)
{
    ULONG r[DIAG_REGS], *k;
    if (!A->Stats) return;
    k = A->Stats->Core;
    A->Chip->Ops->Diag(A, r);
    A->Stats->Seconds = Sec;
    k[USNS_K_ISRCALLS] = A->IsrCalls; k[USNS_K_ISR] = A->IsrCount; k[USNS_K_DPC] = A->DpcCount;
    k[USNS_K_RXOK] = A->RxOk; k[USNS_K_RXTIMER] = A->RxByTimer; k[USNS_K_TXOK] = A->TxOk;
    k[USNS_K_TXDONE] = A->TxDone; k[USNS_K_TXERR] = A->TxErr; k[USNS_K_TXFULL] = A->TxFull;
    k[USNS_K_RXERR] = A->RxErr; k[USNS_K_RXCRC] = A->RxCrcErr; k[USNS_K_TPR] = A->HwTpr;
    k[USNS_K_GPRC] = A->HwGprc; k[USNS_K_GPTC] = A->HwGptc; k[USNS_K_MPC] = A->HwMpc;
    k[USNS_K_RNBC] = A->HwRnbc; k[USNS_K_CRCERRS] = A->HwCrc; k[USNS_K_FILTER] = A->PacketFilter;
    k[USNS_K_LOOKAHEAD] = A->Lookahead; k[USNS_K_POLLMODE] = A->PollMode;
    k[USNS_K_LINK] = DiagFlags(A, 0); k[USNS_K_STATUS] = r[DR_STATUS]; k[USNS_K_RCTL] = r[DR_RCTL];
    k[USNS_K_RXCSUM] = r[DR_RXCSUM]; k[USNS_K_RDH] = r[DR_RDH]; k[USNS_K_RDT] = r[DR_RDT];
    k[USNS_K_TDH] = r[DR_TDH]; k[USNS_K_TDT] = r[DR_TDT]; k[USNS_K_TXBUSY] = A->TxBusy;
    k[USNS_K_LOGS] = A->LogCount; k[USNS_K_LOGREQ] = A->ForcedLogs;
}

/* one shared-memory page (has a physical address for USOSDBG's DPMI map) */
static void StatsInit(PADAPTER A)
{
    USNS_BLOCK *S;
    if (sizeof(USNS_BLOCK) > 4096 || !DmaAlloc(A, &A->StatsMem, 4096, 64)) return;
    S = (USNS_BLOCK *)A->StatsMem.Va;
    UsZero(S, 4096);
    S->Version = USNS_VERSION;
    S->Size = sizeof(USNS_BLOCK);
    S->Magic = USNS_MAGIC;
    A->Stats = S;
}

static void StatsDump(UCHAR *Dst, ULONG *DstLen, const UCHAR *Frame, ULONG Len)
{
    *DstLen = Len;
    UsCopy(Dst, Frame, Len > USNS_DUMP ? USNS_DUMP : Len);
}

/* once a second: link, chip counters, IRQ and TX watchdogs, log schedule */
static void TimerSecond(PADAPTER A)
{
    ULONG sec = A->TimerCount / TICKS_PER_SEC;
    BOOLEAN linkChanged;
#if USOSNET_W95RTM
    if (!A->InitLogged && sec >= LOG_QUIET_SEC) InitLog(A);   /* before any event round */
#endif
    linkChanged = CheckLink(A);

    A->Chip->Ops->Stats(A);
    if (!A->PollMode && UsosnetIrqBroken(sec, A->IsrCount, A->RxByTimer, A->LinkUp)) {
        /* INTx does not reach us: mask the chip so the pin is released, poll */
        A->PollMode = 2;
        A->Chip->Ops->IrqDisable(A);
        UsLog(A, "irq watchdog: poll, rx by timer %x", A->RxByTimer, 0);
        DiagLog(A, EV_IRQ_POLL, sec);
    }
    if (A->TxBusy && A->TxDone == A->TxLastClean) {
#if USOSNET_NDIS3 && !USOSNET_DRVTIMER
        ULONG previous = A->TxStallSec;
        A->TxStallSec = Usosnet351StallNext(previous);
        if (previous < 3 && A->TxStallSec >= 3) { A->TxStalls++; DiagLog(A, EV_TX_STALL, sec); }
#else
        if (++A->TxStallSec == 3) { A->TxStalls++; DiagLog(A, EV_TX_STALL, sec); }
#endif
    } else {
        A->TxStallSec = 0;
    }
    A->TxLastClean = A->TxDone;
    if (linkChanged && sec) DiagLog(A, EV_LINK, sec);
    if (A->LogRequest) { A->LogRequest = 0; DiagLog(A, EV_REQUEST, sec); }
    StatsSecond(A, sec);
    /* first round after the quiet time, then one per budget window */
#if USOSNET_NDIS3
    if (Usosnet351PeriodicLog(sec))
#elif USOSNET_W95RTM
    /* 30 s carries the init round (InitLog); the counters follow in the next window */
    if (sec == LOG_QUIET_SEC + LOG_WINDOW_SEC + 4 || (sec && sec % 300 == 0))
#else
    if (sec == LOG_QUIET_SEC || sec == LOG_QUIET_SEC + LOG_WINDOW_SEC + 4 || (sec && sec % 300 == 0))
#endif
        DiagLog(A, EV_PERIODIC, sec);
}

#if USOSNET_DRVTIMER
static VOID TimerFn(PVOID S1, PVOID Ctx, PVOID S2, PVOID S3)
{
    PADAPTER A = (PADAPTER)Ctx;
    ULONG rx;
    UNREFERENCED_PARAMETER(S1); UNREFERENCED_PARAMETER(S2); UNREFERENCED_PARAMETER(S3);
#if USOSNET_NT351
    /* MpHalt keeps the adapter memory when NdisMCancelTimer missed a queued run */
    if (A->Halted || !A->TimerInit) return;
#endif
    rx = A->RxOk;
    A->TimerCount++;
#if USOSNET_NATIVE4
    N4Tick(A);
#endif
#if USOSNET_NT351
    if (A->TimerCount % TICKS_PER_SEC == 0) AliveTick(A);
#endif
    /* serialized miniport: the timer never runs beside MpSend / the DPC */
    A->Chip->Ops->RxPoll(A);
    if (!A->PollMode) A->RxByTimer += A->RxOk - rx;
    A->Chip->Ops->TxReclaim(A);
    if (A->TimerCount % TICKS_PER_SEC == 0) TimerSecond(A);
#if USOSNET_NDIS30
    /* Miniport timers are serialized with Halt. Only the one-shot export
     * exists in 95 RTM and NT 3.51; rearm after this callback's work has
     * completed. */
    if (A->TimerInit) NdisSetTimer((PNDIS_TIMER)&A->Timer, TICK_MS);
#endif
}
#endif

/* ------------------------------------------------------------------ */
/* RX indication (called by the backend from RxPoll)                   */

void UsRxDropped(PADAPTER A, PUCHAR Frame, ULONG Len, ULONG Status)
{
    USNS_BLOCK *S = A->Stats;
    ULONG c, ports, peer;
    if (!S) return;
    c = UsnsClassify(Frame, Len > BUF_SIZE ? BUF_SIZE : Len, 1, &ports, &peer);
    (void)UsnsRxStatus(S->Drop, Status, c);
    UsnsHistory(S, 3, c, ports, Len, Status, peer);
}

void UsIndicateRx(PADAPTER A, PUCHAR Frame, ULONG Len, ULONG Status)
{
    USNS_BLOCK *S = A->Stats;
    if (Len < ETH_HDR || Len > ETH_MAX_FRAME + 4) {
        A->RxErr++;
        if (S) { S->Drop[USNS_D_LEN]++; UsnsHistory(S, 3, 0, 0, Len, Status, 0); }
        return;
    }
    A->CurRxClasses = 0;
    if (S) {
        ULONG ports, peer, c = UsnsClassify(Frame, Len, 1, &ports, &peer);
        if (!A->PacketFilter) {
            S->Drop[USNS_D_NOFILTER]++;
            UsnsHistory(S, 3, c, ports, Len, Status, peer);
            return;
        }
        (void)UsnsRxStatus(S->Drop, Status, c);
        UsnsCount(S->Rx, c);
        UsnsHistory(S, 1, c, ports, Len, Status, peer);
        if (c & USNS_C_DNS) StatsDump(S->LastDnsRx, &S->LastDnsRxLen, Frame, Len);
        A->CurRxClasses = c;
    }
    if (!A->PacketFilter) return;
    A->CurRx = Frame;
    A->CurRxLen = Len;
    A->RxOk++;
#if USOSNET_NDIS4
    EthFilterDprIndicateReceive(USOSNET_ETHDB(A->Handle), (NDIS_HANDLE)A, (PCHAR)Frame, Frame, ETH_HDR,
                                Frame + ETH_HDR, Len - ETH_HDR, Len - ETH_HDR);
#else
    NdisMEthIndicateReceive(A->Handle, (NDIS_HANDLE)A, (PCHAR)Frame, ETH_HDR,
                            Frame + ETH_HDR, Len - ETH_HDR, Len - ETH_HDR);
#endif
#if USOSNET_NT351
    FirstIndTick(A, Len);
#endif
    A->CurRx = NULL;
    A->CurRxClasses = 0;
}

void UsIndicateRxComplete(PADAPTER A)
{
#if USOSNET_NDIS4
    EthFilterDprIndicateReceiveComplete(USOSNET_ETHDB(A->Handle));
#else
    NdisMEthIndicateReceiveComplete(A->Handle);
#endif
}

static const USOSNET_CHIP *FindChip(ULONG VenDev)
{
    UINT i;
    for (i = 0; i < sizeof(g_Chips) / sizeof(g_Chips[0]); i++)
        if (g_Chips[i].Vendor == (VenDev & 0xFFFF) && g_Chips[i].Device == (VenDev >> 16)) return &g_Chips[i];
    return NULL;
}

#if USOSNET_NDIS4 && !USOSNET_NT35
/* NT4 (no PnP): every PCI bus, device and function for the first supported
 * card. NT4's NdisReadPciSlotInformation reads HAL bus data of the bus in
 * the miniport block with the slot number as given; NdisOverrideBusNumber
 * sets that bus (also the one NdisMPciAssignResources, NdisMMapIoSpace and
 * NdisMRegisterInterrupt use). Found: PciBus / PciSlot, bus left selected. */
static BOOLEAN LegacyFind(PADAPTER A, NDIS_HANDLE Wcc)
{
    ULONG bus, dev, fn, id, hdr, slot;
    for (bus = 0; bus < 256; bus++) {
        NdisOverrideBusNumber(Wcc, A->Handle, bus);
        for (dev = 0; dev < 32; dev++) {
            for (fn = 0; fn < 8; fn++) {
                slot = dev | (fn << 5);
                id = 0xFFFFFFFF;
                if (NdisReadPciSlotInformation(A->Handle, slot, 0, &id, 4) != 4 ||
                    (id & 0xFFFF) == 0 || (id & 0xFFFF) == 0xFFFF) {
                    if (fn == 0) break;
                    continue;
                }
                if (FindChip(id)) {
                    A->PciBus = bus;
                    A->PciSlot = slot;
                    UsLog(A, "nt4 scan: bus %x slot %x", bus, slot);
                    return TRUE;
                }
                if (fn == 0) {
                    hdr = 0;
                    NdisReadPciSlotInformation(A->Handle, slot, 0x0C, &hdr, 4);
                    if (!(hdr & 0x00800000UL)) break;   /* not multi-function */
                }
            }
        }
    }
    NdisOverrideBusNumber(Wcc, A->Handle, 0);
    return FALSE;
}
#endif

#if USOSNET_NT351
/* No card through the HAL: every bus, device and function through CF8h/CFCh
 * (usosnet.h). Found: g_UsCf8Bus / PciBus / PciSlot; the miniport block's
 * bus stays 0 (LegacyFind put it back), the Isa bus of BusType 1. */
static BOOLEAN Cf8Find(PADAPTER A)
{
    ULONG bus, dev, fn, id, hdr, slot;
    for (bus = 0; bus < 256; bus++) {
        for (dev = 0; dev < 32; dev++) {
            for (fn = 0; fn < 8; fn++) {
                slot = dev | (fn << 5);
                id = Cf8Read32(bus, slot, 0);
                if ((id & 0xFFFF) == 0 || (id & 0xFFFF) == 0xFFFF) {
                    if (fn == 0) break;
                    continue;
                }
                if (FindChip(id)) {
                    g_UsCf8Bus = bus;
                    A->PciBus = bus;
                    A->PciSlot = slot;
                    A->Cf8 = TRUE;
                    return TRUE;
                }
                if (fn == 0) {
                    hdr = Cf8Read32(bus, slot, 0x0C);
                    if (!(hdr & 0x00800000UL)) break;   /* not multi-function */
                }
            }
        }
    }
    return FALSE;
}

/* BAR0 size through CF8h/CFCh: memory decode off, all ones, read back,
 * restore BAR0 and the command register. 0 = not a sizeable memory BAR. */
static ULONG Cf8Bar0Size(PADAPTER A)
{
    ULONG cmd, orig, v;
    cmd = Cf8Read32(A->PciBus, A->PciSlot, 4) & 0xFFFF;
    Cf8Write(A->PciBus, A->PciSlot, 4, cmd & ~0x0002UL, 2);
    orig = Cf8Read32(A->PciBus, A->PciSlot, 0x10);
    Cf8Write(A->PciBus, A->PciSlot, 0x10, 0xFFFFFFFFUL, 4);
    v = Cf8Read32(A->PciBus, A->PciSlot, 0x10);
    Cf8Write(A->PciBus, A->PciSlot, 0x10, orig, 4);
    Cf8Write(A->PciBus, A->PciSlot, 4, cmd, 2);
    if ((v & 1) || !(v & ~0xFUL) || v == 0xFFFFFFFFUL) return 0;
    return ~(v & ~0xFUL) + 1;
}
#endif

#if USOSNET_NT35
/* NT35 wrapper SHAfa392...5543, RVA9258 reads BusNumber/BusType from the
 * adapter Parameters before Initialize (9599/95C7 ->96F0/96EA). There is
 * no bus-override API. Require the exact preflight-selected bus/slot and
 * use the real miniport handle; never fabricate a full-MAC handle for
 * the unrelated five-argument NdisPciAssignResources.
 * Firmware BAR0 is checked below and NdisMMapIoSpace claims/translates
 * that range through original NdisMapIoSpace/IoReportResourceUsage. */
static BOOLEAN ConfiguredFind35(PADAPTER A, NDIS_HANDLE Cfg)
{
    NDIS_STRING bus = NDIS_STRING_CONST("BusNumber");
    NDIS_STRING slot = NDIS_STRING_CONST("UsosPciSlot");
    NDIS_STRING type = NDIS_STRING_CONST("BusType");
    ULONG id = 0xFFFFFFFF;
    if (!Cfg) return FALSE;
    A->PciBus = CfgInt(Cfg, &bus, 0xFFFFFFFF);
    A->PciSlot = CfgInt(Cfg, &slot, 0xFFFFFFFF);
    if (A->PciBus > 255 || A->PciSlot > 255 || CfgInt(Cfg, &type, 0xFFFFFFFF) != NdisInterfacePci)
        return FALSE;
    UsLog(A, "nt35 configured bus %x slot %x", A->PciBus, A->PciSlot);
    return NdisReadPciSlotInformation(A->Handle, A->PciSlot, 0, &id, 4) == 4 && FindChip(id) != NULL;
}
#endif

#if USOSNET_W95RTM
/* X470 950 run (NDISLOG 2026-10-25): the mapped "registers" were RAM with
 * x86 code (STATUS 0x1C24448B = mov eax,[esp+1Ch], IMS kept after IMC,
 * TDH never moved) while link / MAC / rings were "programmed". The I211
 * BAR0 is fully relocatable (LogConfig MEM_RANGE align 128 KiB, min 0, max
 * FFFFFFFF), and the 950 CONFIGMG may place it in address space it takes
 * for free: the RAM hidden above MaxPhysPage (1E000 = 480 MiB), which the
 * memory controller answers instead of the card (behind the bus-4 bridge
 * such an address is outside the bridge window as well). The prep
 * environment records the firmware BAR0 as UsosBootBar0. When the assigned
 * range does not answer like an igb (IgbMmioProbe) and config BAR0 differs
 * from the firmware one: put the firmware address back (memory decode off
 * meanwhile), map it, probe again. All of it is recorded (USN6 / USN7); a
 * failed probe still carries on as before, so the log gets written. */
static void MmioRemap(PADAPTER A, ULONG Bar0)
{
    ULONG cmd = 0, off, nb = A->BootBar0;
    NDIS_PHYSICAL_ADDRESS pa;
    PVOID va = NULL;
    NDIS_STATUS st;
    A->OldBar0 = Bar0;
    NdisReadPciSlotInformation(A->Handle, A->PciSlot, 4, &cmd, 4);
    cmd &= 0xFFFF;
    off = cmd & ~0x0002UL;
    NdisWritePciSlotInformation(A->Handle, A->PciSlot, 4, &off, 2);
    NdisWritePciSlotInformation(A->Handle, A->PciSlot, 0x10, &nb, 4);
    NdisWritePciSlotInformation(A->Handle, A->PciSlot, 4, &cmd, 2);
    NdisSetPhysicalAddressHigh(pa, 0);
    NdisSetPhysicalAddressLow(pa, nb);
    st = NdisMMapIoSpace(&va, A->Handle, pa, 0x20000);
    if (st != NDIS_STATUS_SUCCESS || !va) { A->ProbeRestore = 0xFFFFFFFF; return; }
    NdisMUnmapIoSpace(A->Handle, (PVOID)A->Mmio, A->MmioLen);
    A->Mmio = (volatile UCHAR *)va;
    A->MmioPa = pa;
    A->MmioLen = 0x20000;
    A->MmioHow = 4;
    A->ProbeRestore = IgbMmioProbe(A);
    UsLog(A, "boot bar0 %x probe %x", nb, A->ProbeRestore);
}
#endif

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
    PNDIS_RESOURCE_LIST rl = NULL;
    PVOID netAddr;
    UINT netAddrLen;
    NDIS_STRING kPoll = NDIS_STRING_CONST("PollMode");
    NDIS_STRING kDbg = NDIS_STRING_CONST("DebugPort");
    NDIS_STRING kSkipPhy = NDIS_STRING_CONST("SkipPhy");
#if USOSNET_W95RTM
    NDIS_STRING kBootBar = NDIS_STRING_CONST("UsosBootBar0");
#endif

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
#if USOSNET_NT351
    BcInit(WrapperConfigurationContext);
#endif
    BC(A, 0x01);

    NdisOpenConfiguration(&st, &cfg, WrapperConfigurationContext);
    if (st != NDIS_STATUS_SUCCESS) cfg = NULL;
    if (cfg) {
        A->PollMode = CfgInt(cfg, &kPoll, 0);
        A->DebugPort = CfgInt(cfg, &kDbg, 0) & 0xFFFF;
        A->SkipPhy = CfgInt(cfg, &kSkipPhy, 0);
#if USOSNET_NT351
        {
            NDIS_STRING kBusType = NDIS_STRING_CONST("BusType");
            A->BusType = CfgInt(cfg, &kBusType, 0xFFFFFFFF);
        }
#endif
#if USOSNET_W95RTM
        A->BootBar0 = CfgHexString(cfg, &kBootBar) & ~0xFUL;
#endif
    }
    A->Stage = ST_CONFIG;
    UsLog(A, "init v%x poll %x", (USOSNET_MAJOR << 16) | USOSNET_MINOR, A->PollMode);
    BC(A, 0x02);

#if USOSNET_NDIS30
    NdisMSetAttributes(MiniportAdapterHandle, (NDIS_HANDLE)A, TRUE, NdisInterfacePci);
#else
    NdisMSetAttributesEx(MiniportAdapterHandle, (NDIS_HANDLE)A, 0,
                         NDIS_ATTRIBUTE_BUS_MASTER, NdisInterfacePci);
#endif
    BC(A, 0x03);

#if USOSNET_NT35
    A->Legacy = TRUE;
    if (!ConfiguredFind35(A, cfg)) { st = NDIS_STATUS_ADAPTER_NOT_FOUND; goto fail; }
    A->AssignStatus = NDIS_STATUS_NOT_SUPPORTED; /* no full-MAC resources API */
#else
#if USOSNET_NDIS4
    /* 95 OSR2 (PnP): the devnode's resources, PCI slot numbers are ignored.
     * NT4: NDIS.SYS 4.0 answers NOT_SUPPORTED; find the card, then let the
     * HAL assign (claim) its resources for this slot. */
#if USOSNET_NDIS3
    /* Original NDIS351 SHA948d...ab1b, RVA3B26 only returns
       STATUS_NOT_SUPPORTED in EAX (ret0x10); it never writes *Status.
       Do not inherit SUCCESS from NdisOpenConfiguration or read the
       uninitialized resource buffer as a PnP result. NT4/95 stay unchanged. */
    st = NDIS_STATUS_NOT_SUPPORTED;
#endif
    NdisMQueryAdapterResources(&st, WrapperConfigurationContext, res, &resLen);
#if USOSNET_NDIS3
    UsLog(A, "resources status %x bytes %x", st, resLen);
#endif
#if USOSNET_W95RTM
    A->ResStatus = st;
#endif
    if (st == NDIS_STATUS_SUCCESS) {
        rl = res;
    } else {
        A->Legacy = TRUE;
#if USOSNET_NT351
        if (!LegacyFind(A, WrapperConfigurationContext)) {
            /* native NT 3.51: no HAL PCI bus (usosnet.h); config BAR0 and
             * line below, mapped and connected through BusType 1 (Isa) */
            if (!Cf8Find(A)) { st = NDIS_STATUS_ADAPTER_NOT_FOUND; goto fail; }
            A->AssignStatus = NDIS_STATUS_NOT_SUPPORTED;
            UsLog(A, "cf8 scan: bus %x slot %x", A->PciBus, A->PciSlot);
            UsLog(A, "cf8 bus type %x", A->BusType, 0);
        } else
#else
        if (!LegacyFind(A, WrapperConfigurationContext)) { st = NDIS_STATUS_ADAPTER_NOT_FOUND; goto fail; }
#endif
        {
        A->AssignStatus = NdisMPciAssignResources(MiniportAdapterHandle, A->PciSlot, &rl);
        if (A->AssignStatus != NDIS_STATUS_SUCCESS) rl = NULL;  /* BAR0 / interrupt line below */
        UsLog(A, "nt4 assign %x list %x", A->AssignStatus, rl ? rl->Count : 0);
        }
    }
#endif

#endif

    /* PCI identity; memory decode + bus master on, INTx not disabled */
    BC(A, 0x04);
    cfg32 = 0;
    NdisReadPciSlotInformation(MiniportAdapterHandle, A->PciSlot, 0, &cfg32, 4);
    A->VendorId = (USHORT)(cfg32 & 0xFFFF);
    A->DeviceId = (USHORT)(cfg32 >> 16);
    A->Chip = FindChip(cfg32);
    NdisReadPciSlotInformation(MiniportAdapterHandle, A->PciSlot, 8, &cfg32, 4);
    A->RevId = (UCHAR)cfg32;
    UsLog(A, "pci %x rev %x", cfg32 = ((ULONG)A->VendorId << 16) | A->DeviceId, A->RevId);
    if (!A->Chip) { st = NDIS_STATUS_ADAPTER_NOT_FOUND; goto fail; }
    NdisReadPciSlotInformation(MiniportAdapterHandle, A->PciSlot, 4, &cfg32, 4);
#if USOSNET_NT351
    /* native NT 3.51: memory decode only; bus master after the chip reset
     * below, so queues the firmware (UEFI SNP / PXE) left programmed cannot
     * DMA into its old ring addresses, now NT memory, in the meantime */
    cfg32 = ((cfg32 & 0xFFFF) | 0x0002) & ~0x0004UL;
#else
    cfg32 = (cfg32 & 0xFFFF) | 0x0006;
#endif
    cfg32 &= ~0x0400UL;
    NdisWritePciSlotInformation(MiniportAdapterHandle, A->PciSlot, 4, &cfg32, 2);
    NdisReadPciSlotInformation(MiniportAdapterHandle, A->PciSlot, 0x10, &bar0, 4);
#if USOSNET_W95RTM
    A->Bar0Init = bar0;
#endif
    A->Stage = ST_PCI;
    BC(A, 0x05);

    /* BAR0 (CSR, 128 KiB) from config space; a 64-bit BAR has its high half at 0x14 */
    bar0hi = 0;
    if ((bar0 & 7) == 4) NdisReadPciSlotInformation(MiniportAdapterHandle, A->PciSlot, 0x14, &bar0hi, 4);
    A->Bar0High = bar0hi;

    /* resources: the memory range at BAR0; else the first one of >= 128 KiB */
#if !USOSNET_NDIS4
    NdisMQueryAdapterResources(&st, WrapperConfigurationContext, res, &resLen);
    if (st == NDIS_STATUS_SUCCESS) rl = res;
#endif
    if (rl) {
        res = rl;
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
#if USOSNET_W95RTM
            if (d->Type == CmResourceTypeMemory) {
                if ((A->ResInfo & 0x7F00) < 0x7F00) A->ResInfo += 0x100;
                if (!A->ResMemLen || (A->ResMemLen < 0x20000 && d->u.Memory.Length >= 0x20000)) {
                    A->ResMemStart = NdisGetPhysicalAddressLow(d->u.Memory.Start);
                    A->ResMemLen = d->u.Memory.Length;
                }
            }
#endif
        }
#if USOSNET_W95RTM
        /* no "first memory range of >= 128 KiB" fallback here: on the X470
         * 950 run the mapped range was not the card (RAM, see MmioRemap);
         * without a BAR0 match config BAR0 is used below (MmioHow 3) */
        A->ResInfo |= res->Count & 0xFF;
        if (memFound) A->MmioHow = 1;
#else
        for (i = 0; !memFound && i < res->Count; i++) {
            PCM_PARTIAL_RESOURCE_DESCRIPTOR d = &res->PartialDescriptors[i];
            if (d->Type == CmResourceTypeMemory && d->u.Memory.Length >= 0x20000) {
                A->MmioPa = d->u.Memory.Start;
                A->MmioLen = d->u.Memory.Length;
                memFound = TRUE;
            }
        }
#endif
    }
#if USOSNET_W95RTM
    if (A->Legacy) A->ResInfo |= 0x8000;
#endif
    if (!memFound && (bar0 & ~0xFUL) && !(bar0 & 1)) {
        /* no list (should not happen with PnP): BAR0 from config space */
        NdisSetPhysicalAddressHigh(A->MmioPa, bar0hi);
        NdisSetPhysicalAddressLow(A->MmioPa, bar0 & ~0xFUL);
        A->MmioLen = 0x20000;
#if USOSNET_W95RTM
        A->MmioHow = 3;
#endif
    }
    if (!A->IrqLevel && !A->IrqVector) {
        NdisReadPciSlotInformation(MiniportAdapterHandle, A->PciSlot, 0x3C, &cfg32, 4);
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
    BC(A, 0x06);

    st = NdisMMapIoSpace((PVOID *)&A->Mmio, MiniportAdapterHandle, A->MmioPa, A->MmioLen);
#if USOSNET_NT351
    /* X470 2026-10-29 (breadcrumbs, point 06 -> fail, 0xC000009A): on the
     * Cf8 path NdisMMapIoSpace fails; it reports the range as a PCI-typed
     * resource list on a HAL without a PCI bus. The CSR BAR is mapped
     * directly then (non-cached, at most 128 KiB); FreeAll unmaps it with
     * MmUnmapIoSpace. The NDIS status is kept as UsosnetMapStatus. */
    A->MapStatus = st;
    A->MapHow = (st == NDIS_STATUS_SUCCESS && A->Mmio) ? 1 : 0;
    if (!A->MapHow && A->Cf8) {
        PHYSICAL_ADDRESS pa;
        A->Mmio = NULL;
        A->Bar0Size = Cf8Bar0Size(A);
        if (A->Bar0Size && A->Bar0Size < A->MmioLen) A->MmioLen = A->Bar0Size;
        pa.LowPart = NdisGetPhysicalAddressLow(A->MmioPa);
        pa.HighPart = 0;
        A->Mmio = (volatile UCHAR *)MmMapIoSpace(pa, A->MmioLen, MmNonCached);
        if (A->Mmio) { A->MmDirect = TRUE; A->MapHow = 2; st = NDIS_STATUS_SUCCESS; }
    }
    if (!A->MapHow) A->Mmio = NULL;
    BcMap(A);
#endif
    if (st != NDIS_STATUS_SUCCESS || !A->Mmio) { A->Mmio = NULL; st = NDIS_STATUS_RESOURCES; goto fail; }
#if USOSNET_W95RTM
    A->ProbeMap = IgbMmioProbe(A);
    if (A->ProbeMap != 1 && A->BootBar0 && (bar0 & ~0xFUL) != A->BootBar0) MmioRemap(A, bar0);
#endif
    A->Stage = ST_MMIO;
    BC(A, 0x07);

    st = A->Chip->Ops->Reset(A);
    if (st != NDIS_STATUS_SUCCESS) goto fail;
#if USOSNET_NT351
    NdisReadPciSlotInformation(MiniportAdapterHandle, A->PciSlot, 4, &cfg32, 4);
    cfg32 = (cfg32 & 0xFFFF & ~0x0400UL) | 0x0006;
    NdisWritePciSlotInformation(MiniportAdapterHandle, A->PciSlot, 4, &cfg32, 2);
#endif
    A->Stage = ST_RESET;
    BC(A, 0x08);

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
    BC(A, 0x09);

    st = NdisMAllocateMapRegisters(MiniportAdapterHandle, 0, NDIS_DMA_32BITS, 1, BUF_SIZE);
    if (st != NDIS_STATUS_SUCCESS) goto fail;
    A->MapRegs = TRUE;
    BC(A, 0x0A);
    if (!AllocRings(A)) { st = NDIS_STATUS_RESOURCES; goto fail; }
    StatsInit(A);                             /* optional: no page, no live statistics */
    A->Stage = ST_DMA;
#if USOSNET_NT351
    BcDma(A);
#endif
    BC(A, 0x0B);

    A->Chip->Ops->Start(A);
    A->Stage = ST_RINGS;
#if USOSNET_NT351
    BcRings(A);
#endif
    BC(A, 0x0C);

#if USOSNET_NT351
    /* Cf8: nobody routed the card's INTx (no PCI BIOS, no ACPI under the
     * Standard PC HAL); the line register may name an 8259 IRQ another
     * device asserts, and connecting there could unmask a level storm. The
     * chip stays masked and the 20 ms timer polls (PollMode 2). */
    if (A->Cf8 && !A->PollMode) {
        UsLog(A, "cf8 line %x: poll", A->IrqVector, 0);
        A->PollMode = 2;
    }
#endif
    if (!A->PollMode) {
        st = NdisMRegisterInterrupt(&A->Interrupt, MiniportAdapterHandle, A->IrqVector, A->IrqLevel,
                                    TRUE, TRUE, NdisInterruptLevelSensitive);
        A->IrqStatus = st;
#if USOSNET_NDIS4
        /* NT4 without a HAL-assigned interrupt (config-space line only) or a
         * refused line: the 20 ms timer carries RX / TX (PollMode 2) */
        if (st != NDIS_STATUS_SUCCESS) {
            UsLog(A, "irq register failed %x: poll", st, 0);
            A->PollMode = 2;
            st = NDIS_STATUS_SUCCESS;
        } else {
            A->IrqRegistered = TRUE;
        }
#else
        if (st != NDIS_STATUS_SUCCESS) goto fail;
        A->IrqRegistered = TRUE;
#endif
    }
    A->Stage = ST_IRQ;
    BC(A, 0x0D);

    if (!A->SkipPhy) A->Chip->Ops->PhyInit(A);
    A->Stage = ST_PHY;
    BC(A, 0x0E);

    A->Chip->Ops->SetFilter(A);
    /* initial link state: OID_GEN_MEDIA_CONNECT_STATUS answers from it, the
     * timer indicates every later change */
    A->Chip->Ops->LinkState(A, &A->LinkUp, &A->LinkMbps, &A->FullDuplex);
    A->LinkReported = TRUE;
    if (!A->PollMode) A->Chip->Ops->IrqEnable(A);
    BC(A, 0x0F);
#if USOSNET_DRVTIMER
    NdisMInitializeTimer(&A->Timer, MiniportAdapterHandle, TimerFn, A);
    A->TimerInit = TRUE;
#if USOSNET_NDIS30
    NdisSetTimer((PNDIS_TIMER)&A->Timer, TICK_MS);
#else
    NdisMSetPeriodicTimer(&A->Timer, TICK_MS);
#endif
#endif
    BC(A, 0x10);
    NdisMRegisterAdapterShutdownHandler(MiniportAdapterHandle, A, MpShutdown);
    A->Shutdown = TRUE;
    A->Started = TRUE;
    A->Stage = ST_STARTED;
    UsLog(A, "started stage %x status %x", A->Stage, A->StatusAtInit);
    BC(A, 0x11);
    if (cfg) { WriteDiag(A, USOSNET_DIAG_HANDLE(cfg, WrapperConfigurationContext)); NdisCloseConfiguration(cfg); }
    BC(A, 0x12);
    return NDIS_STATUS_SUCCESS;

fail:
    A->Error = st;
    UsLog(A, "init failed stage %x status %x", A->Stage, st);
    BC(A, 0x1F);
    if (A->Mmio) A->Chip->Ops->Stop(A);
    if (cfg) { WriteDiag(A, USOSNET_DIAG_HANDLE(cfg, WrapperConfigurationContext)); NdisCloseConfiguration(cfg); }
    BC(A, 0x1E);
    FreeAll(A);
    return st;
}

static VOID MpHalt(NDIS_HANDLE Ctx)
{
    PADAPTER A = (PADAPTER)Ctx;
#if USOSNET_DRVTIMER
    BOOLEAN cancelled = TRUE;
#endif
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
#if USOSNET_DRVTIMER
#if USOSNET_NT351
    {
        BOOLEAN armed = A->TimerInit;
        A->TimerInit = FALSE;            /* a running callback does not re-arm */
        if (armed) NdisMCancelTimer(&A->Timer, &cancelled);
        /* a run NDIS already deferred may still come: keep the (small)
         * adapter block so it finds Halted, free everything else */
        if (armed && !cancelled) A->Halted = TRUE;
        /* a queued alive record still reads the adapter block */
        if (A->AlivePending) A->Halted = TRUE;
        if (A->FirstIndPending) A->Halted = TRUE;
    }
#else
    if (A->TimerInit) NdisMCancelTimer(&A->Timer, &cancelled);
#endif
#endif
    A->TimerInit = FALSE;
#if USOSNET_NATIVE4
    N4Drain();
#endif
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
#if USOSNET_NDIS3
    PADAPTER A = (PADAPTER)Ctx;
    ULONG rx;
    if (!A->Started) return FALSE;
#if USOSNET_DRVTIMER
    if (A->TimerInit) return FALSE;      /* NT 3.51: TimerFn does it every 20 ms */
#endif
    rx = A->RxOk;
    /* Original NDIS351 RVA98E: lock+0x30 and busy+0x2E serialize this
     * callback with the miniport. NT35 SHAfa392...5543 confirms the same
     * gate in946 and Halt7F68; Check rearm9DD/9E9 is2000ms.
     * It rearms its own timer for 2000 ms.
     * Halt873C owns that same gate; no driver timer/DPC needs draining.
     * IRQ/HandleInterrupt is the normal fast path. This is a slow fallback,
     * not the 20 ms fallback of NT4/95. Counters below are nominal time. */
    A->Chip->Ops->RxPoll(A);
    if (!A->PollMode) A->RxByTimer += A->RxOk - rx;
    A->Chip->Ops->TxReclaim(A);
    A->TimerCount += USOSNET351_CHECK_SECONDS * TICKS_PER_SEC;
    TimerSecond(A);
#else
    UNREFERENCED_PARAMETER(Ctx);
#endif
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

#if !USOSNET_NT351
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
#endif

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
    if (A->Stats) {
        USNS_BLOCK *S = A->Stats;
        ULONG ports, peer, c = UsnsClassify(dst, total, 0, &ports, &peer);
        UsnsCount(S->Tx, c);
        UsnsHistory(S, 2, c, ports, total, 0, peer);
        if (c & USNS_C_DNS) StatsDump(S->LastDnsTx, &S->LastDnsTxLen, dst, total);
        if (UsnsIsLogRequest(c, ports)) A->LogRequest = 1;
    }
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
    USNS_BLOCK *S = A->Stats;
    UNREFERENCED_PARAMETER(Ctx);
    *BytesTransferred = 0;
    if (S) {
        S->Td[USNS_T_CALLS]++;
        if (ByteOffset > S->Td[USNS_T_MAX_OFFSET]) S->Td[USNS_T_MAX_OFFSET] = ByteOffset;
        if (BytesToTransfer > S->Td[USNS_T_MAX_LEN]) S->Td[USNS_T_MAX_LEN] = BytesToTransfer;
        if (!A->CurRx) {
            S->Td[USNS_T_NO_FRAME]++;
        } else {
            if (A->CurRxClasses & USNS_C_UDP) S->Td[USNS_T_UDP]++;
            if (A->CurRxClasses & USNS_C_DNS) S->Td[USNS_T_DNS]++;
        }
    }
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
    if (S) {
        S->Td[USNS_T_BYTES] += done;
        if (done < BytesToTransfer) S->Td[USNS_T_SHORT]++;
    }
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
    USHORT ver = USOSNET_NDIS_MAJOR << 8;   /* NDIS 4.0 / 5.0 */
    NDIS_HARDWARE_STATUS hw = NdisHardwareStatusReady;
    NDIS_MEDIUM med = NdisMedium802_3;
    BOOLEAN counter = FALSE;

    *Written = 0;
    *Needed = 0;
#if USOSNET_NT351
    A->LastOid = Oid; A->LastOidKind = 1; A->OidCount++;
#endif
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
#if USOSNET_NT351
    A->LastOid = Oid; A->LastOidKind = 2; A->OidCount++;
#endif
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

#if USOSNET_NATIVE4
    N4Init(RegistryPath);
#endif
    NdisMInitializeWrapper(&g_Wrapper, DriverObject, RegistryPath, NULL);
    if (!g_Wrapper) return NDIS_STATUS_FAILURE;
    UsZero(&mc, sizeof(mc));
    mc.MajorNdisVersion = USOSNET_NDIS_MAJOR;
    mc.MinorNdisVersion = 0;
    mc.CheckForHangHandler = MpCheckForHang;
#if USOSNET_NT351 || USOSNET_NATIVE4
    /* NT4 mini.h has the same unchecked Interrupt dereference. Both builds
     * use RequestIsr=TRUE/shared IRQ, so enable/disable callbacks are unneeded.
     * X470 2026-10-29 (fbd0fc8d): STOP 0xA (0, 2, 0, NDIS.SYS+7291) in a
     * DPC, MpInitialize had returned SUCCESS (BcPoint 0x12), no alive
     * record yet; MpHandleInterrupt and MpDisableInterrupt on the stack.
     * The NT 3.5 wrapper fires Miniport->DpcTimer after OID queries during
     * the adapter setup (WRAPPER.C) and later from deferred processing;
     * NdisMDpcTimer then runs MINIPORT_SYNC_DISABLE_INTERRUPT, i.e.
     * KeSynchronizeExecution(Miniport->Interrupt->InterruptObject, ...)
     * whenever DisableInterruptHandler is not NULL, without checking
     * Miniport->Interrupt. In PollMode 2 (Cf8 path) no interrupt is
     * registered, Interrupt is NULL: read of address 0. Both SYNC macros
     * skip NULL handlers. With RequestIsr = TRUE and a shared line (the
     * only way this driver registers) NdisMIsr never calls
     * DisableInterruptHandler (NormalInterrupts stays FALSE): MpIsr masks
     * the chip through IrqRead and MpHandleInterrupt re-enables it, so the
     * interrupt mode does not need the two handlers either. */
    mc.DisableInterruptHandler = NULL;
    mc.EnableInterruptHandler = NULL;
#else
    mc.DisableInterruptHandler = MpDisableInterrupt;
    mc.EnableInterruptHandler = MpEnableInterrupt;
#endif
    mc.HaltHandler = MpHalt;
    mc.HandleInterruptHandler = MpHandleInterrupt;
    mc.InitializeHandler = MpInitialize;
    mc.ISRHandler = MpIsr;
    mc.QueryInformationHandler = MpQuery;
    mc.ResetHandler = MpReset;
    mc.SendHandler = MpSend;
    mc.SetInformationHandler = MpSet;
    mc.TransferDataHandler = MpTransferData;
    st = NdisMRegisterMiniport(g_Wrapper, &mc, USOSNET_CHARS_SIZE);
    if (st != NDIS_STATUS_SUCCESS) {
        NdisTerminateWrapper(g_Wrapper, NULL);
        return st;
    }
    return NDIS_STATUS_SUCCESS;
}
