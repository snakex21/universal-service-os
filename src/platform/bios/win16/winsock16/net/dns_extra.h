/* Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later */
/* Bounded reverse DNS helpers. GPL-3.0-or-later. */
#ifndef USOS_DNS_EXTRA_H
#define USOS_DNS_EXTRA_H
#include "net.h"
/* ip is the engine's host-order dotted-quad integer, e.g.0xc0000244. */
usos_u16 net_dns_build_ptr_query(usos_u8 *buffer,usos_u16 room,
                                usos_u16 id,usos_u32 ip);
int net_dns_parse_ptr_response(const usos_u8 *message,usos_u16 length,
                               usos_u16 id,char *name,usos_u16 room);
#endif
