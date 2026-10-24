/* tcp.c - portable client TCP validation and wire-sequence state.
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
 * The socket engine owns bounded TX/RX windows and out-of-order bytes.
 * Sequence comparisons use explicit 32-bit signed differences, including
 * wraparound. net_tcp_build_at rebuilds an outstanding range without
 * rewinding snd_nxt; the latter always denotes the true sent upper edge.
 * ISNs are seeded LFSR values, not cryptographic randomness.
 * Protocol references: RFC9293 (sequence space, windows, open/close),
 * RFC6298 (initial one-second RTO and exponential backoff). This bounded
 * implementation does not yet estimate SRTT/RTTVAR or implement fast recovery.
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
    t->rcv_wnd = (usos_u16)USOS_NET_TCP_RCVWND;
    t->peer_mss = 536;
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
    t->snd_wnd = (usos_u16)USOS_NET_TCP_RCVWND;
    t->rcv_wnd = (usos_u16)USOS_NET_TCP_RCVWND;
    t->peer_mss = 536;
    return USOS_NET_OK;
}

usos_u16 net_tcp_build_at(net_tcp *t, usos_u8 *pkt, usos_u32 sequence,
                          usos_u8 flags, usos_u16 wnd,
                          const usos_u8 *data, usos_u16 data_len)
{
    usos_u8 *seg;
    usos_u16 seglen;
    usos_u16 header;
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
    header = (flags & USOS_TCP_SYN) ? 24 : USOS_NET_TCP_HDR;
    seglen = (usos_u16)(header + data_len);
    net_put16(seg + 0, t->local_port);
    net_put16(seg + 2, t->remote_port);
    net_put32(seg + 4, sequence);
    net_put32(seg + 8, (flags & (usos_u8)USOS_TCP_ACK) ? t->rcv_nxt : 0);
    seg[12] = (usos_u8)((header / 4) << 4);
    seg[13] = flags;
    net_put16(seg + 14, wnd);
    net_put16(seg + 16, 0);                /* checksum placeholder */
    net_put16(seg + 18, 0);                /* urgent pointer */
    if (header == 24) { seg[20]=2; seg[21]=4; net_put16(seg+22,USOS_NET_TCP_MSS); }
    for (i = 0; i < data_len; i++)
        seg[header + i] = data[i];
    net_put16(seg + 16, net_checksum_tcp(t->local_ip, t->remote_ip, seg,
                                         seglen));

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

