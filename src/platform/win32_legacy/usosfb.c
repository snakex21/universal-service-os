/* Source950 first-desktop coordinator. USOS, GPL-3.0-or-later.
 * Ordinary RunOnce is synchronous before Shell_TrayWnd on Windows95.
 * Its persistent phase belongs beside the program, never in a user profile.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
static const char root[]="C:\\USOS9X\\";
static const char once[]="Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce";
static HANDLE journal=INVALID_HANDLE_VALUE;
static char path[MAX_PATH],text[8192];
void *memset(void *p,int v,unsigned n){BYTE*b=p;while(n--)*b++=(BYTE)v;return p;}
static unsigned length(const char*s){unsigned n=0;while(s[n])n++;return n;}
static void local(const char*leaf){lstrcpyA(path,root);lstrcatA(path,leaf);}
static int exists(const char*leaf){local(leaf);return GetFileAttributesA(path)!=INVALID_FILE_ATTRIBUTES;}
static void log_line(const char*s){DWORD n;char line[512];
    wsprintfA(line,"FIRSTBOOT tick=%lu tray=%u %s\r\n",GetTickCount(),FindWindowA("Shell_TrayWnd",0)!=0,s);
    if(journal!=INVALID_HANDLE_VALUE){WriteFile(journal,line,length(line),&n,0);FlushFileBuffers(journal);}}
static int save(const char*leaf,const char*value){HANDLE f;DWORD n,w;int ok;local(leaf);
    f=CreateFileA(path,GENERIC_WRITE,0,0,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,0);
    if(f==INVALID_HANDLE_VALUE)return 0;n=length(value);w=0;
    ok=WriteFile(f,value,n,&w,0)&&w==n&&FlushFileBuffers(f);CloseHandle(f);return ok;}
static int read_local(const char*leaf,char*out,DWORD cap){HANDLE f;DWORD n=0;int ok;local(leaf);
    f=CreateFileA(path,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);if(f==INVALID_HANDLE_VALUE)return 0;
    ok=GetFileSize(f,0)<cap&&ReadFile(f,out,cap-1,&n,0);CloseHandle(f);out[n]=0;return ok;}
static int contains(const char*s,const char*word){const char*a,*b;for(;*s;s++){
    for(a=s,b=word;*a&&*b;a++,b++){char x=*a,y=*b;if(x>='A'&&x<='Z')x+='a'-'A';if(y>='A'&&y<='Z')y+='a'-'A';if(x!=y)break;}
    if(!*b)return 1;}return 0;}
/* A failure never holds the desktop hostage: one closable box, logged.
 * Retry moves FIRSTBT.ERR aside (FIRSTBT.ER1..ER9) and restarts, so the
 * RunOnce that FIRSTBT.BAT re-arms each boot runs the coordinator again;
 * Cancel exits so Explorer starts (the ERR marker keeps later boots quiet). */
static void fail(const char*reason){char aside[MAX_PATH];int i;
    log_line(reason);save("FIRSTBT.ERR",reason);
    if(MessageBoxA(0,"USOS nie m\363g\263 doko\361czy\346 instalacji.\r\nSzczeg\363\263y: C:\\USOS9X\\FIRSTBT.LOG\r\n\r\n"
        "Pon\363w = spr\363buj ponownie po restarcie\r\nAnuluj = przejd\237 do pulpitu","USOS",
        MB_RETRYCANCEL|MB_ICONERROR|MB_SETFOREGROUND|MB_TOPMOST)==IDRETRY){
        local("FIRSTBT.ERR");for(i=1;i<=9;i++){wsprintfA(aside,"%sFIRSTBT.ER%d",root,i);
            if(GetFileAttributesA(aside)==INVALID_FILE_ATTRIBUTES)break;}
        if(i<=9&&MoveFileA(path,aside)){log_line("retry requested: FIRSTBT.ERR moved aside, restarting");
            if(ExitWindowsEx(EWX_REBOOT,0))ExitProcess(2);log_line("retry restart request rejected");}
        else log_line("retry requested but FIRSTBT.ERR could not be moved aside (ER1..ER9 used?)");}
    else log_line("user chose desktop after failure");
    ExitProcess(2);}
