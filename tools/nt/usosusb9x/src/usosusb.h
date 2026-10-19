/*
 * usosusb - USOS USB disk service (UDS) SCSI miniport for Windows 95 OSR2 /
 * 98 / 98 SE / Me (USOSUSB.MPD under SCSIPORT.PDR / IOS), part of Universal
 * Service OS (USOS).
 *
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the Free
 * Software Foundation, either version 3 of the License, or (at your option)
 * any later version. This program is distributed WITHOUT ANY WARRANTY; see
 * the GNU General Public License (LICENSE in the repository root).
 *
 * Own implementation from the public SCSI SPC / SBC definitions, the public
 * DDK documentation of the SCSI port / miniport interface and the USOS UDS
 * ABI (src/platform/bios/win9x/usosuds.h). No Microsoft source code.
 *
 * USOSUSB_HOST: host simulation build (tools/tests/usb9x/test_usosusb9x.py):
 * a fake miniport.h and fake platform hooks replace the WDK headers, VMM
 * calls and inline assembly.
 */
#ifndef USOSUSB_H
#define USOSUSB_H

#ifdef USOSUSB_HOST
#include "fake_miniport.h"
#else
#include <miniport.h>
#include <scsi.h>
#endif
#include "usosuds.h"

#define USOSUSB_VERSION "1.1"
#define USOSUSB_MAJOR   1
#define USOSUSB_MINOR   1

#define USB_PAGE          4096UL
#define USB_BOUNCE_PAGES  16UL                       /* 64 KiB = UDS_MAX_DATA */
#define USB_ENUM_OFFSET   256UL                      /* in the control page */
#define USB_ENUM_BYTES    (UDS_MAX_DEVS * sizeof(struct uds_dev_info))
/* control page + bounce pages + one page of alignment slack */
#define USB_UNCACHED_SIZE ((1UL + USB_BOUNCE_PAGES + 1UL) * USB_PAGE)

#define USB_INITIATOR_ID  7
#define USB_SPIN_US       2000UL     /* short spin in HwStartIo */
/* until SCSIPORT.PDR has called the timer back once, HwStartIo waits for
   the whole request (bounded by the watchdog), as usosnvme's W9X build */
#define USB_SYNC_SPIN_US  ((USB_WATCHDOG_MS + 1000UL) * 1000UL)
#define USB_SPIN_STEP_US  50UL
#define USB_TIMER_US      1000UL     /* RequestTimerCall interval */
#define USB_WATCHDOG_MS   15000UL    /* hard limit per posted request */
#define USB_INIT_ENUM_MS  3000UL     /* HwInitialize waits this long for the first ENUM, then it is stale */
#define USB_TUR_ENUM_MS   1000UL     /* at most one ENUM per second from TEST UNIT READY / an empty slot */
#define USB_TUR_ENUM_EVERY 8UL       /* no TSC: one ENUM per this many TEST UNIT READY */

/* what HwStartIo / the timer do next while no request is posted */
#define STEP_IDLE         0
#define STEP_BEGIN        1   /* EXECUTE_SCSI: pending reset / ENUM first */
#define STEP_SLOT         2   /* EXECUTE_SCSI: uds_slot_before and act */
#define STEP_FINISH       3   /* after a RESET that followed the SCSI request */
#define STEP_FLUSH        4   /* SRB flush / shutdown: SYNCHRONIZE CACHE per slot */
#define STEP_RESETS       5   /* SRB reset bus / device: UDS RESET per slot */

typedef struct _HW_DEVICE_EXTENSION {
    struct uds_channel *Ch;         /* linear, in the F-segment mapping */
    ULONG ChPhys;
    PUCHAR Block;                   /* page-aligned control page */
    ULONG BlockPhys;
    struct uds_req *Req;            /* Block + 0 */
    struct uds_mp_status *Mp;       /* Block + UDS_MP_STATUS_OFFSET */
    struct uds_mp_ring *Ring;       /* Block + UDS_MP_RING_OFFSET (1.1) */
    struct uds_dev_info *Info;      /* Block + USB_ENUM_OFFSET */
    ULONG InfoPhys;
    PUCHAR Bounce;                  /* Block + USB_PAGE */
    ULONG BouncePhys;
    ULONG BounceLen;                /* contiguous bytes (64 KiB unless the allocation was split) */
    ULONG Slots;

    /* channel */
    ULONG Seq;
    BOOLEAN Posted;                 /* a request is out, Seq not yet in Ch->done */
    BOOLEAN Stale;                  /* the watchdog gave up on StaleSeq: the block stays the helper's */
    UCHAR PostOp;                   /* UDS_OP_* of the posted request */
    UCHAR PostSlot;                 /* slot of a posted SCSI / RESET / EJECT, 0xFF none */
    ULONG StaleSeq;
    ULONGLONG Deadline;

    /* slots */
    struct uds_slot Slot[UDS_MP_SLOTS];
    UCHAR ResetNeeded[UDS_MP_SLOTS];
    UCHAR SavedSense[3];
    BOOLEAN NeedEnum;
    ULONGLONG NextTurEnum;
    ULONG TurCount;

    /* the one SRB in progress */
    PSCSI_REQUEST_BLOCK Srb;
    PSCSI_REQUEST_BLOCK DoneSrb;    /* set by UsbFinish, notified by the caller */
    ULONG Step;
    ULONG Iter;
    UCHAR Dir;
    ULONG DataLen;
    struct uds_scsi_res Res;

    /* clock: TSC ticks, or microseconds counted while waiting */
    BOOLEAN Tsc;
    ULONG TicksPerMs;
    ULONGLONG Soft;
    BOOLEAN TimerArmed;
    BOOLEAN TimerSeen;              /* SCSIPORT.PDR called UsbTimer at least once */
    BOOLEAN InPump;                 /* HwStartIo is running the state machine */
    ULONG DbgLines;
    ULONG CrcTab[256];              /* CRC-32 of the request ring (1.1) */
} HW_DEVICE_EXTENSION, *PHW_DEVICE_EXTENSION;

#endif
