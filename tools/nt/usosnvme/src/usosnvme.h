/*
 * usosnvme - NVM Express SCSIPORT miniport for Windows NT 3.1 to
 * Windows Server 2003 (x86), part of Universal Service OS (USOS).
 *
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 *
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the Free
 * Software Foundation, either version 3 of the License, or (at your option)
 * any later version. This program is distributed WITHOUT ANY WARRANTY; see
 * the GNU General Public License (LICENSE in the repository root).
 *
 * Clean-room implementation: written from the NVM Express Base Specification
 * (register map, queue and command layouts) and the public DDK documentation
 * of the SCSI port / miniport interface. No Microsoft source code and no
 * other NVMe driver's source was used.
 *
 * Build variants (tools/nt/usosnvme/build.cmd):
 *   2KXP   Windows 2000 / XP / Server 2003 x86, PnP ScsiPort (PCIBus)
 *   NT4    Windows NT 4.0 (USOSNVME_NT4): non-PnP, the miniport scans PCI
 *   NT351  Windows NT 3.5 / 3.51 (+USOSNVME_NT351): PCI config through
 *          CF8h/CFCh, registered for the Isa bus
 *   NT31   Windows NT 3.1 (+USOSNVME_NT31): NT 3.1 ScsiPort structure sizes
 *   W9X    Windows 95 OSR2 / 98 / 98 SE / Me (USOSNVME_W9X): usosnvme.mpd,
 *          a SCSI miniport for SCSIPORT.PDR under IOS (non-PnP-size init
 *          data as NT4, PCI config through CF8h/CFCh, BAR mapped with the
 *          VMM service _MapPhysToLinear, HwAdapterState, debug text to
 *          port E9h when a debug console answers there)
 */
#ifndef USOSNVME_H
#define USOSNVME_H

#include <miniport.h>
#include <scsi.h>
#include "usosnvme_diag.h"

#define USOSNVME_VERSION "1.0"

#if defined(USOSNVME_W9X) && !defined(USOSNVME_NT4)
#define USOSNVME_NT4
#endif
#if defined(USOSNVME_NT31) && !defined(USOSNVME_NT351)
#define USOSNVME_NT351
#endif
#if defined(USOSNVME_NT351) && !defined(USOSNVME_NT4)
#define USOSNVME_NT4
#endif
/* PCI configuration through ports CF8h / CFCh (no HAL / PCI bus handler) */
#if defined(USOSNVME_NT351) || defined(USOSNVME_W9X)
#define USOSNVME_CF8
#endif
/* Every data address from ScsiPort is checked before it goes into a PRP
   (NvmeBuildPrps): amd64, and NT 3.1, whose ScsiPort answers
   ScsiPortGetPhysicalAddress with SP_UNINITIALIZED_VALUE (all ones, length
   0) when the request has no scatter/gather list (2026-10-30). */
#if (defined(_WIN64) && !defined(USOSNVME_W9X)) || defined(USOSNVME_NT31)
#define USOSNVME_PRPCHECK
#endif

/* I/O queue id. Windows 9x: 2, so that a stray INT 13h from SeaBIOS (which
   created queue 1 before Windows started and still rings doorbell 1) hits a
   queue that no longer exists instead of our ring. NT never calls the BIOS. */
#ifdef USOSNVME_W9X
#define NVME_IO_QID 2
#else
#define NVME_IO_QID 1
#endif

/* ---- NVMe controller registers (NVM Express Base Specification 3.1) ---- */
#define NVME_REG_CAP_LO   0x00
#define NVME_REG_CAP_HI   0x04
#define NVME_REG_VS       0x08
#define NVME_REG_INTMS    0x0C
#define NVME_REG_INTMC    0x10
#define NVME_REG_CC       0x14
#define NVME_REG_CSTS     0x1C
#define NVME_REG_AQA      0x24
#define NVME_REG_ASQ_LO   0x28
#define NVME_REG_ASQ_HI   0x2C
#define NVME_REG_ACQ_LO   0x30
#define NVME_REG_ACQ_HI   0x34
#define NVME_REG_DOORBELL 0x1000

#define NVME_CC_EN        0x00000001UL
#define NVME_CC_IOSQES_64 (6UL << 16)
#define NVME_CC_IOCQES_16 (4UL << 20)
#define NVME_CSTS_RDY     0x00000001UL
#define NVME_CSTS_CFS     0x00000002UL
#define NVME_CC_SHN_NORMAL (1UL << 14)
#define NVME_CSTS_SHST_MASK (3UL << 2)
#define NVME_CSTS_SHST_DONE (2UL << 2)

