/* checksum.c - byte order helpers and the Internet checksum (RFC 1071).
 *
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Everything here is byte-wise: a 16-bit Windows large-model build and a
 * 64-bit host build produce identical results, and no access depends on the
 * alignment of the caller's buffer (802.3 frames put the IPv4 header at
 * offset 14, i.e. the 32-bit fields are not aligned for a 386).
 */

#include "net.h"

int net_host_little(void)
{
    union {
        usos_u16 word;
        usos_u8  byte[2];
    } probe;

    probe.word = 1;
    return probe.byte[0] == 1;
}

usos_u16 net_swap16(usos_u16 value)
{
    return (usos_u16)(((usos_u16)(value << 8) & 0xFF00U) |
                      ((usos_u16)(value >> 8) & 0x00FFU));
}

usos_u32 net_swap32(usos_u32 value)
{
    return ((value & 0x000000FFUL) << 24)
         | ((value & 0x0000FF00UL) << 8)
         | ((value & 0x00FF0000UL) >> 8)
         | ((value & 0xFF000000UL) >> 24);
}

usos_u16 net_htons(usos_u16 host)
{
    return net_host_little() ? net_swap16(host) : host;
}

usos_u16 net_ntohs(usos_u16 net)
{
    return net_htons(net);
}

usos_u32 net_htonl(usos_u32 host)
{
    return net_host_little() ? net_swap32(host) : host;
}

usos_u32 net_ntohl(usos_u32 net)
{
    return net_htonl(net);
}

usos_u16 net_get16(const usos_u8 *p)
{
    return (usos_u16)(((usos_u16)p[0] << 8) | (usos_u16)p[1]);
}

void net_put16(usos_u8 *p, usos_u16 value)
{
    p[0] = (usos_u8)(value >> 8);
    p[1] = (usos_u8)(value & 0xFFU);
}

usos_u32 net_get32(const usos_u8 *p)
{
    return ((usos_u32)p[0] << 24)
         | ((usos_u32)p[1] << 16)
         | ((usos_u32)p[2] << 8)
         |  (usos_u32)p[3];
}

void net_put32(usos_u8 *p, usos_u32 value)
{
    p[0] = (usos_u8)((value >> 24) & 0xFFUL);
    p[1] = (usos_u8)((value >> 16) & 0xFFUL);
    p[2] = (usos_u8)((value >> 8) & 0xFFUL);
    p[3] = (usos_u8)(value & 0xFFUL);
}

/* Ones-complement accumulator.  A full 1500-byte frame adds at most 750
 * 16-bit words, so the 32-bit accumulator cannot wrap before the final fold
 * even with the pseudo-header term already in it. */
usos_u32 net_csum_add(usos_u32 sum, const usos_u8 *p, usos_u16 len)
{
    usos_u16 i = 0;

    if (p == 0)
        return sum;
    while ((usos_u16)(i + 1) < len) {
        sum += net_get16(p + i);
        i = (usos_u16)(i + 2);
    }
    if (i < len)
        sum += (usos_u32)((usos_u16)p[i] << 8);
    return sum;
}

usos_u32 net_csum_pseudo(usos_u32 src, usos_u32 dst, usos_u8 proto,
                         usos_u16 len)
{
    usos_u32 sum = 0;

    sum += (src >> 16) & 0xFFFFUL;
    sum += src & 0xFFFFUL;
    sum += (dst >> 16) & 0xFFFFUL;
    sum += dst & 0xFFFFUL;
    sum += (usos_u32)proto;
    sum += (usos_u32)len;
    return sum;
}

usos_u16 net_csum_finish(usos_u32 sum)
{
    while ((sum >> 16) != 0)
        sum = (sum & 0xFFFFUL) + (sum >> 16);
    return (usos_u16)(~sum & 0xFFFFUL);
}

usos_u16 net_checksum(const usos_u8 *p, usos_u16 len)
{
    return net_csum_finish(net_csum_add(0, p, len));
}

usos_u16 net_checksum_udp(usos_u32 src, usos_u32 dst, const usos_u8 *seg,
                          usos_u16 len)
{
    usos_u32 sum = net_csum_pseudo(src, dst, (usos_u8)USOS_IP_UDP, len);

    return net_csum_finish(net_csum_add(sum, seg, len));
}

usos_u16 net_checksum_tcp(usos_u32 src, usos_u32 dst, const usos_u8 *seg,
                          usos_u16 len)
{
    usos_u32 sum = net_csum_pseudo(src, dst, (usos_u8)USOS_IP_TCP, len);

    return net_csum_finish(net_csum_add(sum, seg, len));
}
