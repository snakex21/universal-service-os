/* Private Win16 event and database support, included after ABI copy helpers.
 * Copyright (C)2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 * Contracts: public Windows Sockets1.1 documentation and RFC1035.
 * No callback is added to the public NE export table.
 */
#define USOS_ASYNC_JOBS 4
#define USOS_ASYNC_CLASS "USOS Winsock events"

typedef struct {
    HWND window;
    unsigned int message;
    long events, notified;
    int connecting;
} usos_selector;
typedef struct {
    int keepalive, reuseaddr, nodelay;
    struct linger linger_value;
} usos_options;
typedef struct {
    int active, reverse, socket_id, sent, retries;
    unsigned int handle;
    HWND window;
    unsigned int message;
    char FAR *buffer;
    int room;
    char name[USOS_NET_NAME_MAX];
    usos_u32 address, last_sent, began;
} usos_async_job;

static usos_selector usos_selectors[USOS_MAX_SOCKETS];
static usos_options usos_socket_options[USOS_MAX_SOCKETS];
static usos_async_job usos_jobs[USOS_ASYNC_JOBS];
static HINSTANCE usos_instance;
static HWND usos_poll_window;
static FARPROC usos_poll_proc;
static unsigned int usos_next_async;
static int usos_in_async_pump, usos_class_registered;
static void usos_async_pump(void);

static int usos_require_startup(void)
{
    if (usos_startup_count != 0) return 1;
    usos_last_error = WSANOTINITIALISED;
    return 0;
}

static int usos_text_equal(const char FAR *left, const char *right)
{
    unsigned int i;
    unsigned char a, b;
    if (left == NULL || right == NULL) return left == right;
    for (i = 0; i < 256; i++) {
        a = (unsigned char)left[i]; b = (unsigned char)right[i];
        if (a >= 'A' && a <= 'Z') a += 'a' - 'A';
        if (b >= 'A' && b <= 'Z') b += 'a' - 'A';
        if (a != b) return 0;
        if (a == 0) return 1;
    }
    return 0;
}

static void usos_socket_defaults(SOCKET s)
{
    if (s >= USOS_MAX_SOCKETS) return;
    usos_far_zero(&usos_selectors[s], sizeof(usos_selectors[s]));
    usos_far_zero(&usos_socket_options[s], sizeof(usos_socket_options[s]));
    usos_socket_options[s].nodelay = 1; /* The bounded engine sends immediately. */
}

static int usos_error_number(int engine_error)
{
    int saved, result;
    if (engine_error >= 0) return 0;
    saved = usos_last_error;
    usos_map_error(engine_error);
    result = usos_last_error;
    usos_last_error = saved;
    return result;
}

static LONG FAR PASCAL __loadds usos_event_window(HWND window, UINT message,
                                                  WPARAM wp, LPARAM lp)
{
    if (message == WM_TIMER && wp == 1) { usos_async_pump(); return 0; }
    return DefWindowProc(window, message, wp, lp);
}

static int usos_async_start(void)
{
    WNDCLASS cls;
    if (usos_poll_window != NULL && IsWindow(usos_poll_window)) return 1;
    usos_poll_window = NULL;
    if (!usos_class_registered) {
        usos_far_zero(&cls, sizeof(cls));
        usos_poll_proc = MakeProcInstance((FARPROC)usos_event_window, usos_instance);
        if (usos_poll_proc == NULL) return 0;
        cls.lpfnWndProc = (WNDPROC)usos_poll_proc;
        cls.hInstance = usos_instance;
        cls.lpszClassName = USOS_ASYNC_CLASS;
        if (!RegisterClass(&cls)) { FreeProcInstance(usos_poll_proc); usos_poll_proc = NULL; return 0; }
        usos_class_registered = 1;
    }
    usos_poll_window = CreateWindow(USOS_ASYNC_CLASS, "", 0, 0, 0, 0, 0,
                                   NULL, NULL, usos_instance, NULL);
    if (usos_poll_window == NULL) return 0;
    if (SetTimer(usos_poll_window, 1, 20, NULL) == 0) {
        DestroyWindow(usos_poll_window); usos_poll_window = NULL; return 0;
    }
    return 1;
}

