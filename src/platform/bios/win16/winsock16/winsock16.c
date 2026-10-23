/* winsock16.c - USOS Winsock 1.1 provider for 16-bit Windows (Win16).
 *
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Milestone 1 (this file): ABI skeleton.  WSAStartup()/WSACleanup() and the
 * last-error accessors are functional; every socket/database entry point is a
 * stub that reports WSAENETDOWN (WSAVERNOTSUPPORTED for the asynchronous
 * database lookups), because no transport engine is linked in yet.
 *
 * milestone 2: silnik TCP/UDP na mTCP + USOSPKT w trybie kolejkowym
 *
 * Export list and ordinals follow the public Winsock 1.1 specification
 * (accept=1 ... socket=23, gethostbyaddr=51 ... gethostname=57,
 * WSAAsyncSelect=101 ... WSACleanup=116, __WSAFDIsSet=151).  No code from any
 * third-party Winsock implementation is used here; this file is written from
 * scratch against winsock.h (Open Watcom) and the published specification.
 *
 * Build: tools/build_win16_winsock.py
 */

#include <windows.h>
#include <winsock.h>

#include "net/net.h"
#include "net/usos_pkt.h"
#include "net/win16_sock.h"

#define USOS_WS_DESCRIPTION   "USOS Winsock 1.1 (Win16)"
#define USOS_WS_SYSTEM_STATUS "USOSPKT queue mode - TCP/IP engine (no DHCP)"
#define USOS_WS_MAX_SOCKETS   4
#define USOS_WS_MAX_UDPDG     512

/* A Win16 DLL is a single instance per machine, so static storage is the
 * documented Winsock 1.1 model. */
static int usos_startup_count = 0;
static int usos_last_error = 0;

static void FAR *usos_far_zero(void FAR *dst, unsigned int count)
{
    unsigned char FAR *p = (unsigned char FAR *)dst;
    while (count-- != 0)
        *p++ = 0;
    return dst;
}

static void usos_far_copyz(char FAR *dst, const char *src, unsigned int room)
{
    unsigned int i = 0;
    while (i + 1 < room && src[i] != '\0') {
        dst[i] = src[i];
        i++;
    }
    dst[i] = '\0';
}

/* ------------------------------------------------------------------ */
/* Engine glue: clock, blocking hook, error mapping, far copies         */
/* ------------------------------------------------------------------ */

/* The socket engine never calls Windows itself; it asks for time and for a
 * chance to let the application run (that is what a blocking Winsock call is
 * expected to do on a cooperative system). */
unsigned long usos_abi_now(void)
{
    return (unsigned long)GetTickCount();
}

void usos_abi_idle(void)
{
    MSG msg;

    usos_pkt_poll(1);
    if (PeekMessage(&msg, NULL, 0, 0, PM_REMOVE)) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
}

static void usos_far_tobuf(void FAR *dst, const void FAR *src, unsigned int len)
{
    unsigned char FAR *d = (unsigned char FAR *)dst;
    const unsigned char FAR *s = (const unsigned char FAR *)src;
    unsigned int i;

    for (i = 0; i < len; i++)
        d[i] = s[i];
}

static void usos_far_tostr(char *dst, const char FAR *src, int room)
{
    int i = 0;

    if (room <= 0) {
        return;
    }
    while (i + 1 < room && src[i] != '\0') {
        dst[i] = src[i];
        i++;
    }
    dst[i] = '\0';
}

static int usos_sock_kind(int type, int protocol)
{
    if (type == SOCK_STREAM) {
        if (protocol != 0 && protocol != IPPROTO_TCP)
            return 0;
        return USOS_SOCK_STREAM;
    }
    if (type == SOCK_DGRAM) {
        if (protocol != 0 && protocol != IPPROTO_UDP)
            return 0;
        return USOS_SOCK_DGRAM;
    }
    return 0;
}

