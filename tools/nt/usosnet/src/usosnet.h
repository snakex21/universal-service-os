/*
 * usosnet - USOS own Ethernet NDIS miniport (shared core + chip backends),
 * part of Universal Service OS (USOS).
 *
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * One binary for Windows 98 / 98 SE / Me (NDIS.VXD loads NDIS 5.0 PE
 * miniports) and Windows 2000 / XP / Server 2003 x86. Rules that keep the
 * binary loadable on 9x (see docs/usosnet-design-2026-10-18.md):
 *   - imports from NDIS.SYS only (no ntoskrnl / HAL): no NdisZeroMemory /
 *     NdisMoveMemory / NdisStallExecution / NdisWriteRegisterUlong macros
 *     (they expand to ntoskrnl / HAL calls when BINARY_COMPATIBLE is 0,
 *     which WDK 7.1 forces); own copy / zero / stall helpers instead;
 *   - NDIS_BUFFER is an MDL on NT but a different structure on 9x: only
 *     the exported NdisQueryBuffer() and the common Next field are used;
 *   - no 64-bit arithmetic (no __allmul / __aullshr helper imports);
 *   - serialized miniport (no spin locks needed): NDIS never runs
 *     MiniportSend, MiniportHandleInterrupt and the timer at the same time,
 *     so TX reclaim / RX polling may happen in any of them; the ISR only
 *     reads ICR and masks the chip. The link state is touched by the timer.
 */
#ifndef USOSNET_H
#define USOSNET_H

#include <ndis.h>
#include "usosnet_proto.h"

#define USOSNET_MAJOR 0
#define USOSNET_MINOR 5

/* USOSNET_NDIS4=1 (src4/sources): usosnet4.sys, registered as an NDIS 4.0
 * miniport for Windows 95 OSR2 (NDIS.VXD 4.0) and Windows NT 4.0 (NDIS.SYS
 * 4.0); both refuse MajorNdisVersion 5. Differences, all in usosnet.c
 * (docs/usosnet-ndis4-2026-10-20.md):
 *   - characteristics: the NDIS 3.0 part + the three 4.0 handlers (0x48);
 *   - receive indication through the exported EthFilterDprIndicateReceive /
 *     ...Complete with the filter at NDIS_MINIPORT_BLOCK + 0xD8 (the same
 *     offset in WDK 7.1, the NT4 SP6a and the 95 OSR2 drivers) instead of
 *     the NDIS 5 handler pointers of the miniport block;
 *   - NT4 (no PnP: NdisMQueryAdapterResources answers NOT_SUPPORTED): the
 *     driver finds the card on the PCI buses itself (NdisOverrideBusNumber +
 *     NdisReadPciSlotInformation with a real slot number) and takes the
 *     resources from NdisMPciAssignResources;
 *   - a failed NdisMRegisterInterrupt switches to timer polling instead of
 *     failing the start. */
#ifndef USOSNET_NDIS4
#define USOSNET_NDIS4 0
#endif
#ifndef USOSNET_NT351
#define USOSNET_NT351 0
#endif
#ifndef USOSNET_NT35
#define USOSNET_NT35 0
#endif
#ifndef USOSNET_W95RTM
#define USOSNET_W95RTM 0
#endif
#define USOSNET_NDIS3 (USOSNET_NT351 || USOSNET_NT35)
/* NDIS 3.0 registration (MajorNdisVersion 3, 0x3C characteristics, the
 * four-argument NdisMSetAttributes): the NT 3.5x family above and Windows 95
 * RTM / OSR1 (NDIS.VXD of SETUP 4.0.0.950, USOSNET_W95RTM). Only NT 3.5x
 * drops the driver timer for the NDIS-owned CheckForHang; 95 RTM keeps the
 * NT4/95 driver timer, re-armed with the one-shot NdisSetTimer because its
 * NDIS.VXD has no NdisMSetPeriodicTimer. */
