/* Cooperative cancellation and nested DNS contexts against real sockets.
 * Copyright (C) 2026 Maksymilian and the USOS Authors.
 * SPDX-License-Identifier: GPL-3.0-or-later */
#define main stage2_main
#define usos_pkt_send stage2_pkt_send
#define usos_abi_now stage2_now
#define usos_abi_idle stage2_idle
#define usos_abi_cancelled stage2_cancelled
#include "socket_stage2_harness.c"
#undef usos_abi_cancelled
#undef usos_abi_idle
#undef usos_abi_now
#undef usos_pkt_send
#undef main

static int context,cancelled[2],cancel_checks,action,other_socket;
static int suppress_syn,suppress_arp,suppress_fin,dns_mode,dns_queries;
static usos_u16 dns_ports[2],dns_ids[2],dns_sizes[2];
static usos_u8 dns_queries_copy[2][256];
static usos_u32 nested_addresses[USOS_NET_MAX_ADDRS];
static usos_u16 nested_count;
static int nested_rc;

unsigned long usos_abi_now(void) { return now; }
int usos_abi_cancelled(void) { ++cancel_checks;return cancelled[context]; }
void usos_abi_idle(void)
{
    int next=action;action=0;++idles;++now;
    if(next==1) cancelled[context]=1;
    else if(next==2) {
        push_data(1,0,32,USOS_TCP_PSH);usos_sock_tick();
        CHECK(usos_sock_readiness(other_socket)&USOS_SOCK_READABLE);
        cancelled[context]=1;
    } else if(next==3 || next==4) {
        /* Finish the outer request's ARP first; nesting must occur while an
         * actual DNS query is outstanding, rather than before it is sent. */
        if(!dns_queries) { action=next;return; }
        context=1;
        nested_rc=usos_sock_resolve("inner.test",nested_addresses,&nested_count);
        context=0;
        if(next==4) cancelled[0]=1;
    }
}
static void dns_reply(int which,usos_u32 address)
{
    usos_u8 answer[512],*frame=frames[head%Q];usos_u16 n=dns_sizes[which];
    CHECK(n+16<=sizeof(answer));memcpy(answer,dns_queries_copy[which],n);
    net_put16(answer+2,0x8180);net_put16(answer+6,1);
    net_put16(answer+n,0xc00c);net_put16(answer+n+2,1);net_put16(answer+n+4,1);
    net_put32(answer+n+6,30);net_put16(answer+n+10,4);net_put32(answer+n+12,address);
    net_eth_build(frame,cmac,smac,USOS_ETH_IPV4);
    lengths[head%Q]=(usos_u16)(14+net_udp_build(frame+14,usos_pkt_dns(),CLIENT,53,dns_ports[which],answer,(usos_u16)(n+16)));
    ++head;
}
int usos_pkt_send(const usos_u8 *frame,usos_u16 bytes)
{
    int rc=stage2_pkt_send(frame,bytes);
    const usos_u8 *tcp=frame+34;
    usos_u16 n;
    if(rc)return rc;
    if(net_get16(frame+12)==USOS_ETH_ARP) {
        if(suppress_arp) --head;
    } else if(frame[23]==USOS_IP_TCP) {
        if(suppress_syn && (tcp[13]&USOS_TCP_SYN)) --head;
        if(suppress_fin && (tcp[13]&USOS_TCP_FIN)) --head;
    } else if(frame[23]==USOS_IP_UDP && dns_mode) {
        n=(usos_u16)(net_get16(frame+38)-8);
        CHECK(dns_queries<2);CHECK(n<=sizeof(dns_queries_copy[0]));
        if(dns_queries>=2 || n>sizeof(dns_queries_copy[0]))return rc;
        dns_ports[dns_queries]=net_get16(frame+34);
        dns_ids[dns_queries]=net_get16(frame+42);dns_sizes[dns_queries]=n;
        memcpy(dns_queries_copy[dns_queries],frame+42,n);++dns_queries;
        if(dns_queries==2 && dns_mode==1) {
            /* Both answers arrive while the inner context is running, with
             * the outer reply first. They must remain in separate slots. */
            dns_reply(0,0xcb00710bUL);dns_reply(1,0xcb007116UL);
        }
    }
    return rc;
}
static void check_other(int socket,int peer)
{
    usos_u8 data[64];
    if(!(usos_sock_readiness(socket)&USOS_SOCK_READABLE)) {
        push_data(peer,0,32,USOS_TCP_PSH);ticks(1);
    }
    CHECK(usos_sock_recv(socket,data,sizeof(data))==32);check_payload(data,32,0);
    CHECK(!usos_sock_error(socket,0));
}
static void case_recv(void)
{
    int first=connect_one();usos_u8 data[64];
    other_socket=connect_one();CHECK(usos_sock_nonblocking(first,0)==0);
    action=2;CHECK(usos_sock_recv(first,data,sizeof(data))==USOS_SOCK_ECANCELLED);
    CHECK(cancelled[0] && !cancelled[1]);context=1;check_other(other_socket,1);context=0;
    cancelled[0]=0;push_data(0,0,32,USOS_TCP_PSH);ticks(1);
    CHECK(usos_sock_recv(first,data,sizeof(data))==32);check_payload(data,32,0);
    printf("cancel_recv=1 socket_preserved=1 other_context_progress=1\n");
}
static void case_connect(void)
{
    int first;usos_u16 before,after;usos_u32 ip;
    other_socket=connect_one();first=usos_sock_open(USOS_SOCK_STREAM);
    CHECK(usos_sock_local(first,&ip,&before)==0);suppress_syn=1;action=1;
    CHECK(usos_sock_connect(first,SERVER,80,0)==USOS_SOCK_ECANCELLED);
    CHECK(usos_sock_remote(first,&ip,&after)==USOS_SOCK_ENOTCONN);
    CHECK(usos_sock_local(first,&ip,&after)==0 && before==after);
    CHECK(!(usos_sock_readiness(first)&USOS_SOCK_CONNECT));
    cancelled[0]=0;suppress_syn=0;CHECK(usos_sock_nonblocking(first,1)==0);
    CHECK(usos_sock_connect(first,SERVER,80,0)==USOS_SOCK_EWOULDBLOCK);ticks(4);
    CHECK(usos_sock_readiness(first)&USOS_SOCK_CONNECT);check_other(other_socket,0);
    printf("cancel_connect=1 slot_reusable=1 local_port_preserved=1 other_socket_preserved=1\n");
}
static void case_send(void)
{
    int first=connect_one();usos_u8 data[5000];usos_u32 edge;
    other_socket=connect_one();memset(data,0x42,sizeof(data));auto_ack=0;
    CHECK(usos_sock_nonblocking(first,0)==0);action=2;
    CHECK(usos_sock_send(first,data,sizeof(data))==4096);
    CHECK(cancelled[0]);context=1;check_other(other_socket,1);context=0;
    cancelled[0]=0;auto_ack=1;edge=client_next[0];
    push_tcp(80,ports[0],server_base[0],edge,USOS_TCP_ACK,4096,0,0);ticks(8);
    CHECK(usos_sock_nonblocking(first,1)==0);
    CHECK(usos_sock_send(first,data,64)==64);ticks(4);CHECK(!usos_sock_error(first,0));
    printf("cancel_send_accepted=4096 queued_bytes_preserved=1 other_context_progress=1\n");
}
static void case_send_full(void)
{
    int first=connect_one();usos_u8 data[4096];
    other_socket=connect_one();memset(data,0x55,sizeof(data));auto_ack=0;
    CHECK(usos_sock_send(first,data,sizeof(data))==sizeof(data));
    CHECK(!(usos_sock_readiness(first)&USOS_SOCK_WRITABLE));
    CHECK(usos_sock_nonblocking(first,0)==0);action=2;
    CHECK(usos_sock_send(first,data,1)==USOS_SOCK_ECANCELLED);
    context=1;check_other(other_socket,1);context=0;cancelled[0]=0;
    CHECK(usos_sock_kind(first)==USOS_SOCK_STREAM && !usos_sock_error(first,0));
    printf("cancel_send_accepted=0 full_queue_preserved=1 other_context_progress=1\n");
}
static void case_accept(void)
{
    int listener=usos_sock_open(USOS_SOCK_STREAM),child;
    other_socket=connect_one();CHECK(usos_sock_bind(listener,0,8080)==0);
    CHECK(usos_sock_listen(listener,2)==0);action=1;
    CHECK(usos_sock_accept(listener,0,0)==USOS_SOCK_ECANCELLED);
    CHECK(usos_sock_kind(listener)==USOS_SOCK_STREAM);cancelled[0]=0;
    CHECK(usos_sock_nonblocking(listener,1)==0);child=usos_sock_accept(listener,0,0);
    CHECK(child==USOS_SOCK_EWOULDBLOCK);check_other(other_socket,0);
    printf("cancel_accept=1 listener_preserved=1 other_socket_preserved=1\n");
}
static void case_close(int fin)
{
    int first=connect_one();usos_u8 data[128];
    other_socket=connect_one();memset(data,1,sizeof(data));
    if(!fin) { auto_ack=0;CHECK(usos_sock_send(first,data,sizeof(data))==sizeof(data)); }
    else suppress_fin=1;
    CHECK(usos_sock_nonblocking(first,0)==0);action=2;
    CHECK(usos_sock_close(first)==USOS_SOCK_ECANCELLED);
    CHECK(usos_sock_kind(first)==USOS_SOCK_ENOTSOCK);
    CHECK(usos_sock_kind(other_socket)==USOS_SOCK_STREAM);
    context=1;check_other(other_socket,1);context=0;cancelled[0]=0;
    CHECK(usos_sock_open(USOS_SOCK_DGRAM)==first);
    printf("cancel_close=1 fin_wait=%d target_released=1 other_context_progress=1\n",fin);
}
static void check_no_dns_leak(void)
{
    int sockets[16],i;
    for(i=0;i<16;i++) { sockets[i]=usos_sock_open(USOS_SOCK_DGRAM);CHECK(sockets[i]>=0); }
    CHECK(usos_sock_open(USOS_SOCK_DGRAM)==USOS_SOCK_EMFILE);
    for(i=0;i<16;i++)CHECK(usos_sock_close(sockets[i])==0);
}
static void case_dns(int cancel_outer)
{
    usos_u32 addresses[USOS_NET_MAX_ADDRS];usos_u16 count=0;int rc;
    dns_mode=1;action=cancel_outer?4:3;
    rc=usos_sock_resolve("outer.test",addresses,&count);
    CHECK(dns_queries==2);CHECK(dns_ports[0]!=dns_ports[1]);CHECK(dns_ids[0]!=dns_ids[1]);
    CHECK(nested_rc==0 && nested_count==1 && nested_addresses[0]==0xcb007116UL);
    if(cancel_outer) CHECK(rc==USOS_SOCK_ECANCELLED && count==0);
    else CHECK(rc==0 && count==1 && addresses[0]==0xcb00710bUL);
    cancelled[0]=0;check_no_dns_leak();
    printf("nested_dns_contexts=2 distinct_port_id=1 isolated_answers=1 cancel_outer=%d no_slot_leak=1\n",cancel_outer);
}
static void case_arp(void)
{
    int socket=usos_sock_open(USOS_SOCK_DGRAM),rc;
    other_socket=connect_one();suppress_arp=1;action=1;
    rc=usos_sock_sendto(socket,0x0a000244UL,1234,(const usos_u8 *)"X",1);
    CHECK(rc==USOS_SOCK_ECANCELLED);CHECK(usos_sock_kind(socket)==USOS_SOCK_DGRAM);
    cancelled[0]=0;check_other(other_socket,0);
    printf("cancel_arp_wait=1 datagram_socket_preserved=1 other_socket_preserved=1\n");
}
static void case_tick(void)
{
    int socket=connect_one(),checks=cancel_checks;
    cancelled[0]=1;push_data(0,0,32,USOS_TCP_PSH);ticks(8);
    CHECK(cancel_checks==checks);check_other(socket,0);CHECK(cancel_checks==checks);
    printf("timer_tick_cancel_hook_calls=0 nonblocking_cancel_hook_calls=0\n");
}
int main(int argc,char **argv)
{
    if(argc!=2)return 2;CHECK(usos_sock_startup()==0);
    if(!strcmp(argv[1],"recv"))case_recv();else if(!strcmp(argv[1],"connect"))case_connect();
    else if(!strcmp(argv[1],"send"))case_send();else if(!strcmp(argv[1],"send-full"))case_send_full();
    else if(!strcmp(argv[1],"accept"))case_accept();
    else if(!strcmp(argv[1],"close"))case_close(0);else if(!strcmp(argv[1],"close-fin"))case_close(1);
    else if(!strcmp(argv[1],"dns"))case_dns(0);else if(!strcmp(argv[1],"dns-cancel"))case_dns(1);
    else if(!strcmp(argv[1],"arp"))case_arp();else if(!strcmp(argv[1],"tick"))case_tick();else return 2;
    printf("failures=%d\n",failures);return failures?1:0;
}
