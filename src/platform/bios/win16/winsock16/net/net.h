/* net.h - portable IPv4/UDP/TCP/ICMP/ARP/DNS core of the USOS Win16
 * Winsock provider.
 *
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * This header and the .c files beside it are plain C89 and contain no
 * Windows, DOS, DPMI or compiler-runtime dependency whatsoever: the very same
 * sources are compiled by Open Watcom for 16-bit Windows (large model) and by
 * the host compiler for the test harness in tools/tests/win16.  Only
 * net/win16_pkt.c knows about DPMI and the USOSPKT queue block.
 *
 * Rules for everything in this directory:
 *   - no dynamic allocation: every buffer is static or owned by the caller,
 *     and every size has a name from this header,
 *   - no 32-bit "long" assumption: usos_u32 is the type that is exactly 32
 *     bits wide on both targets (see below),
 *   - no unaligned multi-byte accesses: all 16/32-bit fields go through
 *     net_get16/net_get32 and friends, which are byte-wise,
 *   - no blocking: the caller drives the state machines, time is expressed as
 *     ticks/polls, never as a wait (the Win16 layer owns the clock).
 */

#ifndef USOS_NET_H
#define USOS_NET_H

#include <limits.h>

/* ------------------------------------------------------------------ */
/* Primitive types: our own, so that the 16-bit Watcom build (32-bit    */
/* long, 16-bit int) and the 32/64-bit host build (32-bit int) agree.   */
/* ------------------------------------------------------------------ */
#if UINT_MAX == 4294967295U
typedef unsigned int usos_u32;
#else
typedef unsigned long usos_u32;
#endif
typedef unsigned short usos_u16;
typedef unsigned char usos_u8;

/* The targets are x86 (16-bit Windows on an 8086-compatible CPU and the x86
 * host harness), i.e. little endian.  net_htons() still asks at run time, see
 * net_host_little(). */

/* ------------------------------------------------------------------ */
/* Wire sizes and limits                                               */
/* ------------------------------------------------------------------ */
#define USOS_NET_ETH_HDR      14
#define USOS_NET_ETH_ALEN     6
#define USOS_NET_IP_HDR       20
#define USOS_NET_UDP_HDR      8
#define USOS_NET_TCP_HDR      20
#define USOS_NET_ICMP_HDR     8
#define USOS_NET_ARP_LEN      28
#define USOS_NET_MTU          1500
#define USOS_NET_FRAME_MAX    1514     /* eth + MTU */

#define USOS_NET_ARP_CACHE    8
#define USOS_NET_ARP_PENDING  4
#define USOS_NET_ARP_TTL      120      /* ticks (seconds) */

#define USOS_NET_MAX_ADDRS    4        /* A records kept from one DNS answer */
#define USOS_NET_NAME_MAX     256
#define USOS_NET_IPID_START   1

#define USOS_NET_TCP_MSS      (USOS_NET_MTU - USOS_NET_IP_HDR - USOS_NET_TCP_HDR)
#define USOS_NET_TCP_RETRIES  4        /* retransmissions before giving up */
#define USOS_NET_TCP_WINDOW   1        /* in segments; the window is not scaled */
#define USOS_NET_TCP_RCVWND   1024     /* what we advertise, in bytes */

/* EtherTypes */
#define USOS_ETH_IPV4         0x0800
#define USOS_ETH_ARP          0x0806

/* IP protocol numbers */
#define USOS_IP_ICMP          1
#define USOS_IP_TCP           6
#define USOS_IP_UDP           17

/* IP flags / fragment field */
#define USOS_IP_MF            0x2000
#define USOS_IP_DF            0x4000
#define USOS_IP_FRAG_MASK     0x1FFF

/* ARP opcodes */
#define USOS_ARP_REQUEST      1
#define USOS_ARP_REPLY        2

/* ICMP types */
#define USOS_ICMP_ECHO_REPLY  0
#define USOS_ICMP_ECHO        8

/* TCP flags */
#define USOS_TCP_FIN          0x01
#define USOS_TCP_SYN          0x02
#define USOS_TCP_RST          0x04
#define USOS_TCP_PSH          0x08
#define USOS_TCP_ACK          0x10
#define USOS_TCP_URG          0x20

/* TCP states (blocking client only: no listen/accept path) */
#define USOS_TCP_CLOSED       0
#define USOS_TCP_SYN_SENT     1
#define USOS_TCP_ESTABLISHED  2
#define USOS_TCP_CLOSE_WAIT   3
#define USOS_TCP_LAST_ACK     4
#define USOS_TCP_FIN_WAIT     5
#define USOS_TCP_TIME_WAIT    6
#define USOS_TCP_RESET        7

/* TCP input events */
#define USOS_TCP_EV_NONE      0
#define USOS_TCP_EV_SYNACK    1
#define USOS_TCP_EV_ACK       2
#define USOS_TCP_EV_DATA      3
#define USOS_TCP_EV_FIN       4
#define USOS_TCP_EV_RST       5
#define USOS_TCP_EV_DUP       6
#define USOS_TCP_EV_BAD       7
#define USOS_TCP_EV_IGNORE    8

