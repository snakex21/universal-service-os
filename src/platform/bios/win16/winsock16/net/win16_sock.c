/* Bounded cooperative Win16 socket engine. GPL-3.0-or-later.
 * Copyright (C) 2026 Maksymilian and the USOS Authors.
 * Sixteen independent sockets; no global head-of-line RX blocking.
 * The Windows timer drives tick(), which never waits or dispatches messages.
 * TCP receive bytes are retained before ACK advancement, including holes.
 */
#include "net.h"
#include "usos_pkt.h"
#include "win16_sock.h"

#define USOS_EPHEMERAL_BASE 49152U
#define USOS_UDP_RX 512
#define USOS_RX_ROOM 4096
#define USOS_TX_ROOM 4096
#define USOS_DRAIN_LIMIT 32
#define USOS_ARP_TIMEOUT_MS 2000UL
#define USOS_DNS_TIMEOUT_MS 5000UL
#define USOS_CONNECT_MS 31000UL
#define USOS_IO_MS 31000UL
#define USOS_CLOSE_MS 2000UL
#define USOS_TCP_RTO_MS 1000UL
#define USOS_TCP_RTO_MAX 60000UL
#define USOS_ARP_AGE_MS 1000UL

#if defined(__WATCOMC__)
#define USOS_FAR __far
#else
#define USOS_FAR
#endif

typedef struct {
    int used, type, connected, connecting, nonblocking, peer_fin, error;
    int connect_done, fin_pending, tx_started;
    int recovering, fast_pending;
    int listening, backlog, parent, read_shutdown, write_shutdown, udp_ready;
    net_tcp tcp;
    usos_u32 raddr, rx_base, fin_seq;
    usos_u32 tx_tick, tx_rto, connect_at, arp_tick, recover_edge;
    usos_u32 udp_address;
    usos_u16 lport, rport, rx_head, rx_len, udp_len, tx_len, tx_sent, cwnd, ssthresh;
    usos_u16 udp_port;
    usos_u8 control, dupacks;
    usos_u8 rx[USOS_RX_ROOM], rx_map[USOS_RX_ROOM/8];
    usos_u8 tx[USOS_TX_ROOM], udp[USOS_UDP_RX];
} usos_sock_st;

/* Each object is below 64KiB. Explicit far storage prevents a 140KiB
 * aggregate from overflowing the Win16 DLL's DGROUP/16-bit array index. */
#define USOS_STORAGE(n) static usos_sock_st USOS_FAR usos_storage_##n
USOS_STORAGE(0); USOS_STORAGE(1); USOS_STORAGE(2); USOS_STORAGE(3);
USOS_STORAGE(4); USOS_STORAGE(5); USOS_STORAGE(6); USOS_STORAGE(7);
USOS_STORAGE(8); USOS_STORAGE(9); USOS_STORAGE(10); USOS_STORAGE(11);
USOS_STORAGE(12); USOS_STORAGE(13); USOS_STORAGE(14); USOS_STORAGE(15);
static usos_sock_st *usos_socks[USOS_MAX_SOCKETS] = {
    &usos_storage_0,&usos_storage_1,&usos_storage_2,&usos_storage_3,
    &usos_storage_4,&usos_storage_5,&usos_storage_6,&usos_storage_7,
    &usos_storage_8,&usos_storage_9,&usos_storage_10,&usos_storage_11,
    &usos_storage_12,&usos_storage_13,&usos_storage_14,&usos_storage_15
};
static usos_u8 usos_tx_frame[USOS_NET_FRAME_MAX], usos_rx_frame[USOS_NET_FRAME_MAX];
static usos_u8 usos_our_mac[6];
static net_arp usos_arp;
static int usos_ready, usos_pumping, usos_ticking;
static usos_u16 usos_next_port=USOS_EPHEMERAL_BASE, usos_dns_seq;
static usos_u32 usos_arp_age_at;
static int usos_capture_active;
static usos_u16 usos_capture_port, usos_capture_len;
static usos_u32 usos_capture_ip;
static usos_u8 usos_capture_buf[512];

static void usos_zero(void *dst,unsigned int len)
{ usos_u8 *d=(usos_u8 *)dst; while(len--) *d++=0; }
static void usos_copy(void *dst,const void *src,unsigned int len)
{ usos_u8 *d=(usos_u8 *)dst; const usos_u8 *s=(const usos_u8 *)src; while(len--) *d++=*s++; }
static int usos_due(usos_u32 now,usos_u32 before,usos_u32 period)
{ return (usos_u32)(now-before)>=period; }
static usos_sock_st *usos_slot(int n)
{ return n>=0 && n<USOS_MAX_SOCKETS && usos_socks[n]->used ? usos_socks[n] : 0; }
static usos_u16 usos_ephemeral(void)
{
    usos_u16 port; int attempt,i,busy;
    for(attempt=0;attempt<16384;attempt++) {
        port=usos_next_port++; if(usos_next_port<USOS_EPHEMERAL_BASE) usos_next_port=USOS_EPHEMERAL_BASE;
        busy=0; for(i=0;i<USOS_MAX_SOCKETS;i++) if(usos_socks[i]->used && usos_socks[i]->lport==port) busy=1;
        if(!busy) return port;
    }
    return 0;
}
usos_u32 usos_sock_local_ip(void) { return usos_pkt_ip(); }
int usos_sock_ready(void) { return usos_ready; }
static void usos_pump(void);
static int usos_tcp_wire(usos_sock_st *,usos_u32,usos_u8,const usos_u8 *,usos_u16,usos_u32);

/* Nonblocking next-hop resolution. Callers rebuild unsent TCP frames later;
 * sequence space is consumed only after the transport accepted the frame. */