static int setup_done(void){HKEY key;DWORD keys=0,values=0;LONG code;
    code=RegOpenKeyExA(HKEY_LOCAL_MACHINE,"Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce\\Setup",0,KEY_READ,&key);
    if(code==ERROR_FILE_NOT_FOUND)return 1;if(code!=ERROR_SUCCESS)return 0;
    code=RegQueryInfoKeyA(key,0,0,0,&keys,0,0,&values,0,0,0,0);RegCloseKey(key);
    return code==ERROR_SUCCESS&&!keys&&!values;}
static int arm(void){HKEY key;const char command[]="C:\\USOS9X\\USOSFB.EXE";LONG code;
    if(RegCreateKeyExA(HKEY_LOCAL_MACHINE,once,0,0,0,KEY_WRITE,0,&key,0)!=ERROR_SUCCESS)return 0;
    code=RegSetValueExA(key,"USOSFirstBoot",0,REG_SZ,(const BYTE*)command,sizeof command);RegCloseKey(key);return code==ERROR_SUCCESS;}
static void reboot(const char*phase,const char*reason){
    if(!arm()||!save("FIRSTBT.STA",phase))fail("cannot persist/arm restart boundary");log_line(reason);
    if(!ExitWindowsEx(EWX_REBOOT|EWX_FORCE,0))fail("restart request rejected");
    /* Never return to Explorer while shutdown messages are being dispatched. */
    {MSG message;while(GetMessageA(&message,0,0,0)>0){TranslateMessage(&message);DispatchMessageA(&message);}}
    fail("restart returned without ending this session");}
static DWORD child(const char*command){STARTUPINFOA si;PROCESS_INFORMATION pi;char cmd[512];DWORD code=999,wait;MSG message;
    log_line(command);lstrcpyA(cmd,command);memset(&si,0,sizeof si);memset(&pi,0,sizeof pi);si.cb=sizeof si;
    if(!CreateProcessA(0,cmd,0,0,FALSE,0,0,0,&si,&pi))return code;CloseHandle(pi.hThread);
    for(;;){wait=MsgWaitForMultipleObjects(1,&pi.hProcess,FALSE,INFINITE,QS_ALLINPUT);
        if(wait==WAIT_OBJECT_0)break;if(wait==WAIT_FAILED){CloseHandle(pi.hProcess);return code;}
        while(PeekMessageA(&message,0,0,0,PM_REMOVE)){if(message.message!=WM_QUIT){TranslateMessage(&message);DispatchMessageA(&message);}}}
    GetExitCodeProcess(pi.hProcess,&code);CloseHandle(pi.hProcess);return code;}
static int legacy_absent(void){HKEY key;LONG code=RegOpenKeyExA(HKEY_LOCAL_MACHINE,"Enum\\Root\\*PNP0900",0,KEY_READ,&key);
    if(code==ERROR_SUCCESS)RegCloseKey(key);return code==ERROR_FILE_NOT_FOUND;}
static int mouse_configured(void){HANDLE f;DWORD n=0;
    if(!exists("USOSVMD.ON"))return 1;
    f=CreateFileA("C:\\WINDOWS\\SYSTEM.INI",GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);
    if(f==INVALID_HANDLE_VALUE)return 0;
    if(!ReadFile(f,text,sizeof text-1,&n,0)){CloseHandle(f);return 0;}CloseHandle(f);text[n]=0;
    return contains(text,"device=C:\\USOS9X\\USOSVMD.VXD");}
