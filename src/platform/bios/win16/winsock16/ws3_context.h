/* Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Private task state. Public Winsock1.1 contracts, no external provider code.
 * Contexts live in separately allocated FAR blocks, not the DLL's DGROUP.
 */
#define USOS_APP_CONTEXTS 8
#define USOS_ASYNC_JOBS 4
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
typedef struct {
    HTASK task;
    int startups, error, blocking, cancelled, in_pump;
    FARPROC hook;
    HWND poll_window;
    usos_async_job jobs[USOS_ASYNC_JOBS];
    char ntoa[16], reverse_result[MAXGETHOSTSTRUCT];
    struct hostent host;
    char host_name[USOS_NET_NAME_MAX];
    usos_u32 host_addresses[USOS_NET_MAX_ADDRS];
    char FAR *host_list[USOS_NET_MAX_ADDRS+1], FAR *host_aliases[1];
    struct protoent protocol;
    char FAR *protocol_aliases[1];
    struct servent service;
    char FAR *service_aliases[1];
} usos_app_context;

static usos_app_context FAR *usos_apps[USOS_APP_CONTEXTS];
static HGLOBAL usos_app_memory[USOS_APP_CONTEXTS];
static usos_app_context usos_overflow_context;
static usos_selector usos_selectors[USOS_MAX_SOCKETS];
static usos_options usos_socket_options[USOS_MAX_SOCKETS];
static HTASK usos_socket_owners[USOS_MAX_SOCKETS];
static int usos_global_startups;
static HINSTANCE usos_instance;
static FARPROC usos_poll_proc;
static int usos_class_registered;
static unsigned int usos_next_async;
static void FAR *usos_far_zero(void FAR *, unsigned int);

static usos_app_context FAR *usos_app(void)
{
    HTASK task = GetCurrentTask();
    int i, free_slot = -1;
    for (i = 0; i < USOS_APP_CONTEXTS; i++) {
        if (usos_apps[i] != NULL && usos_apps[i]->task == task) return usos_apps[i];
        if (free_slot < 0 && (usos_apps[i] == NULL ||
            (usos_apps[i]->startups == 0 && !usos_apps[i]->blocking))) free_slot = i;
    }
    if (free_slot >= 0) {
        i = free_slot;
        if (usos_apps[i] == NULL) {
            usos_app_memory[i] = GlobalAlloc(GMEM_FIXED | GMEM_ZEROINIT | GMEM_DDESHARE, sizeof(usos_app_context));
            if (usos_app_memory[i] != NULL) usos_apps[i] = (usos_app_context FAR *)GlobalLock(usos_app_memory[i]);
        }
        if (usos_apps[i] != NULL) {
            usos_far_zero(usos_apps[i], sizeof(usos_app_context));
            usos_apps[i]->task = task;
            return usos_apps[i];
        }
    }
    usos_overflow_context.error = WSAENOBUFS;
    return &usos_overflow_context;
}
#define usos_startup_count (usos_app()->startups)
#define usos_last_error (usos_app()->error)
#define usos_jobs (usos_app()->jobs)
#define usos_poll_window (usos_app()->poll_window)
#define usos_in_async_pump (usos_app()->in_pump)

static int usos_entry(void)
{
    usos_app_context FAR *app = usos_app();
    if (app == &usos_overflow_context) return 0;
    if (app->blocking) { app->error = WSAEINPROGRESS; return 0; }
    return 1;
}
static int usos_require_startup(void)
{
    if (!usos_entry()) return 0;
    if (usos_startup_count) return 1;
    usos_last_error = WSANOTINITIALISED;
    return 0;
}
static int usos_owned_socket(SOCKET s)
{
    if (!usos_require_startup()) return 0;
    if (s >= USOS_MAX_SOCKETS || usos_socket_owners[s] != GetCurrentTask()) {
        usos_last_error = WSAENOTSOCK; return 0;
    }
    return 1;
}
static int usos_block_done(int result)
{
    usos_app_context FAR *app = usos_app();
    app->blocking = app->cancelled = 0;
    return result;
}
