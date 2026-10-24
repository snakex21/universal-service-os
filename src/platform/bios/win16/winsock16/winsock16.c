/* winsock16.c - USOS Winsock 1.1 provider for 16-bit Windows (Win16).
 *
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The TCP/UDP/DNS engine is our own implementation. USOSPKTQ supplies the
 * real-mode queue; Windows messages and a hidden timer drive async I/O.
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
#define USOS_WS_MAX_SOCKETS   USOS_MAX_SOCKETS
#define USOS_WS_MAX_UDPDG     512

#include "ws3_context.h"

#ifdef USOS_WS_DIAG
static void usos_abi_trace(const char FAR *label, const char FAR *text, unsigned long value)
{
    HFILE file;
    unsigned int length = 0, i;
    char digit;
    static const char hex[] = "0123456789ABCDEF";
    file = _lopen("C:\\NET\\WIN16\\WINSOCK.LOG", OF_WRITE);
    if (file == HFILE_ERROR) file = _lcreat("C:\\NET\\WIN16\\WINSOCK.LOG", 0);
    if (file == HFILE_ERROR) return;
    _llseek(file, 0, 2);
    while (label[length]) length++;
    _lwrite(file, label, length); _lwrite(file, " ", 1);
    if (text != NULL) {
        length = 0; while (text[length] && length < 255) length++;
        _lwrite(file, text, length); _lwrite(file, " ", 1);
    }
    for (i = 0; i < 8; i++) { digit = hex[(unsigned int)((value >> (28 - i * 4)) & 15)]; _lwrite(file, &digit, 1); }
    _lwrite(file, "\r\n", 2); _lclose(file);
}
#define USOS_TRACE(label,text,value) usos_abi_trace(label,text,value)
/* Successful data calls and posted events (2026-10-25: Netscape 3.04 GPF in
 * Windows 3.1 standard mode on the X470 left no trace after the last
 * would-block recv). Values: socket in the high word, result (byte count,
 * 0, the ioctlsocket argument) in the low word, unless noted. */
#define USOS_TRACE_SR(label,s,rc) usos_abi_trace(label,NULL,((unsigned long)(unsigned int)(s) << 16) | (unsigned int)(rc))
#else
#define USOS_TRACE_SR(label,s,rc) ((void)0)
#define USOS_TRACE(label,text,value) ((void)0)
#endif

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

static BOOL FAR PASCAL __loadds usos_default_hook(void)
{
    MSG msg;
    if (PeekMessage(&msg, NULL, 0, 0, PM_REMOVE)) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
        return TRUE;
    }
    return FALSE;
}

void usos_abi_idle(void)
{
    usos_app_context FAR *app = usos_app();
    BOOL (FAR PASCAL *hook)(void);
    MSG msg;
    app->blocking = 1;
    usos_pkt_poll(1);
    /* Only provider messages may be pumped ahead of a caller's hook. A hook
     * returning FALSE must not cause arbitrary application dispatch. */
    if (app->poll_window != NULL && PeekMessage(&msg, app->poll_window, 0, 0, PM_REMOVE))
        DispatchMessage(&msg);
    hook = (BOOL (FAR PASCAL *)(void))(app->hook != NULL ? app->hook : (FARPROC)usos_default_hook);
    (void)hook();
}

int usos_abi_cancelled(void)
{
    return usos_app()->cancelled;
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

static int usos_socket_type(int type, int protocol)
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
    case USOS_SOCK_ECANCELLED:   usos_last_error = WSAEINTR; break;
    case USOS_SOCK_ENOTSOCK:     usos_last_error = WSAENOTSOCK; break;
    case USOS_SOCK_ENOTCONN:     usos_last_error = WSAENOTCONN; break;
    case USOS_SOCK_ETIMEDOUT:    usos_last_error = WSAETIMEDOUT; break;
    case USOS_SOCK_ECONNREFUSED: usos_last_error = WSAECONNREFUSED; break;
    case USOS_SOCK_EMFILE:       usos_last_error = WSAEMFILE; break;
    case USOS_SOCK_ECONNRESET:   usos_last_error = WSAECONNRESET; break;
    case USOS_SOCK_EHOSTUNREACH: usos_last_error = WSAEHOSTUNREACH; break;
    case USOS_SOCK_ENOTREADY:    usos_last_error = WSASYSNOTREADY; break;
    case USOS_SOCK_EISCONN:      usos_last_error = WSAEISCONN; break;
    case USOS_SOCK_EWOULDBLOCK:  usos_last_error = WSAEWOULDBLOCK; break;
    case USOS_SOCK_EINPROGRESS:  usos_last_error = WSAEINPROGRESS; break;
    case USOS_SOCK_EALREADY:     usos_last_error = WSAEALREADY; break;
    case USOS_SOCK_EADDRINUSE:   usos_last_error = WSAEADDRINUSE; break;
    case USOS_SOCK_EADDRNOTAVAIL:usos_last_error = WSAEADDRNOTAVAIL; break;
    case USOS_SOCK_ESHUTDOWN:    usos_last_error = WSAESHUTDOWN; break;
    case USOS_SOCK_EOPNOTSUPP:   usos_last_error = WSAEOPNOTSUPP; break;
    case USOS_SOCK_ENOBUFS:      usos_last_error = WSAENOBUFS; break;
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
    tmp.sin_addr.s_addr = (u_long)net_htonl(ip);
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
    if (!usos_require_startup()) return (HANDLE)0;
    usos_last_error = WSAVERNOTSUPPORTED;
    return (HANDLE)0;
}

