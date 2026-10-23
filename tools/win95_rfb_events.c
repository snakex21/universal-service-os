/* SPDX-License-Identifier: GPL-3.0-or-later
 * Block on one outstanding RFB incremental update. Rearm only after its
 * reply; no timed screen query, process/disk sampling or persisted pixels.
 * QEMU reverse-connects after our READY notification. Only page roles and
 * unsupported public-heading hashes leave; the framebuffer is erased.
 */
#ifndef _WIN32
#define _POSIX_C_SOURCE 200809L
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <time.h>
#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
typedef SOCKET Socket;
#define CLOSE closesocket
#else
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <signal.h>
#include <sys/select.h>
typedef int Socket;
#define INVALID_SOCKET (-1)
#define CLOSE close
#endif
#include "win95_ui_classify.h"
#define MAX_SIDE 2048U
#ifndef WIN95_UI_STABLE_MS
#define WIN95_UI_STABLE_MS 3000U
#endif
#ifndef WIN95_UI_UNSUPPORTED_MS
#define WIN95_UI_UNSUPPORTED_MS 30000U
#endif
#ifndef WIN95_UI_READY_BUTTON_HASH
#define WIN95_UI_READY_BUTTON_HASH UINT64_C(0x298c8b8f1795477c)
#endif
static unsigned char *pixels;
static unsigned width, height;
typedef struct {
    const char *role;
    uint64_t heading, button, deadline;
    int unsupported;
} Gate;
static uint64_t monotonic_ms(void)
{
#ifdef _WIN32
    return GetTickCount64();
#else
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC,&now)) return 0;
    return (uint64_t)now.tv_sec*1000+(unsigned long)now.tv_nsec/1000000;
#endif
}
static int next_button_role(const char *role)
{
    size_t length=strlen(role);
    if (length==sizeof("coa-single-en")-1 && !memcmp(role,"coa-single-en",sizeof("coa-single-en")-1)) return 0;
    if (length==sizeof("network-device-en")-1 && !memcmp(role,"network-device-en",sizeof("network-device-en")-1)) return 0;
    if (length==sizeof("restart")-1 && !memcmp(role,"restart",sizeof("restart")-1)) return 0;
    if (length==sizeof("reboot-confirm")-1 && !memcmp(role,"reboot-confirm",sizeof("reboot-confirm")-1)) return 0;
    return 1;
}
static void gate_update(Gate *gate, const char *role, const char *previous)
{
    uint64_t heading,button;
    int unsupported;
    if (width!=640 || height!=480 || !strcmp(role,"busy")) { gate->role=NULL; return; }
    heading=fingerprint(pixels,width,104,90,480,24);
    button=fingerprint(pixels,width,425,395,32,10);
    unsupported=!strcmp(role,"unknown");
    if ((!unsupported && !strcmp(role,previous)) ||
        ((unsupported || next_button_role(role)) && button!=WIN95_UI_READY_BUTTON_HASH &&
            button!=UINT64_C(0xb304b7dade1a13b1))) {
        gate->role=NULL; return;
    }
    if (gate->role && !strcmp(role,gate->role) && gate->heading==heading &&
        gate->button==button && gate->unsupported==unsupported) return;
    gate->role=role; gate->heading=heading; gate->button=button;
    gate->unsupported=unsupported;
    gate->deadline=monotonic_ms()+(unsupported ? WIN95_UI_UNSUPPORTED_MS:WIN95_UI_STABLE_MS);
}
/* Block for a real wire event or the single pending paint-stability deadline.
 * No screen/status query or request is sent when this deadline fires. */
