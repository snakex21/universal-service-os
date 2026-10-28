/* Windows 95 / 98 first-desktop coordinator (95 RTM / OSR1 4.00.950, OSR2 /
 * OSR2.1 / OSR2.5 4.00.1111..1216, 98 FE 4.10.1998, 98 SE 4.10.2222).
 * USOS, GPL-3.0-or-later.
 * Ordinary RunOnce is synchronous before Shell_TrayWnd on Windows95 RTM;
 * the first boot after Setup still starts the coordinator from it. The
 * package boots after it run with this program as the Windows shell (see
 * shell_set), the final boot under Explorer again.
 * Its persistent phase belongs beside the program, never in a user profile.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
static const char root[]="C:\\USOS9X\\";
static const char once[]="Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce";
static const char sysini[]="C:\\WINDOWS\\SYSTEM.INI";
static const char fbexe[]="C:\\USOS9X\\USOSFB.EXE";
static HANDLE journal=INVALID_HANDLE_VALUE;
static char path[MAX_PATH],text[8192];
static int shell_mode,win98;
void *memset(void *p,int v,unsigned n){BYTE*b=p;while(n--)*b++=(BYTE)v;return p;}
static unsigned length(const char*s){unsigned n=0;while(s[n])n++;return n;}
static void local(const char*leaf){lstrcpyA(path,root);lstrcatA(path,leaf);}
static int exists(const char*leaf){local(leaf);return GetFileAttributesA(path)!=INVALID_FILE_ATTRIBUTES;}
static void log_line(const char*s){DWORD n;char line[1100];
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
static void drop(const char*leaf){local(leaf);DeleteFileA(path);}
static int contains_n(const char*s,const char*word,unsigned n){unsigned i;
    for(i=0;i<n;i++){char x=s[i],y=word[i];if(x>='A'&&x<='Z')x+='a'-'A';if(x!=y)return 0;}return 1;}
/* The journal's first line of every start, written and flushed before any
 * other work (X470 98 FE PL 2026-10-28: a boot died before any record, so
 * whether this program was started at all stayed unknown). */
static void start_line(void){char phase[32],line[96];unsigned i;
    phase[0]=0;if(exists("FIRSTBT.STA")&&!read_local("FIRSTBT.STA",phase,sizeof phase))lstrcpyA(phase,"unreadable");
    for(i=0;phase[i];i++)if(phase[i]=='\r'||phase[i]=='\n'){phase[i]=0;break;}
    wsprintfA(line,"USOSFB start, phase %s",phase[0]?phase:"none (no FIRSTBT.STA)");log_line(line);}
static DWORD child(const char*command);
static const char*running;  /* command line of the child being waited for */
static int arm(void);
/* A hidden top-level window: WM_ENDSESSION while a child runs means some
 * process restarted Windows under it (an installer inside USOSADD whose
 * restart could not be refused). FIRSTBT.STA already names this boundary;
 * the RunOnce value is armed again and SHELLRUN.FLG goes, so the next boot
 * resumes it as a shell boot instead of FIRSTBT.BAT's "ended without its
 * own restart" fallback. The restart itself is never refused here. */
static LRESULT CALLBACK session_proc(HWND w,UINT msg,WPARAM wp,LPARAM lp){char line[1100];
    if(msg==WM_ENDSESSION&&wp&&running){
        wsprintfA(line,"session ends while a child runs (%.900s): phase kept, armed for the next boot",running);
        log_line(line);arm();drop("SHELLRUN.FLG");return 0;}
    return DefWindowProcA(w,msg,wp,lp);}
static void session_window(void){WNDCLASSA wc;HINSTANCE inst=GetModuleHandleA(0);
    memset(&wc,0,sizeof wc);wc.lpfnWndProc=session_proc;wc.hInstance=inst;wc.lpszClassName="USOSFBSession";RegisterClassA(&wc);
    if(!CreateWindowExA(0,"USOSFBSession","USOSFB",WS_POPUP,0,0,0,0,0,0,inst,0))log_line("session window not created");}
