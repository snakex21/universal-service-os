/* Abortive close against the real engine and a deterministic Ethernet peer.
 * Copyright (C) 2026 Maksymilian and the USOS Authors.
 * SPDX-License-Identifier: GPL-3.0-or-later */
#define main stage2_main
#define usos_pkt_send stage2_pkt_send
#define usos_abi_cancelled stage2_cancelled
#include "socket_stage2_harness.c"
#undef usos_abi_cancelled
#undef usos_pkt_send
#undef main

static usos_u8 resets[16][1514];
static usos_u16 reset_bytes[16];
static int reset_attempts,reset_accepted,reset_failure,all_frames,listen_ack,cancel_checks;
int usos_abi_cancelled(void) { cancel_checks++;return 1; }

int usos_pkt_send(const usos_u8 *frame,usos_u16 bytes)
{
    const usos_u8 *tcp=frame+34;
    all_frames++;
    if(bytes>=54 && net_get16(frame+12)==USOS_ETH_IPV4 && frame[23]==USOS_IP_TCP) {
        if(tcp[13]&USOS_TCP_RST) {
            CHECK(reset_attempts<16);
            if(reset_attempts<16) {
                memcpy(resets[reset_attempts],frame,bytes);
                reset_bytes[reset_attempts]=bytes;
            }
            reset_attempts++;
            if(reset_failure) return reset_failure;
            reset_accepted++;
        }
        if(net_get16(tcp)==8080 && net_get16(tcp+2)>=45001 &&
           (tcp[13]&(USOS_TCP_SYN|USOS_TCP_ACK))==(USOS_TCP_SYN|USOS_TCP_ACK)) {
            if(listen_ack) push_tcp(net_get16(tcp+2),8080,0x55550001UL,
                net_get32(tcp+4)+1,USOS_TCP_ACK,4096,0,0);
            return 0;
        }
    }
    return stage2_pkt_send(frame,bytes);
}

static void check_reset(int index,usos_u16 local,usos_u16 remote,
                        usos_u8 flags,usos_u32 sequence,usos_u32 ack)
{
    const usos_u8 *frame,*ip,*tcp;
    CHECK(index<reset_attempts);
    if(index>=reset_attempts) return;
    frame=resets[index];ip=frame+14;tcp=frame+34;
    CHECK(reset_bytes[index]==54);
    CHECK(!memcmp(frame,smac,6) && !memcmp(frame+6,cmac,6));
    CHECK(net_get32(ip+12)==CLIENT && net_get32(ip+16)==SERVER);
    CHECK(net_get16(ip+2)==40 && net_checksum(ip,20)==0);
    CHECK(tcp[12]==0x50 && tcp[13]==flags && !(tcp[13]&USOS_TCP_FIN));
    CHECK(net_get16(tcp)==local && net_get16(tcp+2)==remote);
    CHECK(net_get32(tcp+4)==sequence && net_get32(tcp+8)==ack);
    CHECK(net_get16(tcp+14)==0 && net_checksum_tcp(CLIENT,SERVER,tcp,20)==0);
}

