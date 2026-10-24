/* dns.c - resolver stub: one A query, responses with compressed names.
 *
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Only what gethostbyname needs: build a recursive query for an A record and
 * read the first USOS_NET_MAX_ADDRS answers out of the reply.  Name
 * compression (RFC 1035 4.1.4) is followed by the skipper below, which walks
 * labels and pointer chains with a hard bound so that a hostile packet cannot
 * spin the resolver.  No caching: a lookup is one query, retried by the
 * caller, which keeps the state out of a DLL that has no heap.
 */

#include "net.h"

#define USOS_DNS_HDR      12
#define USOS_DNS_QTYPE_A  1
#define USOS_DNS_QCLASS   1
#define USOS_DNS_LABEL    63
#define USOS_DNS_FLAG_QR  0x8000
#define USOS_DNS_FLAG_RD  0x0100

usos_u16 net_dns_encode_name(usos_u8 *buf, usos_u16 room, const char *name)
{
    usos_u16 pos = 0;

    if (buf == 0 || name == 0 || room < 2)
        return 0;
    while (*name != '\0') {
        usos_u16 label = 0;
        usos_u16 at;
        if (pos >= 254) return 0;
        at = (usos_u16)(pos + 1);

        while (name[label] != '\0' && name[label] != '.') {
            if (label == (usos_u16)USOS_DNS_LABEL)
                return 0;
            if (at + label + 2 > room || at + label + 2 > 255)
                return 0;
            buf[at + label] = (usos_u8)name[label];
            label++;
        }
        if (label == 0)
            return 0;                      /* empty label: "a..b" */
        buf[pos] = (usos_u8)label;
        pos = (usos_u16)(at + label);
        name += label;
        if (*name == '.')
            name++;
    }
    if ((usos_u16)(pos + 1) > room)
        return 0;
    buf[pos] = 0;                          /* root label */
    return (usos_u16)(pos + 1);
}

usos_u16 net_dns_build_query(usos_u8 *buf, usos_u16 room, usos_u16 id,
                             const char *name)
{
    usos_u16 qlen;
    usos_u16 total;

    if (buf == 0 || room <= (usos_u16)(USOS_DNS_HDR + 4))
        return 0;
    qlen = net_dns_encode_name(buf + USOS_DNS_HDR,
                               (usos_u16)(room - USOS_DNS_HDR - 4), name);
    if (qlen == 0)
        return 0;
    total = (usos_u16)(USOS_DNS_HDR + qlen + 4);
    if (total > room)
        return 0;
    net_put16(buf + 0, id);
    net_put16(buf + 2, (usos_u16)USOS_DNS_FLAG_RD);
    net_put16(buf + 4, 1);                 /* one question */
    net_put16(buf + 6, 0);                 /* answers */
    net_put16(buf + 8, 0);                 /* authority */
    net_put16(buf + 10, 0);                /* additional */
    net_put16(buf + USOS_DNS_HDR + qlen, (usos_u16)USOS_DNS_QTYPE_A);
    net_put16(buf + USOS_DNS_HDR + qlen + 2, (usos_u16)USOS_DNS_QCLASS);
    return total;
}