/* Package boots run with SYSTEM.INI [boot] shell=C:\USOS9X\USOSFB.EXE, so no
 * Explorer exists and no desktop can appear however long a package takes.
 * X470 95 OSR1 EN (SHELL32 4.00.951, 2026-10-27): Explorer stopped waiting
 * for this RunOnce child ~6 s into the second package run (FIRSTBT.LOG
 * tray=1); RTM never did (tray=0). The value is swapped in place by the
 * profile API; the final restart puts shell=Explorer.exe back, so the last
 * boot's RunOnce (InstMsi1, VC registrations, this program) runs under
 * Explorer as before. SHELL.ON beside the program tells FIRSTBT.BAT to
 * rebuild shell=Explorer.exe in real mode (SHELLHDR.INI + SYSTEM.INI without
 * its [boot] line and our shell line) if this program is gone, finished or
 * failed, or a shell boot ended without its own restart (SHELLRUN.FLG left
 * over; that also writes SHELL.BAD, which keeps later boots under Explorer's
 * RunOnce). Hence shell mode only for a SYSTEM.INI that starts with [boot]
 * and holds shell=Explorer.exe, and only with SHELLHDR.INI staged. */
static int ini_text(void){HANDLE f;DWORD n=0;int ok;
    WritePrivateProfileStringA(0,0,0,sysini);
    f=CreateFileA(sysini,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);if(f==INVALID_HANDLE_VALUE)return 0;
    ok=GetFileSize(f,0)<sizeof text&&ReadFile(f,text,sizeof text-1,&n,0);CloseHandle(f);text[n]=0;return ok;}
static int usos_shell(void){char value[MAX_PATH];
    GetPrivateProfileStringA("boot","shell","",value,sizeof value,sysini);return !lstrcmpiA(value,fbexe);}
static int boot_first(void){const char*h="[boot]\r\n";int i;
    for(i=0;h[i];i++){char c=text[i];if(c>='A'&&c<='Z')c+='a'-'A';if(c!=h[i])return 0;}return 1;}
static int shell_set(int usos){char value[MAX_PATH];
    GetPrivateProfileStringA("boot","shell","",value,sizeof value,sysini);
    if(!usos){
        if(!lstrcmpiA(value,fbexe)){
            if(!WritePrivateProfileStringA("boot","shell","Explorer.exe",sysini)||!ini_text()||contains(text,"USOSFB.EXE"))return 0;
            log_line("SYSTEM.INI [boot] shell=Explorer.exe restored");}
        drop("SHELL.ON");return 1;}
    if(lstrcmpiA(value,fbexe)){
        if(lstrcmpiA(value,"Explorer.exe")){log_line("shell mode refused: SYSTEM.INI [boot] shell= is not Explorer.exe");return 0;}
        if(!exists("SHELLHDR.INI")){log_line("shell mode refused: SHELLHDR.INI (real-mode restore) not staged");return 0;}
        if(!ini_text()||!boot_first()){log_line("shell mode refused: SYSTEM.INI unreadable or not starting with [boot]");return 0;}
        if(!save("SHELL.ON","SYSTEM.INI [boot] shell=C:\\USOS9X\\USOSFB.EXE until the final restart; was shell=Explorer.exe\r\n")||
           !WritePrivateProfileStringA("boot","shell",fbexe,sysini))return 0;}
    return ini_text()&&contains(text,"shell=C:\\USOS9X\\USOSFB.EXE");}
/* Leave without a desktop to return to: in shell mode no Explorer runs, so
 * put it back and restart (FIRSTBT.OK/FIRSTBT.ERR then end the next run at
 * once); start Explorer only if the restart is refused. */