/* One place where engine results become Winsock errors. */
static int usos_map_error(int rc)
{
    if (rc >= 0)
        return rc;
    switch (rc) {
    case USOS_SOCK_ENOTSOCK:     usos_last_error = WSAENOTSOCK; break;
    case USOS_SOCK_ENOTCONN:     usos_last_error = WSAENOTCONN; break;
    case USOS_SOCK_ETIMEDOUT:    usos_last_error = WSAETIMEDOUT; break;
    case USOS_SOCK_ECONNREFUSED: usos_last_error = WSAECONNREFUSED; break;
    case USOS_SOCK_EMFILE:       usos_last_error = WSAEMFILE; break;
    case USOS_SOCK_ECONNRESET:   usos_last_error = WSAECONNRESET; break;
    case USOS_SOCK_EHOSTUNREACH: usos_last_error = WSAEHOSTUNREACH; break;
    case USOS_SOCK_ENOTREADY:    usos_last_error = WSASYSNOTREADY; break;
    case USOS_SOCK_EISCONN:      usos_last_error = WSAEISCONN; break;
    case USOS_NET_ERR_NAME:      usos_last_error = WSAHOST_NOT_FOUND; break;
    case USOS_NET_ERR_ROOM:      usos_last_error = WSAEFAULT; break;
    default:                     usos_last_error = WSAEINVAL; break;
    }
    return SOCKET_ERROR;
}

static int usos_fill_sockaddr(struct sockaddr FAR *name, int FAR *namelen,
                              usos_u32 ip, usos_u16 port)
{
    struct sockaddr_in tmp;

    if (name == NULL || namelen == NULL) {
        usos_last_error = WSAEFAULT;
        return SOCKET_ERROR;
    }
    if (*namelen < (int)sizeof(tmp)) {
        *namelen = (int)sizeof(tmp);
        usos_last_error = WSAEFAULT;
        return SOCKET_ERROR;
    }
    usos_far_zero(&tmp, (unsigned int)sizeof(tmp));
    tmp.sin_family = AF_INET;
    tmp.sin_port = net_htons(port);
    tmp.sin_addr.s_addr = (u_long)ip;
    usos_far_tobuf(name, &tmp, (unsigned int)sizeof(tmp));
    *namelen = (int)sizeof(tmp);
    return 0;
}

/* Common failure path for entry points with no transport engine yet. */
static int usos_not_implemented(void)
{
    usos_last_error = WSAENETDOWN;
    return SOCKET_ERROR;
}

static HANDLE usos_async_not_implemented(void)
{
    usos_last_error = WSAVERNOTSUPPORTED;
    return (HANDLE)0;
}

int __far __pascal WSAStartup(WORD wVersionRequired, LPWSADATA lpWSAData)
{
    if (lpWSAData == NULL) {
        usos_last_error = WSAEFAULT;
        return SOCKET_ERROR;
    }
    if (LOBYTE(wVersionRequired) != 1) {
        usos_far_zero(lpWSAData, (unsigned int)sizeof(WSADATA));
        usos_last_error = WSAVERNOTSUPPORTED;
        return SOCKET_ERROR;
    }

    /* No driver (USOSPKT without /Q) or no DPMI: the documented Winsock 1.1
     * answer is WSASYSNOTREADY, and the data block stays zeroed. */
    if (usos_startup_count == 0 && usos_sock_startup() != USOS_NET_OK) {
        usos_far_zero(lpWSAData, (unsigned int)sizeof(WSADATA));
        usos_last_error = WSASYSNOTREADY;
        return SOCKET_ERROR;
    }

    usos_far_zero(lpWSAData, (unsigned int)sizeof(WSADATA));
    /* 1.0 is honoured as 1.0; anything newer in the 1.x line as 1.1. */
    lpWSAData->wVersion = (HIBYTE(wVersionRequired) == 0) ? (WORD)0x0100 : (WORD)0x0101;
    lpWSAData->wHighVersion = (WORD)0x0101;
    usos_far_copyz(lpWSAData->szDescription, USOS_WS_DESCRIPTION,
                   (unsigned int)sizeof(lpWSAData->szDescription));
    usos_far_copyz(lpWSAData->szSystemStatus, USOS_WS_SYSTEM_STATUS,
                   (unsigned int)sizeof(lpWSAData->szSystemStatus));
    lpWSAData->iMaxSockets = USOS_WS_MAX_SOCKETS;
    lpWSAData->iMaxUdpDg = USOS_WS_MAX_UDPDG;
    lpWSAData->lpVendorInfo = NULL;

    usos_startup_count++;
    usos_last_error = 0;
    return 0;
}