#include "ws2_private.inc"

int __far __pascal __export WSAStartup(WORD wVersionRequired, LPWSADATA lpWSAData)
{
    if (!usos_entry()) return usos_last_error;
    if (lpWSAData == NULL) {
        usos_last_error = WSAEFAULT;
        return WSAEFAULT;
    }
    if (LOBYTE(wVersionRequired) != 1) {
        usos_far_zero(lpWSAData, (unsigned int)sizeof(WSADATA));
        usos_last_error = WSAVERNOTSUPPORTED;
        return WSAVERNOTSUPPORTED;
    }

    /* No driver (USOSPKT without /Q) or no DPMI: the documented Winsock 1.1
     * answer is WSASYSNOTREADY, and the data block stays zeroed. */
    if (usos_global_startups == 0 && usos_sock_startup() != USOS_NET_OK) {
        usos_far_zero(lpWSAData, (unsigned int)sizeof(WSADATA));
        usos_last_error = WSASYSNOTREADY;
        return WSASYSNOTREADY;
    }

    usos_far_zero(lpWSAData, (unsigned int)sizeof(WSADATA));
    /* 1.0 is honoured as 1.0; anything newer in the 1.x line as 1.1. */
    lpWSAData->wVersion = (HIBYTE(wVersionRequired) == 0) ? (WORD)0x0100 : (WORD)0x0101;
    lpWSAData->wHighVersion = (WORD)0x0101;
    usos_far_copyz(lpWSAData->szDescription, USOS_WS_DESCRIPTION,
                   (unsigned int)sizeof(lpWSAData->szDescription));
    usos_far_copyz(lpWSAData->szSystemStatus,
                   usos_pkt_config_from_file() ? "USOSPKT queue; IP from C:\\NET\\MTCP.CFG" :
                   "USOSPKT queue; QEMU fallback (missing/invalid MTCP.CFG)",
                   (unsigned int)sizeof(lpWSAData->szSystemStatus));
    lpWSAData->iMaxSockets = USOS_WS_MAX_SOCKETS;
    lpWSAData->iMaxUdpDg = USOS_WS_MAX_UDPDG;
    lpWSAData->lpVendorInfo = NULL;

    usos_startup_count++;
    usos_global_startups++;
    usos_last_error = 0;
    return 0;
}

int __far __pascal __export WSACleanup(void)
{
    if (!usos_require_startup()) return SOCKET_ERROR;
    USOS_TRACE("cleanup enter",NULL,usos_global_startups);
    usos_startup_count--;
    usos_global_startups--;
    if (usos_startup_count == 0) {
        usos_async_cleanup(usos_app());
        USOS_TRACE("cleanup own done",NULL,usos_global_startups);
    }
    if (usos_global_startups == 0) {
        usos_async_class_cleanup();
        USOS_TRACE("cleanup class done",NULL,usos_global_startups);
        usos_sock_shutdown();      /* closes every socket, RELEASEs the queue */
        USOS_TRACE("cleanup transport done",NULL,usos_global_startups);
    }
    usos_last_error = 0;
    return 0;
}/* ------------------------------------------------------------------ */
/* Ordinals 1..23: socket API                                          */
/* ------------------------------------------------------------------ */

