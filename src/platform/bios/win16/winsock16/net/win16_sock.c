/* win16_sock.c - blocking socket engine on top of the USOSPKT queue.
 *
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * One place where frames meet sockets:
 *
 *   usos_pump()      drains the RX ring, hands ARP to the cache, IPv4 to the
 *                    TCP/UDP/ICMP demultiplexer, and ages the ARP entries
 *   usos_frame_send() ARP-resolves the next hop, writes the Ethernet header in
 *                    front of an already built IPv4 packet, TX_KICKs
 *   connect/send/recv block by pumping this loop with usos_abi_idle() between
 *                    passes - there is no select(), no WSAAsyncSelect and no
 *                    timer window: a blocking call simply owns the machine and
 *                    the default hook pumps the message queue
 *
 * All state is static (no heap): USOS_MAX_SOCKETS slots, a shared TX and RX
 * frame buffer, one ARP cache and one DNS capture buffer.  Nothing here may
 * be re-entered from an interrupt: the driver queues frames and the DLL pulls
 * them from normal context.
 */

#include "net.h"
#include "usos_pkt.h"
#include "win16_sock.h"

#define USOS_MAX_SOCKETS      4
#define USOS_EPHEMERAL_BASE   49152U
#define USOS_UDP_RX           512
#define USOS_DRAIN_LIMIT      32

#define USOS_ARP_TIMEOUT_MS   2000UL
#define USOS_DNS_TIMEOUT_MS   5000UL
#define USOS_CONNECT_MS       15000UL
#define USOS_IO_MS            20000UL
#define USOS_CLOSE_MS         2000UL
#define USOS_TCP_RTO_MS       1000UL
#define USOS_ARP_AGE_MS       1000UL

typedef struct {
    int used;
    int type;
    int connected;
    int peer_fin;
    int error;
    net_tcp tcp;
    usos_u32 raddr;
    usos_u16 lport;
    usos_u16 rport;
    usos_u16 rx_len;
    usos_u16 udp_len;
    usos_u16 tx_len;
    usos_u8  tx_flags;
    usos_u32 tx_tick;
    usos_u8  rx[USOS_NET_TCP_MSS];
    usos_u8  udp[USOS_UDP_RX];
    usos_u8  tx[USOS_NET_TCP_MSS];
} usos_sock_st;

static usos_sock_st usos_socks[USOS_MAX_SOCKETS];
static usos_u8 usos_tx_frame[USOS_NET_FRAME_MAX];
static usos_u8 usos_rx_frame[USOS_NET_FRAME_MAX];

static usos_u8  usos_our_mac[USOS_NET_ETH_ALEN];
static net_arp usos_arp;
static int     usos_ready;
static int     usos_pumping;
static usos_u16 usos_next_port = (usos_u16)USOS_EPHEMERAL_BASE;
static usos_u16 usos_dns_seq;
static usos_u32 usos_arp_age_at;

/* DNS reply capture: the resolver cannot own a socket slot (those belong to
 * the application), so it asks the UDP demultiplexer to stash the reply to its
 * private ephemeral port. */
static int      usos_capture_active;
static usos_u16 usos_capture_port;
static usos_u32 usos_capture_ip;
static usos_u16 usos_capture_len;
static usos_u8  usos_capture_buf[512];

static void usos_zero(void *dst, unsigned int len)
{
    unsigned char *p = (unsigned char *)dst;

    while (len-- != 0)
        *p++ = 0;
}

static void usos_copy(void *dst, const void *src, unsigned int len)
{
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;

    while (len-- != 0)
        *d++ = *s++;
}

static usos_sock_st *usos_slot(int slot)
{
    if (slot < 0 || slot >= USOS_MAX_SOCKETS)
        return 0;
    if (!usos_socks[slot].used)
        return 0;
    return &usos_socks[slot];
}

