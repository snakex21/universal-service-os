/* net_harness.c - host driver for the portable USOS Winsock engine.
 *
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Built by tools/tests/win16/test_winsock16_net.py with the host compiler over
 * src/platform/bios/win16/winsock16/net/{checksum,ip,arp,udp,icmp,tcp,dns}.c.
 * Nothing here is part of the DLL: it links the very same sources the 16-bit
 * build uses and exercises them with hand-made frames, so the wire formats and
 * the TCP state machine are checked without Windows and without a network.
 *
 * Usage: net_harness <case> [file]
 * Cases: checksum ip arp udp icmp dns tcp
 * Prints "key=value" lines; exit code 0 means the case passed.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "net.h"

static int g_failures;

/* Every check prints its key so the Python side can assert on the numbers as
 * well as on the exit code; a mismatch also prints a FAIL line and forces a
 * non-zero exit. */
static void check(const char *what, long value, long expected)
{
    printf("%s=%ld\n", what, value);
    if (value != expected) {
        printf("FAIL: %s = %ld, expected %ld\n", what, value, expected);
        g_failures++;
    }
}

static void check_hex(const char *what, unsigned long value, unsigned long expected)
{
    printf("%s=0x%04lX\n", what, value);
    if (value != expected) {
        printf("FAIL: %s = 0x%04lX, expected 0x%04lX\n", what, value, expected);
        g_failures++;
    }
}

static void check_mac(const char *what, const usos_u8 *mac, const usos_u8 *expected)
{
    int i;
    int same = 1;

    for (i = 0; i < (int)USOS_NET_ETH_ALEN; i++) {
        if (mac[i] != expected[i])
            same = 0;
    }
    printf("%s=%d\n", what, same);
    if (!same) {
        for (i = 0; i < (int)USOS_NET_ETH_ALEN; i++) {
            if (mac[i] != expected[i]) {
                printf("FAIL: %s byte %d = %02X, expected %02X\n", what, i,
                       mac[i], expected[i]);
                break;
            }
        }
        g_failures++;
    }
}

/* ------------------------------------------------------------------ */
/* Synthetic frames                                                    */
/* ------------------------------------------------------------------ */

/* Build an IPv4 + TCP segment with correct checksums; returns IP length. */
static usos_u16 synth_tcp(usos_u8 *pkt, usos_u32 src, usos_u32 dst,
                          usos_u16 sport, usos_u16 dport, usos_u32 seq,
                          usos_u32 ack, usos_u8 flags, const usos_u8 *data,
                          usos_u16 data_len)
{
    usos_u8 *seg = pkt + USOS_NET_IP_HDR;
    usos_u16 seglen = (usos_u16)(USOS_NET_TCP_HDR + data_len);
    usos_u16 i;

    net_put16(seg + 0, sport);
    net_put16(seg + 2, dport);
    net_put32(seg + 4, seq);
    net_put32(seg + 8, ack);
    seg[12] = (usos_u8)(5 << 4);
    seg[13] = flags;
    net_put16(seg + 14, (usos_u16)USOS_NET_TCP_RCVWND);
    net_put16(seg + 16, 0);
    net_put16(seg + 18, 0);
    for (i = 0; i < data_len; i++)
        seg[USOS_NET_TCP_HDR + i] = data[i];
    net_put16(seg + 16, net_checksum_tcp(src, dst, seg, seglen));
    return net_ip_finalize(pkt, src, dst, (usos_u8)USOS_IP_TCP, 64, 0x4242,
                           (usos_u16)USOS_IP_DF, seglen);
}

static usos_u16 synth_udp(usos_u8 *pkt, usos_u32 src, usos_u32 dst,
                          usos_u16 sport, usos_u16 dport, const usos_u8 *data,
                          usos_u16 data_len)
{
    return net_udp_build(pkt, src, dst, sport, dport, data, data_len);
}

/* ------------------------------------------------------------------ */
/* Cases                                                               */
/* ------------------------------------------------------------------ */

