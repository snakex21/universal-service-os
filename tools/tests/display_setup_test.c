/* Actual USOSRES run/leave paths with fake OS facts and setup state.
 * Only files beside this test executable can be accessed. All registry,
 * DLL loading and process creation are stubbed; no host display is touched. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
static unsigned test_case;
static DWORD test_legacy,test_minor,test_build;
static DWORD WINAPI fake_version(void){return test_legacy;}
static BOOL WINAPI fake_version_ex(LPOSVERSIONINFOA v){
    if(test_case==6)return FALSE;
    if(v->dwOSVersionInfoSize!=sizeof(*v))ExitProcess(201);
    v->dwPlatformId=test_case==7?VER_PLATFORM_WIN32_NT:VER_PLATFORM_WIN32_WINDOWS;
    v->dwMajorVersion=test_case==8?5:4;v->dwMinorVersion=test_case==9?1:test_minor;
    v->dwBuildNumber=test_build;return TRUE;
}
static LPSTR WINAPI fake_command(void){return "unit.exe /setup";}
static DWORD WINAPI fake_attributes(LPCSTR file){const char *name=file,*p=file;
    while(*p){if(*p=='\\')name=p+1;p++;}
    if(!lstrcmpA(name,"PHASE1.OK"))return test_case==10?INVALID_FILE_ATTRIBUTES:0;
    if(!lstrcmpA(name,"VLATE.OK"))return test_case==11||test_case>=19?INVALID_FILE_ATTRIBUTES:0;
    /* 950 stages VESALATE.BAT; OSR2 (19..21) only VESA95.BAT. */
    if(!lstrcmpA(name,"VESALATE.BAT"))return test_case<19?0:INVALID_FILE_ATTRIBUTES;
    if(!lstrcmpA(name,"VESA95.BAT"))return test_case>=19?0:INVALID_FILE_ATTRIBUTES;
    if(!lstrcmpA(name,"VESA95.BAD"))return test_case==20?0:INVALID_FILE_ATTRIBUTES;
    if(!lstrcmpA(name,"VESA95.OK"))return test_case==21?0:INVALID_FILE_ATTRIBUTES;
    if(!lstrcmpA(name,"FIRSTBT.ON"))return test_case==12?INVALID_FILE_ATTRIBUTES:0;
    if(!lstrcmpA(name,"DISPLAY.DONE"))return test_case<6||test_case>=20?0:INVALID_FILE_ATTRIBUTES;
    return INVALID_FILE_ATTRIBUTES;
}
static LONG WINAPI fake_reg_open(HKEY r,LPCSTR k,DWORD o,REGSAM a,PHKEY out){
    (void)r;(void)k;(void)o;(void)a;
    if(test_case==15){*out=(HKEY)(ULONG_PTR)1;return ERROR_SUCCESS;}
    return ERROR_FILE_NOT_FOUND;
}
static LONG WINAPI fake_reg_info(HKEY k,LPSTR c,LPDWORD cs,LPDWORD r,LPDWORD keys,LPDWORD mk,LPDWORD mc,
    LPDWORD values,LPDWORD mv,LPDWORD md,LPDWORD sd,PFILETIME ft){
    (void)k;(void)c;(void)cs;(void)r;(void)mk;(void)mc;(void)mv;(void)md;(void)sd;(void)ft;
    *keys=0;*values=1;return ERROR_SUCCESS;
}
static LONG WINAPI fake_reg_close(HKEY k){(void)k;return ERROR_SUCCESS;}
static HMODULE WINAPI fake_load(LPCSTR name){(void)name;ExitProcess(202);return NULL;}
static BOOL WINAPI fake_process(LPCSTR a,LPSTR b,LPSECURITY_ATTRIBUTES c,LPSECURITY_ATTRIBUTES d,BOOL e,
    DWORD f,LPVOID g,LPCSTR h,LPSTARTUPINFOA i,LPPROCESS_INFORMATION j){
    (void)a;(void)b;(void)c;(void)d;(void)e;(void)f;(void)g;(void)h;(void)i;(void)j;
    SetLastError(ERROR_FILE_NOT_FOUND);return FALSE;
}
#define GetVersion fake_version
#define GetVersionExA fake_version_ex
#define GetCommandLineA fake_command
#define GetFileAttributesA fake_attributes
#define RegOpenKeyExA fake_reg_open
#define RegQueryInfoKeyA fake_reg_info
#define RegCloseKey fake_reg_close
#define LoadLibraryA fake_load
#define CreateProcessA fake_process
#define entry unused_target_entry
#define USOSRES_9X
#include "../windows_usos_res.c"
#undef entry
#undef GetCommandLineA
void entry(void){const char *args=GetCommandLineA(),*last=args;
    while(*args){if(*args==' ')last=args+1;args++;}
    while(*last>='0'&&*last<='9')test_case=test_case*10+(*last++-'0');
    if(test_case>21)ExitProcess(203);
    test_legacy=test_case<3?0x80000004UL:test_case<5?0x80000a04UL:0x80005a04UL;
    test_minor=test_case<3?0:test_case<5?10:90;
    test_build=test_case<2?0x040003b6UL:test_case==2?0x04000457UL:test_case==3?0x040a07ceUL:test_case==4?0x040a08aeUL:0x045a0bb8UL;
    if(test_case>=6){test_legacy=0x80000004UL;test_minor=0;test_build=0x040003b6UL;}
    if(test_case>=19)test_build=test_case==19?0x04000457UL:test_case==20?0x040004bcUL:0x040004beUL; /* 1111 / 1212 / 1214 */
    run();
}
