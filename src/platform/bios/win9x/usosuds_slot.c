/*
 * usosuds_slot.c - USOS USB disk service (UDS): request validation (helper
 * side) and the removable-slot state machine (USOSUSB.MPD side), DRAFT for
 * stage 1 of docs/usb9x-hotswap-design-2026-10-19.md.
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 *
 * Own code from the public SCSI SPC / SBC command and sense definitions and
 * the USB MSC Bulk-Only Transport 1.0 CSW semantics. No C runtime: only
 * byte loops, so it builds for SeaBIOS, the 9x miniport and the host test.
 *
 * Slot model: one SCSI target per slot, always a removable direct-access
 * device with the same INQUIRY identity ("USOS USB disk slot n"), so IOS
 * keeps one DCB and one drive letter per slot whatever stick is plugged in.
 *   no stick                 -> CHECK CONDITION, NOT READY / 3Ah (medium not present)
 *   another stick (gen.)     -> one CHECK CONDITION, UNIT ATTENTION / 28h (medium may have changed)
 *   stick removed mid-request-> the request fails, NOT READY / 3Ah; never retried onto a new stick
 */
#include "usosuds.h"

/* SCSI operation codes used here */
#define SCSIOP_TEST_UNIT_READY   0x00
#define SCSIOP_REQUEST_SENSE     0x03
#define SCSIOP_INQUIRY           0x12
#define SCSIOP_START_STOP_UNIT   0x1B
#define SCSIOP_MEDIUM_REMOVAL    0x1E
#define SCSIOP_SYNCHRONIZE_CACHE 0x35

/* sense keys */
#define SK_NOT_READY       0x02
#define SK_HARDWARE_ERROR  0x04
#define SK_ILLEGAL_REQUEST 0x05
#define SK_UNIT_ATTENTION  0x06
#define SK_ABORTED_COMMAND 0x0B

#define SCSISTAT_GOOD  0x00
#define SCSISTAT_CHECK 0x02

static void zero(void *p, uds_u32 n)
{
    volatile uds_u8 *b = (volatile uds_u8 *)p;
    while (n--) *b++ = 0;
}

static void copy(void *d, const void *s, uds_u32 n)
{
    volatile uds_u8 *a = (volatile uds_u8 *)d;
    const uds_u8 *b = (const uds_u8 *)s;
    while (n--) *a++ = *b++;
}

uds_u32 uds_req_check(const struct uds_req *r, uds_u32 *why)
{
    uds_u32 w = UDS_WHY_OK;
    if (r->magic != UDS_REQ_MAGIC) w = UDS_WHY_MAGIC;
    else if (r->version != UDS_VERSION) w = UDS_WHY_VERSION;
    else if (r->size != sizeof(struct uds_req)) w = UDS_WHY_SIZE;
    else if (r->op < UDS_OP_ENUM || r->op > UDS_OP_STATUS) w = UDS_WHY_OP;
    else if (r->op != UDS_OP_ENUM && r->op != UDS_OP_STATUS && r->dev >= UDS_MAX_DEVS) w = UDS_WHY_DEV;
    else if (r->op == UDS_OP_SCSI && r->lun > UDS_MAX_LUN) w = UDS_WHY_LUN;
    else if (r->op == UDS_OP_SCSI && (r->cdb_len < 6 || r->cdb_len > UDS_MAX_CDB)) w = UDS_WHY_CDB;
    else if (r->dir > UDS_DIR_OUT) w = UDS_WHY_DIR;
    else if ((r->op == UDS_OP_ENUM || r->op == UDS_OP_STATUS) && r->dir != UDS_DIR_IN) w = UDS_WHY_DIR;
    else if ((r->op == UDS_OP_RESET || r->op == UDS_OP_EJECT) && r->dir != UDS_DIR_NONE) w = UDS_WHY_DIR;
    else if ((r->dir == UDS_DIR_NONE) != (r->data_len == 0)) w = UDS_WHY_LEN;
    else if (r->data_len > UDS_MAX_DATA) w = UDS_WHY_LEN;
    else if (r->op == UDS_OP_ENUM && r->data_len < UDS_MAX_DEVS * sizeof(struct uds_dev_info)) w = UDS_WHY_LEN;
    else if (r->data_len && (r->data_phys == 0 || r->data_phys > 0xFFFFFFFFUL - (r->data_len - 1)))
        w = UDS_WHY_ADDR;
    else if (r->data_len && r->data_phys < 0x100000UL && r->data_phys + r->data_len > 0xA0000UL)
        w = UDS_WHY_ADDR;   /* never DMA into VGA / option ROM / BIOS (A0000h-FFFFFh) */
    if (why) *why = w;
    return w == UDS_WHY_OK ? UDS_S_OK : UDS_S_BADREQ;
}