static void usos_async_cleanup(void)
{
    int i;
    if (usos_poll_window != NULL && IsWindow(usos_poll_window)) {
        KillTimer(usos_poll_window, 1);
        DestroyWindow(usos_poll_window);
    }
    usos_poll_window = NULL;
    if (usos_class_registered) UnregisterClass(USOS_ASYNC_CLASS, usos_instance);
    usos_class_registered = 0;
    if (usos_poll_proc != NULL) FreeProcInstance(usos_poll_proc);
    usos_poll_proc = NULL;
    for (i = 0; i < USOS_ASYNC_JOBS; i++) {
        if (usos_jobs[i].active && usos_jobs[i].socket_id >= 0)
            usos_sock_close(usos_jobs[i].socket_id);
        usos_jobs[i].active = 0;
    }
    for (i = 0; i < USOS_MAX_SOCKETS; i++) usos_socket_defaults((SOCKET)i);
}

static int usos_pack_host(char FAR *buffer, int room, const char *name,
                           usos_u32 ip)
{
    struct hostent FAR *host;
    char FAR * FAR *aliases;
    char FAR * FAR *addresses;
    unsigned int length, offset, needed;
    unsigned int i;
    usos_u32 wire;
    for (length = 0; name[length] && length < 255; length++) {}
    offset = (unsigned int)((sizeof(struct hostent) + length + 2) & ~1U);
    needed = offset + 3 * sizeof(char FAR *) + 4;
    if (room < (int)needed) return (int)needed;
    usos_far_zero(buffer, needed);
    host = (struct hostent FAR *)buffer;
    host->h_name = buffer + sizeof(struct hostent);
    for (i = 0; i < length; i++) host->h_name[i] = name[i];
    host->h_name[length] = 0;
    aliases = (char FAR * FAR *)(buffer + offset);
    host->h_aliases = aliases;
    aliases[0] = NULL;
    addresses = (char FAR * FAR *)(buffer + offset + sizeof(char FAR *));
    host->h_addr_list = addresses;
    addresses[0] = buffer + offset + 3 * sizeof(char FAR *);
    addresses[1] = NULL;
    wire = net_htonl(ip);
    usos_far_tobuf(addresses[0], &wire, 4);
    host->h_addrtype = AF_INET;
    host->h_length = 4;
    return -(int)needed; /* Negative means the complete caller buffer exists. */
}

static void usos_async_done(usos_async_job *job, const char *name,
                             usos_u32 ip, int error)
{
    int size = 0;
    if (!error) {
        size = usos_pack_host(job->buffer, job->room, name, ip);
        if (size > 0) error = WSAENOBUFS;
        else size = -size;
    }
    if (IsWindow(job->window)) PostMessage(job->window, job->message,
                (WPARAM)job->handle, MAKELONG((WORD)size, (WORD)error));
    if (job->socket_id >= 0) usos_sock_close(job->socket_id);
    job->active = 0;
}

static HANDLE usos_queue_name(HWND window, unsigned int message,
                               const char FAR *name, usos_u32 ip, int reverse,
                               char FAR *buffer, int room)
{
    int i;
    usos_async_job *job;
    if (!usos_require_startup()) return (HANDLE)0;
    if (window == NULL || !IsWindow(window) || message == 0) { usos_last_error = WSAEINVAL; return (HANDLE)0; }
    if (buffer == NULL || room <= 0 || (name == NULL && !reverse)) { usos_last_error = WSAEFAULT; return (HANDLE)0; }
    if (!usos_async_start()) { usos_last_error = WSAENOBUFS; return (HANDLE)0; }
    for (i = 0; i < USOS_ASYNC_JOBS && usos_jobs[i].active; i++) {}
    if (i == USOS_ASYNC_JOBS) { usos_last_error = WSAENOBUFS; return (HANDLE)0; }
    job = &usos_jobs[i];
    usos_far_zero(job, sizeof(*job));
    job->socket_id = -1;
    usos_next_async = (usos_next_async % 0x7ff0U) + 1;
    job->handle = usos_next_async;
    job->active = 1;
    job->reverse = reverse;
    job->window = window; job->message = message;
    job->buffer = buffer; job->room = room; job->address = ip;
    job->began = (usos_u32)GetTickCount();
    if (!reverse) usos_far_tostr(job->name, name, sizeof(job->name));
    usos_last_error = 0;
    return (HANDLE)job->handle;
}