SOCKET __far __pascal __export accept(SOCKET s, struct sockaddr FAR *addr, int FAR *addrlen)
{
    usos_u32 ip;
    usos_u16 port;
    int rc;
    if (!usos_owned_socket(s)) return INVALID_SOCKET;
    if (addr != NULL && (addrlen == NULL || *addrlen < (int)sizeof(struct sockaddr_in))) {
        usos_last_error = WSAEFAULT; return INVALID_SOCKET;
    }
    if (s < USOS_MAX_SOCKETS) usos_selectors[s].notified &= ~FD_ACCEPT;
    rc = usos_block_done(usos_sock_accept((int)s, &ip, &port));
    if (rc < 0) { usos_map_error(rc); return INVALID_SOCKET; }
    usos_socket_defaults((SOCKET)rc);
    usos_socket_owners[rc] = GetCurrentTask();
    if (s < USOS_MAX_SOCKETS) usos_selectors[rc] = usos_selectors[s];
    usos_selectors[rc].notified = 0;
    usos_selectors[rc].connecting = 0;
    if (addr != NULL) usos_fill_sockaddr(addr, addrlen, ip, port);
    usos_last_error = 0;
    return (SOCKET)rc;
}

int __far __pascal __export bind(SOCKET s, const struct sockaddr FAR *name, int namelen)
{
    struct sockaddr_in addr;
    int rc;
    if (!usos_owned_socket(s)) return SOCKET_ERROR;
    if (name == NULL || namelen < (int)sizeof(addr)) { usos_last_error = WSAEFAULT; return SOCKET_ERROR; }
    usos_far_tobuf(&addr, name, sizeof(addr));
    if (addr.sin_family != AF_INET) { usos_last_error = WSAEAFNOSUPPORT; return SOCKET_ERROR; }
    rc = usos_sock_bind((int)s, net_ntohl(addr.sin_addr.s_addr), net_ntohs(addr.sin_port));
    if (rc < 0) return usos_map_error(rc);
    usos_last_error = 0; return 0;
}

int __far __pascal __export closesocket(SOCKET s)
{
    int rc;

    if (!usos_owned_socket(s)) return SOCKET_ERROR;
    if (usos_socket_options[s].linger_value.l_onoff &&
        !usos_socket_options[s].linger_value.l_linger) {
        USOS_TRACE_SR("closesocket abort", s, 0);
        rc = usos_block_done(usos_sock_abort((int)s));
    } else {
        USOS_TRACE_SR("closesocket", s, 0);
        rc = usos_block_done(usos_sock_close((int)s));
    }
    if (s < USOS_MAX_SOCKETS) usos_socket_defaults(s);
    if (s < USOS_MAX_SOCKETS) usos_socket_owners[s] = NULL;
    if (rc < 0)
        return usos_map_error(rc);
    USOS_TRACE_SR("closesocket ok", s, 0);
    usos_last_error = 0;
    return 0;
}

int __far __pascal __export connect(SOCKET s, const struct sockaddr FAR *name, int namelen)
{
    struct sockaddr_in addr;
    char hostname[USOS_NET_NAME_MAX];
    int rc;

    if (!usos_owned_socket(s)) return SOCKET_ERROR;
    if (name == NULL || namelen < (int)sizeof(struct sockaddr_in)) {
        usos_last_error = WSAEFAULT;
        return SOCKET_ERROR;
    }
    usos_far_tobuf(&addr, name, (unsigned int)sizeof(addr));
    USOS_TRACE("connect address wire", NULL, addr.sin_addr.s_addr);
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
    rc = usos_block_done(usos_sock_connect((int)s, net_ntohl((usos_u32)addr.sin_addr.s_addr),
                           net_ntohs((usos_u16)addr.sin_port),
                           (hostname[0] != '\0') ? hostname : (const char *)0));
    if (s < USOS_MAX_SOCKETS && (rc == 0 || rc == USOS_SOCK_EWOULDBLOCK || rc == USOS_SOCK_EINPROGRESS))
        usos_selectors[s].connecting = 1;
    if (rc < 0)
        return usos_map_error(rc);
    usos_last_error = 0;
    return 0;
}

int __far __pascal __export getpeername(SOCKET s, struct sockaddr FAR *name, int FAR *namelen)
{
    usos_u32 ip = 0;
    usos_u16 port = 0;
    int rc;

    if (!usos_owned_socket(s)) return SOCKET_ERROR;
    rc = usos_sock_remote((int)s, &ip, &port);
    if (rc < 0)
        return usos_map_error(rc);
    if (usos_fill_sockaddr(name, namelen, ip, port) < 0)
        return SOCKET_ERROR;
    usos_last_error = 0;
    return 0;
}