static usos_u16 usos_ephemeral(void)
{
    usos_u16 port = usos_next_port;

    usos_next_port = (usos_u16)(usos_next_port + 1);
    if (usos_next_port < (usos_u16)USOS_EPHEMERAL_BASE)
        usos_next_port = (usos_u16)USOS_EPHEMERAL_BASE;
    return port;
}

usos_u32 usos_sock_local_ip(void)
{
    return usos_pkt_ip();
}

int usos_sock_ready(void)
{
    return usos_ready;
}

/* ------------------------------------------------------------------ */
/* Transmit                                                            */
/* ------------------------------------------------------------------ */

static void usos_pump(void);

/* Send the IPv4 packet that already sits at usos_tx_frame + 14. */
static int usos_frame_send(usos_u32 dst_ip, usos_u16 ip_len)
{
    usos_u8 mac[USOS_NET_ETH_ALEN];
    usos_u8 request[USOS_NET_ETH_HDR + USOS_NET_ARP_LEN];
    usos_u32 deadline;
    usos_u16 n;
    /* Stage 1 uses the documented QEMU user-network configuration. Route
     * remote destinations via its gateway; ARP resolves a local next hop. */
    usos_u32 next_hop = ((dst_ip & 0xFFFFFF00UL) == (usos_pkt_ip() & 0xFFFFFF00UL))
                       ? dst_ip : 0x0A000202UL;

    if (ip_len == 0 || (usos_u16)(ip_len + USOS_NET_ETH_HDR) > USOS_NET_FRAME_MAX)
        return 0;
    if ((net_arp_lookup(&usos_arp, next_hop, mac)) == 0) {
        n = net_arp_build_request(request, &usos_arp, next_hop);
        if (n != 0)
            usos_pkt_send(request, n);
        deadline = usos_abi_now() + USOS_ARP_TIMEOUT_MS;
        for (;;) {
            usos_pump();
            if (net_arp_lookup(&usos_arp, next_hop, mac))
                break;
            if ((long)(usos_abi_now() - deadline) >= 0)
                return 0;               /* nobody answered: unreachable */
            usos_abi_idle();
        }
    }
    net_eth_build(usos_tx_frame, mac, usos_our_mac, (usos_u16)USOS_ETH_IPV4);
    return usos_pkt_send(usos_tx_frame,
                         (usos_u16)(ip_len + USOS_NET_ETH_HDR)) == USOS_PKT_OK;
}

static void usos_tx_remember(usos_sock_st *sk, usos_u8 flags, const usos_u8 *data,
                             usos_u16 len)
{
    sk->tx_flags = flags;
    sk->tx_len = len;
    if (len != 0 && data != 0)
        usos_copy(sk->tx, data, len);
    sk->tx_tick = usos_abi_now();
}

/* Rebuild and resend the outstanding segment after a timeout. */
static int usos_tx_retransmit(usos_sock_st *sk)
{
    usos_u16 n;
    int rc = net_tcp_timeout(&sk->tcp);

    if (rc == USOS_NET_ERR_TIME)
        return USOS_SOCK_ETIMEDOUT;
    if (rc != 1)
        return USOS_NET_OK;             /* nothing in flight */
    n = net_tcp_build(&sk->tcp, usos_tx_frame + USOS_NET_ETH_HDR, sk->tx_flags, 0,
                      (sk->tx_len != 0) ? sk->tx : 0, sk->tx_len);
    if (n == 0)
        return USOS_SOCK_EHOSTUNREACH;
    if (!usos_frame_send(sk->raddr, n))
        return USOS_SOCK_EHOSTUNREACH;
    sk->tx_tick = usos_abi_now();
    return USOS_NET_OK;
}

/* ------------------------------------------------------------------ */
/* Receive                                                             */
/* ------------------------------------------------------------------ */

static void usos_tcp_send_ack(usos_sock_st *sk)
{
    usos_u16 n = net_tcp_build_ack(&sk->tcp, usos_tx_frame + USOS_NET_ETH_HDR);

    if (n != 0)
        usos_frame_send(sk->raddr, n);
}