static void usos_post_event(SOCKET slot, long event, int error)
{
    usos_selector *selector = &usos_selectors[slot];
    if ((selector->events & event) == 0 || (selector->notified & event) != 0) return;
    if (PostMessage(selector->window, selector->message, (WPARAM)slot,
                    MAKELONG((WORD)event, (WORD)error))) selector->notified |= event;
}

/* dns_extra.h/c supply only bounded RFC1035 PTR parsing, no transport. */
#include "net/dns_extra.h"

static void usos_name_step(usos_async_job *job)
{
    usos_u8 bytes[512];
    char name[USOS_NET_NAME_MAX];
    usos_u32 addrs[USOS_NET_MAX_ADDRS], address, from;
    usos_u16 count, length, port;
    usos_u32 now;
    int rc;
    if (!IsWindow(job->window)) {
        if (job->socket_id >= 0) usos_sock_close(job->socket_id);
        job->active = 0; return;
    }
    if (job->socket_id < 0) {
        if (!job->reverse) {
            address = net_inet_addr(job->name);
            if (usos_text_equal(job->name, "usos")) address = usos_sock_local_ip();
            if (usos_text_equal(job->name, "localhost")) address = 0x7f000001UL;
            if (address != 0xffffffffUL) { usos_async_done(job, job->name, address, 0); return; }
        } else if (job->address == usos_sock_local_ip() || job->address == 0x7f000001UL) {
            usos_async_done(job, job->address == 0x7f000001UL ? "localhost" : "usos", job->address, 0); return;
        }
        job->socket_id = usos_sock_open(USOS_SOCK_DGRAM);
        if (job->socket_id < 0) { usos_async_done(job, "", 0, WSAENOBUFS); return; }
        usos_sock_nonblocking(job->socket_id, 1);
        rc = usos_sock_connect(job->socket_id, usos_pkt_dns(), 53, NULL);
        if (rc < 0 && rc != USOS_SOCK_EWOULDBLOCK) { usos_async_done(job, "", 0, WSATRY_AGAIN); return; }
    }
    now = (usos_u32)GetTickCount();
    if ((usos_u32)(now - job->began) >= 16000UL) { usos_async_done(job, "", 0, WSATRY_AGAIN); return; }
    if (!job->sent || (usos_u32)(now - job->last_sent) >= (1000UL << job->retries)) {
        if (job->sent && job->retries >= 3) { usos_async_done(job, "", 0, WSATRY_AGAIN); return; }
        if (job->reverse) length = net_dns_build_ptr_query(bytes, sizeof(bytes), job->handle, job->address);
        else length = net_dns_build_query(bytes, sizeof(bytes), job->handle, job->name);
        if (!length) { usos_async_done(job, "", 0, WSAHOST_NOT_FOUND); return; }
        rc = usos_sock_send(job->socket_id, bytes, length);
        if (rc == USOS_SOCK_EWOULDBLOCK) return;
        if (rc < 0) { usos_async_done(job, "", 0, WSATRY_AGAIN); return; }
        if (job->sent) job->retries++;
        job->sent = 1; job->last_sent = now;
    }
    rc = usos_sock_recvfrom(job->socket_id, bytes, sizeof(bytes), &from, &port);
    if (rc == USOS_SOCK_EWOULDBLOCK) return;
    if (rc < 0) { usos_async_done(job, "", 0, WSATRY_AGAIN); return; }
    if (from != usos_pkt_dns() || port != 53 || rc < 12 || net_get16(bytes) != job->handle) return;
    if (job->reverse) {
        rc = net_dns_parse_ptr_response(bytes, (usos_u16)rc, job->handle, name, sizeof(name));
        if (rc != USOS_NET_OK) usos_async_done(job, "", 0, rc == USOS_NET_ERR_NAME ? WSAHOST_NOT_FOUND : WSATRY_AGAIN);
        else usos_async_done(job, name, job->address, 0);
    } else {
        rc = net_dns_parse_response(bytes, (usos_u16)rc, job->handle, addrs, &count);
        if (rc != USOS_NET_OK || count == 0) usos_async_done(job, "", 0, rc == USOS_NET_ERR_NAME ? WSAHOST_NOT_FOUND : WSATRY_AGAIN);
        else usos_async_done(job, job->name, addrs[0], 0);
    }
}

