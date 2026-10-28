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

#define UDS_VERSION       1             /* channel magic "UDS1" = this version */
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
#define UDS_S_HWFAIL   8   /* xHCI not usable (registers read all ones, halted, host system error) */
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
#define UDS_DEV_GONE     2   /* removed; from usos17 the entry is re-used for a new stick (new generation) */
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

/*
 * Diagnostics record "USOS" "UDSK" (CSMWrap 3.1.2-usos16 patch 0021): SeaBIOS
 * low memory (VARLOW), 16-byte aligned, found by scanning the first MiB for
 * the two signature dwords; also returned by UDS_OP_STATUS. Written by the
 * helper core only, never read back by the BIOS. Version 1, 768 bytes
 * (usos16); version 2 (usos17, patch 0022, hot-swap) appends the port watch
 * block at +768: UDS_DIAG_V2_SIZE bytes.
 */
#define UDS_DIAG_SIG0     0x534F5355UL  /* "USOS" */
#define UDS_DIAG_SIG1     0x4B534455UL  /* "UDSK" */
#define UDS_DIAG_VERSION  2
#define UDS_DIAG_V1_SIZE  768
#define UDS_DIAG_V2_SIZE  984
#define UDS_DIAG_DISKS    8
#define UDS_DIAG_EVENTS   16

struct uds_diag_dev {           /* 64 bytes, one per device table entry */
    uds_u8  state, bios_drive, luns, port;     /* as struct uds_dev_info */
    uds_u16 vid, pid;
    uds_u8  slotid, speed, last_csw, last_key; /* speed: SeaBIOS USB_*SPEED */
    uds_u8  last_asc, last_ascq, last_op, last_status;   /* last_op: CDB[0], last_status: UDS_S_* */
    uds_u32 generation;
    uds_u32 block_size;
    uds_u32 last_lba_lo, last_lba_hi;
    uds_u32 requests;           /* SCSI requests served */
    uds_u32 checks;             /* CSW status 1 */
    uds_u32 timeouts;
    uds_u32 resets;             /* BOT reset recoveries */
    uds_u32 gone;               /* requests ended with UDS_S_GONE */
    uds_u32 refused;            /* UDS_S_OWNED / UDS_S_HWFAIL / UDS_S_BADREQ for this entry */
    uds_u32 kib_in, kib_out;    /* data KiB (usos16: rounded down per request; usos17: exact, the remainder carried) */
};

struct uds_diag_disk {          /* 12 bytes: the BIOS hard disks / CD-ROMs SeaBIOS mapped */
    uds_u8  bios;               /* 80h.. hard disk, E0h.. CD-ROM, 0 = unused entry */
    uds_u8  dtype;              /* SeaBIOS DTYPE_* (70h/71h USB MSC, 91h NVMe, 50h AHCI, 20h ATA, ...) */
    uds_u8  uds;                /* device table index + 1 when this is a UDS stick, else 0 */
    uds_u8  rsvd;
    uds_u32 sectors_lo, sectors_hi;
};

/* event codes */
#define UDS_EV_PRESENT   1   /* registered at POST (result: luns) */
#define UDS_EV_GONE      2   /* root port lost CCS (result: the op) */
#define UDS_EV_RESET     3   /* BOT reset recovery (result: 0 ok, 1 failed) */
#define UDS_EV_EJECT     4
#define UDS_EV_BADREQ    5   /* result: UDS_WHY_* */
#define UDS_EV_HWFAIL    6   /* result: 1 all ones, 2 halted / host system error */
#define UDS_EV_TIMEOUT   7   /* result: phase 1 CBW, 2 data, 3 CSW */
#define UDS_EV_PHASE     8   /* result: phase, 4 CSW signature/tag, 5 CSW status 2 */
#define UDS_EV_REGFAIL   9   /* registration: result 1 table full, 2 INQUIRY failed */
#define UDS_EV_STALL    10   /* result: phase */
/* version 2 (patch 0022); port events: dev = F0h | controller index, port 1-based */
#define UDS_EV_ATTACH    11  /* runtime bring-up done (result: LUNs) */
#define UDS_EV_ATTFAIL   12  /* bring-up failed (result: UDS_AF_*) */
#define UDS_EV_CONNECT   13  /* connect seen by the port watch (result: PORTSC.PLS) */
#define UDS_EV_DETACH    14  /* unplug seen by the port watch (result: 1 = replugged at once) */
#define UDS_EV_UNCLAIMED 15  /* connected when the watch armed, no device slot (result: PLS) */
#define UDS_EV_MEDIA     16  /* media check (result: UDS_FS_*) */
#define UDS_EV_ARM       17  /* the port watch armed (result: watched controllers) */
#define UDS_EV_HIDGONE   18  /* usos18: root USB keyboard/mouse unplugged (result: 1 = replugged at once) */
#define UDS_EV_HIDBACK   19  /* usos18: root USB keyboard/mouse re-attached (result: retries) */

