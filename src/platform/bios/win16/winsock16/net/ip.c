/* ip.c - Ethernet framing, the IPv4 header and dotted-quad conversion.
 *
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The provider never fragments and never reassembles: every datagram it sends
 * carries DF=1 (net_ip_build) and every fragment that arrives is rejected with
 * USOS_NET_ERR_FRAG, which the ABI layer turns into a dropped frame.  The
 * MTU is therefore fixed at USOS_NET_MTU and a caller that tries to exceed it
 * gets 0 back instead of a silently oversized frame.
 */

#include "net.h"

static usos_u16 net_ip_ids = USOS_NET_IPID_START;

usos_u16 net_ip_next_id(void)
{
    usos_u16 id = net_ip_ids;

    net_ip_ids = (usos_u16)(net_ip_ids + 1);
    if (net_ip_ids == 0)
        net_ip_ids = USOS_NET_IPID_START;
    return id;
}

void net_eth_broadcast(usos_u8 mac[USOS_NET_ETH_ALEN])
{
    usos_u8 i;

    for (i = 0; i < (usos_u8)USOS_NET_ETH_ALEN; i++)
        mac[i] = 0xFF;
}

usos_u16 net_eth_build(usos_u8 *frame, const usos_u8 dst[USOS_NET_ETH_ALEN],
                       const usos_u8 src[USOS_NET_ETH_ALEN], usos_u16 type)
{
    usos_u8 i;

    if (frame == 0 || dst == 0 || src == 0)
        return 0;
    for (i = 0; i < (usos_u8)USOS_NET_ETH_ALEN; i++) {
        frame[i] = dst[i];
        frame[USOS_NET_ETH_ALEN + i] = src[i];
    }
    net_put16(frame + 12, type);
    return USOS_NET_ETH_HDR;
}

int net_eth_parse(const usos_u8 *frame, usos_u16 caplen, usos_u16 *type,
                  const usos_u8 **payload, usos_u16 *paylen)
{
    if (frame == 0 || type == 0 || payload == 0 || paylen == 0)
        return USOS_NET_ERR_ARG;
    if (caplen < USOS_NET_ETH_HDR)
        return USOS_NET_ERR_SHORT;
    *type = net_get16(frame + 12);
    *payload = frame + USOS_NET_ETH_HDR;
    *paylen = (usos_u16)(caplen - USOS_NET_ETH_HDR);
    return USOS_NET_OK;
}

/* Fill in the IPv4 header for a payload the caller already placed at
 * pkt + USOS_NET_IP_HDR.  This is what the UDP/TCP/ICMP builders use so that
 * the payload never has to be copied twice. */
usos_u16 net_ip_finalize(usos_u8 *pkt, usos_u32 src, usos_u32 dst,
                         usos_u8 proto, usos_u8 ttl, usos_u16 id,
                         usos_u16 flags, usos_u16 paylen)
{
    usos_u16 total;

    if (pkt == 0)
        return 0;
    if ((usos_u32)paylen + (usos_u32)USOS_NET_IP_HDR > (usos_u32)USOS_NET_MTU)
        return 0;
    total = (usos_u16)(USOS_NET_IP_HDR + paylen);
    pkt[0] = 0x45;                       /* version 4, 5 words of header */
    pkt[1] = 0x00;                       /* no DSCP/ECN */
    net_put16(pkt + 2, total);
    net_put16(pkt + 4, id);
    net_put16(pkt + 6, flags);
    pkt[8] = ttl;
    pkt[9] = proto;
    net_put16(pkt + 10, 0);              /* checksum placeholder */
    net_put32(pkt + 12, src);
    net_put32(pkt + 16, dst);
    net_put16(pkt + 10, net_checksum(pkt, USOS_NET_IP_HDR));
    return total;
}

usos_u16 net_ip_build_flags(usos_u8 *pkt, usos_u32 src, usos_u32 dst,
                            usos_u8 proto, usos_u8 ttl, usos_u16 id,
                            usos_u16 flags, const usos_u8 *payload,
                            usos_u16 paylen)
{
    usos_u16 i;

    if (pkt == 0)
        return 0;
    if (payload == 0 && paylen != 0)
        return 0;
    if ((usos_u32)paylen + (usos_u32)USOS_NET_IP_HDR > (usos_u32)USOS_NET_MTU)
        return 0;
    for (i = 0; i < paylen; i++)
        pkt[USOS_NET_IP_HDR + i] = payload[i];
    return net_ip_finalize(pkt, src, dst, proto, ttl, id, flags, paylen);
}