/* Result codes: shared by every parser in this directory. */
#define USOS_NET_OK           0
#define USOS_NET_ERR_ARG     -1
#define USOS_NET_ERR_SHORT   -2   /* runt / truncated frame */
#define USOS_NET_ERR_VERSION -3   /* not IPv4 */
#define USOS_NET_ERR_CSUM    -4   /* header or pseudo-header checksum */
#define USOS_NET_ERR_FRAG    -5   /* fragment we do not reassemble */
#define USOS_NET_ERR_PROTO   -6   /* wrong protocol / opcode / type */
#define USOS_NET_ERR_ROOM    -7   /* caller buffer too small */
#define USOS_NET_ERR_NAME    -8   /* malformed or unsupported DNS name */
#define USOS_NET_ERR_RCODE   -9   /* DNS server said no */
#define USOS_NET_ERR_SEQ     -10  /* segment outside the window */
#define USOS_NET_ERR_STATE   -11  /* event illegal in this state */
#define USOS_NET_ERR_TIME    -12  /* retransmission budget exhausted */

/* ------------------------------------------------------------------ */
/* checksum.c - byte order and ones-complement checksums               */
/* ------------------------------------------------------------------ */
int      net_host_little(void);
usos_u16 net_swap16(usos_u16 value);
usos_u32 net_swap32(usos_u32 value);
usos_u16 net_htons(usos_u16 host);
usos_u16 net_ntohs(usos_u16 net);
usos_u32 net_htonl(usos_u32 host);
usos_u32 net_ntohl(usos_u32 net);

usos_u16 net_get16(const usos_u8 *p);
void     net_put16(usos_u8 *p, usos_u16 value);
usos_u32 net_get32(const usos_u8 *p);
void     net_put32(usos_u8 *p, usos_u32 value);

usos_u32 net_csum_add(usos_u32 sum, const usos_u8 *p, usos_u16 len);
usos_u32 net_csum_pseudo(usos_u32 src, usos_u32 dst, usos_u8 proto, usos_u16 len);
usos_u16 net_csum_finish(usos_u32 sum);
usos_u16 net_checksum(const usos_u8 *p, usos_u16 len);
usos_u16 net_checksum_udp(usos_u32 src, usos_u32 dst, const usos_u8 *seg,
                          usos_u16 len);
usos_u16 net_checksum_tcp(usos_u32 src, usos_u32 dst, const usos_u8 *seg,
                          usos_u16 len);

/* ------------------------------------------------------------------ */
/* ip.c - Ethernet framing, IPv4 header, dotted-quad conversion        */
/* ------------------------------------------------------------------ */
typedef struct {
    usos_u32 src;
    usos_u32 dst;
    usos_u16 id;
    usos_u16 flags;       /* USOS_IP_DF etc. */
    usos_u16 len;         /* payload length (total - header) */
    usos_u16 hdr_len;
    usos_u16 total_len;
    usos_u8  proto;
    usos_u8  ttl;
} net_ip_view;

usos_u16 net_eth_build(usos_u8 *frame, const usos_u8 dst[USOS_NET_ETH_ALEN],
                       const usos_u8 src[USOS_NET_ETH_ALEN], usos_u16 type);
int      net_eth_parse(const usos_u8 *frame, usos_u16 caplen, usos_u16 *type,
                       const usos_u8 **payload, usos_u16 *paylen);
void     net_eth_broadcast(usos_u8 mac[USOS_NET_ETH_ALEN]);

/* IPv4 id for the datagram builders; wraps at 0xFFFF, single-instance state. */
usos_u16 net_ip_next_id(void);
/* Finish the header for a payload the caller already wrote at pkt+20. */
usos_u16 net_ip_finalize(usos_u8 *pkt, usos_u32 src, usos_u32 dst,
                         usos_u8 proto, usos_u8 ttl, usos_u16 id,
                         usos_u16 flags, usos_u16 paylen);

usos_u16 net_ip_build(usos_u8 *pkt, usos_u32 src, usos_u32 dst, usos_u8 proto,
                      usos_u8 ttl, usos_u16 id, const usos_u8 *payload,
                      usos_u16 paylen);
usos_u16 net_ip_build_flags(usos_u8 *pkt, usos_u32 src, usos_u32 dst,
                            usos_u8 proto, usos_u8 ttl, usos_u16 id,
                            usos_u16 flags, const usos_u8 *payload,
                            usos_u16 paylen);
int      net_ip_parse(const usos_u8 *pkt, usos_u16 caplen, net_ip_view *view,
                      const usos_u8 **payload);
usos_u32 net_inet_addr(const char *text);
int      net_inet_ntoa(usos_u32 addr, char *buf, usos_u16 room);

/* ------------------------------------------------------------------ */
/* arp.c - cache, request/reply                                        */
/* ------------------------------------------------------------------ */
typedef struct {
    usos_u32 ip;
    usos_u16 age;
    usos_u8  mac[USOS_NET_ETH_ALEN];
    usos_u8  valid;
    usos_u8  pending;
} net_arp_entry;

