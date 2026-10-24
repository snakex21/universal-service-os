/* Bounded mTCP address configuration parser; no file or OS dependencies.
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#ifndef USOS_IP_CONFIG_H
#define USOS_IP_CONFIG_H
#include "net.h"
typedef struct {
    usos_u32 ip, mask, gateway, dns;
    unsigned int seen;
    int invalid;
} net_config;
void net_config_begin(net_config *config);
int net_config_line(net_config *config, const char *line);
int net_config_valid(const net_config *config);
#endif