static int usos_mac(usos_u32 dst,usos_u8 mac[6],int request)
{
    usos_u32 mask=usos_pkt_mask();
    usos_u32 hop=((dst&mask)==(usos_pkt_ip()&mask)) ? dst : usos_pkt_gateway();
    usos_u8 arp[42];
    usos_u16 n;
    if(!hop) return -1;
    if(net_arp_lookup(&usos_arp,hop,mac)) return 1;
    if(request) { n=net_arp_build_request(arp,&usos_arp,hop); if(n) (void)usos_pkt_send(arp,n); }
    return 0;
}
static int usos_frame_try(usos_u32 dst,usos_u16 length,int request)
{
    usos_u8 mac[6];
    int rc=usos_mac(dst,mac,request);
    if(rc<=0) return rc;
    net_eth_build(usos_tx_frame,mac,usos_our_mac,USOS_ETH_IPV4);
    rc=usos_pkt_send(usos_tx_frame,(usos_u16)(length+14));
    if(rc==USOS_PKT_ERR_FULL) return 0;
    return rc==USOS_PKT_OK ? 1 : -1;
}
/* Synchronous DNS/UDP compatibility helper. Tick/ACK/retransmission never
 * call it. Preserve the built datagram while other sockets are pumped. */
static int usos_frame_send(usos_u32 dst,usos_u16 length)
{
    usos_u8 saved[USOS_NET_MTU];
    usos_u32 start=(usos_u32)usos_abi_now();
    int rc;
    if(!length || length>USOS_NET_MTU) return 0;
    usos_copy(saved,usos_tx_frame+14,length);
    for(;;) {
        usos_copy(usos_tx_frame+14,saved,length);
        rc=usos_frame_try(dst,length,1);
        if(rc) return rc>0;
        if(usos_due((usos_u32)usos_abi_now(),start,USOS_ARP_TIMEOUT_MS)) return 0;
        usos_sock_tick(); usos_abi_idle();
    }
}
static usos_u16 usos_receive_window(usos_sock_st *sk)
{ return (usos_u16)(USOS_RX_ROOM-sk->rx_len); }
static void usos_tcp_send_ack(usos_sock_st *sk)
{
    usos_u16 n;
    sk->tcp.rcv_wnd=usos_receive_window(sk);
    n=net_tcp_build_at(&sk->tcp,usos_tx_frame+14,sk->tcp.snd_nxt,
        USOS_TCP_ACK,sk->tcp.rcv_wnd,0,0);
    if(n) (void)usos_frame_try(sk->raddr,n,0);
}

/* All congestion state is bounded by the retained 4096-byte send queue.
 * RFC5681/6582: loss reduces the threshold once per recovery window. */
static usos_u16 usos_tcp_threshold(usos_sock_st *sk)
{
    usos_u32 threshold=(usos_u32)(sk->tcp.snd_nxt-sk->tcp.snd_una)/2;
    usos_u32 minimum=(usos_u32)sk->tcp.peer_mss*2;
    if(threshold<minimum) threshold=minimum;
    return (usos_u16)(threshold>USOS_TX_ROOM?USOS_TX_ROOM:threshold);
}
static usos_u16 usos_tcp_window(usos_u32 window)
{ return (usos_u16)(window>USOS_TX_ROOM?USOS_TX_ROOM:window); }

static void usos_tcp_acknowledged(usos_sock_st *sk,usos_u16 bytes)
{
    usos_u32 window,growth;
    sk->dupacks=0;
    if(sk->recovering) {
        if((usos_s32)(sk->tcp.snd_una-sk->recover_edge)>=0) {
            sk->recovering=0; sk->fast_pending=0; sk->cwnd=sk->ssthresh;
        } else {
            /* Partial ACK: another hole remains below the original sent
             * upper edge. Retained bytes now start at the next lost range.
             * Deflate by newly ACKed bytes and add back one SMSS when a
             * full segment was ACKed, without rewinding SND.NXT. */
            window=sk->cwnd>bytes?(usos_u32)(sk->cwnd-bytes):0;
            if(bytes>=sk->tcp.peer_mss) window+=sk->tcp.peer_mss;
            if(window<sk->tcp.peer_mss) window=sk->tcp.peer_mss;
            sk->cwnd=usos_tcp_window(window); sk->fast_pending=1;
        }
        return;
    }
    if(sk->cwnd<sk->ssthresh) {
        growth=bytes<sk->tcp.peer_mss?bytes:sk->tcp.peer_mss;
    } else {
        growth=(usos_u32)sk->tcp.peer_mss*sk->tcp.peer_mss/sk->cwnd;
        if(!growth) growth=1;
    }
    sk->cwnd=usos_tcp_window((usos_u32)sk->cwnd+growth);
}

static void usos_tcp_duplicate_ack(usos_sock_st *sk)
{
    if(sk->recovering) {
        sk->cwnd=usos_tcp_window((usos_u32)sk->cwnd+sk->tcp.peer_mss);
        return;
    }
    if(sk->dupacks<3) ++sk->dupacks;
    if(sk->dupacks!=3 || (usos_s32)(sk->tcp.snd_una-sk->recover_edge)<0) return;
    sk->ssthresh=usos_tcp_threshold(sk);
    sk->recover_edge=sk->tcp.snd_nxt;
    sk->cwnd=usos_tcp_window((usos_u32)sk->ssthresh+3UL*sk->tcp.peer_mss);
    sk->recovering=1; sk->fast_pending=1;
}
static void usos_fail(usos_sock_st *sk,int error)
{ sk->error=error; if(sk->connecting) sk->connect_done=1; sk->connecting=0; sk->tcp.state=USOS_TCP_RESET; }

static void usos_discard_receive(usos_sock_st *sk)
{
    usos_u16 i,at;
    for(i=0;i<sk->rx_len;i++) { at=(usos_u16)((sk->rx_head+i)%USOS_RX_ROOM); sk->rx_map[at/8]&=(usos_u8)~(1U<<(at%8)); }
    sk->rx_head=(usos_u16)((sk->rx_head+sk->rx_len)%USOS_RX_ROOM);
    sk->rx_base+=sk->rx_len; sk->rx_len=0;
}

/* rx_map records occupied ring positions, so a segment beyond a gap cannot
 * be ACKed until that gap has actually been retained. Overlapping/duplicate
 * bytes do not consume extra window and the first retained copy wins. */
