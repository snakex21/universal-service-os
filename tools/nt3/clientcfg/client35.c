/* Owned NT35 client-only service configurator. Logs and marker live beside
 * this EXE. Only explicit /apply changes existing SCM service configuration. */
#include <windows.h>
void *__cdecl memcpy(void *d,const void *s,unsigned int n){volatile BYTE *p=d;const volatile BYTE *q=s;while(n--)*p++=*q++;return d;}
void *__cdecl memset(void *d,int v,unsigned int n){volatile BYTE *p=d;while(n--)*p++=(BYTE)v;return d;}
static HANDLE logFile=INVALID_HANDLE_VALUE;
static DWORD length(const char *s){DWORD n=0;while(s[n])n++;return n;}
static int same(const char *a,const char *b){char x,y;do{x=*a++;y=*b++;if(x>='a'&&x<='z')x-=32;if(y>='a'&&y<='z')y-=32;if(x!=y)return 0;}while(x);return 1;}
static void text(const char *s){DWORD n;if(logFile!=INVALID_HANDLE_VALUE)WriteFile(logFile,s,length(s),&n,NULL);}
static void row(const char *s,DWORD v){char b[9];int i;text(s);text("=");for(i=0;i<8;i++)b[i]="0123456789ABCDEF"[(v>>(28-i*4))&15];b[8]=0;text(b);text("\r\n");}
#include "scm_policy.h"
static int localPath(char *path,const char *name)
{
    DWORD n=GetModuleFileNameA(NULL,path,512),i;
    if(!n||n>=512)return 0;while(n&&path[n-1]!='\\')n--;
    if(!n||n+length(name)>=512)return 0;
    for(i=0;name[i];i++)path[n+i]=name[i];path[n+i]=0;return 1;
}
static const char *arguments(void)
{
    const char *p=GetCommandLineA();
    if(*p=='"'){p++;while(*p&&*p!='"')p++;if(*p)p++;}
    else while(*p&&*p!=' '&&*p!='\t')p++;
    while(*p==' '||*p=='\t')p++;return p;
}
void __cdecl entry(void)
{
    char path[512],data[80];DWORD version,read=0,written;HANDLE marker;int apply=0,ok=0,fixture=0;
    const char *arg=arguments();
    if(!localPath(path,"CLNT35.LOG"))ExitProcess(3);
    logFile=CreateFileA(path,GENERIC_WRITE,FILE_SHARE_READ,NULL,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,NULL);
    if(logFile==INVALID_HANDLE_VALUE)ExitProcess(3);
    text("USOS NT35 client-only service policy\r\n");version=GetVersion();row("GetVersion",version);
    if((version&255)!=3||(((version>>8)&255)!=5&&((version>>8)&255)!=50)||(version&0x80000000)){
        text("REFUSED_OS\r\n");goto done;}
    if(same(arg,"/apply"))apply=1;
    else if(!same(arg,"/check")){text("REFUSED_ARGUMENTS\r\n");goto done;}
    if(!localPath(path,"CLNT35.ON"))goto done;
    marker=CreateFileA(path,GENERIC_READ,FILE_SHARE_READ,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);
    if(marker==INVALID_HANDLE_VALUE){text("REFUSED_MARKER\r\n");goto done;}
    if(!ReadFile(marker,data,sizeof(data)-1,&read,NULL)){CloseHandle(marker);goto done;}CloseHandle(marker);data[read]=0;
    if(read!=length("USOS NT35 client policy test\r\n")||!same(data,"USOS NT35 client policy test\r\n")){
        text("REFUSED_MARKER_CONTENT\r\n");goto done;}
    fixture=1;
    ok=Client35Run(apply);
    text(ok?"CLIENT_POLICY_PASS\r\n":"CLIENT_POLICY_REFUSED\r\n");
done:
    CloseHandle(logFile);
    /* Completion only for the explicitly marked NT35 VM fixture. Host OS
     * refusals never open any serial device. No status polling is needed. */
    if(fixture){
        const char *completion=ok?"USOS_CLIENT35_DONE=0\r\n":"USOS_CLIENT35_DONE=3\r\n";
        marker=CreateFileA("COM1",GENERIC_WRITE,0,NULL,OPEN_EXISTING,0,NULL);
        if(marker!=INVALID_HANDLE_VALUE){WriteFile(marker,completion,length(completion),&written,NULL);CloseHandle(marker);}
    }
    ExitProcess(ok?0:3);
}
