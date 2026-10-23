/* win16_pkt.c - DPMI + USOSPKT queue-mode transport for the Win16 provider.
 *
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Two jobs:
 *
 *   1. DPMI plumbing.  Locate the driver block (INT 2Fh AX=5553h BX=FFFFh),
 *      map it through an owned descriptor (INT 31h AX=0007h/0008h/0009h),
 *      keep a real-mode call structure in a GlobalDosAlloc block and issue
 *      every multiplex call through
 *      INT 31h AX=0300h instead of a protected-mode INT 2Fh, so the call runs
 *      exactly as the driver expects it on a real CPU.
 *
 *   2. The rings.  The block layout is fixed by usospkt.S ('USQ1' header at
 *      0, RX ring 16 x 2056, TX ring 4 x 1544): the driver advances the heads,
 *      we advance the tails.  Completed RX slots are copied out one frame at a
 *      time; TX slots are filled and then handed to the driver with TX_KICK,
 *      which is the only subfunction that touches the NIC, and it runs in our
 *      context, never in an ISR.
 *
 * Everything is static: the provider has no heap (a Win16 DLL would have to
 * use GlobalAlloc and a fixed buffer is simpler and faster).
 */

#include <windows.h>
#include <i86.h>

#include "net.h"
#include "usos_pkt.h"

#ifdef USOS_WS_DIAG
static void diag(const char *text)
{
    HFILE f = _lopen("C:\\WSDIAG.LOG", OF_WRITE);
    unsigned int n = 0;
    if (f == HFILE_ERROR) f = _lcreat("C:\\WSDIAG.LOG", 0);
    if (f == HFILE_ERROR) return;
    while (text[n]) ++n;
    _llseek(f, 0, 2); _lwrite(f, text, n); _lwrite(f, "\r\n", 2); _lclose(f);
}
#else
#define diag(text) ((void)0)
#endif

/* ------------------------------------------------------------------ */
/* 'USQ1' block header: offsets are block relative (see usospkt.S)      */
/* ------------------------------------------------------------------ */
#define Q_MAGIC      0x0000
#define Q_VERSION    0x0004
#define Q_HDRSZ      0x0006
#define Q_FLAGS      0x0008
#define Q_RXHEAD     0x000C
#define Q_RXTAIL     0x000E
#define Q_RXCNT      0x0010
#define Q_RXSTRIDE   0x0012
#define Q_RXBASE     0x0014
#define Q_TXHEAD     0x0018
#define Q_TXTAIL     0x001A
#define Q_TXCNT      0x001C
#define Q_TXSTRIDE   0x001E
#define Q_TXBASE     0x0020
#define Q_RXDROP     0x0024
#define Q_TXBUSY     0x0028
#define Q_TXDONE     0x002C
#define Q_RXERR      0x0030
#define Q_TXERR      0x0034
#define Q_LOGHEAD    0x0038
#define Q_LOGTAIL    0x003A
#define Q_LOGSZ      0x003C
#define Q_LOGBASE    0x003E
#define Q_LOGDROP    0x0042
#define Q_INT        0x0046
#define Q_MAC        0x0048
#define Q_SEQ        0x004E

#define Q_SLOT_LEN   0          /* slot-relative */
#define Q_SLOT_FLAGS 2
#define Q_SLOT_SEQ   4
#define Q_SLOT_DATA  8

#define QF_READY     0x01
#define QF_ATTACH    0x02
#define QF_SUPPRESS  0x04

/* Multiplex: INT 2Fh AX=5553h, subfunction in BX */
#define MPX_AX       0x5553
#define MPX_QUERY    0xFFFF
#define MPX_ATTACH   0x0001
#define MPX_STATE    0x0002
#define MPX_KICK     0x0003
#define MPX_RELEASE  0x0004

/* Real-mode call structure (DPMI INT 31h AX=0300h), 50 bytes at offset 0 of
 * the DOS block; the rest of the block is the real-mode stack. */
