/* SPDX-License-Identifier: GPL-3.0-or-later
 * Block on one outstanding RFB incremental update. Rearm only after its
 * reply; no timer, process/disk sampling, QMP query or persisted pixels.
 * QEMU reverse-connects after our READY notification. Only page roles leave
 * this process; the private framebuffer is erased before release.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
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
typedef int Socket;
#define INVALID_SOCKET (-1)
#define CLOSE close
#endif
#include "win95_ui_classify.h"
#define MAX_SIDE 2048U
static unsigned char *pixels;
static unsigned width, height;
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
        if (strcmp(role,"unknown") && strcmp(role,"busy") && strcmp(role,previous)) {
            printf("page %s\n",role); fflush(stdout); previous=role;
        }
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
