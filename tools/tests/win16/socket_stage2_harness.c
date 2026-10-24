/* Deterministic wire peer for the cooperative socket engine.
 * Copyright (C) 2026 Maksymilian and the USOS Authors.
 * SPDX-License-Identifier: GPL-3.0-or-later */
#include <stdio.h>
#include <string.h>
#include "net.h"
#include "usos_pkt.h"
#include "win16_sock.h"

#define CLIENT 0x0a00020fUL
#define SERVER 0xcb007108UL
#define Q 256
static const usos_u8 cmac[6]={0x52,0x54,0,0x12,0x34,0x56};
static const usos_u8 smac[6]={0x52,0x55,0,0x11,0x22,0x33};
static usos_u8 frames[Q][1514];
static usos_u16 lengths[Q],head,tail,ports[16];
static usos_u32 now,client_next[16],server_base[16],last_ack[16],data_seq[64],data_time[64];
static int peer_count,idles,failures,data_packets,auto_ack=1,fin_packets,listen_mode,listener_handshakes;
static int fail_full;
static usos_u32 initial_server=0x12340000UL;

#define CHECK(x) do { if(!(x)) { printf("FAIL line=%d expr=%s\n",__LINE__,#x); failures++; } } while(0)
unsigned long usos_abi_now(void) { return now; }
void usos_abi_idle(void) { now++; idles++; }
int usos_pkt_init(void) { return 0; }
int usos_pkt_attach(void) { return 0; }
void usos_pkt_term(void) { }
void usos_pkt_poll(usos_u16 n) { (void)n; }
usos_u32 usos_pkt_ip(void) { return CLIENT; }
usos_u32 usos_pkt_dns(void) { return 0x0a000203UL; }
usos_u32 usos_pkt_mask(void) { return 0xffffff00UL; }
usos_u32 usos_pkt_gateway(void) { return 0x0a000202UL; }
int usos_pkt_mac(usos_u8 out[6]) { memcpy(out,cmac,6); return 0; }

