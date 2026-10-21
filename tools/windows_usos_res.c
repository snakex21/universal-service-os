/* USOSRES.EXE: one display request at first hardware logon.
 * USOS, Copyright 2026 Maksymilian and the USOS Authors, GPL-3.0-or-later.
 * No CRT, windows or prompts. Static imports: kernel32/advapi32 only.
 * Video APIs are looked up at runtime for old NT compatibility.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <cpuid.h>
#include "display_policy.h"
#include "display_apply.h"
#include "display_modes.h"
#ifdef USOSRES_9X
#include "display_vbe.h"
#include "display_inf.h"
#define DISPLAY_BUFFERS 1
#else
#define DISPLAY_BUFFERS 0
#endif

typedef BOOL (WINAPI *EnumModes)(LPCSTR, DWORD, DEVMODEA *);
typedef LONG (WINAPI *ChangeMode)(DEVMODEA *, DWORD);
#include "display_compat.h"
static char directory[MAX_PATH], path[MAX_PATH], line[512];
static HANDLE log_file = INVALID_HANDLE_VALUE;
static UsosDisplayMode modes[USOS_DISPLAY_MAX];
static DEVMODEA settings[USOS_DISPLAY_MAX], current;
static ChangeMode change_mode;
static HMODULE display_user;
static DWORD display_flags;
static int permission_failure;
static const char run_key[] = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
#ifndef USOSRES_9X
static SERVICE_STATUS service_status;
static SERVICE_STATUS_HANDLE service_handle;
static UsosDisplayModeList registry_modes;
#endif
static void run(void);
#ifndef USOSRES_9X
/* Vista / 7 (docs/nt6-display-2026-10-21.md): every new user gets a HKCU Run
 * value from the Default hive. Display settings are per machine there, so
 * the first hardware sign-in applies; each user's value is removed without
 * elevation (UAC), also once DISPLAY.DONE exists. Never on older Windows. */
static void forget_user_run(void) {
    HKEY key;
    if((GetVersion()&255)<6) return;
    if(RegOpenKeyExA(HKEY_CURRENT_USER,run_key,0,KEY_SET_VALUE,&key)==ERROR_SUCCESS) {
        RegDeleteValueA(key,"USOSDisplay"); RegCloseKey(key);
    }
}
#else
static void forget_user_run(void) {}
#endif

__attribute__((noreturn)) static void leave(DWORD code) {
#ifndef USOSRES_9X
    if (service_handle) {
        service_status.dwCurrentState=SERVICE_STOPPED;
        service_status.dwWin32ExitCode=code;
        SetServiceStatus(service_handle,&service_status);
    }
#endif
    ExitProcess(code);
}