static void usos_tcp_input(usos_u8 *pkt, usos_u16 len)
{
    net_ip_view ip;
    const usos_u8 *payload;
    const usos_u8 *data;
    usos_u16 dlen;
    usos_u16 sport;
    usos_u16 dport;
    usos_u8 flags;
    int i;
    int ev;

    if (net_ip_parse(pkt, len, &ip, &payload) != USOS_NET_OK)
        return;
    if (ip.len < USOS_NET_TCP_HDR)
        return;
    sport = net_get16(payload + 0);
    dport = net_get16(payload + 2);
    for (i = 0; i < USOS_MAX_SOCKETS; i++) {
        usos_sock_st *sk = &usos_socks[i];

        if (!sk->used || sk->type != USOS_SOCK_STREAM)
            continue;
        if (sk->lport != dport || sk->rport != sport || sk->raddr != ip.src)
            continue;
        ev = net_tcp_input(&sk->tcp, pkt, len, &data, &dlen, &flags);
        switch (ev) {
        case USOS_TCP_EV_SYNACK:
            usos_tcp_send_ack(sk);
            break;
        case USOS_TCP_EV_DATA:
        case USOS_TCP_EV_FIN:
            if ((usos_u16)(sk->rx_len + dlen) <= (usos_u16)USOS_NET_TCP_MSS) {
                usos_copy(sk->rx + sk->rx_len, data, dlen);
                sk->rx_len = (usos_u16)(sk->rx_len + dlen);
            }
            if (ev == USOS_TCP_EV_FIN)
                sk->peer_fin = 1;
            usos_tcp_send_ack(sk);
            break;
        case USOS_TCP_EV_DUP:
            usos_tcp_send_ack(sk);      /* re-ACK, otherwise the peer stalls */
            break;
        case USOS_TCP_EV_RST:
            sk->error = USOS_SOCK_ECONNRESET;
            sk->connected = 0;
            break;
        default:
            break;
        }
        return;
    }
}

static void usos_udp_input(usos_u8 *pkt, usos_u16 len)
{
    net_ip_view ip;
    net_udp_view view;
    int i;

    if (net_ip_parse(pkt, len, &ip, 0) != USOS_NET_OK)
        return;
    if (net_udp_parse(pkt, len, &view) != USOS_NET_OK)
        return;
    if (usos_capture_active && ip.src == usos_capture_ip &&
        view.sport == 53 && view.dport == usos_capture_port) {
        usos_u16 n = view.data_len;

        if (n > (usos_u16)sizeof(usos_capture_buf))
            n = (usos_u16)sizeof(usos_capture_buf);
        usos_copy(usos_capture_buf, view.data, n);
        usos_capture_len = n;
    }
    for (i = 0; i < USOS_MAX_SOCKETS; i++) {
        usos_sock_st *sk = &usos_socks[i];
        usos_u16 n;

        if (!sk->used || sk->type != USOS_SOCK_DGRAM)
            continue;
        if (sk->lport != view.dport)
            continue;
        if (sk->connected && sk->raddr != ip.src)
            continue;
        n = view.data_len;
        if (n > (usos_u16)USOS_UDP_RX)
            n = (usos_u16)USOS_UDP_RX;
        usos_copy(sk->udp, view.data, n);
        sk->udp_len = n;
        return;
    }
}

static void usos_icmp_input(usos_u8 *pkt, usos_u16 len)
{
    net_ip_view ip;
    const usos_u8 *msg;
    usos_u16 id = 0;
    usos_u16 seq = 0;
    usos_u16 n;

    if (net_icmp_echo_request(pkt, len, &id, &seq) != USOS_NET_OK)
        return;
    (void)id;
    (void)seq;
    if (net_ip_parse(pkt, len, &ip, &msg) != USOS_NET_OK)
        return;
    n = net_icmp_build_reply(usos_tx_frame + USOS_NET_ETH_HDR, usos_pkt_ip(),
                             ip.src, msg, ip.len);
    if (n != 0)
        usos_frame_send(ip.src, n);
}