#define RMCS_EBX     0x10
#define RMCS_EDX     0x14
#define RMCS_ECX     0x18
#define RMCS_EAX     0x1C
#define RMCS_FLAGS   0x20
#define RMCS_ES      0x22
#define RMCS_DS      0x24
#define RMCS_SP      0x2E
#define RMCS_SS      0x30

#define USOS_RMCS_SIZE  0x0200
#define USOS_RMCS_PARAS (USOS_RMCS_SIZE / 16)

static usos_u8 FAR *usos_rm;          /* call structure + stack view */
static usos_u16 usos_rm_seg;          /* real-mode segment of that block */
static usos_u16 usos_rm_sel;          /* selector we read/write it through */
static usos_u16 usos_rm_desc;         /* descriptor from AX=0000h, if used */

static usos_u8 FAR *usos_q;           /* mapped 'USQ1' block */
static usos_u16 usos_q_seg;
static usos_u16 usos_q_desc;
static usos_u16 usos_q_ver;
static usos_u16 usos_q_flags;

static usos_u16 usos_rx_cnt, usos_rx_stride, usos_rx_base;
static usos_u16 usos_tx_cnt, usos_tx_stride, usos_tx_base;
static usos_u16 usos_tx_seq;

static int usos_state = USOS_PKT_STATE_DOWN;

static usos_u32 usos_local_ip = 0x0A00020FUL;   /* 10.0.2.15, QEMU slirp */
static usos_u32 usos_dns_ip   = 0x0A000203UL;   /* 10.0.2.3,  QEMU slirp */

static void usos_mem_zero(usos_u8 FAR *p, usos_u16 len)
{
    usos_u16 i;

    for (i = 0; i < len; i++)
        p[i] = 0;
}

static void usos_mem_copy(usos_u8 FAR *dst, const usos_u8 FAR *src,
                          usos_u16 len)
{
    usos_u16 i;

    for (i = 0; i < len; i++)
        dst[i] = src[i];
}

/* ------------------------------------------------------------------ */
/* DPMI primitives                                                     */
/* ------------------------------------------------------------------ */

/* 1687h is the documented probe; in a Win16 session we are already protected
 * mode, where some hosts answer "not supported", so a failed probe falls back
 * to the DPMI version call (INT 31h AX=0400h). */
static int usos_dpmi_present(void)
{
    union REGS r;

    r.x.ax = 0x1687;
    r.x.bx = 0;
    r.x.cx = 0;
    r.x.dx = 0;
    r.x.si = 0;
    r.x.di = 0;
    int86(0x2F, &r, &r);
    if (r.x.ax == 0)
        return 1;
    r.x.ax = 0x0400;
    int86(0x31, &r, &r);
    return r.x.cflag ? 0 : 1;
}

static int usos_dpmi_alloc_desc(usos_u16 *selector)
{
    union REGS in, out;

    in.x.ax = 0x0000;
    in.x.cx = 1;
    int86(0x31, &in, &out);
    if (out.x.cflag)
        return USOS_PKT_ERR_DPMI;
    *selector = out.x.ax;
    return USOS_PKT_OK;
}

static void usos_dpmi_free_desc(usos_u16 selector)
{
    union REGS in, out;

    if (selector == 0)
        return;
    in.x.ax = 0x0001;
    in.x.bx = selector;
    int86(0x31, &in, &out);
}

static int usos_dpmi_alloc_dos(usos_u16 paras, usos_u16 *seg, usos_u16 *sel)
{
    DWORD allocation;
    /* Win16's allocator works in STANDARD as well as enhanced mode and
     * supplies both the protected selector and the real-mode paragraph. */
    diag("GlobalDosAlloc enter");
    allocation = GlobalDosAlloc((DWORD)paras * 16UL);
    diag("GlobalDosAlloc returned");
    if (allocation == 0)
        return USOS_PKT_ERR_DPMI;
    *seg = HIWORD(allocation);
    *sel = LOWORD(allocation);
    return USOS_PKT_OK;
}