typedef struct {
    usos_u8  mac[USOS_NET_ETH_ALEN];
    usos_u32 ip;
    net_arp_entry entry[USOS_NET_ARP_CACHE];
} net_arp;

void     net_arp_init(net_arp *cache, const usos_u8 mac[USOS_NET_ETH_ALEN],
                      usos_u32 ip);
void     net_arp_tick(net_arp *cache);
void     net_arp_learn(net_arp *cache, usos_u32 ip,
                       const usos_u8 mac[USOS_NET_ETH_ALEN]);
int      net_arp_lookup(net_arp *cache, usos_u32 ip,
                        usos_u8 mac[USOS_NET_ETH_ALEN]);
int      net_arp_pending(const net_arp *cache, usos_u32 ip);
usos_u16 net_arp_build_request(usos_u8 *frame, const net_arp *cache,
                               usos_u32 target);
usos_u16 net_arp_build_reply(usos_u8 *frame, const net_arp *cache,
                             const usos_u8 dst_mac[USOS_NET_ETH_ALEN],
                             usos_u32 dst_ip, usos_u32 my_ip);
int      net_arp_parse(net_arp *cache, const usos_u8 *frame, usos_u16 caplen,
                       usos_u16 *op, usos_u32 *sender_ip,
                       usos_u32 *sender_target_ip);

/* ------------------------------------------------------------------ */
/* udp.c                                                               */
/* ------------------------------------------------------------------ */
typedef struct {
    usos_u16 sport;
    usos_u16 dport;
    usos_u16 len;         /* UDP length field (header + data) */
    usos_u16 data_len;
    const usos_u8 *data;
} net_udp_view;

usos_u16 net_udp_build(usos_u8 *pkt, usos_u32 src, usos_u32 dst,
                       usos_u16 sport, usos_u16 dport, const usos_u8 *data,
                       usos_u16 data_len);
int      net_udp_parse(const usos_u8 *pkt, usos_u16 caplen, net_udp_view *view);

/* ------------------------------------------------------------------ */
/* icmp.c                                                              */
/* ------------------------------------------------------------------ */
usos_u16 net_icmp_build_echo(usos_u8 *pkt, usos_u32 src, usos_u32 dst,
                             usos_u16 id, usos_u16 seq, const usos_u8 *data,
                             usos_u16 data_len);
usos_u16 net_icmp_build_reply(usos_u8 *pkt, usos_u32 src, usos_u32 dst,
                              const usos_u8 *request, usos_u16 request_len);
int      net_icmp_echo_request(const usos_u8 *pkt, usos_u16 caplen, usos_u16 *id,
                               usos_u16 *seq);

/* ------------------------------------------------------------------ */
/* tcp.c - blocking client, one segment in flight                      */
/* ------------------------------------------------------------------ */
typedef struct {
    usos_u32 local_ip;
    usos_u32 remote_ip;
    usos_u32 iss;         /* initial send sequence number */
    usos_u32 snd_una;
    usos_u32 snd_nxt;
    usos_u32 rcv_nxt;
    usos_u32 lfsr;        /* ISN generator state */
    usos_u16 local_port;
    usos_u16 remote_port;
    usos_u16 snd_wnd;     /* peer's advertised window */
    usos_u16 ip_id;
    usos_u8  state;
    usos_u8  retries;
    usos_u8  fin_sent;
    usos_u8  rst;
} net_tcp;

void     net_tcp_init(net_tcp *t, usos_u32 seed);
usos_u32 net_tcp_next_isn(net_tcp *t);
int      net_tcp_open(net_tcp *t, usos_u32 local_ip, usos_u16 local_port,
                      usos_u32 remote_ip, usos_u16 remote_port);
usos_u16 net_tcp_build(net_tcp *t, usos_u8 *pkt, usos_u8 flags, usos_u16 wnd,
                       const usos_u8 *data, usos_u16 data_len);
usos_u16 net_tcp_build_ack(net_tcp *t, usos_u8 *pkt);
usos_u16 net_tcp_build_fin(net_tcp *t, usos_u8 *pkt);
usos_u16 net_tcp_build_rst(net_tcp *t, usos_u8 *pkt);
int      net_tcp_input(net_tcp *t, const usos_u8 *pkt, usos_u16 caplen,
                       const usos_u8 **data, usos_u16 *data_len,
                       usos_u8 *flags_out);
int      net_tcp_can_send(const net_tcp *t, usos_u16 len);
int      net_tcp_timeout(net_tcp *t);
int      net_tcp_close(net_tcp *t);

/* ------------------------------------------------------------------ */
/* dns.c - A queries, responses with name compression                  */
/* ------------------------------------------------------------------ */
usos_u16 net_dns_encode_name(usos_u8 *buf, usos_u16 room, const char *name);
usos_u16 net_dns_build_query(usos_u8 *buf, usos_u16 room, usos_u16 id,
                             const char *name);
int      net_dns_parse_response(const usos_u8 *msg, usos_u16 len, usos_u16 id,
                                usos_u32 addrs[USOS_NET_MAX_ADDRS],
                                usos_u16 *count);

#endif /* USOS_NET_H */