static void usos_eth_input(usos_u16 len)
{
    usos_u16 type = 0;
    const usos_u8 *payload = 0;
    usos_u16 paylen = 0;

    if (net_eth_parse(usos_rx_frame, len, &type, &payload, &paylen) != USOS_NET_OK)
        return;
    if (type == (usos_u16)USOS_ETH_ARP) {
        net_arp_parse(&usos_arp, usos_rx_frame, len, 0, 0, 0);
        return;
    }
    if (type != (usos_u16)USOS_ETH_IPV4)
        return;
    {
        net_ip_view ip;
        const usos_u8 *body;

        if (net_ip_parse(payload, paylen, &ip, &body) != USOS_NET_OK)
            return;
        if (ip.dst != usos_pkt_ip())
            return;                     /* not addressed to us */
        switch (ip.proto) {
        case (usos_u8)USOS_IP_TCP:
            usos_tcp_input((usos_u8 *)payload, paylen);
            break;
        case (usos_u8)USOS_IP_UDP:
            usos_udp_input((usos_u8 *)payload, paylen);
            break;
        case (usos_u8)USOS_IP_ICMP:
            usos_icmp_input((usos_u8 *)payload, paylen);
            break;
        default:
            break;
        }
    }
}

/* Drain the RX ring.  Guarded against re-entry: an ACK sent from inside the
 * demultiplexer may need an ARP resolution, which pumps this loop again. */
static void usos_pump(void)
{
    usos_u16 len;
    int guard = 0;
    int i;

    if (!usos_ready || usos_pumping)
        return;
    usos_pumping = 1;
    /* Keep at most one received segment in the socket buffer. Draining the
     * whole queue and ACKing discarded bytes would silently truncate HTTP. */
    for (i = 0; i < USOS_MAX_SOCKETS; ++i)
        if (usos_socks[i].rx_len) goto done;
    while (usos_pkt_recv(usos_rx_frame, (usos_u16)sizeof(usos_rx_frame),
                         &len) == USOS_PKT_OK) {
        usos_eth_input(len);
        for (i = 0; i < USOS_MAX_SOCKETS; ++i)
            if (usos_socks[i].rx_len) goto done;
        if (++guard >= USOS_DRAIN_LIMIT)
            break;
    }
done:
    usos_pumping = 0;
}

void usos_sock_tick(void)
{
    usos_u32 now = usos_abi_now();

    if (!usos_ready)
        return;
    usos_pump();
    usos_pkt_poll(1);
    if ((long)(now - usos_arp_age_at) >= (long)USOS_ARP_AGE_MS) {
        usos_arp_age_at = now;
        net_arp_tick(&usos_arp);
    }
}

/* ------------------------------------------------------------------ */
/* Lifecycle                                                           */
/* ------------------------------------------------------------------ */

int usos_sock_startup(void)
{
    int rc;

    if (usos_ready)
        return USOS_NET_OK;
    rc = usos_pkt_init();
    if (rc != USOS_PKT_OK)
        return USOS_SOCK_ENOTREADY;
    rc = usos_pkt_attach();
    if (rc != USOS_PKT_OK) {
        usos_pkt_term();
        return USOS_SOCK_ENOTREADY;
    }
    if (usos_pkt_mac(usos_our_mac) != USOS_PKT_OK)
        usos_zero(usos_our_mac, (unsigned int)USOS_NET_ETH_ALEN);
    net_arp_init(&usos_arp, usos_our_mac, usos_pkt_ip());
    usos_zero(usos_socks, (unsigned int)sizeof(usos_socks));
    usos_ready = 1;
    usos_arp_age_at = usos_abi_now();
    usos_next_port = (usos_u16)USOS_EPHEMERAL_BASE;
    return USOS_NET_OK;
}