int __far __pascal WSACleanup(void)
{
    if (usos_startup_count == 0) {
        usos_last_error = WSANOTINITIALISED;
        return SOCKET_ERROR;
    }
    usos_startup_count--;
    if (usos_startup_count == 0)
        usos_sock_shutdown();      /* closes every socket, RELEASEs the queue */
    usos_last_error = 0;
    return 0;
}/* ------------------------------------------------------------------ */
/* Ordinals 1..23: socket API                                          */
/* ------------------------------------------------------------------ */

SOCKET __far __pascal accept(SOCKET s, struct sockaddr FAR *addr, int FAR *addrlen)
{
    (void)s; (void)addr; (void)addrlen;
    return (SOCKET)usos_not_implemented();
}

int __far __pascal bind(SOCKET s, const struct sockaddr FAR *name, int namelen)
{
    (void)s; (void)name; (void)namelen;
    return usos_not_implemented();
}

int __far __pascal closesocket(SOCKET s)
{
    int rc;

    if (usos_startup_count == 0) {
        usos_last_error = WSANOTINITIALISED;
        return SOCKET_ERROR;
    }
    rc = usos_sock_close((int)s);
    if (rc < 0)
        return usos_map_error(rc);
    usos_last_error = 0;
    return 0;
}

int __far __pascal connect(SOCKET s, const struct sockaddr FAR *name, int namelen)
{
    struct sockaddr_in addr;
    char hostname[USOS_NET_NAME_MAX];
    int rc;

    if (usos_startup_count == 0) {
        usos_last_error = WSANOTINITIALISED;
        return SOCKET_ERROR;
    }
    if (name == NULL || namelen < (int)sizeof(struct sockaddr_in)) {
        usos_last_error = WSAEFAULT;
        return SOCKET_ERROR;
    }
    usos_far_tobuf(&addr, name, (unsigned int)sizeof(addr));
    if (addr.sin_family != AF_INET) {
        usos_last_error = WSAEAFNOSUPPORT;
        return SOCKET_ERROR;
    }
    hostname[0] = '\0';
    /* Winsock 1.1 sockaddr_in carries no name.  As a USOS extension a caller
     * may pass an over-long buffer: address INADDR_NONE in the sockaddr and the
     * host name right behind it.  Applications that follow the standard flow
     * (gethostbyname, then connect on the returned address) never take this
     * path. */
    if (addr.sin_addr.s_addr == 0xFFFFFFFFUL &&
        namelen > (int)sizeof(struct sockaddr_in)) {
        usos_far_tostr(hostname,
                       ((const char FAR *)name) + sizeof(struct sockaddr_in),
                       (int)sizeof(hostname));
    }
    rc = usos_sock_connect((int)s, (usos_u32)addr.sin_addr.s_addr,
                           net_ntohs((usos_u16)addr.sin_port),
                           (hostname[0] != '\0') ? hostname : (const char *)0);
    if (rc < 0)
        return usos_map_error(rc);
    usos_last_error = 0;
    return 0;
}

int __far __pascal getpeername(SOCKET s, struct sockaddr FAR *name, int FAR *namelen)
{
    usos_u32 ip = 0;
    usos_u16 port = 0;
    int rc;

    if (usos_startup_count == 0) {
        usos_last_error = WSANOTINITIALISED;
        return SOCKET_ERROR;
    }
    rc = usos_sock_remote((int)s, &ip, &port);
    if (rc < 0)
        return usos_map_error(rc);
    if (usos_fill_sockaddr(name, namelen, ip, port) < 0)
        return SOCKET_ERROR;
    usos_last_error = 0;
    return 0;
}

int __far __pascal getsockname(SOCKET s, struct sockaddr FAR *name, int FAR *namelen)
{
    usos_u32 ip = 0;
    usos_u16 port = 0;
    int rc;

    if (usos_startup_count == 0) {
        usos_last_error = WSANOTINITIALISED;
        return SOCKET_ERROR;
    }
    rc = usos_sock_local((int)s, &ip, &port);
    if (rc < 0)
        return usos_map_error(rc);
    if (usos_fill_sockaddr(name, namelen, ip, port) < 0)
        return SOCKET_ERROR;
    usos_last_error = 0;
    return 0;
}

int __far __pascal getsockopt(SOCKET s, int level, int optname,
                              char FAR *optval, int FAR *optlen)
{
    (void)s; (void)level; (void)optname; (void)optval; (void)optlen;
    return usos_not_implemented();
}

