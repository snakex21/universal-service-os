/*
 * usosnet - per-protocol frame classification, RX write-back status decode
 * and the live statistics block (0.4).
 *
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Plain C without NDIS types (like usosnet_irq.h) so tools/tests/test_usosnet.py
 * compiles it with a host compiler and USOSLOG (src/platform/bios/win9x,
 * test/x470-98se-qemu) can read the same layout.
 *
 * The statistics block lives in one 4 KiB page of shared memory. Its
 * linear address (Windows 9x: system arena, readable from Win32 there) and
 * physical address are written as UsosnetStatsVa / UsosnetStatsPa into the
 * adapter's registry key at every start; the magic is cleared at halt
 * before the page is freed. Every field is an unsigned 32-bit value.
 */
#ifndef USOSNET_PROTO_H
#define USOSNET_PROTO_H

#define USNS_MAGIC      0x534E5355UL    /* "USNS" */
#define USNS_VERSION    1UL

/* classes, one bit each; a frame can have several (UDP + DNS + BCAST) */
#define USNS_C_BCAST    0x0001UL
#define USNS_C_MCAST    0x0002UL
#define USNS_C_ARP      0x0004UL
#define USNS_C_IPV4     0x0008UL
#define USNS_C_ICMP     0x0010UL
#define USNS_C_UDP      0x0020UL
#define USNS_C_TCP      0x0040UL
#define USNS_C_DNS      0x0080UL        /* UDP or TCP, port 53 on either side */
#define USNS_C_DHCP     0x0100UL        /* UDP 67 / 68 */
#define USNS_C_HTTP     0x0200UL        /* TCP port 80 on either side */
#define USNS_C_FRAG     0x0400UL        /* IPv4 fragment (MF or offset) */
#define USNS_C_IPV6     0x0800UL
#define USNS_C_OTHER    0x1000UL        /* other EtherType / IP protocol */
#define USNS_C_SHORT    0x2000UL        /* headers cut short */
#define USNS_C_IPOPT    0x4000UL        /* IPv4 header with options */
#define USNS_C_NETBIOS  0x8000UL        /* UDP 137 / 138 */
#define USNS_CLASSES    16

/* igb advanced RX write-back, dword 2: extended status (19:0) and extended
 * error (31:20). The driver drops frames with USNS_ST_FRAME_ERR (CE SE SEQ
 * CXE RXE, the same mask as the Linux igb driver); IPE / L4E (checksum
 * errors) are only reported, never a reason to drop: the stack checks the
 * checksums itself (Windows 9x has no RX checksum offload). */
#define USNS_ST_DD      0x00000001UL
#define USNS_ST_EOP     0x00000002UL
#define USNS_ST_UDPCS   0x00000010UL    /* UDP checksum calculated */
#define USNS_ST_L4CS    0x00000020UL    /* L4 (TCP/UDP) checksum calculated */
#define USNS_ST_IPCS    0x00000040UL    /* IPv4 header checksum calculated */
#define USNS_ST_LB      0x00040000UL    /* looped back (VM to VM) */
#define USNS_ST_CE      0x01000000UL
#define USNS_ST_SE      0x02000000UL
#define USNS_ST_SEQ     0x04000000UL
#define USNS_ST_CXE     0x10000000UL
#define USNS_ST_L4E     0x20000000UL    /* TCP / UDP checksum error */
#define USNS_ST_IPE     0x40000000UL    /* IPv4 header checksum error */
#define USNS_ST_RXE     0x80000000UL
#define USNS_ST_FRAME_ERR (USNS_ST_CE | USNS_ST_SE | USNS_ST_SEQ | USNS_ST_CXE | USNS_ST_RXE)

/* drop / note counters (Drop[]) */
enum {
    USNS_D_NOT_EOP, USNS_D_CE, USNS_D_SE, USNS_D_SEQ, USNS_D_CXE, USNS_D_RXE,
    USNS_D_LEN, USNS_D_NOFILTER,                 /* drops */
    USNS_N_L4E, USNS_N_IPE, USNS_N_L4E_UDP, USNS_N_L4E_DNS, USNS_N_IPCS, USNS_N_L4CS,
    USNS_N_UDPCS, USNS_N_LB,                     /* notes on indicated frames */
    USNS_DROPS
};

