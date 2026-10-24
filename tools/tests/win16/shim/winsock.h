#ifndef USOS_TEST_WINSOCK_H
#define USOS_TEST_WINSOCK_H
#include "windows.h"
typedef unsigned int u_long,SOCKET;
typedef unsigned short u_short;
#define INVALID_SOCKET ((SOCKET)~0U)
#define SOCKET_ERROR (-1)
#define AF_INET 2
#define SOCK_STREAM 1
#define SOCK_DGRAM 2
#define IPPROTO_ICMP 1
#define IPPROTO_TCP 6
#define IPPROTO_UDP 17
#define INADDR_NONE 0xffffffffU
#define SOL_SOCKET 0xffff
#define SO_REUSEADDR 4
#define SO_KEEPALIVE 8
#define SO_LINGER 0x0080
#define SO_SNDBUF 0x1001
#define SO_RCVBUF 0x1002
#define SO_ERROR 0x1007
#define SO_TYPE 0x1008
#define TCP_NODELAY 1
#define MSG_OOB 1
#define MSG_PEEK 2
#define MSG_DONTROUTE 4
#define FIONBIO 0x8004667eUL
#define FIONREAD 0x4004667fUL
#define FD_READ 1
#define FD_WRITE 2
#define FD_OOB 4
#define FD_ACCEPT 8
#define FD_CONNECT 16
#define FD_CLOSE 32
#define FD_SETSIZE 64
#define MAXGETHOSTSTRUCT 1024
#define WSAEINTR 10004
#define WSAEBADF 10009
#define WSAEACCES 10013
#define WSAEFAULT 10014
#define WSAEINVAL 10022
#define WSAEMFILE 10024
#define WSAEWOULDBLOCK 10035
#define WSAEINPROGRESS 10036
#define WSAEALREADY 10037
#define WSAENOTSOCK 10038
#define WSAEDESTADDRREQ 10039
#define WSAEMSGSIZE 10040
#define WSAEPROTOTYPE 10041
#define WSAENOPROTOOPT 10042
#define WSAEPROTONOSUPPORT 10043
#define WSAESOCKTNOSUPPORT 10044
#define WSAEOPNOTSUPP 10045
#define WSAEPFNOSUPPORT 10046
#define WSAEAFNOSUPPORT 10047
#define WSAEADDRINUSE 10048
#define WSAEADDRNOTAVAIL 10049
#define WSAENETDOWN 10050
#define WSAENETUNREACH 10051
#define WSAENETRESET 10052
#define WSAECONNABORTED 10053
#define WSAECONNRESET 10054
#define WSAENOBUFS 10055
#define WSAEISCONN 10056
#define WSAENOTCONN 10057
#define WSAESHUTDOWN 10058
#define WSAETIMEDOUT 10060
#define WSAECONNREFUSED 10061
#define WSAEHOSTUNREACH 10065
#define WSASYSNOTREADY 10091
#define WSAVERNOTSUPPORTED 10092
#define WSANOTINITIALISED 10093
#define WSAHOST_NOT_FOUND 11001
#define WSATRY_AGAIN 11002
#define WSANO_RECOVERY 11003
#define WSANO_DATA 11004
struct in_addr { u_long s_addr; };
struct sockaddr { unsigned short sa_family;char sa_data[14]; };
struct sockaddr_in { short sin_family;u_short sin_port;struct in_addr sin_addr;char sin_zero[8]; };
struct timeval { long tv_sec,tv_usec; };
struct linger { u_short l_onoff,l_linger; };
struct hostent { char *h_name;char **h_aliases;short h_addrtype,h_length;char **h_addr_list; };
struct protoent { char *p_name;char **p_aliases;short p_proto; };
struct servent { char *s_name;char **s_aliases;short s_port;char *s_proto; };
typedef struct { u_short fd_count;SOCKET fd_array[FD_SETSIZE]; } fd_set;
typedef struct { WORD wVersion,wHighVersion;char szDescription[257],szSystemStatus[129];
 unsigned short iMaxSockets,iMaxUdpDg;char *lpVendorInfo; } WSADATA,*LPWSADATA;
#define FD_ZERO(set) ((set)->fd_count=0)
#define FD_SET(s,set) ((set)->fd_array[(set)->fd_count++]=(s))
#define WSAGETSELECTEVENT(v) LOWORD(v)
#define WSAGETSELECTERROR(v) HIWORD(v)
#define WSAGETASYNCBUFLEN(v) LOWORD(v)
#define WSAGETASYNCERROR(v) HIWORD(v)
#endif