static void zero(void *p, unsigned n) { volatile BYTE *b = (volatile BYTE *)p; while (n--) *b++ = 0; }
static void file_path(const char *name) { lstrcpyA(path, directory); lstrcatA(path, name); }
static void say(const char *text) {
    DWORD done;
    if (log_file != INVALID_HANDLE_VALUE) { WriteFile(log_file, text, lstrlenA(text), &done, NULL); FlushFileBuffers(log_file); }
}
static void number(unsigned long n) {
    char out[16], reverse[16]; int i=0,j=0;
    do { reverse[i++]=(char)('0'+n%10); n/=10; } while(n);
    while(i) out[j++]=reverse[--i]; out[j]=0; lstrcatA(line,out);
}
static void signed_number(long n) {
    if(n<0) {lstrcatA(line,"-");number(0UL-(unsigned long)n);} else number((unsigned long)n);
}
static void describe(const UsosDisplayMode *m) {
    number(m->width); lstrcatA(line,"x"); number(m->height); lstrcatA(line,"x"); number(m->bpp);
}
static void request_log(const UsosDisplayRequest *request,unsigned count) {
    lstrcpyA(line,"DISPLAY request=");
    if(request->width) {number(request->width);lstrcatA(line,"x");number(request->height);}
    else lstrcatA(line,"auto");
    lstrcatA(line,"x");if(request->bpp)number(request->bpp);else lstrcatA(line,"auto");
    lstrcatA(line," modes=");number(count);lstrcatA(line,"\r\n");say(line);
}
#ifdef USOSRES_9X
static UsosDisplayVbeList vbe;
static char inf_text[32768];
static DWORD vram_limit;
static void say_number(const char *text,unsigned long n) { lstrcpyA(line,text); number(n); lstrcatA(line,"\r\n"); say(line); }
/* The collector's own one-line VBE.LOG (stage and VBE facts) into USOSRES.LOG. */
static void copy_vbi_log(void) {
    HANDLE file; DWORD bytes=0; char text[260];
    file_path("VBE.LOG");file=CreateFileA(path,GENERIC_READ,FILE_SHARE_READ,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);
    if(file==INVALID_HANDLE_VALUE) { say("DISPLAY VBE.LOG absent\r\n"); return; }
    if(!ReadFile(file,text,sizeof(text)-1,&bytes,NULL))bytes=0;
    CloseHandle(file);text[bytes]=0;
    say("DISPLAY ");say(text);
    if(!bytes || text[bytes-1]!='\n')say("\r\n");
}
static int prepare_vbe(void) {
    STARTUPINFOA startup; PROCESS_INFORMATION process; DWORD result,bytes,type;
    HANDLE file;
    file_path("VBE.DAT"); DeleteFileA(path); /* reject stale results after failure */
    file_path("VBE.LOG"); DeleteFileA(path);
    file_path("USOSVBI.EXE"); zero(&startup,sizeof startup); zero(&process,sizeof process);
    startup.cb=sizeof startup; startup.dwFlags=STARTF_USESHOWWINDOW; startup.wShowWindow=SW_HIDE;
    if(!CreateProcessA(path,NULL,NULL,NULL,FALSE,0,NULL,directory,&startup,&process)) {
        say_number("DISPLAY VBI start failed error=",GetLastError()); return 0;
    }
    result=WaitForSingleObject(process.hProcess,30000);
    type=1; if(result==WAIT_OBJECT_0 && !GetExitCodeProcess(process.hProcess,&type)) type=0xFFFFFFFFUL;
    CloseHandle(process.hThread); CloseHandle(process.hProcess);
    lstrcpyA(line,"DISPLAY VBI wait=");number(result);lstrcatA(line," exit=");number(type);lstrcatA(line,"\r\n");say(line);
    copy_vbi_log();
    /* A Win16 exit code may not reach GetExitCodeProcess: VBE.DAT's own
       magic, count and exact length are the evidence that counts. */
    if(result!=WAIT_OBJECT_0) return 0;
    file_path("VBE.DAT");file=CreateFileA(path,GENERIC_READ,FILE_SHARE_READ,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);
    if(file==INVALID_HANDLE_VALUE) { say("DISPLAY VBE.DAT absent\r\n"); return 0; }
    type=GetFileSize(file,NULL);
    result=ReadFile(file,&vbe,sizeof vbe,&bytes,NULL);CloseHandle(file);
    if(!result || type!=bytes || vbe.magic!=USOS_DISPLAY_VBE_MAGIC || !vbe.count || vbe.count>USOS_DISPLAY_VBE_COUNT || bytes!=8+vbe.count*sizeof(UsosDisplayVbeMode)) {
        say_number("DISPLAY VBE.DAT invalid bytes=",bytes); return 0;
    }
    file_path("USOSVESA.INF");file=CreateFileA(path,GENERIC_READ,FILE_SHARE_READ,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);
    if(file==INVALID_HANDLE_VALUE) { say("DISPLAY USOSVESA.INF absent\r\n"); return 0; }
    result=ReadFile(file,inf_text,sizeof(inf_text)-1,&bytes,NULL);CloseHandle(file);
    if(!result || bytes>=sizeof(inf_text)-1) { say_number("DISPLAY USOSVESA.INF unreadable bytes=",bytes); return 0; }
    inf_text[bytes]=0;vram_limit=usos_display_inf_limit(inf_text);
    lstrcpyA(line,"DISPLAY VBE modes=");number(vbe.count);lstrcatA(line," memory=");
    number(vbe.modes[0].vram);lstrcatA(line," INF_limit=");number(vram_limit);lstrcatA(line," buffers=2\r\n");say(line);
    for(type=0;type<vbe.count;type++) {
        lstrcpyA(line,"DISPLAY VBE ");number(vbe.modes[type].width);lstrcatA(line,"x");number(vbe.modes[type].height);
        lstrcatA(line,"x");number(vbe.modes[type].bpp);lstrcatA(line," pitch=");number(vbe.modes[type].pitch);lstrcatA(line,"\r\n");say(line);
    }
    return vram_limit!=0;
}
static void validate_vbe(UsosDisplayMode *mode) {
    unsigned i;DWORD pitch=0,memory=0;
    if(!mode->valid || !usos_display_inf_has(inf_text,mode->width,mode->height,mode->bpp)) {mode->valid=0;return;}
    for(i=0;i<vbe.count;i++) if(vbe.modes[i].width==mode->width && vbe.modes[i].height==mode->height && vbe.modes[i].bpp==mode->bpp) {
        /* Conservative for duplicate BIOS mode numbers: worst pitch/memory. */
        if(vbe.modes[i].pitch>pitch)pitch=vbe.modes[i].pitch;
        if(!memory || vbe.modes[i].vram<memory)memory=vbe.modes[i].vram;
    }
    mode->pitch=pitch;mode->vram=memory<vram_limit?memory:vram_limit;
    if(!pitch || !memory)mode->valid=0;
}
#endif