#define USOSNET_NDIS30 (USOSNET_NDIS3 || USOSNET_W95RTM)
/* Driver-owned 20 ms timer (TimerFn): every build except NT 3.5, which
 * keeps the NDIS-owned 2 s CheckForHang. NT 3.51 got the timer back for
 * the native path (no install VM, docs/nt351-native-net-2026-10-28.md): on
 * the X470 its HAL has no PCI bus handler, so the card's INTx is not
 * reachable and the timer carries RX / TX. The NDIS 3.0 builds re-arm the
 * one-shot NdisSetTimer (95 RTM pattern). */
#define USOSNET_DRVTIMER (!USOSNET_NDIS3 || USOSNET_NT351)
#if USOSNET_NT351 + USOSNET_NT35 + USOSNET_W95RTM > 1
#error Select one NDIS 3.0 target
#endif
#if USOSNET_NDIS30 && !USOSNET_NDIS4
#error NT351 uses the legacy receive and PCI paths
#endif
#if USOSNET_NDIS30
#define USOSNET_NDIS_MAJOR 3
#elif USOSNET_NDIS4
#define USOSNET_NDIS_MAJOR 4
#else
#define USOSNET_NDIS_MAJOR 5
#endif
#define USOSNET_TAG 'NSOU'

#define ETH_ALEN 6
#define ETH_HDR 14
#define ETH_MAX_DATA 1500
#define ETH_MAX_FRAME 1514
#define MAX_MCAST 32

#define RX_COUNT 64            /* descriptors, ring = 64 * 16 = 1 KiB */
#define TX_COUNT 64
#define BUF_SIZE 2048          /* one RX / TX buffer, 2 per 4 KiB page */
#define BUFS_PER_PAGE 2

/* NT4/95/NDIS5: one timer for every mode, RX / TX housekeeping every tick (also with
 * interrupts: a lost or misrouted INTx then costs latency, not the link),
 * link, statistics, watchdogs and the diagnostic log once a second.
 * NT 3.51 has the timer too (USOSNET_DRVTIMER); NT 3.5 creates none: its
 * NDIS-owned CheckForHang is a slow nominal 2000 ms fallback there. */
#define TICK_MS         20
#define TICKS_PER_SEC   (1000 / TICK_MS)
#define LOG_MAX         40      /* NdisWriteErrorLogEntry rounds per start */
/* Windows 98 SE NDIS.VXD (also Me): before Init_Complete the 5th error log
 * entry of one adapter within 30 s removes its devnode (CONFIGMG
 * Call_At_Appy_Time -> Remove_SubTree) and the first one shows a "device
 * not working properly" notice. So no entry in the first LOG_QUIET_SEC
 * seconds and at most LOG_WINDOW_MAX entries per LOG_WINDOW_SEC window
 * (docs/98se-fresh-install-2026-10-20.md). */
#define LOG_QUIET_SEC   30
#define LOG_WINDOW_SEC  31
#define LOG_WINDOW_MAX  4

/* Diagnostic stages (registry value UsosnetStage, last stage reached). */
#define ST_ENTRY        1
#define ST_CONFIG       2
#define ST_PCI          3
#define ST_RESOURCES    4
#define ST_MMIO         5
#define ST_RESET        6
#define ST_MAC          7
#define ST_DMA          8
#define ST_RINGS        9
#define ST_IRQ          10
#define ST_PHY          11
#define ST_STARTED      12

typedef struct _DMAMEM {
    PVOID AllocVa;
    NDIS_PHYSICAL_ADDRESS AllocPa;
    ULONG AllocLen;
    PUCHAR Va;          /* aligned */
    ULONG Pa;           /* aligned, 32-bit (NDIS_DMA_32BITS) */
} DMAMEM;

struct _ADAPTER;

