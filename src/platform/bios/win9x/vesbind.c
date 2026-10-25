/* USOS, GPL-3.0-or-later. Plan/check a 950 late display binding using only
 * fresh original REGEDIT4 exports (PLAN / CHECK never read hive bytes), and
 * DELKEY: one key deleted from SYSTEM.DAT (see delkey() below).
 * PLAN classes enum idconfig output.reg; CHECK classes enum idconfig config
 * Reject ambiguous displays, custom drivers, malformed/duplicate data.
 * The display is the one PCI display device, else the one legacy
 * Root\*PNP0900 device. A PCI display that 950 PnP already installed from
 * USOSVESA.INF (vesamini, its own class key) needs no rebinding: only the
 * mode is written, and the legacy *PNP0900 that detection left next to it
 * is removed (X470 950 PL, 2026-10-25: Display\0000 = *PNP0900 on the early
 * VESA import, Display\0001 = the RX 560 on USOSVESA.INF; 950 kept both as
 * two adapters, OSR2 drops the legacy devnode by itself; the X470 run with
 * the legacy devnode deleted by hand had the RX 560 working alone). A PCI
 * display on MSDISP.INF next to a *PNP0900 is rebound to Display\0000.
 * PLAN exit: 0 = plan written; 3 = plan written and the batch must delete
 * HKLM\Enum\Root\*PNP0900 (VESBIND DELKEY); 2 = refused. CHECK fails while a
 * legacy *PNP0900 display is still next to the PCI display.
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
static unsigned class_count, pci_displays, root_displays;
static char key[MAXKEY], candidate[MAXKEY], device_class[40], driver[40];
static char chosen[MAXKEY], chosen_driver[40], profile[5], bits[4], resolution[24];
static char root_chosen[MAXKEY], root_driver[40];
static char actual_bits[4], actual_resolution[24], profile_key[MAXKEY];
static int current_class = -1, default_section, valid_device, candidate_pci;

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
        if (candidate_pci) {
            if (++pci_displays!=1) return 0;
            strcpy(chosen,candidate);strcpy(chosen_driver,driver);
        } else {
            if (++root_displays!=1) return 0;
            strcpy(root_chosen,candidate);strcpy(root_driver,driver);
        }
    }
    return 1;
}
/* A class key with USOSVESA.INF [VESA]'s driver (early import or 950 PnP). */
static int vesa_like(int i) {
    return ieq(classes[i].inf,"USOSVESA.INF") && ieq(classes[i].drv,"vesamini.drv") &&
        ieq(classes[i].mini,"vesamini.vxd");
}
static int device_line(const char *line,int header) {
    if (header) {
        const char *s=0;unsigned i;
        if (!flush_device()) return 0;
        valid_device=0;device_class[0]=0;driver[0]=0;
        candidate_pci=prefix(key,ENUMPCI);
        if (candidate_pci) {
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
/* DELKEY <hive> <key path>: remove one key and its whole subtree from a
 * Windows 95 CREG hive (SYSTEM.DAT) in place, streaming (the hive is never
 * loaded whole): the 950 real-mode REGEDIT has no /D. Layout as read from
 * 950 hives (X470 950 PL SYSTEM.1ST / SYSTEM.VL / SYSTEM.DAT, 2026-10-25):
 *   CREG header 0x20: +04 version 10000h, +08 RGDB offset, +0C checksum,
 *     +10 WORD block count, +12 WORD flags.
 *   RGKN at 0x20: +04 size, +08 root entry, +0C first free chunk, +10
 *     flags, +14 checksum. Key entries (1Ch bytes, never across a 4 KB
 *     page): +00 0 = in use, +04 hash, +08 -1, +0C parent, +10 first child,
 *     +14 next sibling, +18 WORD id, +1A WORD RGDB block (offsets relative
 *     to RGKN, -1 = none). Free chunk: +00 80000000h, +04 size, +08 next.
 *   RGDB blocks: +04 size, +08 free bytes, +0C WORD flags, +0E WORD number,
 *     +10 first free record (-1 = none), +1C checksum; records from +20:
 *     +00 size, +04 WORD id, +06 WORD block, +08 bytes used, +0C WORD name
 *     length, +14 name. Free record: id, block and bytes used all -1.
 * Flags bit 2 = checksum present: the section's DWORDs sum to 0.
 * The key is unlinked from its parent / sibling chain, its entries become
 * free chunks (free list kept sorted by offset), its records free records
 * (neighbouring free records merged); the touched checksums are corrected
 * and summed again. Exit 0 = deleted, 1 = no such key (file untouched),
 * 2 = refused (file untouched), 3 = failed while writing (restore the
 * backup). Every structure on the way is checked before the first write.
 */
#define NONE 0xFFFFFFFFUL
#define MASK32 0xFFFFFFFFUL
#define MAXBLK 256
#define MAXDEL 1024
#define SLOTS 4
static unsigned long blk_off[MAXBLK], blk_size[MAXBLK], delta[MAXBLK + 1];
static unsigned blk_flags[MAXBLK], blk_count, rgkn_flags;
static unsigned char touched[MAXBLK + 1];
static unsigned long kn_size, kn_root, kn_free;
static unsigned long del_list[MAXDEL];
static unsigned del_count;
static unsigned long slot_pos[SLOTS][256];
static int slot_blk[SLOTS], slot_next;
static unsigned char io[512];
static const char *del_reason = "not-started";
/* WRAPGRP uses the real exported command, never a localized value name. */
#define SETUPKEY "HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce\\Setup"
static char grp_name[256];
static unsigned grp_count;
static int grp_line(const char *line,int header) {
    const char *p,*start,*base;char command[512],program[256];unsigned n=0,left;
    if(header || !ieq(key,SETUPKEY) || line[0]!='\"') return 1;
    p=line+1;
    while(*p && *p!='\"'){if(*p=='\\'&&p[1])p++;p++;}
    if(*p!='\"' || p[1]!='=' || p[2]!='\"')return 1;
    left=(unsigned)(p-line)+1;if(left>=sizeof(grp_name))return 0;
    p+=3;
    while(*p && *p!='\"'){
        char c=*p++;
        if(c=='\\'){c=*p++;if(c!='\\'&&c!='\"')return 0;}
        if((unsigned char)c<32 || n+1>=sizeof(command))return 0;
        command[n++]=c;
    }
    if(*p!='\"' || p[1])return 0;command[n]=0;p=command;
    while(*p==' '||*p=='\t')p++;
    start=p;n=0;
    if(*p=='\"'){start=++p;while(*p&&*p!='\"')p++;}
    else while(*p&&*p!=' '&&*p!='\t')p++;
    n=(unsigned)(p-start);if(!n||n>=sizeof(program))return 1;
    memcpy(program,start,n);program[n]=0;
    if(*p=='\"')p++;while(*p==' '||*p=='\t')p++;
    if(!ieq(p,"-s"))return 1;
    base=program;for(start=program;*start;start++)if(*start=='\\'||*start=='/')base=start+1;
    if(!ieq(base,"grpconv.exe"))return 1;
    if(++grp_count!=1)return 0;
    memcpy(grp_name,line,left);grp_name[left]=0;return 1;
}
#ifdef __WATCOMC__
static unsigned hive = 0xffff;
static int hopen(const char *path) { hive = dos_open_rw(path); return hive != 0xffff; }
static int hclose(void) { return !dos_close(hive); }
static int hread(unsigned long off, void *buf, unsigned n) {
    return !dos_seek(hive, (unsigned)(off >> 16), (unsigned)(off & 0xffff)) && dos_read(hive, buf, n) == n;
}
static int hwrite(unsigned long off, const void *buf, unsigned n) {
    return !dos_seek(hive, (unsigned)(off >> 16), (unsigned)(off & 0xffff)) && dos_write(hive, buf, n) == n;
}
#else
static FILE *hive;
static int hopen(const char *path) { hive = fopen(path, "r+b"); return hive != NULL; }
static int hclose(void) { return !fclose(hive); }
static int hread(unsigned long off, void *buf, unsigned n) {
    return !fseek(hive, (long)off, SEEK_SET) && fread(buf, 1, n, hive) == n;
}
static int hwrite(unsigned long off, const void *buf, unsigned n) {
    return !fseek(hive, (long)off, SEEK_SET) && fwrite(buf, 1, n, hive) == n && !fflush(hive);
}
#endif
static unsigned long g32(const unsigned char *p) {
    return (unsigned long)p[0] | ((unsigned long)p[1] << 8) | ((unsigned long)p[2] << 16) | ((unsigned long)p[3] << 24);
}
static unsigned g16(const unsigned char *p) { return (unsigned)p[0] | ((unsigned)p[1] << 8); }
static void p32(unsigned char *p, unsigned long v) {
    p[0] = (unsigned char)v; p[1] = (unsigned char)(v >> 8); p[2] = (unsigned char)(v >> 16); p[3] = (unsigned char)(v >> 24);
}
static int same(const unsigned char *a, const char *b, unsigned n) {
    while (n--) if (*a++ != (unsigned char)*b++) return 0;
    return 1;
}
/* Section 0 = RGKN, 1 + b = RGDB block b. */
static unsigned long sec_base(unsigned sec) { return sec ? blk_off[sec - 1] : 0x20UL; }
static int sec_sum(unsigned sec, unsigned long *sum) {
    unsigned long base = sec_base(sec), size = sec ? blk_size[sec - 1] : kn_size, done = 0, s = 0;
    unsigned n, i;
    while (done < size) {
        n = size - done > sizeof(io) ? (unsigned)sizeof(io) : (unsigned)(size - done);
        if (!hread(base + done, io, n)) return 0;
        for (i = 0; i < n; i += 4) s = (s + g32(io + i)) & MASK32;
        done += n;
    }
    *sum = s;
    return 1;
}
/* Write bytes inside a section; the change of its DWORD sum is kept. */
static int put(unsigned sec, unsigned long off, const unsigned char *data, unsigned n) {
    unsigned char old[0x1c]; unsigned i, shift;
    if (n > sizeof(old) || !hread(off, old, n)) return 0;
    for (i = 0; i < n; i++) {
        shift = (unsigned)((off + i - sec_base(sec)) & 3) * 8;
        delta[sec] = (delta[sec] + ((unsigned long)data[i] << shift) - ((unsigned long)old[i] << shift)) & MASK32;
    }
    touched[sec] = 1;
    return hwrite(off, data, n);
}
static int put32(unsigned sec, unsigned long off, unsigned long v) {
    unsigned char b[4]; p32(b, v); return put(sec, off, b, 4);
}
/* A key entry: in use, inside RGKN, within one 4 KB page. */
static int entry(unsigned long rel, unsigned char *e) {
    if (rel == NONE || rel < 0x20 || rel + 0x1c > kn_size || (rel & 0xfffUL) + 0x1c > 0x1000) return 0;
    return hread(0x20 + rel, e, 0x1c) && g32(e) == 0;
}
/* Record positions of one block by id (a few blocks cached). */
static int block_index(unsigned blk) {
    unsigned long pos, end, rs; unsigned char r[8]; unsigned id, i; int s;
    for (s = 0; s < SLOTS; s++) if (slot_blk[s] == (int)blk) return s;
    if (blk >= blk_count) return -1;
    s = slot_next; slot_next = (slot_next + 1) % SLOTS; slot_blk[s] = -1;
    for (i = 0; i < 256; i++) slot_pos[s][i] = NONE;
    pos = 0x20; end = blk_size[blk];
    while (pos < end) {
        if (end - pos < 0x14 || !hread(blk_off[blk] + pos, r, 8)) return -1;
        rs = g32(r);
        if (rs < 0x14 || rs > end - pos) return -1;
        id = g16(r + 4);
        if (id == 0xffff) { if (g16(r + 6) != 0xffff) return -1; }
        else {
            if (id > 255 || g16(r + 6) != blk || slot_pos[s][id] != NONE) return -1;
            slot_pos[s][id] = pos;
        }
        pos += rs;
    }
    slot_blk[s] = (int)blk;
    return s;
}
/* The record of an entry: block-relative position, NONE without one. */
static int record(const unsigned char *e, unsigned *blk, unsigned long *pos) {
    unsigned id = g16(e + 0x18); int s;
    *blk = g16(e + 0x1a);
    if (*blk == 0xffff) { *pos = NONE; return 1; }
    if (id > 255 || (s = block_index(*blk)) < 0) return 0;
    *pos = slot_pos[s][id];
    return *pos != NONE;
}
static int name_is(const unsigned char *e, const char *name, unsigned len, int *match) {
    unsigned char r[0x14], text[256]; unsigned blk, i; unsigned long pos;
    *match = 0;
    if (!record(e, &blk, &pos)) return 0;
    if (pos == NONE) return 1;
    if (!hread(blk_off[blk] + pos, r, 0x14)) return 0;
    if (g16(r + 0xc) != len) return 1;
    if (!hread(blk_off[blk] + pos + 0x14, text, len)) return 0;
    for (i = 0; i < len; i++) if (tolower(text[i]) != tolower((unsigned char)name[i])) return 1;
    *match = 1;
    return 1;
}
static int free_insert(unsigned long rel) {
    unsigned long prev = NONE, cur = kn_free; unsigned char c[12], e[0x1c]; unsigned n = 0;
    while (cur != NONE && cur < rel) {
        if (++n > 60000U || cur + 12 > kn_size || !hread(0x20 + cur, c, 12) || g32(c) != 0x80000000UL) return 0;
        prev = cur; cur = g32(c + 8);
    }
    if (cur == rel) return 0;
    memset(e, 0, sizeof(e)); p32(e, 0x80000000UL); p32(e + 4, 0x1c); p32(e + 8, cur);
    if (!put(0, 0x20 + rel, e, sizeof(e))) return 0;
    if (prev == NONE) { kn_free = rel; return put32(0, 0x20 + 0x0c, rel); }
    return put32(0, 0x20 + prev + 8, rel);
}
static int free_record(unsigned blk, unsigned long pos) {
    unsigned char h[0x14], ff[8]; unsigned long base = blk_off[blk];
    if (!hread(base, h, 0x14) || !hread(base + pos, ff, 4)) return 0;
    if (!put32(1 + blk, base + 8, (g32(h + 8) + g32(ff)) & MASK32)) return 0;
    if ((g32(h + 0x10) == NONE || g32(h + 0x10) > pos) && !put32(1 + blk, base + 0x10, pos)) return 0;
    memset(ff, 0xff, sizeof(ff));
    return put(1 + blk, base + pos + 4, ff, 8);
}
/* Neighbouring free records become one. */
static int merge_free(unsigned blk) {
    unsigned long pos = 0x20, prev = NONE, prev_size = 0, rs, base = blk_off[blk]; unsigned char r[8];
    while (pos < blk_size[blk]) {
        if (!hread(base + pos, r, 8)) return 0;
        rs = g32(r);
        if (rs < 0x14 || rs > blk_size[blk] - pos) return 0;
        if (g16(r + 4) == 0xffff) {
            if (prev != NONE) { prev_size += rs; if (!put32(1 + blk, base + prev, prev_size)) return 0; }
            else { prev = pos; prev_size = rs; }
        } else prev = NONE;
        pos += rs;
    }
    return 1;
}
static int delkey(const char *path, const char *key) {
    unsigned char h[0x20], e[0x1c], p[0x1c]; unsigned long off, cur, target, parent, sum, ck, rel, pos;
    unsigned i, len, blk; int match, failed; const char *name, *end;
    del_reason = "argument";
    if (prefix(key, "HKEY_LOCAL_MACHINE\\")) key += 19;
    if (!*key || *key == '\\') return 2;
    for (i = 0; i <= MAXBLK; i++) { delta[i] = 0; touched[i] = 0; }
    for (i = 0; i < SLOTS; i++) slot_blk[i] = -1;
    slot_next = 0; del_count = 0;
    del_reason = "hive-open";
    if (!hopen(path)) return 2;
    failed = 2;
    del_reason = "creg-header";
    if (!hread(0, h, 0x20) || !same(h, "CREG", 4) || g32(h + 4) != 0x10000UL) goto done;
    off = g32(h + 8); blk_count = g16(h + 0x10);
    del_reason = "rgdb-count";
    if (!blk_count || blk_count > MAXBLK) goto done;
    if (g16(h + 0x12) & 4) {
        del_reason = "creg-checksum";
        for (sum = 0, i = 0; i < 0x20; i += 4) sum = (sum + g32(h + i)) & MASK32;
        if (sum) goto done;
    }
    del_reason = "rgkn-header";
    if (!hread(0x20, h, 0x20) || !same(h, "RGKN", 4)) goto done;
    kn_size = g32(h + 4); kn_root = g32(h + 8); kn_free = g32(h + 0x0c); rgkn_flags = g16(h + 0x10);
    del_reason = "rgkn-layout";
    if (kn_size < 0x3c || (kn_size & 3) || off != 0x20 + kn_size) goto done;
    del_reason = "rgdb-layout";
    for (i = 0; i < blk_count; i++) {
        if (!hread(off, h, 0x20) || !same(h, "RGDB", 4) || g16(h + 0x0e) != i) goto done;
        blk_off[i] = off; blk_size[i] = g32(h + 4); blk_flags[i] = g16(h + 0x0c);
        if (blk_size[i] < 0x20 || (blk_size[i] & 3)) goto done;
        off += blk_size[i];
    }
    /* Checksums as found: a hive this tool does not understand is refused. */
    del_reason = "rgkn-checksum";
    if ((rgkn_flags & 4) && (!sec_sum(0, &sum) || sum)) goto done;
    del_reason = "rgdb-checksum";
    for (i = 0; i < blk_count; i++) if ((blk_flags[i] & 4) && (!sec_sum(1 + i, &sum) || sum)) goto done;
    /* Walk the path from the root entry. */
    del_reason = "root-entry";
    if (!entry(kn_root, e)) goto done;
    target = kn_root; name = key;
    while (*name) {
        del_reason = "path-entry";
        end = strchr(name, '\\'); len = end ? (unsigned)(end - name) : (unsigned)strlen(name);
        if (!len || len > 255) goto done;
        cur = g32(e + 0x10); match = 0;
        for (i = 0; cur != NONE; i++) {
            if (i > 60000U || !entry(cur, e) || g32(e + 0x0c) != target || !name_is(e, name, len, &match)) goto done;
            if (match) break;
            cur = g32(e + 0x14);
        }
        if (!match) { failed = 1; del_reason = "not-found"; goto done; }
        target = cur; name += len; if (*name) name++;
    }
    /* The subtree, breadth first; every entry and record must be sound. */
    del_reason = "subtree";
    del_list[del_count++] = target;
    for (i = 0; i < del_count; i++) {
        if (!entry(del_list[i], e) || !record(e, &blk, &pos)) goto done;
        cur = g32(e + 0x10);
        while (cur != NONE) {
            if (del_count == MAXDEL || !entry(cur, p) || g32(p + 0x0c) != del_list[i]) goto done;
            del_list[del_count++] = cur; cur = g32(p + 0x14);
        }
    }
    del_reason = "parent-entry";
    if (!entry(target, e)) goto done;
    parent = g32(e + 0x0c);
    if (!entry(parent, p)) goto done;
    /* From here on the file changes. */
    failed = 3;
    del_reason = "write-unlink";
    if (g32(p + 0x10) == target) { if (!put32(0, 0x20 + parent + 0x10, g32(e + 0x14))) goto done; }
    else {
        cur = g32(p + 0x10);
        for (i = 0;; i++) {
            if (cur == NONE || i > 60000U || !entry(cur, p)) goto done;
            if (g32(p + 0x14) == target) break;
            cur = g32(p + 0x14);
        }
        if (!put32(0, 0x20 + cur + 0x14, g32(e + 0x14))) goto done;
    }
    del_reason = "write-free";
    for (i = 0; i < del_count; i++) {
        if (!entry(del_list[i], e) || !record(e, &blk, &pos)) goto done;
        if (pos != NONE && !free_record(blk, pos)) goto done;
        if (!free_insert(del_list[i])) goto done;
    }
    del_reason = "write-merge";
    for (i = 0; i < blk_count; i++) if (touched[1 + i] && !merge_free(i)) goto done;
    del_reason = "write-checksum";
    for (i = 0; i <= blk_count; i++) {
        if (!touched[i] || !((i ? blk_flags[i - 1] : rgkn_flags) & 4)) continue;
        rel = sec_base(i) + (i ? 0x1c : 0x14);
        if (!hread(rel, h, 4)) goto done;
        ck = (g32(h) - delta[i]) & MASK32; p32(h, ck);
        if (!hwrite(rel, h, 4) || !sec_sum(i, &sum) || sum) goto done;
    }
    failed = 0; del_reason = "complete";
done:
    if (!hclose() && failed != 1 && failed != 2) { failed = 3; del_reason = "hive-close"; }
    return failed;
}
int main(int argc,char **argv) {
    int vesa,old,bound;FILE *out;int failed;
    memset(classes,0,sizeof(classes));class_count=pci_displays=root_displays=0;
    key[0]=candidate[0]=device_class[0]=driver[0]=chosen[0]=chosen_driver[0]=0;
    root_chosen[0]=root_driver[0]=0;
    profile[0]=bits[0]=resolution[0]=actual_bits[0]=actual_resolution[0]=profile_key[0]=0;
    current_class=-1;default_section=valid_device=candidate_pci=0;
    if(argc==4 && ieq(argv[1],"WRAPGRP")){
        grp_count=0;grp_name[0]=0;
        if(!scan(argv[2],grp_line))return 2;
        if(!grp_count)return 1;
        out=fopen(argv[3],"wb");if(!out)return 2;
        failed=fprintf(out,"REGEDIT4\r\n\r\n[" SETUPKEY "]\r\n%s=\"C:\\\\USOS9X\\\\USOSGRPW.EXE -s\"\r\n",grp_name)<0;
        if(fclose(out))failed=1;return failed?2:0;
    }
    if ((argc==4 || argc==5) && ieq(argv[1],"DELKEY")) {
        static const char *codes[] = {"0", "1", "2", "3"};
        failed=delkey(argv[2],argv[3]);
        if (argc==5) {
            out=fopen(argv[4],"wb");
            if (!out) return 3;
            if (fprintf(out,"version=1\r\nexit=%s\r\nreason=%s\r\n",codes[failed],del_reason)<0) {
                fclose(out); return 3;
            }
            if (fclose(out)) return 3;
        }
        return failed;
    }
    if (argc!=6 || (!ieq(argv[1],"PLAN") && !ieq(argv[1],"CHECK"))) return 2;
    if (!scan(argv[2],class_line) || !scan(argv[3],device_line) || !flush_device() ||
        pci_displays+root_displays==0 || !scan(argv[4],id_line) || !id4(profile) ||
        !strcmp(profile,"0000")) return 2;
    if (!pci_displays) { strcpy(chosen,root_chosen);strcpy(chosen_driver,root_driver); }
    vesa=find_class("0000");
    if (vesa<0 || !ieq(classes[vesa].inf,"USOSVESA.INF") ||
        !ieq(classes[vesa].drv,"vesamini.drv") || !ieq(classes[vesa].mini,"vesamini.vxd") ||
        !mode(classes[vesa].mode)) return 2;
    if (!prefix(chosen_driver,"Display\\") || !id4(chosen_driver+8)) return 2;
    old=find_class(chosen_driver+8);
    if (old<0) return 2;
    bound=old==vesa || vesa_like(old);
    if (!bound && (!ieq(classes[old].inf,"MSDISP.INF") ||
        (!ieq(classes[old].drv,"vga.drv") && !ieq(classes[old].drv,"supervga.drv")))) return 2;
    sprintf(profile_key,"HKEY_LOCAL_MACHINE\\Config\\%s\\Display\\Settings",profile);
    if (ieq(argv[1],"CHECK")) {
        /* One adapter: no legacy *PNP0900 display may stay next to the PCI one. */
        if (!bound || (pci_displays && root_displays) || !scan(argv[5],config_line)) return 2;
        return strcmp(bits,actual_bits) || strcmp(resolution,actual_resolution) ? 2 : 0;
    }
    out=fopen(argv[5],"wb");if(!out) return 2;
    if (!bound) failed=fprintf(out,"REGEDIT4\r\n\r\n[%s]\r\n\"Driver\"=\"Display\\\\0000\"\r\n\r\n"
        "[%s]\r\n\"BitsPerPixel\"=\"%s\"\r\n\"Resolution\"=\"%s\"\r\n",
        chosen,profile_key,bits,resolution)<0;
    else if (old!=vesa) failed=fprintf(out,"REGEDIT4\r\n\r\n[" CLS "%s\\DEFAULT]\r\n\"Mode\"=\"%s,%s\"\r\n\r\n"
        "[%s]\r\n\"BitsPerPixel\"=\"%s\"\r\n\"Resolution\"=\"%s\"\r\n",
        classes[old].id,bits,resolution,profile_key,bits,resolution)<0;
    else failed=fprintf(out,"REGEDIT4\r\n\r\n[%s]\r\n\"BitsPerPixel\"=\"%s\"\r\n\"Resolution\"=\"%s\"\r\n",
        profile_key,bits,resolution)<0;
    if (fclose(out)) failed=1;
    if (failed) return 2;
    /* The PCI display takes over; the batch deletes Enum\Root\*PNP0900. */
    return pci_displays && root_displays ? 3 : 0;
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
