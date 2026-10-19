/* Bounded ISO9660 reader for legacy addon containers. GPL-3.0-or-later.
 * No devices, mounting, Rock Ridge links, Joliet or boot code. The caller
 * supplies a regular archive file and its private staging folder.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#ifdef _WIN32
#include <direct.h>
#define make_dir(p) _mkdir(p)
#else
#include <sys/stat.h>
#define make_dir(p) mkdir(p,0700)
#endif
static uint32_t le32(const unsigned char *p){return (uint32_t)p[0]|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24);}
static int component(char *s,int short_name){int base=0,ext=0,dot=0;char *p=s;
 for(;*p;p++){if(*p==';'){*p=0;break;}if(*p>='a'&&*p<='z')*p=(char)(*p-32);
  if(*p=='.'){dot++;continue;}if(!((*p>='A'&&*p<='Z')||(*p>='0'&&*p<='9')||*p=='_'||*p=='-'))return 0;
  if(dot)ext++;else base++;}
 if(!base||!strcmp(s,".")||!strcmp(s,".."))return 0;
 return !short_name||(dot<=1&&base<=8&&ext<=3&&(!dot||ext));}
static uint64_t image_size,total_written;
static uint32_t visited[4096];static unsigned visited_count;
static uint32_t sizes[1024];static unsigned size_count;
static int wanted(uint32_t n){unsigned i;for(i=0;i<size_count;i++)if(sizes[i]==n)return 1;return 0;}
static int range(uint32_t sector,uint32_t bytes){return (uint64_t)sector*2048+bytes<=image_size;}
static int block(FILE *f,uint32_t sector,void *out,uint32_t n){return range(sector,n)&&!fseek(f,(long)((uint64_t)sector*2048),SEEK_SET)&&fread(out,1,n,f)==n;}
static int walk(FILE *f,uint32_t sector,uint32_t length,const char *dest,unsigned depth,int scan){unsigned char *data;uint32_t at=0;int result=0;unsigned seen;
 if(depth>12||length>1024*1024||!range(sector,length))return 0;
 for(seen=0;seen<visited_count;seen++)if(visited[seen]==sector)return 0;
 if(visited_count>=4096)return 0;visited[visited_count++]=sector;
 data=malloc(length?length:1);if(!data||!block(f,sector,data,length)){free(data);return 0;}
 while(at<length){unsigned n=data[at];unsigned char *r;char name[256],path[2048];uint32_t bytes,lba;int directory;
  if(!n){at=(at/2048+1)*2048;continue;}if(n<34||at+n>length)break;r=data+at;at+=n;
  if(r[32]==1&&(r[33]==0||r[33]==1))continue;if(33u+r[32]>n)continue;
  memcpy(name,r+33,r[32]);name[r[32]]=0;directory=(r[25]&2)!=0;
  if(!component(name,!scan)||snprintf(path,sizeof path,"%s/%s",dest,name)>=(int)sizeof path)continue;
  lba=le32(r+2);bytes=le32(r+10);if(!range(lba,bytes))continue;
  if(directory){if(scan){make_dir(path);result+=walk(f,lba,bytes,path,depth+1,scan);}continue;}
  if(scan&&!wanted(bytes))continue;if(bytes>512u*1024*1024||total_written+bytes>2ull*1024*1024*1024)continue;
  {FILE *out=fopen(path,"wb");unsigned char buffer[65536];uint32_t left=bytes;int ok=out!=0;
   if(ok&&fseek(f,(long)((uint64_t)lba*2048),SEEK_SET))ok=0;
   while(ok&&left){size_t chunk=left<sizeof buffer?left:sizeof buffer;if(fread(buffer,1,chunk,f)!=chunk||fwrite(buffer,1,chunk,out)!=chunk)ok=0;left-=(uint32_t)chunk;}
   if(out&&fclose(out))ok=0;if(ok){result++;total_written+=bytes;}else remove(path);
  }
 }free(data);return result;}
int legacy_iso(const char *image,const char *dest,const char *requests){FILE *f;unsigned char pvd[2048];long end;int n;
 size_count=0;total_written=0;visited_count=0;
 if(requests){FILE *q=fopen(requests,"rb");char line[2048];if(!q)return 2;
  while(fgets(line,sizeof line,q)){char *p=line;int fields=0;while(*p&&fields<5){if(*p++=='|')fields++;}if(fields==5&&size_count<1024)sizes[size_count++]=(uint32_t)strtoul(p,0,10);}fclose(q);}
 f=fopen(image,"rb");if(!f)return 2;if(fseek(f,0,SEEK_END)||(end=ftell(f))<0){fclose(f);return 2;}image_size=(uint64_t)end;
 if(!block(f,16,pvd,sizeof pvd)||pvd[0]!=1||memcmp(pvd+1,"CD001",5)){fclose(f);return 2;}
 make_dir(dest);n=walk(f,le32(pvd+158),le32(pvd+166),dest,0,requests!=0);fclose(f);return n?0:1;}
