/* Read VS_FIXEDFILEINFO from PE resources without loading executable code.
 * Used by the Linux preparation stage to prevent downgrading Windows files.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned char *data;
static size_t size,sections,resource;
static uint16_t count;
static uint32_t resource_size,major_minor,build_revision;
static int found;
static int range(size_t at,size_t bytes){return at<=size&&bytes<=size-at;}
static uint16_t u16(size_t at){return (uint16_t)data[at]|((uint16_t)data[at+1]<<8);}
static uint32_t u32(size_t at){return (uint32_t)u16(at)|((uint32_t)u16(at+2)<<16);}
static size_t offset(uint32_t rva,uint32_t bytes){
 for(unsigned i=0;i<count;i++){
  size_t s=sections+40*i;uint32_t va=u32(s+12),raw=u32(s+20),length=u32(s+16);
  if(rva>=va&&rva-va<=length&&bytes<=length-(rva-va)){
   size_t at=(size_t)raw+(rva-va);if(range(at,bytes))return at;
  }
 }
 return SIZE_MAX;
}
static int relative(uint32_t at,uint32_t bytes){return at<=resource_size&&bytes<=resource_size-at&&range(resource+at,bytes);}
static int version(uint32_t leaf){
 if(!relative(leaf,16))return 0;
 uint32_t length=u32(resource+leaf+4);size_t at=offset(u32(resource+leaf),length);
 if(at==SIZE_MAX||length<92||u16(at)<92||u16(at)>length||u16(at+2)<52||u16(at+4)!=0)return 0;
 static const char key[]="VS_VERSION_INFO";
 for(unsigned i=0;i<sizeof(key);i++)if(u16(at+6+2*i)!=(unsigned char)key[i])return 0;
 size_t fixed=at+40;
 if(u32(fixed)!=0xfeef04bd||u32(fixed+4)!=0x10000)return 0;
 uint32_t ms=u32(fixed+8),ls=u32(fixed+12);
 if(found&&(ms!=major_minor||ls!=build_revision))return 0;
 major_minor=ms;build_revision=ls;found=1;return 1;
}
static int walk(uint32_t at,unsigned depth){
 if(depth>2||!relative(at,16))return 0;
 size_t table=resource+at;unsigned n=(unsigned)u16(table+12)+u16(table+14);
 if(n>4096||!relative(at+16,n*8))return 0;
 int matched=0;
 for(unsigned i=0;i<n;i++){
  size_t e=table+16+8*i;uint32_t id=u32(e),child=u32(e+4);
  if(depth==0&&id!=16)continue;
  matched=1;
  if(depth<2){if(!(child&0x80000000)||!walk(child&0x7fffffff,depth+1))return 0;}
  else if((child&0x80000000)||!version(child))return 0;
 }
 return matched;
}
int main(int argc,char **argv){
 if(argc!=2)return 2;
 FILE *f=fopen(argv[1],"rb");if(!f)return 1;
 if(fseek(f,0,SEEK_END)){fclose(f);return 1;}long n=ftell(f);
 if(n<256||n>64*1024*1024||fseek(f,0,SEEK_SET)){fclose(f);return 1;}
 size=(size_t)n;data=malloc(size);if(!data){fclose(f);return 1;}
 int ok=fread(data,1,size,f)==size;fclose(f);
 if(!ok||u16(0)!=0x5a4d)goto fail;
 size_t pe=u32(0x3c);if(!range(pe,24)||u32(pe)!=0x4550)goto fail;
 count=u16(pe+6);unsigned optional=u16(pe+20);size_t op=pe+24;
 if(count>96||optional<2||!range(op,optional))goto fail;
 unsigned directory=u16(op)==0x20b?112:u16(op)==0x10b?96:0;
 if(!directory||optional<directory+24||u32(op+directory-4)<3)goto fail;
 sections=op+optional;if(!range(sections,(size_t)count*40))goto fail;
 uint32_t rva=u32(op+directory+16);resource_size=u32(op+directory+20);
 resource=offset(rva,resource_size);if(resource==SIZE_MAX||!walk(0,0)||!found)goto fail;
 printf("%u %u %u %u\n",major_minor>>16,major_minor&65535,build_revision>>16,build_revision&65535);free(data);return 0;
 fail:free(data);return 1;
}
