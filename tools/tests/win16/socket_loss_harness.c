/* Loss/recovery peer: validates actual retained bytes and cumulative ACKs.
 * Copyright (C) 2026 Maksymilian and the USOS Authors.
 * SPDX-License-Identifier: GPL-3.0-or-later */
#define main stage2_main
#define usos_pkt_send stage2_pkt_send
#include "socket_stage2_harness.c"
#undef usos_pkt_send
#undef main

#define LOSS_ROOM 8192
static int loss_active,loss_total,loss_delivered,loss_transmissions;
static int drop_count[16],drop_offset[16],drop_rules;
static usos_u32 loss_base,wire_seq[128],wire_time[128];
static usos_u16 wire_len[128];
static usos_u8 retained[LOSS_ROOM],retained_map[LOSS_ROOM];

int usos_pkt_send(const usos_u8 *frame,usos_u16 bytes)
{
    const usos_u8 *tcp=frame+34,*data;
    usos_u8 *reply;
    usos_u16 header,payload;
    usos_u32 seq,offset;
    int rc,i,drop=0;
    rc=stage2_pkt_send(frame,bytes);
    if(rc || net_get16(frame+12)!=USOS_ETH_IPV4 || frame[23]!=USOS_IP_TCP) return rc;
    if(tcp[13]&USOS_TCP_SYN) {
        /* Small negotiated MSS gives a real flight of eight segments in the
         * unchanged 4096-byte bounded queue, sufficient for duplicate ACKs. */
        reply=frames[(head-1)%Q]+34;
        net_put16(reply+22,536); net_put16(reply+16,0);
        net_put16(reply+16,net_checksum_tcp(SERVER,CLIENT,reply,24));
        return rc;
    }
    header=(usos_u16)((tcp[12]>>4)*4); payload=(usos_u16)(bytes-34-header);
    if(!loss_active || !payload) return rc;
    seq=net_get32(tcp+4);offset=(usos_u32)(seq-loss_base);data=tcp+header;
    CHECK(loss_transmissions<128);
    if(loss_transmissions<128) {
        wire_seq[loss_transmissions]=seq;wire_time[loss_transmissions]=now;
        wire_len[loss_transmissions]=payload;
    }
    loss_transmissions++;
    CHECK(offset+payload<=(usos_u32)loss_total);
    if(offset+payload>(usos_u32)loss_total) return rc;
    for(i=0;i<payload;i++) CHECK(data[i]==(usos_u8)((offset+i)%251));
    for(i=0;i<drop_rules;i++) if(offset==(usos_u32)drop_offset[i] && drop_count[i]) {
        --drop_count[i];drop=1;break;
    }
    if(drop) return rc; /* An actually lost segment generates no ACK. */
    for(i=0;i<payload;i++) {
        if(retained_map[offset+i]) CHECK(retained[offset+i]==data[i]);
        retained[offset+i]=data[i];retained_map[offset+i]=1;
    }
    while(loss_delivered<loss_total && retained_map[loss_delivered]) ++loss_delivered;
    push_tcp(80,ports[0],server_base[0],loss_base+(usos_u32)loss_delivered,
             USOS_TCP_ACK,4096,0,0);
    return rc;
}

