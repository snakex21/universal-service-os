/* tcp.c - blocking TCP client: one connection, one segment in flight.
 *
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Deliberately small, because the Win16 socket layer only needs a client:
 *
 *   CLOSED --connect--> SYN_SENT --SYN+ACK--> ESTABLISHED
 *   ESTABLISHED --peer FIN--> CLOSE_WAIT --our FIN--> LAST_ACK --ACK--> CLOSED
 *   ESTABLISHED --our close--> FIN_WAIT --peer FIN--> TIME_WAIT
 *   anything --RST--> RESET
 *
 * The send window is one segment (USOS_NET_TCP_WINDOW), so there is never more
 * than one unacknowledged segment: snd_una advances only when the peer
 * acknowledges all of snd_nxt, and net_tcp_timeout() rewinds snd_nxt to
 * snd_una so the caller can rebuild the very same segment.  Sequence numbers
 * come from a 32-bit LFSR seeded per socket, which keeps the ISN
 * unpredictable enough for an educational stack and keeps the host tests
 * deterministic.
 */

#include "net.h"

static void net_tcp_zero(net_tcp *t)
{
    usos_u8 *p = (usos_u8 *)t;
    usos_u16 i;

    for (i = 0; i < (usos_u16)sizeof(net_tcp); i++)
        p[i] = 0;
}

static usos_u32 net_tcp_lfsr(usos_u32 *state)
{
    usos_u32 v = *state;

    /* x^32 + x^31 + x^29 + x + 1, shifted down so the result stays in 32 bits */
    v = (v >> 1) ^ ((usos_u32)(0UL - (v & 1UL)) & 0xB4BCD35CUL);
    if (v == 0)
        v = 0xACE1ACE1UL;
    *state = v;
    return v;
}

void net_tcp_init(net_tcp *t, usos_u32 seed)
{
    if (t == 0)
        return;
    net_tcp_zero(t);
    t->lfsr = (seed != 0) ? seed : 0x2545F491UL;
    t->state = (usos_u8)USOS_TCP_CLOSED;
    t->ip_id = (usos_u16)USOS_NET_IPID_START;
    t->snd_wnd = (usos_u16)USOS_NET_TCP_RCVWND;
}

usos_u32 net_tcp_next_isn(net_tcp *t)
{
    usos_u32 value;

    if (t == 0)
        return 0;
    value = net_tcp_lfsr(&t->lfsr);
    value ^= t->local_ip;
    value ^= t->remote_ip;
    value ^= ((usos_u32)t->local_port << 16);
    value ^= (usos_u32)t->remote_port;
    if (value == 0)
        value = 1;
    return value;
}

int net_tcp_open(net_tcp *t, usos_u32 local_ip, usos_u16 local_port,
                 usos_u32 remote_ip, usos_u16 remote_port)
{
    if (t == 0 || local_port == 0 || remote_port == 0)
        return USOS_NET_ERR_ARG;
    net_tcp_zero(t);
    t->lfsr = ((usos_u32)local_port << 16) ^ (usos_u32)remote_port ^
              local_ip ^ 0x2545F491UL;
    if (t->lfsr == 0)
        t->lfsr = 0x2545F491UL;
    t->ip_id = (usos_u16)USOS_NET_IPID_START;
    t->local_ip = local_ip;
    t->remote_ip = remote_ip;
    t->local_port = local_port;
    t->remote_port = remote_port;
    t->iss = net_tcp_next_isn(t);
    t->snd_una = t->iss;
    t->snd_nxt = t->iss;
    t->rcv_nxt = 0;
    t->state = (usos_u8)USOS_TCP_SYN_SENT;
    t->retries = 0;
    t->fin_sent = 0;
    t->rst = 0;
    return USOS_NET_OK;
}

