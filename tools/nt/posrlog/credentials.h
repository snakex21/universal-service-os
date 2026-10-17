/* Bounded parser for the POSReady answer's plain AdminPassword attribute.
 * Own code, GPL-3.0-or-later. No file access or XML entity expansion. */
#ifndef POSR_CREDENTIALS_H
#define POSR_CREDENTIALS_H
static int pr_eq(const char *p,unsigned n,const char *s){unsigned i=0;while(s[i]){if(i>=n||p[i]!=s[i])return 0;i++;}return i==n;}
static int pr_space(char c){return c==' '||c=='\r'||c=='\n'||c=='\t';}
static int pr_copy(const char *p,unsigned n,char *out,unsigned capacity){
 unsigned used=0;
 for(unsigned i=0;i<n;i++){
  unsigned value=(unsigned char)p[i];
  if(value=='&'){
   unsigned end=i+1;while(end<n&&p[end]!=';'&&end-i<16)end++;if(end==n||p[end]!=';')return 0;
   const char *entity=p+i+1;unsigned size=end-i-1;
   if(pr_eq(entity,size,"amp"))value='&';else if(pr_eq(entity,size,"quot"))value='"';
   else if(pr_eq(entity,size,"apos"))value='\'';else if(pr_eq(entity,size,"lt"))value='<';else if(pr_eq(entity,size,"gt"))value='>';
   else if(size>1&&entity[0]=='#'){
    unsigned at=1,base=10;value=0;if(entity[at]=='x'||entity[at]=='X'){base=16;at++;}if(at==size)return 0;
    for(;at<size;at++){unsigned v=(unsigned char)entity[at];if(v>='0'&&v<='9')v-='0';else if(base==16&&v>='a'&&v<='f')v=v-'a'+10;else if(base==16&&v>='A'&&v<='F')v=v-'A'+10;else return 0;
     if(value>0x10ffffu/base)return 0;value=value*base+v;}
   }else return 0;
   if(!value||value>0x10ffffu||(value>=0xd800&&value<=0xdfff)||value<32)return 0;
   i=end;
   if(value>=128){
    unsigned need=value<0x800?2:value<0x10000?3:4;if(used+need>=capacity)return 0;
    if(need==2)out[used++]=(char)(0xc0|(value>>6));
    else if(need==3){out[used++]=(char)(0xe0|(value>>12));out[used++]=(char)(0x80|((value>>6)&63));}
    else{out[used++]=(char)(0xf0|(value>>18));out[used++]=(char)(0x80|((value>>12)&63));out[used++]=(char)(0x80|((value>>6)&63));}
    out[used++]=(char)(0x80|(value&63));continue;
   }
  }
  if(value<32||used+1>=capacity)return 0;out[used++]=(char)value;
 }
 if(!capacity)return 0;out[used]=0;return 1;
}
static int pr_password(const char *xml,unsigned length,char *out,unsigned capacity){
 unsigned found=0;
 for(unsigned at=0;at<length;){
  if(xml[at]!='<'){at++;continue;}
  if(at+4<=length&&pr_eq(xml+at,4,"<!--")){
   at+=4;while(at+3<=length&&!pr_eq(xml+at,3,"-->"))at++;if(at+3>length)return 0;at+=3;continue;
  }
  if(at+9<=length&&pr_eq(xml+at,9,"<!DOCTYPE"))return 0;
  at++;unsigned start=at;while(at<length&&!pr_space(xml[at])&&xml[at]!='>'&&xml[at]!='/')at++;
  if(!pr_eq(xml+start,at-start,"AdminPassword"))continue;
  if(++found!=1)return 0;
  unsigned have=0;
  while(at<length){
   while(at<length&&pr_space(xml[at]))at++;
   if(at<length&&(xml[at]=='/'||xml[at]=='>'))break;
   start=at;while(at<length&&!pr_space(xml[at])&&xml[at]!='=')at++;unsigned keylen=at-start;
   while(at<length&&pr_space(xml[at]))at++;if(at==length||xml[at++]!='=')return 0;
   while(at<length&&pr_space(xml[at]))at++;if(at==length||(xml[at]!='"'&&xml[at]!='\''))return 0;
   char quote=xml[at++];unsigned value=at;while(at<length&&xml[at]!=quote)at++;if(at==length)return 0;
   if(pr_eq(xml+start,keylen,"Value")){if(have++||!pr_copy(xml+value,at-value,out,capacity))return 0;}
   if(pr_eq(xml+start,keylen,"EncryptedPassword")&&!pr_eq(xml+value,at-value,"No"))return 0;
   at++;
  }
  if(!have||at>=length)return 0;
 }
 return found==1;
}
#endif