void usos_sock_shutdown(void)
{
    int i;

    for (i = 0; i < USOS_MAX_SOCKETS; i++) {
        if (usos_socks[i].used)
            usos_sock_close(i);
    }
    usos_ready = 0;
    usos_pkt_term();
}

int usos_sock_open(int type)
{
    int i;

    if (!usos_ready)
        return USOS_SOCK_ENOTREADY;
    if (type != USOS_SOCK_STREAM && type != USOS_SOCK_DGRAM)
        return USOS_NET_ERR_ARG;
    for (i = 0; i < USOS_MAX_SOCKETS; i++) {
        usos_sock_st *sk = &usos_socks[i];

        if (sk->used)
            continue;
        usos_zero(sk, (unsigned int)sizeof(*sk));
        sk->used = 1;
        sk->type = type;
        sk->lport = usos_ephemeral();
        sk->rport = 0;
        sk->raddr = 0;
        if (type == USOS_SOCK_STREAM)
            net_tcp_init(&sk->tcp, ((usos_u32)sk->lport << 16) ^
                                    (usos_u32)usos_abi_now());
        return i;
    }
    return USOS_SOCK_EMFILE;
}

/* ------------------------------------------------------------------ */
/* Connect                                                             */
/* ------------------------------------------------------------------ */

int usos_sock_connect(int slot, usos_u32 ip, usos_u16 port, const char *name)
{
    usos_sock_st *sk = usos_slot(slot);
    usos_u32 deadline;
    usos_u16 n;

    if (sk == 0)
        return USOS_SOCK_ENOTSOCK;
    if (!usos_ready)
        return USOS_SOCK_ENOTREADY;
    if (sk->connected)
        return USOS_SOCK_EISCONN;
    if (name != 0) {
        usos_u32 addrs[USOS_NET_MAX_ADDRS];
        usos_u16 count = 0;

        if (usos_sock_resolve(name, addrs, &count) != USOS_NET_OK || count == 0)
            return USOS_SOCK_EHOSTUNREACH;
        ip = addrs[0];
    }
    if (ip == 0 || ip == 0xFFFFFFFFUL || port == 0)
        return USOS_NET_ERR_ARG;
    sk->raddr = ip;
    sk->rport = port;
    if (sk->type == USOS_SOCK_DGRAM) {
        sk->connected = 1;              /* UDP: latches the peer, nothing sent */
        return USOS_NET_OK;
    }
    if (net_tcp_open(&sk->tcp, usos_pkt_ip(), sk->lport, ip, port) != USOS_NET_OK)
        return USOS_NET_ERR_ARG;
    n = net_tcp_build(&sk->tcp, usos_tx_frame + USOS_NET_ETH_HDR,
                      (usos_u8)USOS_TCP_SYN, 0, 0, 0);
    if (n == 0)
        return USOS_SOCK_EHOSTUNREACH;
    usos_tx_remember(sk, (usos_u8)USOS_TCP_SYN, 0, 0);
    if (!usos_frame_send(ip, n)) {
        net_tcp_init(&sk->tcp, (usos_u32)sk->lport);
        return USOS_SOCK_EHOSTUNREACH;
    }
    deadline = usos_abi_now() + USOS_CONNECT_MS;
    for (;;) {
        int rc;

        usos_sock_tick();
        if (sk->tcp.state == (usos_u8)USOS_TCP_ESTABLISHED) {
            sk->connected = 1;
            return USOS_NET_OK;
        }
        if (sk->tcp.state == (usos_u8)USOS_TCP_RESET ||
            sk->error == USOS_SOCK_ECONNRESET)
            return USOS_SOCK_ECONNREFUSED;
        if (sk->tcp.state == (usos_u8)USOS_TCP_CLOSED)
            return USOS_SOCK_ECONNREFUSED;
        if ((long)(usos_abi_now() - deadline) >= 0)
            return USOS_SOCK_ETIMEDOUT;
        if (sk->tcp.snd_una != sk->tcp.snd_nxt &&
            (long)(usos_abi_now() - sk->tx_tick) >= (long)USOS_TCP_RTO_MS) {
            rc = usos_tx_retransmit(sk);
            if (rc != USOS_NET_OK)
                return rc;
        }
        usos_abi_idle();
    }
}