static void leave(DWORD code){
    if(shell_mode){
        if(!shell_set(0))log_line("WARNING: SYSTEM.INI shell= not restored; FIRSTBT.BAT restores it in real mode");
        drop("SHELLRUN.FLG");log_line("shell mode: restarting so that Explorer starts");
        if(ExitWindowsEx(EWX_REBOOT,0))ExitProcess(code);
        log_line("restart request rejected; starting Explorer");child("C:\\WINDOWS\\EXPLORER.EXE");}
    ExitProcess(code);}
/* A failure never holds the desktop hostage: one closable box, logged.
 * Retry moves FIRSTBT.ERR aside (FIRSTBT.ER1..ER9) and restarts, so the
 * RunOnce that FIRSTBT.BAT re-arms each boot runs the coordinator again;
 * Cancel exits so Explorer starts (the ERR marker keeps later boots quiet). */
/* The box in the language of the installed system (RTM PL, OSR1 EN): Polish
 * for a Polish system locale (primary language 0x15, as USOSADD decides),
 * else English. Retry/Cancel are Windows' own buttons in that language. */
static const char fail_pl[]="USOS nie m\363g\263 doko\361czy\346 instalacji.\r\nSzczeg\363\263y: C:\\USOS9X\\FIRSTBT.LOG\r\n\r\n"
    "Pon\363w = spr\363buj ponownie po restarcie\r\nAnuluj = przejd\237 do pulpitu";
static const char fail_en[]="USOS could not finish the installation.\r\nDetails: C:\\USOS9X\\FIRSTBT.LOG\r\n\r\n"
    "Retry = try again after a restart\r\nCancel = go to the desktop";
static void fail(const char*reason){char aside[MAX_PATH];int i;
    log_line(reason);save("FIRSTBT.ERR",reason);
    if(!shell_set(0))log_line("WARNING: SYSTEM.INI shell= not restored; FIRSTBT.BAT restores it in real mode (FIRSTBT.ERR)");
    drop("SHELLRUN.FLG");
    if(MessageBoxA(0,(GetSystemDefaultLangID()&0x3ff)==0x15?fail_pl:fail_en,"USOS",
        MB_RETRYCANCEL|MB_ICONERROR|MB_SETFOREGROUND|MB_TOPMOST)==IDRETRY){
        local("FIRSTBT.ERR");for(i=1;i<=9;i++){wsprintfA(aside,"%sFIRSTBT.ER%d",root,i);
            if(GetFileAttributesA(aside)==INVALID_FILE_ATTRIBUTES)break;}
        if(i<=9&&MoveFileA(path,aside)){log_line("retry requested: FIRSTBT.ERR moved aside, restarting");
            if(ExitWindowsEx(EWX_REBOOT,0))ExitProcess(2);log_line("retry restart request rejected");}
        else log_line("retry requested but FIRSTBT.ERR could not be moved aside (ER1..ER9 used?)");}
    else log_line("user chose desktop after failure");
    leave(2);}
static int setup_done(void){HKEY key;DWORD keys=0,values=0;LONG code;
    code=RegOpenKeyExA(HKEY_LOCAL_MACHINE,"Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce\\Setup",0,KEY_READ,&key);
    if(code==ERROR_FILE_NOT_FOUND)return 1;if(code!=ERROR_SUCCESS)return 0;
    code=RegQueryInfoKeyA(key,0,0,0,&keys,0,0,&values,0,0,0,0);RegCloseKey(key);
    return code==ERROR_SUCCESS&&!keys&&!values;}
static int arm(void){HKEY key;const char command[]="C:\\USOS9X\\USOSFB.EXE";LONG code;
    if(RegCreateKeyExA(HKEY_LOCAL_MACHINE,once,0,0,0,KEY_WRITE,0,&key,0)!=ERROR_SUCCESS)return 0;
    code=RegSetValueExA(key,"USOSFirstBoot",0,REG_SZ,(const BYTE*)command,sizeof command);RegCloseKey(key);return code==ERROR_SUCCESS;}