static void usos_tcp_receive(usos_sock_st *sk,const usos_u8 *data,usos_u16 len,
                              usos_u32 sequence,usos_u8 flags)
{
    usos_u16 i,at;
    usos_u32 relative,fin;
    if(sk->peer_fin) { usos_tcp_send_ack(sk); return; }
    for(i=0;i<len;i++) {
        relative=(usos_u32)(sequence+i-sk->rx_base);
        if(relative>=USOS_RX_ROOM) continue;
        at=(usos_u16)((sk->rx_head+(usos_u16)relative)%USOS_RX_ROOM);
        if(!(sk->rx_map[at/8]&(1U<<(at%8)))) {
            sk->rx[at]=data[i]; sk->rx_map[at/8]|=(usos_u8)(1U<<(at%8));
        }
    }
    if(flags&USOS_TCP_FIN) {
        fin=sequence+len;
        relative=(usos_u32)(fin-sk->rx_base);
        if(relative<=USOS_RX_ROOM) { sk->fin_seq=fin; sk->fin_pending=1; }
    }
    while(sk->rx_len<USOS_RX_ROOM) {
        if(sk->fin_pending && sk->rx_base+sk->rx_len==sk->fin_seq) break;
        at=(usos_u16)((sk->rx_head+sk->rx_len)%USOS_RX_ROOM);
        if(!(sk->rx_map[at/8]&(1U<<(at%8)))) break;
        sk->rx_len++;
    }
    sk->tcp.rcv_nxt=sk->rx_base+sk->rx_len;
    if(sk->fin_pending && sk->tcp.rcv_nxt==sk->fin_seq) {
        sk->tcp.rcv_nxt++; sk->peer_fin=1; sk->fin_pending=0;
        if(sk->tcp.state==USOS_TCP_ESTABLISHED) sk->tcp.state=USOS_TCP_CLOSE_WAIT;
        else if(sk->tcp.state==USOS_TCP_FIN_WAIT) sk->tcp.state=USOS_TCP_TIME_WAIT;
    }
    if(sk->read_shutdown) usos_discard_receive(sk);
    usos_tcp_send_ack(sk);
}
static void usos_tcp_input(usos_u8 *packet,usos_u16 length)
{
    net_ip_view ip;
    const usos_u8 *segment,*data;
    usos_u16 len,sport,dport,acknowledged,previous_window;
    usos_u8 flags;
    usos_u32 before,delta;
    int i,event,j,child,count;
    usos_sock_st *sk;
    if(net_ip_parse(packet,length,&ip,&segment) || ip.len<20) return;
    sport=net_get16(segment); dport=net_get16(segment+2);
    for(i=0;i<USOS_MAX_SOCKETS;i++) {
        sk=usos_socks[i];
        if(!sk->used || sk->type!=USOS_SOCK_STREAM || sk->lport!=dport || sk->rport!=sport || sk->raddr!=ip.src) continue;
        before=sk->tcp.snd_una; previous_window=sk->tcp.snd_wnd;
        if(sk->tcp.state==USOS_TCP_SYN_RCVD && (segment[13]&USOS_TCP_SYN) && !(segment[13]&USOS_TCP_ACK)) {
            if(net_get32(segment+4)+1==sk->tcp.rcv_nxt && !net_checksum_tcp(ip.src,ip.dst,segment,ip.len))
                (void)usos_tcp_wire(sk,sk->tcp.iss,USOS_TCP_SYN|USOS_TCP_ACK,0,0,(usos_u32)usos_abi_now());
            return;
        }
        event=net_tcp_input(&sk->tcp,packet,length,&data,&len,&flags);
        if(event==USOS_TCP_EV_BAD || event==USOS_TCP_EV_IGNORE) return;
        if(event==USOS_TCP_EV_RST) {
            usos_fail(sk,sk->connecting ? USOS_SOCK_ECONNREFUSED : USOS_SOCK_ECONNRESET); return;
        }
        if(event==USOS_TCP_EV_SYNACK) {
            sk->connected=1; sk->connecting=0; sk->connect_done=sk->parent<0;
            sk->control=0; sk->tx_started=0; sk->tx_rto=USOS_TCP_RTO_MS;
            sk->cwnd=(usos_u16)(2*sk->tcp.peer_mss);
            if(sk->cwnd>USOS_TX_ROOM) sk->cwnd=USOS_TX_ROOM;
            sk->ssthresh=USOS_TX_ROOM; sk->recover_edge=sk->tcp.snd_una;
            sk->recovering=sk->fast_pending=0; sk->dupacks=0;
            sk->rx_base=sk->tcp.rcv_nxt;
            usos_tcp_receive(sk,data,len,sk->tcp.input_seq,(usos_u8)(flags&USOS_TCP_FIN));
            return;
        }
        if(sk->control&USOS_TCP_FIN) {
            if(sk->tcp.snd_una==sk->tcp.snd_nxt) { sk->control=0; sk->tx_started=0; }
        }
        delta=(usos_u32)(sk->tcp.snd_una-before);
        if(delta && delta<=USOS_TX_ROOM) {
            acknowledged=(usos_u16)delta;
            if(acknowledged>sk->tx_sent) acknowledged=sk->tx_sent;
            if(acknowledged) {
                usos_copy(sk->tx,sk->tx+acknowledged,(unsigned int)(sk->tx_len-acknowledged));
                sk->tx_len=(usos_u16)(sk->tx_len-acknowledged);
                sk->tx_sent=(usos_u16)(sk->tx_sent-acknowledged);
                sk->tx_tick=(usos_u32)usos_abi_now(); sk->tx_rto=USOS_TCP_RTO_MS;
                usos_tcp_acknowledged(sk,acknowledged);
            }
        } else if(!delta && sk->tx_sent && !sk->control &&
                  !len && !(flags&(USOS_TCP_SYN|USOS_TCP_FIN|USOS_TCP_RST)) &&
                  (flags&USOS_TCP_ACK) && net_get32(segment+8)==before &&
                  previous_window==sk->tcp.snd_wnd &&
                  sk->tcp.input_seq==sk->tcp.rcv_nxt) {
            /* A window update, stale ACK, data packet or unrelated sequence
             * must not manufacture the three duplicate ACKs of a loss. */
            usos_tcp_duplicate_ack(sk);
        }
        if(event==USOS_TCP_EV_DATA) usos_tcp_receive(sk,data,len,sk->tcp.input_seq,flags);
        else if(event==USOS_TCP_EV_DUP) usos_tcp_send_ack(sk);
        return;
    }
    /* Only a validated new SYN can occupy the bounded listener backlog. */
    if(!(segment[13]&USOS_TCP_SYN) || (segment[13]&(USOS_TCP_ACK|USOS_TCP_RST|USOS_TCP_FIN))) return;
    for(i=0;i<USOS_MAX_SOCKETS;i++) {
        sk=usos_socks[i];
        if(!sk->used || !sk->listening || sk->lport!=dport) continue;
        count=0; for(j=0;j<USOS_MAX_SOCKETS;j++) if(usos_socks[j]->used && usos_socks[j]->parent==i) count++;
        if(count>=sk->backlog) return;
        child=usos_sock_open(USOS_SOCK_STREAM); if(child<0) return;
        sk=usos_socks[child]; sk->lport=dport; sk->rport=sport; sk->raddr=ip.src;
        sk->parent=i; sk->nonblocking=usos_socks[i]->nonblocking;
        (void)net_tcp_open(&sk->tcp,usos_pkt_ip(),dport,ip.src,sport);
        sk->tcp.state=USOS_TCP_LISTEN; sk->tcp.buffered_receive=1;
        event=net_tcp_input(&sk->tcp,packet,length,&data,&len,&flags);
        if(event!=USOS_TCP_EV_SYNACK) { usos_zero(sk,sizeof(*sk)); return; }
        sk->rx_base=sk->tcp.rcv_nxt; sk->control=USOS_TCP_SYN|USOS_TCP_ACK;
        sk->connect_at=(usos_u32)usos_abi_now(); sk->arp_tick=sk->connect_at-250UL;
        return;
    }
}
static void usos_udp_input(usos_u8 *packet,usos_u16 length)
{
    net_ip_view ip;
    net_udp_view udp;
    usos_u16 count;
    int i;
    usos_sock_st *sk;
    if(net_ip_parse(packet,length,&ip,0) || net_udp_parse(packet,length,&udp)) return;
    if(usos_capture_active && ip.src==usos_capture_ip && udp.sport==53 && udp.dport==usos_capture_port) {
        count=udp.data_len>sizeof(usos_capture_buf)?sizeof(usos_capture_buf):udp.data_len;
        usos_copy(usos_capture_buf,udp.data,count); usos_capture_len=count;
    }
    for(i=0;i<USOS_MAX_SOCKETS;i++) {
        sk=usos_socks[i];
        if(!sk->used || sk->type!=USOS_SOCK_DGRAM || sk->lport!=udp.dport || (sk->connected && (sk->raddr!=ip.src || sk->rport!=udp.sport))) continue;
        if(sk->udp_ready) return;
        count=udp.data_len>USOS_UDP_RX?USOS_UDP_RX:udp.data_len;
        usos_copy(sk->udp,udp.data,count); sk->udp_len=count; sk->udp_ready=1;
        sk->udp_address=ip.src; sk->udp_port=udp.sport; return;
    }
}
static void usos_eth_input(usos_u16 length)
{
    usos_u16 type,bytes,n;
    const usos_u8 *payload,*body;
    net_ip_view ip;
    if(net_eth_parse(usos_rx_frame,length,&type,&payload,&bytes)) return;
    if(type==USOS_ETH_ARP) { (void)net_arp_parse(&usos_arp,usos_rx_frame,length,0,0,0); return; }
    if(type!=USOS_ETH_IPV4 || net_ip_parse(payload,bytes,&ip,&body) || ip.dst!=usos_pkt_ip()) return;
    if(ip.proto==USOS_IP_TCP) usos_tcp_input((usos_u8 *)payload,bytes);
    else if(ip.proto==USOS_IP_UDP) usos_udp_input((usos_u8 *)payload,bytes);
    else if(ip.proto==USOS_IP_ICMP && net_icmp_echo_request(payload,bytes,0,0)==USOS_NET_OK) {
        n=net_icmp_build_reply(usos_tx_frame+14,usos_pkt_ip(),ip.src,body,ip.len);
        if(n) (void)usos_frame_try(ip.src,n,0);
    }
}
static void usos_pump(void)
{
    usos_u16 length;
    int count=0;
    if(!usos_ready || usos_pumping) return;
    usos_pumping=1;
    while(count++<USOS_DRAIN_LIMIT && usos_pkt_recv(usos_rx_frame,sizeof(usos_rx_frame),&length)==USOS_PKT_OK)
        usos_eth_input(length);
    usos_pumping=0;
}
static int usos_tcp_wire(usos_sock_st *sk,usos_u32 seq,usos_u8 flags,
                          const usos_u8 *bytes,usos_u16 length,usos_u32 now)
{
    usos_u16 n;
    int request=usos_due(now,sk->arp_tick,250UL),rc;
    if(request) sk->arp_tick=now;
    sk->tcp.rcv_wnd=usos_receive_window(sk);
    n=net_tcp_build_at(&sk->tcp,usos_tx_frame+14,seq,flags,sk->tcp.rcv_wnd,bytes,length);
    if(!n) return -1;
    rc=usos_frame_try(sk->raddr,n,request);
    if(rc<0) usos_fail(sk,USOS_SOCK_EHOSTUNREACH);
    return rc;
}
static void usos_tcp_service(usos_sock_st *sk,usos_u32 now)
{
    usos_u16 chunk,available;
    usos_u32 flight;
    int rc;
    if(sk->error) { if(sk->parent>=0) usos_zero(sk,sizeof(*sk)); return; }
    if(sk->type!=USOS_SOCK_STREAM) return;
    if(sk->listening) return;
    if(sk->connecting && usos_due(now,sk->connect_at,USOS_CONNECT_MS)) { usos_fail(sk,USOS_SOCK_ETIMEDOUT); return; }
    if(sk->control && !sk->tx_started) {
        rc=usos_tcp_wire(sk,sk->tcp.snd_nxt,sk->control,0,0,now);
        if(rc>0) { sk->tcp.snd_nxt++; sk->tx_tick=now; sk->tx_started=1; if(sk->control&USOS_TCP_FIN) sk->tcp.fin_sent=1; }
        return;
    }
    if(sk->tcp.snd_nxt!=sk->tcp.snd_una && sk->tx_started && usos_due(now,sk->tx_tick,sk->tx_rto)) {
        if(sk->tcp.retries>=USOS_NET_TCP_RETRIES) { usos_fail(sk,USOS_SOCK_ETIMEDOUT); return; }
        chunk=sk->tx_sent>sk->tcp.peer_mss?sk->tcp.peer_mss:sk->tx_sent;
        rc=usos_tcp_wire(sk,sk->tcp.snd_una,sk->control?sk->control:(USOS_TCP_ACK|USOS_TCP_PSH),chunk?sk->tx:0,chunk,now);
        if(rc>0) {
            sk->ssthresh=usos_tcp_threshold(sk);
            sk->recover_edge=sk->tcp.snd_nxt;
            sk->recovering=sk->fast_pending=0; sk->dupacks=0;
            (void)net_tcp_timeout(&sk->tcp);
            sk->tx_tick=now; sk->tx_rto=sk->tx_rto<USOS_TCP_RTO_MAX/2?sk->tx_rto*2:USOS_TCP_RTO_MAX;
            sk->cwnd=sk->tcp.peer_mss;
        }
        return;
    }
    if(sk->fast_pending && sk->tx_sent && !sk->control) {
        chunk=sk->tx_sent>sk->tcp.peer_mss?sk->tcp.peer_mss:sk->tx_sent;
        rc=usos_tcp_wire(sk,sk->tcp.snd_una,USOS_TCP_ACK|USOS_TCP_PSH,sk->tx,chunk,now);
        /* A full transport queue leaves the recovery request pending. The
         * send upper edge and retained byte counts never change on retry. */
        if(rc>0) { sk->fast_pending=0; sk->tx_tick=now; }
        return;
    }
    if(!sk->connected || sk->control) return;
    if(sk->tx_len && !sk->tx_sent && !sk->tcp.snd_wnd) {
        if(!sk->tx_started) { sk->tx_started=1; sk->tx_tick=now; }
        if(usos_due(now,sk->tx_tick,sk->tx_rto) && usos_tcp_wire(sk,sk->tcp.snd_nxt,USOS_TCP_ACK|USOS_TCP_PSH,sk->tx,1,now)>0) {
            sk->tcp.snd_nxt++; sk->tx_sent=1; sk->tx_tick=now;
        }
        return;
    }
    while(sk->tx_sent<sk->tx_len) {
        flight=(usos_u32)(sk->tcp.snd_nxt-sk->tcp.snd_una);
        available=sk->tcp.snd_wnd<sk->cwnd?sk->tcp.snd_wnd:sk->cwnd;
        if(flight>=available) break;
        available=(usos_u16)(available-flight);
        chunk=(usos_u16)(sk->tx_len-sk->tx_sent);
        if(chunk>sk->tcp.peer_mss) chunk=sk->tcp.peer_mss;
        if(chunk>available) chunk=available;
        if(!chunk) break;
        rc=usos_tcp_wire(sk,sk->tcp.snd_nxt,USOS_TCP_ACK|USOS_TCP_PSH,sk->tx+sk->tx_sent,chunk,now);
        if(rc<=0) break;
        if(!flight) sk->tx_tick=now;
        sk->tcp.snd_nxt+=chunk; sk->tx_sent=(usos_u16)(sk->tx_sent+chunk); sk->tx_started=1;
    }
    if(sk->write_shutdown && !sk->tx_len && !sk->tcp.fin_sent && !sk->control) {
        sk->control=USOS_TCP_FIN|USOS_TCP_ACK; sk->tx_started=0;
        sk->tcp.state=sk->peer_fin?USOS_TCP_LAST_ACK:USOS_TCP_FIN_WAIT;
    }
}
void usos_sock_tick(void)
{
    usos_u32 now;
    int i;
    if(!usos_ready || usos_ticking) return;
    usos_ticking=1; now=(usos_u32)usos_abi_now();
    usos_pkt_poll(1); usos_pump();
    for(i=0;i<USOS_MAX_SOCKETS;i++) if(usos_socks[i]->used) usos_tcp_service(usos_socks[i],now);
    if(usos_due(now,usos_arp_age_at,USOS_ARP_AGE_MS)) { usos_arp_age_at=now; net_arp_tick(&usos_arp); }
    usos_ticking=0;
}
int usos_sock_startup(void)
{
    int i,rc;
    if(usos_ready) return 0;
    rc=usos_pkt_init(); if(rc) return USOS_SOCK_ENOTREADY;
    rc=usos_pkt_attach(); if(rc) { usos_pkt_term(); return USOS_SOCK_ENOTREADY; }
    if(usos_pkt_mac(usos_our_mac)) usos_zero(usos_our_mac,6);
    net_arp_init(&usos_arp,usos_our_mac,usos_pkt_ip());
    for(i=0;i<USOS_MAX_SOCKETS;i++) usos_zero(usos_socks[i],sizeof(usos_sock_st));
    usos_ready=1; usos_pumping=usos_ticking=0; usos_capture_active=0;
    usos_arp_age_at=(usos_u32)usos_abi_now(); usos_next_port=USOS_EPHEMERAL_BASE; return 0;
}
void usos_sock_shutdown(void)
{
    int i;
    for(i=0;i<USOS_MAX_SOCKETS;i++) if(usos_socks[i]->used) (void)usos_sock_close(i);
    usos_ready=0; usos_pkt_term();
}
int usos_sock_open(int type)
{
    int i; usos_sock_st *sk;
    if(!usos_ready) return USOS_SOCK_ENOTREADY;
    if(type!=USOS_SOCK_STREAM && type!=USOS_SOCK_DGRAM) return USOS_NET_ERR_ARG;
    for(i=0;i<USOS_MAX_SOCKETS;i++) {
        sk=usos_socks[i]; if(sk->used) continue;
        usos_zero(sk,sizeof(*sk)); sk->used=1; sk->type=type; sk->lport=usos_ephemeral(); sk->parent=-1;
        sk->tx_rto=USOS_TCP_RTO_MS; sk->cwnd=2*USOS_NET_TCP_MSS; sk->ssthresh=USOS_TX_ROOM;
        net_tcp_init(&sk->tcp,((usos_u32)sk->lport<<16)^(usos_u32)usos_abi_now()); return i;
    }
    return USOS_SOCK_EMFILE;
}
int usos_sock_nonblocking(int slot,int enabled)
{ usos_sock_st *sk=usos_slot(slot); if(!sk) return USOS_SOCK_ENOTSOCK; sk->nonblocking=enabled!=0; return 0; }
int usos_sock_available(int slot,usos_u32 *count)
{ usos_sock_st *sk=usos_slot(slot); if(!sk) return USOS_SOCK_ENOTSOCK; if(!count) return USOS_NET_ERR_ARG; *count=sk->type==USOS_SOCK_DGRAM?sk->udp_len:sk->rx_len; return 0; }
int usos_sock_error(int slot,int clear)
{ usos_sock_st *sk=usos_slot(slot); int e; if(!sk) return USOS_SOCK_ENOTSOCK; e=sk->error; if(clear) sk->error=0; return e; }
int usos_sock_readiness(int slot)
{
    usos_sock_st *sk=usos_slot(slot); int ready=0,i;
    if(!sk) return USOS_SOCK_ENOTSOCK;
    if(sk->listening) { for(i=0;i<USOS_MAX_SOCKETS;i++) if(usos_socks[i]->used && usos_socks[i]->parent==slot && usos_socks[i]->connected) ready|=USOS_SOCK_ACCEPT; return ready; }
    if(sk->rx_len || sk->udp_ready || sk->peer_fin || sk->read_shutdown) ready|=USOS_SOCK_READABLE;
    if((sk->connected || sk->type==USOS_SOCK_DGRAM) && !sk->error && !sk->write_shutdown && sk->tx_len<USOS_TX_ROOM && sk->tcp.state!=USOS_TCP_RESET) ready|=USOS_SOCK_WRITABLE;
    if(sk->error) ready|=USOS_SOCK_EXCEPTION;
    if(sk->peer_fin || sk->error || sk->tcp.state==USOS_TCP_RESET) ready|=USOS_SOCK_CLOSED;
    if(sk->connect_done) ready|=USOS_SOCK_CONNECT;
    return ready;
}
int usos_sock_connect(int slot,usos_u32 ip,usos_u16 port,const char *name)
{
    usos_sock_st *sk=usos_slot(slot); usos_u32 addresses[USOS_NET_MAX_ADDRS]; usos_u16 count;
    if(!sk) return USOS_SOCK_ENOTSOCK;
    if(!usos_ready) return USOS_SOCK_ENOTREADY;
    if(sk->connected || sk->listening) return USOS_SOCK_EISCONN;
    if(sk->connecting) return USOS_SOCK_EALREADY;
    if(name) { if(usos_sock_resolve(name,addresses,&count) || !count) return USOS_SOCK_EHOSTUNREACH; ip=addresses[0]; }
    if(!ip || ip==0xffffffffUL || !port) return USOS_NET_ERR_ARG;
    sk->raddr=ip; sk->rport=port; sk->error=0; sk->connect_done=0;
    if(sk->type==USOS_SOCK_DGRAM) { sk->connected=1; sk->connect_done=1; return 0; }
    if(net_tcp_open(&sk->tcp,usos_pkt_ip(),sk->lport,ip,port)) return USOS_NET_ERR_ARG;
    sk->tcp.buffered_receive=1; sk->control=USOS_TCP_SYN; sk->connecting=1;
    sk->connect_at=(usos_u32)usos_abi_now(); sk->arp_tick=sk->connect_at-250UL;
    usos_sock_tick();
    if(sk->connected) return 0;
    if(sk->nonblocking) return sk->error?sk->error:USOS_SOCK_EWOULDBLOCK;
    while(!sk->connected && !sk->error) { usos_sock_tick(); usos_abi_idle(); }
    return sk->error?sk->error:0;
}
int usos_sock_send(int slot,const usos_u8 *buffer,usos_u16 length)
{
    usos_sock_st *sk=usos_slot(slot); usos_u16 sent=0,count,n;
    usos_u32 start=(usos_u32)usos_abi_now(); int rc;
    if(!sk) return USOS_SOCK_ENOTSOCK;
    if(!sk->connected) return sk->error?sk->error:USOS_SOCK_ENOTCONN;
    if(sk->write_shutdown) return USOS_SOCK_ESHUTDOWN;
    if(!buffer && length) return USOS_NET_ERR_ARG;
    if(!length) return 0;
    if(sk->type==USOS_SOCK_DGRAM) {
        if(length>USOS_UDP_RX) return USOS_NET_ERR_ARG;
        n=net_udp_build(usos_tx_frame+14,usos_pkt_ip(),sk->raddr,sk->lport,sk->rport,buffer,length);
        if(sk->nonblocking) { rc=usos_frame_try(sk->raddr,n,1); return rc>0?(int)length:(rc<0?USOS_SOCK_EHOSTUNREACH:USOS_SOCK_EWOULDBLOCK); }
        return usos_frame_send(sk->raddr,n)?(int)length:USOS_SOCK_EHOSTUNREACH;
    }
    for(;;) {
        if(sk->error) return sent?(int)sent:sk->error;
        if(sk->tcp.state!=USOS_TCP_ESTABLISHED && sk->tcp.state!=USOS_TCP_CLOSE_WAIT) return sent?(int)sent:USOS_SOCK_ENOTCONN;
        count=(usos_u16)(USOS_TX_ROOM-sk->tx_len);
        if(count>length-sent) count=(usos_u16)(length-sent);
        if(count) { usos_copy(sk->tx+sk->tx_len,buffer+sent,count); sk->tx_len=(usos_u16)(sk->tx_len+count); sent=(usos_u16)(sent+count); }
        usos_sock_tick();
        if(sk->nonblocking) return sent?(int)sent:USOS_SOCK_EWOULDBLOCK;
        if(sent==length && !sk->tx_len) return (int)sent;
        if(usos_due((usos_u32)usos_abi_now(),start,USOS_IO_MS)) return sent?(int)sent:USOS_SOCK_ETIMEDOUT;
        usos_abi_idle();
    }
}
static int usos_receive(int slot,usos_u8 *buffer,usos_u16 length,int peek)
{
    usos_sock_st *sk=usos_slot(slot); usos_u32 start=(usos_u32)usos_abi_now();
    usos_u16 count,i,at;
    if(!sk) return USOS_SOCK_ENOTSOCK;
    if(!sk->connected && sk->type!=USOS_SOCK_DGRAM) return sk->error?sk->error:USOS_SOCK_ENOTCONN;
    if(!buffer && length) return USOS_NET_ERR_ARG;
    if(!length) return 0;
    if(sk->read_shutdown) return 0;
    for(;;) {
        count=sk->type==USOS_SOCK_DGRAM?sk->udp_len:sk->rx_len;
        if(count || (sk->type==USOS_SOCK_DGRAM && sk->udp_ready)) {
            if(count>length) count=length;
            if(sk->type==USOS_SOCK_DGRAM) { usos_copy(buffer,sk->udp,count); if(!peek) { sk->udp_len=0; sk->udp_ready=0; } }
            else {
                for(i=0;i<count;i++) { at=(usos_u16)((sk->rx_head+i)%USOS_RX_ROOM); buffer[i]=sk->rx[at]; if(!peek) sk->rx_map[at/8]&=(usos_u8)~(1U<<(at%8)); }
                if(!peek) { sk->rx_head=(usos_u16)((sk->rx_head+count)%USOS_RX_ROOM); sk->rx_base+=count; sk->rx_len=(usos_u16)(sk->rx_len-count); usos_tcp_send_ack(sk); }
            }
            return (int)count;
        }
        if(sk->error) return sk->error;
        if(sk->tcp.state==USOS_TCP_RESET) return USOS_SOCK_ECONNRESET;
        if(sk->peer_fin) return 0;
        if(sk->nonblocking) return USOS_SOCK_EWOULDBLOCK;
        if(usos_due((usos_u32)usos_abi_now(),start,USOS_IO_MS)) return USOS_SOCK_ETIMEDOUT;
        usos_sock_tick(); usos_abi_idle();
    }
}
int usos_sock_recv(int slot,usos_u8 *buffer,usos_u16 length) { return usos_receive(slot,buffer,length,0); }
int usos_sock_peek(int slot,usos_u8 *buffer,usos_u16 length) { return usos_receive(slot,buffer,length,1); }
int usos_sock_close(int slot)
{
    usos_sock_st *sk=usos_slot(slot); usos_u32 now,started; usos_u16 n; int i;
    if(!sk) return USOS_SOCK_ENOTSOCK;
    if(sk->listening) for(i=0;i<USOS_MAX_SOCKETS;i++) if(usos_socks[i]->used && usos_socks[i]->parent==slot) {
        usos_socks[i]->nonblocking=1; (void)usos_sock_close(i);
    }
    started=(usos_u32)usos_abi_now();
    if(sk->type==USOS_SOCK_STREAM && sk->connected && !sk->error && !sk->tcp.fin_sent) {
        if(!sk->nonblocking) while(sk->tx_len && !sk->error && !usos_due((usos_u32)usos_abi_now(),started,USOS_CLOSE_MS)) { usos_sock_tick(); usos_abi_idle(); }
        if(!sk->tx_len) {
            now=(usos_u32)usos_abi_now();
            if(usos_tcp_wire(sk,sk->tcp.snd_nxt,USOS_TCP_ACK|USOS_TCP_FIN,0,0,now)>0) {
                sk->tcp.snd_nxt++; sk->control=USOS_TCP_ACK|USOS_TCP_FIN; sk->tx_started=1; sk->tx_tick=now;
                sk->tcp.state=sk->peer_fin?USOS_TCP_LAST_ACK:USOS_TCP_FIN_WAIT;
                if(!sk->nonblocking) while(sk->tcp.snd_nxt!=sk->tcp.snd_una && !sk->error && !usos_due((usos_u32)usos_abi_now(),started,USOS_CLOSE_MS)) { usos_sock_tick(); usos_abi_idle(); }
            }
        } else {
            n=net_tcp_build_rst(&sk->tcp,usos_tx_frame+14); if(n) (void)usos_frame_try(sk->raddr,n,0);
        }
    } else if(sk->connecting) { n=net_tcp_build_rst(&sk->tcp,usos_tx_frame+14); if(n) (void)usos_frame_try(sk->raddr,n,0); }
    usos_zero(sk,sizeof(*sk)); return 0;
}
int usos_sock_local(int slot,usos_u32 *ip,usos_u16 *port)
{ usos_sock_st *sk=usos_slot(slot); if(!sk) return USOS_SOCK_ENOTSOCK; if(ip) *ip=usos_pkt_ip(); if(port) *port=sk->lport; return 0; }
int usos_sock_remote(int slot,usos_u32 *ip,usos_u16 *port)
{ usos_sock_st *sk=usos_slot(slot); if(!sk) return USOS_SOCK_ENOTSOCK; if(!sk->connected) return USOS_SOCK_ENOTCONN; if(ip) *ip=sk->raddr; if(port) *port=sk->rport; return 0; }

