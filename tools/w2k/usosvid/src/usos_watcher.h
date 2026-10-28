/* USOS diagnostic watcher ABI v1. Own implementation, LGPL-2.1-or-later.
 * No NT source is included. Numeric offsets are shared with usosvid.
 * Owners after handoff: firmware 00..27 (except helper 20..27) and
 * 200..23f; usosvid 28..ff; helper 100..1ff. Proxy ABI is separate. */
#ifndef USOS_WATCHER_H
#define USOS_WATCHER_H
typedef unsigned char usw_u8;
typedef unsigned short usw_u16;
typedef unsigned int usw_u32;
typedef unsigned long long usw_u64;
typedef char usw_width_check[(sizeof(usw_u32)==4 && sizeof(usw_u64)==8)?1:-1];
#define USW_SIZE 0x1000u
#define USW_HEADER 0x100u
#define USW_BDA 0x4FCu
#define USW_MAGIC 0x44375755u /* UW7D */
#define USW_RESERVED 1u
#define USW_NONINVARIANT 2u
#define USW_FREQ 0x18u
#define USW_START 0x20u
#define USW_SEQ 0x28u
#define USW_READY 0x2Cu
#define USW_TICK_PA 0x30u
#define USW_SHARED_PA 0x38u
#define USW_HB_ENTRY 0x70u
#define USW_HB_DRAW 0x74u
#define USW_ARM 0x90u
#define USW_INIT_CNT 0xB0u
#define USW_CONFIG 0x200u
#define USW_SSEQ 0x100u
#define USW_NEXT 0x1E0u
#define USW_LAST 0x1E8u
#define USW_PROXY_START 0x1F0u
#define USW_LATE 0x1F8u
#define USW_PROXY_COUNT 0x1FCu
/* Sample flags. Validity is separate from values, including zero. */
#define USW_V_TICK 1u
#define USW_V_TIME 2u
#define USW_V_PMEVT 4u
#define USW_V_PMCNT 8u
#define USW_V_GPE 16u
#define USW_V_PUBLISH 32u
#define USW_F_READY 0x100u
#define USW_F_HIGHPA 0x200u
#define USW_F_BUSY 0x400u
#define USW_F_TORN 0x800u
#define USW_F_GPEPART 0x1000u
#define USW_F_UNSTABLE 0x2000u
#define USW_F_BADPA 0x4000u
#define USW_F_STALE 0x8000u
struct usw_ports {
    usw_u16 pm_sts, pm_en, pm_cnt, pm_tmr, gpe_sts, gpe_en;
    usw_u16 gpe_half, timer_bits;
};
struct usw_sample {
    usw_u32 flags, tick, it_low, it_high, hb_entry, hb_draw, arm;
    usw_u16 pm_sts, pm_en, pm_cnt;
    usw_u8 imr_master, imr_slave;
    usw_u32 gpe_sts, gpe_en;
    usw_u64 elapsed, seconds;
};
struct usw_ops {
    void *ctx;
    usw_u32 (*read32)(void *, usw_u32);
    usw_u8 (*inb)(void *, usw_u16);
    usw_u16 (*inw)(void *, usw_u16);
};
usw_u32 usw_load32(const volatile usw_u8 *, usw_u32);
usw_u64 usw_load64(const volatile usw_u8 *, usw_u32);
void usw_store32(volatile usw_u8 *, usw_u32, usw_u32);
void usw_store64(volatile usw_u8 *, usw_u32, usw_u64);
int usw_header_valid(const volatile usw_u8 *, usw_u32);
int usw_parse_fadt(const usw_u8 *, usw_u32, struct usw_ports *);
int usw_e820_reserved(const usw_u8 *, usw_u32, usw_u32, usw_u64, usw_u64);
void usw_init(volatile usw_u8 *, const struct usw_ports *, usw_u64, usw_u32);
int usw_time_read(const struct usw_ops *, usw_u32, usw_u32 *, usw_u32 *);
void usw_collect(const volatile usw_u8 *, const struct usw_ops *, usw_u64, struct usw_sample *);
void usw_format(const struct usw_sample *, char [80]);
void usw_save(volatile usw_u8 *, const struct usw_sample *, const char [80]);
#endif