static void usos_async_pump(void)
{
    int i, ready, error;
    usos_u32 available;
    usos_selector *selector;
    if (usos_in_async_pump || usos_startup_count == 0) return;
    usos_in_async_pump = 1;
    usos_sock_tick();
    for (i = 0; i < USOS_ASYNC_JOBS; i++) if (usos_jobs[i].active) usos_name_step(&usos_jobs[i]);
    for (i = 0; i < USOS_MAX_SOCKETS; i++) {
        selector = &usos_selectors[i];
        if (!selector->events) continue;
        if (!IsWindow(selector->window)) { selector->events = 0; continue; }
        ready = usos_sock_readiness(i);
        if (ready < 0) continue;
        error = usos_error_number(usos_sock_error(i, 0));
        if (selector->connecting && (ready & (USOS_SOCK_CONNECT | USOS_SOCK_EXCEPTION))) {
            usos_post_event((SOCKET)i, FD_CONNECT, error);
            selector->connecting = 0;
        }
        if (ready & USOS_SOCK_READABLE) usos_post_event((SOCKET)i, FD_READ, 0);
        if (ready & USOS_SOCK_WRITABLE) usos_post_event((SOCKET)i, FD_WRITE, 0);
        if (ready & USOS_SOCK_ACCEPT) usos_post_event((SOCKET)i, FD_ACCEPT, 0);
        available = 0; usos_sock_available(i, &available);
        if ((ready & USOS_SOCK_CLOSED) && (available == 0 || error)) usos_post_event((SOCKET)i, FD_CLOSE, error);
    }
    usos_in_async_pump = 0;
}

static int usos_filter_set(fd_set *destination, const fd_set *source, int mask)
{
    unsigned int i;
    int ready;
    destination->fd_count = 0;
    for (i = 0; i < source->fd_count; i++) {
        ready = usos_sock_readiness((int)source->fd_array[i]);
        if (ready < 0) return usos_map_error(ready);
        if (ready & mask) destination->fd_array[destination->fd_count++] = source->fd_array[i];
    }
    return destination->fd_count;
}

static int usos_select_wait(fd_set FAR *readset, fd_set FAR *writeset,
                             fd_set FAR *exceptset, const struct timeval FAR *timeout)
{
    fd_set sources[3], result[3];
    fd_set FAR *sets[3];
    int masks[3];
    int i, rc, total, sockets = 0;
    usos_u32 began, limit;
    if (!usos_require_startup()) return SOCKET_ERROR;
    sets[0] = readset; sets[1] = writeset; sets[2] = exceptset;
    masks[0] = USOS_SOCK_READABLE | USOS_SOCK_CLOSED | USOS_SOCK_ACCEPT;
    masks[1] = USOS_SOCK_WRITABLE;
    masks[2] = USOS_SOCK_EXCEPTION;
    for (i = 0; i < 3; i++) {
        usos_far_zero(&sources[i], sizeof(fd_set));
        if (sets[i] == NULL) continue;
        if (sets[i]->fd_count > FD_SETSIZE) { usos_last_error = WSAEINVAL; return SOCKET_ERROR; }
        sockets += sets[i]->fd_count;
        usos_far_tobuf(&sources[i], sets[i], sizeof(fd_set));
    }
    if (!sockets) { usos_last_error = WSAEINVAL; return SOCKET_ERROR; }
    limit = 0x7fffffffUL;
    if (timeout != NULL) {
        if (timeout->tv_sec < 0 || timeout->tv_usec < 0 || timeout->tv_usec >= 1000000L) { usos_last_error = WSAEINVAL; return SOCKET_ERROR; }
        if ((usos_u32)timeout->tv_sec < 2147483UL)
            limit = (usos_u32)timeout->tv_sec * 1000UL + ((usos_u32)timeout->tv_usec + 999UL) / 1000UL;
    }
    began = (usos_u32)GetTickCount();
    do {
        usos_async_pump();
        total = 0;
        for (i = 0; i < 3; i++) {
            rc = usos_filter_set(&result[i], &sources[i], masks[i]);
            if (rc < 0) return SOCKET_ERROR;
            total += rc;
        }
        if (total || (timeout != NULL && (usos_u32)((usos_u32)GetTickCount() - began) >= limit)) break;
        usos_abi_idle();
    } while (1);
    for (i = 0; i < 3; i++) if (sets[i] != NULL) usos_far_tobuf(sets[i], &result[i], sizeof(fd_set));
    usos_last_error = 0;
    return total;
}