int __far __pascal __export getsockname(SOCKET s, struct sockaddr FAR *name, int FAR *namelen)
{
    usos_u32 ip = 0;
    usos_u16 port = 0;
    int rc;

    if (!usos_owned_socket(s)) return SOCKET_ERROR;
    rc = usos_sock_local((int)s, &ip, &port);
    if (rc < 0)
        return usos_map_error(rc);
    if (usos_fill_sockaddr(name, namelen, ip, port) < 0)
        return SOCKET_ERROR;
    usos_last_error = 0;
    return 0;
}

int __far __pascal __export getsockopt(SOCKET s, int level, int optname,
                              char FAR *optval, int FAR *optlen)
{
    return usos_get_option(s, level, optname, optval, optlen);
}

u_long __far __pascal __export htonl(u_long hostlong)
{
    if (!usos_entry()) return (u_long)SOCKET_ERROR;
    return (u_long)net_htonl((usos_u32)hostlong);
}

u_short __far __pascal __export htons(u_short hostshort)
{
    if (!usos_entry()) return (u_short)SOCKET_ERROR;
    return (u_short)net_htons((usos_u16)hostshort);
}

unsigned long __far __pascal __export inet_addr(const char FAR *cp)
{
    char text[24];
    if (!usos_entry()) return (unsigned long)INADDR_NONE;

    if (cp == NULL) {
        usos_last_error = WSAEFAULT;
        return (unsigned long)INADDR_NONE;
    }
    usos_far_tostr(text, cp, (int)sizeof(text));
    USOS_TRACE("inet_addr", cp, net_inet_addr(text));
    return (unsigned long)net_htonl(net_inet_addr(text));
}

char FAR * __far __pascal __export inet_ntoa(struct in_addr in)
{
    usos_app_context FAR *app = usos_app();
    if (!usos_entry()) return NULL;

    if (net_inet_ntoa(net_ntohl((usos_u32)in.s_addr), app->ntoa,
                      (usos_u16)sizeof(app->ntoa)) != USOS_NET_OK) {
        usos_last_error = WSAEINVAL;
        return (char FAR *)0;
    }
    usos_last_error = 0;
    return app->ntoa;
}

int __far __pascal __export ioctlsocket(SOCKET s, long cmd, u_long FAR *argp)
{
    usos_u32 count;
    int rc;
    /* The command itself (FIONBIO 8004667E, FIONREAD 4004667F, SIOCATMARK
     * 40047307): an unknown one is the WSAEINVAL seen after setsockopt. */
    USOS_TRACE("ioctlsocket cmd", NULL, (unsigned long)cmd);
    if (!usos_owned_socket(s)) return SOCKET_ERROR;
    if (argp == NULL) { usos_last_error = WSAEFAULT; return SOCKET_ERROR; }
    if (cmd == FIONBIO) {
        if (s < USOS_MAX_SOCKETS && *argp == 0 && usos_selectors[s].events != 0) {
            usos_last_error = WSAEINVAL; return SOCKET_ERROR;
        }
        rc = usos_sock_nonblocking((int)s, *argp != 0);
    } else if (cmd == FIONREAD) {
        usos_sock_tick();
        rc = usos_sock_available((int)s, &count);
        if (rc >= 0) *argp = (u_long)count;
    } else { usos_last_error = WSAEINVAL; return SOCKET_ERROR; }
    if (rc < 0) return usos_map_error(rc);
    USOS_TRACE_SR("ioctlsocket ok", s, *argp);
    usos_last_error = 0; return 0;
}

int __far __pascal __export listen(SOCKET s, int backlog)
{
    int rc;
    if (!usos_owned_socket(s)) return SOCKET_ERROR;
    rc = usos_sock_listen((int)s, backlog);
    if (rc < 0) return usos_map_error(rc);
    usos_last_error = 0; return 0;
}u_long __far __pascal __export ntohl(u_long netlong)
{
    if (!usos_entry()) return (u_long)SOCKET_ERROR;
    return (u_long)net_ntohl((usos_u32)netlong);
}

u_short __far __pascal __export ntohs(u_short netshort)
{
    if (!usos_entry()) return (u_short)SOCKET_ERROR;
    return (u_short)net_ntohs((usos_u16)netshort);
}

int __far __pascal __export recv(SOCKET s, char FAR *buf, int len, int flags)
{
    int rc;

    if (!usos_owned_socket(s)) return SOCKET_ERROR;
    if (len < 0 || (buf == NULL && len > 0)) {
        usos_last_error = WSAEFAULT;
        return SOCKET_ERROR;
    }
    if (len == 0)
        return 0;
    if (s < USOS_MAX_SOCKETS) usos_selectors[s].notified &= ~FD_READ;
    if (flags == MSG_PEEK) rc = usos_block_done(usos_sock_peek((int)s, (usos_u8 FAR *)buf, (usos_u16)len));
    else if (flags == 0) rc = usos_block_done(usos_sock_recv((int)s, (usos_u8 FAR *)buf, (usos_u16)len));
    else { usos_last_error = WSAEOPNOTSUPP; return SOCKET_ERROR; }
    if (rc < 0)
        return usos_map_error(rc);
    USOS_TRACE_SR(flags == MSG_PEEK ? "recv peek ok" : "recv ok", s, rc);
    usos_last_error = 0;
    return rc;
}

