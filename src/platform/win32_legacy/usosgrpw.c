/* USOS, GPL-3.0-or-later. Windows95 GRPCONV watchdog, no CRT or UI.
 * Waits on process/messages for120s; only its own GRPCONV and descendant
 * PROGMAN processes may be terminated. Always returns0 to the Setup chain.
 * Own diagnostics stay beside this executable. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>

void *memset(void *p,int v,unsigned n){unsigned char *d=p;while(n--)*d++=(unsigned char)v;return p;}
static HANDLE log_file=INVALID_HANDLE_VALUE;
static unsigned length(const char *s){unsigned n=0;while(s[n])n++;return n;}
static void line(const char *s){DWORD n;if(log_file==INVALID_HANDLE_VALUE)return;
    WriteFile(log_file,s,length(s),&n,0);WriteFile(log_file,"\r\n",2,&n,0);FlushFileBuffers(log_file);}
static void number(const char *key,DWORD v){char s[80],digits[11];unsigned n=0,i=0;
    while(key[i]&&i<60){s[i]=key[i];i++;}do{digits[n++]=(char)('0'+v%10);v/=10;}while(v&&n<10);
    while(n)s[i++]=digits[--n];s[i]=0;line(s);}
static int equal(const char *a,const char *b){while(*a&&*b){char x=*a++,y=*b++;
    if(x>='a'&&x<='z')x-=32;if(y>='a'&&y<='z')y-=32;if(x!=y)return 0;}return *a==*b;}

typedef HANDLE (WINAPI *OWN_SNAPSHOT)(DWORD,DWORD);
typedef BOOL (WINAPI *OWN_PROCESS_ENUM)(HANDLE,LPPROCESSENTRY32);
typedef struct {DWORD pid,parent;int progman;} CHILD;
static CHILD children[128];
static void stop_progman(DWORD owner){
    HMODULE kernel=GetModuleHandleA("KERNEL32.DLL");HANDLE snapshot,process;
    OWN_SNAPSHOT snap=(OWN_SNAPSHOT)GetProcAddress(kernel,"CreateToolhelp32Snapshot");
    OWN_PROCESS_ENUM first=(OWN_PROCESS_ENUM)GetProcAddress(kernel,"Process32First");
    OWN_PROCESS_ENUM next=(OWN_PROCESS_ENUM)GetProcAddress(kernel,"Process32Next");
    PROCESSENTRY32 entry;unsigned count=0,i,j,depth;DWORD parent;const char *name,*p;
    if(!snap||!first||!next){line("GRPW descendant-snapshot-unavailable");return;}
    snapshot=snap(TH32CS_SNAPPROCESS,0);if(snapshot==INVALID_HANDLE_VALUE){line("GRPW descendant-snapshot-failed");return;}
    memset(&entry,0,sizeof entry);entry.dwSize=sizeof entry;
    if(first(snapshot,&entry))do{
        if(count==128){line("GRPW descendant-snapshot-capacity");break;}
        children[count].pid=entry.th32ProcessID;children[count].parent=entry.th32ParentProcessID;
        name=entry.szExeFile;for(p=name;*p;p++)if(*p=='\\'||*p=='/')name=p+1;
        children[count++].progman=equal(name,"PROGMAN.EXE");
    }while(next(snapshot,&entry));
    CloseHandle(snapshot);
    for(i=0;i<count;i++)if(children[i].progman){
        parent=children[i].parent;
        for(depth=0;depth<count&&parent&&parent!=owner;depth++){
            for(j=0;j<count;j++)if(children[j].pid==parent)break;
            if(j==count)break;parent=children[j].parent;
        }
        if(parent!=owner)continue;
        process=OpenProcess(PROCESS_TERMINATE,FALSE,children[i].pid);
        if(process){number(TerminateProcess(process,0)?"GRPW progman-stopped pid=":"GRPW progman-stop-failed pid=",children[i].pid);CloseHandle(process);}
        else number("GRPW progman-open-failed pid=",children[i].pid);
    }
}

void __cdecl grp_start(void){
    char path[MAX_PATH],command[MAX_PATH+8];unsigned i,last=0;DWORD n,start,elapsed,result,exit_code;
    STARTUPINFOA startup;PROCESS_INFORMATION process;MSG msg;int stop=0;
    n=GetModuleFileNameA(0,path,sizeof path);
    if(n&&n<sizeof path){for(i=0;i<n;i++)if(path[i]=='\\'||path[i]=='/')last=i+1;
        if(last&&last+12<sizeof path){lstrcpyA(path+last,"USOSLOG.TXT");
            log_file=CreateFileA(path,GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,0,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,0);
            if(log_file!=INVALID_HANDLE_VALUE)SetFilePointer(log_file,0,0,FILE_END);}}
    line("GRPW version=1 begin");
    n=GetWindowsDirectoryA(path,sizeof path);
    if(!n||n+13>=sizeof path){line("GRPW windows-directory-failed");goto done;}
    lstrcatA(path,"\\GRPCONV.EXE");command[0]='\"';lstrcpyA(command+1,path);lstrcatA(command,"\" -s");
    memset(&startup,0,sizeof startup);memset(&process,0,sizeof process);startup.cb=sizeof startup;
    startup.dwFlags=STARTF_USESHOWWINDOW;startup.wShowWindow=SW_HIDE;start=GetTickCount();
    if(!CreateProcessA(path,command,0,0,FALSE,0,0,0,&startup,&process)){
        number("GRPW create-error=",GetLastError());goto done;}
    number("GRPW child-pid=",process.dwProcessId);CloseHandle(process.hThread);
    for(;;){
        elapsed=GetTickCount()-start;if(elapsed>=120000UL){line("GRPW timeout-ms=120000");stop=1;break;}
        result=MsgWaitForMultipleObjects(1,&process.hProcess,FALSE,120000UL-elapsed,QS_ALLINPUT);
        if(result==WAIT_OBJECT_0){if(GetExitCodeProcess(process.hProcess,&exit_code))number("GRPW child-exit=",exit_code);break;}
        if(result==WAIT_TIMEOUT){line("GRPW timeout-ms=120000");stop=1;break;}
        if(result!=WAIT_OBJECT_0+1){number("GRPW wait-error=",GetLastError());stop=1;break;}
        for(i=0;i<64&&PeekMessageA(&msg,0,0,0,PM_REMOVE);i++){
            if(msg.message!=WM_QUIT){TranslateMessage(&msg);DispatchMessageA(&msg);}}
    }
    if(stop){stop_progman(process.dwProcessId);
        line(TerminateProcess(process.hProcess,0)?"GRPW grpconv-stopped":"GRPW grpconv-stop-failed");}
    CloseHandle(process.hProcess);number("GRPW elapsed-ms=",GetTickCount()-start);
done:
    line("GRPW complete exit=0");if(log_file!=INVALID_HANDLE_VALUE)CloseHandle(log_file);ExitProcess(0);
}
