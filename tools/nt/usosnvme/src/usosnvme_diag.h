/*
 * usosnvme_diag.h - diagnostics block of the USOS NVMe miniport, read with
 * IOCTL_SCSI_MINIPORT (SRB_FUNCTION_IO_CONTROL, signature "USOSNVME").
 * Shared by the driver (tools/nt/usosnvme/src/usosnvme.c) and the WinPE
 * helper (tools/windows_nvme_modern.c). Own code, GPL-3.0-or-later.
 *
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 *
 * Every field is a ULONG (no packing questions between the WDK 7.1 driver
 * build and the zig / mingw helper build). Times are microseconds measured
 * by the driver's polling loop (see NvmeWait in usosnvme.c).
 * NVMe status values: 0 = success, 0xFFFFFFFF = no completion within the
 * timeout, else (SCT << 8) | SC from the completion entry.
 */
#ifndef USOSNVME_DIAG_H
#define USOSNVME_DIAG_H

#define USOSNVME_DIAG_SIGNATURE "USOSNVME"     /* SRB_IO_CONTROL.Signature, 8 bytes */
#define USOSNVME_DIAG_CODE      0x55534401UL   /* SRB_IO_CONTROL.ControlCode */
#define USOSNVME_DIAG_VERSION   1UL
#define USOSNVME_DIAG_RING      8

/* USOSNVME_FLUSH_REC.Source, low 16 bits: who asked for the flush */
#define USOSNVME_FLUSH_SYNC_CACHE 1UL          /* SCSI SYNCHRONIZE CACHE (10/16) */
#define USOSNVME_FLUSH_SRB_FLUSH  2UL          /* SRB_FUNCTION_FLUSH */
#define USOSNVME_FLUSH_SHUTDOWN   3UL          /* SRB_FUNCTION_SHUTDOWN / 9x exit */
/* high 16 bits: what was done */
#define USOSNVME_FLUSH_SENT       0x00000000UL /* an NVMe FLUSH went to the controller */
#define USOSNVME_FLUSH_CLEAN      0x00010000UL /* not sent: no WRITE since the last good flush */
#define USOSNVME_FLUSH_NO_VWC     0x00020000UL /* not sent: Identify VWC = 0 (nothing to flush) */
#define USOSNVME_FLUSH_ALL_NS     0x00040000UL /* resent with NSID FFFFFFFFh after an NSID refusal */

typedef struct _USOSNVME_SRB_IO_CONTROL {    /* = SRB_IO_CONTROL (ntddscsi.h) */
    ULONG HeaderLength;
    UCHAR Signature[8];
    ULONG Timeout;
    ULONG ControlCode;
    ULONG ReturnCode;
    ULONG Length;
} USOSNVME_SRB_IO_CONTROL, *PUSOSNVME_SRB_IO_CONTROL;

typedef struct _USOSNVME_FLUSH_REC {
    ULONG Seq;            /* 1, 2, ... (0 = unused slot) */
    ULONG Source;         /* USOSNVME_FLUSH_* */
    ULONG Us;             /* duration of the NVMe command(s) */
    ULONG Status;         /* NVMe status */
} USOSNVME_FLUSH_REC;

typedef struct _USOSNVME_DIAG {
    ULONG Version;        /* USOSNVME_DIAG_VERSION */
    ULONG Size;           /* sizeof(USOSNVME_DIAG) */
    ULONG PciId;          /* vendor | device << 16 */
    ULONG NvmeVersion;    /* VS register */
    ULONG Nsid;
    ULONG Vwc;            /* Identify Controller byte 525 (bit 0 = volatile write cache) */
    ULONG Rtd3eUs;        /* Identify Controller RTD3E */
    ULONG State;          /* bit 0 ControllerUp, 1 NamespaceReady, 2 NeedRestart, 3 Dirty */
    ULONG Starts;         /* controller (re)initialisations */
    ULONG Reads, Writes;  /* NVMe READ / WRITE commands completed */
    ULONG Errors;         /* failed SCSI requests */
    ULONG Timeouts;       /* commands with no completion within the timeout */
    ULONG LastIoStatus;   /* last failing status of any command */
    ULONG LastFailCsts;   /* CSTS read right after the last failure */
    ULONG LastCqeDw3;     /* raw DW3 of the last completion (incl. DNR / More / CRD) */
    ULONG MaxIoUs;        /* slowest READ / WRITE */
    ULONG FlushRequests;  /* flush requests from Windows (all sources) */
    ULONG FlushSent;      /* NVMe FLUSH commands submitted */
    ULONG FlushSkipped;   /* answered without a command (clean / no VWC) */
    ULONG FlushOk;
    ULONG FlushErrors;    /* error status or timeout */
    ULONG FlushTimeouts;
    ULONG LastFlushUs;
    ULONG MaxFlushUs;
    ULONG TotalFlushMs;
    ULONG LastFlushStatus;
    ULONG Shutdowns;      /* CC.SHN normal shutdown notifications */
    ULONG LastShutdownUs; /* until CSTS.SHST = complete (or the limit) */
    ULONG LastShutdownCsts;
    ULONG FlushSeq;
    USOSNVME_FLUSH_REC Ring[USOSNVME_DIAG_RING];   /* last flushes, slot = Seq % 8 */
} USOSNVME_DIAG, *PUSOSNVME_DIAG;

#endif