void uds_slot_init(struct uds_slot *s)
{
    zero(s, sizeof(*s));
    s->dev = 0xFF;
}

void uds_slot_update(struct uds_slot *s, uds_u8 dev, const struct uds_dev_info *info)
{
    /* only a present stick without a BIOS number is ours (no double mount with INT 13h) */
    if (!info || info->state != UDS_DEV_PRESENT || info->bios_drive != 0 || info->generation == 0) {
        if (s->dev == dev || !info) s->present = 0;
        return;
    }
    if (s->present && s->dev == dev && s->generation == info->generation) return;
    /* a stick IOS has not seen in this slot yet: the cached volume is stale.
       The first update before any command needs no UNIT ATTENTION. */
    if (s->rsvd[0]) s->ua_pending = 1;
    s->dev = dev;
    s->present = 1;
    s->generation = info->generation;
}

static void check(struct uds_slot *s, struct uds_scsi_res *res, uds_u8 key, uds_u8 asc, uds_u8 ascq)
{
    res->action = UDS_ACT_CHECK;
    res->scsi_status = SCSISTAT_CHECK;
    res->key = key; res->asc = asc; res->ascq = ascq;
    s->last_key = key; s->last_asc = asc; s->last_ascq = ascq;
}

static void good(struct uds_slot *s, struct uds_scsi_res *res, uds_u8 action)
{
    res->action = action;
    res->scsi_status = SCSISTAT_GOOD;
    res->key = res->asc = res->ascq = 0;
    if (action != UDS_ACT_LOCAL) s->last_key = s->last_asc = s->last_ascq = 0;
}

void uds_slot_before(struct uds_slot *s, const uds_u8 *cdb, uds_u8 cdb_len, struct uds_scsi_res *res)
{
    uds_u8 op = cdb_len ? cdb[0] : 0xFF;
    zero(res, sizeof(*res));
    s->rsvd[0] = 1;   /* commands seen: later stick changes report UNIT ATTENTION */
    if (cdb_len < 6) { check(s, res, SK_ILLEGAL_REQUEST, 0x20, 0x00); return; }
    switch (op) {
    case SCSIOP_INQUIRY:        /* fixed slot identity, also without a stick */
        good(s, res, UDS_ACT_LOCAL);
        return;
    case SCSIOP_REQUEST_SENSE:  /* the last sense of this slot (uds_local_sense) */
        good(s, res, UDS_ACT_LOCAL);
        return;
    case SCSIOP_MEDIUM_REMOVAL: /* a stick cannot be locked; never refuse */
        good(s, res, UDS_ACT_GOOD);
        return;
    case SCSIOP_START_STOP_UNIT:
        if ((cdb[4] & 0x03) == 0x02 && s->present) { good(s, res, UDS_ACT_EJECT); return; }
        good(s, res, UDS_ACT_GOOD);
        return;
    case SCSIOP_SYNCHRONIZE_CACHE:  /* no stick: nothing to flush (shutdown) */
        if (!s->present) { good(s, res, UDS_ACT_GOOD); return; }
        break;
    default:
        break;
    }
    if (!s->present) { check(s, res, SK_NOT_READY, 0x3A, 0x00); return; }
    if (s->ua_pending) {
        s->ua_pending = 0;
        check(s, res, SK_UNIT_ATTENTION, 0x28, 0x00);
        return;
    }
    /* a new command clears the sense of the previous one (SPC) */
    s->last_key = s->last_asc = s->last_ascq = 0;
    res->action = UDS_ACT_SEND;
}