/* Offset just past the (possibly compressed) name at `off`. */
static int net_dns_skip_name(const usos_u8 *msg, usos_u16 len, usos_u16 off,
                             usos_u16 *next)
{
    usos_u16 pos = off;
    usos_u16 guard = 0;
    usos_u16 target;
    usos_u16 wire = 1;
    int jumped = 0;

    while (pos < len) {
        usos_u8 c = msg[pos];

        if (c == 0) {
            if (!jumped) *next = (usos_u16)(pos + 1);
            return USOS_NET_OK;
        }
        if ((c & 0xC0U) == 0xC0U) {
            if (len - pos < 2)
                return USOS_NET_ERR_SHORT;
            target = (usos_u16)(((usos_u16)(c & 0x3f) << 8) | msg[pos + 1]);
            if (target < USOS_DNS_HDR || target >= pos || target >= len)
                return USOS_NET_ERR_NAME;
            if (!jumped) { *next = (usos_u16)(pos + 2); jumped = 1; }
            pos = target;
            if (++guard > 256) return USOS_NET_ERR_NAME;
            continue;
        }
        if ((c & 0xC0U) != 0)
            return USOS_NET_ERR_NAME;
        if ((usos_u16)c > len - pos - 1)
            return USOS_NET_ERR_SHORT;
        if ((usos_u16)c + 1 > 255 - wire)
            return USOS_NET_ERR_NAME;
        wire = (usos_u16)(wire + c + 1);
        pos = (usos_u16)(pos + 1 + (usos_u16)c);
        if (++guard > 256)
            return USOS_NET_ERR_NAME;
    }
    return USOS_NET_ERR_SHORT;
}

int net_dns_parse_response(const usos_u8 *msg, usos_u16 len, usos_u16 id,
                           usos_u32 addrs[USOS_NET_MAX_ADDRS],
                           usos_u16 *count)
{
    usos_u16 flags;
    usos_u16 qdcount;
    usos_u16 ancount;
    usos_u16 off;
    usos_u16 i;
    usos_u16 found = 0;
    int rc;

    if (msg == 0 || addrs == 0 || count == 0)
        return USOS_NET_ERR_ARG;
    *count = 0;
    if (len < USOS_DNS_HDR)
        return USOS_NET_ERR_SHORT;
    if (net_get16(msg + 0) != id)
        return USOS_NET_ERR_ARG;
    flags = net_get16(msg + 2);
    if (!(flags & (usos_u16)USOS_DNS_FLAG_QR) || (flags & 0x7800U))
        return USOS_NET_ERR_PROTO;         /* a query, not a response */
    if (flags & 0x0200U) return USOS_NET_ERR_SHORT;
    switch (flags & 0x000FU) {
    case 0:
        break;
    case 3:
        return USOS_NET_ERR_NAME;          /* NXDOMAIN */
    default:
        return USOS_NET_ERR_RCODE;
    }
    qdcount = net_get16(msg + 4);
    ancount = net_get16(msg + 6);
    off = USOS_DNS_HDR;
    for (i = 0; i < qdcount; i++) {
        rc = net_dns_skip_name(msg, len, off, &off);
        if (rc != USOS_NET_OK)
            return rc;
        if (off > len || len - off < 4)
            return USOS_NET_ERR_SHORT;
        off = (usos_u16)(off + 4);         /* qtype + qclass */
    }
    for (i = 0; i < ancount; i++) {
        usos_u16 type;
        usos_u16 class_;
        usos_u16 rdlen;
        usos_u16 rdata;

        rc = net_dns_skip_name(msg, len, off, &off);
        if (rc != USOS_NET_OK)
            return rc;
        if (off > len || len - off < 10)
            return USOS_NET_ERR_SHORT;
        type = net_get16(msg + off);
        class_ = net_get16(msg + off + 2);
        rdlen = net_get16(msg + off + 8);
        rdata = (usos_u16)(off + 10);
        if (rdlen > len - rdata)
            return USOS_NET_ERR_SHORT;
        if (type == (usos_u16)USOS_DNS_QTYPE_A &&
            class_ == (usos_u16)USOS_DNS_QCLASS && rdlen == 4) {
            if (found < (usos_u16)USOS_NET_MAX_ADDRS)
                addrs[found] = net_get32(msg + rdata);
            found++;
        }
        off = (usos_u16)(rdata + rdlen);
    }
    if (found == 0)
        return USOS_NET_ERR_NAME;          /* no A record in the answer */
    *count = (found < (usos_u16)USOS_NET_MAX_ADDRS) ? found
                                                   : (usos_u16)USOS_NET_MAX_ADDRS;
    return USOS_NET_OK;
}