u_long __far __pascal htonl(u_long hostlong)
{
    return (u_long)net_htonl((usos_u32)hostlong);
}

u_short __far __pascal htons(u_short hostshort)
{
    return (u_short)net_htons((usos_u16)hostshort);
}

unsigned long __far __pascal inet_addr(const char FAR *cp)
{
    char text[24];

    if (cp == NULL) {
        usos_last_error = WSAEFAULT;
        return (unsigned long)INADDR_NONE;
    }
    usos_far_tostr(text, cp, (int)sizeof(text));
    return (unsigned long)net_inet_addr(text);
}

char FAR * __far __pascal inet_ntoa(struct in_addr in)
{
    static char usos_ntoa_buf[16];

    if (net_inet_ntoa((usos_u32)in.s_addr, usos_ntoa_buf,
                      (usos_u16)sizeof(usos_ntoa_buf)) != USOS_NET_OK) {
        usos_last_error = WSAEINVAL;
        return (char FAR *)0;
    }
    usos_last_error = 0;
    return usos_ntoa_buf;
}

int __far __pascal ioctlsocket(SOCKET s, long cmd, u_long FAR *argp)
{
    (void)s; (void)cmd; (void)argp;
    return usos_not_implemented();
}

int __far __pascal listen(SOCKET s, int backlog)
{
    (void)s; (void)backlog;
    return usos_not_implemented();
}u_long __far __pascal ntohl(u_long netlong)
{
    return (u_long)net_ntohl((usos_u32)netlong);
}

u_short __far __pascal ntohs(u_short netshort)
{
    return (u_short)net_ntohs((usos_u16)netshort);
}

int __far __pascal recv(SOCKET s, char FAR *buf, int len, int flags)
{
    int rc;

    if (usos_startup_count == 0) {
        usos_last_error = WSANOTINITIALISED;
        return SOCKET_ERROR;
    }
    if (len < 0 || (buf == NULL && len > 0)) {
        usos_last_error = WSAEFAULT;
        return SOCKET_ERROR;
    }
    if (len == 0)
        return 0;
    rc = usos_sock_recv((int)s, (usos_u8 FAR *)buf, (usos_u16)len);
    if (rc < 0)
        return usos_map_error(rc);
    usos_last_error = 0;
    return rc;
}

int __far __pascal recvfrom(SOCKET s, char FAR *buf, int len, int flags,
                            struct sockaddr FAR *from, int FAR *fromlen)
{
    (void)s; (void)buf; (void)len; (void)flags; (void)from; (void)fromlen;
    return usos_not_implemented();
}

int __far __pascal select(int nfds, fd_set FAR *readfds, fd_set FAR *writefds,
                          fd_set FAR *exceptfds, const struct timeval FAR *timeout)
{
    (void)nfds; (void)readfds; (void)writefds; (void)exceptfds; (void)timeout;
    return usos_not_implemented();
}

int __far __pascal send(SOCKET s, const char FAR *buf, int len, int flags)
{
    int rc;

    if (usos_startup_count == 0) {
        usos_last_error = WSANOTINITIALISED;
        return SOCKET_ERROR;
    }
    if (len < 0 || (buf == NULL && len > 0)) {
        usos_last_error = WSAEFAULT;
        return SOCKET_ERROR;
    }
    if (flags != 0) {
        usos_last_error = WSAEOPNOTSUPP;   /* MSG_OOB/MSG_DONTROUTE: no path */
        return SOCKET_ERROR;
    }
    if (len == 0)
        return 0;
    rc = usos_sock_send((int)s, (const usos_u8 FAR *)buf, (usos_u16)len);
    if (rc < 0)
        return usos_map_error(rc);
    usos_last_error = 0;
    return rc;                         /* partial writes are reported as such */
}

int __far __pascal sendto(SOCKET s, const char FAR *buf, int len, int flags,
                          const struct sockaddr FAR *to, int tolen)
{
    (void)s; (void)buf; (void)len; (void)flags; (void)to; (void)tolen;
    return usos_not_implemented();
}

int __far __pascal setsockopt(SOCKET s, int level, int optname,
                              const char FAR *optval, int optlen)
{
    (void)s; (void)level; (void)optname; (void)optval; (void)optlen;
    return usos_not_implemented();
}