static void closed_and_reusable(int slot)
{
    int replacement;
    CHECK(usos_sock_kind(slot)==USOS_SOCK_ENOTSOCK);
    CHECK(usos_sock_abort(slot)==USOS_SOCK_ENOTSOCK);
    CHECK(usos_sock_close(slot)==USOS_SOCK_ENOTSOCK);
    replacement=usos_sock_open(USOS_SOCK_DGRAM);
    CHECK(replacement==slot);
    CHECK(usos_sock_abort(replacement)==0);
}
static void case_connected(int pending)
{
    int socket=connect_one(),other=connect_one(),before_data,before_frames;
    usos_u8 data[4096],received[16];usos_u32 sequence=client_next[0];
    auto_ack=0;memset(data,0x41,sizeof(data));
    if(pending) {
        CHECK(usos_sock_send(socket,data,sizeof(data))==sizeof(data));
        CHECK(data_packets==2); /* 2920 sent; 1176 still only locally queued. */
        sequence=client_next[0];
    }
    before_data=data_packets;before_frames=all_frames;
    CHECK(usos_sock_abort(socket)==0);
    CHECK(reset_attempts==1 && reset_accepted==1 && all_frames==before_frames+1);
    check_reset(0,ports[0],80,USOS_TCP_RST|USOS_TCP_ACK,sequence,server_base[0]);
    ticks(8);CHECK(data_packets==before_data && reset_attempts==1);
    CHECK(usos_sock_kind(other)==USOS_SOCK_STREAM);
    push_data(1,0,sizeof(received),USOS_TCP_PSH);ticks(1);
    CHECK(usos_sock_recv(other,received,sizeof(received))==sizeof(received));
    check_payload(received,sizeof(received),0);
    closed_and_reusable(socket);
    CHECK(fin_packets==0 && idles==0);
    printf("connected_rst=1 pending_bytes_discarded=%d other_socket_io=1 slot_reusable=1 idle_calls=%d\n",pending?1176:0,idles);
}
static void case_connecting(void)
{
    int warm=connect_one(),socket=usos_sock_open(USOS_SOCK_STREAM),rc;
    usos_u16 port;
    CHECK(usos_sock_nonblocking(socket,1)==0);
    rc=usos_sock_connect(socket,SERVER,80,0);
    CHECK(rc==USOS_SOCK_EWOULDBLOCK && peer_count==2);
    CHECK(usos_sock_local(socket,0,&port)==0);
    /* Drop the SYN+ACK before it enters the engine. */
    head=tail;
    CHECK(usos_sock_abort(socket)==0 && reset_attempts==1);
    check_reset(0,port,80,USOS_TCP_RST,client_next[1],0);
    CHECK(usos_sock_kind(warm)==USOS_SOCK_STREAM);
    closed_and_reusable(socket);
    CHECK(fin_packets==0 && idles==0);
    printf("connecting_rst=1 unknown_peer_sequence_no_ack=1 idle_calls=%d\n",idles);
}
static void case_abort_udp(void)
{
    int socket=usos_sock_open(USOS_SOCK_DGRAM),plain,before=all_frames;
    CHECK(usos_sock_connect(socket,SERVER,53,0)==0);
    CHECK(usos_sock_abort(socket)==0);
    CHECK(all_frames==before && reset_attempts==0);
    closed_and_reusable(socket);
    plain=usos_sock_open(USOS_SOCK_STREAM);
    CHECK(usos_sock_abort(plain)==0 && all_frames==before);
    CHECK(usos_sock_abort(-1)==USOS_SOCK_ENOTSOCK);
    CHECK(usos_sock_abort(USOS_MAX_SOCKETS)==USOS_SOCK_ENOTSOCK);
    CHECK(fin_packets==0 && idles==0);
    printf("udp_no_wire=1 unconnected_no_wire=1 invalid_double_close=1 idle_calls=%d\n",idles);
}
static void case_abort_listener(int full)
{
    int warm=connect_one(),listener=usos_sock_open(USOS_SOCK_STREAM),accepted,i,open=0;
    usos_u8 data[16];usos_u32 ip;usos_u16 port;
    CHECK(usos_sock_nonblocking(listener,1)==0);
    CHECK(usos_sock_bind(listener,CLIENT,8080)==0 && usos_sock_listen(listener,3)==0);
    listen_mode=1;
    push_tcp(45000,8080,0x55550000UL,0,USOS_TCP_SYN,4096,0,0);ticks(4);
    accepted=usos_sock_accept(listener,&ip,&port);
    CHECK(accepted>=0 && ip==SERVER && port==45000);
    listen_ack=1;
    push_tcp(45001,8080,0x55550000UL,0,USOS_TCP_SYN,4096,0,0);ticks(4);
    CHECK(usos_sock_readiness(listener)&USOS_SOCK_ACCEPT);
    listen_ack=0;
    push_tcp(45002,8080,0x55550000UL,0,USOS_TCP_SYN,4096,0,0);ticks(1);
    reset_failure=full?USOS_PKT_ERR_FULL:0;
    CHECK(usos_sock_abort(listener)==(full?USOS_SOCK_ENOBUFS:0));
    CHECK(reset_attempts==2 && reset_accepted==(full?0:2));
    reset_failure=0;
    for(i=0;i<2;i++) {
        const usos_u8 *tcp=resets[i]+34;
        CHECK(net_get16(tcp)==8080 && net_get16(tcp+2)==45001+i);
        CHECK(tcp[13]==(USOS_TCP_RST|USOS_TCP_ACK));
        CHECK(net_get32(tcp+8)==0x55550001UL);
        CHECK(net_checksum_tcp(CLIENT,SERVER,tcp,20)==0);
    }
    CHECK(usos_sock_kind(warm)==USOS_SOCK_STREAM);
    CHECK(usos_sock_kind(accepted)==USOS_SOCK_STREAM);
    push_tcp(45000,8080,0x55550001UL,client_next[0],USOS_TCP_ACK|USOS_TCP_PSH,4096,sizeof(data),0);ticks(1);
    CHECK(usos_sock_recv(accepted,data,sizeof(data))==sizeof(data));
    check_payload(data,sizeof(data),0);
    CHECK(usos_sock_kind(listener)==USOS_SOCK_ENOTSOCK);
    for(i=0;i<USOS_MAX_SOCKETS;i++) if(usos_sock_kind(i)==USOS_SOCK_STREAM) open++;
    CHECK(open==2); /* Accepted socket and unrelated outgoing connection. */
    CHECK(fin_packets==0 && idles==0);
    printf("backlog_established_and_syn_rcvd_reset=2 accepted_io_preserved=1 unrelated_preserved=1 reset_result=%s idle_calls=%d\n",full?"ENOBUFS":"accepted",idles);
}
static void case_send_failure(int full)
{
    int socket=connect_one(),before=all_frames;
    reset_failure=full?USOS_PKT_ERR_FULL:USOS_PKT_ERR_SEND;
    CHECK(usos_sock_abort(socket)==(full?USOS_SOCK_ENOBUFS:USOS_SOCK_EHOSTUNREACH));
    CHECK(reset_attempts==1 && reset_accepted==0 && all_frames==before+1);
    check_reset(0,ports[0],80,USOS_TCP_RST|USOS_TCP_ACK,client_next[0],server_base[0]);
    reset_failure=0;ticks(8);CHECK(reset_attempts==1);
    closed_and_reusable(socket);
    CHECK(fin_packets==0 && idles==0);
    printf("reset_tx_failure=%s slot_closed=1 no_retry=1 idle_calls=%d\n",full?"ENOBUFS":"EHOSTUNREACH",idles);
}
static void case_no_arp(void)
{
    int socket=usos_sock_open(USOS_SOCK_STREAM),before;
    CHECK(usos_sock_nonblocking(socket,1)==0);
    CHECK(usos_sock_connect(socket,SERVER,80,0)==USOS_SOCK_EWOULDBLOCK);
    before=all_frames; /* ARP reply is queued but not yet processed. */
    CHECK(usos_sock_abort(socket)==USOS_SOCK_EHOSTUNREACH);
    CHECK(all_frames==before && reset_attempts==0);
    closed_and_reusable(socket);
    CHECK(fin_packets==0 && idles==0);
    printf("unresolved_next_hop=EHOSTUNREACH no_arp_wait_or_send=1 slot_closed=1 idle_calls=%d\n",idles);
}
int main(int argc,char **argv)
{
    if(argc!=2) return 2;
    CHECK(usos_sock_startup()==0);
    if(!strcmp(argv[1],"connected")) case_connected(0);
    else if(!strcmp(argv[1],"pending")) case_connected(1);
    else if(!strcmp(argv[1],"connecting")) case_connecting();
    else if(!strcmp(argv[1],"udp")) case_abort_udp();
    else if(!strcmp(argv[1],"listener")) case_abort_listener(0);
    else if(!strcmp(argv[1],"listener-full")) case_abort_listener(1);
    else if(!strcmp(argv[1],"full")) case_send_failure(1);
    else if(!strcmp(argv[1],"failed-send")) case_send_failure(0);
    else if(!strcmp(argv[1],"no-arp")) case_no_arp();
    else return 2;
    CHECK(cancel_checks==0);
    printf("cancel_hook_calls=%d failures=%d\n",cancel_checks,failures);return failures?1:0;
}