static int save_mode(DWORD width,DWORD height,DWORD bpp) {
    HANDLE file;DWORD bytes,expected;UsosDisplayMode mode;
    mode.width=width;mode.height=height;mode.bpp=bpp;
    line[0]=0;describe(&mode);lstrcatA(line,"\r\n");expected=lstrlenA(line);
    file_path("DISPLAY.BAK");file=CreateFileA(path,GENERIC_WRITE,0,NULL,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,NULL);
    if(file==INVALID_HANDLE_VALUE)return 0;
    bytes=0;WriteFile(file,line,expected,&bytes,NULL);
    expected=bytes==expected && FlushFileBuffers(file);CloseHandle(file);
    return expected!=0;
}
static int save_current(void) {return save_mode(current.dmPelsWidth,current.dmPelsHeight,current.dmBitsPerPel);}
static long action_test(void *context,int index,const char *reason) {
    LONG result; (void)context;
    result=change_mode(&settings[index],CDS_TEST);
    lstrcpyA(line,"DISPLAY selected=");describe(&modes[index]);lstrcatA(line," reason=");
    if(result==DISP_CHANGE_NOTUPDATED)permission_failure=1;
    lstrcatA(line,reason);lstrcatA(line," test=");signed_number(result);
    lstrcatA(line,"\r\n");say(line);return result;
}
static int action_backup(void *context) {(void)context;return save_current();}
static long action_apply(void *context,int index) {(void)context;return usos_display_change(change_mode,&settings[index],display_flags);}
static long action_rollback(void *context) {(void)context;return usos_display_change(change_mode,&current,display_flags);}
static int current_caps(DWORD *width,DWORD *height,DWORD *bpp) {
    HMODULE gdi=LoadLibraryA("gdi32.dll");HDC dc;int ok=0;
    HDC(WINAPI *get_dc)(HWND);int(WINAPI *release_dc)(HWND,HDC);int(WINAPI *caps)(HDC,int);
    if(!gdi)return 0;
    get_dc=(void*)GetProcAddress(display_user,"GetDC");release_dc=(void*)GetProcAddress(display_user,"ReleaseDC");
    caps=(void*)GetProcAddress(gdi,"GetDeviceCaps");
    if(get_dc&&release_dc&&caps&&(dc=get_dc(NULL))!=NULL) {
        *width=(DWORD)caps(dc,HORZRES);*height=(DWORD)caps(dc,VERTRES);
        *bpp=(DWORD)(caps(dc,BITSPIXEL)*caps(dc,PLANES));
        ok=*width&&*height&&*bpp;release_dc(NULL,dc);
    }
    FreeLibrary(gdi);return ok;
}
static int vm(void) {
    unsigned a,b,c,d;
    return __get_cpuid(1,&a,&b,&c,&d) && (c & (1U<<31));
}
static int finish(const char *reason) {
    HANDLE f; DWORD done; HKEY key;
    say(reason); say("\r\n");
    file_path("DISPLAY.DONE");
    f=CreateFileA(path,GENERIC_WRITE,0,NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,NULL);
    if(f==INVALID_HANDLE_VALUE) { say("DISPLAY marker failed; retry remains registered\r\n"); return 0; }
    if(!WriteFile(f,reason,lstrlenA(reason),&done,NULL) || done!=(DWORD)lstrlenA(reason) || !FlushFileBuffers(f)) {
        CloseHandle(f); DeleteFileA(path); say("DISPLAY marker write failed\r\n"); return 0;
    }
    CloseHandle(f);
#ifdef USOSRES_9X
    /* The 9x shell starts Run values inside its RegEnumValue(index) loop:
       an early delete shifts the next value onto this index and the shell
       skips it (95 X470 2026-10-20, USOSLan hid USOSDisplay). */
    Sleep(15000);
#endif
    if(RegOpenKeyExA(HKEY_LOCAL_MACHINE,run_key,0,KEY_SET_VALUE,&key)==ERROR_SUCCESS) {
        RegDeleteValueA(key,"USOSDisplay"); RegCloseKey(key);
    }
    forget_user_run();
#ifndef USOSRES_9X
    if(service_handle && RegOpenKeyExA(HKEY_LOCAL_MACHINE,"SYSTEM\\CurrentControlSet\\Services\\usosdisplay",0,KEY_SET_VALUE,&key)==ERROR_SUCCESS) {
        DWORD disabled=SERVICE_DISABLED;
        RegSetValueExA(key,"Start",0,REG_DWORD,(BYTE *)&disabled,sizeof disabled); RegCloseKey(key);
    }
    #endif
    return 1;
}