/* ------------------------------------------------------------------ */
/* Data                                                                */
/* ------------------------------------------------------------------ */

static int usos_tcp_wait_ack(usos_sock_st *sk, usos_u32 deadline)
{
    for (;;) {
        int rc;

        usos_sock_tick();
        if (sk->tcp.snd_una == sk->tcp.snd_nxt)
            return USOS_NET_OK;
        if (sk->tcp.state == (usos_u8)USOS_TCP_RESET ||
            sk->error == USOS_SOCK_ECONNRESET)
            return USOS_SOCK_ECONNRESET;
        if ((long)(usos_abi_now() - deadline) >= 0)
            return USOS_SOCK_ETIMEDOUT;
        if ((long)(usos_abi_now() - sk->tx_tick) >= (long)USOS_TCP_RTO_MS) {
            rc = usos_tx_retransmit(sk);
            if (rc != USOS_NET_OK)
                return rc;
        }
        usos_abi_idle();
    }
}

int usos_sock_send(int slot, const usos_u8 *buf, usos_u16 len)
{
    usos_sock_st *sk = usos_slot(slot);
    usos_u16 sent = 0;
    usos_u32 deadline;

    if (sk == 0)
        return USOS_SOCK_ENOTSOCK;
    if (!sk->connected)
        return USOS_SOCK_ENOTCONN;
    if (buf == 0 && len != 0)
        return USOS_NET_ERR_ARG;
    if (len == 0)
        return 0;
    deadline = usos_abi_now() + USOS_IO_MS;

    if (sk->type == USOS_SOCK_DGRAM) {
        usos_u16 n;

        if (len > (usos_u16)USOS_UDP_RX)
            return USOS_NET_ERR_ARG;
        n = net_udp_build(usos_tx_frame + USOS_NET_ETH_HDR, usos_pkt_ip(),
                          sk->raddr, sk->lport, sk->rport, buf, len);
        if (n == 0)
            return USOS_NET_ERR_ARG;
        if (!usos_frame_send(sk->raddr, n))
            return USOS_SOCK_EHOSTUNREACH;
        return (int)len;
    }

    while (sent < len) {
        usos_u16 chunk = (usos_u16)(len - sent);
        usos_u16 n;
        int rc;

        if (chunk > (usos_u16)USOS_NET_TCP_MSS)
            chunk = (usos_u16)USOS_NET_TCP_MSS;
        /* One segment in flight: wait until the previous one is acknowledged. */
        while (!net_tcp_can_send(&sk->tcp, chunk)) {
            usos_sock_tick();
            if (sk->tcp.state == (usos_u8)USOS_TCP_RESET ||
                sk->error == USOS_SOCK_ECONNRESET)
                return (sent != 0) ? (int)sent : USOS_SOCK_ECONNRESET;
            if ((long)(usos_abi_now() - deadline) >= 0)
                return (sent != 0) ? (int)sent : USOS_SOCK_ETIMEDOUT;
            if (sk->tcp.snd_una != sk->tcp.snd_nxt &&
                (long)(usos_abi_now() - sk->tx_tick) >= (long)USOS_TCP_RTO_MS) {
                rc = usos_tx_retransmit(sk);
                if (rc != USOS_NET_OK)
                    return (sent != 0) ? (int)sent : rc;
            }
            usos_abi_idle();
        }
        n = net_tcp_build(&sk->tcp, usos_tx_frame + USOS_NET_ETH_HDR,
                          (usos_u8)(USOS_TCP_ACK | USOS_TCP_PSH), 0,
                          buf + sent, chunk);
        if (n == 0)
            return (sent != 0) ? (int)sent : USOS_NET_ERR_ARG;
        usos_tx_remember(sk, (usos_u8)(USOS_TCP_ACK | USOS_TCP_PSH),
                         buf + sent, chunk);
        if (!usos_frame_send(sk->raddr, n))
            return (sent != 0) ? (int)sent : USOS_SOCK_EHOSTUNREACH;
        rc = usos_tcp_wait_ack(sk, deadline);
        if (rc != USOS_NET_OK)
            return (sent != 0) ? (int)sent : rc;
        sent = (usos_u16)(sent + chunk);
    }
    return (int)sent;
}