int __far __pascal __export recvfrom(SOCKET s, char FAR *buf, int len, int flags,
                            struct sockaddr FAR *from, int FAR *fromlen)
{
    usos_u32 ip;
    usos_u16 port;
    int rc;
    if (!usos_owned_socket(s)) return SOCKET_ERROR;
    if (len < 0 || (len && buf == NULL) || (from != NULL && (fromlen == NULL || *fromlen < (int)sizeof(struct sockaddr_in)))) {
        usos_last_error = WSAEFAULT; return SOCKET_ERROR;
    }
    if (flags != 0) { usos_last_error = WSAEOPNOTSUPP; return SOCKET_ERROR; }
    if (s < USOS_MAX_SOCKETS) usos_selectors[s].notified &= ~FD_READ;
    rc = usos_block_done(usos_sock_recvfrom((int)s, (usos_u8 FAR *)buf, (usos_u16)len, &ip, &port));
    if (rc < 0) return usos_map_error(rc);
    if (from != NULL) usos_fill_sockaddr(from, fromlen, ip, port);
    USOS_TRACE_SR("recvfrom ok", s, rc);
    usos_last_error = 0; return rc;
}

int __far __pascal __export select(int nfds, fd_set FAR *readfds, fd_set FAR *writefds,
                          fd_set FAR *exceptfds, const struct timeval FAR *timeout)
{
    (void)nfds;
#ifdef USOS_WS_DIAG
    {
        /* Ready count (or -1) in the low word, the read/write/except set
         * sizes the caller passed in the high word (4 bits each). */
        unsigned int sizes = (readfds != NULL ? (readfds->fd_count & 15) << 8 : 0)
                           | (writefds != NULL ? (writefds->fd_count & 15) << 4 : 0)
                           | (exceptfds != NULL ? exceptfds->fd_count & 15 : 0);
        int rc = usos_select_wait(readfds, writefds, exceptfds, timeout);
        USOS_TRACE_SR(timeout == NULL ? "select" : "select timeout", sizes, rc);
        return rc;
    }
#else
    return usos_select_wait(readfds, writefds, exceptfds, timeout);
#endif
}

int __far __pascal __export send(SOCKET s, const char FAR *buf, int len, int flags)
{
    int rc;

    if (!usos_owned_socket(s)) return SOCKET_ERROR;
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
    rc = usos_block_done(usos_sock_send((int)s, (const usos_u8 FAR *)buf, (usos_u16)len));
    if (s < USOS_MAX_SOCKETS && rc == USOS_SOCK_EWOULDBLOCK) usos_selectors[s].notified &= ~FD_WRITE;
    if (rc < 0)
        return usos_map_error(rc);
    USOS_TRACE_SR("send ok", s, rc);
    usos_last_error = 0;
    return rc;                         /* partial writes are reported as such */
}

int __far __pascal __export sendto(SOCKET s, const char FAR *buf, int len, int flags,
                          const struct sockaddr FAR *to, int tolen)
{
    struct sockaddr_in addr;
    int rc;
    if (!usos_owned_socket(s)) return SOCKET_ERROR;
    if (to == NULL) return send(s, buf, len, flags);
    if (len < 0 || (len && buf == NULL) || tolen < (int)sizeof(addr)) { usos_last_error = WSAEFAULT; return SOCKET_ERROR; }
    if (flags != 0) { usos_last_error = WSAEOPNOTSUPP; return SOCKET_ERROR; }
    usos_far_tobuf(&addr, to, sizeof(addr));
    if (addr.sin_family != AF_INET) { usos_last_error = WSAEAFNOSUPPORT; return SOCKET_ERROR; }
    rc = usos_block_done(usos_sock_sendto((int)s, net_ntohl(addr.sin_addr.s_addr), net_ntohs(addr.sin_port), (const usos_u8 FAR *)buf, (usos_u16)len));
    if (s < USOS_MAX_SOCKETS && rc == USOS_SOCK_EWOULDBLOCK) usos_selectors[s].notified &= ~FD_WRITE;
    if (rc < 0) return usos_map_error(rc);
    USOS_TRACE_SR("sendto ok", s, rc);
    usos_last_error = 0; return rc;
}