/* bring-up failure reasons (UDS_EV_ATTFAIL, last_fail) */
#define UDS_AF_RESET    1    /* port reset failed / disconnected */
#define UDS_AF_SLOT     2    /* Enable Slot */
#define UDS_AF_ADDRESS  3    /* Address Device */
#define UDS_AF_DEVDESC  4    /* device descriptor */
#define UDS_AF_CONFIG   5    /* configuration descriptor */
#define UDS_AF_NOTMSC   6    /* no bulk-only mass storage interface (keyboard, hub, UAS only) */
#define UDS_AF_SETCFG   7    /* SET_CONFIGURATION */
#define UDS_AF_EPS      8    /* Configure Endpoint */
#define UDS_AF_POOL     9    /* both runtime pool chunks in use */
#define UDS_AF_TABLE   10    /* device table full */
#define UDS_AF_MPS     11    /* EP0 packet size */
#define UDS_AF_HID     12    /* usos18: keyboard/mouse re-attach bring-up failed */

/* media check (struct uds_diag_media.fs) */
#define UDS_FS_UNREAD   0
#define UDS_FS_READFAIL 1
#define UDS_FS_NOSIG    2    /* sector 0 without 55AAh: blank / not a PC medium */
#define UDS_FS_FAT12    3
#define UDS_FS_FAT16    4
#define UDS_FS_FAT32    5
#define UDS_FS_NTFS     6
#define UDS_FS_EXFAT    7
#define UDS_FS_GPT      8    /* protective MBR (GPT) */
#define UDS_FS_OTHER    9    /* MBR, volume unknown or not read */
#define UDS_MF_SIG      1    /* sector 0 ends with 55AAh */
#define UDS_MF_VBR      2    /* a boot sector was read and checked */
#define UDS_DIAG_CTLS   4

struct uds_diag_ctl {           /* 16 bytes per watched xHCI controller */
    uds_u32 ports;
    uds_u32 ccs_post;           /* CCS of root ports 1-32 after POST enumeration */
    uds_u32 busy_arm;           /* ports with a device slot when the watch armed */
    uds_u32 ccs_now;            /* CCS at the last watch pass */
};

struct uds_diag_media {         /* 16 bytes per device table entry */
    uds_u8  fs;                 /* UDS_FS_* */
    uds_u8  types[4];           /* MBR partition types, slots 1-4 */
    uds_u8  flags;              /* UDS_MF_* */
    uds_u8  ctl;                /* watched controller index, FFh none */
    uds_u8  attach;             /* 0 POST, 1 port watch (runtime) */
    uds_u32 part_lba;           /* boot sector checked (0 = sector 0) */
    uds_u32 hash0;              /* FNV-1a of the first 512 bytes of sector 0 */
};

struct uds_diag_event {         /* 8 bytes */
    uds_u32 ms;                 /* SeaBIOS timer in ms (wraps; relative order only) */
    uds_u8  dev, port, event, result;
};