usos_u16 net_tcp_build(net_tcp *t, usos_u8 *pkt, usos_u8 flags, usos_u16 wnd,
                       const usos_u8 *data, usos_u16 data_len)
{
    usos_u16 length;
    if (t == 0) return 0;
    length = net_tcp_build_at(t, pkt, t->snd_nxt, flags,
        wnd ? wnd : t->rcv_wnd, data, data_len);
    if (length) {
        t->snd_nxt += (usos_u32)data_len;
        if (flags & USOS_TCP_SYN) ++t->snd_nxt;
        if (flags & USOS_TCP_FIN) { ++t->snd_nxt; t->fin_sent = 1; }
    }
    return length;
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
    usos_u16 option, option_len;
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
    if (flags & USOS_TCP_SYN) {
        option=20;
        while (option<doff) {
            if (!seg[option]) break;
            if (seg[option]==1) { ++option; continue; }
            if (option+2>doff) return USOS_TCP_EV_BAD;
            option_len=seg[option+1];
            if (option_len<2 || option+option_len>doff) return USOS_TCP_EV_BAD;
            if (seg[option]==2 && option_len==4 && net_get16(seg+option+2)) {
                t->peer_mss=net_get16(seg+option+2);
                if (t->peer_mss>USOS_NET_TCP_MSS) t->peer_mss=USOS_NET_TCP_MSS;
            }
            option=(usos_u16)(option+option_len);
        }
    }
    if (flags_out != 0)
        *flags_out = flags;
    seq = net_get32(seg + 4);
    ack = net_get32(seg + 8);
    t->input_seq = seq;
    dlen = (usos_u16)(ip.len - doff);
    if (data != 0)
        *data = seg + doff;
    if (data_len != 0)
        *data_len = dlen;

    if (flags & (usos_u8)USOS_TCP_RST) {
        if (t->state == USOS_TCP_SYN_SENT) {
            if (!(flags & USOS_TCP_ACK) || ack != t->snd_nxt)
                return USOS_TCP_EV_IGNORE;
        } else if ((usos_s32)(seq - t->rcv_nxt) < 0 ||
                   (usos_u32)(seq - t->rcv_nxt) > t->rcv_wnd) {
            return USOS_TCP_EV_IGNORE;
        }
        t->rst = 1;
        t->state = (usos_u8)USOS_TCP_RESET;
        return USOS_TCP_EV_RST;
    }
    if (t->state == (usos_u8)USOS_TCP_CLOSED ||
        t->state == (usos_u8)USOS_TCP_RESET)
        return USOS_TCP_EV_IGNORE;

    if (t->state == USOS_TCP_LISTEN) {
        if (!(flags & USOS_TCP_SYN) || (flags & (USOS_TCP_ACK|USOS_TCP_FIN))) return USOS_TCP_EV_BAD;
        t->rcv_nxt=seq+1; t->input_seq=seq+1;
        t->snd_wnd=net_get16(seg+14); t->state=USOS_TCP_SYN_RCVD;
        return USOS_TCP_EV_SYNACK;
    }

    if (t->state == (usos_u8)USOS_TCP_SYN_SENT) {
        if (!(flags & (usos_u8)USOS_TCP_SYN) ||
            !(flags & (usos_u8)USOS_TCP_ACK))
            return USOS_TCP_EV_BAD;        /* no simultaneous open */
        if (ack != t->snd_nxt)
            return USOS_TCP_EV_BAD;        /* ACK of a SYN we did not send */
        t->input_seq = seq + 1;
        t->rcv_nxt = seq + 1 + (t->buffered_receive ? 0 : (usos_u32)dlen);
        t->snd_una = ack;
        t->snd_wnd = net_get16(seg + 14);
        t->retries = 0;
        t->state = (usos_u8)USOS_TCP_ESTABLISHED;
        return USOS_TCP_EV_SYNACK;
    }

    if (t->state == USOS_TCP_SYN_RCVD) {
        if (!(flags & USOS_TCP_ACK) || (flags & USOS_TCP_SYN) ||
            ack != t->snd_nxt || seq != t->rcv_nxt) return USOS_TCP_EV_BAD;
        t->snd_una=ack; t->snd_wnd=net_get16(seg+14); t->retries=0;
        t->state=USOS_TCP_ESTABLISHED;
        return USOS_TCP_EV_SYNACK;
    }

    /* Everything below is a state where the connection is up (or closing). */
    if (!(flags & (usos_u8)USOS_TCP_ACK))
        return USOS_TCP_EV_BAD;            /* data/ackless segment: not for us */

    if ((usos_s32)(ack - t->snd_nxt) > 0)
        return USOS_TCP_EV_BAD;            /* ACKs data we never sent */
    if ((usos_s32)(ack - t->snd_una) >= 0) {
        if (ack != t->snd_una) t->retries = 0;
        t->snd_una = ack;
        t->snd_wnd = net_get16(seg + 14);
        event = USOS_TCP_EV_ACK;
    }

    if ((flags & USOS_TCP_SYN) && seq + 1 == t->rcv_nxt)
        return USOS_TCP_EV_DUP;            /* lost final handshake ACK */

    if (t->state == (usos_u8)USOS_TCP_LAST_ACK && t->snd_una == t->snd_nxt)
        t->state = (usos_u8)USOS_TCP_CLOSED;

    if (t->buffered_receive) {
        /* ACK state above is independent of receive ordering. The caller
         * clips the segment to its ring window, stores holes, and advances
         * rcv_nxt only after contiguous bytes were retained successfully. */
        if (dlen || (flags & USOS_TCP_FIN)) return USOS_TCP_EV_DATA;
        return event;
    }

    if (dlen != 0) {
        if (seq == t->rcv_nxt) {
            t->rcv_nxt = t->rcv_nxt + (usos_u32)dlen;
            event = USOS_TCP_EV_DATA;
        } else if ((usos_s32)(seq - t->rcv_nxt) < 0) {
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
    if (t->state != (usos_u8)USOS_TCP_ESTABLISHED && t->state != USOS_TCP_CLOSE_WAIT)
        return 0;
    if (len == 0)
        return 0;
    if (len > (usos_u16)USOS_NET_TCP_MSS)
        return 0;
    if (len > t->peer_mss) return 0;
    return (usos_u32)(t->snd_nxt - t->snd_una) + len <= t->snd_wnd &&
           (usos_u32)(t->snd_nxt - t->snd_una) + len <=
               (usos_u32)USOS_NET_TCP_WINDOW * USOS_NET_TCP_MSS;
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