int __far __pascal __export setsockopt(SOCKET s, int level, int optname,
                              const char FAR *optval, int optlen)
{
    return usos_set_option(s, level, optname, optval, optlen);
}

int __far __pascal __export shutdown(SOCKET s, int how)
{
    int rc;
    if (!usos_owned_socket(s)) return SOCKET_ERROR;
    if (how < 0 || how > 2) { usos_last_error = WSAEINVAL; return SOCKET_ERROR; }
    rc = usos_sock_shutdown_one((int)s, how);
    if (rc < 0) return usos_map_error(rc);
    usos_last_error = 0; return 0;
}

SOCKET __far __pascal __export socket(int af, int type, int protocol)
{
    int kind;
    int slot;

    USOS_TRACE("socket type",NULL,type);
    if (!usos_require_startup()) return INVALID_SOCKET;
    if (af != AF_INET) {
        usos_last_error = WSAEAFNOSUPPORT;
        return INVALID_SOCKET;
    }
    kind = usos_socket_type(type, protocol);
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
    usos_socket_defaults((SOCKET)slot);
    usos_socket_owners[slot] = GetCurrentTask();
    usos_last_error = 0;
    return (SOCKET)slot;
}

/* ------------------------------------------------------------------ */
/* Ordinals 51..57: database lookups                                   */
/* ------------------------------------------------------------------ */

struct hostent FAR * __far __pascal __export gethostbyaddr(const char FAR *addr, int len, int type)
{
    usos_app_context FAR *app = usos_app();
    char name[USOS_NET_NAME_MAX];
    usos_u32 wire, ip;
    int rc;
    if (!usos_require_startup()) return NULL;
    if (addr == NULL || len != 4) { usos_last_error = WSAEFAULT; return NULL; }
    if (type != AF_INET) { usos_last_error = WSAEAFNOSUPPORT; return NULL; }
    usos_far_tobuf(&wire, addr, 4); ip = net_ntohl(wire);
    rc = usos_reverse_name(ip, name, sizeof(name));
    usos_block_done(rc);
    if (rc < 0) { usos_last_error = rc == USOS_SOCK_ECANCELLED ? WSAEINTR : (rc == USOS_SOCK_ETIMEDOUT ? WSATRY_AGAIN : WSAHOST_NOT_FOUND); return NULL; }
    usos_pack_host(app->reverse_result, sizeof(app->reverse_result), name, ip);
    usos_last_error = 0; return (struct hostent FAR *)app->reverse_result;
}

struct hostent FAR * __far __pascal __export gethostbyname(const char FAR *name)
{
    usos_app_context FAR *app = usos_app();
    usos_u32 addrs[USOS_NET_MAX_ADDRS];
    usos_u16 count = 0;
    char text[USOS_NET_NAME_MAX];
    int i;
    int rc;

    if (!usos_require_startup()) return (struct hostent FAR *)0;
    if (name == NULL) {
        usos_last_error = WSAEFAULT;
        return (struct hostent FAR *)0;
    }
    usos_far_tostr(text, name, (int)sizeof(text));
    USOS_TRACE("gethostbyname", name, 0);
    if (text[0] == '\0') {
        usos_last_error = WSAHOST_NOT_FOUND;
        return (struct hostent FAR *)0;
    }
    if (usos_text_equal(text, "usos") || usos_text_equal(text, "localhost")) {
        addrs[0] = usos_text_equal(text, "localhost") ? 0x7f000001UL : usos_sock_local_ip();
        count = 1; rc = USOS_NET_OK;
    } else rc = usos_sock_resolve(text, addrs, &count);
    usos_block_done(rc);
    if (rc != USOS_NET_OK || count == 0) {
        usos_last_error = rc == USOS_SOCK_ECANCELLED ? WSAEINTR : ((rc == USOS_SOCK_ETIMEDOUT) ? WSATRY_AGAIN : WSAHOST_NOT_FOUND);
        return (struct hostent FAR *)0;
    }
    USOS_TRACE("resolved host", text, addrs[0]);
    usos_far_copyz(app->host_name, text, (unsigned int)sizeof(app->host_name));
    for (i = 0; i < (int)count; i++) {
        app->host_addresses[i] = net_htonl(addrs[i]);
        app->host_list[i] = (char FAR *)&app->host_addresses[i];
    }
    app->host_list[count] = (char FAR *)0;
    app->host_aliases[0] = (char FAR *)0;
    app->host.h_name = app->host_name;
    app->host.h_aliases = app->host_aliases;
    app->host.h_addrtype = AF_INET;
    app->host.h_length = 4;
    app->host.h_addr_list = app->host_list;
    usos_last_error = 0;
    return &app->host;
}