/* ExitWindowsEx refused while another shutdown is already in progress
 * (X470 98 FE PL 2026-10-27: WMP 7.1's setup_wm restarted Windows itself;
 * this restart was "rejected", FIRSTBT.ERR then stopped every later boot).
 * The phase is journalled and the value armed, so that shutdown's next
 * boot resumes: no FIRSTBT.ERR. Only a session still alive a minute later
 * gets one more request, and fails if that is refused too. */
static void rejected(void){char line[160];DWORD start=GetTickCount(),gone;MSG message;
    wsprintfA(line,"restart request rejected (error %lu): another shutdown may be in progress; FIRSTBT.STA kept, no FIRSTBT.ERR, waiting up to 60 s",GetLastError());
    log_line(line);
    while((gone=GetTickCount()-start)<60000){MsgWaitForMultipleObjects(0,0,FALSE,60000-gone,QS_ALLINPUT);
        while(PeekMessageA(&message,0,0,0,PM_REMOVE)){TranslateMessage(&message);DispatchMessageA(&message);}}
    log_line("session still running a minute after the rejected restart: one more restart request");
    if(!ExitWindowsEx(EWX_REBOOT|EWX_FORCE,0))fail("restart request rejected twice");}
static void reboot(const char*phase,const char*reason){int last=!lstrcmpA(phase,"reboot\r\n");
    if(last){
        if(!shell_set(0))fail("cannot restore SYSTEM.INI shell=Explorer.exe before the final restart");
        log_line("final boot: Explorer is the shell again and processes RunOnce before this coordinator");}
    else if(!exists("SHELL.BAD")){
        if(shell_set(1)&&save("SHELL.TRY",phase))log_line("next boot: SYSTEM.INI [boot] shell=C:\\USOS9X\\USOSFB.EXE (no Explorer, no desktop)");
        else{save("SHELL.BAD","shell=USOSFB could not be set\r\n");shell_set(0);
            log_line("shell mode unavailable; the next boot starts this coordinator from Explorer's RunOnce");}}
    if(!arm()||!save("FIRSTBT.STA",phase))fail("cannot persist/arm restart boundary");log_line(reason);
    drop("SHELLRUN.FLG");
    if(!ExitWindowsEx(EWX_REBOOT|EWX_FORCE,0))rejected();
    /* Never return to Explorer while shutdown messages are being dispatched. */
    {MSG message;while(GetMessageA(&message,0,0,0)>0){TranslateMessage(&message);DispatchMessageA(&message);}}
    fail("restart returned without ending this session");}
/* A taskbar that appears while a child runs means Explorer no longer waits
 * for this coordinator (OSR1 under RunOnce): logged once, with the tick. */
static DWORD child(const char*command){STARTUPINFOA si;PROCESS_INFORMATION pi;char cmd[1024];DWORD code=999,wait;MSG message;int tray;
    log_line(command);running=command;lstrcpynA(cmd,command,sizeof cmd);memset(&si,0,sizeof si);memset(&pi,0,sizeof pi);si.cb=sizeof si;
    if(!CreateProcessA(0,cmd,0,0,FALSE,0,0,0,&si,&pi)){log_line("child not started");return code;}CloseHandle(pi.hThread);
    tray=FindWindowA("Shell_TrayWnd",0)!=0;
    for(;;){wait=MsgWaitForMultipleObjects(1,&pi.hProcess,FALSE,500,QS_ALLINPUT);
        if(wait==WAIT_OBJECT_0)break;if(wait==WAIT_FAILED){CloseHandle(pi.hProcess);return code;}
        if(!tray&&FindWindowA("Shell_TrayWnd",0)){tray=1;
            log_line("WARNING: desktop taskbar (Shell_TrayWnd) appeared while this child runs: Explorer stopped waiting for the coordinator");}
        while(PeekMessageA(&message,0,0,0,PM_REMOVE)){if(message.message!=WM_QUIT){TranslateMessage(&message);DispatchMessageA(&message);}}}
    GetExitCodeProcess(pi.hProcess,&code);CloseHandle(pi.hProcess);running=0;return code;}
