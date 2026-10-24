/* win16_sock.h - blocking socket engine between the Winsock ABI and the
 * USOSPKT queue transport.
 *
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Deliberately free of <windows.h>: the engine needs a millisecond clock and a
 * way to let Windows breathe while it blocks, and both are injected by the ABI
 * file (winsock16.c) through usos_abi_now()/usos_abi_idle().  That keeps the
 * "no Windows dependency outside win16_pkt.c" rule honest and lets the engine
 * be reasoned about (and later tested) on its own.
 *
 * The ABI layer maps the USOS_SOCK_EXxx codes below onto WSAE* values, so this
 * header does not have to include winsock.h either.
 */

#ifndef USOS_WIN16_SOCK_H
#define USOS_WIN16_SOCK_H

#include "net.h"

/* Socket types (mirror SOCK_STREAM/SOCK_DGRAM without winsock.h) */
#define USOS_SOCK_STREAM 1
#define USOS_SOCK_DGRAM  2

/* Engine results; 0 is success, everything negative is an error.  The
 * USOS_NET_ERR_* range is reused where it fits. */
#define USOS_SOCK_ENOTSOCK    (-30)
#define USOS_SOCK_ENOTCONN    (-31)
#define USOS_SOCK_ETIMEDOUT   (-32)
#define USOS_SOCK_ECONNREFUSED (-33)
#define USOS_SOCK_EMFILE      (-34)
#define USOS_SOCK_ECONNRESET  (-35)
#define USOS_SOCK_EHOSTUNREACH (-36)
#define USOS_SOCK_ENOTREADY   (-37)
#define USOS_SOCK_EISCONN     (-38)
#define USOS_SOCK_EBADF       (-39)

/* Provided by winsock16.c (GetTickCount / PeekMessage pump). */
unsigned long usos_abi_now(void);
void          usos_abi_idle(void);

int  usos_sock_startup(void);    /* pkt init + attach + ARP; USOS_NET_OK or <0 */
void usos_sock_shutdown(void);   /* close every socket, release the driver */
int  usos_sock_ready(void);

int  usos_sock_open(int type);   /* slot >= 0, or USOS_SOCK_EMFILE */
int  usos_sock_close(int slot);
int  usos_sock_connect(int slot, usos_u32 ip, usos_u16 port, const char *name);
int  usos_sock_send(int slot, const usos_u8 *buf, usos_u16 len);
int  usos_sock_recv(int slot, usos_u8 *buf, usos_u16 len);
int  usos_sock_local(int slot, usos_u32 *ip, usos_u16 *port);
int  usos_sock_remote(int slot, usos_u32 *ip, usos_u16 *port);
int  usos_sock_resolve(const char *name, usos_u32 addrs[USOS_NET_MAX_ADDRS],
                       usos_u16 *count);
void usos_sock_tick(void);       /* ARP aging + driver poll, no blocking */
usos_u32 usos_sock_local_ip(void);

#endif /* USOS_WIN16_SOCK_H */
