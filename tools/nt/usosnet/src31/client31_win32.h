#include "client31_policy.h"
static SC_HANDLE Client31Scm,Client31Services[4];
static const char *Client31Names[4]={"Browser","LanmanServer","LanmanWorkstation","Tcpip"};
static int Client31Dependency(const char *deps,const BYTE *begin,DWORD size)
{
    const BYTE *p=(const BYTE *)deps,*end=begin+size;DWORD len;int found=0;
    if(!deps||p<begin||p>=end)return 0;
    while(p<end&&*p){
        for(len=0;p+len<end&&p[len];len++);if(p+len>=end)return 0;
        if(same((const char *)p,"LanmanServer"))found=1;p+=len+1;
    }
    return p<end&&found;
}
static int Client31Query(int id,unsigned long *state,unsigned long *start)
{
    SERVICE_STATUS status;static union {DWORD alignment;BYTE data[4096];} buffer;DWORD need=0;
    QUERY_SERVICE_CONFIGA *config=(QUERY_SERVICE_CONFIGA *)buffer.data;
    if(!Client31Services[id])return id==0?2:0;
    if(!QueryServiceStatus(Client31Services[id],&status)){row("QueryServiceStatusError",GetLastError());return 0;}
    if(!QueryServiceConfigA(Client31Services[id],config,sizeof(buffer.data),&need)){row("QueryServiceConfigError",GetLastError());return 0;}
    if(!id&&!Client31Dependency(config->lpDependencies,buffer.data,sizeof(buffer.data))){text("REFUSED_BROWSER_WITHOUT_SERVER_DEPENDENCY\r\n");return 0;}
    text(Client31Names[id]);text("\r\n");row("state",status.dwCurrentState);row("start",config->dwStartType);
    *state=status.dwCurrentState;*start=config->dwStartType;return 1;
}
static int Client31Stop(int id)
{
    static union {DWORD alignment;BYTE data[4096];} buffer;DWORD needed=0,count=0,n,i,code=999,wait;
    char exe[512],command[600];STARTUPINFOA si;PROCESS_INFORMATION pi;
    /* No /y and no unbounded dependent-service traversal. Browser is handled
     * first. Refuse any other active dependent before invoking native NET. */
    if(!EnumDependentServicesA(Client31Services[id],SERVICE_ACTIVE,(ENUM_SERVICE_STATUSA *)buffer.data,sizeof(buffer.data),&needed,&count)||count){
        row("REFUSED_ACTIVE_DEPENDENTS",count);return 0;}
    n=GetSystemDirectoryA(exe,sizeof(exe));if(!n||n+9>=sizeof(exe))return 0;
    for(i=0;"\\NET.EXE"[i];i++)exe[n+i]="\\NET.EXE"[i];exe[n+i]=0;
    n=0;command[n++]='"';for(i=0;exe[i];i++)command[n++]=exe[i];command[n++]='"';
    for(i=0;" stop "[i];i++)command[n++]=" stop "[i];for(i=0;Client31Names[id][i];i++)command[n++]=Client31Names[id][i];command[n]=0;
    for(i=0;i<sizeof(si);i++)((BYTE *)&si)[i]=0;for(i=0;i<sizeof(pi);i++)((BYTE *)&pi)[i]=0;
    si.cb=sizeof(si);si.dwFlags=STARTF_USESHOWWINDOW;si.wShowWindow=SW_HIDE;
    if(!CreateProcessA(exe,command,NULL,NULL,FALSE,0,NULL,NULL,&si,&pi)){row("NativeNetCreateError",GetLastError());return 0;}
    wait=WaitForSingleObject(pi.hProcess,60000);
    if(wait!=WAIT_OBJECT_0){row("NativeNetWait",wait);TerminateProcess(pi.hProcess,3);WaitForSingleObject(pi.hProcess,5000);}
    else if(!GetExitCodeProcess(pi.hProcess,&code))code=999;
    CloseHandle(pi.hThread);CloseHandle(pi.hProcess);row("NativeNetExit",code);return wait==WAIT_OBJECT_0&&code==0;
}
static int Client31Disable(int id)
{
    if(!ChangeServiceConfigA(Client31Services[id],SERVICE_NO_CHANGE,SERVICE_DISABLED,SERVICE_NO_CHANGE,NULL,NULL,NULL,NULL,NULL,NULL,NULL)){
        row("ChangeServiceConfigError",GetLastError());return 0;}
    return 1;
}
static int Client31Run(int apply)
{
    CLIENT31_OPS ops={Client31Query,Client31Stop,Client31Disable};DWORD i,rights;int ok=0;
    Client31Scm=OpenSCManagerA(NULL,NULL,SC_MANAGER_CONNECT);if(!Client31Scm){row("OpenSCManagerError",GetLastError());return 0;}
    for(i=0;i<4;i++){
        rights=SERVICE_QUERY_STATUS|SERVICE_QUERY_CONFIG;
        if(apply&&i<2)rights|=SERVICE_CHANGE_CONFIG|SERVICE_ENUMERATE_DEPENDENTS;
        Client31Services[i]=OpenServiceA(Client31Scm,Client31Names[i],rights);
        if(!Client31Services[i]){DWORD e=GetLastError();if(!i&&e==ERROR_SERVICE_DOES_NOT_EXIST)continue;row("OpenServiceError",e);goto done;}
    }
    ok=Client31Policy(&ops,apply);
done:
    for(i=0;i<4;i++)if(Client31Services[i]){CloseServiceHandle(Client31Services[i]);Client31Services[i]=NULL;}
    CloseServiceHandle(Client31Scm);Client31Scm=NULL;return ok;
}
