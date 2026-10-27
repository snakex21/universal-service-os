/* USOSRES.EXE: one display request at first hardware logon.
 * USOS, Copyright 2026 Maksymilian and the USOS Authors, GPL-3.0-or-later.
 * No CRT, windows or prompts. Static imports: kernel32/advapi32 only.
 * Video APIs are looked up at runtime for old NT compatibility.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <cpuid.h>
#ifdef USOSRES_9X
#define USOS_DISPLAY_AUTO_MAX_W 1920
#define USOS_DISPLAY_AUTO_MAX_H 1080
#endif
#include "display_policy.h"
#include "display_edid.h"
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
static unsigned test_count,test_failed;
static int setup_mode;
static const char run_key[] = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
#ifndef USOSRES_9X
static SERVICE_STATUS service_status;
static SERVICE_STATUS_HANDLE service_handle;
static UsosDisplayModeList registry_modes;
#endif
static void run(void);
#ifndef USOSRES_9X
/* Vista / 7 / 8 / 8.1 / 10 (docs/display-policy.md): every new user gets a
 * HKCU Run value from the Default hive. Display settings are per machine
 * there, so the first hardware sign-in applies; each user's value is
 * removed without elevation (UAC), also once DISPLAY.DONE exists. Never on
 * older Windows. */
static void forget_user_run(void) {
    HKEY key;
    if(!usos_display_user_run(GetVersion())) return;
    if(RegOpenKeyExA(HKEY_CURRENT_USER,run_key,0,KEY_SET_VALUE,&key)==ERROR_SUCCESS) {
        RegDeleteValueA(key,"USOSDisplay"); RegCloseKey(key);
    }
}
#else
static void forget_user_run(void) {}
#endif

__attribute__((noreturn)) static void leave(DWORD code);

static void zero(void *p, unsigned n) { volatile BYTE *b = (volatile BYTE *)p; while (n--) *b++ = 0; }
static void file_path(const char *name) { lstrcpyA(path, directory); lstrcatA(path, name); }
#ifdef USOSRES_9X
static int present(const char *name) { file_path(name); return GetFileAttributesA(path)!=INVALID_FILE_ATTRIBUTES; }
/* usosfb.c coordinated_build / display_ready: 4.00 950 (RTM / OSR1) and the
 * OSR2 family (1111, 1212..1216), 4.10 98 FE (1998) and 98 SE (2222). 950
 * binds VESALATE.BAT late (VLATE.OK); OSR2 stages no VESALATE: VESA95.BAT
 * had its one attempt (OK or BAD), or none; 98 stages neither (Setup binds
 * the VESA driver from USOSVESA.INF), so its boundary is always open. */
static int coordinated_build(DWORD minor,DWORD build) { build&=0xffff;
    if(minor==0) return build==950||build==1111||build==1212||build==1214||build==1216;
    return minor==10&&(build==1998||build==2222); }
