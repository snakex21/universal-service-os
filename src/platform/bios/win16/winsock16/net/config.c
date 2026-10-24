/* mTCP.CFG syntax is a public, whitespace-separated key/value text format.
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "config.h"

static int same(const char *a, const char *b)
{
    char c;
    do {
        c = *a++;
        if (c >= 'a' && c <= 'z') c = (char)(c - 'a' + 'A');
        if (c != *b++) return 0;
    } while (c);
    return 1;
}
static int space(char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }

void net_config_begin(net_config *c)
{
    c->ip = c->mask = c->gateway = c->dns = 0;
    c->seen = 0; c->invalid = 0;
}

int net_config_line(net_config *c, const char *line)
{
    char key[16], value[16];
    unsigned int n = 0, bit;
    usos_u32 address;
    while (space(*line)) ++line;
    if (!*line || *line == '#' || *line == ';') return 0;
    while (*line && !space(*line)) {
        if (n + 1 >= sizeof(key)) return 0; /* unrelated long key */
        key[n++] = *line++;
    }
    key[n] = 0;
    if (same(key, "IPADDR")) bit = 1;
    else if (same(key, "NETMASK")) bit = 2;
    else if (same(key, "GATEWAY")) bit = 4;
    else if (same(key, "NAMESERVER")) bit = 8;
    else return 0; /* PACKETINT/HOSTNAME/lease metadata belong to mTCP */
    while (space(*line)) ++line;
    n = 0;
    while (*line && !space(*line) && *line != '#' && *line != ';') {
        if (n + 1 >= sizeof(value)) { c->invalid = 1; return -1; }
        value[n++] = *line++;
    }
    value[n] = 0;
    while (space(*line)) ++line;
    if (*line && *line != '#' && *line != ';') { c->invalid = 1; return -1; }
    address = net_inet_addr(value);
    if ((address == 0xFFFFFFFFUL && !(bit == 2 && same(value,"255.255.255.255"))) ||
        (address == 0 && bit != 4) ||
        (bit != 2 && address >= 0xE0000000UL)) {
        c->invalid = 1; return -1;
    }
    if ((c->seen & bit) && bit != 8) { c->invalid = 1; return -1; }
    if (bit == 1) c->ip = address;
    else if (bit == 2) c->mask = address;
    else if (bit == 4) c->gateway = address;
    else if (!(c->seen & 8)) c->dns = address; /* first of multiple DNS servers */
    c->seen |= bit;
    return 1;
}

int net_config_valid(const net_config *c)
{
    usos_u32 hostbits = ~c->mask;
    if (c->invalid || c->seen != 15 || !c->mask || (hostbits & (hostbits + 1)) != 0)
        return 0;
    if (hostbits && (!(c->ip & hostbits) || (c->ip & hostbits) == hostbits)) return 0;
    if (c->gateway && (c->gateway & c->mask) != (c->ip & c->mask)) return 0;
    return 1;
}