#ifndef USOSRES_9X
/* NT3.5 lacks user32's mode APIs. Never use a stale list from an unloaded
 * miniport. Its FindAdapter clears the previous boot's list before query. */
static void registry_display(const UsosDisplayRequest *request) {
    HKEY key; DWORD bytes=sizeof registry_modes,type,old[3],values[3],i;
    static const char *names[]={"DefaultSettings.XResolution","DefaultSettings.YResolution","DefaultSettings.BitsPerPel"};
    SC_HANDLE scm,driver; SERVICE_STATUS status; LONG rc; UsosDisplayChoice chosen;
    scm=OpenSCManagerA(NULL,NULL,SC_MANAGER_CONNECT);
    driver=scm ? OpenServiceA(scm,"usosvbe",SERVICE_QUERY_STATUS) : NULL;
    i=driver && QueryServiceStatus(driver,&status) && status.dwCurrentState==SERVICE_RUNNING;
    if(driver) CloseServiceHandle(driver); if(scm) CloseServiceHandle(scm);
    if(!i) { say("DISPLAY miniport not running; request retained\r\n"); return; }
    if(RegOpenKeyExA(HKEY_LOCAL_MACHINE,"SYSTEM\\CurrentControlSet\\Services\\usosvbe\\Device0",0,KEY_QUERY_VALUE|KEY_SET_VALUE,&key)!=ERROR_SUCCESS) return;
    rc=RegQueryValueExA(key,"UsosVbeModes",NULL,&type,(BYTE *)&registry_modes,&bytes);
    if(rc!=ERROR_SUCCESS || type!=REG_BINARY || registry_modes.magic!=USOS_DISPLAY_MODES_MAGIC ||
        !registry_modes.count || registry_modes.count>USOS_DISPLAY_MODES_COUNT || bytes!=8+registry_modes.count*sizeof(UsosDisplayRecord)) {
        RegCloseKey(key); say("DISPLAY no current miniport list; request retained\r\n"); return;
    }
    for(i=0;i<registry_modes.count;i++) {
        modes[i].width=registry_modes.modes[i].width; modes[i].height=registry_modes.modes[i].height;
        modes[i].bpp=registry_modes.modes[i].bpp; modes[i].valid=1;
    }
    request_log(request,registry_modes.count);
    chosen=usos_display_choose(modes,registry_modes.count,request,0);
    if(chosen.index<0) { RegCloseKey(key); finish("DISPLAY no safe registry mode; unchanged"); return; }
    values[0]=modes[chosen.index].width; values[1]=modes[chosen.index].height; values[2]=modes[chosen.index].bpp;
    for(i=0;i<3;i++) {
        bytes=sizeof(DWORD);
        if(RegQueryValueExA(key,names[i],NULL,&type,(BYTE *)&old[i],&bytes)!=ERROR_SUCCESS || type!=REG_DWORD || bytes!=sizeof(DWORD)) {
            RegCloseKey(key); say("DISPLAY no rollback values; unchanged\r\n"); return;
        }
    }
    if(old[0]==values[0] && old[1]==values[1] && old[2]==values[2]) {
        RegCloseKey(key); finish("DISPLAY registry already requested; no restart"); return;
    }
    if(!save_mode(old[0],old[1],old[2])) {
        RegCloseKey(key);say("DISPLAY cannot save registry rollback mode; unchanged\r\n");return;
    }
    for(i=0;i<3;i++) if(RegSetValueExA(key,names[i],0,REG_DWORD,(BYTE *)&values[i],sizeof(DWORD))!=ERROR_SUCCESS) break;
    if(i<3) {
        DWORD j;
        for(j=0;j<3;j++) RegSetValueExA(key,names[j],0,REG_DWORD,(BYTE *)&old[j],sizeof(DWORD));
        RegCloseKey(key); say("DISPLAY registry write failed; rollback attempted\r\n"); return;
    }
    RegCloseKey(key);
    lstrcpyA(line,"DISPLAY registry selected="); describe(&modes[chosen.index]); lstrcatA(line," reason="); lstrcatA(line,chosen.reason); lstrcatA(line,"\r\n"); say(line);
    if(!finish("DISPLAY registry saved; restart required")) return;
    /* Once-only hardware service: restart using the same old-NT APIs as usosnt3. */
    if(service_handle) {
        HANDLE token; TOKEN_PRIVILEGES privilege;
        if(OpenProcessToken(GetCurrentProcess(),TOKEN_ADJUST_PRIVILEGES|TOKEN_QUERY,&token)) {
            zero(&privilege,sizeof privilege); privilege.PrivilegeCount=1;
            if(LookupPrivilegeValueA(NULL,"SeShutdownPrivilege",&privilege.Privileges[0].Luid)) {
                privilege.Privileges[0].Attributes=SE_PRIVILEGE_ENABLED;
                if(AdjustTokenPrivileges(token,FALSE,&privilege,0,NULL,NULL)) {
                    if(!InitiateSystemShutdownA(NULL,NULL,0,FALSE,TRUE)) say("DISPLAY automatic restart failed; values apply at next boot\r\n");
                }
            }
            CloseHandle(token);
        }
    }
}