static int legacy_absent(void){HKEY key;LONG code=RegOpenKeyExA(HKEY_LOCAL_MACHINE,"Enum\\Root\\*PNP0900",0,KEY_READ,&key);
    if(code==ERROR_SUCCESS)RegCloseKey(key);return code==ERROR_FILE_NOT_FOUND;}
/* 950: the late binding of VESALATE.BAT (VLATE.OK). OSR2 stages no
 * VESALATE (its PnP drops the legacy display itself): VESA95.BAT had its
 * one attempt before the first GUI start (VESA95.OK, or VESA95.BAD with
 * Setup's display kept), or none is staged. */
static int display_ready(void){
    if(exists("VESALATE.BAT"))return exists("VLATE.OK");
    return exists("VESA95.OK")||exists("VESA95.BAD")||!exists("VESA95.BAT");}
/* GetVersionEx 4.00 build: 950 (RTM / OSR1) or the OSR2 family (OSR2 /
 * OSR2.1 1111, OSR2.5 1212..1216); 4.10 build: 98 FE 1998 or 98 SE 2222.
 * Me (4.90) runs no AUTOEXEC.BAT, so FIRSTBT.BAT never arms it. */
static int coordinated_build(DWORD minor,DWORD build){build&=0xffff;
    if(minor==0)return build==950||build==1111||build==1212||build==1214||build==1216;
    return minor==10&&(build==1998||build==2222);}
/* The REG95 / VMDLATE RunOnce value USOSVmd with our INF command, still queued. */
static int vmd_queued(void){HKEY key;DWORD size=sizeof text-1,type;LONG code;
    if(RegOpenKeyExA(HKEY_LOCAL_MACHINE,once,0,KEY_READ,&key)!=ERROR_SUCCESS)return 0;
    code=RegQueryValueExA(key,"USOSVmd",0,&type,(BYTE*)text,&size);RegCloseKey(key);
    if(code!=ERROR_SUCCESS||type!=REG_SZ)return 0;text[size<sizeof text?size:sizeof text-1]=0;
    return contains(text,"C:\\USOS9X\\USOSVMD.INF");}
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
    /* OSR2 has no VMDLATE: REG95.REG queued USOSVmd before the first GUI
     * boot; if that boot's Explorer did not run it, it is still queued. */
    if(!(exists("VMDLATE.RUN")||(!exists("VMDLATE.BAT")&&vmd_queued()))||exists("VMDLATE.ERR")||
       !exists("USOSVMD.INF")||!exists("USOSVMD.VXD"))
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
/* 98 / 98 SE: Setup applies MSBATCH.INF [Install] AddReg and installs
 * TCP/IP itself, so there is no REG95.BAT (REG95.OK) and no NET95 step;
 * a stray NET95.REG there is not ours to wait for. */
static int late_ready(void){
    if(!display_ready()||!tz_ready()||(!win98&&!exists("REG95.OK"))){log_line("late: display/time zone/registry marker missing");return 0;}
    if(exists("R95LATE.REG")&&!exists("R95LATE.OK")){log_line("late: IE registry import missing");return 0;}
    if(exists("VLATE.ERR")||exists("TZFIX.BAD")||exists("R95LATE.ERR")||exists("VMDLATE.ERR")){log_line("late: real-mode error marker present");return 0;}
    if(!win98&&exists("NET\\NET95.REG")&&(!exists("NET\\NET95.OK")||!exists("NET\\NLATE.OK")||!exists("NET\\NFILES.OK"))){log_line("late: network preparation incomplete");return 0;}
    if(!mouse_configured()){log_line("late: selected DOS-box mouse missing in SYSTEM.INI");return 0;}
    if(!legacy_absent()){log_line("late: legacy display still present");return 0;}return 1;}