int usos_sock_recv(int slot, usos_u8 *buf, usos_u16 len)
{
    usos_sock_st *sk = usos_slot(slot);
    usos_u32 deadline;

    if (sk == 0)
        return USOS_SOCK_ENOTSOCK;
    if (!sk->connected)
        return USOS_SOCK_ENOTCONN;
    if (buf == 0 && len != 0)
        return USOS_NET_ERR_ARG;
    if (len == 0)
        return 0;
    deadline = usos_abi_now() + USOS_IO_MS;

    if (sk->type == USOS_SOCK_DGRAM) {
        for (;;) {
            if (sk->udp_len != 0) {
                usos_u16 n = sk->udp_len;

                if (n > len)
                    n = len;
                usos_copy(buf, sk->udp, n);
                sk->udp_len = 0;
                return (int)n;
            }
            if ((long)(usos_abi_now() - deadline) >= 0)
                return USOS_SOCK_ETIMEDOUT;
            usos_sock_tick();
            usos_abi_idle();
        }
    }

    for (;;) {
        if (sk->rx_len != 0) {
            usos_u16 n = sk->rx_len;
            usos_u16 rest;

            if (n > len)
                n = len;
            usos_copy(buf, sk->rx, n);
            rest = (usos_u16)(sk->rx_len - n);
            if (rest != 0)
                usos_copy(sk->rx, sk->rx + n, rest);
            sk->rx_len = rest;
            return (int)n;
        }
        if (sk->peer_fin)
            return 0;                   /* orderly close: EOF */
        if (sk->tcp.state == (usos_u8)USOS_TCP_RESET ||
            sk->error == USOS_SOCK_ECONNRESET)
            return USOS_SOCK_ECONNRESET;
        if ((long)(usos_abi_now() - deadline) >= 0)
            return USOS_SOCK_ETIMEDOUT;
        usos_sock_tick();
        usos_abi_idle();
    }
}

int usos_sock_close(int slot)
{
    usos_sock_st *sk = usos_slot(slot);
    usos_u32 deadline;
    usos_u16 n;

    if (sk == 0)
        return USOS_SOCK_ENOTSOCK;
    if (sk->type == USOS_SOCK_STREAM && sk->connected) {
        if (sk->tcp.state == (usos_u8)USOS_TCP_ESTABLISHED ||
            sk->tcp.state == (usos_u8)USOS_TCP_CLOSE_WAIT) {
            n = net_tcp_build_fin(&sk->tcp, usos_tx_frame + USOS_NET_ETH_HDR);
            if (n != 0) {
                usos_tx_remember(sk, (usos_u8)(USOS_TCP_ACK | USOS_TCP_FIN),
                                 0, 0);
                if (usos_frame_send(sk->raddr, n)) {
                    deadline = usos_abi_now() + USOS_CLOSE_MS;
                    (void)usos_tcp_wait_ack(sk, deadline);
                }
            }
        } else if (sk->tcp.state == (usos_u8)USOS_TCP_SYN_SENT) {
            n = net_tcp_build_rst(&sk->tcp, usos_tx_frame + USOS_NET_ETH_HDR);
            if (n != 0)
                usos_frame_send(sk->raddr, n);
        }
    }
    usos_zero(sk, (unsigned int)sizeof(*sk));
    return USOS_NET_OK;
}