int usos_sock_kind(int slot)
{ usos_sock_st *sk=usos_slot(slot); return sk?sk->type:USOS_SOCK_ENOTSOCK; }
int usos_sock_bind(int slot,usos_u32 ip,usos_u16 port)
{
    usos_sock_st *sk=usos_slot(slot); int i;
    if(!sk) return USOS_SOCK_ENOTSOCK;
    if(sk->connected || sk->connecting || sk->listening) return USOS_NET_ERR_STATE;
    if(ip && ip!=usos_pkt_ip()) return USOS_SOCK_EADDRNOTAVAIL;
    if(!port) port=usos_ephemeral();
    for(i=0;i<USOS_MAX_SOCKETS;i++) if(i!=slot && usos_socks[i]->used && usos_socks[i]->type==sk->type && usos_socks[i]->lport==port)
        return USOS_SOCK_EADDRINUSE;
    sk->lport=port; return 0;
}
int usos_sock_listen(int slot,int backlog)
{
    usos_sock_st *sk=usos_slot(slot);
    if(!sk) return USOS_SOCK_ENOTSOCK;
    if(sk->type!=USOS_SOCK_STREAM) return USOS_SOCK_EOPNOTSUPP;
    if(sk->connected || sk->connecting) return USOS_SOCK_EISCONN;
    sk->listening=1; sk->tcp.state=USOS_TCP_LISTEN;
    sk->backlog=backlog<1?1:(backlog>USOS_MAX_SOCKETS-1?USOS_MAX_SOCKETS-1:backlog); return 0;
}
int usos_sock_accept(int slot,usos_u32 *ip,usos_u16 *port)
{
    usos_sock_st *sk=usos_slot(slot); int i; usos_u32 start=(usos_u32)usos_abi_now();
    if(!sk) return USOS_SOCK_ENOTSOCK;
    if(!sk->listening) return USOS_NET_ERR_STATE;
    for(;;) {
        for(i=0;i<USOS_MAX_SOCKETS;i++) if(usos_socks[i]->used && usos_socks[i]->parent==slot && usos_socks[i]->connected) {
            usos_socks[i]->parent=-1;
            if(ip) *ip=usos_socks[i]->raddr; if(port) *port=usos_socks[i]->rport; return i;
        }
        if(sk->nonblocking) return USOS_SOCK_EWOULDBLOCK;
        if(usos_due((usos_u32)usos_abi_now(),start,USOS_IO_MS)) return USOS_SOCK_ETIMEDOUT;
        usos_sock_tick(); usos_abi_idle();
    }
}
int usos_sock_shutdown_one(int slot,int how)
{
    usos_sock_st *sk=usos_slot(slot);
    if(!sk) return USOS_SOCK_ENOTSOCK;
    if(how<0 || how>2) return USOS_NET_ERR_ARG;
    if(!sk->connected) return USOS_SOCK_ENOTCONN;
    if(how==0 || how==2) { sk->read_shutdown=1; usos_discard_receive(sk); sk->udp_len=0; sk->udp_ready=0; }
    if(how==1 || how==2) sk->write_shutdown=1;
    usos_sock_tick(); return 0;
}
int usos_sock_sendto(int slot,usos_u32 ip,usos_u16 port,const usos_u8 *buffer,usos_u16 length)
{
    usos_sock_st *sk=usos_slot(slot); usos_u16 n; int rc;
    if(!sk) return USOS_SOCK_ENOTSOCK;
    if(sk->type!=USOS_SOCK_DGRAM) return USOS_SOCK_EOPNOTSUPP;
    if(sk->write_shutdown) return USOS_SOCK_ESHUTDOWN;
    if(!ip || ip==0xffffffffUL || !port || (!buffer && length) || length>USOS_UDP_RX) return USOS_NET_ERR_ARG;
    n=net_udp_build(usos_tx_frame+14,usos_pkt_ip(),ip,sk->lport,port,buffer,length);
    if(!n) return USOS_NET_ERR_ARG;
    if(sk->nonblocking) { rc=usos_frame_try(ip,n,1); return rc>0?(int)length:(rc<0?USOS_SOCK_EHOSTUNREACH:USOS_SOCK_EWOULDBLOCK); }
    return usos_frame_send(ip,n)?(int)length:USOS_SOCK_EHOSTUNREACH;
}
int usos_sock_recvfrom(int slot,usos_u8 *buffer,usos_u16 length,usos_u32 *ip,usos_u16 *port)
{
    usos_sock_st *sk=usos_slot(slot); int result;
    if(!sk) return USOS_SOCK_ENOTSOCK;
    result=usos_sock_recv(slot,buffer,length);
    if(result>=0) {
        if(ip) *ip=sk->type==USOS_SOCK_DGRAM?sk->udp_address:sk->raddr;
        if(port) *port=sk->type==USOS_SOCK_DGRAM?sk->udp_port:sk->rport;
    }
    return result;
}

