/* RFC1035 PTR wire format; no transport, heap or platform headers.
 * Copyright(C)2026 Maksymilian and the USOS Authors.
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Public specification:https://www.rfc-editor.org/rfc/rfc1035.html
 * Compression points to prior names; forward/self references are rejected.
 */
#include "dns_extra.h"

static usos_u16 dns_decimal(char *out,usos_u8 value)
{
    usos_u16 n=0;
    if(value>=100) { out[n++]=(char)('0'+value/100);value=(usos_u8)(value%100);out[n++]=(char)('0'+value/10); }
    else if(value>=10) out[n++]=(char)('0'+value/10);
    out[n++]=(char)('0'+value%10);return n;
}
usos_u16 net_dns_build_ptr_query(usos_u8 *buffer,usos_u16 room,usos_u16 id,usos_u32 ip)
{
    char name[32];const char *suffix="in-addr.arpa";
    usos_u16 n=0,i,total;
    for(i=0;i<4;i++) { n=(usos_u16)(n+dns_decimal(name+n,(usos_u8)(ip>>(i*8))));name[n++]='.'; }
    while(*suffix) name[n++]=*suffix++;
    name[n]=0;total=net_dns_build_query(buffer,room,id,name);
    if(total) net_put16(buffer+total-4,12);
    return total;
}

/* next denotes the end of the original encoding, not the compressed tail.
 * All offset additions are preceded by subtraction bounds so the 16-bit
 * Watcom integer model cannot wrap malformed RDLENGTH/name lengths. */
static int dns_name(const usos_u8 *message,usos_u16 length,usos_u16 offset,
                      char out[256],usos_u16 *next)
{
    usos_u16 pos=offset,used=0,wire=1,hops=0,target,i;
    usos_u8 label,c;
    int jumped=0;
    while(pos<length) {
        if(++hops>256) return USOS_NET_ERR_NAME;
        label=message[pos];
        if(!label) {
            if(!jumped) *next=(usos_u16)(pos+1);
            out[used]=0;return USOS_NET_OK;
        }
        if((label&0xc0)==0xc0) {
            if(length-pos<2) return USOS_NET_ERR_SHORT;
            target=(usos_u16)(((usos_u16)(label&0x3f)<<8)|message[pos+1]);
            if(target<12 || target>=pos || target>=length) return USOS_NET_ERR_NAME;
            if(!jumped) { *next=(usos_u16)(pos+2);jumped=1; }
            pos=target;continue;
        }
        if(label&0xc0) return USOS_NET_ERR_NAME;
        if((usos_u16)label>length-pos-1) return USOS_NET_ERR_SHORT;
        if((usos_u16)label+1>255-wire) return USOS_NET_ERR_NAME;
        wire=(usos_u16)(wire+label+1);
        if(used) out[used++]='.';
        if((usos_u16)label>255-used) return USOS_NET_ERR_NAME;
        for(i=0;i<label;i++) {
            c=message[pos+1+i];
            if(c<=32 || c>=127 || c=='.') return USOS_NET_ERR_NAME;
            out[used++]=(char)c;
        }
        pos=(usos_u16)(pos+label+1);
    }
    return USOS_NET_ERR_SHORT;
}
static int dns_equal(const char *a,const char *b)
{
    unsigned char x,y;
    do {
        x=(unsigned char)*a++;y=(unsigned char)*b++;
        if(x>='A' && x<='Z') x=(unsigned char)(x+'a'-'A');
        if(y>='A' && y<='Z') y=(unsigned char)(y+'a'-'A');
        if(x!=y) return 0;
    } while(x);
    return 1;
}
static void dns_copy(char *out,const char *input)
{ while((*out++=*input++)!=0) {} }

int net_dns_parse_ptr_response(const usos_u8 *message,usos_u16 length,
                               usos_u16 id,char *name,usos_u16 room)
{
    char expected[256],owner[256],answer[256],found[256];
    usos_u16 flags,offset,next,i,answers,type,class_,rdlen,rdata,end,needed;
    int rc,have=0;
    if(!message || !name || !room) return USOS_NET_ERR_ARG;
    name[0]=0;
    if(length<12) return USOS_NET_ERR_SHORT;
    if(net_get16(message)!=id) return USOS_NET_ERR_ARG;
    flags=net_get16(message+2);
    if(!(flags&0x8000) || (flags&0x7800)) return USOS_NET_ERR_PROTO;
    if(flags&0x0200) return USOS_NET_ERR_SHORT;
    if((flags&15)==3) return USOS_NET_ERR_NAME;
    if(flags&15) return USOS_NET_ERR_RCODE;
    if(net_get16(message+4)!=1) return USOS_NET_ERR_PROTO;
    offset=12;rc=dns_name(message,length,offset,expected,&offset);if(rc) return rc;
    if(offset>length || length-offset<4) return USOS_NET_ERR_SHORT;
    if(net_get16(message+offset)!=12 || net_get16(message+offset+2)!=1) return USOS_NET_ERR_PROTO;
    offset=(usos_u16)(offset+4);answers=net_get16(message+6);
    for(i=0;i<answers;i++) {
        rc=dns_name(message,length,offset,owner,&offset);if(rc) return rc;
        if(offset>length || length-offset<10) return USOS_NET_ERR_SHORT;
        type=net_get16(message+offset);class_=net_get16(message+offset+2);rdlen=net_get16(message+offset+8);
        rdata=(usos_u16)(offset+10);
        if(rdlen>length-rdata) return USOS_NET_ERR_SHORT;
        end=(usos_u16)(rdata+rdlen);
        if(class_==1 && (type==12 || type==5)) {
            rc=dns_name(message,length,rdata,answer,&next);if(rc) return rc;
            if(next!=end || !answer[0]) return USOS_NET_ERR_NAME;
            if(dns_equal(owner,expected)) {
                if(type==5) dns_copy(expected,answer);
                else if(!have) { dns_copy(found,answer);have=1; }
            }
        }
        offset=end;
    }
    if(!have) return USOS_NET_ERR_NAME; /* no authority/additional referral accepted */
    for(needed=0;found[needed];needed++) {}
    if(needed>=room) return USOS_NET_ERR_ROOM;
    dns_copy(name,found);return USOS_NET_OK;
}
