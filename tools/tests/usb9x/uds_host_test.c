/* Host test of src/platform/bios/win9x/usosuds_slot.c (UDS ABI v1 draft):
 * layout, request validation and the removable-slot state machine.
 * Built by test_usosuds.py with zig cc -fsanitize=undefined. */
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include "usosuds.h"

static int fails;
#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); fails++; } } while (0)

static const uds_u8 READ10[10] = { 0x28, 0, 0, 0, 0, 0, 0, 0, 8, 0 };
static const uds_u8 TUR[6] = { 0x00, 0, 0, 0, 0, 0 };
static const uds_u8 INQ[6] = { 0x12, 0, 0, 0, 36, 0 };
static const uds_u8 SYNC10[10] = { 0x35, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
static const uds_u8 EJECT[6] = { 0x1B, 0, 0, 0, 0x02, 0 };
static const uds_u8 LOCK[6] = { 0x1E, 0, 0, 0, 0x01, 0 };

static struct uds_req valid_read(void)
{
    struct uds_req r;
    memset(&r, 0, sizeof(r));
    r.magic = UDS_REQ_MAGIC; r.version = UDS_VERSION; r.size = sizeof(r);
    r.op = UDS_OP_SCSI; r.dev = 0; r.lun = 0; r.dir = UDS_DIR_IN;
    r.data_phys = 0x01000000UL; r.data_len = 4096;
    r.cdb_len = 10; memcpy(r.cdb, READ10, 10);
    return r;
}

static uds_u32 why_of(struct uds_req r)
{
    uds_u32 why = 99;
    uds_u32 st = uds_req_check(&r, &why);
    CHECK((st == UDS_S_OK) == (why == UDS_WHY_OK));
    return why;
}

static struct uds_dev_info dev(uds_u8 state, uds_u8 bios, uds_u32 gen)
{
    struct uds_dev_info d;
    memset(&d, 0, sizeof(d));
    d.state = state; d.bios_drive = bios; d.generation = gen; d.luns = 1; d.port = 3;
    d.block_size = 512; d.last_lba_lo = 0x1D7FFFF;
    return d;
}

static void layout(void)
{
    CHECK(sizeof(struct uds_channel) == 16);
    CHECK(UDS_CH1_OFFSET + sizeof(struct uds_channel) == 64);   /* one cache line with CSMPPrxy */
    CHECK(sizeof(struct uds_req) == 80);
    CHECK(offsetof(struct uds_req, seq) == 8);
    CHECK(offsetof(struct uds_req, data_phys) == 16);
    CHECK(offsetof(struct uds_req, cdb) == 28);
    CHECK(offsetof(struct uds_req, status) == 44);
    CHECK(offsetof(struct uds_req, generation) == 48);
    CHECK(offsetof(struct uds_req, sense) == 60);
    CHECK(sizeof(struct uds_dev_info) == 48);
    CHECK(offsetof(struct uds_dev_info, generation) == 8);
    CHECK(offsetof(struct uds_dev_info, vendor) == 24);
    CHECK(UDS_MAX_DEVS * sizeof(struct uds_dev_info) <= 4096);
    /* USOSUDSK record (patch 0021) and the USOSUSB.MPD status page */
    CHECK(sizeof(struct uds_diag_dev) == 64);
    CHECK(sizeof(struct uds_diag_disk) == 12);
    CHECK(sizeof(struct uds_diag_event) == 8);
    CHECK(offsetof(struct uds_diag, dev) == 32);
    CHECK(offsetof(struct uds_diag, disk) == 544);
    CHECK(offsetof(struct uds_diag, ev) == 640);
    /* version 2 (usos17 patch 0022): the port watch block appended at +768 */
    CHECK(offsetof(struct uds_diag, watch_passes) == UDS_DIAG_V1_SIZE);
    CHECK(offsetof(struct uds_diag, pool) == 788);
    CHECK(offsetof(struct uds_diag, ctl) == 792);
    CHECK(offsetof(struct uds_diag, media) == 856);
    CHECK(sizeof(struct uds_diag_ctl) == 16 && sizeof(struct uds_diag_media) == 16);
    CHECK(sizeof(struct uds_diag) == UDS_DIAG_V2_SIZE && UDS_DIAG_V2_SIZE == 984);
    CHECK(offsetof(struct uds_diag_dev, generation) == 16);
    CHECK(offsetof(struct uds_diag_dev, requests) == 32);
    CHECK(offsetof(struct uds_diag_dev, kib_in) == 56);
    CHECK(sizeof(struct uds_mp_slot) == 16);
    CHECK(offsetof(struct uds_mp_status, slot) == 36);
    CHECK(offsetof(struct uds_mp_status, notready) == 100 && sizeof(struct uds_mp_status) == 104);
    /* USOSUSB 1.1 request ring: after the ENUM table (256 + 8 * 48), inside the control page */
    CHECK(sizeof(struct uds_mp_rent) == 16 && sizeof(struct uds_mp_ring) == 528);
    CHECK(UDS_MP_RING_OFFSET >= 256 + UDS_MAX_DEVS * sizeof(struct uds_dev_info));
    CHECK(UDS_MP_RING_OFFSET + sizeof(struct uds_mp_ring) <= 4096);
    CHECK(UDS_MP_STATUS_OFFSET + sizeof(struct uds_mp_status) <= 256);
    CHECK(UDS_MP_STATUS_OFFSET >= sizeof(struct uds_req));
}

static void validation(void)
{
    struct uds_req r = valid_read();
    CHECK(why_of(r) == UDS_WHY_OK);
    r = valid_read(); r.magic ^= 1; CHECK(why_of(r) == UDS_WHY_MAGIC);
    r = valid_read(); r.version = 2; CHECK(why_of(r) == UDS_WHY_VERSION);
    r = valid_read(); r.size = 64; CHECK(why_of(r) == UDS_WHY_SIZE);
    r = valid_read(); r.op = 0; CHECK(why_of(r) == UDS_WHY_OP);
    r = valid_read(); r.op = 6; CHECK(why_of(r) == UDS_WHY_OP);
    r = valid_read(); r.dev = UDS_MAX_DEVS; CHECK(why_of(r) == UDS_WHY_DEV);
    r = valid_read(); r.lun = 16; CHECK(why_of(r) == UDS_WHY_LUN);
    r = valid_read(); r.cdb_len = 5; CHECK(why_of(r) == UDS_WHY_CDB);
    r = valid_read(); r.cdb_len = 17; CHECK(why_of(r) == UDS_WHY_CDB);
    r = valid_read(); r.dir = 3; CHECK(why_of(r) == UDS_WHY_DIR);
    r = valid_read(); r.dir = UDS_DIR_NONE; CHECK(why_of(r) == UDS_WHY_LEN);       /* data without a direction */
    r = valid_read(); r.data_len = 0; CHECK(why_of(r) == UDS_WHY_LEN);             /* direction without data */
    r = valid_read(); r.data_len = 0; r.dir = UDS_DIR_NONE; r.data_phys = 0; CHECK(why_of(r) == UDS_WHY_OK);
    r = valid_read(); r.data_len = UDS_MAX_DATA; CHECK(why_of(r) == UDS_WHY_OK);
    r = valid_read(); r.data_len = UDS_MAX_DATA + 1; CHECK(why_of(r) == UDS_WHY_LEN);
    r = valid_read(); r.data_phys = 0; CHECK(why_of(r) == UDS_WHY_ADDR);
    r = valid_read(); r.data_phys = 0xFFFFF000UL; r.data_len = 4096; CHECK(why_of(r) == UDS_WHY_OK);  /* ends at 4 GiB */
    r = valid_read(); r.data_phys = 0xFFFFF001UL; r.data_len = 4096; CHECK(why_of(r) == UDS_WHY_ADDR); /* wraps */
    r = valid_read(); r.data_phys = 0x90000UL; r.data_len = 0x10000; CHECK(why_of(r) == UDS_WHY_OK);  /* up to A0000h */
    r = valid_read(); r.data_phys = 0x90001UL; r.data_len = 0x10000; CHECK(why_of(r) == UDS_WHY_ADDR);
    r = valid_read(); r.data_phys = 0xF0000UL; r.data_len = 512; CHECK(why_of(r) == UDS_WHY_ADDR);    /* BIOS */
    r = valid_read(); r.data_phys = 0xFF000UL; r.data_len = 0x2000; CHECK(why_of(r) == UDS_WHY_ADDR);
    r = valid_read(); r.data_phys = 0x100000UL; r.data_len = 512; CHECK(why_of(r) == UDS_WHY_OK);
    /* ENUM: data in, room for the whole table, dev ignored */
    r = valid_read(); r.op = UDS_OP_ENUM; r.cdb_len = 0; r.dev = 200; r.data_len = UDS_MAX_DEVS * sizeof(struct uds_dev_info);
    CHECK(why_of(r) == UDS_WHY_OK);
    r.data_len -= 1; CHECK(why_of(r) == UDS_WHY_LEN);
    r.data_len += 1; r.dir = UDS_DIR_OUT; CHECK(why_of(r) == UDS_WHY_DIR);
    /* RESET / EJECT: no data */
    r = valid_read(); r.op = UDS_OP_RESET; r.cdb_len = 0; r.dir = UDS_DIR_NONE; r.data_len = 0; r.data_phys = 0;
    CHECK(why_of(r) == UDS_WHY_OK);
    r.dir = UDS_DIR_IN; r.data_len = 512; r.data_phys = 0x100000UL; CHECK(why_of(r) == UDS_WHY_DIR);
    r = valid_read(); r.op = UDS_OP_EJECT; r.cdb_len = 0; r.dir = UDS_DIR_NONE; r.data_len = 0; r.dev = UDS_MAX_DEVS;
    CHECK(why_of(r) == UDS_WHY_DEV);
}

static void before(struct uds_slot *s, const uds_u8 *cdb, uds_u8 len, uds_u8 action, uds_u8 key, uds_u8 asc)
{
    struct uds_scsi_res res;
    memset(&res, 0xCC, sizeof(res));
    uds_slot_before(s, cdb, len, &res);
    CHECK(res.action == action);
    if (action == UDS_ACT_CHECK) {
        CHECK(res.scsi_status == 2 && res.key == key && res.asc == asc && res.ascq == 0);
    } else {
        CHECK(res.scsi_status == 0);
    }
}

static struct uds_scsi_res after(struct uds_slot *s, const uds_u8 *cdb, uds_u8 len, uds_u32 status,
                                  const uds_u8 *sense, uds_u8 sense_len)
{
    struct uds_req r;
    struct uds_scsi_res res;
    r.seq = 7;
    uds_slot_fill(s, &r, 0, cdb, len, UDS_DIR_IN, 0x200000UL, 4096);
    r.status = status;
    r.sense_len = sense_len;
    if (sense_len) memcpy(r.sense, sense, sense_len);
    memset(&res, 0xCC, sizeof(res));
    uds_slot_after(s, &r, &res);
    return res;
}

static void slots(void)
{
    struct uds_slot s;
    struct uds_dev_info d;
    struct uds_req r;
    struct uds_scsi_res res;
    uds_u8 buf[64];
    uds_u32 why;

    /* boot with a stick: the first ENUM before any command gives no UNIT ATTENTION */
    uds_slot_init(&s);
    CHECK(s.dev == 0xFF && !s.present);
    d = dev(UDS_DEV_PRESENT, 0, 1);
    uds_slot_update(&s, 0, &d);
    CHECK(s.present && s.dev == 0 && s.generation == 1 && !s.ua_pending);
    before(&s, READ10, 10, UDS_ACT_SEND, 0, 0);
    before(&s, TUR, 6, UDS_ACT_SEND, 0, 0);

    /* the request carries the generation it was meant for and passes validation */
    r.seq = 41;
    uds_slot_fill(&s, &r, 0, READ10, 10, UDS_DIR_IN, 0x200000UL, 4096);
    CHECK(r.seq == 41 && r.op == UDS_OP_SCSI && r.dev == 0 && r.generation == 1 && r.status == UDS_S_PENDING);
    CHECK(r.cdb_len == 10 && !memcmp(r.cdb, READ10, 10) && r.dir == UDS_DIR_IN && r.data_len == 4096);
    CHECK(uds_req_check(&r, &why) == UDS_S_OK && why == UDS_WHY_OK);
    uds_slot_fill(&s, &r, 0, TUR, 6, UDS_DIR_IN, 0x200000UL, 0);
    CHECK(r.dir == UDS_DIR_NONE && r.data_phys == 0 && uds_req_check(&r, &why) == UDS_S_OK);

    /* same stick again in ENUM: nothing changes */
    uds_slot_update(&s, 0, &d);
    before(&s, READ10, 10, UDS_ACT_SEND, 0, 0);

    /* the stick is pulled: NOT READY / medium not present; INQUIRY still answers (fixed identity) */
    d = dev(UDS_DEV_GONE, 0, 1);
    uds_slot_update(&s, 0, &d);
    CHECK(!s.present);
    before(&s, READ10, 10, UDS_ACT_CHECK, 0x02, 0x3A);
    before(&s, TUR, 6, UDS_ACT_CHECK, 0x02, 0x3A);
    before(&s, INQ, 6, UDS_ACT_LOCAL, 0, 0);
    before(&s, SYNC10, 10, UDS_ACT_GOOD, 0, 0);      /* shutdown flush without a stick */
    before(&s, EJECT, 6, UDS_ACT_GOOD, 0, 0);        /* eject of an empty slot */
    uds_local_sense(&s, buf, 18);
    CHECK(buf[0] == 0x70 && buf[2] == 0x02 && buf[7] == 10 && buf[12] == 0x3A && buf[13] == 0);

    /* another stick: exactly one UNIT ATTENTION / 28h, then commands go through */
    d = dev(UDS_DEV_PRESENT, 0, 2);
    uds_slot_update(&s, 0, &d);
    CHECK(s.present && s.generation == 2 && s.ua_pending);
    before(&s, INQ, 6, UDS_ACT_LOCAL, 0, 0);         /* INQUIRY does not consume it */
    before(&s, READ10, 10, UDS_ACT_CHECK, 0x06, 0x28);
    before(&s, READ10, 10, UDS_ACT_SEND, 0, 0);
    uds_local_sense(&s, buf, 18);
    CHECK(buf[2] == 0 && buf[12] == 0);              /* the SEND cleared the last sense */

    /* replaced between two ENUMs without a gap: still a UNIT ATTENTION */
    d = dev(UDS_DEV_PRESENT, 0, 3);
    uds_slot_update(&s, 0, &d);
    before(&s, TUR, 6, UDS_ACT_CHECK, 0x06, 0x28);
    before(&s, TUR, 6, UDS_ACT_SEND, 0, 0);

    /* pulled during a write: the request fails, the slot is empty, no retry onto a new stick */
    res = after(&s, READ10, 10, UDS_S_GONE, 0, 0);
    CHECK(res.action == UDS_ACT_SEND && res.scsi_status == 2 && res.key == 0x02 && res.asc == 0x3A && !res.reset);
    CHECK(!s.present);
    before(&s, READ10, 10, UDS_ACT_CHECK, 0x02, 0x3A);

    /* a stick that has a BIOS number (opt-out flag) is never offered */
    uds_slot_init(&s);
    d = dev(UDS_DEV_PRESENT, 0x81, 1);
    uds_slot_update(&s, 0, &d);
    CHECK(!s.present);
    before(&s, READ10, 10, UDS_ACT_CHECK, 0x02, 0x3A);
    d = dev(UDS_DEV_PRESENT, 0, 0);                  /* generation 0 is never a present stick */
    uds_slot_update(&s, 0, &d);
    CHECK(!s.present);

    /* empty at boot, stick plugged later (stage 2): UNIT ATTENTION after NOT READY */
    uds_slot_init(&s);
    uds_slot_update(&s, 0, NULL);
    before(&s, TUR, 6, UDS_ACT_CHECK, 0x02, 0x3A);
    d = dev(UDS_DEV_PRESENT, 0, 5);
    uds_slot_update(&s, 2, &d);
    CHECK(s.present && s.dev == 2);
    before(&s, TUR, 6, UDS_ACT_CHECK, 0x06, 0x28);
    before(&s, READ10, 10, UDS_ACT_SEND, 0, 0);

    /* completion mapping */
    {
        static const uds_u8 sense_mc[18] = { 0x70, 0, 0x06, 0, 0, 0, 0, 10, 0, 0, 0, 0, 0x28, 0x00 };
        static const uds_u8 sense_ill[18] = { 0x70, 0, 0x05, 0, 0, 0, 0, 10, 0, 0, 0, 0, 0x20, 0x00 };
        static const uds_u8 sense_med[18] = { 0xF0, 0, 0x03, 0, 0, 0, 0, 10, 0, 0, 0, 0, 0x11, 0x00 };
        res = after(&s, READ10, 10, UDS_S_OK, 0, 0);
        CHECK(res.scsi_status == 0 && res.key == 0);
        res = after(&s, READ10, 10, UDS_S_CHECK, sense_med, 18);        /* unrecovered read error */
        CHECK(res.scsi_status == 2 && res.key == 0x03 && res.asc == 0x11 && !res.reset);
        uds_local_sense(&s, buf, 18);
        CHECK(buf[2] == 0x03 && buf[12] == 0x11);
        res = after(&s, READ10, 10, UDS_S_CHECK, sense_mc, 18);         /* the stick's own UA passes */
        CHECK(res.key == 0x06 && res.asc == 0x28);
        res = after(&s, SYNC10, 10, UDS_S_CHECK, sense_ill, 18);        /* no cache: GOOD */
        CHECK(res.scsi_status == 0);
        res = after(&s, READ10, 10, UDS_S_CHECK, sense_ill, 18);        /* other commands keep it */
        CHECK(res.scsi_status == 2 && res.key == 0x05);
        res = after(&s, READ10, 10, UDS_S_CHECK, sense_ill, 8);         /* short sense */
        CHECK(res.key == 0x04 && res.asc == 0x44);
        res = after(&s, READ10, 10, UDS_S_TIMEOUT, 0, 0);
        CHECK(res.key == 0x0B && res.asc == 0x00 && res.reset == 1);
        res = after(&s, READ10, 10, UDS_S_PHASE, 0, 0);
        CHECK(res.key == 0x0B && res.asc == 0x4B && res.reset == 1);
        res = after(&s, READ10, 10, UDS_S_BADREQ, 0, 0);
        CHECK(res.key == 0x05 && res.asc == 0x24 && !res.reset);
        CHECK(s.present);                                               /* none of these empties the slot */
        res = after(&s, READ10, 10, 0x1234, 0, 0);
        CHECK(res.key == 0x04 && res.asc == 0x44);
        res = after(&s, READ10, 10, UDS_S_OWNED, 0, 0);
        CHECK(res.key == 0x02 && res.asc == 0x3A && !s.present);
    }

    /* local commands */
    uds_slot_init(&s);
    d = dev(UDS_DEV_PRESENT, 0, 1);
    uds_slot_update(&s, 0, &d);
    before(&s, LOCK, 6, UDS_ACT_GOOD, 0, 0);
    before(&s, EJECT, 6, UDS_ACT_EJECT, 0, 0);
    {
        static const uds_u8 start[6] = { 0x1B, 0, 0, 0, 0x01, 0 };
        static const uds_u8 load[6] = { 0x1B, 0, 0, 0, 0x03, 0 };
        before(&s, start, 6, UDS_ACT_GOOD, 0, 0);
        before(&s, load, 6, UDS_ACT_GOOD, 0, 0);
    }
    before(&s, READ10, 3, UDS_ACT_CHECK, 0x05, 0x20);                  /* short CDB */

    memset(buf, 0xEE, sizeof(buf));
    uds_local_inquiry(buf, sizeof(buf), 3);
    CHECK(buf[0] == 0 && buf[1] == 0x80 && buf[4] == 31);
    CHECK(!memcmp(buf + 8, "USOS    ", 8) && !memcmp(buf + 16, "USB disk slot 3 ", 16) && !memcmp(buf + 32, "0001", 4));
    CHECK(buf[36] == 0xEE);                                             /* never more than 36 bytes */
    memset(buf, 0xEE, sizeof(buf));
    uds_local_inquiry(buf, 5, 0);
    CHECK(buf[1] == 0x80 && buf[4] == 31 && buf[5] == 0xEE);
}

int main(void)
{
    layout();
    validation();
    slots();
    if (fails) { printf("uds host test: %d failure(s)\n", fails); return 1; }
    printf("uds host test PASS\n");
    return 0;
}
