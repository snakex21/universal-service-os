/*
 * usosuds.h - USOS USB disk service (UDS) ABI, version 1 (DRAFT, stage 1).
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 * (The SeaBIOS side will carry its own LGPLv3 copy of the same layout.)
 *
 * docs/usb9x-hotswap-design-2026-10-19.md: SeaBIOS inside CSMWrap stays the
 * only xHCI owner. Its 32-bit code runs on CSMWrap's hidden helper core; the
 * helper serves channel 0 (the CSMPPrxy mailbox, call32 from V86) and, with
 * this service, channel 1 for one OS client (USOSUSB.MPD on Windows 9x):
 *
 *   F-segment: "CSMPPrxy" mailbox (48 bytes, 64-byte aligned from the UDS
 *   patch on) followed at +UDS_CH1_OFFSET by struct uds_channel, in the same
 *   cache line, so the helper's MONITOR/MWAIT on request_pending also wakes
 *   on the channel 1 doorbell.
 *
 * Protocol (one request at a time, the OS polls):
 *   1. OS: req_phys = physical address of its struct uds_req (contiguous,
 *      below 4 GiB, written once); fill the request, req.seq = ++n;
 *      store barrier; doorbell = n.
 *   2. helper: doorbell != done -> uds_req_check(), run, write the results;
 *      store barrier; done = doorbell.
 *   3. OS: done == n -> read the results.
 * Nothing in the request is trusted beyond uds_req_check(); the data buffer
 * is a physical range the OS owns (DMA target of the stick's bulk pipes).
 *
 * Plain C89 with fixed-size typedefs: built by SeaBIOS gcc, WDK 7.1 cl
 * (the miniport), OpenWatcom (USOSDBG) and zig cc (host tests).
 */
#ifndef USOSUDS_H
#define USOSUDS_H

#if defined(_MSC_VER) && _MSC_VER < 1600
typedef unsigned __int8 uds_u8;
typedef unsigned __int16 uds_u16;
typedef unsigned __int32 uds_u32;
#else
#include <stdint.h>
typedef uint8_t uds_u8;
typedef uint16_t uds_u16;
typedef uint32_t uds_u32;
#endif

#define UDS_VERSION       1
#define UDS_CH1_OFFSET    48            /* from the "CSMPPrxy" signature */
#define UDS_CH1_MAGIC     0x31534455UL  /* "UDS1" */
#define UDS_REQ_MAGIC     0x52534455UL  /* "UDSR" */
#define UDS_MAX_DEVS      8
#define UDS_MAX_LUN       15
#define UDS_MAX_DATA      65536UL       /* bytes per request */
#define UDS_MAX_CDB       16

/* channel 1: 16 bytes at +48 of the 64-byte aligned CSMPPrxy mailbox */
struct uds_channel {
    uds_u32 magic;              /* UDS_CH1_MAGIC, written by SeaBIOS at POST */
    uds_u32 req_phys;           /* OS: physical address of struct uds_req */
    volatile uds_u32 doorbell;  /* OS: seq of the posted request */
    volatile uds_u32 done;      /* helper: seq of the last completed request */
};

/* ops */
#define UDS_OP_ENUM    1   /* data (in): struct uds_dev_info[UDS_MAX_DEVS] */
#define UDS_OP_SCSI    2   /* CBW / data / CSW with cdb[], auto REQUEST SENSE */
#define UDS_OP_RESET   3   /* BOT reset recovery of dev */
#define UDS_OP_EJECT   4   /* SYNCHRONIZE CACHE, START STOP (LoEj), detach */
#define UDS_OP_STATUS  5   /* data (in): counters for the logs */

/* dir */
#define UDS_DIR_NONE   0
#define UDS_DIR_IN     1   /* device to host */
#define UDS_DIR_OUT    2   /* host to device */

/* status (helper -> OS) */
#define UDS_S_OK       0   /* CSW status 0 */
#define UDS_S_CHECK    1   /* CSW status 1, sense[] valid (sense_len) */
#define UDS_S_NODEV    2   /* no device in this table entry */
#define UDS_S_GONE     3   /* generation differs: the stick was removed / replaced */
#define UDS_S_TIMEOUT  4   /* transfer timed out (the helper tried one BOT reset) */
#define UDS_S_PHASE    5   /* CSW invalid / phase error after one BOT reset */
#define UDS_S_BADREQ   6   /* uds_req_check() refused the request */
#define UDS_S_OWNED    7   /* the drive has a BIOS number: INT 13h owns it */
#define UDS_S_PENDING  0xFFFFFFFFUL  /* written by the OS before the doorbell */

