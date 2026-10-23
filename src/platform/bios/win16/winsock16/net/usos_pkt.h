/* usos_pkt.h - contract of the Win16 side of the USOSPKT queue driver.
 *
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * This is the only part of the provider that needs Windows and DPMI; the
 * portable engine next to it (the other sources in net/) never includes this
 * header.
 *
 * The driver (src/platform/bios/msdos/usospkt.S, branch ds/usospkt-queue) is
 * multiplexed on INT 2Fh AX=5553h:
 *
 *   BX=FFFF  query      -> AL=FFh present, ES:DI = block, CX = version,
 *                          DX = flags
 *   BX=0001  ATTACH     -> AL=0 ok, 1 no driver, 2 already owned
 *   BX=0002  GET_STATE  -> AL=0, ES:DI = block, CX = frames in RX,
 *                          DX = frames in TX
 *   BX=0003  TX_KICK    -> AL=0 sent, 1 nothing queued, 2 no client,
 *                          3 send error
 *   BX=0004  RELEASE    -> AL=0 released, 1 nothing attached
 *
 * Every call goes through DPMI INT 31h AX=0300h with a real-mode call
 * structure; the block itself is mapped once with INT 31h AX=0002h.
 * The block is only present when the driver runs with /Q.
 */

#ifndef USOS_PKT_H
#define USOS_PKT_H

#include "net.h"

/* Results */
#define USOS_PKT_OK           0
#define USOS_PKT_ERR_NODRIVER -1   /* no driver, or not started with /Q */
#define USOS_PKT_ERR_DPMI    -2    /* no DPMI host / out of descriptors */
#define USOS_PKT_ERR_BUSY    -3    /* another client owns the queue */
#define USOS_PKT_ERR_STATE   -4    /* not attached / wrong subfunction */
#define USOS_PKT_ERR_PARAM   -5    /* bad frame length */
#define USOS_PKT_ERR_EMPTY   -6    /* RX ring empty */
#define USOS_PKT_ERR_FULL    -7    /* TX ring full */
#define USOS_PKT_ERR_SEND    -8    /* the NIC refused the frame */

#define USOS_PKT_STATE_DOWN      0
#define USOS_PKT_STATE_INIT      1  /* block mapped */
#define USOS_PKT_STATE_ATTACHED  2  /* queue owned by us */

/* Frame size limits: the driver's slots are 1536 bytes, the engine's MTU is
 * 1500 and a frame is never shorter than an Ethernet header. */
#define USOS_PKT_FRAME_MIN    USOS_NET_ETH_HDR
#define USOS_PKT_FRAME_MAX    USOS_NET_FRAME_MAX

int  usos_pkt_init(void);        /* DPMI probe, block query, descriptor map */
int  usos_pkt_attach(void);      /* ATTACH: takes the queue, kills upcalls */
void usos_pkt_release(void);     /* RELEASE: back to driver-owned upcalls */
void usos_pkt_term(void);        /* release + give the DPMI resources back */
int  usos_pkt_state(void);       /* USOS_PKT_STATE_* */

int  usos_pkt_send(const usos_u8 *frame, usos_u16 len);   /* queue + TX_KICK */
int  usos_pkt_recv(usos_u8 *frame, usos_u16 room, usos_u16 *len);
void usos_pkt_poll(usos_u16 ticks);                       /* kick TX, age stats */

usos_u32 usos_pkt_rx_dropped(void);
usos_u32 usos_pkt_tx_dropped(void);
usos_u32 usos_pkt_rx_frames(void);
usos_u32 usos_pkt_tx_frames(void);
int  usos_pkt_mac(usos_u8 mac[USOS_NET_ETH_ALEN]);

/* Address configuration: milestone 2b has no DHCP client, so the provider
 * starts on the QEMU user-network defaults (guest 10.0.2.15, DNS 10.0.2.3) and
 * the caller may override both. */
usos_u32 usos_pkt_ip(void);
void     usos_pkt_set_ip(usos_u32 ip);
usos_u32 usos_pkt_dns(void);
void     usos_pkt_set_dns(usos_u32 dns);

#endif /* USOS_PKT_H */
