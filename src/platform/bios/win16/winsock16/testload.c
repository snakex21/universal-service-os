/* testload.c - minimal Win16 application that proves WINSOCK.DLL loads.
 *
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Started by `WIN /S C:\TEST\TESTLOAD.EXE` on a Windows 3.1 standard-mode
 * session.  It loads WINSOCK.DLL by name (LoadLibrary, so the loader and the
 * NE export table are exercised), resolves WSAStartup/WSACleanup with
 * GetProcAddress, calls WSAStartup(1.1), reports the negotiated version and the
 * provider description to C:\WSTEST.LOG with the 16-bit C runtime
 * (_lcreat/_lwrite/_lclose), posts WM_QUIT and returns, so Windows ends the
 * session by itself: no keyboard, mouse or window is needed.
 *
 * `TESTLOAD.EXE fail` is the negative control: it asks for Winsock 2.2, so the
 * provider must refuse with WSAVERNOTSUPPORTED and the log must read
 * `USOS WINSOCK FAIL err=10092`.
 *
 * Build: tools/build_win16_winsock.py (wcc -bt=windows -ml -zW + wlink)
 */
#include <windows.h>
#include <winsock.h>
#include <io.h>
#include <fcntl.h>

#define USOS_LOG_PATH "C:\\WSTEST.LOG"

static char usos_log[256];
static int usos_log_len;

static void usos_append(const char *text)
{
    while (*text != '\0' && usos_log_len < (int)sizeof(usos_log) - 1)
        usos_log[usos_log_len++] = *text++;
    usos_log[usos_log_len] = '\0';
}

static void usos_append_dec(int value)
{
    char digits[8];
    int count = 0;
    if (value < 0) {
        usos_append("-");
        value = -value;
    }
    do {
        digits[count++] = (char)('0' + value % 10);
        value /= 10;
    } while (value != 0 && count < (int)sizeof(digits));
    while (count > 0) {
        char one[2];
        one[0] = digits[--count];
        one[1] = '\0';
        usos_append(one);
    }
}

static void usos_append_version(WORD version)
{
    usos_append_dec(HIBYTE(version));
    usos_append(".");
    usos_append_dec(LOBYTE(version));
}

static void usos_write_log(void)
{
    int handle;

    usos_append("\r\n");
    handle = _lcreat(USOS_LOG_PATH, 0);
    if (handle != -1) {
        _lwrite(handle, usos_log, (unsigned int)usos_log_len);
        _lclose(handle);
    }
}

/* No window is created: WM_QUIT makes GetMessage end the loop at once and
 * WIN.COM/Windows closes this session without user interaction. */
static void usos_quit(void)
{
    MSG msg;

    PostQuitMessage(0);
    while (GetMessage(&msg, NULL, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
}

typedef int (FAR PASCAL *LPFN_WSASTARTUP)(WORD, LPWSADATA);
typedef int (FAR PASCAL *LPFN_WSACLEANUP)(void);

int PASCAL WinMain(HANDLE hInstance, HANDLE hPrevInstance, LPSTR lpCmdLine, int nCmdShow)
{
    WSADATA data;
    WORD requested = 0x0101;
    LPFN_WSASTARTUP startup;
    LPFN_WSACLEANUP cleanup;
    HINSTANCE dll;
    int rc;

    (void)hInstance;
    (void)hPrevInstance;
    (void)nCmdShow;

    /* Negative control: "TESTLOAD.EXE fail" requests Winsock 2.2. */
    if (lpCmdLine != NULL && (lpCmdLine[0] == 'f' || lpCmdLine[0] == 'F'))
        requested = 0x0202;

    dll = LoadLibrary("WINSOCK.DLL");
    if ((UINT)dll < 32) {
        usos_append("USOS WINSOCK FAIL err=load:");
        usos_append_dec((int)(UINT)dll);
        usos_write_log();
        usos_quit();
        return 1;
    }
    startup = (LPFN_WSASTARTUP)GetProcAddress(dll, "WSAStartup");
    cleanup = (LPFN_WSACLEANUP)GetProcAddress(dll, "WSACleanup");
    if (startup == NULL || cleanup == NULL) {
        usos_append("USOS WINSOCK FAIL err=missing-export");
        usos_write_log();
        usos_quit();
        return 1;
    }

    rc = startup(requested, &data);
    if (rc != 0) {
        usos_append("USOS WINSOCK FAIL err=");
        usos_append_dec(rc);
    } else {
        usos_append("USOS WINSOCK OK version=");
        usos_append_version(data.wVersion);
        usos_append(" high=");
        usos_append_version(data.wHighVersion);
        usos_append(" desc=");
        usos_append((const char *)data.szDescription);
        cleanup();
    }
    usos_write_log();
    usos_quit();
    return 0;
}