static void usos_dpmi_free_dos(usos_u16 selector)
{
    if (selector == 0)
        return;
    GlobalDosFree(selector);
}

/* AX=0007h/0008h/0009h: base, limit, access rights of our owned descriptor. */
static int usos_dpmi_set_seg(usos_u16 selector, usos_u32 base, usos_u32 limit,
                             usos_u8 rights)
{
    union REGS in, out;

    in.x.ax = 0x0007;
    in.x.bx = selector;
    in.x.cx = (usos_u16)((base >> 16) & 0xFFFFUL);
    in.x.dx = (usos_u16)(base & 0xFFFFUL);
    int86(0x31, &in, &out);
    if (out.x.cflag)
        return USOS_PKT_ERR_DPMI;
    in.x.ax = 0x0008;
    in.x.bx = selector;
    in.x.cx = (usos_u16)((limit >> 16) & 0xFFFFUL);
    in.x.dx = (usos_u16)(limit & 0xFFFFUL);
    int86(0x31, &in, &out);
    if (out.x.cflag)
        return USOS_PKT_ERR_DPMI;
    in.x.ax = 0x0009;
    in.x.bx = selector;
    in.x.cx = rights;
    int86(0x31, &in, &out);
    return out.x.cflag ? USOS_PKT_ERR_DPMI : USOS_PKT_OK;
}

/* Map an owned descriptor; AX=0002h would instead RETURN a different
 * selector in AX and must not be confused with setting a descriptor. */
static int usos_dpmi_map(usos_u16 seg, usos_u16 selector)
{
    return usos_dpmi_set_seg(selector, (usos_u32)seg * 16UL, 0xFFFFUL, 0xF2);
}

/* The shared x86 queue uses little endian, independently of wire headers. */
static usos_u16 q_get16(const usos_u8 FAR *p)
{
    return (usos_u16)((usos_u16)p[0] | ((usos_u16)p[1] << 8));
}
static usos_u32 q_get32(const usos_u8 FAR *p)
{
    return (usos_u32)q_get16(p) | ((usos_u32)q_get16(p + 2) << 16);
}
static void q_put16(usos_u8 FAR *p, usos_u16 v)
{
    p[0] = (usos_u8)v;
    p[1] = (usos_u8)(v >> 8);
}

/* ------------------------------------------------------------------ */
/* Real-mode call structure access                                     */
/* ------------------------------------------------------------------ */

static void usos_rm_put16(usos_u16 off, usos_u16 value)
{
    usos_rm[off] = (usos_u8)(value & 0xFFU);
    usos_rm[off + 1] = (usos_u8)(value >> 8);
}

static void usos_rm_put32(usos_u16 off, usos_u32 value)
{
    usos_rm[off] = (usos_u8)(value & 0xFFUL);
    usos_rm[off + 1] = (usos_u8)((value >> 8) & 0xFFUL);
    usos_rm[off + 2] = (usos_u8)((value >> 16) & 0xFFUL);
    usos_rm[off + 3] = (usos_u8)((value >> 24) & 0xFFUL);
}

static usos_u16 usos_rm_get16(usos_u16 off)
{
    return (usos_u16)((usos_u16)usos_rm[off] |
                      ((usos_u16)usos_rm[off + 1] << 8));
}

static usos_u32 usos_rm_get32(usos_u16 off)
{
    return ((usos_u32)usos_rm[off])
         | ((usos_u32)usos_rm[off + 1] << 8)
         | ((usos_u32)usos_rm[off + 2] << 16)
         | ((usos_u32)usos_rm[off + 3] << 24);
}

/* Run real-mode INT `intno` with the given AX/BX/CX/DX through DPMI.  The
 * real-mode handler sees the registers from the call structure and may change
 * them, which is how the driver reports AL/ES/... back. */
