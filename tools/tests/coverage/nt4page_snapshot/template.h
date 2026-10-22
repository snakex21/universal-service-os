#ifndef NT4PAGE_TEMPLATE_H
#define NT4PAGE_TEMPLATE_H
/* Bounded whole-message match against original public resource templates.
   Inserted contents remain in RAM and are never emitted. No edit reads. */
static unsigned n4_insert_token(const N4W *p){
 unsigned k=1,n=0;
 if(p[0]!='%')return 0;
 if(p[k]>='1'&&p[k]<='9'){
  k++;if(p[k]>='0'&&p[k]<='9')k++;
  if(p[k]=='!'){
   k++;
   while(p[k]&&p[k]!='!'&&n<16){N4W c=p[k];
    if(!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='.'||c=='-'||c=='+'))return 0;
    k++;n++;
   }
   if(!n||p[k]!='!')return 0;k++;
  }
  return k;
 }
 if(p[k]=='l'||p[k]=='w')k++;
 if(p[k]=='s'||p[k]=='S'||p[k]=='d'||p[k]=='u'||p[k]=='x'||p[k]=='X')return k+1;
 return 0;
}
static int n4_segment_equal(const N4W *a,unsigned pos,const N4W *p,unsigned n,unsigned alen){
 unsigned i;if(pos>alen||n>alen-pos)return 0;
 for(i=0;i<n;i++)if(a[pos+i]!=p[i])return 0;return 1;
}
static int n4_segments_match(const N4W *a,unsigned alen,const N4W **s,const unsigned *lens,unsigned count,unsigned part,unsigned pos,unsigned *budget){
 unsigned end,limit,next;
 if(!*budget)return 0;(*budget)--;
 if(!n4_segment_equal(a,pos,s[part],lens[part],alen))return 0;
 end=pos+lens[part];if(part==count)return end==alen;
 limit=alen-end;if(limit>256)limit=256;
 for(next=0;next<=limit;next++){
  if(!*budget)return 0;
  if(n4_segments_match(a,alen,s,lens,count,part+1,end+next,budget))return 1;
 }
 return 0;
}
static int n4_public_template(const N4W *a,const N4W *p){
 const N4W *segments[4];unsigned lens[4],i=0,start=0,count=0,alen=0,literal=0,words=0,budget=2048;int inword=0;
 if(n4_equal(a,p))return 1;
 while(a[alen]){if(alen>=767)return 0;alen++;}
 segments[0]=p;
 while(p[i]){
  unsigned token;if(i>=767)return 0;
  if(p[i]!='%'){if(p[i]!=' '){literal++;if(!inword){words++;inword=1;}}else inword=0;i++;continue;}
  token=n4_insert_token(p+i);if(!token||count>=3)return 0;
  lens[count]=i-start;if((!count&&lens[0]<8)||(count&&lens[count]<3))return 0;
  count++;i+=token;start=i;segments[count]=p+i;inword=0;
 }
 lens[count]=i-start;
 if(!count||literal<24||words<4)return 0;
 return n4_segments_match(a,alen,segments,lens,count,0,0,&budget);
}
/* A diagnostic public-literal fragment is explicitly weaker than whole-message.
   It never sets an error owner and can never authorize ACK. */
static int n4_public_fragment(const N4W *a,const N4W *p){
 unsigned n=0,alen=0,i,j,words=0;int inword=0;
 while(p[n]){if(n>=767||p[n]=='%')return 0;if(p[n]==' ')inword=0;else if(!inword){words++;inword=1;}n++;}
 if(n<24||words<4)return 0;
 while(a[alen]){if(alen>=767)return 0;alen++;}
 if(n>=alen)return 0;
 for(i=0;i+n<=alen;i++){
  if(i&&a[i-1]!=' '&&a[i-1]!=':'&&a[i-1]!='(')continue;
  for(j=0;j<n&&a[i+j]==p[j];j++){}
  if(j==n&&(i+n==alen||a[i+n]==' '||a[i+n]==')'))return 1;
 }
 return 0;
}
#endif