usos_u16 net_tcp_build(net_tcp *t, usos_u8 *pkt, usos_u8 flags, usos_u16 wnd,
                       const usos_u8 *data, usos_u16 data_len)
{
    usos_u8 *seg;
    usos_u16 seglen;
    usos_u16 i;

    if (t == 0 || pkt == 0)
        return 0;
    if (data == 0 && data_len != 0)
        return 0;
    if ((flags & (usos_u8)USOS_TCP_SYN) && data_len != 0)
        return 0;
    if ((usos_u32)data_len + (usos_u32)USOS_NET_TCP_HDR >
        (usos_u32)(USOS_NET_MTU - USOS_NET_IP_HDR))
        return 0;
    seg = pkt + USOS_NET_IP_HDR;
    seglen = (usos_u16)(USOS_NET_TCP_HDR + data_len);
    net_put16(seg + 0, t->local_port);
    net_put16(seg + 2, t->remote_port);
    net_put32(seg + 4, t->snd_nxt);
    net_put32(seg + 8, (flags & (usos_u8)USOS_TCP_ACK) ? t->rcv_nxt : 0);
    seg[12] = (usos_u8)(5 << 4);           /* data offset: 20 bytes, no options */
    seg[13] = flags;
    net_put16(seg + 14, (wnd != 0) ? wnd : (usos_u16)USOS_NET_TCP_RCVWND);
    net_put16(seg + 16, 0);                /* checksum placeholder */
    net_put16(seg + 18, 0);                /* urgent pointer */
    for (i = 0; i < data_len; i++)
        seg[USOS_NET_TCP_HDR + i] = data[i];
    net_put16(seg + 16, net_checksum_tcp(t->local_ip, t->remote_ip, seg,
                                         seglen));

    /* Advance the send sequence space.  SYN and FIN each consume one number,
     * data consumes its length; nothing is acknowledged locally. */
    if (flags & (usos_u8)USOS_TCP_SYN) {
        t->snd_nxt = t->snd_nxt + 1;
    } else {
        t->snd_nxt = t->snd_nxt + (usos_u32)data_len;
        if (flags & (usos_u8)USOS_TCP_FIN) {
            t->snd_nxt = t->snd_nxt + 1;
            t->fin_sent = 1;
        }
    }
    {
        usos_u16 id = t->ip_id;

        t->ip_id = (usos_u16)(t->ip_id + 1);
        if (t->ip_id == 0)
            t->ip_id = (usos_u16)USOS_NET_IPID_START;
        return net_ip_finalize(pkt, t->local_ip, t->remote_ip,
                               (usos_u8)USOS_IP_TCP, 64, id,
                               (usos_u16)USOS_IP_DF, seglen);
    }
}

usos_u16 net_tcp_build_ack(net_tcp *t, usos_u8 *pkt)
{
    return net_tcp_build(t, pkt, (usos_u8)USOS_TCP_ACK, 0, 0, 0);
}

usos_u16 net_tcp_build_fin(net_tcp *t, usos_u8 *pkt)
{
    usos_u16 len;

    if (t == 0)
        return 0;
    len = net_tcp_build(t, pkt, (usos_u8)(USOS_TCP_ACK | USOS_TCP_FIN), 0, 0, 0);
    if (len != 0) {
        if (t->state == (usos_u8)USOS_TCP_CLOSE_WAIT)
            t->state = (usos_u8)USOS_TCP_LAST_ACK;
        else if (t->state == (usos_u8)USOS_TCP_ESTABLISHED)
            t->state = (usos_u8)USOS_TCP_FIN_WAIT;
    }
    return len;
}

usos_u16 net_tcp_build_rst(net_tcp *t, usos_u8 *pkt)
{
    return net_tcp_build(t, pkt, (usos_u8)(USOS_TCP_RST | USOS_TCP_ACK), 0, 0, 0);
}