struct uds_req {
    uds_u32 magic;          /* UDS_REQ_MAGIC */
    uds_u16 version;        /* UDS_VERSION */
    uds_u16 size;           /* sizeof(struct uds_req) */
    uds_u32 seq;
    uds_u8  op, dev, lun, dir;
    uds_u32 data_phys;
    uds_u32 data_len;
    uds_u8  cdb_len, rsvd0[3];
    uds_u8  cdb[UDS_MAX_CDB];
    /* in: the generation the OS believes dev has; out: the current one */
    uds_u32 status;
    uds_u32 generation;
    uds_u32 residue;        /* CSW dCSWDataResidue, clamped to data_len */
    uds_u8  csw_status, sense_len, rsvd1[2];
    uds_u8  sense[20];
};

/* states of a device table entry */
#define UDS_DEV_EMPTY    0
#define UDS_DEV_PRESENT  1
#define UDS_DEV_GONE     2   /* removed; stage 1 keeps it gone until reboot */
#define UDS_DEV_EJECTED  3
#define UDS_DEV_FAILED   4   /* enumeration failed, see the USOSUDSK event ring */

struct uds_dev_info {
    uds_u8  state;
    uds_u8  bios_drive;     /* 0 = no BIOS number (offered to the OS) */
    uds_u8  luns;           /* max LUN + 1 */
    uds_u8  port;           /* xHCI root port, 1-based */
    uds_u16 vid, pid;
    uds_u32 generation;     /* +1 at every plug, never 0 for a present stick */
    uds_u32 block_size;
    uds_u32 last_lba_lo, last_lba_hi;
    char    vendor[8];
    char    product[16];
};

/* uds_req_check() result: UDS_S_OK or UDS_S_BADREQ, reason in *why */
#define UDS_WHY_OK        0
#define UDS_WHY_MAGIC     1
#define UDS_WHY_VERSION   2
#define UDS_WHY_SIZE      3
#define UDS_WHY_OP        4
#define UDS_WHY_DEV       5
#define UDS_WHY_LUN       6
#define UDS_WHY_CDB       7
#define UDS_WHY_DIR       8
#define UDS_WHY_LEN       9
#define UDS_WHY_ADDR      10

uds_u32 uds_req_check(const struct uds_req *r, uds_u32 *why);

/*
 * Miniport side: per-slot (SCSI target) state machine that turns the UDS
 * view of a stick into removable-media SCSI semantics for IOS:
 * absent -> NOT READY / MEDIUM NOT PRESENT, new generation -> one UNIT
 * ATTENTION / MEDIUM MAY HAVE CHANGED, and a few commands answered locally.
 */
struct uds_slot {
    uds_u8  dev;            /* device table index served by this slot, 0xFF none */
    uds_u8  present;        /* last known */
    uds_u8  ua_pending;     /* report UNIT ATTENTION before the next command */
    uds_u8  last_key, last_asc, last_ascq;   /* for a REQUEST SENSE from IOS */
    uds_u8  rsvd[2];
    uds_u32 generation;     /* the generation the OS volume belongs to */
};

/* what the miniport does with one SRB */
#define UDS_ACT_SEND      0   /* fill a uds_req (uds_slot_fill), post it */
#define UDS_ACT_LOCAL     1   /* answered here: SCSI status in *res, data from uds_local_inquiry */
#define UDS_ACT_CHECK     2   /* CHECK CONDITION with the sense in *res */
#define UDS_ACT_EJECT     3   /* post UDS_OP_EJECT */
#define UDS_ACT_GOOD      4   /* GOOD, no data, nothing sent */

struct uds_scsi_res {
    uds_u8 action;
    uds_u8 scsi_status;     /* 0 GOOD, 2 CHECK CONDITION */
    uds_u8 key, asc, ascq;
    uds_u8 reset;           /* the miniport should post UDS_OP_RESET next */
    uds_u8 rsvd[2];
};

void uds_slot_init(struct uds_slot *s);
/* ENUM result for the slot's device (or NULL when the table has none) */
void uds_slot_update(struct uds_slot *s, uds_u8 dev, const struct uds_dev_info *info);
void uds_slot_before(struct uds_slot *s, const uds_u8 *cdb, uds_u8 cdb_len, struct uds_scsi_res *res);
void uds_slot_fill(const struct uds_slot *s, struct uds_req *r, uds_u8 lun, const uds_u8 *cdb,
                   uds_u8 cdb_len, uds_u8 dir, uds_u32 data_phys, uds_u32 data_len);
void uds_slot_after(struct uds_slot *s, const struct uds_req *r, struct uds_scsi_res *res);
/* standard INQUIRY data (36 bytes) of an empty / any slot: removable direct access */
void uds_local_inquiry(uds_u8 *buf, uds_u32 len, uds_u8 slot);
/* fixed-format sense data (18 bytes) for a REQUEST SENSE IOS sends itself */
void uds_local_sense(const struct uds_slot *s, uds_u8 *buf, uds_u32 len);

#endif