/* Admin and NVM command set opcodes */
#define NVME_ADM_CREATE_SQ   0x01
#define NVME_ADM_CREATE_CQ   0x05
#define NVME_ADM_IDENTIFY    0x06
#define NVME_ADM_SET_FEATURE 0x09
#define NVME_NVM_FLUSH       0x00
#define NVME_NVM_WRITE       0x01
#define NVME_NVM_READ        0x02

#define NVME_FEAT_NUM_QUEUES 0x07

/* Queue geometry: one admin queue pair and one I/O queue pair, polled. */
#define NVME_PAGE          4096UL
#define NVME_ADMIN_DEPTH   16
#define NVME_IO_DEPTH      32
/* Uncached extension pages (after aligning to 4 KiB): */
#define NVME_PG_ASQ        0
#define NVME_PG_ACQ        1
#define NVME_PG_IOSQ       2
#define NVME_PG_IOCQ       3
#define NVME_PG_IDENT      4
#define NVME_PG_PRPLIST    5
#define NVME_PAGES         6

#define NVME_BAR_MAP_SIZE  0x2000
#define NVME_MAX_TRANSFER  (128UL * 1024UL)
#define NVME_MAX_BREAKS    ((NVME_MAX_TRANSFER / NVME_PAGE) + 1)
#define NVME_PRP9X_MAX     (NVME_MAX_BREAKS + 1)

/* Polling limits (microseconds of real time, see NvmeWait). Every command
   is polled inside HwStartIo at raised IRQL (the ScsiPort lock, often from
   its completion DPC); Windows 8+ stop a DPC that runs for ~20 s
   (DPC_WATCHDOG_VIOLATION) and a polled wait that long blocks the whole
   adapter, so no wait comes near that. A command that does not complete in
   time fails as ABORTED COMMAND (the class driver retries) and the
   controller is re-initialised before the next command. */
#define NVME_ADMIN_TIMEOUT_US  (5UL * 1000UL * 1000UL)
#define NVME_IO_TIMEOUT_US     (10UL * 1000UL * 1000UL)
#define NVME_FLUSH_TIMEOUT_US  (10UL * 1000UL * 1000UL)
/* CC.SHN normal shutdown: wait for CSTS.SHST = complete, RTD3E clamped */
#define NVME_SHN_MIN_MS        1000UL
#define NVME_SHN_DEFAULT_MS    5000UL
#define NVME_SHN_MAX_MS        10000UL

/* Error-log unique ids (ScsiPortLogError, System event log "usosnvme") */
#define NVME_LOG_NO_READY    0x4E560001UL  /* CSTS.RDY never became 1 / CFS */
#define NVME_LOG_ADMIN_FAIL  0x4E560002UL  /* an init admin command failed */
#define NVME_LOG_NOT_512     0x4E560003UL  /* namespace LBA size not 512 */
#define NVME_LOG_IO_TIMEOUT  0x4E560004UL  /* an I/O command timed out */
#define NVME_LOG_IO_ERROR    0x4E560005UL  /* an I/O command returned an error */
#define NVME_LOG_NO_NS       0x4E560006UL  /* no active namespace */
#define NVME_LOG_PAGE_SIZE   0x4E560007UL  /* controller cannot do 4 KiB pages */
#define NVME_LOG_BAR_HIGH    0x4E560008UL  /* 9x: BAR above 4 GiB, not mapped */
#define NVME_LOG_DMA_HIGH    0x4E560009UL  /* amd64: first data PRP above 4 GiB (once per boot; informational) */
#define NVME_LOG_BAD_PA      0x4E56000AUL  /* amd64: unusable data address from ScsiPort, command not sent */
/* a FLUSH failed: low 12 bits = (SCT << 8) | SC, FFFh = no completion in time */
#define NVME_LOG_FLUSH_BASE  0x4E561000UL

#pragma pack(push, 1)
typedef struct _NVME_SQE {
    ULONG Cdw0;          /* opcode 7:0, CID 31:16 */
    ULONG Nsid;
    ULONG Rsvd2;
    ULONG Rsvd3;
    ULONG MptrLo;
    ULONG MptrHi;
    ULONG Prp1Lo;
    ULONG Prp1Hi;
    ULONG Prp2Lo;
    ULONG Prp2Hi;
    ULONG Cdw10;
    ULONG Cdw11;
    ULONG Cdw12;
    ULONG Cdw13;
    ULONG Cdw14;
    ULONG Cdw15;
} NVME_SQE, *PNVME_SQE;