static int case_checksum(void)
{
    static const usos_u8 ipv4[20] = {
        0x45, 0x00, 0x00, 0x73, 0x00, 0x00, 0x40, 0x00, 0x40, 0x11,
        0x00, 0x00, 0xC0, 0xA8, 0x00, 0x01, 0xC0, 0xA8, 0x00, 0xC7
    };
    usos_u8 pkt[USOS_NET_MTU + 64];
    usos_u16 csum;
    usos_u16 len;
    usos_u32 pseudo;

    csum = net_checksum(ipv4, 20);
    printf("ipv4_header=0x%04X\n", csum);
    check_hex("ipv4 header checksum", csum, 0xB861UL);

    /* With the checksum field filled in, the whole header must sum to zero. */
    {
        usos_u8 copy[20];

        memcpy(copy, ipv4, sizeof copy);
        net_put16(copy + 10, csum);
        printf("ipv4_header_filled=0x%04X\n", net_checksum(copy, 20));
        check_hex("filled header checksum", net_checksum(copy, 20), 0);
    }

    /* Odd length: "abc" -> 0x6162 + 0x6300. */
    {
        static const usos_u8 odd[3] = { 'a', 'b', 'c' };
        usos_u16 odd_csum = net_checksum(odd, 3);

        printf("odd=0x%04X\n", odd_csum);
        check_hex("odd length checksum", odd_csum, 0x3B9DUL);
    }

    printf("htons=0x%04X\n", net_htons(0x1234));
    check_hex("htons", net_htons(0x1234), 0x3412UL);
    printf("htonl=0x%08lX\n", (unsigned long)net_htonl(0x12345678UL));
    check("htonl ok", (long)net_htonl(0x12345678UL) == 0x78563412UL, 1);
    check("roundtrip16", (long)net_ntohs(net_htons(0xBEEF)), (long)0xBEEF);
    check("roundtrip32", (long)(net_ntohl(net_htonl(0xDEADBEEFUL)) == 0xDEADBEEFUL), 1);

    /* Pseudo-header term: src 192.168.0.1, dst 192.168.0.2, UDP, len 13. */
    pseudo = net_csum_pseudo(0xC0A80001UL, 0xC0A80002UL, (usos_u8)USOS_IP_UDP, 13);
    printf("pseudo=0x%08lX\n", (unsigned long)(net_csum_finish(pseudo) & 0xFFFFUL));

    len = synth_udp(pkt, 0xC0A80001UL, 0xC0A80002UL, 1234, 80,
                    (const usos_u8 *)"hello", 5);
    check("udp build len", (long)len, 20 + 8 + 5);
    csum = net_get16(pkt + USOS_NET_IP_HDR + 6);
    printf("udp_csum=0x%04X\n", csum);
    check("udp checksum self-check",
          (long)(net_checksum_udp(0xC0A80001UL, 0xC0A80002UL,
                                  pkt + USOS_NET_IP_HDR, 13) == 0), 1);
    check_hex("ip header in built udp", net_checksum(pkt, USOS_NET_IP_HDR), 0);

    len = synth_tcp(pkt, 0xC0A80001UL, 0xC0A80002UL, 40000, 80, 0x11223344UL,
                    0, (usos_u8)USOS_TCP_SYN, 0, 0);
    check("tcp build len", (long)len, 40);
    check("tcp checksum self-check",
          (long)(net_checksum_tcp(0xC0A80001UL, 0xC0A80002UL,
                                  pkt + USOS_NET_IP_HDR, 20) == 0), 1);
    printf("tcp_csum=0x%04X\n", net_get16(pkt + USOS_NET_IP_HDR + 16));
    return g_failures;
}