static int usos_rm_int(usos_u8 intno, usos_u16 ax, usos_u16 bx, usos_u16 cx,
                       usos_u16 dx, usos_u16 *o_ax, usos_u16 *o_bx,
                       usos_u16 *o_cx, usos_u16 *o_dx, usos_u16 *o_es)
{
    union REGS in, out;
    struct SREGS sr;

    if (usos_rm == 0)
        return USOS_PKT_ERR_DPMI;
    usos_mem_zero(usos_rm, 0x32);
    usos_rm_put32(RMCS_EBX, (usos_u32)bx);
    usos_rm_put32(RMCS_EDX, (usos_u32)dx);
    usos_rm_put32(RMCS_ECX, (usos_u32)cx);
    usos_rm_put32(RMCS_EAX, (usos_u32)ax);
    usos_rm_put16(RMCS_FLAGS, 0x0202);            /* IF=1, CF=0 on entry */
    usos_rm_put16(RMCS_ES, 0);
    usos_rm_put16(RMCS_DS, 0);
    usos_rm_put16(RMCS_SS, usos_rm_seg);
    usos_rm_put16(RMCS_SP, (usos_u16)(USOS_RMCS_SIZE - 2));

    segread(&sr);
    in.x.ax = 0x0300;
    in.x.bx = (usos_u16)intno;                    /* BL = interrupt number */
    in.x.cx = 0;                                  /* no stack parameter copy */
    in.x.di = 0;                                  /* RMCS at offset 0 */
    sr.es = usos_rm_sel;                          /* protected-mode selector */
    if (bx != MPX_KICK) diag("DPMI simulate interrupt enter");
    int86x(0x31, &in, &out, &sr);
    if (bx != MPX_KICK) diag("DPMI simulate interrupt returned");
    if (out.x.cflag)
        return USOS_PKT_ERR_DPMI;

    if (o_ax != 0)
        *o_ax = (usos_u16)(usos_rm_get32(RMCS_EAX) & 0xFFFFUL);
    if (o_bx != 0)
        *o_bx = (usos_u16)(usos_rm_get32(RMCS_EBX) & 0xFFFFUL);
    if (o_cx != 0)
        *o_cx = (usos_u16)(usos_rm_get32(RMCS_ECX) & 0xFFFFUL);
    if (o_dx != 0)
        *o_dx = (usos_u16)(usos_rm_get32(RMCS_EDX) & 0xFFFFUL);
    if (o_es != 0)
        *o_es = usos_rm_get16(RMCS_ES);
    return USOS_PKT_OK;
}

static int usos_pkt_give_back(void)
{
    if (usos_q_desc != 0)
        usos_dpmi_free_desc(usos_q_desc);
    if (usos_rm_desc != 0)
        usos_dpmi_free_desc(usos_rm_desc);
    usos_dpmi_free_dos(usos_rm_sel);
    usos_q = 0;
    usos_q_desc = 0;
    usos_q_seg = 0;
    usos_rm = 0;
    usos_rm_desc = 0;
    usos_rm_sel = 0;
    usos_rm_seg = 0;
    usos_state = USOS_PKT_STATE_DOWN;
    return USOS_PKT_ERR_NODRIVER;
}

static int usos_pkt_is_pow2(usos_u16 value)
{
    return value != 0 && (value & (usos_u16)(value - 1)) == 0;
}