static void finish_mouse(void){HKEY key;LONG code;
    if(mouse_configured())return;
    /* Original950 REGEDIT preserves an existing value's position. A B0
     * coordinator can therefore precede the VMDLATE value added in B1.
     * Complete only our known queued INF command before other prerequisites;
     * do not execute arbitrary remaining RunOnce commands or expose a tray. */
    if(!exists("VMDLATE.RUN")||exists("VMDLATE.ERR")||!exists("USOSVMD.INF")||!exists("USOSVMD.VXD"))
        fail("selected DOS-box mouse has no valid queued late command");
    if(child("C:\\WINDOWS\\rundll.exe setupx.dll,InstallHinfSection DefaultInstall 4 C:\\USOS9X\\USOSVMD.INF")!=0)
        fail("queued DOS-box mouse INF failed");
    WritePrivateProfileStringA(0,0,0,"C:\\WINDOWS\\SYSTEM.INI");
    if(!mouse_configured())fail("queued DOS-box mouse INF did not update SYSTEM.INI");
    code=RegOpenKeyExA(HKEY_LOCAL_MACHINE,once,0,KEY_SET_VALUE,&key);
    if(code==ERROR_SUCCESS){code=RegDeleteValueA(key,"USOSVmd");RegCloseKey(key);}
    if(code!=ERROR_SUCCESS&&code!=ERROR_FILE_NOT_FOUND)fail("cannot retire completed DOS-box mouse RunOnce value");
    log_line("queued DOS-box mouse INF completed before packages; driver starts at final restart");}
/* TZFIX.BAT (tools/w9x_tzfix.sh): TZDST.OK after its late summer-time
 * step; nothing deferred (TZFIX.OK without TZDST.PND, e.g. an older
 * not-pending TZFIX that wrote no TZDST.OK) or no TZFIX staged is ready too. */
static int tz_ready(void){
    if(exists("TZDST.OK")||!exists("TZFIX.BAT"))return 1;
    return exists("TZFIX.OK")&&!exists("TZDST.PND");}
static int late_ready(void){
    if(!exists("VLATE.OK")||!tz_ready()||!exists("REG95.OK")){log_line("late: display/time zone/registry marker missing");return 0;}
    if(exists("R95LATE.REG")&&!exists("R95LATE.OK")){log_line("late: IE registry import missing");return 0;}
    if(exists("VLATE.ERR")||exists("TZFIX.BAD")||exists("R95LATE.ERR")||exists("VMDLATE.ERR")){log_line("late: real-mode error marker present");return 0;}
    if(exists("NET\\NET95.REG")&&(!exists("NET\\NET95.OK")||!exists("NET\\NLATE.OK")||!exists("NET\\NFILES.OK"))){log_line("late: network preparation incomplete");return 0;}
    if(!mouse_configured()){log_line("late: selected DOS-box mouse missing in SYSTEM.INI");return 0;}
    if(!legacy_absent()){log_line("late: legacy display still present");return 0;}return 1;}
/* IE 5.5 SP2 leaves its DLL registrations in HKLM RunOnceEx for
 * iernonce.dll. On the X470 95 RTM fresh install (2026-10-26) no RunOnce
 * value ever ran them. After every coordinator restart, pending RunOnceEx
 * sections are processed here, before packages or the desktop: also when an
 * iernonce RunOnce value exists, since ordinary RunOnce would run it only
 * after this synchronous coordinator (it then finds nothing left to do). */
static DWORD ex_sections(void){HKEY key;DWORD keys=0;
    if(RegOpenKeyExA(HKEY_LOCAL_MACHINE,"Software\\Microsoft\\Windows\\CurrentVersion\\RunOnceEx",0,KEY_READ,&key)!=ERROR_SUCCESS)return 0;
    if(RegQueryInfoKeyA(key,0,0,0,&keys,0,0,0,0,0,0,0)!=ERROR_SUCCESS)keys=0;RegCloseKey(key);return keys;}
