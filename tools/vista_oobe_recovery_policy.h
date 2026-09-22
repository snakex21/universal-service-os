/* Bounded OOBE evidence checks, shared with local tests. */
static int vo_match(const char *p,unsigned n,const char *s){
 for(unsigned i=0;s[i];i++)if(i>=n||p[i]!=s[i])return 0;return 1;
}
static int vo_completed(const char *data,unsigned n,const char *user){
 unsigned created=0,complete=0;
 for(unsigned i=0;i<n;i++){
  if(!data[i])return 0; /* Sparse/truncated logs cannot authorize recovery. */
  if(vo_match(data+i,n-i,"[oobeldr.exe] Launching [")){created=0;complete=0;}
  const char prefix[]="[msoobe.exe] Finalize: create user [";
  if(vo_match(data+i,n-i,prefix)){
   unsigned j=i+sizeof(prefix)-1,k=0;while(user[k]&&j+k<n&&data[j+k]==user[k])k++;
   created=!user[k]&&j+k<n&&data[j+k]==']';complete=0;
  }
  if(vo_match(data+i,n-i,"[msoobe.exe] Running mandatory tasks"))complete=0;
  if(vo_match(data+i,n-i,"[msoobe.exe] Exiting mandatory tasks... [0x0]"))complete=created;
 }return created&&complete;
}
/* 0 first account, 1 recover, -1 stop; never ask for a duplicate account. */
static int vo_decide(unsigned oobe,unsigned setup_done,unsigned users,unsigned evidence){
 if(!oobe||!setup_done)return -1;
 if(users==0)return 0;
 return users==1&&evidence?1:-1;
}