void uds_slot_fill(const struct uds_slot *s, struct uds_req *r, uds_u8 lun, const uds_u8 *cdb,
                   uds_u8 cdb_len, uds_u8 dir, uds_u32 data_phys, uds_u32 data_len)
{
    uds_u32 seq = r->seq;
    zero(r, sizeof(*r));
    r->magic = UDS_REQ_MAGIC;
    r->version = UDS_VERSION;
    r->size = sizeof(struct uds_req);
    r->seq = seq;
    r->op = UDS_OP_SCSI;
    r->dev = s->dev;
    r->lun = lun;
    r->dir = data_len ? dir : UDS_DIR_NONE;
    r->data_phys = data_len ? data_phys : 0;
    r->data_len = data_len;
    if (cdb_len > UDS_MAX_CDB) cdb_len = UDS_MAX_CDB;
    r->cdb_len = cdb_len;
    copy(r->cdb, cdb, cdb_len);
    r->status = UDS_S_PENDING;
    r->generation = s->generation;
}

void uds_slot_after(struct uds_slot *s, const struct uds_req *r, struct uds_scsi_res *res)
{
    zero(res, sizeof(*res));
    switch (r->status) {
    case UDS_S_OK:
        good(s, res, UDS_ACT_SEND);
        return;
    case UDS_S_CHECK:
        if (r->sense_len >= 14 && (r->sense[0] & 0x7E) == 0x70) {
            uds_u8 key = r->sense[2] & 0x0F;
            /* sticks without a cache refuse SYNCHRONIZE CACHE: nothing to flush */
            if (r->cdb[0] == SCSIOP_SYNCHRONIZE_CACHE && key == SK_ILLEGAL_REQUEST) {
                good(s, res, UDS_ACT_SEND);
                return;
            }
            check(s, res, key, r->sense[12], r->sense[13]);
        } else {
            check(s, res, SK_HARDWARE_ERROR, 0x44, 0x00);   /* no usable sense */
        }
        res->action = UDS_ACT_SEND;
        return;
    case UDS_S_NODEV:
    case UDS_S_GONE:
    case UDS_S_OWNED:
        /* the stick this volume was on is gone: fail, never retry onto another one */
        s->present = 0;
        check(s, res, SK_NOT_READY, 0x3A, 0x00);
        res->action = UDS_ACT_SEND;
        return;
    case UDS_S_TIMEOUT:
        check(s, res, SK_ABORTED_COMMAND, 0x00, 0x00);
        res->reset = 1;
        res->action = UDS_ACT_SEND;
        return;
    case UDS_S_PHASE:
        check(s, res, SK_ABORTED_COMMAND, 0x4B, 0x00);   /* data phase error */
        res->reset = 1;
        res->action = UDS_ACT_SEND;
        return;
    case UDS_S_BADREQ:
        check(s, res, SK_ILLEGAL_REQUEST, 0x24, 0x00);   /* invalid field in CDB */
        res->action = UDS_ACT_SEND;
        return;
    default:
        check(s, res, SK_HARDWARE_ERROR, 0x44, 0x00);    /* internal target failure */
        res->action = UDS_ACT_SEND;
        return;
    }
}

void uds_local_inquiry(uds_u8 *buf, uds_u32 len, uds_u8 slot)
{
    static const char id[29] = "USOS    USB disk slot 0 0001";   /* 28 bytes used */
    uds_u8 d[36];
    zero(d, sizeof(d));
    d[0] = 0x00;            /* direct-access block device */
    d[1] = 0x80;            /* RMB: removable medium */
    d[2] = 0x02;            /* SCSI-2, what the 9x DiskTSD expects */
    d[3] = 0x02;            /* response data format */
    d[4] = 31;              /* additional length */
    copy(d + 8, id, 28);
    d[8 + 22] = (uds_u8)('0' + (slot % 10));
    copy(buf, d, len < sizeof(d) ? len : (uds_u32)sizeof(d));
}

void uds_local_sense(const struct uds_slot *s, uds_u8 *buf, uds_u32 len)
{
    uds_u8 d[18];
    zero(d, sizeof(d));
    d[0] = 0x70;            /* current error, fixed format */
    d[2] = s->last_key;
    d[7] = 10;              /* additional sense length */
    d[12] = s->last_asc;
    d[13] = s->last_ascq;
    if (!s->present && !s->last_key) { d[2] = SK_NOT_READY; d[12] = 0x3A; }
    copy(buf, d, len < sizeof(d) ? len : (uds_u32)sizeof(d));
}