struct uds_diag {
    uds_u32 sig[2];             /* UDS_DIAG_SIG0, UDS_DIAG_SIG1 */
    uds_u8  version, devs;      /* devs: table entries in use */
    uds_u8  next_event, disks;  /* next ring slot, BIOS disk entries filled */
    uds_u32 services;           /* channel 1 doorbells served */
    uds_u32 badreq;             /* refused by the request check (or a bad req_phys) */
    uds_u32 last_why;           /* UDS_WHY_* of the last refusal */
    uds_u32 channel;            /* linear address of struct uds_channel */
    uds_u32 events;             /* events written (the ring keeps the last 16) */
    struct uds_diag_dev dev[UDS_MAX_DEVS];         /* +32 */
    struct uds_diag_disk disk[UDS_DIAG_DISKS];     /* +544 */
    struct uds_diag_event ev[UDS_DIAG_EVENTS];     /* +640 */
    /* version 2 (patch 0022), +768 */
    uds_u32 watch_passes, attaches, detaches, attach_fails;
    uds_u8  ctls, armed, pool_used, last_fail;     /* last_fail: UDS_AF_* */
    uds_u32 pool;               /* physical address of the runtime pool, 0 = none (no hot-swap) */
    struct uds_diag_ctl ctl[UDS_DIAG_CTLS];        /* +792 */
    struct uds_diag_media media[UDS_MAX_DEVS];     /* +856 */
};                                                  /* 984 */

/*
 * USOSUSB.MPD status page: right after the miniport's request block, at
 * channel.req_phys + UDS_MP_STATUS_OFFSET (same physically contiguous
 * uncached block), so USOSDBG finds it through the channel. Written by the
 * miniport only.
 */
#define UDS_MP_STATUS_OFFSET  128
#define UDS_MP_SIG0     0x534F5355UL  /* "USOS" */
#define UDS_MP_SIG1     0x53504D55UL  /* "UMPS" */
#define UDS_MP_VERSION  2             /* 2 (USOSUSB 1.1): the request ring below */
#define UDS_MP_SLOTS    4

struct uds_mp_slot {            /* 16 bytes */
    uds_u8  dev, present, ua_pending, last_op;   /* last_op: CDB[0] of the last SRB */
    uds_u8  last_srb_status, last_key, last_asc, last_ascq;
    uds_u32 generation;
    uds_u32 srbs;
};

struct uds_mp_status {          /* 104 bytes (1.0: 100) */
    uds_u32 sig[2];             /* UDS_MP_SIG0, UDS_MP_SIG1 */
    uds_u8  version, slots, mp_major, mp_minor;
    uds_u32 srbs;               /* all SRBs seen */
    uds_u32 posted;             /* requests posted to the channel */
    uds_u32 polled;             /* completions found by the timer poll (not the short spin) */
    uds_u32 errors;             /* SRBs completed with an error status (1.1: not NOT READY / 3Ah of an empty slot) */
    uds_u32 enums;              /* UDS_OP_ENUM requests */
    uds_u32 last_status;        /* UDS_S_* of the last request */
    struct uds_mp_slot slot[UDS_MP_SLOTS];       /* +36 */
    uds_u32 notready;           /* 1.1: SRBs answered NOT READY / 3Ah (empty slot polls), +100 */
};

/*
 * USOSUSB.MPD request ring (status page version 2): the last UDS_MP_RING
 * SCSI requests sent to a stick, at channel.req_phys + UDS_MP_RING_OFFSET.
 * crc: CRC-32 (IEEE 802.3, as zip) of the data the stick returned (IN) or
 * was sent (OUT), 0 without data.
 */
#define UDS_MP_RING_OFFSET  1024
#define UDS_MP_RSIG1    0x474E5255UL  /* "URNG" (sig[0] = "USOS") */
#define UDS_MP_RING     32

struct uds_mp_rent {            /* 16 bytes */
    uds_u8  op, slot, srb_status, uds_status;
    uds_u32 lba;                /* READ / WRITE 6/10/12/16 (low 32 bits), else 0 */
    uds_u32 bytes;              /* data moved */
    uds_u32 crc;
};

struct uds_mp_ring {            /* 16 + 512 bytes */
    uds_u32 sig[2];             /* UDS_MP_SIG0, UDS_MP_RSIG1 */
    uds_u32 count;              /* entries written */
    uds_u32 next;               /* next slot */
    struct uds_mp_rent ent[UDS_MP_RING];
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
