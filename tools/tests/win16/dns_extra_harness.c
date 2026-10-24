/* Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later */
/* Host-only wire test bridge. GPL-3.0-or-later. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "dns_extra.h"
static usos_u8 message[65535];
int main(int argc,char **argv)
{
    FILE *file;size_t bytes;usos_u16 i,n,count;usos_u32 addresses[USOS_NET_MAX_ADDRS];
    char guarded[258];int rc,room=256;
    if(argc<3) return 2;
    if(!strcmp(argv[1],"query")) {
        n=net_dns_build_ptr_query(message,sizeof(message),0x1234,(usos_u32)strtoul(argv[2],0,16));
        printf("length=%u\nhex=",n);for(i=0;i<n;i++) printf("%02x",message[i]);printf("\n");return !n;
    }
    file=fopen(argv[2],"rb");if(!file) return 2;bytes=fread(message,1,sizeof(message),file);fclose(file);
    if(!strcmp(argv[1],"a")) {
        count=999;rc=net_dns_parse_response(message,(usos_u16)bytes,0x1234,addresses,&count);
        printf("rc=%d\ncount=%u\n",rc,count);return 0;
    }
    if(argc>3) room=atoi(argv[3]);if(room<1 || room>256) return 2;
    memset(guarded,0x5a,sizeof(guarded));guarded[0]='A';guarded[room+1]='Z';
    rc=net_dns_parse_ptr_response(message,(usos_u16)bytes,0x1234,guarded+1,(usos_u16)room);
    printf("rc=%d\nname=%s\nguards=%d\n",rc,guarded+1,guarded[0]=='A' && guarded[room+1]=='Z');return 0;
}