#endif

static void run(void) {
    DWORD length,bytes; HANDLE input; HMODULE user; EnumModes enumerate; ChangeMode change;
    UsosDisplayRequest request; UsosDisplayResult transaction;
    UsosDisplayActions actions={NULL,action_test,action_backup,action_apply,action_rollback};
    char text[64]; unsigned count=0,i;
    length=GetModuleFileNameA(NULL,directory,sizeof directory);
    if(!length || length>=sizeof directory) leave(1);
    while(length && directory[length-1]!='\\') length--;
    if(!length) leave(1); directory[length]=0;
    if(length>MAX_PATH-32)leave(1);
    file_path("DISPLAY.DONE"); if(GetFileAttributesA(path)!=0xFFFFFFFF) { forget_user_run(); leave(0); }
    file_path("DISPLAY.TXT"); input=CreateFileA(path,GENERIC_READ,FILE_SHARE_READ,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);
    if(input==INVALID_HANDLE_VALUE) leave(0); /* absent profile = unchanged */
    zero(text,sizeof text);
    if(!ReadFile(input,text,sizeof(text)-1,&bytes,NULL) || !bytes || bytes>=sizeof(text)-1) { CloseHandle(input); leave(1); }
    CloseHandle(input);
    file_path("USOSRES.LOG"); log_file=CreateFileA(path,GENERIC_WRITE,FILE_SHARE_READ,NULL,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,NULL);
    if(log_file==INVALID_HANDLE_VALUE) leave(1); /* never change without logging */
    SetFilePointer(log_file,0,NULL,FILE_END);
    if(!usos_display_parse(text,&request)) { finish("DISPLAY invalid request; unchanged"); CloseHandle(log_file); leave(1); }
    if(vm()) { say("DISPLAY deferred: virtual machine; hardware request retained\r\n"); CloseHandle(log_file); leave(0); }
#ifdef USOSRES_9X
    if(!prepare_vbe()) { say("DISPLAY no fresh VBE/INF memory evidence; unchanged\r\n"); CloseHandle(log_file); leave(1); }
#endif
    user=LoadLibraryA("user32.dll");
    enumerate=user ? (EnumModes)GetProcAddress(user,"EnumDisplaySettingsA") : NULL;
    change=user ? (ChangeMode)GetProcAddress(user,"ChangeDisplaySettingsA") : NULL;
    if(!enumerate || !change) {
#ifndef USOSRES_9X
        registry_display(&request);
#else
        say("DISPLAY no display API; unchanged\r\n");
#endif
        CloseHandle(log_file); leave(0);
    }
    display_user=user;
    if(!usos_display_current(enumerate,GetVersion(),current_caps,&current)) { say("DISPLAY no current mode for rollback; request retained\r\n"); CloseHandle(log_file); leave(1); }
    if(current.dmBitsPerPel<16) {say("DISPLAY VGA/low depth; request retained for the normal driver\r\n");CloseHandle(log_file);leave(0);}
    display_flags=CDS_UPDATEREGISTRY;
#ifndef USOSRES_9X
    /* NT5 only: on 6.x the settings are per machine already, and CDS_GLOBAL
       needs an elevated token the first sign-in may lack (UAC). */
    if((GetVersion()&255)==5)display_flags|=CDS_GLOBAL;
#endif
    for(i=0;i<USOS_DISPLAY_MAX;i++) {
        if(!usos_display_enum(enumerate,GetVersion(),i,&settings[count])) break;
        modes[count].width=settings[count].dmPelsWidth; modes[count].height=settings[count].dmPelsHeight;
        modes[count].bpp=settings[count].dmBitsPerPel;
        /* Progressive 60 Hz or firmware default only; no guessed refresh. */
        modes[count].valid=!(settings[count].dmDisplayFlags&DM_INTERLACED) &&
            (settings[count].dmDisplayFrequency<=1 || settings[count].dmDisplayFrequency==60);
#ifdef USOSRES_9X
        validate_vbe(&modes[count]);
        lstrcpyA(line,"DISPLAY mode ");describe(&modes[count]);lstrcatA(line,modes[count].valid?" ok":" rejected");
        lstrcatA(line," pitch=");number(modes[count].pitch);lstrcatA(line," memory=");number(modes[count].vram);lstrcatA(line,"\r\n");say(line);
#endif
        count++;
    }
    request_log(&request,count);
    change_mode=change;
    transaction=usos_display_execute(modes,count,&request,DISPLAY_BUFFERS,&actions);
    if(usos_display_retry(current.dmBitsPerPel,transaction.state,transaction.apply_result,permission_failure)) {
        say("DISPLAY permissions prevent saving; request retained\r\n");CloseHandle(log_file);leave(1);
    }
    if(transaction.state==4) say("DISPLAY cannot save rollback mode; unchanged\r\n");
    else if(transaction.state==3) {
        lstrcpyA(line,"DISPLAY apply failed; rollback=");signed_number(transaction.rollback_result);
        lstrcatA(line,"\r\n");say(line);
        finish(transaction.rollback_result==0 ? "DISPLAY previous mode restored" : "DISPLAY rollback failed; inspect DISPLAY.BAK");
    } else finish(transaction.state==1 ? "DISPLAY applied" : transaction.state==2 ? "DISPLAY saved; restart required" : "DISPLAY no tested mode; current retained");
    CloseHandle(log_file);leave(transaction.state>=3?1:0);
}

