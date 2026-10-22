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
#if USOSNET_NT351 && !USOSNET_NDIS4
#error NT351 uses the legacy receive and PCI paths
#endif
#if USOSNET_NT351
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
 * NT351 creates no driver timer; its NDIS-owned CheckForHang is a slow
 * nominal2000ms fallback. IRQ is the normal RX/TX path in that variant. */
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
       DR_RXDCTL, DR_TXDCTL, DR_RXCSUM, DIAG_REGS };

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

extern const USOSNET_CHIP_OPS IgbOps;

#endif