/* Synchronous DNS resolver; the ABI provides asynchronous request jobs. */
static int usos_is_numeric(const char *name)
{
    const char *p = name;

    if (p == 0 || *p == '\0')
        return 0;
    for (; *p != '\0'; p++) {
        if ((*p < '0' || *p > '9') && *p != '.')
            return 0;
    }
    return 1;
}

int usos_sock_resolve(const char *name, usos_u32 addrs[USOS_NET_MAX_ADDRS],
                      usos_u16 *count)
{
    usos_u8 query[USOS_NET_NAME_MAX];
    usos_u32 dns_ip;
    usos_u16 qlen;
    usos_u16 sport;
    usos_u16 id;
    usos_u16 n;
    int attempt;
    int rc = USOS_NET_ERR_NAME;

    if (name == 0 || addrs == 0 || count == 0)
        return USOS_NET_ERR_ARG;
    *count = 0;
    if (usos_is_numeric(name)) {
        usos_u32 ip = net_inet_addr(name);

        if (ip == 0xFFFFFFFFUL)
            return USOS_NET_ERR_NAME;
        addrs[0] = ip;
        *count = 1;
        return USOS_NET_OK;
    }
    if (!usos_ready)
        return USOS_SOCK_ENOTREADY;
    dns_ip = usos_pkt_dns();
    if (dns_ip == 0 || dns_ip == 0xFFFFFFFFUL)
        return USOS_NET_ERR_NAME;

    id = (usos_u16)(usos_abi_now() ^ ((usos_u32)usos_dns_seq << 8));
    usos_dns_seq = (usos_u16)(usos_dns_seq + 1);
    qlen = net_dns_build_query(query, (usos_u16)sizeof(query), id, name);
    if (qlen == 0)
        return USOS_NET_ERR_NAME;
    sport = usos_ephemeral();

    usos_capture_active = 1;
    usos_capture_port = sport;
    usos_capture_ip = dns_ip;
    usos_capture_len = 0;

    for (attempt = 0; attempt < 2; attempt++) {
        usos_u32 deadline;

        usos_capture_len = 0;
        n = net_udp_build(usos_tx_frame + USOS_NET_ETH_HDR, usos_pkt_ip(),
                          dns_ip, sport, 53, query, qlen);
        if (n == 0) {
            rc = USOS_NET_ERR_ARG;
            break;
        }
        if (!usos_frame_send(dns_ip, n)) {
            rc = USOS_SOCK_EHOSTUNREACH;
            break;
        }
        deadline = usos_abi_now() + USOS_DNS_TIMEOUT_MS;
        for (;;) {
            if (usos_capture_len != 0) {
                rc = net_dns_parse_response(usos_capture_buf, usos_capture_len,
                                            id, addrs, count);
                if (rc == USOS_NET_OK)
                    break;
            }
            if ((usos_s32)((usos_u32)usos_abi_now() - deadline) >= 0) {
                rc = USOS_SOCK_ETIMEDOUT;
                break;
            }
            usos_sock_tick();
            usos_abi_idle();
        }
        if (rc == USOS_NET_OK)
            break;
    }
    usos_capture_active = 0;
    usos_capture_len = 0;
    return rc;
}