#ifndef USOSRES_9X
static void WINAPI control(DWORD code) { (void)code; }
static void WINAPI service(DWORD argc,LPSTR *argv) {
    (void)argc; (void)argv;
    service_handle=RegisterServiceCtrlHandlerA("usosdisplay",control);
    if(!service_handle) leave(1);
    zero(&service_status,sizeof service_status);
    service_status.dwServiceType=SERVICE_WIN32_OWN_PROCESS|SERVICE_INTERACTIVE_PROCESS;
    service_status.dwCurrentState=SERVICE_RUNNING;
    SetServiceStatus(service_handle,&service_status);
    run();
}
void entry(void) {
    const char *p=GetCommandLineA();
    while(*p) {
        if(p[0]==' ' && p[1]=='s' && p[2]=='e' && p[3]=='r' && p[4]=='v' && p[5]=='i' && p[6]=='c' && p[7]=='e' && p[8]==0) {
            SERVICE_TABLE_ENTRYA table[2];
            table[0].lpServiceName="usosdisplay"; table[0].lpServiceProc=service;
            table[1].lpServiceName=NULL; table[1].lpServiceProc=NULL;
            StartServiceCtrlDispatcherA(table); leave(1);
        }
        p++;
    }
    run();
}

#else
void entry(void) { run(); }
#endif