int net_tcp_input(net_tcp *t, const usos_u8 *pkt, usos_u16 caplen,
                  const usos_u8 **data, usos_u16 *data_len, usos_u8 *flags_out)
{
    net_ip_view ip;
    const usos_u8 *seg;
    usos_u16 doff;
    usos_u16 dlen;
    usos_u32 seq;
    usos_u32 ack;
    usos_u8 flags;
    int event = USOS_TCP_EV_NONE;
    int rc;

    if (data != 0)
        *data = 0;
    if (data_len != 0)
        *data_len = 0;
    if (flags_out != 0)
        *flags_out = 0;
    if (t == 0 || pkt == 0)
        return USOS_TCP_EV_IGNORE;
    rc = net_ip_parse(pkt, caplen, &ip, &seg);
    if (rc != USOS_NET_OK)
        return (rc == USOS_NET_ERR_CSUM) ? USOS_TCP_EV_BAD : USOS_TCP_EV_IGNORE;
    if (ip.proto != (usos_u8)USOS_IP_TCP)
        return USOS_TCP_EV_IGNORE;
    if (ip.src != t->remote_ip || ip.dst != t->local_ip)
        return USOS_TCP_EV_IGNORE;
    if (ip.len < USOS_NET_TCP_HDR)
        return USOS_TCP_EV_BAD;
    if (net_get16(seg + 0) != t->remote_port ||
        net_get16(seg + 2) != t->local_port)
        return USOS_TCP_EV_IGNORE;
    doff = (usos_u16)((usos_u16)(seg[12] >> 4) * 4);
    if (doff < USOS_NET_TCP_HDR || doff > ip.len)
        return USOS_TCP_EV_BAD;
    if (net_checksum_tcp(ip.src, ip.dst, seg, ip.len) != 0)
        return USOS_TCP_EV_BAD;
    flags = seg[13];
    if (flags_out != 0)
        *flags_out = flags;
    seq = net_get32(seg + 4);
    ack = net_get32(seg + 8);
    dlen = (usos_u16)(ip.len - doff);
    if (data != 0)
        *data = seg + doff;
    if (data_len != 0)
        *data_len = dlen;

    if (flags & (usos_u8)USOS_TCP_RST) {
        t->rst = 1;
        t->state = (usos_u8)USOS_TCP_RESET;
        t->rcv_nxt = seq + (usos_u32)dlen;
        return USOS_TCP_EV_RST;
    }
    if (t->state == (usos_u8)USOS_TCP_CLOSED ||
        t->state == (usos_u8)USOS_TCP_RESET)
        return USOS_TCP_EV_IGNORE;

    if (t->state == (usos_u8)USOS_TCP_SYN_SENT) {
        if (!(flags & (usos_u8)USOS_TCP_SYN) ||
            !(flags & (usos_u8)USOS_TCP_ACK))
            return USOS_TCP_EV_BAD;        /* no simultaneous open */
        if (ack != t->snd_nxt)
            return USOS_TCP_EV_BAD;        /* ACK of a SYN we did not send */
        t->rcv_nxt = seq + 1 + (usos_u32)dlen;
        t->snd_una = ack;
        t->snd_wnd = net_get16(seg + 14);
        t->retries = 0;
        t->state = (usos_u8)USOS_TCP_ESTABLISHED;
        return USOS_TCP_EV_SYNACK;
    }

    /* Everything below is a state where the connection is up (or closing). */
    if (!(flags & (usos_u8)USOS_TCP_ACK))
        return USOS_TCP_EV_BAD;            /* data/ackless segment: not for us */

    if ((usos_u32)(ack - t->snd_una) <= (usos_u32)(t->snd_nxt - t->snd_una)) {
        t->snd_una = ack;
        t->snd_wnd = net_get16(seg + 14);
        t->retries = 0;
        event = USOS_TCP_EV_ACK;
    } else {
        return USOS_TCP_EV_BAD;            /* ACKs data we never sent */
    }

    if (dlen != 0) {
        if (seq == t->rcv_nxt) {
            t->rcv_nxt = t->rcv_nxt + (usos_u32)dlen;
            event = USOS_TCP_EV_DATA;
        } else if ((usos_u32)(seq - t->rcv_nxt) > 0xF0000000UL) {
            return USOS_TCP_EV_DUP;        /* old retransmission: re-ACK it */
        } else {
            return USOS_TCP_EV_BAD;        /* gap: out of order, no reassembly */
        }
    }

    if (flags & (usos_u8)USOS_TCP_FIN) {
        if (seq + (usos_u32)dlen != t->rcv_nxt)
            return USOS_TCP_EV_BAD;
        t->rcv_nxt = t->rcv_nxt + 1;
        if (t->state == (usos_u8)USOS_TCP_ESTABLISHED)
            t->state = (usos_u8)USOS_TCP_CLOSE_WAIT;
        else if (t->state == (usos_u8)USOS_TCP_FIN_WAIT)
            t->state = (usos_u8)USOS_TCP_TIME_WAIT;
        return USOS_TCP_EV_FIN;
    }

    if (t->state == (usos_u8)USOS_TCP_LAST_ACK && t->snd_una == t->snd_nxt)
        t->state = (usos_u8)USOS_TCP_CLOSED;

    return event;
}

int net_tcp_can_send(const net_tcp *t, usos_u16 len)
{
    if (t == 0)
        return 0;
    if (t->state != (usos_u8)USOS_TCP_ESTABLISHED)
        return 0;
    if (len == 0)
        return 0;
    if (len > (usos_u16)USOS_NET_TCP_MSS)
        return 0;
    return t->snd_nxt == t->snd_una;       /* nothing in flight */
}

int net_tcp_timeout(net_tcp *t)
{
    if (t == 0)
        return 0;
    if (t->state == (usos_u8)USOS_TCP_CLOSED ||
        t->state == (usos_u8)USOS_TCP_RESET)
        return 0;
    if (t->snd_nxt == t->snd_una)
        return 0;                          /* nothing outstanding */
    t->retries = (usos_u8)(t->retries + 1);
    if (t->retries > (usos_u8)USOS_NET_TCP_RETRIES) {
        t->state = (usos_u8)USOS_TCP_CLOSED;
        return USOS_NET_ERR_TIME;
    }
    t->snd_nxt = t->snd_una;               /* rewind: rebuild the same segment */
    return 1;
}

int net_tcp_close(net_tcp *t)
{
    if (t == 0)
        return USOS_NET_ERR_ARG;
    if (t->state == (usos_u8)USOS_TCP_ESTABLISHED)
        return USOS_NET_OK;                /* caller sends FIN, state moves in build */
    if (t->state == (usos_u8)USOS_TCP_CLOSE_WAIT)
        return USOS_NET_OK;
    if (t->state == (usos_u8)USOS_TCP_SYN_SENT)
        return USOS_NET_OK;                /* abort: RST, no FIN */
    return USOS_NET_ERR_STATE;
}
