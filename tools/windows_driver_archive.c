/* Expand the Core's driver archive beside this helper in WinPE RAM only.
 * --inspect validates a regular archive file without loading drivers or writing.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
static BYTE data[64*1024*1024];
static WCHAR base[MAX_PATH],path[MAX_PATH];
static unsigned positions[512],lengths[512];
static unsigned len(const WCHAR *s){unsigned n=0;while(s[n])n++;return n;}
static void copy(WCHAR *d,const WCHAR *s){while((*d++=*s++));}
static void say(const char *s){DWORD n=0,w;while(s[n])n++;WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),s,n,&w,0);}
static unsigned u16(const BYTE *p){return p[0]|(unsigned)p[1]<<8;}
static unsigned u32(const BYTE *p){return u16(p)|u16(p+2)<<16;}
static int same(const WCHAR *a,const WCHAR *b){while(*a&&*a==*b){a++;b++;}return *a==*b;}
static int valid_name(const BYTE *s,unsigned n){
 if(!n||n>180)return 0;unsigned start=0;
 for(unsigned i=0;i<=n;i++){
  if(i==n||s[i]=='\\'){
   unsigned count=i-start;if(!count||(count==1&&s[start]=='.')||(count==2&&s[start]=='.'&&s[start+1]=='.')||s[i-1]=='.'||s[i-1]==' ')return 0;
   /* Reject device names, even with extensions, before CreateFile is called. */
   char word[5]={0};unsigned k=0;while(k<count&&k<4&&s[start+k]!='.'){BYTE c=s[start+k];word[k]=(char)(c>='a'&&c<='z'?c-32:c);k++;}
   if((k==3&&((word[0]=='C'&&word[1]=='O'&&word[2]=='N')||(word[0]=='P'&&word[1]=='R'&&word[2]=='N')||(word[0]=='A'&&word[1]=='U'&&word[2]=='X')||(word[0]=='N'&&word[1]=='U'&&word[2]=='L')))||(k==4&&word[3]>='1'&&word[3]<='9'&&((word[0]=='C'&&word[1]=='O'&&word[2]=='M')||(word[0]=='L'&&word[1]=='P'&&word[2]=='T'))))return 0;
   start=i+1;continue;
  }
  BYTE c=s[i];if(c<32||c>126||c=='/'||c==':'||c=='"'||c=='<'||c=='>'||c=='|'||c=='*'||c=='?'||c=='%')return 0;
 }
 return 1;
}
static int validate(unsigned size,unsigned *files){
 const char *magic="USOSDRV1";if(size<12)return 0;for(unsigned i=0;i<8;i++)if(data[i]!=magic[i])return 0;
 unsigned count=u32(data+8),at=12;if(count>512)return 0;
 for(unsigned i=0;i<count;i++){
  if(at>size||size-at<6)return 0;unsigned name=u16(data+at),bytes=u32(data+at+2);at+=6;
  if(name>size-at||!valid_name(data+at,name))return 0;
  for(unsigned j=0;j<i;j++)if(lengths[j]==name){unsigned k=0;for(;k<name;k++){BYTE a=data[positions[j]+k],b=data[at+k];if(a>='a'&&a<='z')a-=32;if(b>='a'&&b<='z')b-=32;if(a!=b)break;}if(k==name)return 0;}
  positions[i]=at;lengths[i]=name;at+=name;if(bytes>size-at)return 0;at+=bytes;
 }
 if(at!=size)return 0;*files=count;return 1;
}
static int extract(unsigned count){
 unsigned prefix=len(base);if(prefix+21+180>=MAX_PATH)return 0;
 copy(path,base);copy(path+prefix,L"usos-win7-drivers");
 if(!CreateDirectoryW(path,0)&&GetLastError()!=ERROR_ALREADY_EXISTS)return 0;
 copy(base+prefix,L"usos-win7-drivers\\");prefix=len(base);
 for(unsigned i=0;i<count;i++){
  copy(path,base);unsigned name=lengths[i],at=positions[i];
  for(unsigned j=0;j<name;j++){
   path[prefix+j]=data[at+j];
   if(data[at+j]=='\\'){path[prefix+j]=0;if(!CreateDirectoryW(path,0)&&GetLastError()!=ERROR_ALREADY_EXISTS)return 0;path[prefix+j]='\\';}
  }
  path[prefix+name]=0;unsigned bytes=u32(data+at-4);at+=name;
  HANDLE h=CreateFileW(path,GENERIC_WRITE,0,0,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,0);if(h==INVALID_HANDLE_VALUE)return 0;
  DWORD done=0;int ok=WriteFile(h,data+at,bytes,&done,0)&&done==bytes;CloseHandle(h);if(!ok)return 0;
 }
 return 1;
}
void entry(void){
 static WCHAR args[3][MAX_PATH];const WCHAR *s=GetCommandLineW();unsigned count=0;
 while(*s){while(*s==' '||*s=='\t')s++;if(!*s)break;if(count==3)ExitProcess(2);int quote=0;unsigned n=0;
  while(*s&&(quote||(*s!=' '&&*s!='\t'))){if(*s=='"'){quote=!quote;s++;continue;}if(n+1>=MAX_PATH)ExitProcess(2);args[count][n++]=*s++;}if(quote)ExitProcess(2);args[count++][n]=0;
 }
 int inspect=count==3&&same(args[1],L"--inspect");
 if(inspect){if(args[2][0]=='\\')ExitProcess(2);copy(path,args[2]);}
 else{
  if(count!=1)ExitProcess(2);HKEY key;if(RegOpenKeyExW(HKEY_LOCAL_MACHINE,L"SYSTEM\\CurrentControlSet\\Control\\MiniNT",0,KEY_READ,&key)!=ERROR_SUCCESS)ExitProcess(2);RegCloseKey(key);
  unsigned n=GetModuleFileNameW(0,base,MAX_PATH);if(!n||n>=MAX_PATH-32)ExitProcess(2);while(n&&base[n-1]!='\\')n--;base[n]=0;if(!n)ExitProcess(2);
  copy(path,base);copy(path+n,L"usos-drivers.bin");
 }
 HANDLE h=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);if(h==INVALID_HANDLE_VALUE)ExitProcess(1);
 LARGE_INTEGER size;DWORD got=0;int ok=GetFileSizeEx(h,&size)&&size.QuadPart>=12&&size.QuadPart<=sizeof(data)&&ReadFile(h,data,(DWORD)size.QuadPart,&got,0)&&got==size.QuadPart;CloseHandle(h);
 unsigned files=0;if(!ok||!validate(got,&files)){say("Driver archive rejected.\r\n");ExitProcess(1);}
 if(!inspect&&!extract(files)){say("Driver extraction failed.\r\n");ExitProcess(1);}
 say(inspect?"PASS driver archive\r\n":"Driver packages available in WinPE RAM.\r\n");ExitProcess(0);
}
