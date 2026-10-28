/* Host cases for CSMWrap 3.1.2-usos10 patch 0011 (src/usos_watcher.c), run by
 * test_csmwrap_watcher.py. Written by Codex with the patch (2026-10-15). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "usos_watcher.h"
#define CHECK(x) do {if(!(x)){fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x);exit(1);}}while(0)
static unsigned tests;
static void pass(const char *s){printf("PASS %s\n",s);tests++;}
static void w32(unsigned char *p,unsigned n){p[0]=n;p[1]=n>>8;p[2]=n>>16;p[3]=n>>24;}
static void fixsum(unsigned char *f,unsigned n){unsigned i;unsigned char s=0;f[9]=0;for(i=0;i<n;i++)s+=f[i];f[9]=(unsigned char)-s;}
static void fadt(unsigned char f[276]){
 memset(f,0,276);memcpy(f,"FACP",4);w32(f+4,116);w32(f+56,0x800);w32(f+64,0x804);
 w32(f+76,0x808);w32(f+80,0x820);f[88]=4;f[89]=2;f[91]=4;f[92]=8;w32(f+112,256);fixsum(f,116);
}
struct mock {unsigned reads,bytes,words,bad,tear;};
static usw_u32 memread(void *ctx,usw_u32 pa){struct mock *m=ctx;m->reads++;
 if(pa==0x100000)return 0x12345678;
 if(pa==0x200008)return 0xAABBCCDD;
 if(pa==0x20000C)return 7;
 if(pa==0x200010)return m->tear?8:7;
 m->bad++;return 0;
}
static usw_u8 inbyte(void *ctx,usw_u16 p){struct mock *m=ctx;m->bytes++;
 if(p==0x21)return 0xFE;if(p==0xA1)return 0xFF;
 if(p>=0x820 && p<0x830)return (usw_u8)p;
 m->bad++;return 0;
}
static usw_u16 inword(void *ctx,usw_u16 p){struct mock *m=ctx;m->words++;
 if(p==0x800)return 0x100;if(p==0x802)return 0x101;if(p==0x804)return 1;
 m->bad++;return 0;
}
int main(void){
 unsigned char f[276];struct usw_ports p;unsigned char *mb=calloc(1,USW_SIZE),map[60]={0};
 struct mock mock={0};struct usw_ops ops={&mock,memread,inbyte,inword};struct usw_sample s;
 char line[82];unsigned i;
 CHECK(mb!=NULL);fadt(f);CHECK(usw_parse_fadt(f,116,&p));
 CHECK(p.pm_sts==0x800 && p.pm_en==0x802 && p.pm_cnt==0x804 && p.pm_tmr==0x808);
 CHECK(p.gpe_sts==0x820 && p.gpe_en==0x824 && p.gpe_half==4 && p.timer_bits==32);
 pass("FADT legacy X470 port offsets and widths");
 f[9]++;CHECK(!usw_parse_fadt(f,116,&p));fadt(f);f[92]=7;fixsum(f,116);
 CHECK(usw_parse_fadt(f,116,&p) && !p.gpe_sts);fadt(f);w32(f+56,0x70);fixsum(f,116);
 CHECK(usw_parse_fadt(f,116,&p) && !p.pm_sts);fadt(f);w32(f+112,1<<20);fixsum(f,116);
 CHECK(!usw_parse_fadt(f,116,&p));CHECK(!usw_parse_fadt(f,115,&p));
 pass("reject malformed/checksum/HW_REDUCED/legacy indexed I/O");
 fadt(f);w32(f+4,276);w32(f+56,0);f[148]=1;w32(f+152,0x600);
 w32(f+64,0);f[172]=1;w32(f+176,0x604);w32(f+76,0);f[208]=1;w32(f+212,0x608);
 w32(f+80,0);f[220]=1;w32(f+224,0x620);fixsum(f,276);
 CHECK(usw_parse_fadt(f,276,&p) && p.pm_sts==0x600 && p.pm_en==0x602 && p.pm_cnt==0x604 && p.gpe_en==0x624);
 f[148]=0;fixsum(f,276);CHECK(usw_parse_fadt(f,276,&p) && !p.pm_sts);
 pass("GAS fallback only in System I/O");
 f[148]=1;w32(f+152,0xFFFFFFFEu);w32(f+156,0xFFFFFFFFu);fixsum(f,276);
 CHECK(usw_parse_fadt(f,276,&p) && !p.pm_sts);
 pass("GAS address overflow cannot turn a 64-bit address into a valid I/O port");
 w32(map,0x100000);w32(map+8,0x800);w32(map+16,2);
 w32(map+20,0x100800);w32(map+28,0x800);w32(map+36,2);
 CHECK(usw_e820_reserved(map,2,20,0x100000,4096));
 w32(map+36,1);CHECK(!usw_e820_reserved(map,2,20,0x100000,4096));w32(map+36,2);
 w32(map+28,0x400);CHECK(!usw_e820_reserved(map,2,20,0x100000,4096));w32(map+28,0x800);
 w32(map+40,0x100400);w32(map+48,0x100);w32(map+56,1);
 CHECK(!usw_e820_reserved(map,3,20,0x100000,4096));
 pass("E820 full coverage, gap and conflicting RAM rejected");
 fadt(f);CHECK(usw_parse_fadt(f,116,&p));usw_init(mb,&p,1000000000,USW_RESERVED);
 CHECK(usw_header_valid(mb,USW_SIZE));CHECK(!usw_header_valid(mb,4095));mb[4]=2;CHECK(!usw_header_valid(mb,4096));mb[4]=1;
 mb[0]='X';CHECK(!usw_header_valid(mb,4096));mb[0]='U';usw_store32(mb,12,0);CHECK(!usw_header_valid(mb,4096));usw_store32(mb,12,1);
 pass("mailbox signature/version/size/reservation validation");
 usw_store64(mb,USW_START,1000000000);usw_store32(mb,USW_READY,1);
 usw_store64(mb,USW_TICK_PA,0x100000);usw_store64(mb,USW_SHARED_PA,0x200000);
 usw_store32(mb,USW_HB_ENTRY,9);usw_store32(mb,USW_HB_DRAW,3);usw_store32(mb,USW_ARM,2);
 usw_collect(mb,&ops,6000000000ull,&s);CHECK(!mock.bad && mock.reads==4);
 CHECK(s.tick==0x12345678 && s.it_low==0xAABBCCDD && s.it_high==7 && s.hb_entry==9 && s.hb_draw==3 && s.seconds==5);
 line[80]='X';line[81]=0;usw_format(&s,line);CHECK(line[80]=='X');line[80]=0;
 CHECK(strlen(line)==80 && strstr(line,"W0005T12345678IAABBCCDD h0009a2 P0100/0101/0001"));
 CHECK(strstr(line,"G23222120/27262524 MFEFF ."));printf("ROW: [%s]\n",line);
 pass("80-column format, actual TSC seconds, GPE byte assembly, zero-safe validity");
 mock.tear=1;mock.reads=0;usw_collect(mb,&ops,6000000000ull,&s);
 CHECK(mock.reads==7 && !(s.flags&USW_V_TIME) && (s.flags&USW_F_TORN));usw_format(&s,line);
 CHECK(!memcmp(line+15,"????????",8));mock.tear=0;
 pass("InterruptTime retry bounded to two attempts");
 usw_store64(mb,USW_TICK_PA,0x100100000ull);usw_store64(mb,USW_SHARED_PA,0x100200000ull);
 mock.reads=0;usw_collect(mb,&ops,6000000000ull,&s);
 CHECK(!mock.reads && (s.flags&USW_F_HIGHPA) && !(s.flags&(USW_V_TICK|USW_V_TIME)));
 pass("PA >=4 GiB never truncated or dereferenced");
 usw_store32(mb,USW_SEQ,1);mock.reads=0;usw_collect(mb,&ops,6000000000ull,&s);CHECK(!mock.reads && (s.flags&USW_F_TORN));
 usw_store32(mb,USW_SEQ,2);usw_store32(mb,USW_READY,0);usw_collect(mb,&ops,6000000000ull,&s);
 CHECK(s.flags&USW_F_READY);pass("odd seq and not-ready publication never followed");
 usw_store32(mb,USW_LATE,1);usw_store32(mb,12,USW_RESERVED|USW_NONINVARIANT);
 usw_collect(mb,&ops,6000000000ull,&s);usw_format(&s,line);
 CHECK((s.flags&(USW_F_BUSY|USW_F_UNSTABLE))==(USW_F_BUSY|USW_F_UNSTABLE));
 pass("proxy-delay and non-invariant-TSC indicators");
 s.flags=USW_V_PUBLISH|USW_F_READY|USW_F_HIGHPA|USW_F_BUSY|USW_F_TORN|USW_F_GPEPART|USW_F_UNSTABLE|USW_F_BADPA;
 usw_format(&s,line);CHECK(!memcmp(line+73,"R4B?GUX",7) && line[80]==0);
 pass("all seven diagnostic flag characters fit in exactly 80 columns");
 {unsigned char before[4096];memcpy(before,mb,4096);usw_save(mb,&s,line);
  for(i=0;i<4096;i++)if(i<0x100 || i>=0x200)CHECK(mb[i]==before[i]);
  CHECK(!(usw_load32(mb,USW_SSEQ)&1));}
 pass("sample persistent writes confined to helper-owned 100..1ff");
 s.flags=USW_V_TICK|USW_V_TIME;s.tick=10;s.it_low=100;s.seconds=3;
 usw_save(mb,&s,line);s.tick=11;s.it_low=200;s.seconds=4;usw_save(mb,&s,line);
 CHECK(usw_load32(mb,0x1A0)==10 && usw_load32(mb,0x1A4)==100 && usw_load32(mb,0x1A8)==2);
 CHECK(usw_load32(mb,0x1AC)==10 && usw_load32(mb,0x1B8)==100 && usw_load64(mb,0x1B0)==3);
 pass("first and previous samples retained for end-of-run verification");
 mb[USW_CONFIG+12]=0xFF;mb[USW_CONFIG+13]=0xFF;mock.bad=0;
 usw_collect(mb,&ops,6000000000ull,&s);CHECK(!mock.bad && !(s.flags&USW_V_GPE));
 pass("corrupt GPE length cannot cause wrapped/indexed I/O reads");
 free(mb);printf("WATCHER-HOST-PASS %u tests\n",tests);return 0;
}