int __far __pascal shutdown(SOCKET s, int how)
{
    (void)s; (void)how;
    return usos_not_implemented();
}

SOCKET __far __pascal socket(int af, int type, int protocol)
{
    int kind;
    int slot;

    if (usos_startup_count == 0) {
        usos_last_error = WSANOTINITIALISED;
        return INVALID_SOCKET;
    }
    if (af != AF_INET) {
        usos_last_error = WSAEAFNOSUPPORT;
        return INVALID_SOCKET;
    }
    kind = usos_sock_kind(type, protocol);
    if (kind == 0) {
        usos_last_error = (type == SOCK_STREAM || type == SOCK_DGRAM)
                        ? WSAEPROTONOSUPPORT : WSAESOCKTNOSUPPORT;
        return INVALID_SOCKET;
    }
    slot = usos_sock_open(kind);
    if (slot < 0) {
        usos_map_error(slot);
        return INVALID_SOCKET;
    }
    usos_last_error = 0;
    return (SOCKET)slot;
}

/* ------------------------------------------------------------------ */
/* Ordinals 51..57: database lookups                                   */
/* ------------------------------------------------------------------ */

struct hostent FAR * __far __pascal gethostbyaddr(const char FAR *addr, int len, int type)
{
    (void)addr; (void)len; (void)type;
    usos_not_implemented();
    return (struct hostent FAR *)0;
}

struct hostent FAR * __far __pascal gethostbyname(const char FAR *name)
{
    static struct hostent usos_hostent;
    static char usos_host_name[USOS_NET_NAME_MAX];
    static usos_u32 usos_host_addrs[USOS_NET_MAX_ADDRS];
    static char FAR *usos_host_addr_list[USOS_NET_MAX_ADDRS + 1];
    static char FAR *usos_host_aliases[1];
    usos_u32 addrs[USOS_NET_MAX_ADDRS];
    usos_u16 count = 0;
    char text[USOS_NET_NAME_MAX];
    int i;
    int rc;

    if (usos_startup_count == 0) {
        usos_last_error = WSANOTINITIALISED;
        return (struct hostent FAR *)0;
    }
    if (name == NULL) {
        usos_last_error = WSAEFAULT;
        return (struct hostent FAR *)0;
    }
    usos_far_tostr(text, name, (int)sizeof(text));
    if (text[0] == '\0') {
        usos_last_error = WSAHOST_NOT_FOUND;
        return (struct hostent FAR *)0;
    }
    rc = usos_sock_resolve(text, addrs, &count);
    if (rc != USOS_NET_OK || count == 0) {
        usos_last_error = (rc == USOS_SOCK_ETIMEDOUT) ? WSATRY_AGAIN
                                                     : WSAHOST_NOT_FOUND;
        return (struct hostent FAR *)0;
    }
    usos_far_copyz(usos_host_name, text, (unsigned int)sizeof(usos_host_name));
    for (i = 0; i < (int)count; i++) {
        usos_host_addrs[i] = addrs[i];
        usos_host_addr_list[i] = (char FAR *)&usos_host_addrs[i];
    }
    usos_host_addr_list[count] = (char FAR *)0;
    usos_host_aliases[0] = (char FAR *)0;
    usos_hostent.h_name = usos_host_name;
    usos_hostent.h_aliases = usos_host_aliases;
    usos_hostent.h_addrtype = AF_INET;
    usos_hostent.h_length = 4;
    usos_hostent.h_addr_list = usos_host_addr_list;
    usos_last_error = 0;
    return &usos_hostent;
}

struct protoent FAR * __far __pascal getprotobyname(const char FAR *name)
{
    (void)name;
    usos_not_implemented();
    return (struct protoent FAR *)0;
}

struct protoent FAR * __far __pascal getprotobynumber(int proto)
{
    (void)proto;
    usos_not_implemented();
    return (struct protoent FAR *)0;
}

struct servent FAR * __far __pascal getservbyname(const char FAR *name, const char FAR *proto)
{
    (void)name; (void)proto;
    usos_not_implemented();
    return (struct servent FAR *)0;
}

struct servent FAR * __far __pascal getservbyport(int port, const char FAR *proto)
{
    (void)port; (void)proto;
    usos_not_implemented();
    return (struct servent FAR *)0;
}

