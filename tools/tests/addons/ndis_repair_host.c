/* Synthetic files only, rooted beside this test EXE. No OS detection,
 * registry writes, installed Windows paths or reboot API are used. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
static unsigned test_case,inject_write_failure;
static BOOL WINAPI patch_write(HANDLE f,LPCVOID data,DWORD size,LPDWORD done,LPOVERLAPPED async) {
    if(inject_write_failure){inject_write_failure=0;WriteFile(f,data,5,done,async);return FALSE;}
    return WriteFile(f,data,size,done,async);
}
#define WriteFile patch_write
#include "../../../src/platform/win32_legacy/usosadd/ndis_repair.h"
#undef WriteFile
#define CHECK(x) do{if(!(x))ExitProcess(__LINE__);}while(0)
static unsigned char original[256],actual[256];
static void log_line(const char *s){(void)s;}
static void write_fixture(const char *p,const void *data,DWORD size){DWORD done;HANDLE f;
    f=CreateFileA(p,GENERIC_WRITE,0,0,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,0);CHECK(f!=INVALID_HANDLE_VALUE);
    CHECK(WriteFile(f,data,size,&done,0)&&done==size);CloseHandle(f);
}
static DWORD read_fixture(const char *p,void *data,DWORD size){DWORD done;HANDLE f;
    f=CreateFileA(p,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);CHECK(f!=INVALID_HANDLE_VALUE);
    CHECK(ReadFile(f,data,size,&done,0));CloseHandle(f);return done;
}
void entry(void){static char root[MAX_PATH],windows[MAX_PATH],system[MAX_PATH],app[MAX_PATH],driver[MAX_PATH],
    queued[MAX_PATH],ini[MAX_PATH],backup[MAX_PATH],text[1024],observed[1024];
    const char *args=GetCommandLineA(),*last=args;DWORD n,offset=64,i;int result,expected=2;
    while(*args){if(*args==' ')last=args+1;args++;}while(*last>='0'&&*last<='9')test_case=test_case*10+(*last++-'0');CHECK(test_case<=12);
    n=GetModuleFileNameA(0,root,sizeof root);CHECK(n&&n<sizeof root);
    while(n&&root[n-1]!='\\')n--;CHECK(n);root[n]=0;
    CHECK(ua_ndis_join(windows,root,"win"));CHECK(CreateDirectoryA(windows,0));
    CHECK(ua_ndis_join(system,windows,"system"));CHECK(CreateDirectoryA(system,0));
    CHECK(ua_ndis_join(app,root,"app"));CHECK(CreateDirectoryA(app,0));
    CHECK(ua_ndis_join(driver,system,"NDIS.VXD"));CHECK(ua_ndis_join(queued,windows,"new ndis.vxd"));
    CHECK(ua_ndis_join(ini,windows,"WININIT.INI"));CHECK(ua_ndis_join(backup,app,test_case==8||test_case==9?"NDISQ.BAK":"NDIS95.BAK"));
    for(i=0;i<sizeof original;i++)original[i]=0x55;
    if(test_case==0)offset=0;if(test_case==1)offset=sizeof original-UA_NDIS_PATCH_SIZE;
    for(i=0;i<UA_NDIS_PATCH_SIZE;i++)original[offset+i]=ua_ndis_original[i];
    if(test_case==2)for(i=0;i<UA_NDIS_PATCH_SIZE;i++)original[offset+i]=ua_ndis_patched[i];
    if(test_case==3||test_case==5){for(i=0;i<UA_NDIS_PATCH_SIZE;i++)original[128+i]=test_case==3?ua_ndis_original[i]:ua_ndis_patched[i];expected=0;}
    if(test_case==4){original[offset+5]^=1;expected=0;}
    if(test_case==6){original[offset+11]=0x29;original[offset+12]=0xd0;}
    write_fixture(driver,original,sizeof original);
    if(test_case==7)CHECK(SetFileAttributesA(driver,FILE_ATTRIBUTE_READONLY|FILE_ATTRIBUTE_HIDDEN));
    if(test_case==8||test_case==9){
        text[0]=0;lstrcatA(text,"[Rename]\r\n");lstrcatA(text,driver);lstrcatA(text,"=\"");lstrcatA(text,queued);lstrcatA(text,"\"\r\n");
        write_fixture(ini,text,lstrlenA(text));
        if(test_case==8)write_fixture(queued,original,sizeof original);else expected=0;
    }
    if(test_case==10){CHECK(CreateDirectoryA(backup,0));expected=0;}
    if(test_case==11){write_fixture(backup,"old evidence",12);}
    if(test_case==12){inject_write_failure=1;expected=0;}
    if(test_case==2)expected=1;
    result=ua_ndis_repair(windows,system,app,log_line);CHECK(result==expected);
    if(test_case==8){n=read_fixture(ini,observed,sizeof observed);CHECK(n==(DWORD)lstrlenA(text));observed[n]=0;CHECK(!lstrcmpA(text,observed));
        CHECK(read_fixture(driver,actual,sizeof actual)==sizeof original);
        for(i=0;i<sizeof original;i++)CHECK(actual[i]==original[i]);lstrcpyA(driver,queued);}
    CHECK(read_fixture(driver,actual,sizeof actual)==sizeof original);
    for(i=0;i<sizeof original;i++)CHECK(actual[i]==(expected==2&&i>=offset&&i<offset+UA_NDIS_PATCH_SIZE?ua_ndis_patched[i-offset]:original[i]));
    if(test_case==7)CHECK((GetFileAttributesA(driver)&(FILE_ATTRIBUTE_READONLY|FILE_ATTRIBUTE_HIDDEN))==(FILE_ATTRIBUTE_READONLY|FILE_ATTRIBUTE_HIDDEN));
    if(test_case==11){n=read_fixture(backup,observed,sizeof observed);CHECK(n==12);observed[n]=0;CHECK(!lstrcmpA(observed,"old evidence"));}
    if(expected==2)CHECK(ua_ndis_repair(windows,system,app,log_line)==1);
    ExitProcess(0);
}
