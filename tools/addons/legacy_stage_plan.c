/* Native initramfs frontend for the existing USOSADD resolver. GPL-3.0-or-later.
 * The exact same plan.c/ini.c/str.c/detect.c are linked for host and Linux.
 * Output is an ASCII data protocol, never shell code.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ua.h"
int legacy_iso(const char *,const char *,const char *);
int legacy_zip(const char *,const char *);
static ua_ini manifest,select_ini;
static ua_pkgs packages;
static ua_plan plan;
static ua_choice choice;
static ua_system system_id;
static int selected[UA_MAX_PKGS];
static int unavailable[UA_MAX_PKGS];
static char manifest_text[256*1024],select_text[16*1024];
static int read_text(const char *path,char *out,size_t cap){FILE *f=fopen(path,"rb");size_t n;if(!f)return -1;n=fread(out,1,cap-1,f);if(ferror(f)||!feof(f)){fclose(f);return -1;}out[n]=0;fclose(f);return (int)n;}
static int safe83(const char *s){int base=0,ext=0,dot=0;if(!*s)return 0;for(;*s;s++){
 if(*s=='.'){if(dot++||!base)return 0;continue;}
 if(!((*s>='A'&&*s<='Z')||(*s>='0'&&*s<='9')||*s=='_'||*s=='-'))return 0;
 if(dot)ext++;else base++;}return base<=8&&ext<=3&&(!dot||ext);}
static void add_plan(const char *os){int j;ua_copy(system_id.os,sizeof system_id.os,os);
 ua_resolve(&manifest,&packages,&system_id,choice.full,choice.options,choice.exclude,&plan);
 for(j=0;j<plan.count;j++)selected[plan.idx[j]]=1;
 for(j=0;j<packages.count;j++)if(plan.why[j]==UA_OUT_STATUS&&((choice.full&&packages.pkg[j].tier==UA_TIER_FULL)||ua_list_has(choice.options,packages.pkg[j].id)))unavailable[j]=1;}
static int emit(void){int i,j;
 for(i=0;i<packages.count;i++)if(unavailable[i])printf("unavailable|%s|||||%s\n",packages.pkg[i].id,packages.pkg[i].status);
 for(i=0;i<packages.count;i++)if(selected[i]){const ua_pkg *p=packages.pkg+i;const char *unpack=ua_ini_get(&manifest,p->section,"unpack");
   if(p->tier==UA_TIER_GROUP){printf("group|%s|||||\n",p->id);continue;}
   if(!safe83(p->dir))return 3;
   for(j=1;j<30;j++){char key[24],record[1024],*part[4],*v;int k;
     snprintf(key,sizeof key,"file%d",j);v=(char*)ua_ini_get(&manifest,p->section,key);if(!v)break;
     if(strlen(v)>=sizeof record)return 3;strcpy(record,v);part[0]=record;
     for(k=1;k<4;k++){char *s=strchr(part[k-1],'|');if(!s)return 3;*s=0;part[k]=s+1;}
     if(!safe83(part[0])||strlen(part[2])!=64||strspn(part[2],"0123456789abcdef")!=64||!part[3][0]||strspn(part[3],"0123456789")!=strlen(part[3]))return 3;
     printf("file|%s|%s|%s|%s|%s|%s\n",p->id,p->dir,part[0],part[2],part[3],unpack?unpack:"");
   }
 }return 0;}
static int language(const char *path){char buf[65537],*p;FILE *f=fopen(path,"rb");size_t n;if(!f)return 1;n=fread(buf,1,sizeof(buf)-1,f);fclose(f);buf[n]=0;
 /* Microsoft SETUP.TXT on the supported CDs is RTF. Read its declared
  * document language; never infer the OS language from menu or filename. */
 p=strstr(buf,"\\deflang");if(p){int id=atoi(p+8);if((id&0x3ff)==0x15){puts("PL");return 0;}if((id&0x3ff)==9){puts("EN");return 0;}}
 if(strstr(buf,"Plik README dla Instalatora")){puts("PL");return 0;}
 if(strstr(buf,"README for Setup")){puts("EN");return 0;}
 puts("XX");return 0;}
int main(int argc,char **argv){int n;
 if(argc==4&&!strcmp(argv[1],"prepare-zip"))return legacy_zip(argv[2],argv[3]);
 if(argc==3&&!strcmp(argv[1],"list-zip"))return legacy_zip(argv[2],0);
 if(argc==4&&!strcmp(argv[1],"unpack-iso"))return legacy_iso(argv[2],argv[3],0);
 if(argc==5&&!strcmp(argv[1],"scan-iso"))return legacy_iso(argv[2],argv[3],argv[4]);
 if(argc==3&&!strcmp(argv[1],"language"))return language(argv[2]);
 if(argc!=6){fputs("usage: legacy-stage-plan MANIFEST SELECT OS LANG NTSP\n",stderr);return 2;}
 n=read_text(argv[1],manifest_text,sizeof manifest_text);if(n<0)return 2;ua_ini_parse(&manifest,manifest_text,n);
 n=read_text(argv[2],select_text,sizeof select_text);if(n<0)return 2;ua_ini_parse(&select_ini,select_text,n);
 if(manifest.overflow||select_ini.overflow||ua_load_pkgs(&manifest,&packages)<0)return 3;
 ua_selection(&manifest,&select_ini,&choice);if(!strcmp(choice.preset,"none"))return 0;
 ua_copy(system_id.lang,sizeof system_id.lang,argv[4]);ua_copy(system_id.ntsp,sizeof system_id.ntsp,argv[5]);
 if(!strcmp(argv[3],"95")){add_plan("95OSR2");add_plan("95OSR21");add_plan("95OSR25");}
 else if(!strcmp(argv[3],"NT4")&&!argv[5][0]){ua_copy(system_id.ntsp,sizeof system_id.ntsp,"0");add_plan("NT4");ua_copy(system_id.ntsp,sizeof system_id.ntsp,"6a");add_plan("NT4");}
 else add_plan(argv[3]);return emit();}
