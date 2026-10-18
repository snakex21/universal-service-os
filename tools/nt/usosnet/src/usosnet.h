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
 *   - serialized miniport (no spin locks needed): TX is touched only by
 *     MiniportSend, RX only by MiniportHandleInterrupt (or the poll timer
 *     in PollMode), the link state only by the timer.
 */
#ifndef USOSNET_H
#define USOSNET_H

#include <ndis.h>

#define USOSNET_MAJOR 0
#define USOSNET_MINOR 1
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
} USOSNET_CHIP_OPS;

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

    /* options (registry, see usosnet9x.inf [params]) */
    ULONG PollMode;             /* 1 = no interrupt, 10 ms... timer polling */
    ULONG DebugPort;            /* 0 = off, else I/O port (0xE9 in QEMU) */
    ULONG SkipPhy;

    /* statistics */
    ULONG TxOk, RxOk, TxErr, RxErr, RxNoBuf, RxCrcErr;
    ULONG IsrCount, DpcCount, TimerCount, LinkChanges;

    /* diagnostics written to the adapter's registry key at init */
    ULONG Stage, Error, StatusAtInit, CtrlAtInit, PhyBmsr, PhyId;
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
void UsIndicateRx(PADAPTER A, PUCHAR Frame, ULONG Len);

extern const USOSNET_CHIP_OPS IgbOps;

#endif