static int iernonce_queued(void){HKEY key;DWORD i,n,size,type;char name[128];int found=0;
    if(RegOpenKeyExA(HKEY_LOCAL_MACHINE,once,0,KEY_READ,&key)!=ERROR_SUCCESS)return 0;
    for(i=0;i<64&&!found;i++){n=sizeof name;size=sizeof text-1;
        if(RegEnumValueA(key,i,name,&n,0,&type,(BYTE*)text,&size)!=ERROR_SUCCESS)break;
        text[size<sizeof text?size:sizeof text-1]=0;found=type==REG_SZ&&(contains(text,"iernonce")||contains(text,"RunOnceEx"));}
    RegCloseKey(key);return found;}
static void finish_runonceex(void){DWORD before=ex_sections(),code;char line[160];
    if(!before){log_line("RunOnceEx: nothing pending");return;}
    if(GetFileAttributesA("C:\\WINDOWS\\SYSTEM\\iernonce.dll")==INVALID_FILE_ATTRIBUTES){log_line("RunOnceEx pending but iernonce.dll missing; left alone");return;}
    log_line(iernonce_queued()?"RunOnceEx pending; its iernonce RunOnce value would run after this coordinator, processing it now":
        "RunOnceEx pending without an iernonce RunOnce value; processing it now");
    code=child("rundll32.exe C:\\WINDOWS\\SYSTEM\\iernonce.dll,RunOnceExProcess");
    wsprintfA(line,"RunOnceEx: iernonce exit %lu, sections %lu -> %lu",code,before,ex_sections());log_line(line);}
/* 950 Setup writes Network\Logon PrimaryProvider "Microsoft Network" although
 * the answer asks for Windows Logon; FIRSTBT.BAT removes the key in real mode
 * on every boot until FIRSTBT.OK, this is the last removal before the desktop. */
static void windows_logon(void){HKEY key;LONG code;char line[96];
    code=RegOpenKeyExA(HKEY_LOCAL_MACHINE,"Network\\Logon",0,KEY_SET_VALUE,&key);
    if(code==ERROR_SUCCESS){code=RegDeleteValueA(key,"PrimaryProvider");RegCloseKey(key);}
    if(code==ERROR_SUCCESS)lstrcpyA(line,"Network\\Logon PrimaryProvider removed");
    else if(code==ERROR_FILE_NOT_FOUND)lstrcpyA(line,"Network\\Logon PrimaryProvider absent");
    else wsprintfA(line,"Network\\Logon PrimaryProvider not removed (code %ld)",code);
    log_line(line);}
/* FIRSTBT.STA phases: late, install, mid1..mid4 (USOSADD exit 1001: a package
 * restart the chain asked for), resume1..resume4, reboot (the final one).
 * 950: DCOM95 and IE 5.5 SP2 restart (reboot_setup=now), one more for a
 * package retried after a restart (Q810847 check_setup), one spare. */
static int mid_phase(const char*phase){
    if(phase[0]=='m'&&phase[1]=='i'&&phase[2]=='d'&&phase[3]>='1'&&phase[3]<='4'&&phase[4]=='\r'&&phase[5]=='\n'&&!phase[6])return phase[3]-'0';
    return 0;}