static void push_tcp(usos_u16 source,usos_u16 dest,usos_u32 seq,usos_u32 ack,
                       usos_u8 flags,usos_u16 window,usos_u16 bytes,usos_u32 offset)
{
    usos_u8 *frame=frames[head%Q],*ip=frame+14,*tcp=ip+20;
    usos_u16 header=(flags&USOS_TCP_SYN)?24:20,i;
    CHECK((usos_u16)(head-tail)<Q);
    memset(frame,0,1514); net_eth_build(frame,cmac,smac,USOS_ETH_IPV4);
    net_put16(tcp,source);net_put16(tcp+2,dest);net_put32(tcp+4,seq);net_put32(tcp+8,ack);
    tcp[12]=(usos_u8)((header/4)<<4);tcp[13]=flags;net_put16(tcp+14,window);
    if(header==24) { tcp[20]=2;tcp[21]=4;net_put16(tcp+22,1460); }
    for(i=0;i<bytes;i++) tcp[header+i]=(usos_u8)((offset+i)%251);
    net_put16(tcp+16,net_checksum_tcp(SERVER,CLIENT,tcp,(usos_u16)(header+bytes)));
    lengths[head%Q]=(usos_u16)(14+net_ip_finalize(ip,SERVER,CLIENT,USOS_IP_TCP,64,1,USOS_IP_DF,(usos_u16)(header+bytes)));
    head++;
}
static void push_data(int peer,usos_u32 offset,usos_u16 bytes,usos_u8 extra)
{ push_tcp(80,ports[peer],server_base[peer]+offset,client_next[peer],(usos_u8)(USOS_TCP_ACK|extra),4096,bytes,offset); }
static int peer_for(usos_u16 port,int create)
{
    int i;
    for(i=0;i<peer_count;i++) if(ports[i]==port) return i;
    if(!create || peer_count==16) return -1;
    i=peer_count++; ports[i]=port; server_base[i]=initial_server+(usos_u32)i*100000UL+1; return i;
}
int usos_pkt_send(const usos_u8 *frame,usos_u16 bytes)
{
    usos_u8 *reply;
    const usos_u8 *tcp=frame+34;
    usos_u16 payload,header;
    usos_u32 seq,ack;
    int peer;
    if(net_get16(frame+12)==USOS_ETH_ARP) {
        reply=frames[head%Q]; memcpy(reply,frame,42);memcpy(reply,cmac,6);memcpy(reply+6,smac,6);
        net_put16(reply+20,2);memcpy(reply+22,smac,6);net_put32(reply+28,net_get32(frame+38));
        memcpy(reply+32,cmac,6);net_put32(reply+38,CLIENT);lengths[head%Q]=42;head++;return 0;
    }
    if(frame[23]==USOS_IP_UDP) return 0;
    seq=net_get32(tcp+4);ack=net_get32(tcp+8);header=(usos_u16)((tcp[12]>>4)*4);
    payload=(usos_u16)(bytes-34-header);
    if(listen_mode && net_get16(tcp)==8080 && net_get16(tcp+2)==45000) {
        if((tcp[13]&(USOS_TCP_SYN|USOS_TCP_ACK))==(USOS_TCP_SYN|USOS_TCP_ACK)) {
            listener_handshakes++; client_next[0]=seq+1;
            push_tcp(45000,8080,0x55550001UL,seq+1,USOS_TCP_ACK,4096,0,0);
        }
        if(tcp[13]&USOS_TCP_FIN) { fin_packets++; push_tcp(45000,8080,0x55550001UL,seq+1,USOS_TCP_ACK,4096,0,0); }
        return 0;
    }
    peer=peer_for(net_get16(tcp),(tcp[13]&USOS_TCP_SYN)!=0);
    if(peer<0) return 0;
    last_ack[peer]=ack;
    if(tcp[13]&USOS_TCP_SYN) {
        client_next[peer]=seq+1;
        push_tcp(80,ports[peer],server_base[peer]-1,client_next[peer],USOS_TCP_SYN|USOS_TCP_ACK,4096,0,0);
    } else if(payload) {
        if(fail_full) { fail_full--; return USOS_PKT_ERR_FULL; }
        if(data_packets<64) { data_seq[data_packets]=seq;data_time[data_packets]=now; }
        data_packets++;
        if((usos_s32)(seq+payload-client_next[peer])>0) client_next[peer]=seq+payload;
        if(auto_ack) push_tcp(80,ports[peer],server_base[peer],client_next[peer],USOS_TCP_ACK,4096,0,0);
    } else if(tcp[13]&USOS_TCP_FIN) {
        fin_packets++;client_next[peer]=seq+1;
        push_tcp(80,ports[peer],server_base[peer],client_next[peer],USOS_TCP_ACK,4096,0,0);
    }
    return 0;
}
int usos_pkt_recv(usos_u8 *out,usos_u16 room,usos_u16 *bytes)
{
    if(tail==head) return USOS_PKT_ERR_EMPTY;
    if(lengths[tail%Q]>room) return USOS_PKT_ERR_PARAM;
    *bytes=lengths[tail%Q];memcpy(out,frames[tail%Q],*bytes);tail++;return 0;
}
static void ticks(int count) { while(count--) usos_sock_tick(); }
static int connect_one(void)
{
    int socket=usos_sock_open(USOS_SOCK_STREAM),rc;
    CHECK(socket>=0);CHECK(usos_sock_nonblocking(socket,1)==0);
    rc=usos_sock_connect(socket,SERVER,80,0);CHECK(rc==0 || rc==USOS_SOCK_EWOULDBLOCK);
    ticks(4);CHECK((usos_sock_readiness(socket)&(USOS_SOCK_CONNECT|USOS_SOCK_WRITABLE))==(USOS_SOCK_CONNECT|USOS_SOCK_WRITABLE));
    return socket;
}
static void check_payload(const usos_u8 *data,usos_u16 bytes,usos_u32 start)
{ usos_u16 i; for(i=0;i<bytes;i++) CHECK(data[i]==(usos_u8)((start+i)%251)); }

