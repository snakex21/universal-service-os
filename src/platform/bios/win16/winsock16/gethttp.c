/* Blocking Win16 HTTP client: use the public Winsock 1.1 ordinal ABI.
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include <windows.h>
#include <winsock.h>
#include <string.h>

typedef int (FAR PASCAL *FN_START)(WORD, LPWSADATA);
typedef int (FAR PASCAL *FN_CLEAN)(void);
typedef struct hostent FAR *(FAR PASCAL *FN_HOST)(const char FAR *);
typedef SOCKET (FAR PASCAL *FN_SOCKET)(int, int, int);
typedef int (FAR PASCAL *FN_CONNECT)(SOCKET, const struct sockaddr FAR *, int);
typedef int (FAR PASCAL *FN_IO)(SOCKET, char FAR *, int, int);
typedef int (FAR PASCAL *FN_SEND)(SOCKET, const char FAR *, int, int);
typedef int (FAR PASCAL *FN_CLOSE)(SOCKET);
typedef int (FAR PASCAL *FN_ERROR)(void);

static HFILE journal;
static char buffer[1024];
static char status[80];
static const char request[] = "GET / HTTP/1.0\r\nHost: 68k.news\r\nConnection: close\r\n\r\n";

static void logtext(const char *s)
{
    _lwrite(journal, s, (UINT)strlen(s));
}
static void number(long value)
{
    char s[16];
    int n = 0;
    if (value < 0) { logtext("-"); value = -value; }
    do { s[n++] = (char)('0' + value % 10); value /= 10; } while (value);
    while (n) _lwrite(journal, &s[--n], 1);
}

static void log_windows_mode(void)
{
    DWORD flags = GetWinFlags();
    static const char hex[] = "0123456789ABCDEF";
    int shift;
    logtext("GETHTTP Win16; GetWinFlags=0x");
    for (shift = 28; shift >= 0; shift -= 4) {
        char digit = hex[(unsigned int)((flags >> shift) & 15)];
        _lwrite(journal, &digit, 1);
    }
    logtext(" mode=");
    if (flags & WF_ENHANCED) logtext("386_ENHANCED");
    else if (flags & WF_STANDARD) logtext("STANDARD");
    else if (flags & WF_PMODE) logtext("PROTECTED_OTHER");
    else logtext("REAL");
    logtext("; http://68k.news/\r\n");
}

int PASCAL WinMain(HANDLE instance, HANDLE previous, LPSTR cmdline, int show)
{
    HINSTANCE dll;
    FN_START start;
    FN_CLEAN clean;
    FN_HOST host;
    FN_SOCKET opensocket;
    FN_CONNECT connectsocket;
    FN_IO readsocket;
    FN_SEND writesocket;
    FN_CLOSE closesocketfn;
    FN_ERROR error;
    WSADATA data;
    struct hostent FAR *resolved;
    struct sockaddr_in address;
    SOCKET sock = INVALID_SOCKET;
    HFILE response = HFILE_ERROR;
    int rc, count, sent = 0, i, line = 0;
    long total = 0;
    (void)instance; (void)previous; (void)cmdline; (void)show;

    journal = _lcreat("C:\\GETHTTP.LOG", 0);
    if (journal == HFILE_ERROR) return 1;
    log_windows_mode();
    dll = LoadLibrary("WINSOCK.DLL");
    if ((UINT)dll < 32) { logtext("FAIL load="); number((UINT)dll); goto end; }
    start = (FN_START)GetProcAddress(dll, MAKEINTRESOURCE(115));
    clean = (FN_CLEAN)GetProcAddress(dll, MAKEINTRESOURCE(116));
    host = (FN_HOST)GetProcAddress(dll, MAKEINTRESOURCE(52));
    opensocket = (FN_SOCKET)GetProcAddress(dll, MAKEINTRESOURCE(23));
    connectsocket = (FN_CONNECT)GetProcAddress(dll, MAKEINTRESOURCE(4));
    readsocket = (FN_IO)GetProcAddress(dll, MAKEINTRESOURCE(16));
    writesocket = (FN_SEND)GetProcAddress(dll, MAKEINTRESOURCE(19));
    closesocketfn = (FN_CLOSE)GetProcAddress(dll, MAKEINTRESOURCE(3));
    error = (FN_ERROR)GetProcAddress(dll, MAKEINTRESOURCE(111));
    if (!start || !clean || !host || !opensocket || !connectsocket ||
        !readsocket || !writesocket || !closesocketfn || !error) {
        logtext("FAIL missing ordinal"); goto unload;
    }
    rc = start(0x0101, &data);
    logtext("WSAStartup="); number(rc); logtext("\r\n");
    if (rc) goto unload;
    logtext("config="); logtext(data.szSystemStatus); logtext("\r\n");
    resolved = host("68k.news");
    if (!resolved || resolved->h_addrtype != AF_INET || resolved->h_length != 4) {
        logtext("FAIL DNS error="); number(error()); goto cleanup;
    }
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = 0x5000; /* htons(80), x86 Win16 */
    for (i = 0; i < 4; ++i)
        ((char *)&address.sin_addr)[i] = resolved->h_addr_list[0][i];
    logtext("DNS OK\r\n");
    sock = opensocket(AF_INET, SOCK_STREAM, 0);
    if (sock == INVALID_SOCKET) { logtext("FAIL socket"); goto cleanup; }
    rc = connectsocket(sock, (const struct sockaddr FAR *)&address, sizeof(address));
    if (rc) { logtext("FAIL connect error="); number(error()); goto close; }
    logtext("connect OK\r\n");
    while (sent < sizeof(request)-1) {
        rc = writesocket(sock, request + sent, sizeof(request)-1-sent, 0);
        if (rc <= 0) { logtext("FAIL send error="); number(error()); goto close; }
        sent += rc;
    }
    response = _lcreat("C:\\GETHTTP.RSP", 0);
    if (response == HFILE_ERROR) { logtext("FAIL create response"); goto close; }
    while ((count = readsocket(sock, buffer, sizeof(buffer), 0)) > 0) {
        if (_lwrite(response, buffer, count) != count) { logtext("FAIL disk write"); goto close; }
        for (i = 0; i < count && line < sizeof(status)-1; ++i) {
            if (buffer[i] == '\r' || buffer[i] == '\n') break;
            status[line++] = buffer[i];
        }
        total += count;
        if (line && (strchr(status, ' ') != NULL)) {
            /* Preserve only the first status line; later chunks are body. */
            if (i < count) line = sizeof(status)-1;
        }
    }
    logtext("status="); logtext(status); logtext(" bytes="); number(total);
    if (count == 0 && total > 12 &&
        (!strncmp(status, "HTTP/1.0 200", 12) || !strncmp(status, "HTTP/1.1 200", 12)))
        logtext("\r\nPASS HTTP 200; response=C:\\GETHTTP.RSP\r\n");
    else { logtext("\r\nFAIL recv/status error="); number(error()); }
close:
    if (response != HFILE_ERROR) _lclose(response);
    if (sock != INVALID_SOCKET) closesocketfn(sock);
cleanup:
    clean();
unload:
    FreeLibrary(dll);
end:
    logtext("\r\n"); _lclose(journal);
    ExitWindows(0, 0);
    return 0;
}