/* MiniportTransferData (Td[]) */
enum {
    USNS_T_CALLS, USNS_T_NO_FRAME, USNS_T_SHORT, USNS_T_BYTES, USNS_T_MAX_OFFSET, USNS_T_MAX_LEN,
    USNS_T_UDP, USNS_T_DNS, USNS_TDS
};

/* core counters copied once a second (Core[]) */
enum {
    USNS_K_ISRCALLS, USNS_K_ISR, USNS_K_DPC, USNS_K_RXOK, USNS_K_RXTIMER, USNS_K_TXOK, USNS_K_TXDONE,
    USNS_K_TXERR, USNS_K_TXFULL, USNS_K_RXERR, USNS_K_RXCRC, USNS_K_TPR, USNS_K_GPRC, USNS_K_GPTC,
    USNS_K_MPC, USNS_K_RNBC, USNS_K_CRCERRS, USNS_K_FILTER, USNS_K_LOOKAHEAD, USNS_K_POLLMODE,
    USNS_K_LINK, USNS_K_STATUS, USNS_K_RCTL, USNS_K_RXCSUM, USNS_K_RDH, USNS_K_RDT, USNS_K_TDH,
    USNS_K_TDT, USNS_K_TXBUSY, USNS_K_LOGS, USNS_K_LOGREQ, USNS_CORES
};

#define USNS_HIST       32      /* last frames, both directions */
#define USNS_DUMP       128     /* bytes kept of the last DNS frame per direction */

/* Hist[i]: seq << 8 | dir (1 RX indicated, 2 TX, 3 RX dropped), classes,
 * src port << 16 | dst port, length, RX write-back status (TX 0),
 * peer IPv4 address (RX source, TX destination; network order bytes). */
typedef struct {
    unsigned long Magic, Version, Size, Seconds;
    unsigned long Rx[USNS_CLASSES];
    unsigned long Tx[USNS_CLASSES];
    unsigned long Drop[USNS_DROPS];
    unsigned long Td[USNS_TDS];
    unsigned long Core[USNS_CORES];
    unsigned long Seq;
    unsigned long Hist[USNS_HIST][6];
    unsigned long LastDnsRxLen, LastDnsTxLen;
    unsigned char LastDnsRx[USNS_DUMP];
    unsigned char LastDnsTx[USNS_DUMP];
} USNS_BLOCK;

/* the UDP destination port of a broadcast that asks the driver for one
 * diagnostic log round in the next second (USOSLOG sends it) */
#define USNS_LOG_PORT   0x5553          /* 21843 */

/* Ethernet frame -> classes; *Ports = src << 16 | dst, *Peer = IPv4
 * source (Rx != 0) or destination address as stored in the frame. */
static __inline unsigned long UsnsClassify(const unsigned char *F, unsigned long Len, int Rx,
                                           unsigned long *Ports, unsigned long *Peer)
{
    unsigned long c = 0, et, ihl, proto, sp, dp, off;
    const unsigned char *ip, *l4;
    *Ports = 0;
    *Peer = 0;
    if (Len < 14) return USNS_C_SHORT;
    if (F[0] & 1) {
        if ((F[0] & F[1] & F[2] & F[3] & F[4] & F[5]) == 0xFF) c |= USNS_C_BCAST;
        else c |= USNS_C_MCAST;
    }
    et = ((unsigned long)F[12] << 8) | F[13];
    if (et == 0x0806) return c | USNS_C_ARP;
    if (et == 0x86DD) return c | USNS_C_IPV6;
    if (et != 0x0800) return c | USNS_C_OTHER;
    c |= USNS_C_IPV4;
    if (Len < 34) return c | USNS_C_SHORT;
    ip = F + 14;
    ihl = (unsigned long)(ip[0] & 15) * 4;
    if ((ip[0] >> 4) != 4 || ihl < 20 || Len < 14 + ihl) return c | USNS_C_SHORT;
    if (ihl > 20) c |= USNS_C_IPOPT;
    proto = ip[9];
    off = Rx ? 12 : 16;
    *Peer = (unsigned long)ip[off] | ((unsigned long)ip[off + 1] << 8) |
            ((unsigned long)ip[off + 2] << 16) | ((unsigned long)ip[off + 3] << 24);
    if (((((unsigned long)ip[6] << 8) | ip[7]) & 0x3FFF) != 0) {
        c |= USNS_C_FRAG;
        if ((((unsigned long)ip[6] << 8) | ip[7]) & 0x1FFF) {   /* not the first fragment: no L4 header */
            if (proto == 1) return c | USNS_C_ICMP;
            if (proto == 17) return c | USNS_C_UDP;
            if (proto == 6) return c | USNS_C_TCP;
            return c | USNS_C_OTHER;
        }
    }
    if (proto == 1) return c | USNS_C_ICMP;
    if (proto != 17 && proto != 6) return c | USNS_C_OTHER;
    c |= proto == 17 ? USNS_C_UDP : USNS_C_TCP;
    if (Len < 14 + ihl + 4) return c | USNS_C_SHORT;
    l4 = ip + ihl;
    sp = ((unsigned long)l4[0] << 8) | l4[1];
    dp = ((unsigned long)l4[2] << 8) | l4[3];
    *Ports = (sp << 16) | dp;
    if (sp == 53 || dp == 53) c |= USNS_C_DNS;
    if (proto == 17 && (sp == 67 || sp == 68 || dp == 67 || dp == 68)) c |= USNS_C_DHCP;
    if (proto == 17 && (sp == 137 || sp == 138 || dp == 137 || dp == 138)) c |= USNS_C_NETBIOS;
    if (proto == 6 && (sp == 80 || dp == 80)) c |= USNS_C_HTTP;
    return c;
}