#endif
static void say(const char *text) {
    DWORD done;
    if (log_file != INVALID_HANDLE_VALUE) { WriteFile(log_file, text, lstrlenA(text), &done, NULL); FlushFileBuffers(log_file); }
}
static void number(unsigned long n) {
    char out[16], reverse[16]; int i=0,j=0;
    do { reverse[i++]=(char)('0'+n%10); n/=10; } while(n);
    while(i) out[j++]=reverse[--i]; out[j]=0; lstrcatA(line,out);
}
static int open_log(void) {
    if(log_file!=INVALID_HANDLE_VALUE)return 1;
    file_path("USOSRES.LOG");
    log_file=CreateFileA(path,GENERIC_WRITE,FILE_SHARE_READ,NULL,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,NULL);
    if(log_file==INVALID_HANDLE_VALUE)return 0;
    SetFilePointer(log_file,0,NULL,FILE_END);
    return 1;
}
__attribute__((noreturn)) static void leave(DWORD code) {
    if(setup_mode) {
        lstrcpyA(line,"DISPLAY /setup exit=");number(code);lstrcatA(line,"\r\n");say(line);
    }
    if(log_file!=INVALID_HANDLE_VALUE) {CloseHandle(log_file);log_file=INVALID_HANDLE_VALUE;}
#ifndef USOSRES_9X
    if (service_handle) {
        service_status.dwCurrentState=SERVICE_STOPPED;
        service_status.dwWin32ExitCode=code;
        SetServiceStatus(service_handle,&service_status);
    }
#endif
    ExitProcess(code);
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
    lstrcatA(line," native=");
    if(request->native_width) {number(request->native_width);lstrcatA(line,"x");number(request->native_height);}
    else lstrcatA(line,"unknown");
    lstrcatA(line," modes=");number(count);lstrcatA(line,"\r\n");say(line);
}
#ifndef USOSRES_9X
/* No native size from the preparation (DISPLAY.TXT native=): NT5 / 6.x keep
 * each monitor's EDID under Enum\DISPLAY\<id>\<instance>\Device Parameters.
 * Used only when every EDID found names the same native size (a fresh
 * install has just the connected monitor; several sizes: unknown). */
static BYTE edid[256];
static void registry_native(UsosDisplayRequest *request) {
    HKEY root,id,instance; char name[128],sub[160]; DWORD i,j,size,type,found=0,conflict=0;
    unsigned long w=0,h=0,nw,nh;
    if((GetVersion()&255)<5 || request->native_width) return;
    if(RegOpenKeyExA(HKEY_LOCAL_MACHINE,"SYSTEM\\CurrentControlSet\\Enum\\DISPLAY",0,KEY_READ,&root)!=ERROR_SUCCESS) return;
    for(i=0;i<64;i++) {
        size=sizeof name; if(RegEnumKeyExA(root,i,name,&size,NULL,NULL,NULL,NULL)!=ERROR_SUCCESS) break;
        if(RegOpenKeyExA(root,name,0,KEY_READ,&id)!=ERROR_SUCCESS) continue;
        for(j=0;j<16;j++) {
            size=128; if(RegEnumKeyExA(id,j,sub,&size,NULL,NULL,NULL,NULL)!=ERROR_SUCCESS) break;
            lstrcatA(sub,"\\Device Parameters");
            if(RegOpenKeyExA(id,sub,0,KEY_QUERY_VALUE,&instance)!=ERROR_SUCCESS) continue;
            size=sizeof edid;
            if(RegQueryValueExA(instance,"EDID",NULL,&type,edid,&size)==ERROR_SUCCESS && type==REG_BINARY &&
               usos_edid_native(edid,size,&nw,&nh)) {
                if(found && (nw!=w || nh!=h)) conflict=1;
                w=nw;h=nh;found++;
            }
            RegCloseKey(instance);
        }
        RegCloseKey(id);
    }
    RegCloseKey(root);
    lstrcpyA(line,"DISPLAY registry EDID found=");number(found);
    if(found && !conflict) {
        request->native_width=w;request->native_height=h;
        lstrcatA(line," native=");number(w);lstrcatA(line,"x");number(h);
    } else if(conflict) lstrcatA(line," sizes differ; native unknown");
    lstrcatA(line,"\r\n");say(line);
}
#endif
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
    test_count++; if(result==DISP_CHANGE_FAILED)test_failed++;
    lstrcatA(line,reason);lstrcatA(line," test=");signed_number(result);
    lstrcatA(line,"\r\n");say(line);return result;
}
static int action_backup(void *context) {(void)context;return save_current();}
static long action_apply(void *context,int index) {(void)context;return usos_display_change(change_mode,&settings[index],display_flags);}
static long action_rollback(void *context) {(void)context;return usos_display_change(change_mode,&current,display_flags);}
#ifndef USOSRES_9X
/* win32k refuses every mode change (CDS_TEST too: DISP_CHANGE_FAILED) from
   a desktop that is not the input desktop. A first-sign-in Run value can
   start while Winlogon still shows its screen (Win7 x86 X470 2026-10-22),
   so wait until this thread's desktop takes input; OpenInputDesktop fails
   for the user while the Winlogon desktop has it. Returns 1 ready, 0 not
   ready after the timeout, -1 no API (old USER32: rule unchanged). */
