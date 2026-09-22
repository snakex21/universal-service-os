/* Bounded access to existing Vista hive cells. No allocation, compaction,
 * cell relocation or new registry values. Dirty/invalid headers are rejected.
 * Used only on the freshly installed target, after Setup has exited.
 */
#include <stdint.h>
typedef struct { unsigned char *p; uint32_t size,end; } VistaHive;
static uint16_t vh16(const unsigned char *p){return p[0]|(uint16_t)p[1]<<8;}
static uint32_t vh32(const unsigned char *p){return vh16(p)|(uint32_t)vh16(p+2)<<16;}
static void vhw32(unsigned char *p,uint32_t v){for(unsigned i=0;i<4;i++)p[i]=(unsigned char)(v>>(8*i));}
static uint32_t vh_checksum(const unsigned char *p){uint32_t v=0;for(unsigned i=0;i<0x1fc;i+=4)v^=vh32(p+i);return v==0?1:v==0xffffffff?0xfffffffe:v;}
static int vh_open(VistaHive *h,unsigned char *p,uint32_t size){
 if(size<4096||p[0]!='r'||p[1]!='e'||p[2]!='g'||p[3]!='f'||vh32(p+4)!=vh32(p+8)||vh32(p+0x1fc)!=vh_checksum(p))return 0;
 uint32_t bins=vh32(p+0x28);if(bins>size-4096||!bins||(bins&4095))return 0;
 h->p=p;h->size=size;h->end=4096+bins;return 1;
}
static unsigned char *vh_cell(VistaHive *h,uint32_t offset,uint32_t need,uint32_t *capacity){
 if((offset&7)||offset>h->end-4096||h->end-4096-offset<4)return 0;
 uint32_t at=4096+offset,raw=vh32(h->p+at),bytes=0u-raw;
 if(!(raw&0x80000000)||bytes<4||bytes>h->end-at||need>bytes-4||(bytes&7))return 0;
 if(capacity)*capacity=bytes-4;return h->p+at+4;
}
static uint16_t vh_upper(uint16_t c){return c>='a'&&c<='z'?c-32:c;}
static int vh_name(const unsigned char *raw,unsigned bytes,int ascii,const char *name,unsigned count){
 if(bytes!=count*(ascii?1u:2u))return 0;
 for(unsigned i=0;i<count;i++)if(vh_upper(ascii?raw[i]:vh16(raw+2*i))!=vh_upper((unsigned char)name[i]))return 0;
 return 1;
}
static uint32_t vh_subkey(VistaHive *h,uint32_t list,const char *name,unsigned count,unsigned depth,unsigned *budget){
 if(depth>32||!*budget)return 0xffffffff;(*budget)--;
 uint32_t cap;unsigned char *p=vh_cell(h,list,4,&cap);if(!p)return 0xffffffff;
 unsigned n=vh16(p+2),stride=(p[0]=='l'&&(p[1]=='h'||p[1]=='f'))?8:4;
 int nested=p[0]=='r'&&p[1]=='i';if(!nested&&!(p[0]=='l'&&(p[1]=='h'||p[1]=='f'||p[1]=='i')))return 0xffffffff;
 if(n>(cap-4)/stride)return 0xffffffff;
 for(unsigned i=0;i<n;i++){
  uint32_t at=vh32(p+4+i*stride);
  if(nested){uint32_t found=vh_subkey(h,at,name,count,depth+1,budget);if(found!=0xffffffff)return found;}
  else {uint32_t bytes;unsigned char *key=vh_cell(h,at,0x4c,&bytes);
   if(!key||key[0]!='n'||key[1]!='k'||vh16(key+0x48)>bytes-0x4c)return 0xffffffff;
   if(vh_name(key+0x4c,vh16(key+0x48),vh16(key+2)&0x20,name,count))return at;
  }
 }return 0xffffffff;
}
static unsigned char *vh_key(VistaHive *h,const char *path){
 uint32_t at=vh32(h->p+0x24);unsigned budget=100000;
 while(*path){
  unsigned char *key=vh_cell(h,at,0x4c,0);if(!key||key[0]!='n'||key[1]!='k'||!vh32(key+0x14))return 0;
  unsigned n=0;while(path[n]&&path[n]!='\\')n++;if(!n)return 0;
  at=vh_subkey(h,vh32(key+0x1c),path,n,0,&budget);if(at==0xffffffff)return 0;
  path+=n;if(*path)path++;
 }
 unsigned char *key=vh_cell(h,at,0x4c,0);return key&&key[0]=='n'&&key[1]=='k'?key:0;
}
static unsigned char *vh_value(VistaHive *h,const char *path,const char *name){
 unsigned char *key=vh_key(h,path);if(!key)return 0;
 uint32_t n=vh32(key+0x24),cap;unsigned length=0;while(name[length])length++;
 unsigned char *list=vh_cell(h,vh32(key+0x28),4,&cap);if(!list||n>cap/4)return 0;
 for(uint32_t i=0;i<n;i++){
  unsigned char *v=vh_cell(h,vh32(list+4*i),0x14,&cap);
  if(!v||v[0]!='v'||v[1]!='k'||vh16(v+2)>cap-0x14)return 0;
  if(vh_name(v+0x14,vh16(v+2),vh16(v+0x10)&1,name,length))return v;
 }return 0;
}
static unsigned char *vh_data(VistaHive *h,unsigned char *v,uint32_t type,uint32_t *size){
 if(!v||vh32(v+0xc)!=type)return 0;uint32_t raw=vh32(v+4);*size=raw&0x7fffffff;
 if(raw&0x80000000)return *size<=4?v+8:0;
 // Relevant settings are small, never segmented "db" data blocks.
 if(*size>0x3fd8)return 0;return vh_cell(h,vh32(v+8),*size,0);
}
static int vh_dword(VistaHive *h,const char *key,const char *name,uint32_t *out){
 uint32_t n;unsigned char *p=vh_data(h,vh_value(h,key,name),4,&n);if(!p||n!=4)return 0;*out=vh32(p);return 1;
}
static int vh_string(VistaHive *h,const char *key,const char *name,uint16_t *out,unsigned count){
 unsigned char *v=vh_value(h,key,name);uint32_t n;if(!v)return 0;
 uint32_t type=vh32(v+0xc);if(type!=1&&type!=2)return 0;
 unsigned char *p=vh_data(h,v,type,&n);if(!p||n<2||(n&1)||n/2>count||vh16(p+n-2))return 0;
 for(unsigned i=0;i<n/2;i++)out[i]=vh16(p+i*2);return 1;
}
static int vh_set_dword(VistaHive *h,const char *key,const char *name,uint32_t value){
 uint32_t n;unsigned char *p=vh_data(h,vh_value(h,key,name),4,&n);if(!p||n!=4)return 0;vhw32(p,value);return 1;
}
static int vh_set_string(VistaHive *h,const char *key,const char *name,const uint16_t *value){
 uint32_t n;unsigned char *v=vh_value(h,key,name),*p=vh_data(h,v,1,&n);if(!p||n<=4)return 0;
 unsigned length=0;while(value[length])length++;unsigned bytes=(length+1)*2;if(bytes>n)return 0;
 for(unsigned i=0;i<n;i++)p[i]=i<bytes?(unsigned char)(value[i/2]>>(8*(i%2))):0;
 vhw32(v+4,bytes);return 1;
}
static void vh_seal(VistaHive *h){uint32_t seq=vh32(h->p+4)+1;vhw32(h->p+4,seq);vhw32(h->p+8,seq);vhw32(h->p+0x1fc,vh_checksum(h->p));}