/* Explorer's part in a shell boot. On 95 RTM Explorer ran the values that
 * packages queued before the next coordinator start (X470 PL 2026-10-27:
 * after IE 5.5 its RunOnceEx value ran first, FIRSTBT.LOG "RunOnceEx:
 * nothing pending"; DCOM95's IExpressRegOCX/GrpConv before IE): the values
 * queued behind ours, because Explorer deletes ours and arm() appends it
 * again at each restart. Same order here: HKLM RunOnce values in registry
 * order, each deleted before its command starts, one at a time and waited
 * for. Our own value is only deleted (reboot() arms it again behind what
 * packages queue next); USOSVmd stays for finish_mouse. HKLM Run and the
 * HKCU keys wait for the final Explorer boot, as before: the coordinator
 * always restarted before Explorer reached them. */
static void run_once_values(void){HKEY key;DWORD index=0,n,size,type,code;int done=0;char name[128],cmd[1024],line[300];
    SetCurrentDirectoryA("C:\\WINDOWS");
    while(done<64){
        if(RegOpenKeyExA(HKEY_LOCAL_MACHINE,once,0,KEY_READ|KEY_SET_VALUE,&key)!=ERROR_SUCCESS)break;
        n=sizeof name;size=sizeof cmd-1;code=RegEnumValueA(key,index,name,&n,0,&type,(BYTE*)cmd,&size);
        if(code!=ERROR_SUCCESS){RegCloseKey(key);
            if(code!=ERROR_NO_MORE_ITEMS){wsprintfA(line,"RunOnce: value %lu unreadable (code %lu); the rest waits for the final Explorer boot",index,code);log_line(line);}
            break;}
        cmd[size<sizeof cmd?size:sizeof cmd-1]=0;
        if(!lstrcmpiA(name,"USOSVmd")){RegCloseKey(key);index++;continue;}
        code=RegDeleteValueA(key,name);RegCloseKey(key);
        if(code!=ERROR_SUCCESS){wsprintfA(line,"RunOnce %s not deleted (code %lu); not run, the rest waits for the final Explorer boot",name,code);log_line(line);break;}
        done++;
        if(!lstrcmpiA(name,"USOSFirstBoot")){log_line("RunOnce USOSFirstBoot: own value deleted, armed again at the next restart");continue;}
        if(type!=REG_SZ||!cmd[0]){wsprintfA(line,"RunOnce %s: no command, deleted",name);log_line(line);continue;}
        wsprintfA(line,"RunOnce %s, as Explorer runs it before the desktop:",name);log_line(line);
        code=child(cmd);wsprintfA(line,"RunOnce %s exit %lu",name,code);log_line(line);}
    if(done>=64)log_line("RunOnce: 64 values handled, the rest waits for the next boot");}
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
 * on every boot until FIRSTBT.OK, this is the last removal before the desktop.
 * 98 keeps the logon provider its Setup chose from the answer. */
static void windows_logon(void){HKEY key;LONG code;char line[96];
    if(win98){log_line("98: Network\\Logon left as Setup wrote it");return;}
    code=RegOpenKeyExA(HKEY_LOCAL_MACHINE,"Network\\Logon",0,KEY_SET_VALUE,&key);
    if(code==ERROR_SUCCESS){code=RegDeleteValueA(key,"PrimaryProvider");RegCloseKey(key);}
    if(code==ERROR_SUCCESS)lstrcpyA(line,"Network\\Logon PrimaryProvider removed");
    else if(code==ERROR_FILE_NOT_FOUND)lstrcpyA(line,"Network\\Logon PrimaryProvider absent");
    else wsprintfA(line,"Network\\Logon PrimaryProvider not removed (code %ld)",code);
    log_line(line);}
/* USOSADD's STATE.INI with a package still "running" (an installer
 * restarted Windows inside it, X470 98 FE PL 2026-10-27 wmp71-pl=running:1,
 * or a retry deferred to a restart), or a clean exit without the CHAIN.END
 * that its last /setup run writes at the end of the chain: the chain is not
 * complete, so the restart is a package restart, never the final one. The
 * id of the first running package goes into why. 1 = running, 2 = no end. */
