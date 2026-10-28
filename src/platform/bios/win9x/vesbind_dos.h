/* USOS GPL-3.0-or-later. Minimal DOS I/O and strings used by vesbind.c.
 * Own entry point and routines; no OpenWatcom runtime linked.
 */
#include <stdarg.h>
#define NULL ((void *)0)
typedef unsigned size_t;
typedef struct { unsigned handle, pos, used, error, open; char data[256]; } FILE;
/* Two at once: PMDROP / MAXRES read one file while writing another. */
static FILE own_files[2];
unsigned dos_open(const char *path);
#pragma aux dos_open = "mov ax,3d00h" "int 21h" "jnc ok" "mov ax,0ffffh" "ok:" parm [dx] value [ax] modify [ax];
unsigned dos_open_rw(const char *path);
#pragma aux dos_open_rw = "mov ax,3d02h" "int 21h" "jnc ok" "mov ax,0ffffh" "ok:" parm [dx] value [ax] modify [ax];
/* 0 = moved, nonzero = DOS error (carry). */
unsigned dos_seek(unsigned handle,unsigned high,unsigned low);
#pragma aux dos_seek = "mov ax,4200h" "int 21h" "sbb ax,ax" parm [bx] [cx] [dx] value [ax] modify [ax dx];
unsigned dos_create(const char *path);
#pragma aux dos_create = "xor cx,cx" "mov ah,3ch" "int 21h" "jnc ok" "mov ax,0ffffh" "ok:" parm [dx] value [ax] modify [ax cx];
unsigned dos_read(unsigned handle,char *data,unsigned count);
#pragma aux dos_read = "mov ah,3fh" "int 21h" "jnc ok" "mov ax,0ffffh" "ok:" parm [bx] [dx] [cx] value [ax] modify [ax];
unsigned dos_write(unsigned handle,const char *data,unsigned count);
#pragma aux dos_write = "mov ah,40h" "int 21h" "jnc ok" "mov ax,0ffffh" "ok:" parm [bx] [dx] [cx] value [ax] modify [ax];
unsigned dos_close(unsigned handle);
#pragma aux dos_close = "mov ah,3eh" "int 21h" "jc bad" "xor ax,ax" "jmp ok" "bad:" "mov ax,1" "ok:" parm [bx] value [ax] modify [ax];
unsigned dos_psp(void);
#pragma aux dos_psp = "mov ah,62h" "int 21h" value [bx] modify [ax];
size_t strlen(const char *s) { const char *p=s;while(*p)p++;return (size_t)(p-s); }
void *memcpy(void *to,const void *from,size_t n) { char *d=to;const char*s=from;while(n--)*d++=*s++;return to; }
void *memset(void *to,int v,size_t n) { char*d=to;while(n--)*d++=(char)v;return to; }
char *strcpy(char *to,const char *from) { char*d=to;do{*d++=*from;}while(*from++);return to; }
int strcmp(const char*a,const char*b) { while(*a&&*a==*b){a++;b++;}return (unsigned char)*a-(unsigned char)*b; }
char *strchr(const char*s,int c) { while(*s&&(unsigned char)*s!=(unsigned char)c)s++;return *s==(char)c?(char*)s:NULL; }
char *strstr(const char*s,const char*w) {
    unsigned n=strlen(w);
    for(;*s;s++){unsigned i=0;while(i<n&&s[i]==w[i])i++;if(i==n)return (char*)s;}
    return n?NULL:(char*)s;
}
int tolower(int c) { return c>='A'&&c<='Z'?c+32:c; }
int isdigit(int c) { return c>='0'&&c<='9'; }
int isxdigit(int c) { return isdigit(c)||(tolower(c)>='a'&&tolower(c)<='f'); }
int isalnum(int c) { return isdigit(c)||(tolower(c)>='a'&&tolower(c)<='z'); }
int atoi(const char*s) { unsigned n=0;while(isdigit(*s)){if(n>3276)return 32767;n=n*10+(*s++-'0');}return (int)n; }
static unsigned format(char *out,const char *fmt,va_list ap) {
    unsigned n=0;const char*s;
    while(*fmt) {
        if(fmt[0]=='%'&&fmt[1]=='s') { s=va_arg(ap,const char*);while(*s)out[n++]=*s++;fmt+=2; }
        else out[n++]=*fmt++;
    }
    out[n]=0;return n;
}
int sprintf(char*out,const char*fmt,...) {
    va_list ap;unsigned n;va_start(ap,fmt);n=format(out,fmt,ap);va_end(ap);return (int)n;
}
FILE *fopen(const char*path,const char*mode) {
    FILE *f=own_files[0].open?&own_files[1]:&own_files[0];unsigned h;
    if(f->open)return NULL;
    h=mode[0]=='r'?dos_open(path):dos_create(path);
    if(h==0xffff)return NULL;
    f->handle=h;f->pos=f->used=f->error=0;f->open=1;return f;
}
char *fgets(char*out,unsigned size,FILE*f) {
    unsigned n=0;char c;
    while(n+1<size) {
        if(f->pos==f->used) {
            f->used=dos_read(f->handle,f->data,sizeof(f->data));f->pos=0;
            if(f->used==0xffff){f->error=1;break;}if(!f->used)break;
        }
        c=f->data[f->pos++];out[n++]=c;if(c=='\n')break;
    }
    out[n]=0;return n?out:NULL;
}
int ferror(FILE*f) { return f->error!=0; }
int fclose(FILE*f) { f->open=0;return dos_close(f->handle)?-1:0; }
int fprintf(FILE*f,const char*fmt,...) {
    char data[768];va_list ap;unsigned n;
    va_start(ap,fmt);n=format(data,fmt,ap);va_end(ap);
    if(dos_write(f->handle,data,n)!=n){f->error=1;return -1;}return (int)n;
}