int usos_pkt_init(void)
{
    usos_u16 seg = 0, ver = 0, flags = 0;
    usos_u16 ax = 0, bx = 0, cx = 0, dx = 0, es = 0;
    int rc;

    if (usos_state != USOS_PKT_STATE_DOWN)
        return USOS_PKT_OK;
    diag("transport init");
    if (!usos_dpmi_present())
        return USOS_PKT_ERR_DPMI;
    diag("DPMI present");

    rc = usos_dpmi_alloc_dos((usos_u16)USOS_RMCS_PARAS, &usos_rm_seg,
                             &usos_rm_sel);
    if (rc != USOS_PKT_OK)
        return rc;
    if (usos_rm_sel == 0) {
        rc = usos_dpmi_alloc_desc(&usos_rm_desc);
        if (rc != USOS_PKT_OK) {
            usos_dpmi_free_dos(usos_rm_sel);
            usos_rm_seg = 0;
            return rc;
        }
        rc = usos_dpmi_map(usos_rm_seg, usos_rm_desc);
        if (rc != USOS_PKT_OK) {
            usos_dpmi_free_desc(usos_rm_desc);
            usos_dpmi_free_dos(usos_rm_sel);
            usos_rm_desc = 0;
            usos_rm_seg = 0;
            return rc;
        }
        usos_rm_sel = usos_rm_desc;
    }
    usos_rm = (usos_u8 FAR *)MK_FP(usos_rm_sel, 0);
    diag("DOS pointer mapped");

    /* Query: a driver without /Q answers 0 in AL, which is precisely the
     * "no transport" case WSAStartup turns into WSASYSNOTREADY. */
    rc = usos_rm_int(0x2F, MPX_AX, MPX_QUERY, 0, 0, &ax, &bx, &cx, &dx, &es);
    if (rc != USOS_PKT_OK)
        return usos_pkt_give_back();
    if ((usos_u8)ax != 0xFFU)
        return usos_pkt_give_back();
    diag("queue query present");
    seg = es;
    ver = cx;
    flags = dx;

    rc = usos_dpmi_alloc_desc(&usos_q_desc);
    if (rc != USOS_PKT_OK)
        return usos_pkt_give_back();
    rc = usos_dpmi_map(seg, usos_q_desc);
    if (rc != USOS_PKT_OK)
        return usos_pkt_give_back();
    usos_q = (usos_u8 FAR *)MK_FP(usos_q_desc, 0);
    diag("queue pointer mapped");
    usos_q_seg = seg;
    usos_q_ver = ver;
    usos_q_flags = flags;

    if (usos_q[Q_MAGIC + 0] != 'U' || usos_q[Q_MAGIC + 1] != 'S' ||
        usos_q[Q_MAGIC + 2] != 'Q' || usos_q[Q_MAGIC + 3] != '1')
        return usos_pkt_give_back();
    if ((usos_u16)(q_get16(usos_q + Q_VERSION) >> 8) != 1)
        return usos_pkt_give_back();   /* only major version 1 */

    usos_rx_cnt = q_get16(usos_q + Q_RXCNT);
    usos_rx_stride = q_get16(usos_q + Q_RXSTRIDE);
    usos_rx_base = (usos_u16)(q_get32(usos_q + Q_RXBASE) & 0xFFFFUL);
    usos_tx_cnt = q_get16(usos_q + Q_TXCNT);
    usos_tx_stride = q_get16(usos_q + Q_TXSTRIDE);
    usos_tx_base = (usos_u16)(q_get32(usos_q + Q_TXBASE) & 0xFFFFUL);
    if (!usos_pkt_is_pow2(usos_rx_cnt) || !usos_pkt_is_pow2(usos_tx_cnt) ||
        usos_rx_stride < (usos_u16)(Q_SLOT_DATA + 64) ||
        usos_tx_stride < (usos_u16)(Q_SLOT_DATA + 64))
        return usos_pkt_give_back();
    if (usos_rx_base == 0 || usos_tx_base == 0)
        return usos_pkt_give_back();

    usos_state = USOS_PKT_STATE_INIT;
    return USOS_PKT_OK;
}

int usos_pkt_attach(void)
{
    usos_u16 ax = 0, bx = 0, cx = 0, dx = 0, es = 0;
    int rc;

    if (usos_state == USOS_PKT_STATE_ATTACHED)
        return USOS_PKT_OK;
    rc = usos_pkt_init();
    if (rc != USOS_PKT_OK)
        return rc;
    rc = usos_rm_int(0x2F, MPX_AX, MPX_ATTACH, 0, 0, &ax, &bx, &cx, &dx, &es);
    if (rc != USOS_PKT_OK)
        return rc;
    switch ((usos_u8)ax) {
    case 0:
        break;
    case 1:
        return USOS_PKT_ERR_NODRIVER;
    case 2:
        return USOS_PKT_ERR_BUSY;
    default:
        return USOS_PKT_ERR_STATE;
    }
    /* The driver hands the block back with every ATTACH; the mapping does not
     * change, but the flags do (ATTACH + SUPPRESS are set now). */
    usos_q_seg = es;
    usos_q_flags = dx;
    usos_state = USOS_PKT_STATE_ATTACHED;
    return USOS_PKT_OK;
}