int usos_sock_local(int slot, usos_u32 *ip, usos_u16 *port)
{
    usos_sock_st *sk = usos_slot(slot);

    if (sk == 0)
        return USOS_SOCK_ENOTSOCK;
    if (ip != 0)
        *ip = usos_pkt_ip();
    if (port != 0)
        *port = sk->lport;
    return USOS_NET_OK;
}

int usos_sock_remote(int slot, usos_u32 *ip, usos_u16 *port)
{
    usos_sock_st *sk = usos_slot(slot);

    if (sk == 0)
        return USOS_SOCK_ENOTSOCK;
    if (!sk->connected)
        return USOS_SOCK_ENOTCONN;
    if (ip != 0)
        *ip = sk->raddr;
    if (port != 0)
        *port = sk->rport;
    return USOS_NET_OK;
}

/* ------------------------------------------------------------------ */
/* Resolver                                                            */
/* ------------------------------------------------------------------ */

static int usos_is_numeric(const char *name)
{
    const char *p = name;

    if (p == 0 || *p == '\0')
        return 0;
    for (; *p != '\0'; p++) {
        if ((*p < '0' || *p > '9') && *p != '.')
            return 0;
    }
    return 1;
}

int usos_sock_resolve(const char *name, usos_u32 addrs[USOS_NET_MAX_ADDRS],
                      usos_u16 *count)
{
    usos_u8 query[USOS_NET_NAME_MAX];
    usos_u32 dns_ip;
    usos_u16 qlen;
    usos_u16 sport;
    usos_u16 id;
    usos_u16 n;
    int attempt;
    int rc = USOS_NET_ERR_NAME;

    if (name == 0 || addrs == 0 || count == 0)
        return USOS_NET_ERR_ARG;
    *count = 0;
    if (usos_is_numeric(name)) {
        usos_u32 ip = net_inet_addr(name);

        if (ip == 0xFFFFFFFFUL)
            return USOS_NET_ERR_NAME;
        addrs[0] = ip;
        *count = 1;
        return USOS_NET_OK;
    }
    if (!usos_ready)
        return USOS_SOCK_ENOTREADY;
    dns_ip = usos_pkt_dns();
    if (dns_ip == 0 || dns_ip == 0xFFFFFFFFUL)
        return USOS_NET_ERR_NAME;

    id = (usos_u16)(usos_abi_now() ^ ((usos_u32)usos_dns_seq << 8));
    usos_dns_seq = (usos_u16)(usos_dns_seq + 1);
    qlen = net_dns_build_query(query, (usos_u16)sizeof(query), id, name);
    if (qlen == 0)
        return USOS_NET_ERR_NAME;
    sport = usos_ephemeral();

    usos_capture_active = 1;
    usos_capture_port = sport;
    usos_capture_ip = dns_ip;
    usos_capture_len = 0;

    for (attempt = 0; attempt < 2; attempt++) {
        usos_u32 deadline;

        usos_capture_len = 0;
        n = net_udp_build(usos_tx_frame + USOS_NET_ETH_HDR, usos_pkt_ip(),
                          dns_ip, sport, 53, query, qlen);
        if (n == 0) {
            rc = USOS_NET_ERR_ARG;
            break;
        }
        if (!usos_frame_send(dns_ip, n)) {
            rc = USOS_SOCK_EHOSTUNREACH;
            break;
        }
        deadline = usos_abi_now() + USOS_DNS_TIMEOUT_MS;
        for (;;) {
            if (usos_capture_len != 0) {
                rc = net_dns_parse_response(usos_capture_buf, usos_capture_len,
                                            id, addrs, count);
                if (rc == USOS_NET_OK)
                    break;
            }
            if ((long)(usos_abi_now() - deadline) >= 0) {
                rc = USOS_SOCK_ETIMEDOUT;
                break;
            }
            usos_sock_tick();
            usos_abi_idle();
        }
        if (rc == USOS_NET_OK)
            break;
    }
    usos_capture_active = 0;
    usos_capture_len = 0;
    return rc;
}