/* Per-chip backend (igb now; e1000e / igc / rtl8168 later). */
typedef struct _USOSNET_CHIP_OPS {
    const char *Name;
    NDIS_STATUS (*Reset)(struct _ADAPTER *A);           /* full reset, IRQs off */
    BOOLEAN (*ReadMac)(struct _ADAPTER *A, UCHAR *Mac); /* permanent address */
    void (*SetMac)(struct _ADAPTER *A, const UCHAR *Mac);
    void (*PhyInit)(struct _ADAPTER *A);                /* power up, autoneg */
    void (*Start)(struct _ADAPTER *A);                  /* rings, RX/TX on */
    void (*Stop)(struct _ADAPTER *A);                   /* RX/TX off, reset */
    void (*IrqEnable)(struct _ADAPTER *A);
    void (*IrqDisable)(struct _ADAPTER *A);
    ULONG (*IrqRead)(struct _ADAPTER *A);               /* 0 = not ours */
    BOOLEAN (*Transmit)(struct _ADAPTER *A, ULONG Len); /* frame in TxBuf[TxNext] */
    void (*TxReclaim)(struct _ADAPTER *A);
    void (*RxPoll)(struct _ADAPTER *A);                 /* indicates frames */
    void (*LinkState)(struct _ADAPTER *A, BOOLEAN *Up, ULONG *Mbps, BOOLEAN *Full);
    void (*SetFilter)(struct _ADAPTER *A);              /* PacketFilter + McList */
    void (*Stats)(struct _ADAPTER *A);                  /* accumulate clear-on-read counters */
    void (*Diag)(struct _ADAPTER *A, ULONG *R);         /* DIAG_REGS register snapshot */
} USOSNET_CHIP_OPS;

/* Diag() snapshot order */
enum { DR_STATUS, DR_CTRL, DR_IMS, DR_RCTL, DR_TCTL, DR_RDH, DR_RDT, DR_TDH, DR_TDT,
       DR_RXDCTL, DR_TXDCTL, DR_RXCSUM,
#if USOSNET_W95RTM || USOSNET_NT351
       /* 95 RTM init log (USN4 / USN8), NT 3.51 BcRings: ring bases as read back, INTx setup */
       DR_TDBAL, DR_TDBAH, DR_TDLEN, DR_RDBAL, DR_RDBAH, DR_RDLEN, DR_GPIE, DR_EIMS, DR_IVAR0,
#endif
       DIAG_REGS };

typedef struct _USOSNET_CHIP {
    USHORT Vendor;
    USHORT Device;
    ULONG Flags;
    const char *Desc;
    const USOSNET_CHIP_OPS *Ops;
} USOSNET_CHIP;

#define CHIP_IGB_82576  0x0001
#define CHIP_IGB_I210   0x0002   /* I210 / I211: iNVM or flash, PHY addr 1 */
#define CHIP_IGB_I211   0x0004   /* iNVM only */

