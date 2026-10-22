/* NT3-only fallback when no complete named ICMP DLL API exists.
 * Uses the already initialized Winsock1.1 functions and a private socket.
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 */
#include "usoslog_icmp_packet.h"

static void raw_ping_gateway(void)
{
    BYTE request[32], response[512];
    struct sockaddr_in destination, from;
    SOCKET handle;
    DWORD start = GetTickCount(), elapsed, i, received = 0;
    WORD checksum, id = (WORD)(start ^ gateway ^ 0x5355);
    int n, size, matched = 0;
    char address[20];
    ipstr(address, gateway);
    handle = socket(AF_INET, SOCK_RAW, IPPROTO_ICMP);
    if (handle == INVALID_SOCKET) {
        o("[NET] ICMP gateway %s: UNAVAILABLE (raw Winsock error %d)", (LPSTR)address, WSAGetLastError());
        return;
    }
    mset(&destination, 0, sizeof(destination));
    destination.sin_family = AF_INET;
    destination.sin_addr.s_addr = gateway;
    mset(request, 0, sizeof(request));
    request[0] = 8;
    request[4] = (BYTE)(id >> 8); request[5] = (BYTE)id;
    request[7] = 1;
    for (i = 8; i < sizeof(request); i++) request[i] = (BYTE)((start >> ((i & 3) * 8)) ^ (0x55 + i));
    checksum = echo_checksum(request, sizeof(request));
    request[2] = (BYTE)(checksum >> 8); request[3] = (BYTE)checksum;
    if (sendto(handle, (char *)request, sizeof(request), 0,
               (struct sockaddr *)&destination, sizeof(destination)) != sizeof(request)) {
        o("[NET] ICMP gateway %s: FAIL raw send error %d", (LPSTR)address, WSAGetLastError());
        closesocket(handle); return;
    }
    for (;;) {
        elapsed = GetTickCount() - start;
        if (elapsed >= 5000 || received == 32 || sock_wait(handle, 0, 5000 - elapsed) <= 0) break;
        size = sizeof(from);
        mset(&from, 0, sizeof(from));
        n = recvfrom(handle, (char *)response, sizeof(response), 0, (struct sockaddr *)&from, &size);
        if (n <= 0) break;
        received++;
        if (size >= (int)sizeof(from) && from.sin_family == AF_INET &&
            echo_matches(response, (DWORD)n, from.sin_addr.s_addr, gateway, request, sizeof(request))) {
            matched = 1; break;
        }
    }
    o("[NET] ICMP gateway %s: %s raw Winsock echo_match=%u rtt=%lu ms packets=%lu",
      (LPSTR)address, (LPSTR)(matched ? "PASS" : "FAIL"), matched, GetTickCount() - start, received);
    closesocket(handle);
}
