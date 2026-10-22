/* Silent network evidence for USOSLOG: NT4 registry fallback and ICMP.
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 * Included after the logger's formatting, address and DNS helpers.
 * Registry is read only. No command interpreter or external ping process.
 */
typedef struct {
    BYTE Ttl, Tos, Flags, OptionsSize;
    BYTE *OptionsData;
} USOS_IP_OPTIONS;

typedef struct {
    DWORD Address, Status, RoundTripTime;
    WORD DataSize, Reserved;
    void *Data;
    USOS_IP_OPTIONS Options;
} USOS_ICMP_REPLY;
typedef char USOS_ICMP_REPLY_X86_SIZE[(sizeof(void *) != 4 || sizeof(USOS_ICMP_REPLY) == 28) ? 1 : -1];

typedef HANDLE (WINAPI *USOS_ICMP_CREATE)(void);
typedef BOOL (WINAPI *USOS_ICMP_CLOSE)(HANDLE);
typedef DWORD (WINAPI *USOS_ICMP_SEND)(HANDLE, DWORD, void *, WORD,
                                    USOS_IP_OPTIONS *, void *, DWORD, DWORD);

static int tcpip_strings(HKEY key, const char *name, char *text, DWORD cap)
{
    DWORD type, length = cap - 2;
    LONG result;
    mset(text, 0, cap);
    result = RegQueryValueExA(key, name, 0, &type, (BYTE *)text, &length);
    if (result != ERROR_SUCCESS || length > cap - 2 ||
        (type != REG_SZ && type != REG_MULTI_SZ)) {
        mset(text, 0, cap);
        return 0;
    }
    return 1;
}

/* REG_SZ space/comma lists and REG_MULTI_SZ, bounded by the supplied size. */
static DWORD tcpip_addresses(const char *text, DWORD cap, int dns)
{
    DWORD at = 0, first = 0;
    while (at < cap) {
        char item[16];
        DWORD n = 0, address;
        while (at < cap && (!text[at] || text[at] == ' ' || text[at] == ',' || text[at] == ';')) at++;
        if (at == cap) break;
        while (at < cap && text[at] && text[at] != ' ' && text[at] != ',' && text[at] != ';') {
            if (n < sizeof(item) - 1) item[n] = text[at];
            n++; at++;
        }
        if (n >= sizeof(item)) continue;
        item[n] = 0;
        address = inet_addr(item);
        if (!address || address == INADDR_NONE || (address & 255) == 127 || (address & 255) >= 224) continue;
        if (!first) first = address;
        if (dns) add_dns(address);
    }
    return first;
}

static void nt_tcpip_config(void)
{
    HKEY linkage, adapter;
    char bindings[4096], path[320], value[1024];
    DWORD at = 0, count = 0;
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, "System\\CurrentControlSet\\Services\\Tcpip\\Linkage", 0,
                      KEY_READ, &linkage) != ERROR_SUCCESS) {
        o("[NET] NT adapter registry: Tcpip\\Linkage unavailable");
        return;
    }
    tcpip_strings(linkage, "Bind", bindings, sizeof(bindings));
    RegCloseKey(linkage);
    while (at < sizeof(bindings) && bindings[at] && count++ < 32) {
        const char *binding = bindings + at, *name;
        DWORD length = 0, i, enabled = 0, type, size;
        while (at < sizeof(bindings) && bindings[at]) { at++; length++; }
        at++;
        if (length <= 8 || length > 135) continue;
        if (binding[0] != '\\' || binding[7] != '\\') continue;
        name = binding + 8;
        for (i = 0; name[i]; i++)
            if (!((name[i] >= 'a' && name[i] <= 'z') || (name[i] >= 'A' && name[i] <= 'Z') ||
                  (name[i] >= '0' && name[i] <= '9') || name[i] == '_' || name[i] == '-' ||
                  name[i] == '{' || name[i] == '}')) break;
        if (name[i]) continue;
        wsprintfA(path, "System\\CurrentControlSet\\Services\\%s\\Parameters\\Tcpip", (LPSTR)name);
        if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, path, 0, KEY_READ, &adapter) != ERROR_SUCCESS) continue;
        size = sizeof(enabled);
        if (RegQueryValueExA(adapter, "EnableDHCP", 0, &type, (BYTE *)&enabled, &size) != ERROR_SUCCESS ||
            type != REG_DWORD || size != sizeof(enabled)) enabled = 0;
        o("[NET] NT adapter registry %s: EnableDHCP=%lu (configuration/lease record, not live proof)",
          (LPSTR)name, enabled);
        reg_dump(HKEY_LOCAL_MACHINE, "HKLM", path, 32);
        if (tcpip_strings(adapter, enabled ? "DhcpDefaultGateway" : "DefaultGateway", value, sizeof(value)) && !gateway)
            gateway = tcpip_addresses(value, sizeof(value), 0);
        if (!gateway && tcpip_strings(adapter, "DefaultGateway", value, sizeof(value)))
            gateway = tcpip_addresses(value, sizeof(value), 0);
        /* A configured DNS list takes precedence over the DHCP value. */
        if (!tcpip_strings(adapter, "NameServer", value, sizeof(value)) ||
            !tcpip_addresses(value, sizeof(value), 1)) {
            if (tcpip_strings(adapter, "DhcpNameServer", value, sizeof(value)))
                tcpip_addresses(value, sizeof(value), 1);
        }
        RegCloseKey(adapter);
    }
}

