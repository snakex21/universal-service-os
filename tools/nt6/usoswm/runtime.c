/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "common.h"
void *memcpy(void *dst,const void *src,SIZE_T n){BYTE *d=dst;const BYTE *s=src;while(n--)*d++=*s++;return dst;}
void *memset(void *dst,int value,SIZE_T n){BYTE *d=dst;while(n--)*d++=(BYTE)value;return dst;}