static int case_ip(void)
{
    usos_u8 pkt[USOS_NET_MTU + 64];
    net_ip_view view;
    const usos_u8 *payload;
    usos_u16 len;
    int rc;

    len = net_udp_build(pkt, 0xC0A80001UL, 0xC0A80002UL, 1024, 53,
                        (const usos_u8 *)"hello", 5);
    memset(&view, 0, sizeof view);
    rc = net_ip_parse(pkt, len, &view, &payload);
    printf("parse=%d\n", rc);
    check("ip parse", rc, USOS_NET_OK);
    check("version", (long)(pkt[0] >> 4), 4);
    check("df", (long)((net_get16(pkt + 6) & USOS_IP_DF) != 0), 1);
    check("mf clear", (long)((net_get16(pkt + 6) & USOS_IP_MF) != 0), 0);
    check("proto", view.proto, USOS_IP_UDP);
    check("total", view.total_len, 33);
    check("hdr", view.hdr_len, 20);
    check("payload", view.len, 13);
    check("src", (long)(view.src == 0xC0A80001UL), 1);
    check("dst", (long)(view.dst == 0xC0A80002UL), 1);
    check("payload pointer", (long)(payload == pkt + 20), 1);
    check("payload offset", (long)(payload[0] == 0x04 && payload[1] == 0x00), 1);
    check("optional payload output", net_ip_parse(pkt, len, &view, 0), USOS_NET_OK);

    /* Rejections. */
    {
        usos_u8 broken[64];

        memcpy(broken, pkt, len);
        broken[0] = 0x65;                       /* version 6 */
        check("bad version", net_ip_parse(broken, len, &view, &payload),
              USOS_NET_ERR_VERSION);

        memcpy(broken, pkt, len);
        broken[10] ^= 0xFF;                     /* corrupt header checksum */
        check("bad checksum", net_ip_parse(broken, len, &view, &payload),
              USOS_NET_ERR_CSUM);

        memcpy(broken, pkt, len);
        net_put16(broken + 6, USOS_IP_MF);      /* more fragments */
        net_put16(broken + 10, 0);
        net_put16(broken + 10, net_checksum(broken, 20));
        check("mf fragment", net_ip_parse(broken, len, &view, &payload),
              USOS_NET_ERR_FRAG);

        memcpy(broken, pkt, len);
        net_put16(broken + 6, 0x0010);          /* fragment offset 2 */
        net_put16(broken + 10, 0);
        net_put16(broken + 10, net_checksum(broken, 20));
        check("offset fragment", net_ip_parse(broken, len, &view, &payload),
              USOS_NET_ERR_FRAG);

        check("runt", net_ip_parse(pkt, 10, &view, &payload), USOS_NET_ERR_SHORT);
        check("len beyond capture",
              net_ip_parse(pkt, (usos_u16)(len - 1), &view, &payload),
              USOS_NET_ERR_SHORT);
    }

    /* Dotted-quad conversion. */
    check("inet_addr", (long)(net_inet_addr("192.168.0.1") == 0xC0A80001UL), 1);
    check("inet_addr none", (long)(net_inet_addr("192.168.0.256") == 0xFFFFFFFFUL), 1);
    check("inet_addr junk", (long)(net_inet_addr("a.b.c.d") == 0xFFFFFFFFUL), 1);
    {
        char text[16];
        int nrc = net_inet_ntoa(0xC0A80001UL, text, (usos_u16)sizeof text);

        printf("ntoa=%s\n", text);
        check("inet_ntoa", nrc, USOS_NET_OK);
        check("inet_ntoa text", strcmp(text, "192.168.0.1"), 0);
    }

    /* Ethernet framing. */
    {
        static const usos_u8 dst[6] = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
        static const usos_u8 src[6] = { 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
        usos_u8 frame[64];
        usos_u16 type = 0;
        const usos_u8 *body = 0;
        usos_u16 body_len = 0;

        check("eth build", net_eth_build(frame, dst, src, (usos_u16)USOS_ETH_IPV4),
              USOS_NET_ETH_HDR);
        check("eth parse", net_eth_parse(frame, 14, &type, &body, &body_len),
              USOS_NET_OK);
        check("eth type", type, USOS_ETH_IPV4);
        check("eth body len", body_len, 0);
        check_mac("eth dst", frame, dst);
    }
    return g_failures;
}

static int case_arp(void)
{
    static const usos_u8 mac[6] = { 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
    static const usos_u8 peer[6] = { 0x02, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE };
    static const usos_u8 broadcast[6] = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    static const usos_u8 zero[6] = { 0, 0, 0, 0, 0, 0 };
    net_arp cache;
    usos_u8 frame[64];
    usos_u8 reply[64];
    usos_u8 found[6];
    usos_u16 len;
    usos_u16 op = 0;
    usos_u32 sender = 0;
    usos_u32 target = 0;
    int i;

    net_arp_init(&cache, mac, 0x0A00020FUL);
    len = net_arp_build_request(frame, &cache, 0x0A000203UL);
    printf("request_len=%u\n", len);
    check("arp request len", len, USOS_NET_ETH_HDR + USOS_NET_ARP_LEN);
    check_mac("arp dst", frame, broadcast);
    check("arp ethertype", net_get16(frame + 12), USOS_ETH_ARP);
    check("arp htype", net_get16(frame + 14), 1);
    check("arp ptype", net_get16(frame + 16), USOS_ETH_IPV4);
    check("arp hlen", frame[18], 6);
    check("arp plen", frame[19], 4);
    check("arp op", net_get16(frame + 20), USOS_ARP_REQUEST);
    check_mac("arp sha", frame + 22, mac);
    check("arp spa", (long)(net_get32(frame + 28) == 0x0A00020FUL), 1);
    check_mac("arp tha", frame + 32, zero);
    check("arp tpa", (long)(net_get32(frame + 38) == 0x0A000203UL), 1);

    /* A reply from the peer teaches the cache. */
    net_arp_init(&cache, mac, 0x0A00020FUL);
    len = net_arp_build_reply(reply, &cache, peer, 0x0A00020FUL, 0x0A000203UL);
    check("arp reply len", len, USOS_NET_ETH_HDR + USOS_NET_ARP_LEN);
    check_mac("arp reply dst", reply, peer);
    check("arp reply op", net_get16(reply + 20), USOS_ARP_REPLY);
    check("arp parse", net_arp_parse(&cache, reply, len, &op, &sender, &target),
          USOS_NET_OK);
    check("parsed op", op, USOS_ARP_REPLY);
    check("parsed sender", (long)(sender == 0x0A000203UL), 1);
    check("lookup hit", net_arp_lookup(&cache, 0x0A000203UL, found), 1);
    check_mac("learned mac", found, mac);

    /* Unknown address: miss, and a pending request is recorded once. */
    net_arp_init(&cache, mac, 0x0A00020FUL);
    check("unknown miss", net_arp_lookup(&cache, 0x0A000099UL, found), 0);
    check("unknown pending", net_arp_pending(&cache, 0x0A000099UL), 1);

    /* Ageing: 121 ticks drop the entry. */
    net_arp_init(&cache, mac, 0x0A00020FUL);
    net_arp_learn(&cache, 0x0A000203UL, peer);
    for (i = 0; i < (int)USOS_NET_ARP_TTL + 1; i++)
        net_arp_tick(&cache);
    check("expired", net_arp_lookup(&cache, 0x0A000203UL, found), 0);

    /* A non-ARP frame is rejected. */
    frame[12] = 0x08;
    frame[13] = 0x00;
    check("arp wrong type", net_arp_parse(&cache, frame, 14, 0, 0, 0),
          USOS_NET_ERR_PROTO);
    return g_failures;
}

static int case_udp(void)
{
    usos_u8 pkt[USOS_NET_MTU];
    net_udp_view view;
    usos_u16 len;

    len = net_udp_build(pkt, 0xC0A80001UL, 0xC0A80002UL, 1234, 80,
                        (const usos_u8 *)"hello", 5);
    check("udp len", len, 33);
    check("udp parse", net_udp_parse(pkt, len, &view), USOS_NET_OK);
    check("udp sport", view.sport, 1234);
    check("udp dport", view.dport, 80);
    check("udp field len", view.len, 13);
    check("udp data len", view.data_len, 5);
    check("udp data", strncmp((const char *)view.data, "hello", 5), 0);

    pkt[USOS_NET_IP_HDR + 6] ^= 0x5A;          /* corrupt the checksum */
    check("udp bad checksum", net_udp_parse(pkt, len, &view), USOS_NET_ERR_CSUM);
    pkt[USOS_NET_IP_HDR + 6] = 0;              /* 0 = "not computed": allowed */
    pkt[USOS_NET_IP_HDR + 7] = 0;
    check("udp zero checksum", net_udp_parse(pkt, len, &view), USOS_NET_OK);

    /* Over-long payload: refused rather than truncated. */
    check("udp oversize",
          net_udp_build(pkt, 0xC0A80001UL, 0xC0A80002UL, 1, 2,
                        (const usos_u8 *)"x", (usos_u16)(USOS_NET_MTU)),
          0);
    return g_failures;
}

static int case_icmp(void)
{
    usos_u8 pkt[USOS_NET_MTU];
    usos_u8 reply[USOS_NET_MTU];
    net_ip_view view;
    const usos_u8 *msg;
    usos_u16 len;
    usos_u16 rlen;
    usos_u16 id = 0;
    usos_u16 seq = 0;

    len = net_icmp_build_echo(pkt, 0xC0A80001UL, 0xC0A80002UL, 0x1234, 7,
                              (const usos_u8 *)"ping", 4);
    check("icmp echo len", len, 20 + 8 + 4);
    check("icmp is request", net_icmp_echo_request(pkt, len, &id, &seq),
          USOS_NET_OK);
    check("icmp id", id, 0x1234);
    check("icmp seq", seq, 7);
    check("icmp parse", net_ip_parse(pkt, len, &view, &msg), USOS_NET_OK);
    check("icmp proto", view.proto, USOS_IP_ICMP);
    check("icmp type", msg[0], USOS_ICMP_ECHO);

    rlen = net_icmp_build_reply(reply, 0xC0A80002UL, 0xC0A80001UL, msg, view.len);
    check("icmp reply len", rlen, len);
    check("icmp reply parse", net_ip_parse(reply, rlen, &view, &msg), USOS_NET_OK);
    check("icmp reply type", msg[0], USOS_ICMP_ECHO_REPLY);
    check("icmp reply id", net_get16(msg + 4), 0x1234);
    check("icmp reply data", strncmp((const char *)msg + 8, "ping", 4), 0);
    check("icmp reply checksum", net_checksum(msg, view.len), 0);

    /* A request with a corrupt checksum must not be answered. */
    pkt[USOS_NET_IP_HDR + 2] ^= 0xFF;
    check("icmp bad checksum", net_icmp_echo_request(pkt, len, &id, &seq),
          USOS_NET_ERR_CSUM);
    return g_failures;
}

static int case_dns(int argc, char **argv)
{
    usos_u8 query[512];
    usos_u16 qlen;
    usos_u32 addrs[USOS_NET_MAX_ADDRS];
    usos_u16 count = 0;
    int i;

    qlen = net_dns_build_query(query, (usos_u16)sizeof query, 0x1234, "68k.news");
    printf("query_len=%u\n", qlen);
    printf("query_hex=");
    for (i = 0; i < (int)qlen; i++)
        printf("%02X", query[i]);
    printf("\n");
    check("dns query len", (long)qlen, 12 + 10 + 4);

    if (argc < 3) {
        printf("FAIL: dns case needs a response file\n");
        return 1;
    }
    {
        FILE *fp = fopen(argv[2], "rb");
        usos_u8 response[512];
        size_t n;

        if (fp == 0) {
            printf("FAIL: cannot open %s\n", argv[2]);
            return 1;
        }
        n = fread(response, 1, sizeof response, fp);
        fclose(fp);
        printf("response_len=%u\n", (unsigned)n);
        check("dns parse", net_dns_parse_response(response, (usos_u16)n, 0x1234,
                                                  addrs, &count), USOS_NET_OK);
        check("dns count", count, 1);
        {
            char text[16];

            net_inet_ntoa(addrs[0], text, (usos_u16)sizeof text);
            printf("addr=%s\n", text);
        }
        /* Wrong id and NXDOMAIN must be refused. */
        net_put16(response + 0, 0x9999);
        check("dns wrong id",
              net_dns_parse_response(response, (usos_u16)n, 0x1234, addrs, &count),
              USOS_NET_ERR_ARG);
        net_put16(response + 0, 0x1234);
        net_put16(response + 2, (usos_u16)(net_get16(response + 2) | 0x0003));
        check("dns nxdomain",
              net_dns_parse_response(response, (usos_u16)n, 0x1234, addrs, &count),
              USOS_NET_ERR_NAME);
    }
    return g_failures;
}

static int case_tcp(void)
{
    net_tcp client;
    net_tcp other;
    usos_u8 pkt[USOS_NET_MTU];
    const usos_u8 *data = 0;
    usos_u16 dlen = 0;
    usos_u8 flags = 0;
    usos_u16 len;
    usos_u32 cip = 0xC0A80002UL;
    usos_u32 sip = 0xC0A80001UL;
    usos_u16 cport = 40000;
    usos_u16 sport = 80;
    usos_u32 c_isn;
    usos_u32 s_isn = 0x5000UL;
    int ev;

    net_tcp_init(&client, 0x12345678UL);
    net_tcp_init(&other, 0x87654321UL);
    check("isn differs", (long)(net_tcp_next_isn(&client) != net_tcp_next_isn(&other)), 1);

    check("tcp open", net_tcp_open(&client, cip, cport, sip, sport), USOS_NET_OK);
    c_isn = client.iss;
    printf("isn=0x%08lX\n", (unsigned long)c_isn);
    check("iss nonzero", (long)(c_isn != 0), 1);
    check("state syn_sent", client.state, USOS_TCP_SYN_SENT);

    len = net_tcp_build(&client, pkt, (usos_u8)USOS_TCP_SYN, 0, 0, 0);
    check("syn len", len, 44);
    check("syn seq", (long)(net_get32(pkt + 24) == c_isn), 1);
    check("syn flags", pkt[33], USOS_TCP_SYN);
    check("syn snd_nxt", (long)(client.snd_nxt == c_isn + 1), 1);
    check("syn snd_una", (long)(client.snd_una == c_isn), 1);
    check("syn port", net_get16(pkt + 20), cport);
    check("syn checksum", net_checksum_tcp(cip, sip, pkt + 20, 24), 0);
    check("syn mss option", net_get16(pkt+42), USOS_NET_TCP_MSS);
    check("cannot send in syn_sent", net_tcp_can_send(&client, 10), 0);

    /* SYN/ACK from the server. */
    len = synth_tcp(pkt, sip, cip, sport, cport, s_isn, c_isn + 1,
                    (usos_u8)(USOS_TCP_SYN | USOS_TCP_ACK), 0, 0);
    ev = net_tcp_input(&client, pkt, len, &data, &dlen, &flags);
    printf("synack_ev=%d\n", ev);
    check("synack event", ev, USOS_TCP_EV_SYNACK);
    check("synack state", client.state, USOS_TCP_ESTABLISHED);
    check("synack rcv_nxt", (long)(client.rcv_nxt == s_isn + 1), 1);
    check("synack snd_una", (long)(client.snd_una == c_isn + 1), 1);
    check("synack window", client.snd_wnd, USOS_NET_TCP_RCVWND);

    /* The ACK that completes the handshake. */
    len = net_tcp_build_ack(&client, pkt);
    check("ack len", len, 40);
    check("ack flags", pkt[33], USOS_TCP_ACK);
    check("ack seq", (long)(net_get32(pkt + 24) == c_isn + 1), 1);
    check("ack ack", (long)(net_get32(pkt + 28) == s_isn + 1), 1);
    check("ack snd_nxt unchanged", (long)(client.snd_nxt == c_isn + 1), 1);
    check("ack checksum", net_checksum_tcp(cip, sip, pkt + 20, 20), 0);

    /* A second segment fits without waiting for the first one's ACK. */
    check("can send", net_tcp_can_send(&client, 100), 1);
    len = net_tcp_build(&client, pkt, (usos_u8)(USOS_TCP_ACK | USOS_TCP_PSH), 0,
                        (const usos_u8 *)"GET / HTTP/1.0\r\n\r\n", 18);
    check("data len", len, 58);
    check("data seq", (long)(net_get32(pkt + 24) == c_isn + 1), 1);
    check("data ack", (long)(net_get32(pkt + 28) == s_isn + 1), 1);
    check("data snd_nxt", (long)(client.snd_nxt == c_isn + 1 + 18), 1);
    check("in flight", (long)(client.snd_una != client.snd_nxt), 1);
    check("window has room", net_tcp_can_send(&client, 10), 1);
    check("data checksum", net_checksum_tcp(cip, sip, pkt + 20, 38), 0);

    /* Retransmission preserves the true upper edge of sent sequence space. */
    check("timeout 1", net_tcp_timeout(&client), 1);
    check("upper edge preserved", (long)(client.snd_nxt == c_isn+19), 1);
    check("retries", client.retries, 1);
    len = net_tcp_build_at(&client, pkt, client.snd_una, (usos_u8)(USOS_TCP_ACK | USOS_TCP_PSH), client.rcv_wnd,
                        (const usos_u8 *)"GET / HTTP/1.0\r\n\r\n", 18);
    check("retransmit seq", (long)(net_get32(pkt + 24) == c_isn + 1), 1);
    check("retransmit snd_nxt", (long)(client.snd_nxt == c_isn + 1 + 18), 1);

    /* The peer acknowledges the data. */
    len = synth_tcp(pkt, sip, cip, sport, cport, s_isn + 1, c_isn + 1 + 18,
                    (usos_u8)USOS_TCP_ACK, 0, 0);
    ev = net_tcp_input(&client, pkt, len, &data, &dlen, &flags);
    check("data ack event", ev, USOS_TCP_EV_ACK);
    check("snd_una advanced", (long)(client.snd_una == c_isn + 1 + 18), 1);
    check("can send again", net_tcp_can_send(&client, 100), 1);
    check("retries reset", client.retries, 0);

    /* Incoming data: rcv_nxt advances, duplicate is flagged, gap is refused. */
    len = synth_tcp(pkt, sip, cip, sport, cport, s_isn + 1,
                    c_isn + 1 + 18, (usos_u8)(USOS_TCP_ACK | USOS_TCP_PSH),
                    (const usos_u8 *)"HTTP/1.0", 8);
    ev = net_tcp_input(&client, pkt, len, &data, &dlen, &flags);
    printf("data_ev=%d\n", ev);
    check("data event", ev, USOS_TCP_EV_DATA);
    check("data dlen", dlen, 8);
    check("data payload", strncmp((const char *)data, "HTTP/1.0", 8), 0);
    check("rcv_nxt advanced", (long)(client.rcv_nxt == s_isn + 1 + 8), 1);

    ev = net_tcp_input(&client, pkt, len, &data, &dlen, &flags);
    check("duplicate", ev, USOS_TCP_EV_DUP);

    len = synth_tcp(pkt, sip, cip, sport, cport, s_isn + 100, c_isn + 19,
                    (usos_u8)(USOS_TCP_ACK | USOS_TCP_PSH),
                    (const usos_u8 *)"gap", 3);
    check("out of order", net_tcp_input(&client, pkt, len, &data, &dlen, &flags),
          USOS_TCP_EV_BAD);

    /* Retransmission budget: each timeout rewinds, the caller rebuilds, and
     * after USOS_NET_TCP_RETRIES the call fails. */
    len = net_tcp_build(&client, pkt, (usos_u8)(USOS_TCP_ACK | USOS_TCP_PSH), 0,
                        (const usos_u8 *)"x", 1);
    check("second send", (long)(len != 0), 1);
    {
        int i;
        int rc = 0;

        for (i = 0; i < (int)USOS_NET_TCP_RETRIES + 1; i++) {
            rc = net_tcp_timeout(&client);
            if (rc == 1) {
                len = net_tcp_build_at(&client, pkt, client.snd_una,
                                    (usos_u8)(USOS_TCP_ACK | USOS_TCP_PSH), client.rcv_wnd,
                                    (const usos_u8 *)"x", 1);
                check("retransmit rebuild", (long)(len != 0), 1);
            }
        }
        printf("timeout_giveup=%d\n", rc);
        check("timeout giveup", rc, USOS_NET_ERR_TIME);
        check("closed after giveup", client.state, USOS_TCP_CLOSED);
    }

    /* FIN handling on a fresh connection. */
    net_tcp_open(&client, cip, cport, sip, sport);
    c_isn = client.iss;
    len = net_tcp_build(&client, pkt, (usos_u8)USOS_TCP_SYN, 0, 0, 0);
    check("syn again", (long)(len != 0), 1);
    len = synth_tcp(pkt, sip, cip, sport, cport, s_isn, c_isn + 1,
                    (usos_u8)(USOS_TCP_SYN | USOS_TCP_ACK), 0, 0);
    check("synack again", net_tcp_input(&client, pkt, len, &data, &dlen, &flags),
          USOS_TCP_EV_SYNACK);

    len = synth_tcp(pkt, sip, cip, sport, cport, s_isn + 1, c_isn + 1,
                    (usos_u8)(USOS_TCP_ACK | USOS_TCP_FIN), 0, 0);
    ev = net_tcp_input(&client, pkt, len, &data, &dlen, &flags);
    printf("fin_ev=%d\n", ev);
    check("fin event", ev, USOS_TCP_EV_FIN);
    check("close_wait", client.state, USOS_TCP_CLOSE_WAIT);
    check("rcv_nxt after fin", (long)(client.rcv_nxt == s_isn + 2), 1);

    len = net_tcp_build_fin(&client, pkt);
    check("fin flags", pkt[33], (usos_u8)(USOS_TCP_ACK | USOS_TCP_FIN));
    check("fin state", client.state, USOS_TCP_LAST_ACK);
    check("fin snd_nxt", (long)(client.snd_nxt == c_isn + 2), 1);
    check("fin checksum", net_checksum_tcp(cip, sip, pkt + 20, 20), 0);

    len = synth_tcp(pkt, sip, cip, sport, cport, s_isn + 2,
                    client.snd_nxt, (usos_u8)USOS_TCP_ACK, 0, 0);
    check("final ack event", net_tcp_input(&client, pkt, len, &data, &dlen, &flags),
          USOS_TCP_EV_ACK);
    check("closed", client.state, USOS_TCP_CLOSED);

    /* RST aborts whatever is open. */
    net_tcp_open(&client, cip, cport, sip, sport);
    c_isn = client.iss;
    (void)net_tcp_build(&client,pkt,USOS_TCP_SYN,0,0,0);
    len = synth_tcp(pkt, sip, cip, sport, cport, 0, c_isn + 1,
                    (usos_u8)(USOS_TCP_RST | USOS_TCP_ACK), 0, 0);
    ev = net_tcp_input(&client, pkt, len, &data, &dlen, &flags);
    printf("rst_ev=%d\n", ev);
    check("rst event", ev, USOS_TCP_EV_RST);
    check("rst state", client.state, USOS_TCP_RESET);
    check("rst flag", client.rst, 1);

    /* Frames for somebody else's connection are ignored, not fatal. */
    net_tcp_open(&client, cip, cport, sip, sport);
    len = synth_tcp(pkt, 0x0A000099UL, cip, sport, cport, 1, 1,
                    (usos_u8)USOS_TCP_ACK, 0, 0);
    check("foreign segment", net_tcp_input(&client, pkt, len, &data, &dlen, &flags),
          USOS_TCP_EV_IGNORE);
    return g_failures;
}

int main(int argc, char **argv)
{
    const char *name;

    if (argc < 2) {
        printf("usage: %s <checksum|ip|arp|udp|icmp|dns|tcp>\n", argv[0]);
        return 2;
    }
    name = argv[1];
    if (strcmp(name, "checksum") == 0)
        case_checksum();
    else if (strcmp(name, "ip") == 0)
        case_ip();
    else if (strcmp(name, "arp") == 0)
        case_arp();
    else if (strcmp(name, "udp") == 0)
        case_udp();
    else if (strcmp(name, "icmp") == 0)
        case_icmp();
    else if (strcmp(name, "dns") == 0)
        case_dns(argc, argv);
    else if (strcmp(name, "tcp") == 0)
        case_tcp();
    else {
        printf("unknown case: %s\n", name);
        return 2;
    }
    if (g_failures != 0) {
        printf("FAILED: %d check(s)\n", g_failures);
        return 1;
    }
    printf("OK\n");
    return 0;
}
