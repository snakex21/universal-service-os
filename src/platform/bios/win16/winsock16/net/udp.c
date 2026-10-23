/* udp.c - UDP datagrams (RFC 768) with the IPv4 pseudo-header checksum.
 *
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The checksum is always emitted (a zero checksum on IPv4 means "not
 * computed", which some gateways do not like), but a received datagram with a
 * zero checksum is accepted as the RFC allows, and one with a wrong checksum
 * is rejected with USOS_NET_ERR_CSUM.
 */

#include "net.h"

usos_u16 net_udp_build(usos_u8 *pkt, usos_u32 src, usos_u32 dst,
                       usos_u16 sport, usos_u16 dport, const usos_u8 *data,
                       usos_u16 data_len)
{
    usos_u8 *seg;
    usos_u16 seglen;
    usos_u16 csum;
    usos_u16 i;

    if (pkt == 0)
        return 0;
    if (data == 0 && data_len != 0)
        return 0;
    if ((usos_u32)data_len + (usos_u32)USOS_NET_UDP_HDR >
        (usos_u32)(USOS_NET_MTU - USOS_NET_IP_HDR))
        return 0;
    seg = pkt + USOS_NET_IP_HDR;
    seglen = (usos_u16)(USOS_NET_UDP_HDR + data_len);
    net_put16(seg + 0, sport);
    net_put16(seg + 2, dport);
    net_put16(seg + 4, seglen);
    net_put16(seg + 6, 0);
    for (i = 0; i < data_len; i++)
        seg[USOS_NET_UDP_HDR + i] = data[i];
    csum = net_checksum_udp(src, dst, seg, seglen);
    if (csum == 0)
        csum = 0xFFFFU;                    /* 0 means "no checksum" on the wire */
    net_put16(seg + 6, csum);
    return net_ip_finalize(pkt, src, dst, (usos_u8)USOS_IP_UDP, 64,
                           net_ip_next_id(), (usos_u16)USOS_IP_DF, seglen);
}

int net_udp_parse(const usos_u8 *pkt, usos_u16 caplen, net_udp_view *view)
{
    net_ip_view ip;
    const usos_u8 *seg;
    const usos_u8 *payload;
    usos_u16 len;
    usos_u16 csum;
    int rc;

    if (pkt == 0 || view == 0)
        return USOS_NET_ERR_ARG;
    rc = net_ip_parse(pkt, caplen, &ip, &payload);
    if (rc != USOS_NET_OK)
        return rc;
    if (ip.proto != (usos_u8)USOS_IP_UDP)
        return USOS_NET_ERR_PROTO;
    if (ip.len < USOS_NET_UDP_HDR)
        return USOS_NET_ERR_SHORT;
    seg = payload;
    len = net_get16(seg + 4);
    if (len < USOS_NET_UDP_HDR || len > ip.len)
        return USOS_NET_ERR_SHORT;
    csum = net_get16(seg + 6);
    if (csum != 0 && net_checksum_udp(ip.src, ip.dst, seg, len) != 0)
        return USOS_NET_ERR_CSUM;
    view->sport = net_get16(seg + 0);
    view->dport = net_get16(seg + 2);
    view->len = len;
    view->data_len = (usos_u16)(len - USOS_NET_UDP_HDR);
    view->data = seg + USOS_NET_UDP_HDR;
    return USOS_NET_OK;
}
