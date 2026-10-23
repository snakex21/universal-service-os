/* USOS, GPL-3.0-or-later. Plan/check a 950 late display binding using only
 * fresh original REGEDIT4 exports. Never reads/writes registry hives.
 * PLAN classes enum idconfig output.reg; CHECK classes enum idconfig config
 * Reject ambiguous displays, custom drivers, malformed/duplicate data.
 */
#ifdef __WATCOMC__
#include "vesbind_dos.h"
#define main vesbind_main
#else
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <ctype.h>
#endif

#define MAXKEY 256
#define MAXLINE 768
#define MAXCLASS 32
#define CLS "HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\Class\\Display\\"
#define ENUMPCI "HKEY_LOCAL_MACHINE\\Enum\\PCI\\"
#define ENUMROOT "HKEY_LOCAL_MACHINE\\Enum\\Root\\*PNP0900\\"
#define IDCONFIG "HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Control\\IDConfigDB"

typedef struct { char id[5], inf[40], drv[40], mini[40], mode[40]; } DisplayClass;
static DisplayClass classes[MAXCLASS];
static unsigned class_count, displays;
static char key[MAXKEY], candidate[MAXKEY], device_class[40], driver[40];
static char chosen[MAXKEY], chosen_driver[40], profile[5], bits[4], resolution[24];
static char actual_bits[4], actual_resolution[24], profile_key[MAXKEY];
static int current_class = -1, default_section, valid_device;