typedef HDESK (WINAPI *UsosOpenInput)(DWORD,BOOL,ACCESS_MASK);
typedef HDESK (WINAPI *UsosThreadDesktop)(DWORD);
typedef BOOL (WINAPI *UsosObjectInfo)(HANDLE,int,PVOID,DWORD,LPDWORD);
typedef BOOL (WINAPI *UsosCloseDesktop)(HDESK);
static int input_desktop_ready(HMODULE user,DWORD timeout_ms) {
    UsosOpenInput open_input=(UsosOpenInput)GetProcAddress(user,"OpenInputDesktop");
    UsosThreadDesktop thread_desktop=(UsosThreadDesktop)GetProcAddress(user,"GetThreadDesktop");
    UsosObjectInfo info=(UsosObjectInfo)GetProcAddress(user,"GetUserObjectInformationA");
    UsosCloseDesktop close_desktop=(UsosCloseDesktop)GetProcAddress(user,"CloseDesktop");
    char own[64],input[64]; DWORD waited=0,got; HDESK mine,desk; BOOL named;
    if(!open_input||!thread_desktop||!info||!close_desktop) return -1;
    mine=thread_desktop(GetCurrentThreadId());
    zero(own,sizeof own);
    if(!mine||!info(mine,UOI_NAME,own,sizeof(own)-1,&got)) return -1;
    for(;;) {
        desk=open_input(0,FALSE,DESKTOP_READOBJECTS);
        if(desk) {
            zero(input,sizeof input);
            named=info(desk,UOI_NAME,input,sizeof(input)-1,&got);
            close_desktop(desk);
            if(named&&!lstrcmpiA(own,input)) return 1;
        }
        if(waited>=timeout_ms) return 0;
        Sleep(1000); waited+=1000;
    }
}
#endif
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
    if(!setup_mode)Sleep(15000);
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
#ifdef USOSRES_9X
    { const char *arg=GetCommandLineA();
      while(*arg){if(*arg==' '&&!lstrcmpiA(arg+1,"/setup"))setup_mode=1;arg++;}
      if(setup_mode){
          OSVERSIONINFOA version;
          /* Log before every setup guard, including refusal (exit 2).
             Win9x GetVersion's high word is NOT its build number. */
          if(!open_log())leave(1); /* never change without logging */
          say("DISPLAY /setup begin\r\n");
          zero(&version,sizeof version);version.dwOSVersionInfoSize=sizeof version;
          if(!GetVersionExA(&version)){say("DISPLAY refused: GetVersionExA failed\r\n");leave(2);}
          lstrcpyA(line,"DISPLAY OS platform=");number(version.dwPlatformId);
          lstrcatA(line," version=");number(version.dwMajorVersion);lstrcatA(line,".");number(version.dwMinorVersion);
          lstrcatA(line," build=");number(version.dwBuildNumber&0xffff);lstrcatA(line,"\r\n");say(line);
          if(version.dwPlatformId!=VER_PLATFORM_WIN32_WINDOWS||version.dwMajorVersion!=4||
             !coordinated_build(version.dwMinorVersion,version.dwBuildNumber)){say("DISPLAY refused: /setup requires 95 (950 / OSR2) or 98 (1998 / 2222)\r\n");leave(2);}
          file_path("PHASE1.OK");if(GetFileAttributesA(path)==INVALID_FILE_ATTRIBUTES){say("DISPLAY refused: PHASE1.OK absent\r\n");leave(2);}
          if(present("VESALATE.BAT")){if(!present("VLATE.OK")){say("DISPLAY refused: VLATE.OK absent\r\n");leave(2);}}
          else if(!present("VESA95.OK")&&!present("VESA95.BAD")&&present("VESA95.BAT")){say("DISPLAY refused: VESA95 display boundary absent\r\n");leave(2);}
          file_path("FIRSTBT.ON");if(GetFileAttributesA(path)==INVALID_FILE_ATTRIBUTES){say("DISPLAY refused: FIRSTBT.ON absent\r\n");leave(2);}
      }
    }