struct protoent FAR * __far __pascal __export getprotobyname(const char FAR *name)
{
    if (!usos_require_startup()) return NULL;
    if (name == NULL) { usos_last_error = WSAEFAULT; return NULL; }
    if (usos_text_equal(name, "tcp")) return usos_protocol(6);
    if (usos_text_equal(name, "udp")) return usos_protocol(17);
    if (usos_text_equal(name, "icmp")) return usos_protocol(1);
    usos_last_error = WSANO_DATA; return NULL;
}

struct protoent FAR * __far __pascal __export getprotobynumber(int proto)
{
    if (!usos_require_startup()) return NULL;
    return usos_protocol(proto);
}

struct servent FAR * __far __pascal __export getservbyname(const char FAR *name, const char FAR *proto)
{
    if (!usos_require_startup()) return NULL;
    if (name == NULL) { usos_last_error = WSAEFAULT; return NULL; }
    return usos_service(name, 0, proto);
}

struct servent FAR * __far __pascal __export getservbyport(int port, const char FAR *proto)
{
    if (!usos_require_startup()) return NULL;
    return usos_service(NULL, net_ntohs((usos_u16)port), proto);
}

int __far __pascal __export gethostname(char FAR *name, int namelen)
{
    if (!usos_require_startup()) return SOCKET_ERROR;
    if (name == NULL || namelen < 5) { usos_last_error = WSAEFAULT; return SOCKET_ERROR; }
    usos_far_copyz(name, "usos", (unsigned int)namelen);
    usos_last_error = 0; return 0;
}/* ------------------------------------------------------------------ */
/* Ordinals 101..116: Windows Sockets extensions                       */
/* ------------------------------------------------------------------ */

int __far __pascal __export WSAAsyncSelect(SOCKET s, HWND hWnd, unsigned int wMsg, long lEvent)
{
    int rc;
    USOS_TRACE("async select mask",NULL,lEvent);
    if (!usos_owned_socket(s)) return SOCKET_ERROR;
    if (s >= USOS_MAX_SOCKETS || usos_sock_kind((int)s) < 0) { usos_last_error = WSAENOTSOCK; return SOCKET_ERROR; }
    if ((lEvent & ~(FD_READ | FD_WRITE | FD_OOB | FD_CONNECT | FD_CLOSE | FD_ACCEPT)) != 0 ||
        (lEvent && (hWnd == NULL || !IsWindow(hWnd) || wMsg == 0))) {
        usos_last_error = WSAEINVAL; return SOCKET_ERROR;
    }
    if (lEvent && !usos_async_start()) { usos_last_error = WSAENOBUFS; return SOCKET_ERROR; }
    if (lEvent) {
        rc = usos_sock_nonblocking((int)s, 1);
        if (rc < 0) return usos_map_error(rc);
    }
    usos_selectors[s].window = hWnd;
    usos_selectors[s].message = wMsg;
    usos_selectors[s].events = lEvent;
    usos_selectors[s].notified = 0;
    usos_last_error = 0; return 0;
}

HANDLE __far __pascal __export WSAAsyncGetHostByAddr(HWND hWnd, unsigned int wMsg,
                                            const char FAR *addr, int len, int type,
                                            char FAR *buf, int buflen)
{
    usos_u32 wire;
    if (!usos_require_startup()) return (HANDLE)0;
    if (addr == NULL || len != 4) { usos_last_error = WSAEFAULT; return (HANDLE)0; }
    if (type != AF_INET) { usos_last_error = WSAEAFNOSUPPORT; return (HANDLE)0; }
    usos_far_tobuf(&wire, addr, 4);
    return usos_queue_name(hWnd, wMsg, NULL, net_ntohl(wire), 1, buf, buflen);
}

HANDLE __far __pascal __export WSAAsyncGetHostByName(HWND hWnd, unsigned int wMsg,
                                            const char FAR *name,
                                            char FAR *buf, int buflen)
{
    return usos_queue_name(hWnd, wMsg, name, 0, 0, buf, buflen);
}

HANDLE __far __pascal __export WSAAsyncGetProtoByNumber(HWND hWnd, unsigned int wMsg,
                                               int number, char FAR *buf, int buflen)
{
    (void)hWnd; (void)wMsg; (void)number; (void)buf; (void)buflen;
    return usos_async_not_implemented();
}