static __inline void UsnsCount(unsigned long *Ctr, unsigned long Classes)
{
    int i;
    for (i = 0; i < USNS_CLASSES; i++) if (Classes & (1UL << i)) Ctr[i]++;
}

/* RX write-back status -> 1 = drop (frame error / not one descriptor);
 * the reason and the notes are counted in Drop[]. */
static __inline int UsnsRxStatus(unsigned long *Drop, unsigned long St, unsigned long Classes)
{
    int drop = 0;
    if (!(St & USNS_ST_EOP)) { Drop[USNS_D_NOT_EOP]++; drop = 1; }
    if (St & USNS_ST_CE) { Drop[USNS_D_CE]++; drop = 1; }
    if (St & USNS_ST_SE) { Drop[USNS_D_SE]++; drop = 1; }
    if (St & USNS_ST_SEQ) { Drop[USNS_D_SEQ]++; drop = 1; }
    if (St & USNS_ST_CXE) { Drop[USNS_D_CXE]++; drop = 1; }
    if (St & USNS_ST_RXE) { Drop[USNS_D_RXE]++; drop = 1; }
    if (drop) return 1;
    if (St & USNS_ST_L4E) {
        Drop[USNS_N_L4E]++;
        if (Classes & USNS_C_UDP) Drop[USNS_N_L4E_UDP]++;
        if (Classes & USNS_C_DNS) Drop[USNS_N_L4E_DNS]++;
    }
    if (St & USNS_ST_IPE) Drop[USNS_N_IPE]++;
    if (St & USNS_ST_IPCS) Drop[USNS_N_IPCS]++;
    if (St & USNS_ST_L4CS) Drop[USNS_N_L4CS]++;
    if (St & USNS_ST_UDPCS) Drop[USNS_N_UDPCS]++;
    if (St & USNS_ST_LB) Drop[USNS_N_LB]++;
    return 0;
}

/* one history entry; Dir 1 RX, 2 TX, 3 RX dropped */
static __inline void UsnsHistory(USNS_BLOCK *S, unsigned long Dir, unsigned long Classes, unsigned long Ports,
                                 unsigned long Len, unsigned long St, unsigned long Peer)
{
    unsigned long *h = S->Hist[S->Seq % USNS_HIST];
    h[0] = (S->Seq << 8) | Dir;
    h[1] = Classes;
    h[2] = Ports;
    h[3] = Len;
    h[4] = St;
    h[5] = Peer;
    S->Seq++;
}

/* TX: a UDP broadcast to USNS_LOG_PORT asks for a log round */
static __inline int UsnsIsLogRequest(unsigned long Classes, unsigned long Ports)
{
    return (Classes & USNS_C_UDP) && (Classes & USNS_C_BCAST) && (Ports & 0xFFFF) == USNS_LOG_PORT;
}

#endif