static void ping_gateway(void)
{
    static int tried;
    static USOS_ICMP_CREATE create;
    static USOS_ICMP_CLOSE close_icmp;
    static USOS_ICMP_SEND echo;
    HANDLE handle;
    DWORD reply_words[256], received, i;
    USOS_ICMP_REPLY *reply = (USOS_ICMP_REPLY *)reply_words;
    char address[20], request[] = "USOS gateway echo";
    int matched;
    if (!gateway) { o("[NET] ICMP gateway: SKIP, no configured gateway; no guessed address"); return; }
    ipstr(address, gateway);
    if (!tried) {
        const char *modules[2] = { "IPHLPAPI.DLL", "ICMP.DLL" };
        tried = 1;
        for (i = 0; i < 2; i++) {
            HMODULE module = LoadLibraryA(modules[i]);
            if (!module) continue;
            create = (USOS_ICMP_CREATE)GetProcAddress(module, "IcmpCreateFile");
            close_icmp = (USOS_ICMP_CLOSE)GetProcAddress(module, "IcmpCloseHandle");
            echo = (USOS_ICMP_SEND)GetProcAddress(module, "IcmpSendEcho");
            if (create && close_icmp && echo) break;
            create = 0; close_icmp = 0; echo = 0;
        }
    }
    if (!echo) {
#ifdef USOS_NT3_RAW_ICMP
        raw_ping_gateway();
#else
        o("[NET] ICMP gateway %s: UNAVAILABLE (no complete ICMP API)", (LPSTR)address);
#endif
        return;
    }
    handle = create();
    if (handle == INVALID_HANDLE_VALUE || !handle) {
        o("[NET] ICMP gateway %s: create failed error %lu", (LPSTR)address, GetLastError()); return;
    }
    mset(reply_words, 0, sizeof(reply_words));
    received = echo(handle, gateway, request, sizeof(request), 0, reply_words, sizeof(reply_words), 1500);
    if (!received) {
        o("[NET] ICMP gateway %s: FAIL, no echo reply, error %lu", (LPSTR)address, GetLastError());
    } else {
        matched = reply->Status == 0 && reply->Address == gateway && reply->DataSize == sizeof(request);
        if ((BYTE *)reply->Data < (BYTE *)(reply + 1) ||
            (BYTE *)reply->Data > (BYTE *)reply_words + sizeof(reply_words) - sizeof(request)) matched = 0;
        if (matched) for (i = 0; i < sizeof(request); i++)
            if (((char *)reply->Data)[i] != request[i]) matched = 0;
        o("[NET] ICMP gateway %s: %s status=%lu replies=%lu rtt=%lu ms echo_match=%u", (LPSTR)address,
          (LPSTR)(matched ? "PASS" : "FAIL"), reply->Status, received, reply->RoundTripTime, matched);
    }
    close_icmp(handle);
}