typedef struct _ADAPTER {
    NDIS_HANDLE Handle;
    const USOSNET_CHIP *Chip;
    USHORT VendorId, DeviceId;
    UCHAR RevId;

    volatile UCHAR *Mmio;
    ULONG MmioLen;
    NDIS_PHYSICAL_ADDRESS MmioPa;

    ULONG IrqLevel, IrqVector;
    BOOLEAN IrqRegistered;
    BOOLEAN TimerInit;
    BOOLEAN MapRegs;
    BOOLEAN Started;
    BOOLEAN Shutdown;
    NDIS_MINIPORT_INTERRUPT Interrupt;
    NDIS_MINIPORT_TIMER Timer;

    UCHAR PermAddr[ETH_ALEN];
    UCHAR CurAddr[ETH_ALEN];
    ULONG MacSource;            /* 1 RAL/RAH autoload, 2 EERD, 3 iNVM, 4 registry */

    DMAMEM RxRing, TxRing;
    DMAMEM RxPage[RX_COUNT / BUFS_PER_PAGE];
    DMAMEM TxPage[TX_COUNT / BUFS_PER_PAGE];
    PUCHAR RxBuf[RX_COUNT];
    ULONG RxBufPa[RX_COUNT];
    PUCHAR TxBuf[TX_COUNT];
    ULONG TxBufPa[TX_COUNT];
    ULONG RxNext;
    ULONG TxNext, TxClean, TxBusy;

    ULONG PacketFilter;
    ULONG Lookahead;
    UCHAR McList[MAX_MCAST][ETH_ALEN];
    ULONG McCount;

    BOOLEAN LinkUp;
    BOOLEAN FullDuplex;
    BOOLEAN LinkReported;       /* first status indication done */
    ULONG LinkMbps;

    volatile LONG PendingIrq;
    ULONG ImsMask;

    /* RX frame being indicated (for MiniportTransferData) */
    PUCHAR CurRx;
    ULONG CurRxLen;
    ULONG CurRxClasses;         /* 0.4: its classes (usosnet_proto.h) */

    /* options (registry, see usosnet9x.inf [params]) */
    ULONG PollMode;             /* 1 = no interrupt (registry), 2 = switched by the IRQ watchdog */
    ULONG DebugPort;            /* 0 = off, else I/O port (0xE9 in QEMU) */
    ULONG SkipPhy;

    /* statistics */
    ULONG TxOk, RxOk, TxErr, RxErr, RxNoBuf, RxCrcErr;
    ULONG IsrCount, DpcCount, TimerCount, LinkChanges;
    ULONG IsrCalls;             /* ISR entered at all (shared line: also not ours) */
    ULONG RxByTimer;            /* frames found by the timer before any interrupt */
    ULONG TxDone, TxFull, TxStalls, TxStallSec, TxLastClean;
    ULONG HwTpr, HwTpt, HwGprc, HwGptc, HwMpc, HwRnbc, HwCrc;   /* chip counters, summed */
    ULONG LogCount;
    ULONG LogWindowStart, LogWindowUsed, LogSkipped; /* error log budget (ticks) */

    /* diagnostics written to the adapter's registry key at init */
    ULONG Stage, Error, StatusAtInit, CtrlAtInit, PhyBmsr, PhyId, Bar0High;
    ULONG PllTries;             /* I210/I211 iNVM PLL workaround: tries, 0x100 = failed */
    BOOLEAN IrqMasked;          /* set by the ISR, cleared by IrqEnable */

    /* 0.4: live statistics page (usosnet_proto.h), UsosnetStatsVa / Pa */
    DMAMEM StatsMem;
    USNS_BLOCK *Stats;
    ULONG LogRequest;           /* TX saw the USOSLOG request broadcast */
    ULONG ForcedLogs;

    /* PCI location: slot number for Ndis{Read,Write}PciSlotInformation (0 on
     * PnP systems, which ignore it; NT4: device | function << 5 on PciBus) */
    ULONG PciSlot, PciBus;
    BOOLEAN Legacy;             /* NT4: found by the bus scan, no PnP resources */
    ULONG AssignStatus;         /* NT4: NdisMPciAssignResources status */
    ULONG IrqStatus;            /* NdisMRegisterInterrupt status (NDIS 4 build: failure -> polling) */
#if USOSNET_W95RTM
    /* 95 RTM init log (USN6 / USN7, README.md); only this build, so the
     * NDIS 4 / 5 binaries keep their layout */
    ULONG Bar0Init;             /* config BAR0 as found at init */
    ULONG BootBar0;             /* registry UsosBootBar0 (prep env: firmware BAR0), 0 = none */
    ULONG OldBar0;              /* config BAR0 replaced by BootBar0, 0 = not restored */
    ULONG ResStatus;            /* NdisMQueryAdapterResources status */
    ULONG ResInfo;              /* descriptors | memory descriptors << 8 | Legacy << 15 */
    ULONG ResMemStart, ResMemLen; /* first memory descriptor of >= 128 KiB, else the first one */
    ULONG MmioHow;              /* 1 resource = BAR0, 3 config BAR0, 4 boot BAR0 restored */
    ULONG ProbeMap, ProbeRestore, ProbeReset; /* IgbMmioProbe: 1 = chip answers */
    BOOLEAN InitLogged;
#endif
#if USOSNET_NT351
    BOOLEAN Cf8;                /* found by the CF8h/CFCh scan (no HAL PCI bus) */
    BOOLEAN Halted;             /* MpHalt done; a late timer callback returns */
    ULONG BusType;              /* registry Parameters BusType (1 Isa for Cf8) */
    /* durable breadcrumbs (usosnet.c, BcWrite): alive records at 1/2/5/10 s
     * from a work item the 20 ms timer queues */
    WORK_QUEUE_ITEM AliveWi;
    volatile LONG AlivePending; /* work item queued, adapter memory must stay */
    ULONG AliveIdx;             /* next entry of g_AliveAt */
    ULONG AliveSec;             /* nominal second of the queued record */
    ULONG LastOid;              /* last OID NDIS queried or set */
    ULONG LastOidKind;          /* 1 query, 2 set */
    ULONG OidCount;
    BOOLEAN MmDirect;           /* BAR0 mapped with MmMapIoSpace (Cf8 path), not NDIS */
    ULONG MapStatus;            /* NdisMMapIoSpace status as returned */
    ULONG MapHow;               /* 1 NdisMMapIoSpace, 2 MmMapIoSpace */
    ULONG Bar0Size;             /* sized through CF8h/CFCh, 0 = not sized */
    /* first receive indication breadcrumb (UsosnetFirstInd*) */
    WORK_QUEUE_ITEM FirstIndWi;
    volatile LONG FirstIndPending; /* work item queued, adapter memory must stay */
    BOOLEAN FirstIndDone;
    ULONG FirstIndTicks, FirstIndLen;
#endif
} ADAPTER, *PADAPTER;