usos_u16 net_ip_build(usos_u8 *pkt, usos_u32 src, usos_u32 dst, usos_u8 proto,
                      usos_u8 ttl, usos_u16 id, const usos_u8 *payload,
                      usos_u16 paylen)
{
    return net_ip_build_flags(pkt, src, dst, proto, ttl, id,
                              (usos_u16)USOS_IP_DF, payload, paylen);
}

int net_ip_parse(const usos_u8 *pkt, usos_u16 caplen, net_ip_view *view,
                 const usos_u8 **payload)
{
    usos_u16 hdr_len;
    usos_u16 total;
    usos_u16 frag;

    if (pkt == 0 || view == 0 || payload == 0)
        return USOS_NET_ERR_ARG;
    if (caplen < USOS_NET_IP_HDR)
        return USOS_NET_ERR_SHORT;
    if ((pkt[0] >> 4) != 4)
        return USOS_NET_ERR_VERSION;
    hdr_len = (usos_u16)((usos_u16)(pkt[0] & 0x0F) * 4);
    if (hdr_len < USOS_NET_IP_HDR || hdr_len > caplen)
        return USOS_NET_ERR_SHORT;
    total = net_get16(pkt + 2);
    if (total < hdr_len || total > caplen)
        return USOS_NET_ERR_SHORT;
    if (net_checksum(pkt, hdr_len) != 0)
        return USOS_NET_ERR_CSUM;

    frag = net_get16(pkt + 6);
    if ((frag & USOS_IP_MF) != 0 || (frag & USOS_IP_FRAG_MASK) != 0)
        return USOS_NET_ERR_FRAG;

    view->src = net_get32(pkt + 12);
    view->dst = net_get32(pkt + 16);
    view->id = net_get16(pkt + 4);
    view->flags = (usos_u16)(frag & 0xE000U);
    view->hdr_len = hdr_len;
    view->total_len = total;
    view->len = (usos_u16)(total - hdr_len);
    view->proto = pkt[9];
    view->ttl = pkt[8];
    *payload = pkt + hdr_len;
    return USOS_NET_OK;
}

/* Dotted quad in, 32-bit value in network order out; 0xFFFFFFFF (INADDR_NONE)
 * for anything that is not exactly four decimal octets.  No host-name
 * resolution here: that is gethostbyname's job (dns.c). */
usos_u32 net_inet_addr(const char *text)
{
    const char *p = text;
    usos_u32 addr = 0;
    int part;

    if (p == 0)
        return 0xFFFFFFFFUL;
    for (part = 0; part < 4; part++) {
        unsigned int value = 0;
        int digits = 0;

        while (*p >= '0' && *p <= '9') {
            value = value * 10U + (unsigned int)(*p - '0');
            if (++digits > 3 || value > 255U)
                return 0xFFFFFFFFUL;
            p++;
        }
        if (digits == 0)
            return 0xFFFFFFFFUL;
        addr = (addr << 8) | (usos_u32)value;
        if (part < 3) {
            if (*p != '.')
                return 0xFFFFFFFFUL;
            p++;
        }
    }
    if (*p != '\0')
        return 0xFFFFFFFFUL;
    return addr;
}

static char *net_put_uint(char *dst, unsigned int value)
{
    char digits[4];
    int n = 0;

    do {
        digits[n++] = (char)('0' + (int)(value % 10U));
        value /= 10U;
    } while (value != 0U && n < 3);
    while (n > 0)
        *dst++ = digits[--n];
    return dst;
}

int net_inet_ntoa(usos_u32 addr, char *buf, usos_u16 room)
{
    char *p = buf;
    int i;

    if (buf == 0 || room < 8)
        return USOS_NET_ERR_ROOM;
    for (i = 3; i >= 0; i--) {
        p = net_put_uint(p, (unsigned int)((addr >> (i * 8)) & 0xFFUL));
        if (i != 0)
            *p++ = '.';
    }
    *p = '\0';
    if ((usos_u16)(p - buf) + 1 > room)
        return USOS_NET_ERR_ROOM;
    return USOS_NET_OK;
}