void __cdecl fb_start(void){OSVERSIONINFOA version;char phase[32],next[16],note[64];DWORD code;HKEY key;int mid;
    local("FIRSTBT.LOG");journal=CreateFileA(path,GENERIC_WRITE,FILE_SHARE_READ,0,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,0);
    if(journal==INVALID_HANDLE_VALUE)ExitProcess(2);SetFilePointer(journal,0,0,FILE_END);
    memset(&version,0,sizeof version);version.dwOSVersionInfoSize=sizeof version;
    if(!GetVersionExA(&version)||version.dwPlatformId!=VER_PLATFORM_WIN32_WINDOWS||version.dwMajorVersion!=4||
       version.dwMinorVersion!=0||(version.dwBuildNumber&0xffff)!=950||!exists("FIRSTBT.ON")||!exists("PHASE1.OK"))fail("source950/phase1 scope refused");
    if(exists("FIRSTBT.OK")){log_line("already complete");ExitProcess(0);}
    if(exists("FIRSTBT.ERR")){log_line("previous firstboot failure; automatic retry refused (FIRSTBT.ERR present)");ExitProcess(2);}
    log_line("coordinator entered before desktop");
    if(FindWindowA("Shell_TrayWnd",0))fail("ordinary RunOnce started after desktop");
    if(!setup_done())fail("original RunOnce Setup has not completed");
    phase[0]=0;if(exists("FIRSTBT.STA")&&!read_local("FIRSTBT.STA",phase,sizeof phase))fail("cannot read phase journal");
    if(!exists("VLATE.OK")||!tz_ready()){
        if(phase[0])fail("late real-mode preparation did not complete after Setup transition");
        reboot("late\r\n","restart: Setup transition before late DOS preparation");}
    finish_mouse();
    if(!late_ready())fail("late prerequisites or single display check failed");
    if(!lstrcmpA(phase,"reboot\r\n")){
        if(exists("VMDLATE.BAT")&&!exists("VMDLATE.OK"))fail("DOS mouse final restart check failed");
        finish_runonceex();
        if(GetFileAttributesA("C:\\USOS\\ADDONS\\SELECT.INI")!=INVALID_FILE_ATTRIBUTES&&
           child("C:\\USOS\\ADDONS\\USOSADD.EXE /setup /check")!=0)fail("final package checks incomplete");
        if(exists("NETCFG.INI")&&child("C:\\USOS9X\\USOSLAN.EXE /setup /refresh")!=0)fail("final IE/network defaults incomplete");
        windows_logon();
        if(!save("FIRSTBT.OK","complete; final_post_addons_restarts=1\r\n"))fail("cannot save completion");
        if(RegOpenKeyExA(HKEY_LOCAL_MACHINE,once,0,KEY_SET_VALUE,&key)==ERROR_SUCCESS){RegDeleteValueA(key,"USOSFirstBoot");RegCloseKey(key);}
        log_line("complete: releasing first desktop; final_post_addons_restarts=1");CloseHandle(journal);ExitProcess(0);
    }
    mid=mid_phase(phase);
    if(phase[0]&&lstrcmpA(phase,"late\r\n")&&!mid)fail("unknown phase; automatic retry refused");
    if(mid){
        wsprintfA(note,"resume after package restart %d before the desktop",mid);log_line(note);
        finish_runonceex();
        wsprintfA(next,"resume%d\r\n",mid);
        if(!save("FIRSTBT.STA",next))fail("cannot journal package resume boundary");
    }else{
        if(!save("FIRSTBT.STA","install\r\n"))fail("cannot journal package boundary");
        if(exists("USOSRES.EXE")){
            if(child("C:\\USOS9X\\USOSRES.EXE /setup")!=0||!read_local("DISPLAY.DONE",text,sizeof text)||
               (!contains(text,"DISPLAY applied")&&!contains(text,"DISPLAY saved; restart required")&&!contains(text,"DISPLAY already at the selected mode")))fail("display request not applied before packages");}
    }
    if(GetFileAttributesA("C:\\USOS\\ADDONS\\SELECT.INI")!=INVALID_FILE_ATTRIBUTES){
        code=child("C:\\USOS\\ADDONS\\USOSADD.EXE /setup");
        if(code==1001){
            /* The chain asked for a restart (DCOM95 / IE 5.5 SP2 reboot_setup=now, or
             * a retry after a restart): restart, keep holding the desktop,
             * resume the chain from STATE.INI. */
            if(mid>=4)fail("more than four package restarts before the desktop");
            wsprintfA(next,"mid%d\r\n",mid+1);wsprintfA(note,"restart: package restart %d before the desktop",mid+1);
            reboot(next,note);}
        if(code!=0&&code!=3010)fail("packages did not finish before final restart");}
    reboot("reboot\r\n","restart: sole final post-addons restart");
}
