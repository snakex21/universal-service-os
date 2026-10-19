/* ZIP32 SFX envelope normalization for BusyBox unzip. GPL-3.0-or-later.
 * Does not decompress or execute members. Original size/SHA is checked first.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
static unsigned short z16(const unsigned char *p){return p[0]|(p[1]<<8);}
static unsigned long z32(const unsigned char *p){return (unsigned long)p[0]|((unsigned long)p[1]<<8)|((unsigned long)p[2]<<16)|((unsigned long)p[3]<<24);}
static void put32(unsigned char *p,unsigned long v){int i;for(i=0;i<4;i++){p[i]=(unsigned char)v;v>>=8;}}
int legacy_zip(const char *source,const char *dest){
 FILE *f;unsigned char tail[65557],*b;long size,start,e=-1,delta;size_t n,i,cd,pos,prefix;unsigned count,j;int ok=0;
 f=fopen(source,"rb");if(!f)return 1;
 if(fseek(f,0,SEEK_END)||(size=ftell(f))<22||size>536870912L){fclose(f);return 1;}
 start=size>(long)sizeof tail?size-(long)sizeof tail:0;
 if(fseek(f,start,SEEK_SET)){fclose(f);return 1;}n=fread(tail,1,(size_t)(size-start),f);
 if(n!=(size_t)(size-start)){fclose(f);return 1;}
 for(i=n-22;;i--){if(!memcmp(tail+i,"PK\005\006",4)&&i+22+z16(tail+i+20)==n){e=(long)i;break;}if(!i)break;}
 if(e<0||z16(tail+e+4)||z16(tail+e+6)||z16(tail+e+8)!=z16(tail+e+10)||z16(tail+e+10)==65535){fclose(f);return 1;}
 count=z16(tail+e+10);e+=start;
 if(!count||z32(tail+(e-start)+12)>(unsigned long)e||z32(tail+(e-start)+16)>536870912UL){fclose(f);return 1;}
 cd=(size_t)e-z32(tail+(e-start)+12);delta=(long)cd-(long)z32(tail+(e-start)+16);
 b=(unsigned char*)malloc((size_t)size);if(!b){fclose(f);return 1;}
 rewind(f);if(fread(b,1,(size_t)size,f)!=(size_t)size){free(b);fclose(f);return 1;}fclose(f);
 pos=cd;prefix=cd;
 for(j=0;j<count;j++){
   long long local;size_t step;
   if(pos>(size_t)e||((size_t)e-pos)<46||memcmp(b+pos,"PK\001\002",4))goto done;
   step=46+(size_t)z16(b+pos+28)+z16(b+pos+30)+z16(b+pos+32);
   if(step>(size_t)e-pos||z16(b+pos+34))goto done;
   local=(long long)z32(b+pos+42)+delta;
   if(local<0||(unsigned long long)local>=cd||cd-(size_t)local<30||memcmp(b+(size_t)local,"PK\003\004",4))goto done;
   if((size_t)local<prefix)prefix=(size_t)local;
   pos+=step;
 }
 if(pos!=(size_t)e)goto done;
 if(!dest){
   pos=cd;for(j=0;j<count;j++){
     size_t length=z16(b+pos+28);const unsigned char *name=b+pos+46;
     if(length&&name[length-1]!='/'&&!memchr(name,0,length)&&!memchr(name,'|',length)&&!memchr(name,'\n',length)&&!memchr(name,'\r',length)){
       printf("%lu|",z32(b+pos+24));fwrite(name,1,length,stdout);putchar('\n');
     }
     pos+=46+length+z16(b+pos+30)+z16(b+pos+32);
   }
   ok=!ferror(stdout);goto done;
 }
 pos=cd;for(j=0;j<count;j++){
   put32(b+pos+42,(unsigned long)((long long)z32(b+pos+42)+delta-(long long)prefix));
   pos+=46+(size_t)z16(b+pos+28)+z16(b+pos+30)+z16(b+pos+32);
 }
 put32(b+e+16,(unsigned long)(cd-prefix));
 f=fopen(dest,"wb");if(!f)goto done;
 ok=fwrite(b+prefix,1,(size_t)size-prefix,f)==(size_t)size-prefix;
 if(fclose(f))ok=0;
 if(!ok)remove(dest);
 done:free(b);return ok?0:1;
}