void usos_pkt_release(void)
{
    usos_u16 ax = 0;

    if (usos_state != USOS_PKT_STATE_ATTACHED)
        return;
    usos_rm_int(0x2F, MPX_AX, MPX_RELEASE, 0, 0, &ax, 0, 0, 0, 0);
    usos_state = USOS_PKT_STATE_INIT;
}

void usos_pkt_term(void)
{
#ifdef USOS_WS_DIAG
    if (usos_q != 0) {
        char image[161];
        static const char hex[] = "0123456789ABCDEF";
        unsigned int i;
        for (i = 0; i < 80; ++i) {
            image[2*i] = hex[usos_q[i] >> 4];
            image[2*i+1] = hex[usos_q[i] & 15];
        }
        image[160] = 0;
        diag(image);
    }
#endif
    usos_pkt_release();
    if (usos_state == USOS_PKT_STATE_INIT) {
        usos_dpmi_free_desc(usos_q_desc);
        usos_dpmi_free_desc(usos_rm_desc);
        usos_dpmi_free_dos(usos_rm_sel);
        usos_q = 0;
        usos_q_desc = 0;
        usos_rm = 0;
        usos_rm_desc = 0;
        usos_rm_sel = 0;
        usos_rm_seg = 0;
        usos_state = USOS_PKT_STATE_DOWN;
    }
}

int usos_pkt_state(void)
{
    return usos_state;
}

static int usos_pkt_kick(void)
{
    usos_u16 ax = 0;
    int rc = usos_rm_int(0x2F, MPX_AX, MPX_KICK, 0, 0, &ax, 0, 0, 0, 0);

    if (rc != USOS_PKT_OK)
        return rc;
    switch ((usos_u8)ax) {
    case 0:                            /* sent */
    case 1:                            /* nothing queued */
        return USOS_PKT_OK;
    case 2:                            /* client vanished */
        return USOS_PKT_ERR_STATE;
    default:                           /* 3: the NIC refused it */
        return USOS_PKT_ERR_SEND;
    }
}

int usos_pkt_send(const usos_u8 *frame, usos_u16 len)
{
    usos_u16 head, tail, next, slot;
    int rc;

    if (usos_state != USOS_PKT_STATE_ATTACHED)
        return USOS_PKT_ERR_STATE;
    if (frame == 0 || len < (usos_u16)USOS_PKT_FRAME_MIN ||
        len > (usos_u16)USOS_PKT_FRAME_MAX)
        return USOS_PKT_ERR_PARAM;
    head = q_get16(usos_q + Q_TXHEAD);
    tail = q_get16(usos_q + Q_TXTAIL);
    next = (usos_u16)((head + 1) & (usos_u16)(usos_tx_cnt - 1));
    if (next == tail)
        return USOS_PKT_ERR_FULL;
    slot = (usos_u16)(usos_tx_base + head * usos_tx_stride);
    usos_mem_copy(usos_q + slot + Q_SLOT_DATA, frame, len);
    q_put16(usos_q + slot + Q_SLOT_LEN, len);
    q_put16(usos_q + slot + Q_SLOT_FLAGS, 1);        /* bit 0: complete */
    q_put16(usos_q + slot + Q_SLOT_SEQ, usos_tx_seq);
    usos_tx_seq = (usos_u16)(usos_tx_seq + 1);
    q_put16(usos_q + Q_TXHEAD, next);
    rc = usos_pkt_kick();
    return rc;
}

