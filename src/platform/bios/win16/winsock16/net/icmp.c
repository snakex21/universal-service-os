/* icmp.c - ICMP echo only (enough for gethostbyname's reachability probe and
 * for answering an echo request from the local network).
 *
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Error messages are not generated or consumed: a blocking client learns
 * about an unreachable peer from TCP timeouts, which the ABI layer reports as
 * WSAETIMEDOUT, so no ICMP error path is wired into the socket layer.
 */

#include "net.h"

usos_u16 net_icmp_build_echo(usos_u8 *pkt, usos_u32 src, usos_u32 dst,
                             usos_u16 id, usos_u16 seq, const usos_u8 *data,
                             usos_u16 data_len)
{
    usos_u8 *msg;
    usos_u16 len;
    usos_u16 i;

    if (pkt == 0)
        return 0;
    if (data == 0 && data_len != 0)
        return 0;
    if ((usos_u32)data_len + (usos_u32)USOS_NET_ICMP_HDR >
        (usos_u32)(USOS_NET_MTU - USOS_NET_IP_HDR))
        return 0;
    msg = pkt + USOS_NET_IP_HDR;
    len = (usos_u16)(USOS_NET_ICMP_HDR + data_len);
    msg[0] = (usos_u8)USOS_ICMP_ECHO;
    msg[1] = 0;
    net_put16(msg + 2, 0);
    net_put16(msg + 4, id);
    net_put16(msg + 6, seq);
    for (i = 0; i < data_len; i++)
        msg[USOS_NET_ICMP_HDR + i] = data[i];
    net_put16(msg + 2, net_checksum(msg, len));
    return net_ip_finalize(pkt, src, dst, (usos_u8)USOS_IP_ICMP, 64,
                           net_ip_next_id(), (usos_u16)USOS_IP_DF, len);
}

/* Turn a received echo request (a bare ICMP message, header included) into an
 * echo reply addressed back to the sender. */
usos_u16 net_icmp_build_reply(usos_u8 *pkt, usos_u32 src, usos_u32 dst,
                              const usos_u8 *request, usos_u16 request_len)
{
    usos_u8 *msg;
    usos_u16 i;

    if (pkt == 0 || request == 0)
        return 0;
    if (request_len < USOS_NET_ICMP_HDR)
        return 0;
    if ((usos_u32)request_len + (usos_u32)USOS_NET_IP_HDR >
        (usos_u32)USOS_NET_MTU)
        return 0;
    msg = pkt + USOS_NET_IP_HDR;
    for (i = 0; i < request_len; i++)
        msg[i] = request[i];
    msg[0] = (usos_u8)USOS_ICMP_ECHO_REPLY;
    msg[1] = 0;
    net_put16(msg + 2, 0);
    net_put16(msg + 2, net_checksum(msg, request_len));
    return net_ip_finalize(pkt, src, dst, (usos_u8)USOS_IP_ICMP, 64,
                           net_ip_next_id(), (usos_u16)USOS_IP_DF,
                           request_len);
}

int net_icmp_echo_request(const usos_u8 *pkt, usos_u16 caplen, usos_u16 *id,
                          usos_u16 *seq)
{
    net_ip_view ip;
    const usos_u8 *msg;
    int rc;

    if (pkt == 0)
        return USOS_NET_ERR_ARG;
    rc = net_ip_parse(pkt, caplen, &ip, &msg);
    if (rc != USOS_NET_OK)
        return rc;
    if (ip.proto != (usos_u8)USOS_IP_ICMP)
        return USOS_NET_ERR_PROTO;
    if (ip.len < USOS_NET_ICMP_HDR)
        return USOS_NET_ERR_SHORT;
    if (msg[0] != (usos_u8)USOS_ICMP_ECHO || msg[1] != 0)
        return USOS_NET_ERR_PROTO;
    if (net_checksum(msg, ip.len) != 0)
        return USOS_NET_ERR_CSUM;
    if (id != 0)
        *id = net_get16(msg + 4);
    if (seq != 0)
        *seq = net_get16(msg + 6);
    return USOS_NET_OK;
}
