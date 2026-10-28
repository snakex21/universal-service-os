/* arp.c - ARP cache and request/reply frames (RFC 826, Ethernet/IPv4 only).
 *
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The cache is fixed size and tick driven: net_arp_tick() is called once per
 * second by the Win16 layer, entries age out after USOS_NET_ARP_TTL and a
 * miss records a pending request so that the caller knows whether it has to
 * emit an ARP request or whether one is already on the wire.
 */

#include "net.h"

static void net_mac_copy(usos_u8 *dst, const usos_u8 *src)
{
    usos_u8 i;

    for (i = 0; i < (usos_u8)USOS_NET_ETH_ALEN; i++)
        dst[i] = src[i];
}

static void net_mac_zero(usos_u8 *dst)
{
    usos_u8 i;

    for (i = 0; i < (usos_u8)USOS_NET_ETH_ALEN; i++)
        dst[i] = 0;
}

void net_arp_init(net_arp *cache, const usos_u8 mac[USOS_NET_ETH_ALEN],
                  usos_u32 ip)
{
    int i;

    if (cache == 0)
        return;
    if (mac != 0)
        net_mac_copy(cache->mac, mac);
    else
        net_mac_zero(cache->mac);
    cache->ip = ip;
    for (i = 0; i < USOS_NET_ARP_CACHE; i++) {
        cache->entry[i].ip = 0;
        cache->entry[i].age = 0;
        cache->entry[i].valid = 0;
        cache->entry[i].pending = 0;
        net_mac_zero(cache->entry[i].mac);
    }
}

void net_arp_tick(net_arp *cache)
{
    int i;

    if (cache == 0)
        return;
    for (i = 0; i < USOS_NET_ARP_CACHE; i++) {
        net_arp_entry *e = &cache->entry[i];

        if (!e->valid && !e->pending)
            continue;
        if (e->age < 0xFFFFU)
            e->age = (usos_u16)(e->age + 1);
        if (e->valid && e->age > (usos_u16)USOS_NET_ARP_TTL) {
            e->valid = 0;
            e->pending = 0;
            net_mac_zero(e->mac);
        }
    }
}

void net_arp_learn(net_arp *cache, usos_u32 ip,
                   const usos_u8 mac[USOS_NET_ETH_ALEN])
{
    int i;
    int slot = -1;
    int oldest = -1;
    usos_u16 oldest_age = 0;

    if (cache == 0 || mac == 0 || ip == 0 || ip == 0xFFFFFFFFUL)
        return;
    for (i = 0; i < USOS_NET_ARP_CACHE; i++) {
        if ((cache->entry[i].valid || cache->entry[i].pending) &&
            cache->entry[i].ip == ip) {
            net_mac_copy(cache->entry[i].mac, mac);
            cache->entry[i].age = 0;
            cache->entry[i].valid = 1;
            cache->entry[i].pending = 0;
            return;
        }
    }
    for (i = 0; i < USOS_NET_ARP_CACHE; i++) {
        if (!cache->entry[i].valid && !cache->entry[i].pending) {
            slot = i;
            break;
        }
        if (slot < 0 && !cache->entry[i].valid) {
            slot = i;              /* a pending slot can be reused */
            break;
        }
    }
    if (slot < 0) {
        for (i = 0; i < USOS_NET_ARP_CACHE; i++) {
            if (oldest < 0 || cache->entry[i].age > oldest_age) {
                oldest = i;
                oldest_age = cache->entry[i].age;
            }
        }
        slot = oldest;
    }
    if (slot < 0)
        return;
    cache->entry[slot].ip = ip;
    net_mac_copy(cache->entry[slot].mac, mac);
    cache->entry[slot].age = 0;
    cache->entry[slot].valid = 1;
    cache->entry[slot].pending = 0;
}

/* 1 and the MAC on a hit; 0 on a miss, with the pending flag set so that the
 * caller knows a request has been (or must be) sent. */
int net_arp_lookup(net_arp *cache, usos_u32 ip,
                   usos_u8 mac[USOS_NET_ETH_ALEN])
{
    int i;
    int slot = -1;

    if (cache == 0 || ip == 0 || ip == 0xFFFFFFFFUL)
        return 0;
    for (i = 0; i < USOS_NET_ARP_CACHE; i++) {
        if (cache->entry[i].valid && cache->entry[i].ip == ip) {
            if (mac != 0)
                net_mac_copy(mac, cache->entry[i].mac);
            return 1;
        }
        if (cache->entry[i].pending && cache->entry[i].ip == ip)
            return 0;
        if (slot < 0 && !cache->entry[i].valid && !cache->entry[i].pending)
            slot = i;
    }
    if (slot >= 0) {
        cache->entry[slot].ip = ip;
        cache->entry[slot].age = 0;
        cache->entry[slot].valid = 0;
        cache->entry[slot].pending = 1;
        net_mac_zero(cache->entry[slot].mac);
    }
    return 0;
}