int usos_pkt_recv(usos_u8 *frame, usos_u16 room, usos_u16 *len)
{
    usos_u16 head, tail, next, slot, slot_len, i;

    if (len != 0)
        *len = 0;
    if (usos_state != USOS_PKT_STATE_ATTACHED)
        return USOS_PKT_ERR_STATE;
    if (frame == 0 || len == 0)
        return USOS_PKT_ERR_PARAM;
    /* Poll hardware on each receive attempt, including ARP/DNS waits. A
     * count of idle-loop iterations is not a clock in STANDARD Windows. */
    usos_pkt_kick();
    head = q_get16(usos_q + Q_RXHEAD);
    tail = q_get16(usos_q + Q_RXTAIL);
    if (tail == head)
        return USOS_PKT_ERR_EMPTY;
    slot = (usos_u16)(usos_rx_base + tail * usos_rx_stride);
    slot_len = q_get16(usos_q + slot + Q_SLOT_LEN);
    next = (usos_u16)((tail + 1) & (usos_u16)(usos_rx_cnt - 1));
    if (slot_len > (usos_u16)USOS_PKT_FRAME_MAX || slot_len > room ||
        slot_len < (usos_u16)USOS_PKT_FRAME_MIN) {
        /* Over-long or runt slot: drop it and advance, or the ring wedges. */
        q_put16(usos_q + Q_RXTAIL, next);
        return USOS_PKT_ERR_PARAM;
    }
    for (i = 0; i < slot_len; i++)
        frame[i] = usos_q[slot + Q_SLOT_DATA + i];
    q_put16(usos_q + Q_RXTAIL, next);
    *len = slot_len;
    return USOS_PKT_OK;
}

void usos_pkt_poll(usos_u16 ticks)
{
    static usos_u16 accumulated = 0;

    if (usos_state != USOS_PKT_STATE_ATTACHED)
        return;
    if (ticks == 0)
        ticks = 1;
    accumulated = (usos_u16)(accumulated + ticks);
    if (accumulated >= 100) {
        /* Every ~100 ticks the driver gets a chance to flush whatever it
         * still holds; its own timer keeps the RX ring moving. */
        accumulated = 0;
        usos_pkt_kick();
    }
}

usos_u32 usos_pkt_rx_dropped(void)
{
    if (usos_q == 0)
        return 0;
    return q_get32(usos_q + Q_RXDROP);
}

usos_u32 usos_pkt_tx_dropped(void)
{
    if (usos_q == 0)
        return 0;
    return q_get32(usos_q + Q_TXERR);
}

usos_u32 usos_pkt_rx_frames(void)
{
    if (usos_q == 0)
        return 0;
    return q_get32(usos_q + Q_RXERR) + q_get32(usos_q + Q_RXDROP);
}

usos_u32 usos_pkt_tx_frames(void)
{
    if (usos_q == 0)
        return 0;
    return q_get32(usos_q + Q_TXDONE);
}

int usos_pkt_mac(usos_u8 mac[USOS_NET_ETH_ALEN])
{
    usos_u8 i;

    if (mac == 0)
        return USOS_PKT_ERR_PARAM;
    if (usos_q == 0)
        return USOS_PKT_ERR_STATE;
    for (i = 0; i < (usos_u8)USOS_NET_ETH_ALEN; i++)
        mac[i] = usos_q[Q_MAC + i];
    return USOS_PKT_OK;
}

usos_u32 usos_pkt_ip(void)
{
    return usos_local_ip;
}

void usos_pkt_set_ip(usos_u32 ip)
{
    if (ip != 0 && ip != 0xFFFFFFFFUL)
        usos_local_ip = ip;
}

usos_u32 usos_pkt_dns(void)
{
    return usos_dns_ip;
}

void usos_pkt_set_dns(usos_u32 dns)
{
    if (dns != 0 && dns != 0xFFFFFFFFUL)
        usos_dns_ip = dns;
}