static int ieq(const char *a, const char *b) {
    while (*a && *b) {
        if (tolower((unsigned char)*a++) != tolower((unsigned char)*b++)) return 0;
    }
    return *a == *b;
}
static int prefix(const char *a, const char *b) {
    while (*b) {
        if (!*a || tolower((unsigned char)*a++) != tolower((unsigned char)*b++)) return 0;
    }
    return 1;
}
static int id4(const char *a) {
    unsigned i;
    if (strlen(a) != 4) return 0;
    for (i=0;i<4;i++) if (a[i]<'0' || a[i]>'9') return 0;
    return 1;
}
/* 0 = unrelated field; 1 = parsed; -1 = malformed or duplicate. */
static int field(const char *line, const char *name, char *out, unsigned size) {
    char wanted[80]; const char *s; unsigned n=0;
    sprintf(wanted, "\"%s\"=", name);
    if (!prefix(line, wanted)) return 0;
    if (*out) return -1;
    s=line+strlen(wanted);
    if (*s++!='\"') return -1;
    while (*s && *s!='\"') {
        char ch=*s++;
        if (ch=='\\') { ch=*s++; if (ch!='\\' && ch!='\"') return -1; }
        if ((unsigned char)ch<32 || n+1>=size) return -1;
        out[n++]=ch;
    }
    if (*s++!='\"' || *s) return -1;
    out[n]=0;
    return 1;
}
/* Callback sees every complete line; long lines fail closed. */
static int scan(const char *path, int (*visit)(const char *,int)) {
    FILE *f=fopen(path,"rb"); char line[MAXLINE]; int first=1, ok=1;
    if (!f) return 0;
    key[0]=0;
    while (fgets(line,sizeof(line),f)) {
        unsigned n=(unsigned)strlen(line); int header=0;
        if (n==sizeof(line)-1 && line[n-1]!='\n') { ok=0; break; }
        while (n && (line[n-1]=='\r'||line[n-1]=='\n')) line[--n]=0;
        if (first) { first=0; if (!ieq(line,"REGEDIT4")) { ok=0; break; } continue; }
        if (line[0]=='[') {
            if (n<3 || line[n-1]!=']' || n-2>=sizeof(key)) { ok=0; break; }
            memcpy(key,line+1,n-2);key[n-2]=0;header=1;
        }
        if (!visit(line,header)) { ok=0; break; }
    }
    if (ferror(f) || first) ok=0;
    if (fclose(f)) ok=0;
    return ok;
}
static int find_class(const char *id) {
    unsigned i;
    for(i=0;i<class_count;i++) if (!strcmp(classes[i].id,id)) return (int)i;
    return -1;
}
static int class_line(const char *line,int header) {
    DisplayClass *c;
    if (header) {
        char id[5]; const char *s;
        current_class=-1;default_section=0;
        if (!prefix(key,CLS)) return 1;
        s=key+strlen(CLS);
        if (strlen(s)<4) return 1;
        memcpy(id,s,4);id[4]=0;
        if (!id4(id) || (s[4] && !ieq(s+4,"\\DEFAULT"))) return 1;
        current_class=find_class(id);
        if (current_class<0) {
            if (class_count==MAXCLASS) return 0;
            current_class=(int)class_count++;
            strcpy(classes[current_class].id,id);
        }
        default_section=s[4]!=0;
        return 1;
    }
    if (current_class<0) return 1;
    c=&classes[current_class];
    if (default_section) {
        return field(line,"drv",c->drv,sizeof(c->drv))>=0 &&
            field(line,"minivdd",c->mini,sizeof(c->mini))>=0 &&
            field(line,"Mode",c->mode,sizeof(c->mode))>=0;
    }
    return field(line,"InfPath",c->inf,sizeof(c->inf))>=0;
}
static int flush_device(void) {
    if (valid_device && ieq(device_class,"Display")) {
        if (++displays!=1) return 0;
        strcpy(chosen,candidate);strcpy(chosen_driver,driver);
    }
    return 1;
}
static int device_line(const char *line,int header) {
    if (header) {
        const char *s=0;unsigned i;
        if (!flush_device()) return 0;
        valid_device=0;device_class[0]=0;driver[0]=0;
        if (prefix(key,ENUMPCI)) {
            s=key+strlen(ENUMPCI);
            if (!prefix(s,"VEN_") || strlen(s)<17 || !prefix(s+8,"&DEV_")) return 1;
            for(i=4;i<8;i++) if(!isxdigit((unsigned char)s[i])) return 1;
            for(i=13;i<17;i++) if(!isxdigit((unsigned char)s[i])) return 1;
            s=strchr(s,'\\');if (!s || !s[1] || strchr(s+1,'\\')) return 1;
        } else if (prefix(key,ENUMROOT)) {
            s=key+strlen(ENUMROOT);if (!*s || strchr(s,'\\')) return 1;
        } else return 1;
        for(i=0;key[i];i++) {
            unsigned char ch=(unsigned char)key[i];
            if (!(isalnum(ch) || strchr("_&\\*.-",ch))) return 0;
        }
        strcpy(candidate,key);valid_device=1;return 1;
    }
    if (!valid_device) return 1;
    return field(line,"Class",device_class,sizeof(device_class))>=0 &&
        field(line,"Driver",driver,sizeof(driver))>=0;
}
static int id_line(const char *line,int header) {
    (void)header;
    return !ieq(key,IDCONFIG) || field(line,"CurrentConfig",profile,sizeof(profile))>=0;
}
static int config_line(const char *line,int header) {
    (void)header;
    if (!ieq(key,profile_key)) return 1;
    return field(line,"BitsPerPixel",actual_bits,sizeof(actual_bits))>=0 &&
        field(line,"Resolution",actual_resolution,sizeof(actual_resolution))>=0;
}
static int mode(const char *text) {
    const char *comma=strchr(text,',');const char *second;unsigned n,i;
    if (!comma || (n=(unsigned)(comma-text))>=sizeof(bits)) return 0;
    memcpy(bits,text,n);bits[n]=0;
    if (strcmp(bits,"8") && strcmp(bits,"16") && strcmp(bits,"24") && strcmp(bits,"32")) return 0;
    if (strlen(comma+1)>=sizeof(resolution)) return 0;
    strcpy(resolution,comma+1);second=strchr(resolution,',');
    if (!second || second==resolution || !second[1] || strchr(second+1,',')) return 0;
    for(i=0;resolution[i];i++) if(resolution[i]!=',' && !isdigit((unsigned char)resolution[i])) return 0;
    return atoi(resolution)>=320 && atoi(resolution)<=8192 && atoi(second+1)>=200 && atoi(second+1)<=8192;
}
int main(int argc,char **argv) {
    int vesa,old;FILE *out;int failed;
    memset(classes,0,sizeof(classes));class_count=displays=0;
    key[0]=candidate[0]=device_class[0]=driver[0]=chosen[0]=chosen_driver[0]=0;
    profile[0]=bits[0]=resolution[0]=actual_bits[0]=actual_resolution[0]=profile_key[0]=0;
    current_class=-1;default_section=valid_device=0;
    if (argc!=6 || (!ieq(argv[1],"PLAN") && !ieq(argv[1],"CHECK"))) return 2;
    if (!scan(argv[2],class_line) || !scan(argv[3],device_line) || !flush_device() ||
        displays!=1 || !scan(argv[4],id_line) || !id4(profile) || !strcmp(profile,"0000")) return 2;
    vesa=find_class("0000");
    if (vesa<0 || !ieq(classes[vesa].inf,"USOSVESA.INF") ||
        !ieq(classes[vesa].drv,"vesamini.drv") || !ieq(classes[vesa].mini,"vesamini.vxd") ||
        !mode(classes[vesa].mode)) return 2;
    if (!prefix(chosen_driver,"Display\\") || !id4(chosen_driver+8)) return 2;
    old=find_class(chosen_driver+8);
    if (old<0) return 2;
    if (old!=vesa && (!ieq(classes[old].inf,"MSDISP.INF") ||
        (!ieq(classes[old].drv,"vga.drv") && !ieq(classes[old].drv,"supervga.drv")))) return 2;
    sprintf(profile_key,"HKEY_LOCAL_MACHINE\\Config\\%s\\Display\\Settings",profile);
    if (ieq(argv[1],"CHECK")) {
        if (old!=vesa || !scan(argv[5],config_line)) return 2;
        return strcmp(bits,actual_bits) || strcmp(resolution,actual_resolution) ? 2 : 0;
    }
    out=fopen(argv[5],"wb");if(!out) return 2;
    failed=fprintf(out,"REGEDIT4\r\n\r\n[%s]\r\n\"Driver\"=\"Display\\\\0000\"\r\n\r\n"
        "[%s]\r\n\"BitsPerPixel\"=\"%s\"\r\n\"Resolution\"=\"%s\"\r\n",
        chosen,profile_key,bits,resolution)<0;
    if (fclose(out)) failed=1;
    return failed ? 2 : 0;
}
#ifdef __WATCOMC__
int dos_entry(void) {
    char args[128];char *argv[8];unsigned n,i=0,argc=1;
    const unsigned char __far *psp=(const unsigned char __far *)((unsigned long)dos_psp()<<16);
    n=psp[0x80];if(n>126)return 2;
    for(i=0;i<n;i++)args[i]=(char)psp[0x81+i];args[n]=0;
    argv[0]="VESBIND";i=0;
    while(i<n) {
        while(i<n&&(args[i]==' '||args[i]=='\t'))args[i++]=0;
        if(i==n)break;if(argc==8)return 2;
        argv[argc++]=args+i;
        while(i<n&&args[i]!=' '&&args[i]!='\t')i++;
    }
    return main((int)argc,argv);
}
#endif