HANDLE __far __pascal __export WSAAsyncGetProtoByName(HWND hWnd, unsigned int wMsg,
                                             const char FAR *name,
                                             char FAR *buf, int buflen)
{
    (void)hWnd; (void)wMsg; (void)name; (void)buf; (void)buflen;
    return usos_async_not_implemented();
}

HANDLE __far __pascal __export WSAAsyncGetServByPort(HWND hWnd, unsigned int wMsg, int port,
                                            const char FAR *proto,
                                            char FAR *buf, int buflen)
{
    (void)hWnd; (void)wMsg; (void)port; (void)proto; (void)buf; (void)buflen;
    return usos_async_not_implemented();
}

HANDLE __far __pascal __export WSAAsyncGetServByName(HWND hWnd, unsigned int wMsg,
                                            const char FAR *name, const char FAR *proto,
                                            char FAR *buf, int buflen)
{
    (void)hWnd; (void)wMsg; (void)name; (void)proto; (void)buf; (void)buflen;
    return usos_async_not_implemented();
}

int __far __pascal __export WSACancelAsyncRequest(HANDLE hAsyncTaskHandle)
{
    int i;
    if (!usos_require_startup()) return SOCKET_ERROR;
    for (i = 0; i < USOS_ASYNC_JOBS; i++) if (usos_jobs[i].active &&
            usos_jobs[i].handle == (unsigned int)hAsyncTaskHandle) {
        if (usos_jobs[i].socket_id >= 0) usos_block_done(usos_sock_close(usos_jobs[i].socket_id));
        usos_jobs[i].active = 0;
        usos_last_error = 0; return 0;
    }
    usos_last_error = WSAEINVAL; return SOCKET_ERROR;
}

FARPROC __far __pascal __export WSASetBlockingHook(FARPROC lpBlockFunc)
{
    FARPROC previous;
    if (!usos_require_startup()) return NULL;
    if (lpBlockFunc == NULL) { usos_last_error = WSAEFAULT; return NULL; }
    previous = usos_app()->hook;
    usos_app()->hook = lpBlockFunc;
    usos_last_error = 0;
    return previous != NULL ? previous : (FARPROC)usos_default_hook;
}

int __far __pascal __export WSAUnhookBlockingHook(void)
{
    if (!usos_require_startup()) return SOCKET_ERROR;
    usos_app()->hook = NULL;
    usos_last_error = 0; return 0;
}

int __far __pascal __export WSAGetLastError(void)
{
    USOS_TRACE("last error",NULL,usos_last_error);
    return usos_last_error;
}

void __far __pascal __export WSASetLastError(int iError)
{
    usos_last_error = iError;
}

int __far __pascal __export WSACancelBlockingCall(void)
{
    if (!usos_app()->blocking) { usos_last_error = WSAEINVAL; return SOCKET_ERROR; }
    usos_app()->cancelled = 1;
    usos_last_error = 0; return 0;
}

BOOL __far __pascal __export WSAIsBlocking(void)
{
    return usos_app()->blocking ? TRUE : FALSE;
}

/* Ordinal 151. */
int __far __pascal __export __WSAFDIsSet(SOCKET fd, fd_set FAR *set)
{
    unsigned int i;
    if (!usos_entry()) return 0;
    if (set == NULL || set->fd_count > FD_SETSIZE) return 0;
    for (i = 0; i < set->fd_count; i++) if (set->fd_array[i] == fd) return 1;
    return 0;
}

/* ------------------------------------------------------------------ */
/* Win16 DLL plumbing (not part of the Winsock ABI)                    */
/* ------------------------------------------------------------------ */

int __far __pascal LibMain(HANDLE hInstance, WORD wDataSeg, WORD wHeapSize, LPSTR lpCmdLine)
{
    (void)wDataSeg; (void)wHeapSize; (void)lpCmdLine;
    usos_instance = (HINSTANCE)hInstance;
    usos_global_startups = 0;
    return 1;
}

int __far __pascal __export WEP(int nExitType)
{
    int i;
    (void)nExitType;
    for (i = 0; i < USOS_APP_CONTEXTS; i++) if (usos_apps[i] != NULL) {
        usos_async_cleanup(usos_apps[i]);
        GlobalUnlock(usos_app_memory[i]);
        GlobalFree(usos_app_memory[i]);
        usos_apps[i] = NULL; usos_app_memory[i] = NULL;
    }
    usos_async_class_cleanup();
    if (usos_global_startups != 0) usos_sock_shutdown();
    usos_global_startups = 0;
    return 1;
}
