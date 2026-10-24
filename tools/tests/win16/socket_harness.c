/* Deterministic multi-segment peer for the actual blocking socket engine.
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include <stdio.h>
#include <string.h>
#include "net.h"
#include "usos_pkt.h"
#include "win16_sock.h"

static const usos_u8 clientmac[6] = {0x52,0x54,0,0x12,0x34,0x56};
static const usos_u8 gatewaymac[6] = {0x52,0x55,0x0a,0,2,2};
static usos_u8 frames[16][1514];
static usos_u16 sizes[16], head, tail, clientport;
static usos_u32 now, clientseq, peerseq = 100;
static int failures, routed, dns_onlink;
static int response_active;
static usos_u16 response_offset;
static usos_u32 local_ip=0x0a00020fUL, dns_ip=0x0a000203UL;
static usos_u32 local_mask=0xffffff00UL, router_ip=0x0a000202UL;

unsigned long usos_abi_now(void) { return now++; }
void usos_abi_idle(void) { ++now; }
int usos_abi_cancelled(void) { return 0; }
int usos_pkt_init(void) { return 0; }
int usos_pkt_attach(void) { return 0; }
void usos_pkt_term(void) { }
void usos_pkt_poll(usos_u16 ticks) { (void)ticks; }
usos_u32 usos_pkt_ip(void) { return local_ip; }
usos_u32 usos_pkt_dns(void) { return dns_ip; }
usos_u32 usos_pkt_mask(void) { return local_mask; }
usos_u32 usos_pkt_gateway(void) { return router_ip; }
int usos_pkt_mac(usos_u8 mac[6]) { memcpy(mac,clientmac,6); return 0; }

static void segment(usos_u8 flags, usos_u16 length, usos_u16 offset)
{
    usos_u8 *frame = frames[head], *ip = frame+14, *tcp = ip+20;
    usos_u16 i;
    memset(frame,0,1514);
    net_eth_build(frame,clientmac,gatewaymac,0x0800);
    net_put16(tcp,80); net_put16(tcp+2,clientport);
    net_put32(tcp+4,peerseq); net_put32(tcp+8,clientseq);
    tcp[12]=0x50; tcp[13]=flags; net_put16(tcp+14,4096);
    for(i=0;i<length;i++) tcp[20+i]=(usos_u8)((offset+i)%251);
    net_put16(tcp+16,net_checksum_tcp(0xcb007108UL,usos_pkt_ip(),tcp,20+length));
    sizes[head++]=14+net_ip_finalize(ip,0xcb007108UL,usos_pkt_ip(),6,64,1,0x4000,20+length);
    peerseq += length + ((flags & (USOS_TCP_SYN|USOS_TCP_FIN)) ? 1 : 0);
}

static void response(const usos_u8 *ack)
{
    usos_u32 edge=net_get32(ack+8)+net_get16(ack+14);
    usos_u16 count;
    while(response_active && (usos_s32)(edge-peerseq)>0) {
        count=(usos_u16)(5157-response_offset);
        if(count>1024) count=1024;
        if((usos_u32)count+(response_offset+count==5157?1:0)>edge-peerseq) break;
        segment((usos_u8)(USOS_TCP_ACK|USOS_TCP_PSH|(response_offset+count==5157?USOS_TCP_FIN:0)),count,response_offset);
        response_offset=(usos_u16)(response_offset+count);
        if(response_offset==5157) response_active=0;
    }
}

int usos_pkt_send(const usos_u8 *frame, usos_u16 len)
{
    const usos_u8 *tcp = frame+34;
    (void)len;
    if(net_get16(frame+12)==0x0806) {
        usos_u8 *reply=frames[head];
        usos_u32 target=net_get32(frame+38);
        if(target!=usos_pkt_gateway() && target!=usos_pkt_dns()) { ++failures; return -8; }
        if(target==usos_pkt_dns()) dns_onlink=1;
        if(target==usos_pkt_gateway()) routed=1;
        memcpy(reply,frame,42);
        memcpy(reply,clientmac,6); memcpy(reply+6,gatewaymac,6);
        net_put16(reply+20,2); memcpy(reply+22,gatewaymac,6);
        net_put32(reply+28,target); memcpy(reply+32,clientmac,6);
        net_put32(reply+38,usos_pkt_ip()); sizes[head++]=42;
    } else if(frame[23]==USOS_IP_UDP) {
        usos_u8 answer[128], *reply=frames[head];
        usos_u16 qlen=net_get16(frame+38)-8;
        if(qlen+16>sizeof(answer)) return -8;
        memcpy(answer,frame+42,qlen);
        net_put16(answer+2,0x8180); net_put16(answer+6,1);
        net_put16(answer+qlen,0xc00c); net_put16(answer+qlen+2,1);
        net_put16(answer+qlen+4,1); net_put32(answer+qlen+6,60);
        net_put16(answer+qlen+10,4); net_put32(answer+qlen+12,0xcb007108UL);
        net_eth_build(reply,clientmac,gatewaymac,0x0800);
        sizes[head++]=14+net_udp_build(reply+14,usos_pkt_dns(),usos_pkt_ip(),53,
                                     net_get16(frame+34),answer,qlen+16);
    } else if(tcp[13] & USOS_TCP_SYN) {
        clientport=net_get16(tcp); clientseq=net_get32(tcp+4)+1;
        segment(USOS_TCP_SYN|USOS_TCP_ACK,0,0);
    } else if(tcp[13] & USOS_TCP_PSH) {
        clientseq=net_get32(tcp+4)+(len-54);
        response_active=1; response_offset=0;
        response(tcp);
    } else if(tcp[13] & USOS_TCP_FIN) {
        clientseq=net_get32(tcp+4)+1; segment(USOS_TCP_ACK,0,0);
    } else if((tcp[13]&USOS_TCP_ACK) && response_active) {
        response(tcp);
    }
    return 0;
}
int usos_pkt_recv(usos_u8 *frame, usos_u16 room, usos_u16 *len)
{
    if(tail==head) return USOS_PKT_ERR_EMPTY;
    if(sizes[tail]>room) return -1;
    *len=sizes[tail]; memcpy(frame,frames[tail],*len); ++tail; return 0;
}

int main(int argc, char **argv)
{
    int s, rc;
    usos_u8 buffer[317];
    usos_u16 i, total=0;
    usos_u16 count=0;
    usos_u32 addresses[USOS_NET_MAX_ADDRS];
    if(argc>1 && !strcmp(argv[1],"lan")) {
        local_ip=0xac1f080fUL; local_mask=0xfffffe00UL;
        router_ip=0xac1f0801UL; dns_ip=0xac1f0903UL;
    }
    if(usos_sock_startup()!=0) return 1;
    rc=usos_sock_resolve("68k.news",addresses,&count);
    if(rc || count!=1 || addresses[0]!=0xcb007108UL) {
        printf("DNS=%d count=%u\n",rc,count); return 4;
    }
    s=usos_sock_open(USOS_SOCK_STREAM);
    rc=usos_sock_connect(s,0xcb007108UL,80,0);
    if(rc!=0) { printf("connect=%d routed=%d\n",rc,routed); return 2; }
    if(usos_sock_send(s,(const usos_u8 *)"GET",3)!=3) return 3;
    while((rc=usos_sock_recv(s,buffer,sizeof(buffer)))>0) {
        for(i=0;i<rc;i++) if(buffer[i]!=(total+i)%251) ++failures;
        total+=rc;
    }
    printf("bytes=%u eof=%d routed=%d failures=%d dns_onlink=%d\n",total,rc,routed,failures,dns_onlink);
    usos_sock_shutdown();
    return total!=5157 || rc!=0 || !routed || failures || !dns_onlink;
}