static int warm_socket(void)
{
    int socket=connect_one();usos_u8 warm[4096];
    memset(warm,0,sizeof(warm));
    CHECK(usos_sock_send(socket,warm,sizeof(warm))==4096);ticks(8);
    CHECK(usos_sock_readiness(socket)&USOS_SOCK_WRITABLE);
    loss_base=client_next[0];auto_ack=0;data_packets=0;
    return socket;
}
static void payload_fill(usos_u8 *p,int n,int offset)
{ int i;for(i=0;i<n;i++) p[i]=(usos_u8)((offset+i)%251); }
static void loss_begin(int total)
{ loss_total=total;loss_active=1; }
static void loss_drop(int offset,int count)
{ CHECK(drop_rules<16);drop_offset[drop_rules]=offset;drop_count[drop_rules++]=count; }
static void validate_finished(int socket,int total)
{
    int i;usos_u8 next[256];
    CHECK(loss_delivered==total);CHECK(!usos_sock_error(socket,0));
    for(i=0;i<total;i++) CHECK(retained[i]==(usos_u8)(i%251));
    /* Sending again checks SND.NXT did not rewind during retransmission or
     * partial ACK compaction. The independent peer expects the next byte. */
    loss_total+=sizeof(next);payload_fill(next,sizeof(next),total);
    CHECK(usos_sock_send(socket,next,sizeof(next))==sizeof(next));ticks(6);
    CHECK(loss_delivered==loss_total);CHECK(idles==0);
}
static void case_fast(int multiple)
{
    int socket=warm_socket(),first_retry=-1,i;usos_u8 data[4096];
    payload_fill(data,sizeof(data),0);loss_begin(sizeof(data));loss_drop(0,1);
    if(multiple) { loss_drop(3*536,1);loss_drop(7*536,1); }
    CHECK(usos_sock_send(socket,data,sizeof(data))==sizeof(data));
    CHECK(loss_transmissions==8); /* Original flight, before any peer ACK. */
    now=10;ticks(12);
    for(i=1;i<loss_transmissions;i++) if(wire_seq[i]==loss_base) { first_retry=i;break; }
    CHECK(first_retry>=8);CHECK(first_retry>=0 && wire_time[first_retry]==10);
    CHECK(loss_transmissions==8+(multiple?3:1));
    validate_finished(socket,sizeof(data));
    printf("fast_retransmit=3dup multiple_losses=%d recovered_without_rto=1 bytes_preserved=1 snd_nxt_preserved=1 idle_calls=%d\n",multiple?3:1,idles);
}
static void case_partial(void)
{
    int socket=warm_socket();usos_u8 data[4096];
    payload_fill(data,sizeof(data),0);loss_begin(sizeof(data));
    /* The first hole starts 107 bytes into the original segment: ACK only a
     * prefix, then three real out-of-order duplicate acknowledgments. */
    loss_drop(0,1);loss_drop(3*536,1);
    CHECK(usos_sock_send(socket,data,sizeof(data))==sizeof(data));
    memcpy(retained,data,107);memset(retained_map,1,107);loss_delivered=107;
    /* Replace queued ACKs with the receiver's correctly advanced prefix. */
    head=tail;
    push_tcp(80,ports[0],server_base[0],loss_base+107,USOS_TCP_ACK,4096,0,0);ticks(1);
    push_tcp(80,ports[0],server_base[0],loss_base+107,USOS_TCP_ACK,4096,0,0);
    push_tcp(80,ports[0],server_base[0],loss_base+107,USOS_TCP_ACK,4096,0,0);
    push_tcp(80,ports[0],server_base[0],loss_base+107,USOS_TCP_ACK,4096,0,0);
    now=20;ticks(12);
    CHECK(wire_seq[8]==loss_base+107);CHECK(wire_len[8]==536);
    CHECK(loss_delivered==4096);CHECK(loss_transmissions==10);
    validate_finished(socket,sizeof(data));
    printf("partial_ack_inside_segment=107 subsequent_loss=1 recovered_without_rto=1 idle_calls=%d\n",idles);
}
static void case_queue(void)
{
    int socket=warm_socket();usos_u8 data[4096];
    payload_fill(data,sizeof(data),0);loss_begin(sizeof(data));loss_drop(0,1);
    CHECK(usos_sock_send(socket,data,sizeof(data))==sizeof(data));
    fail_full=2;now=100;ticks(1);CHECK(loss_transmissions==8);
    ticks(1);CHECK(loss_transmissions==8);CHECK(!usos_sock_error(socket,0));
    ticks(8);CHECK(loss_transmissions==9);CHECK(wire_time[8]==100);
    validate_finished(socket,sizeof(data));
    printf("fast_retransmit_queue_full=2 request_preserved=1 retry_budget_preserved=1 idle_calls=%d\n",idles);
}
static void case_timeout(void)
{
    int socket=warm_socket();usos_u8 data[4096];
    payload_fill(data,sizeof(data),0);loss_begin(sizeof(data));loss_drop(0,2);loss_drop(3*536,1);
    CHECK(usos_sock_send(socket,data,sizeof(data))==sizeof(data));
    now=10;ticks(8);CHECK(loss_transmissions==9);CHECK(loss_delivered==0);
    now=1009;ticks(1);CHECK(loss_transmissions==9);
    now=1010;ticks(4);CHECK(loss_transmissions==10);CHECK(loss_delivered==3*536);
    now=2009;ticks(1);CHECK(loss_transmissions==10);
    now=2010;ticks(4);CHECK(loss_transmissions==11);
    validate_finished(socket,sizeof(data));
    printf("lost_fast_retransmission=1 rto_fallback=1010,2010 multiple_losses=2 idle_calls=%d\n",idles);
}
static void case_no_false(void)
{
    int socket=warm_socket(),i;usos_u8 data[1000];usos_u32 base=loss_base;
    payload_fill(data,sizeof(data),0);loss_begin(sizeof(data));loss_drop(0,16);loss_drop(536,16);
    CHECK(usos_sock_send(socket,data,sizeof(data))==sizeof(data));CHECK(loss_transmissions==2);
    /* Window updates and stale/wrong-sequence ACKs are not duplicate ACKs. */
    for(i=0;i<4;i++) push_tcp(80,ports[0],server_base[0],base,USOS_TCP_ACK,(usos_u16)(3000+i),0,0);
    for(i=0;i<4;i++) push_tcp(80,ports[0],server_base[0],base-1,USOS_TCP_ACK,4096,0,0);
    for(i=0;i<4;i++) push_tcp(80,ports[0],server_base[0]+1,base,USOS_TCP_ACK,4096,0,0);
    now=100;ticks(2);CHECK(loss_transmissions==2);
    now=999;ticks(1);CHECK(loss_transmissions==2);
    now=1000;ticks(1);CHECK(loss_transmissions==3);CHECK(wire_seq[2]==base);
    printf("window_stale_sequence_ack_not_duplicates=1 original_rto=1000 idle_calls=%d\n",idles);
}
int main(int argc,char **argv)
{
    if(argc!=2)return 2;CHECK(usos_sock_startup()==0);
    if(!strcmp(argv[1],"fast"))case_fast(0);
    else if(!strcmp(argv[1],"multiple"))case_fast(1);
    else if(!strcmp(argv[1],"partial"))case_partial();
    else if(!strcmp(argv[1],"queue"))case_queue();
    else if(!strcmp(argv[1],"timeout"))case_timeout();
    else if(!strcmp(argv[1],"no-false"))case_no_false();
    else return 2;
    printf("failures=%d\n",failures);return failures?1:0;
}