#endif
    file_path("DISPLAY.DONE"); if(GetFileAttributesA(path)!=0xFFFFFFFF) { say("DISPLAY already completed\r\n");forget_user_run(); leave(0); }
    file_path("DISPLAY.TXT"); input=CreateFileA(path,GENERIC_READ,FILE_SHARE_READ,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);
    if(input==INVALID_HANDLE_VALUE) {say("DISPLAY request absent or unreadable; unchanged\r\n");leave(0);} /* absent profile = unchanged */
    zero(text,sizeof text);
    if(!ReadFile(input,text,sizeof(text)-1,&bytes,NULL) || !bytes || bytes>=sizeof(text)-1) { CloseHandle(input);say("DISPLAY request read failed or invalid length; unchanged\r\n");leave(1); }
    CloseHandle(input);
    if(!open_log()) leave(1); /* never change without logging */
#ifdef USOSRES_9X
    /* Never while 9x Setup's RunOnce\Setup list is not empty (950 first GUI
       boot froze in GRPCONV, X470 2026-10-25; an empty key does not count,
       as in USOSADD's setup_busy): the request and the Run value stay. */
    { HKEY setup; DWORD keys=0,values=0;
      if(RegOpenKeyExA(HKEY_LOCAL_MACHINE,"Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce\\Setup",0,KEY_READ,&setup)==ERROR_SUCCESS) {
          if(RegQueryInfoKeyA(setup,NULL,NULL,NULL,&keys,NULL,NULL,&values,NULL,NULL,NULL,NULL)!=ERROR_SUCCESS) keys=values=1;
          RegCloseKey(setup);
      }
      if(keys||values) {
          say("DISPLAY deferred: Windows Setup still running (RunOnce\\Setup); request retained\r\n");
          leave(0);
      } }
#endif
    if(!usos_display_parse(text,&request)) { finish("DISPLAY invalid request; unchanged"); leave(1); }
    if(vm()&&!setup_mode) { say("DISPLAY deferred: virtual machine; hardware request retained\r\n"); leave(0); }
#ifndef USOSRES_9X
    if(!request.width) registry_native(&request);
#endif
#ifdef USOSRES_9X
    if(!prepare_vbe()) { say("DISPLAY no fresh VBE/INF memory evidence; unchanged\r\n"); leave(1); }
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
        leave(0);
    }
    display_user=user;
#ifndef USOSRES_9X
    if(usos_display_user_run(GetVersion())) {
        int ready=input_desktop_ready(user,120000);
        say(ready>0?"DISPLAY input desktop ready\r\n":ready==0?"DISPLAY input desktop not ready after 120 s\r\n":"DISPLAY input desktop check unavailable\r\n");
    }
#endif
    if(!usos_display_current(enumerate,GetVersion(),current_caps,&current)) { say("DISPLAY no current mode for rollback; request retained\r\n"); leave(1); }
    if(current.dmBitsPerPel<16) {say("DISPLAY VGA/low depth; request retained for the normal driver\r\n");leave(0);}
#ifndef USOSRES_9X
    /* CDS_GLOBAL on NT5 only (display_compat.h usos_display_flags). */
    display_flags=usos_display_flags(GetVersion());
#else
    display_flags=CDS_UPDATEREGISTRY;