static int usos_get_option(SOCKET s, int level, int option, char FAR *value, int FAR *length)
{
    int result, needed;
    struct linger linger_value;
    if (!usos_require_startup()) return SOCKET_ERROR;
    if (s >= USOS_MAX_SOCKETS || usos_sock_kind((int)s) < 0) { usos_last_error = WSAENOTSOCK; return SOCKET_ERROR; }
    if (value == NULL || length == NULL) { usos_last_error = WSAEFAULT; return SOCKET_ERROR; }
    needed = sizeof(int); result = 0;
    if (level == IPPROTO_TCP && option == TCP_NODELAY) result = usos_socket_options[s].nodelay;
    else if (level != SOL_SOCKET) { usos_last_error = WSAENOPROTOOPT; return SOCKET_ERROR; }
    else switch (option) {
    case SO_TYPE: result = usos_sock_kind((int)s); break;
    case SO_ERROR:
        if (*length < (int)sizeof(int)) { *length = sizeof(int); usos_last_error = WSAEFAULT; return SOCKET_ERROR; }
        result = usos_error_number(usos_sock_error((int)s, 1)); break;
    case SO_RCVBUF: case SO_SNDBUF: result = 4096; break;
    case SO_KEEPALIVE: result = usos_socket_options[s].keepalive; break;
    case SO_REUSEADDR: result = usos_socket_options[s].reuseaddr; break;
    case SO_LINGER: needed = sizeof(struct linger); linger_value = usos_socket_options[s].linger_value; break;
    default: usos_last_error = WSAENOPROTOOPT; return SOCKET_ERROR;
    }
    if (*length < needed) { *length = needed; usos_last_error = WSAEFAULT; return SOCKET_ERROR; }
    usos_far_tobuf(value, needed == sizeof(struct linger) && option == SO_LINGER ? (void FAR *)&linger_value : (void FAR *)&result, needed);
    *length = needed; usos_last_error = 0; return 0;
}

static int usos_set_option(SOCKET s, int level, int option, const char FAR *value, int length)
{
    int input;
    struct linger linger_value;
    if (!usos_require_startup()) return SOCKET_ERROR;
    if (s >= USOS_MAX_SOCKETS || usos_sock_kind((int)s) < 0) { usos_last_error = WSAENOTSOCK; return SOCKET_ERROR; }
    if (value == NULL) { usos_last_error = WSAEFAULT; return SOCKET_ERROR; }
    if (level == SOL_SOCKET && option == SO_LINGER) {
        if (length < (int)sizeof(linger_value)) { usos_last_error = WSAEFAULT; return SOCKET_ERROR; }
        usos_far_tobuf(&linger_value, value, sizeof(linger_value));
        /* The engine has a bounded close, not caller-selected linger. */
        if (linger_value.l_onoff) { usos_last_error = WSAEOPNOTSUPP; return SOCKET_ERROR; }
        usos_socket_options[s].linger_value = linger_value;
    } else {
        if (length < (int)sizeof(input)) { usos_last_error = WSAEFAULT; return SOCKET_ERROR; }
        usos_far_tobuf(&input, value, sizeof(input));
        if (level == IPPROTO_TCP && option == TCP_NODELAY) {
            if (!input) { usos_last_error = WSAEOPNOTSUPP; return SOCKET_ERROR; }
            usos_socket_options[s].nodelay = 1;
        }
        else if (level != SOL_SOCKET) { usos_last_error = WSAENOPROTOOPT; return SOCKET_ERROR; }
        else switch (option) {
        case SO_RCVBUF: case SO_SNDBUF:
            if (input <= 0) { usos_last_error = WSAEINVAL; return SOCKET_ERROR; } break;
        case SO_KEEPALIVE:
            if (input) { usos_last_error = WSAENOPROTOOPT; return SOCKET_ERROR; }
            usos_socket_options[s].keepalive = 0; break;
        case SO_REUSEADDR:
            if (input) { usos_last_error = WSAENOPROTOOPT; return SOCKET_ERROR; }
            usos_socket_options[s].reuseaddr = 0; break;
        default: usos_last_error = WSAENOPROTOOPT; return SOCKET_ERROR;
        }
    }
    usos_last_error = 0; return 0;
}