static int running_entry(const char*s,char*why,unsigned cap){const char*l,*e;unsigned i;
    why[0]=0;
    for(l=s;*l;l=*e?e+1:e){for(e=l;*e&&*e!='\n';e++);
        for(i=0;l+i<e&&l[i]!='=';i++);
        if(l+i<e&&i&&l[0]!=';'&&l[0]!='['&&e-(l+i+1)>=7&&contains_n(l+i+1,"running",7)){
            if(i>=cap)i=cap-1;lstrcpynA(why,l,i+1);return 1;}}
    return 0;}
static int chain_open(char*why,unsigned cap){HANDLE f;DWORD n=0;
    f=CreateFileA("C:\\USOS\\ADDONS\\STATE.INI",GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);
    if(f!=INVALID_HANDLE_VALUE){if(!ReadFile(f,text,sizeof text-1,&n,0))n=0;CloseHandle(f);}
    text[n]=0;if(running_entry(text,why,cap))return 1;
    return GetFileAttributesA("C:\\USOS\\ADDONS\\CHAIN.END")==INVALID_FILE_ATTRIBUTES?2:0;}
/* FIRSTBT.STA phases: late, install, mid1..mid9 (USOSADD exit 1001: a package
 * restart the chain asked for), resume1..resume9, reboot (the final one).
 * 95 allows four: 950's DCOM95 and IE 5.5 SP2 restart (reboot_setup=now),
 * one more for a package retried after a restart (Q810847 check_setup), one
 * spare. 98 allows nine: the reboot=now packages of legacy-pack.ini (kept
 * under /setup) are DCOM98, DUN 1.4 and IE 6 SP1, on 98 SE also Q243199
 * and WMP 9, plus the options (ASPI, DS client, KernelEx) and retries. */
static int mid_limit(void){return win98?9:4;}
static int mid_phase(const char*phase){
    if(phase[0]=='m'&&phase[1]=='i'&&phase[2]=='d'&&phase[3]>='1'&&phase[3]-'0'<=mid_limit()&&phase[4]=='\r'&&phase[5]=='\n'&&!phase[6])return phase[3]-'0';
    /* resumeN: the boot ended inside that package boundary (an installer
     * restart USOSADD could not refuse): the same boundary runs again. */
    if(contains_n(phase,"resume",6)&&phase[6]>='1'&&phase[6]-'0'<=mid_limit()&&phase[7]=='\r'&&phase[8]=='\n'&&!phase[9])return phase[6]-'0';
    return 0;}