typedef struct _NVME_CQE {
    ULONG Dw0;
    ULONG Dw1;
    ULONG Dw2;           /* SQHD 15:0, SQID 31:16 */
    ULONG Dw3;           /* CID 15:0, P 16, status 31:17 */
} NVME_CQE, *PNVME_CQE;
#pragma pack(pop)

typedef struct _NVME_QUEUE {
    PNVME_SQE Sq;
    PNVME_CQE Cq;
    SCSI_PHYSICAL_ADDRESS SqPhys;
    SCSI_PHYSICAL_ADDRESS CqPhys;
    ULONG Depth;
    ULONG SqTail;
    ULONG CqHead;
    ULONG Phase;
    ULONG SqDoorbell;    /* register offsets */
    ULONG CqDoorbell;
} NVME_QUEUE, *PNVME_QUEUE;

typedef struct _HW_DEVICE_EXTENSION {
    PUCHAR Regs;                 /* mapped BAR0 */
    ULONG PciBus;
    ULONG PciSlot;
    ULONG PciId;                 /* vendor | device << 16 */
    ULONG CapLo, CapHi;
    ULONG Version;
    ULONG DoorbellStride;        /* bytes */
    ULONG ReadyTimeoutMs;
    ULONG MaxChunkBytes;         /* min(MDTS, NVME_MAX_TRANSFER) */
    BOOLEAN VolatileCache;
    BOOLEAN Dirty;               /* a WRITE since the last successful FLUSH */
    BOOLEAN ControllerUp;
    BOOLEAN NeedRestart;
    BOOLEAN NamespaceReady;
    ULONG Nsid;
    ULONG LbaShift;
    ULONG NsBlocksLo, NsBlocksHi;  /* NSZE */
    ULONG CommandId;
    PUCHAR Uncached;             /* 4 KiB aligned */
    SCSI_PHYSICAL_ADDRESS UncachedPhys;
    PULONG PrpList;
    SCSI_PHYSICAL_ADDRESS PrpListPhys;
    PUCHAR Ident;
    SCSI_PHYSICAL_ADDRESS IdentPhys;
    NVME_QUEUE Admin;
    NVME_QUEUE Io;
    UCHAR Serial[20];
    UCHAR Model[40];
    UCHAR Firmware[8];
    UCHAR SenseKey, Asc, Ascq;   /* last sense for REQUEST SENSE */
    ULONG Reads, Writes, Flushes, Errors, Timeouts;
    ULONG LastStatus;            /* last failing NVMe status (SCT << 8 | SC) */
    ULONG LastWaitUs;            /* NvmeWait: duration of the last command */
    ULONG ShutdownMs;            /* CC.SHN limit (RTD3E clamped) */
    ULONG FlushUsCarry;          /* Diag.TotalFlushMs: microseconds below 1 ms */
    USOSNVME_DIAG Diag;          /* IOCTL_SCSI_MINIPORT "USOSNVME" */
    PUSHORT Vga;
    ULONG InitStage;
    ULONG IoQid;                 /* NVME_IO_QID, or 1 if fewer queues */
    ULONG Srbs;                  /* 9x debug: completed SRBs */
    ULONG DbgNonRw;              /* 9x debug: non read/write SRBs shown */
#ifdef USOSNVME_NT31
    ULONG IoSrbs;                /* NT 3.1 /SOS I/O row: SRBs seen by HwStartIo */
    ULONG LastPrp1;              /* NT 3.1 /SOS I/O row: PRP1 of the last READ / WRITE */
#endif
#ifdef USOSNVME_PRPCHECK
    BOOLEAN DmaHighLogged;       /* NVME_LOG_DMA_HIGH written for this start */
    ULONG BadPa;                 /* data addresses refused (NvmeBuildPrps) */
#endif
#ifdef USOSNVME_W9X
    SCSI_PHYSICAL_ADDRESS Prp9x[NVME_PRP9X_MAX];  /* NvmeRwPrps9x */
    ULONG Prp9xCount;
#endif
} HW_DEVICE_EXTENSION, *PHW_DEVICE_EXTENSION;

#endif