int __far __pascal gethostname(char FAR *name, int namelen)
{
    (void)name; (void)namelen;
    return usos_not_implemented();
}/* ------------------------------------------------------------------ */
/* Ordinals 101..116: Windows Sockets extensions                       */
/* ------------------------------------------------------------------ */

int __far __pascal WSAAsyncSelect(SOCKET s, HWND hWnd, unsigned int wMsg, long lEvent)
{
    (void)s; (void)hWnd; (void)wMsg; (void)lEvent;
    return usos_not_implemented();
}

HANDLE __far __pascal WSAAsyncGetHostByAddr(HWND hWnd, unsigned int wMsg,
                                            const char FAR *addr, int len, int type,
                                            char FAR *buf, int buflen)
{
    (void)hWnd; (void)wMsg; (void)addr; (void)len; (void)type; (void)buf; (void)buflen;
    return usos_async_not_implemented();
}

HANDLE __far __pascal WSAAsyncGetHostByName(HWND hWnd, unsigned int wMsg,
                                            const char FAR *name,
                                            char FAR *buf, int buflen)
{
    (void)hWnd; (void)wMsg; (void)name; (void)buf; (void)buflen;
    return usos_async_not_implemented();
}

HANDLE __far __pascal WSAAsyncGetProtoByNumber(HWND hWnd, unsigned int wMsg,
                                               int number, char FAR *buf, int buflen)
{
    (void)hWnd; (void)wMsg; (void)number; (void)buf; (void)buflen;
    return usos_async_not_implemented();
}

HANDLE __far __pascal WSAAsyncGetProtoByName(HWND hWnd, unsigned int wMsg,
                                             const char FAR *name,
                                             char FAR *buf, int buflen)
{
    (void)hWnd; (void)wMsg; (void)name; (void)buf; (void)buflen;
    return usos_async_not_implemented();
}

HANDLE __far __pascal WSAAsyncGetServByPort(HWND hWnd, unsigned int wMsg, int port,
                                            const char FAR *proto,
                                            char FAR *buf, int buflen)
{
    (void)hWnd; (void)wMsg; (void)port; (void)proto; (void)buf; (void)buflen;
    return usos_async_not_implemented();
}

HANDLE __far __pascal WSAAsyncGetServByName(HWND hWnd, unsigned int wMsg,
                                            const char FAR *name, const char FAR *proto,
                                            char FAR *buf, int buflen)
{
    (void)hWnd; (void)wMsg; (void)name; (void)proto; (void)buf; (void)buflen;
    return usos_async_not_implemented();
}

int __far __pascal WSACancelAsyncRequest(HANDLE hAsyncTaskHandle)
{
    (void)hAsyncTaskHandle;
    return usos_not_implemented();
}

FARPROC __far __pascal WSASetBlockingHook(FARPROC lpBlockFunc)
{
    (void)lpBlockFunc;
    usos_not_implemented();
    return (FARPROC)NULL;
}

int __far __pascal WSAUnhookBlockingHook(void)
{
    return usos_not_implemented();
}

int __far __pascal WSAGetLastError(void)
{
    return usos_last_error;
}

void __far __pascal WSASetLastError(int iError)
{
    usos_last_error = iError;
}

int __far __pascal WSACancelBlockingCall(void)
{
    return usos_not_implemented();
}

BOOL __far __pascal WSAIsBlocking(void)
{
    return FALSE;
}

/* Ordinal 151. */
int __far __pascal __WSAFDIsSet(SOCKET fd, fd_set FAR *set)
{
    (void)fd; (void)set;
    return 0;
}

/* ------------------------------------------------------------------ */
/* Win16 DLL plumbing (not part of the Winsock ABI)                    */
/* ------------------------------------------------------------------ */

int __far __pascal LibMain(HANDLE hInstance, WORD wDataSeg, WORD wHeapSize, LPSTR lpCmdLine)
{
    (void)hInstance; (void)wDataSeg; (void)wHeapSize; (void)lpCmdLine;
    usos_startup_count = 0;
    usos_last_error = 0;
    return 1;
}

int __far __pascal WEP(int nExitType)
{
    (void)nExitType;
    usos_startup_count = 0;
    return 1;
}