#endif
    /* Candidates are only the driver's own list (EnumDisplaySettings): the
       real VBIOS / driver mode set, switched fullscreen. Never a synthetic
       or centred-window mode (docs/display-policy.md). */
    for(i=0;i<USOS_DISPLAY_MAX;i++) {
        if(!usos_display_enum(enumerate,GetVersion(),i,&settings[count])) break;
        count++;
    }
    {   /* Progressive 60 Hz / driver default, or the single refresh a
           uniform driver reports for its whole list; no guessed refresh. */
        DWORD uniform_hz=0; int uniform=usos_display_uniform_refresh(settings,count,&uniform_hz);
        lstrcpyA(line,"DISPLAY active=");number(current.dmPelsWidth);lstrcatA(line,"x");number(current.dmPelsHeight);
        lstrcatA(line,"x");number(current.dmBitsPerPel);lstrcatA(line,"@");number(current.dmDisplayFrequency);
        lstrcatA(line," refresh=");
        if(uniform){lstrcatA(line,"uniform@");number(uniform_hz);} else lstrcatA(line,"mixed");
        lstrcatA(line,"\r\n");say(line);
        for(i=0;i<count;i++) {
            modes[i].width=settings[i].dmPelsWidth; modes[i].height=settings[i].dmPelsHeight;
            modes[i].bpp=settings[i].dmBitsPerPel; modes[i].pitch=modes[i].vram=0;
            modes[i].valid=usos_display_refresh_ok(&settings[i],uniform,uniform_hz);
#ifdef USOSRES_9X
            validate_vbe(&modes[i]);
#endif
            lstrcpyA(line,"DISPLAY mode ");describe(&modes[i]);lstrcatA(line,"@");number(settings[i].dmDisplayFrequency);
            if(settings[i].dmDisplayFlags&DM_INTERLACED)lstrcatA(line,"i");
            lstrcatA(line,modes[i].valid?" ok":" rejected");
#ifdef USOSRES_9X
            lstrcatA(line," pitch=");number(modes[i].pitch);lstrcatA(line," memory=");number(modes[i].vram);
#endif
            lstrcatA(line,"\r\n");say(line);
        }
    }
    request_log(&request,count);
    change_mode=change;
    {   /* The driver already runs the mode the policy picks (e.g. an XP
           driver at the monitor's native mode): nothing to change. */
        UsosDisplayChoice chosen;
        if(usos_display_already(modes,count,&request,DISPLAY_BUFFERS,current.dmPelsWidth,current.dmPelsHeight,current.dmBitsPerPel,&chosen)>=0) {
            lstrcpyA(line,"DISPLAY current=");describe(&modes[chosen.index]);lstrcatA(line," reason=");
            lstrcatA(line,chosen.reason);lstrcatA(line,"\r\n");say(line);
            finish("DISPLAY already at the selected mode; unchanged");leave(0);
        }
    }
    transaction=usos_display_execute(modes,count,&request,DISPLAY_BUFFERS,&actions);
    if(usos_display_retry(current.dmBitsPerPel,transaction.state,transaction.apply_result,permission_failure)) {
        say("DISPLAY permissions prevent saving; request retained\r\n");leave(1);
    }
#ifndef USOSRES_9X
    if(usos_display_desktop_retry(GetVersion(),transaction.state,test_count,test_failed)) {
        say("DISPLAY every test failed (-1): not the input desktop; request retained for the next sign-in\r\n");
        leave(1);
    }
#endif
    if(transaction.state==4) say("DISPLAY cannot save rollback mode; unchanged\r\n");
    else if(transaction.state==3) {
        lstrcpyA(line,"DISPLAY apply failed; rollback=");signed_number(transaction.rollback_result);
        lstrcatA(line,"\r\n");say(line);
        finish(transaction.rollback_result==0 ? "DISPLAY previous mode restored" : "DISPLAY rollback failed; inspect DISPLAY.BAK");
    } else finish(transaction.state==1 ? "DISPLAY applied" : transaction.state==2 ? "DISPLAY saved; restart required" : "DISPLAY no tested mode; current retained");
    leave(transaction.state>=3?1:0);
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