void __cdecl fb_start(void){OSVERSIONINFOA version;char phase[32],next[16],note[64];DWORD code;HKEY key;int mid;
    local("FIRSTBT.LOG");journal=CreateFileA(path,GENERIC_WRITE,FILE_SHARE_READ,0,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,0);
    if(journal!=INVALID_HANDLE_VALUE){SetFilePointer(journal,0,0,FILE_END);start_line();}
    shell_mode=usos_shell();
    if(journal==INVALID_HANDLE_VALUE)leave(2);
    session_window();
    if(shell_mode){save("SHELLRUN.FLG","USOSFB shell boot running; deleted before its own restart\r\n");drop("SHELL.TRY");
        log_line("running as the Windows shell (SYSTEM.INI [boot] shell=C:\\USOS9X\\USOSFB.EXE): no Explorer, no desktop in this boot");}
    else if(exists("SHELL.TRY")){drop("SHELL.TRY");save("SHELL.BAD","shell=USOSFB was set but Explorer started\r\n");
        log_line("WARNING: shell=USOSFB was set for this boot but Explorer started; package boots stay under Explorer's RunOnce");}
    memset(&version,0,sizeof version);version.dwOSVersionInfoSize=sizeof version;
    if(!GetVersionExA(&version)||version.dwPlatformId!=VER_PLATFORM_WIN32_WINDOWS||version.dwMajorVersion!=4||
       !coordinated_build(version.dwMinorVersion,version.dwBuildNumber)||!exists("FIRSTBT.ON")||!exists("PHASE1.OK"))
        fail("95 (950 / OSR2) / 98 (1998 / 2222) / phase1 scope refused");
    win98=version.dwMinorVersion==10;
    if(exists("FIRSTBT.OK")){log_line("already complete");leave(0);}
    if(exists("FIRSTBT.ERR")){log_line("previous firstboot failure; automatic retry refused (FIRSTBT.ERR present)");leave(2);}
    log_line("coordinator entered before desktop");
    /* 98, first start under Explorer's RunOnce (no FIRSTBT.STA yet; not yet
     * seen on hardware). A taskbar only means Explorer did not wait for
     * RunOnce: this start installs nothing and restarts into a shell boot at
     * once. A RunOnce\Setup list still there (98 Setup restarts inside it)
     * is waited out without FIRSTBT.ERR: FIRSTBT.BAT arms the next boot. */
    if(win98&&!shell_mode&&!exists("FIRSTBT.STA")){
        if(!setup_done()){log_line("98: original RunOnce Setup not finished; the coordinator starts again at the next boot");leave(0);}
        if(FindWindowA("Shell_TrayWnd",0))log_line("WARNING: 98 taskbar present at the first coordinator start; restarting into a shell boot");}
    else if(FindWindowA("Shell_TrayWnd",0))fail("ordinary RunOnce started after desktop");
    if(!setup_done())fail("original RunOnce Setup has not completed");
    phase[0]=0;if(exists("FIRSTBT.STA")&&!read_local("FIRSTBT.STA",phase,sizeof phase))fail("cannot read phase journal");
    if(shell_mode)run_once_values();
    else if(!exists("SHELL.BAD")&&(!phase[0]||!lstrcmpA(phase,"late\r\n")||!lstrcmpA(phase,"install\r\n")||mid_phase(phase))){
        /* Under Explorer's RunOnce (first boot after Setup, or after Retry):
         * no package runs here; the same phase continues in a shell boot. */
        if(shell_set(1))reboot(phase[0]?phase:"late\r\n","restart: package boots continue with USOSFB as the Windows shell");
        save("SHELL.BAD","shell=USOSFB could not be set\r\n");log_line("shell mode unavailable; packages run under Explorer's RunOnce");}
    if(!display_ready()||!tz_ready()){
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
    /* "install": a restart or Retry inside the package boundary (OSR2.1
     * X470 2026-10-27: USOSRES refused, Retry met "unknown phase"). The
     * boundary runs again: DISPLAY.DONE ends USOSRES at once, USOSADD
     * resumes from its STATE.INI. */
    if(phase[0]&&lstrcmpA(phase,"late\r\n")&&lstrcmpA(phase,"install\r\n")&&!mid)fail("unknown phase; automatic retry refused");
    if(!lstrcmpA(phase,"install\r\n"))log_line("resume: package boundary (install) runs again");
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
        if(code!=1001){char why[64],line[200];int open=chain_open(why,sizeof why);
            if(open==1||(open==2&&(code==0||code==3010))){
                if(open==1)wsprintfA(line,"USOSADD exit %lu with %s still running in STATE.INI: package restart, not the final one",code,why);
                else wsprintfA(line,"USOSADD exit %lu without CHAIN.END (chain not finished): package restart, not the final one",code);
                log_line(line);code=1001;}}
        if(code==1001){
            /* The chain asked for a restart (DCOM95 / IE 5.5 SP2 reboot_setup=now, or
             * a retry after a restart): restart, keep holding the desktop,
             * resume the chain from STATE.INI. */
            if(mid>=mid_limit())fail(win98?"more than nine package restarts before the desktop":"more than four package restarts before the desktop");
            wsprintfA(next,"mid%d\r\n",mid+1);wsprintfA(note,"restart: package restart %d before the desktop",mid+1);
            reboot(next,note);}
        if(code!=0&&code!=3010)fail("packages did not finish before final restart");}
    reboot("reboot\r\n","restart: sole final post-addons restart");
}