int net_arp_pending(const net_arp *cache, usos_u32 ip)
{
    int i;

    if (cache == 0)
        return 0;
    for (i = 0; i < USOS_NET_ARP_CACHE; i++) {
        if (cache->entry[i].pending && cache->entry[i].ip == ip)
            return 1;
    }
    return 0;
}

static void net_arp_header(usos_u8 *frame, const net_arp *cache, usos_u16 op,
                           const usos_u8 *dst_mac, usos_u32 sender_ip,
                           const usos_u8 *target_mac, usos_u32 target_ip)
{
    usos_u8 broadcast[USOS_NET_ETH_ALEN];
    usos_u8 empty[USOS_NET_ETH_ALEN];
    usos_u8 *arp = frame + USOS_NET_ETH_HDR;

    net_eth_broadcast(broadcast);
    net_mac_zero(empty);
    net_eth_build(frame, dst_mac != 0 ? dst_mac : broadcast, cache->mac,
                  (usos_u16)USOS_ETH_ARP);
    net_put16(arp + 0, 1);                    /* hardware type: Ethernet */
    net_put16(arp + 2, (usos_u16)USOS_ETH_IPV4);
    arp[4] = (usos_u8)USOS_NET_ETH_ALEN;
    arp[5] = 4;
    net_put16(arp + 6, op);
    net_mac_copy(arp + 8, cache->mac);
    net_put32(arp + 14, sender_ip);
    net_mac_copy(arp + 18, target_mac != 0 ? target_mac : empty);
    net_put32(arp + 24, target_ip);
}

usos_u16 net_arp_build_request(usos_u8 *frame, const net_arp *cache,
                               usos_u32 target)
{
    if (frame == 0 || cache == 0)
        return 0;
    net_arp_header(frame, cache, (usos_u16)USOS_ARP_REQUEST, 0, cache->ip, 0,
                   target);
    return (usos_u16)(USOS_NET_ETH_HDR + USOS_NET_ARP_LEN);
}

usos_u16 net_arp_build_reply(usos_u8 *frame, const net_arp *cache,
                             const usos_u8 dst_mac[USOS_NET_ETH_ALEN],
                             usos_u32 dst_ip, usos_u32 my_ip)
{
    if (frame == 0 || cache == 0 || dst_mac == 0)
        return 0;
    net_arp_header(frame, cache, (usos_u16)USOS_ARP_REPLY, dst_mac, my_ip,
                   dst_mac, dst_ip);
    return (usos_u16)(USOS_NET_ETH_HDR + USOS_NET_ARP_LEN);
}

int net_arp_parse(net_arp *cache, const usos_u8 *frame, usos_u16 caplen,
                  usos_u16 *op, usos_u32 *sender_ip,
                  usos_u32 *sender_target_ip)
{
    const usos_u8 *arp;
    usos_u16 type = 0;
    usos_u16 code;
    int rc;

    if (frame == 0)
        return USOS_NET_ERR_ARG;
    rc = net_eth_parse(frame, caplen, &type, &arp, &caplen);
    if (rc != USOS_NET_OK)
        return rc;
    if (type != (usos_u16)USOS_ETH_ARP)
        return USOS_NET_ERR_PROTO;
    if (caplen < USOS_NET_ARP_LEN)
        return USOS_NET_ERR_SHORT;
    if (net_get16(arp + 0) != 1 || net_get16(arp + 2) != USOS_ETH_IPV4 ||
        arp[4] != (usos_u8)USOS_NET_ETH_ALEN || arp[5] != 4)
        return USOS_NET_ERR_PROTO;
    code = net_get16(arp + 6);
    if (code != (usos_u16)USOS_ARP_REQUEST &&
        code != (usos_u16)USOS_ARP_REPLY)
        return USOS_NET_ERR_PROTO;
    if (op != 0)
        *op = code;
    if (sender_ip != 0)
        *sender_ip = net_get32(arp + 14);
    if (sender_target_ip != 0)
        *sender_target_ip = net_get32(arp + 24);
    if (cache != 0 && code == (usos_u16)USOS_ARP_REPLY)
        net_arp_learn(cache, net_get32(arp + 14), arp + 8);
    return USOS_NET_OK;
}
