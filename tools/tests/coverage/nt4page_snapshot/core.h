#ifndef NT4PAGE_CORE_H
#define NT4PAGE_CORE_H
/* Own diagnostic policy: static public captions only, never EDIT contents. */
typedef unsigned short N4W;
static N4W n4_lower(N4W x){return x>='A'&&x<='Z'?(N4W)(x+32):x;}
static int n4_equal(const N4W *a,const N4W *b){while(*a&&*b&&n4_lower(*a)==n4_lower(*b)){a++;b++;}return !*a&&!*b;}
static int n4_allowed(const N4W *name,int top){
 static const N4W st[]={'s','t','a','t','i','c',0},bt[]={'b','u','t','t','o','n',0},dlg[]={'#','3','2','7','7','0',0};
 return n4_equal(name,st)||n4_equal(name,bt)||(top&&n4_equal(name,dlg));
}
typedef unsigned (*N4READ)(void *context,N4W *target,unsigned capacity);
static unsigned n4_guarded_read(const N4W *name,int top,N4READ read,void *context,N4W *target,unsigned capacity){
 if(!n4_allowed(name,top)||capacity<2)return 0;
 return read(context,target,capacity);
}
static int n4_space(N4W c){return c==' '||c=='\r'||c=='\n'||c=='\t';}
static unsigned n4_normalize(const N4W *in,N4W *out,unsigned capacity){
 unsigned n=0;int gap=0;
 while(*in){N4W c=*in++;
  if(c=='&')continue;
  if(n4_space(c)){if(n)gap=1;continue;}
  if(gap){if(n+1>=capacity)return 0;out[n++]=' ';gap=0;}
  if(n+1>=capacity)return 0;out[n++]=n4_lower(c);
 }
 out[n]=0;return n;
}
static int n4_public_exact(const N4W *actual,const N4W *original){return n4_equal(actual,original);}
#endif