/* Small read-only services database: returned pointers remain valid until the
 * next call in this database, as required by the Win16 interface. */
static struct protoent FAR *usos_protocol(int number)
{
    static struct protoent result;
    static char FAR *aliases[1];
    static char tcp_name[] = "tcp", udp_name[] = "udp", icmp_name[] = "icmp";
    if (number == 6) result.p_name = tcp_name;
    else if (number == 17) result.p_name = udp_name;
    else if (number == 1) result.p_name = icmp_name;
    else { usos_last_error = WSANO_DATA; return NULL; }
    aliases[0] = NULL; result.p_aliases = aliases; result.p_proto = number;
    usos_last_error = 0; return &result;
}

typedef struct { char *name; unsigned int port; char *protocol; } usos_service_entry;
static usos_service_entry usos_services[] = {
    {"http",80,"tcp"}, {"https",443,"tcp"}, {"ftp",21,"tcp"},
    {"ftp-data",20,"tcp"}, {"telnet",23,"tcp"}, {"smtp",25,"tcp"},
    {"pop3",110,"tcp"}, {"nntp",119,"tcp"}, {"irc",6667,"tcp"},
    {"domain",53,"udp"}, {"domain",53,"tcp"}, {"ntp",123,"udp"}
};

static struct servent FAR *usos_service(const char FAR *name, unsigned int port,
                                         const char FAR *protocol)
{
    static struct servent result;
    static char FAR *aliases[1];
    unsigned int i;
    for (i = 0; i < sizeof(usos_services) / sizeof(usos_services[0]); i++) {
        if (protocol != NULL && !usos_text_equal(protocol, usos_services[i].protocol)) continue;
        if (name != NULL ? !usos_text_equal(name, usos_services[i].name) : port != usos_services[i].port) continue;
        result.s_name = usos_services[i].name;
        result.s_port = net_htons(usos_services[i].port);
        result.s_proto = usos_services[i].protocol;
        aliases[0] = NULL; result.s_aliases = aliases;
        usos_last_error = 0; return &result;
    }
    usos_last_error = WSANO_DATA; return NULL;
}

static int usos_reverse_name(usos_u32 ip, char *name, unsigned int room)
{
    usos_u8 packet[512];
    usos_u32 began, sent = 0, from;
    usos_u16 length, port;
    int slot, rc, retries = 0;
    if (ip == usos_sock_local_ip() || ip == 0x7f000001UL) {
        usos_far_copyz(name, ip == 0x7f000001UL ? "localhost" : "usos", room);
        return USOS_NET_OK;
    }
    slot = usos_sock_open(USOS_SOCK_DGRAM);
    if (slot < 0) return slot;
    usos_sock_nonblocking(slot, 1);
    rc = usos_sock_connect(slot, usos_pkt_dns(), 53, NULL);
    if (rc < 0 && rc != USOS_SOCK_EWOULDBLOCK) { usos_sock_close(slot); return rc; }
    began = (usos_u32)GetTickCount();
    rc = USOS_SOCK_ETIMEDOUT;
    while ((usos_u32)((usos_u32)GetTickCount() - began) < 15000UL) {
        usos_sock_tick();
        if (sent == 0 || (usos_u32)((usos_u32)GetTickCount() - sent) >= (1000UL << retries)) {
            length = net_dns_build_ptr_query(packet, sizeof(packet), 0x9d21, ip);
            rc = usos_sock_send(slot, packet, length);
            if (rc >= 0) { if (sent != 0 && retries < 3) retries++; sent = (usos_u32)GetTickCount(); }
            else if (rc != USOS_SOCK_EWOULDBLOCK) break;
        }
        rc = usos_sock_recvfrom(slot, packet, sizeof(packet), &from, &port);
        if (rc >= 12 && from == usos_pkt_dns() && port == 53 && net_get16(packet) == 0x9d21) {
            rc = net_dns_parse_ptr_response(packet, (usos_u16)rc, 0x9d21, name, room);
            usos_sock_close(slot); return rc;
        }
        if (rc < 0 && rc != USOS_SOCK_EWOULDBLOCK) break;
        usos_abi_idle();
        rc = USOS_SOCK_ETIMEDOUT;
    }
    usos_sock_close(slot); return rc;
}
