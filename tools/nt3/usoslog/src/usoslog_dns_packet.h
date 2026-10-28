/* Own bounded DNS A-response validation, GPL-3.0-or-later.
 * No OS types/imports; shared by the actual NT3 logger and host C tests.
 * RFC1035 wire format, RFC5452 question/ID/peer matching. Not DNSSEC.
 */
#ifndef USOSLOG_DNS_PACKET_H
#define USOSLOG_DNS_PACKET_H

static unsigned usos_dns_u16(const unsigned char *p)
{
    return ((unsigned)p[0] << 8) | p[1];
}

static int usos_dns_same(const char *a, const char *b)
{
    unsigned x, y;
    do {
        x=(unsigned char)*a++; y=(unsigned char)*b++;
        if (x>='A' && x<='Z') x+='a'-'A';
        if (y>='A' && y<='Z') y+='a'-'A';
        if (x!=y) return 0;
    } while (x);
    return 1;
}

/* Return position after the encoded name, while following bounded pointers.
 * Only printable ASCII labels without an embedded dot are needed by this
 * diagnostic's fixed hostname; ambiguous/binary label names fail closed. */
static int usos_dns_name(const unsigned char *p, int n, int at, char *out)
{
    int next=-1, used=0, steps=0, count, i;
    unsigned c;
    while (at>=0 && at<n && ++steps<=128) {
        count=p[at++];
        if (!count) { out[used]=0; return next<0 ? at : next; }
        if ((count&0xc0)==0xc0) {
            if (at>=n) return -1;
            if (next<0) next=at+1;
            at=((count&63)<<8)|p[at];
            continue;
        }
        if ((count&0xc0) || count>63 || at+count>n || used+count+(used?1:0)>253) return -1;
        if (used) out[used++]='.';
        for (i=0;i<count;i++) {
            c=p[at++];
            if (c<33 || c>126 || c=='.') return -1;
            out[used++]=(char)c;
        }
    }
    return -1;
}

/* Return one matching answer A, following at most16 CNAME links. Require all
 * record boundaries before trusting any answer. UDP peer identity is checked
 * by recvfrom caller; TCP's connected socket supplies the corresponding peer. */
static int usos_dns_a_reply(const unsigned char *p, int n, unsigned id,
                           const char *question, int peer_matches,
                           unsigned char answer[4])
{
    char current[256], owner[256], target[256];
    int qend, start, at, end, i, j, total, an, depth, cn, data, size;
    unsigned type, cls;
    for (i=0;i<4;i++) answer[i]=0;
    if (!peer_matches || n<12 || n>4096 || usos_dns_u16(p)!=id ||
        !(p[2]&0x80) || (p[2]&0x7a) || (p[3]&0x4f) || usos_dns_u16(p+4)!=1) return 0;
    an=(int)usos_dns_u16(p+6);
    total=an+(int)usos_dns_u16(p+8)+(int)usos_dns_u16(p+10);
    if (!an || an>64 || total>128) return 0;
    qend=usos_dns_name(p,n,12,current);
    if (qend<0 || qend+4>n || !usos_dns_same(current,question) ||
        usos_dns_u16(p+qend)!=1 || usos_dns_u16(p+qend+2)!=1) return 0;
    start=qend+4; at=start;
    for (i=0;i<total;i++) {
        at=usos_dns_name(p,n,at,owner);
        if (at<0 || at+10>n) return 0;
        type=usos_dns_u16(p+at);cls=usos_dns_u16(p+at+2);
        size=(int)usos_dns_u16(p+at+8);data=at+10;
        if (data+size>n) return 0;
        if (cls==1 && type==1 && size!=4) return 0;
        if (cls==1 && type==5) {
            end=usos_dns_name(p,n,data,target);
            if (end<0 || end!=data+size) return 0;
        }
        at=data+size;
    }
    if (at!=n) return 0;
    for (depth=0;depth<16;depth++) {
        at=start;cn=0;
        for (i=0;i<an;i++) {
            at=usos_dns_name(p,n,at,owner);
            type=usos_dns_u16(p+at);cls=usos_dns_u16(p+at+2);
            size=(int)usos_dns_u16(p+at+8);data=at+10;
            if (cls==1 && usos_dns_same(owner,current)) {
                if (type==1 && size==4) {
                    if (!(p[data]|p[data+1]|p[data+2]|p[data+3])) return 0;
                    for (j=0;j<4;j++) answer[j]=p[data+j];
                    return 1;
                }
                if (type==5 && !cn) {
                    if (usos_dns_name(p,n,data,target)<0) return 0;
                    cn=1;
                }
            }
            at=data+size;
        }
        if (!cn) return 0;
        for (j=0;(current[j]=target[j])!=0;j++) {}
    }
    return 0;
}

#endif