/* register access (MMIO through volatile pointers, no HAL import) */
static __inline ULONG RD32(PADAPTER A, ULONG Reg)
{
    return *(volatile ULONG *)(A->Mmio + Reg);
}
static __inline void WR32(PADAPTER A, ULONG Reg, ULONG Val)
{
    *(volatile ULONG *)(A->Mmio + Reg) = Val;
}

void UsZero(void *D, ULONG N);
void UsCopy(void *D, const void *S, ULONG N);
BOOLEAN UsEqual(const void *A, const void *B, ULONG N);
void UsStall(ULONG Us);
void UsLog(PADAPTER A, const char *Fmt, ULONG V1, ULONG V2);
void UsIndicateRx(PADAPTER A, PUCHAR Frame, ULONG Len, ULONG Status);
void UsIndicateRxComplete(PADAPTER A);
void UsRxDropped(PADAPTER A, PUCHAR Frame, ULONG Len, ULONG Status);

#if USOSNET_NT351
/* Native NT 3.51 (docs/nt351-native-net-2026-10-28.md): the NT 3.x MBR hides
 * the PCI BIOS on machines with more than 8 PCI buses (X470), so the HAL
 * has no PCI bus handler and NdisRead/WritePciSlotInformation return 0.
 * When the NDIS bus scan finds no card, the driver scans ports CF8h/CFCh
 * itself (as AHCINT / usosnvme NT351) and every later config access of
 * this binary goes there: g_UsCf8Bus = the card's bus, ~0 = through NDIS. */
extern ULONG g_UsCf8Bus;
ULONG UsPciRead(NDIS_HANDLE H, ULONG Slot, ULONG Off, PVOID Buf, ULONG Len);
ULONG UsPciWrite(NDIS_HANDLE H, ULONG Slot, ULONG Off, PVOID Buf, ULONG Len);
#define NdisReadPciSlotInformation(h, s, o, b, l) UsPciRead((h), (s), (o), (b), (l))
#define NdisWritePciSlotInformation(h, s, o, b, l) UsPciWrite((h), (s), (o), (b), (l))
#endif
extern const USOSNET_CHIP_OPS IgbOps;
#if USOSNET_W95RTM
ULONG IgbMmioProbe(PADAPTER A);
#endif

#endif