static void case_multi(void)
{
    int sockets[16],i;usos_u8 bytes[1024];usos_u32 count;
    for(i=0;i<16;i++) sockets[i]=connect_one();
    CHECK(usos_sock_open(USOS_SOCK_STREAM)==USOS_SOCK_EMFILE);
    /* A hole and unread bytes on socket0 must not block socket15's input. */
    push_data(0,1000,1000,USOS_TCP_PSH);
    push_data(15,0,1000,USOS_TCP_PSH);ticks(2);
    CHECK(usos_sock_available(sockets[0],&count)==0 && count==0);
    CHECK(usos_sock_available(sockets[15],&count)==0 && count==1000);
    CHECK(usos_sock_recv(sockets[15],bytes,sizeof(bytes))==1000);check_payload(bytes,1000,0);
    push_data(0,2000,1000,USOS_TCP_PSH|USOS_TCP_FIN);
    push_data(0,500,1000,USOS_TCP_PSH);push_data(0,0,1000,USOS_TCP_PSH);ticks(2);
    CHECK(usos_sock_available(sockets[0],&count)==0 && count==3000);
    CHECK(usos_sock_peek(sockets[0],bytes,317)==317);check_payload(bytes,317,0);
    CHECK(usos_sock_available(sockets[0],&count)==0 && count==3000);
    for(i=0;i<3;i++) { CHECK(usos_sock_recv(sockets[0],bytes,1000)==1000);check_payload(bytes,1000,(usos_u32)i*1000); }
    CHECK(usos_sock_recv(sockets[0],bytes,1)==0);
    CHECK(usos_sock_readiness(sockets[0])&USOS_SOCK_CLOSED);
    CHECK(last_ack[0]==server_base[0]+3001);
    CHECK(usos_sock_recv(sockets[1],bytes,1)==USOS_SOCK_EWOULDBLOCK);
    CHECK(idles==0);printf("sixteen=16 out_of_order=3000 independent_rx=1 peek=1 idle_calls=%d\n",idles);
}
static void case_window(void)
{
    int socket=connect_one(),before;usos_u8 data[4096];usos_u32 count;
    memset(data,0x5b,sizeof(data));auto_ack=0;
    CHECK(usos_sock_send(socket,data,sizeof(data))==4096);
    CHECK(data_packets==2);CHECK(!(usos_sock_readiness(socket)&USOS_SOCK_WRITABLE));
    CHECK(usos_sock_send(socket,data,1)==USOS_SOCK_EWOULDBLOCK);
    push_tcp(80,ports[0],server_base[0],data_seq[0]+500,USOS_TCP_ACK,4096,0,0);ticks(1);
    CHECK(usos_sock_readiness(socket)&USOS_SOCK_WRITABLE);
    CHECK(data_packets>=3);
    push_tcp(80,ports[0],server_base[0],data_seq[0]+4096,USOS_TCP_ACK,4096,0,0);ticks(1);
    /* Overrun the advertised receive window deliberately. Dropped bytes
     * must not be acknowledged; a later retransmission fills them. */
    push_data(0,0,1460,USOS_TCP_PSH);push_data(0,1460,1460,USOS_TCP_PSH);push_data(0,2920,1176,USOS_TCP_PSH);
    push_data(0,4096,500,USOS_TCP_PSH);ticks(2);
    CHECK(usos_sock_available(socket,&count)==0 && count==4096);
    CHECK(last_ack[0]==server_base[0]+4096);
    before=usos_sock_recv(socket,data,4096);CHECK(before==4096);check_payload(data,4096,0);
    push_data(0,4096,500,USOS_TCP_PSH|USOS_TCP_FIN);ticks(2);
    CHECK(usos_sock_recv(socket,data,500)==500);check_payload(data,500,4096);
    CHECK(usos_sock_recv(socket,data,1)==0);CHECK(idles==0);
    printf("multi_segment_flight=2 partial_ack=1 receive_window=4096 retransmitted_tail=500 idle_calls=%d\n",idles);
}
static void case_backoff(void)
{
    int socket=connect_one();usos_u8 data[1000];usos_u32 base;
    memset(data,0x33,sizeof(data));auto_ack=0;
    CHECK(usos_sock_send(socket,data,sizeof(data))==1000);CHECK(data_packets==1);base=data_seq[0];
    now=999;ticks(1);CHECK(data_packets==1);
    now=1000;fail_full=1;ticks(1);CHECK(data_packets==1);CHECK(!usos_sock_error(socket,0));
    ticks(1);CHECK(data_packets==2);
    now=2000;push_tcp(80,ports[0],server_base[0],base,USOS_TCP_ACK,4096,0,0);ticks(1);
    now=2999;ticks(1);CHECK(data_packets==2);
    now=3000;ticks(1);CHECK(data_packets==3);
    now=7000;ticks(1);CHECK(data_packets==4);
    now=15000;ticks(1);CHECK(data_packets==5);
    CHECK(data_seq[1]==base && data_seq[2]==base && data_seq[3]==base && data_seq[4]==base);
    CHECK(data_time[1]==1000 && data_time[2]==3000 && data_time[3]==7000 && data_time[4]==15000);
    now=31000;ticks(1);CHECK(usos_sock_error(socket,0)==USOS_SOCK_ETIMEDOUT);
    CHECK(usos_sock_readiness(socket)&USOS_SOCK_EXCEPTION);CHECK(idles==0);
    printf("rto_ms=1000,2000,4000,8000 duplicate_ack_does_not_reset=1 timeout=31000 idle_calls=%d\n",idles);
}
static void case_persist(void)
{
    int socket=connect_one();usos_u8 data[100];usos_u32 sequence=client_next[0];
    memset(data,0x19,sizeof(data));
    push_tcp(80,ports[0],server_base[0],sequence,USOS_TCP_ACK,0,0,0);ticks(1);
    CHECK(usos_sock_send(socket,data,sizeof(data))==100);CHECK(data_packets==0);
    now=999;ticks(1);CHECK(data_packets==0);
    now=1000;ticks(1);CHECK(data_packets==1);CHECK(data_seq[0]==sequence);
    ticks(3);CHECK(data_packets==2);CHECK(client_next[0]==sequence+100);
    CHECK(usos_sock_readiness(socket)&USOS_SOCK_WRITABLE);CHECK(!usos_sock_error(socket,0));CHECK(idles==0);
    printf("zero_window_probe=1 resumed_bytes=100 idle_calls=%d\n",idles);
}
static void case_listener(void)
{
    int listener=usos_sock_open(USOS_SOCK_STREAM),child;usos_u32 ip;usos_u16 port;usos_u8 data[32];
    CHECK(usos_sock_nonblocking(listener,1)==0);CHECK(usos_sock_bind(listener,CLIENT,8080)==0);
    CHECK(usos_sock_listen(listener,2)==0);CHECK(usos_sock_accept(listener,&ip,&port)==USOS_SOCK_EWOULDBLOCK);
    listen_mode=1;push_tcp(45000,8080,0x55550000UL,0,USOS_TCP_SYN,4096,0,0);ticks(4);
    CHECK(listener_handshakes==1);CHECK(usos_sock_readiness(listener)&USOS_SOCK_ACCEPT);
    child=usos_sock_accept(listener,&ip,&port);CHECK(child>=0 && child!=listener);CHECK(ip==SERVER && port==45000);
    CHECK(!(usos_sock_readiness(listener)&USOS_SOCK_ACCEPT));
    push_tcp(45000,8080,0x55550001UL,client_next[0],USOS_TCP_ACK|USOS_TCP_PSH,4096,16,0);ticks(1);
    CHECK(usos_sock_recv(child,data,sizeof(data))==16);check_payload(data,16,0);
    CHECK(usos_sock_shutdown_one(child,1)==0);ticks(3);CHECK(fin_packets==1);
    CHECK(usos_sock_send(child,data,1)==USOS_SOCK_ESHUTDOWN);
    CHECK(usos_sock_shutdown_one(child,0)==0);CHECK(usos_sock_recv(child,data,1)==0);
    CHECK(usos_sock_close(child)==0);CHECK(usos_sock_close(listener)==0);CHECK(idles==0);
    printf("listen_handshake=1 accept=1 half_close=1 idle_calls=%d\n",idles);
}
static void case_wrap(void)
{
    int socket;usos_u8 bytes[1024];usos_u32 count;
    initial_server=0xfffffff0UL;socket=connect_one();
    push_data(0,512,512,USOS_TCP_PSH|USOS_TCP_FIN);push_data(0,0,512,USOS_TCP_PSH);ticks(2);
    CHECK(usos_sock_available(socket,&count)==0 && count==1024);
    CHECK(usos_sock_recv(socket,bytes,sizeof(bytes))==1024);check_payload(bytes,1024,0);
    CHECK(usos_sock_recv(socket,bytes,1)==0);CHECK(last_ack[0]==server_base[0]+1025);CHECK(idles==0);
    printf("receive_sequence_wrap=1 out_of_order_fin=1 idle_calls=%d\n",idles);
}
static void case_udp(void)
{
    int socket=usos_sock_open(USOS_SOCK_DGRAM),rc;usos_u8 *frame,buffer[16];usos_u32 ip;usos_u16 port;
    CHECK(usos_sock_nonblocking(socket,1)==0);CHECK(usos_sock_bind(socket,0,53000)==0);
    rc=usos_sock_sendto(socket,SERVER,53,(const usos_u8 *)"Q",1);
    CHECK(rc==USOS_SOCK_EWOULDBLOCK);ticks(1);
    CHECK(usos_sock_sendto(socket,SERVER,53,(const usos_u8 *)"Q",1)==1);
    frame=frames[head%Q];net_eth_build(frame,cmac,smac,USOS_ETH_IPV4);
    lengths[head%Q]=(usos_u16)(14+net_udp_build(frame+14,SERVER,CLIENT,53,53000,(const usos_u8 *)"reply",5));head++;ticks(1);
    CHECK(usos_sock_recvfrom(socket,buffer,sizeof(buffer),&ip,&port)==5);CHECK(ip==SERVER && port==53);CHECK(!memcmp(buffer,"reply",5));
    frame=frames[head%Q];net_eth_build(frame,cmac,smac,USOS_ETH_IPV4);
    lengths[head%Q]=(usos_u16)(14+net_udp_build(frame+14,SERVER,CLIENT,53,53000,0,0));head++;ticks(1);
    CHECK(usos_sock_readiness(socket)&USOS_SOCK_READABLE);CHECK(usos_sock_recvfrom(socket,buffer,sizeof(buffer),&ip,&port)==0);
    CHECK(!(usos_sock_readiness(socket)&USOS_SOCK_READABLE));CHECK(idles==0);
    printf("udp_sendto=1 recvfrom=1 empty_datagram=1 idle_calls=%d\n",idles);
}
int main(int argc,char **argv)
{
    if(argc!=2) return 2;CHECK(usos_sock_startup()==0);
    if(!strcmp(argv[1],"multi")) case_multi();else if(!strcmp(argv[1],"window")) case_window();
    else if(!strcmp(argv[1],"backoff")) case_backoff();else if(!strcmp(argv[1],"listener")) case_listener();
    else if(!strcmp(argv[1],"wrap")) case_wrap();else if(!strcmp(argv[1],"udp")) case_udp();
    else if(!strcmp(argv[1],"persist")) case_persist();else return 2;
    printf("failures=%d\n",failures);return failures?1:0;
}