static int wait_wire(Socket s, const Gate *gate)
{
    fd_set readset;
    struct timeval timeout,*limit=NULL;
    int result;
    FD_ZERO(&readset); FD_SET(s,&readset);
    if (gate->role) {
        uint64_t now=monotonic_ms(),left=gate->deadline>now ? gate->deadline-now:0;
        timeout.tv_sec=(long)(left/1000); timeout.tv_usec=(long)((left%1000)*1000);
        limit=&timeout;
    }
#ifdef _WIN32
    result=select(0,&readset,NULL,NULL,limit);
#else
    result=select(s+1,&readset,NULL,NULL,limit);
    if (result<0 && errno==EINTR) return 2;
#endif
    return result<0 ? -1:result;
}
static unsigned u16(const unsigned char *p) { return ((unsigned)p[0]<<8)|p[1]; }
static uint32_t u32(const unsigned char *p) { return ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[2]<<8)|p[3]; }
static void put16(unsigned char *p, unsigned v) { p[0]=(unsigned char)(v>>8); p[1]=(unsigned char)v; }
static int exact(Socket s, void *buffer, size_t size, int writing)
{
    unsigned char *p=buffer;
    while (size) {
        int n=writing ? send(s,(const char *)p,(int)size,0) : recv(s,(char *)p,(int)size,0);
        if (n<=0) {
#ifndef _WIN32
            if (n<0 && errno==EINTR) continue;
#endif
            return 0;
        }
        p+=n; size-=(unsigned)n;
    }
    return 1;
}
static void clear_pixels(void)
{
    if (pixels) {
        volatile unsigned char *p=pixels;
        size_t n=(size_t)width*height*3;
        while (n--) *p++=0;
        free(pixels); pixels=NULL;
    }
}
static int resize(unsigned w, unsigned h)
{
    if (!w || !h || w>MAX_SIDE || h>MAX_SIDE) return 0;
    clear_pixels(); width=w; height=h;
    pixels=calloc((size_t)w*h,3);
    return pixels!=NULL;
}
static int request(Socket s, int incremental)
{
    unsigned char b[10]={3,0};
    b[1]=(unsigned char)incremental; put16(b+6,width); put16(b+8,height);
    return exact(s,b,sizeof b,1);
}
static int watch(Socket s)
{
    unsigned char b[32], row[MAX_SIDE*4];
    unsigned n,i,y,x,w,h,xx,yy;
    const char *previous="unknown", *role;
    Gate gate={0};
    /* The reverse endpoint is owned QEMU; still validate every wire bound. */
    if (!exact(s,b,12,0) || memcmp(b,"RFB 003.008\n",12)) return 2;
    memcpy(b,"RFB 003.008\n",12);
    if (!exact(s,b,12,1) || !exact(s,b,1,0) || !b[0]) return 2;
    n=b[0];
    for (i=0,w=0;i<n;i++) { if (!exact(s,b,1,0)) return 2; if (b[0]==1) w=1; }
    b[0]=1;
    if (!w || !exact(s,b,1,1) || !exact(s,b,4,0) || u32(b)) return 2;
    b[0]=1;
    if (!exact(s,b,1,1) || !exact(s,b,24,0)) return 2;
    w=u16(b); h=u16(b+2); n=u32(b+20);
    if (n>4096 || !resize(w,h)) return 2;
    while (n) { unsigned chunk=n>sizeof row ? sizeof row:n; if (!exact(s,row,chunk,0)) return 2; n-=chunk; }
    /* SetPixelFormat: 32 bpp, little endian, true colour, R16/G8/B0. */
    memset(b,0,20); b[4]=32; b[5]=24; b[7]=1;
    b[9]=255; b[11]=255; b[13]=255; b[14]=16; b[15]=8;
    if (!exact(s,b,20,1)) return 2;
    /* Raw + DesktopSize; never request compression, clipboard or cursor. */
    memset(b,0,12); b[0]=2; b[3]=2;
    b[8]=255; b[9]=255; b[10]=255; b[11]=33;
    if (!exact(s,b,12,1) || !request(s,0)) return 2;
    for (;;) {
        int ready=wait_wire(s,&gate);
        if (ready<0) return 2;
        if (ready==2) continue; /* Interrupted wait: recompute its deadline. */
        if (!ready) {
            if (gate.unsupported) {
                printf("unsupported %016llx\n",(unsigned long long)gate.heading);
                fflush(stdout); return 4;
            }
            printf("page %s\n",gate.role); fflush(stdout);
            previous=gate.role; gate.role=NULL;
            continue;
        }
        if (!exact(s,b,1,0)) return 0;
        if (b[0]==2) continue; /* Bell has no payload. */
        if (b[0]!=0 || !exact(s,b,3,0)) return 2;
        n=u16(b+1);
        if (n>4096) return 2;
        for (i=0;i<n;i++) {
            uint32_t encoding;
            if (!exact(s,b,12,0)) return 2;
            x=u16(b); y=u16(b+2); w=u16(b+4); h=u16(b+6); encoding=u32(b+8);
            if (encoding==UINT32_C(0xffffff21)) {
                if (x || y || !resize(w,h)) return 2;
                previous="unknown";
                gate.role=NULL;
                continue;
            }
            if (encoding || !w || !h || x>width || y>height || w>width-x || h>height-y) return 2;
            for (yy=0;yy<h;yy++) {
                if (!exact(s,row,(size_t)w*4,0)) return 2;
                for (xx=0;xx<w;xx++) {
                    unsigned char *p=pixels+((size_t)(y+yy)*width+x+xx)*3;
                    p[0]=row[xx*4+2]; p[1]=row[xx*4+1]; p[2]=row[xx*4];
                }
            }
        }
        role=win95_classify(pixels,width,height);
        gate_update(&gate,role,previous);
        if (!request(s,1)) return 2;
    }
}
int main(int argc, char **argv)
{
    Socket listener=INVALID_SOCKET, client;
    int result;
#ifdef _WIN32
    WSADATA data;
    struct sockaddr_in address;
    if (argc!=3 || strcmp(argv[1],"--tcp-test") || WSAStartup(MAKEWORD(2,2),&data)) return 2;
    memset(&address,0,sizeof address); address.sin_family=AF_INET;
    address.sin_addr.s_addr=htonl(INADDR_LOOPBACK); address.sin_port=htons((unsigned short)atoi(argv[2]));
    listener=socket(AF_INET,SOCK_STREAM,0);
#else
    struct sockaddr_un address;
    if (argc!=3 || strcmp(argv[1],"--listen") || strlen(argv[2])>=sizeof address.sun_path) return 2;
    signal(SIGPIPE,SIG_IGN);
    memset(&address,0,sizeof address); address.sun_family=AF_UNIX; strcpy(address.sun_path,argv[2]);
    listener=socket(AF_UNIX,SOCK_STREAM,0);
#endif
    if (listener==INVALID_SOCKET || bind(listener,(struct sockaddr *)&address,sizeof address) || listen(listener,1)) return 2;
    puts("ready"); fflush(stdout);
    client=accept(listener,NULL,NULL); CLOSE(listener);
    if (client==INVALID_SOCKET) return 2;
    result=watch(client); clear_pixels(); CLOSE(client);
#ifdef _WIN32
    WSACleanup();
#endif
    return result;
}
