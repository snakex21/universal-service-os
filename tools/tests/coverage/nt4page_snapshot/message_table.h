#ifndef NT4PAGE_MESSAGE_TABLE_H
#define NT4PAGE_MESSAGE_TABLE_H
/* Own bounded RT_MESSAGETABLE parser; returns a RAM-only original view. */
typedef struct {const unsigned char *text;unsigned bytes,unicode;} N4MESSAGE;
static unsigned n4_msg16(const unsigned char *p){return p[0]|((unsigned)p[1]<<8);}
static unsigned long n4_msg32(const unsigned char *p){return (unsigned long)n4_msg16(p)|((unsigned long)n4_msg16(p+2)<<16);}
static int n4_message_view(const unsigned char *data,unsigned size,unsigned long id,N4MESSAGE *view){
 unsigned blocks,i,pos=0,matches=0,entry;unsigned long low=0,high=0;
 if(!data||size<4||size>1024u*1024u)return 0;
 blocks=(unsigned)n4_msg32(data);if(!blocks||blocks>256||blocks>(size-4)/12)return 0;
 for(i=0;i<blocks;i++){
  unsigned at=4+12*i;unsigned long lo=n4_msg32(data+at),hi=n4_msg32(data+at+4),off=n4_msg32(data+at+8);
  if(hi<lo||hi-lo>16384||off<4+12*blocks||off>size-4)return 0;
  if(id>=lo&&id<=hi){matches++;low=lo;high=hi;pos=(unsigned)off;}
 }
 if(matches!=1||id>high)return 0;
 for(entry=0;entry<=(unsigned)(id-low);entry++){
  unsigned length,flags,j,unit,used;
  if(pos>size-4)return 0;length=n4_msg16(data+pos);flags=n4_msg16(data+pos+2);
  if(length<4||length>size-pos||flags>1)return 0;
  if(entry!=(unsigned)(id-low)){pos+=length;continue;}
  unit=flags?2u:1u;used=length-4;if(used<unit||used%unit)return 0;
  for(j=0;j<used;j+=unit)if(flags?n4_msg16(data+pos+4+j)==0:data[pos+4+j]==0)break;
  if(j==used)return 0;
  {unsigned tail;for(tail=j;tail<used;tail++)if(data[pos+4+tail])return 0;}
  view->text=data+pos+4;view->bytes=j;view->unicode=flags;return j!=0;
 }
 return 0;
}
static unsigned n4_message_controls(const N4W *in,N4W *out,unsigned cap){
 unsigned i=0,n=0;
 if(cap<2)return 0;
 while(in[i]){
  N4W c=in[i++];
  if(c=='%'&&in[i]){
   N4W next=in[i];
   if(next=='0')break;
   if(next=='n'||next=='r'||next=='t'||next=='b'){c=' ';i++;}
   else if(next=='%'){c='%';i++;}
  }
  if(n+1>=cap)return 0;out[n++]=c;
 }
 out[n]=0;return n;
}
#endif
