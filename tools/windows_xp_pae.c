/* XP-only adaptation of evgen-b/PatchPAE3 (commit 3e1d3b65f5c3c1ec0c4759f707d3017e51113103).
 * Patch patterns by evgen_b, based on wj32 / XP64G; CC-BY-4.0.
 * Changes: strict XP version/PE checks, unique matches in executable sections,
 * separate output files, original boot entry retained. No other OS is patched.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winver.h>
#include "windows_xp_pae_strings.h"

static HANDLE log_file;
void *memset(void *p,int v,size_t n){volatile BYTE *b=p;while(n--)*b++=(BYTE)v;return p;}
static void logline(const char *s) { DWORD n; if(log_file!=INVALID_HANDLE_VALUE){WriteFile(log_file,s,lstrlenA(s),&n,0);WriteFile(log_file,"\r\n",2,&n,0);FlushFileBuffers(log_file);} }
static BYTE *readfile(const char *p,DWORD *size) {
    HANDLE h=CreateFileA(p,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0); DWORD n=0;
    if(h==INVALID_HANDLE_VALUE)return 0;
    *size=GetFileSize(h,0); if(*size==INVALID_FILE_SIZE||*size>16777216){CloseHandle(h);return 0;}
    BYTE *b=GlobalAlloc(GPTR,*size+2); BOOL ok=b&&ReadFile(h,b,*size,&n,0)&&n==*size;CloseHandle(h);
    if(!ok){if(b)GlobalFree(b);return 0;}return b;
}
static BOOL writefile(const char *p,const BYTE *b,DWORD n) {
    HANDLE h=CreateFileA(p,GENERIC_WRITE,0,0,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,0);DWORD done=0;
    if(h==INVALID_HANDLE_VALUE)return FALSE;
    BOOL ok=WriteFile(h,b,n,&done,0)&&done==n&&FlushFileBuffers(h);CloseHandle(h);return ok;
}
static BOOL xp_version(const char *p){
    DWORD ignored,n=GetFileVersionInfoSizeA(p,&ignored);if(!n)return FALSE;
    void *b=GlobalAlloc(GPTR,n);VS_FIXEDFILEINFO *v=0;UINT z=0;
    BOOL ok=b&&GetFileVersionInfoA(p,0,n,b)&&VerQueryValueA(b,"\\",(void**)&v,&z)&&z>=sizeof(*v)
        &&v->dwSignature==0xfeef04bd&&v->dwFileVersionMS==0x00050001&&HIWORD(v->dwFileVersionLS)==2600;
    if(b)GlobalFree(b);return ok;
}
static LONG match(BYTE *b,DWORD n,const BYTE *pattern,DWORD length){
    IMAGE_DOS_HEADER *d=(void*)b; if(n<sizeof(*d)||d->e_magic!=IMAGE_DOS_SIGNATURE||d->e_lfanew<0||(DWORD)d->e_lfanew>n-sizeof(IMAGE_NT_HEADERS32))return -1;
    IMAGE_NT_HEADERS32 *pe=(void*)(b+d->e_lfanew);
    if(pe->Signature!=IMAGE_NT_SIGNATURE||pe->FileHeader.Machine!=IMAGE_FILE_MACHINE_I386||pe->OptionalHeader.Magic!=IMAGE_NT_OPTIONAL_HDR32_MAGIC)return -1;
    IMAGE_SECTION_HEADER *s=IMAGE_FIRST_SECTION(pe); LONG result=-1;
    if((BYTE*)(s+pe->FileHeader.NumberOfSections)>b+n)return -1;
    for(WORD j=0;j<pe->FileHeader.NumberOfSections;j++){
        DWORD start=s[j].PointerToRawData,size=s[j].SizeOfRawData;
        if(!(s[j].Characteristics&IMAGE_SCN_MEM_EXECUTE))continue;
        if(start>n||size>n-start||size<length)return -1;
        for(DWORD i=start;i<=start+size-length;i++){
            DWORD k=0;while(k<length&&b[i+k]==pattern[k])k++;
            if(k==length){if(result!=-1)return -2;result=(LONG)i;}
        }
    }return result;
}
static BOOL patch(const char *input,const char *output,BOOL hal){
    if(!xp_version(input)){logline("REFUSED: not an XP 5.1.2600 file");return FALSE;}
    DWORD n=0;BYTE *b=readfile(input,&n);if(!b)return FALSE;
    const BYTE k1[]={0x3b,0xfb,0x73,0xd9,0x6a,7,0xe8};
    const BYTE k1b[]={0x3b,0xd9,0x73,0xdb,0x6a,7,0xe8};
    const BYTE k2[]={0x6a,7,0x8b,0xf0,0x89,0x5d,0xfc,0x89,0x7d,0xf8,0xe8};
    const BYTE h1[]={0x8a,0x4f,5,0x84,0xc9,0x53,0x74,0x17,0x80,0x3d};
    const BYTE h2[]={0x6a,1,0x6a,0x10,0x68,0,0,0,1,0x53};
    LONG a=match(b,n,hal?h1:k1,hal?sizeof(h1):sizeof(k1));
    if(!hal&&a==-1)a=match(b,n,k1b,sizeof(k1b));
    LONG c=match(b,n,hal?h2:k2,hal?sizeof(h2):sizeof(k2));
    BOOL ok=a>=0&&c>=0&&(DWORD)a+16<n&&(DWORD)c+25<n;
    if(ok&&hal)ok=b[c+10]==0xc7&&b[c+11]==5&&b[c+16]==0x40&&b[c+17]==0&&b[c+18]==0&&b[c+19]==0&&b[c+20]==0xbe&&b[c+21]==0&&b[c+22]==0&&b[c+23]==1&&b[c+24]==0;
    if(ok&&!hal)ok=b[a+12]==1&&b[a+13]==0x75&&b[c+15]==0x3c&&b[c+16]==1&&b[c+17]==0x75;
    if(!ok){logline("REFUSED: unsupported or ambiguous patch pattern");GlobalFree(b);return FALSE;}
    if(hal){b[a+6]=0xeb;b[c+3]=0x30;for(int i=5;i<9;i++)b[c+i]=0xff;b[c+16]=0;b[c+17]=0x40;b[c+23]=3;}
    else {b[a+13]=0x74;b[c+17]=0x74;}
    IMAGE_NT_HEADERS32 *pe=(void*)(b+((IMAGE_DOS_HEADER*)b)->e_lfanew);
    pe->OptionalHeader.CheckSum=0;DWORD sum=0;
    for(DWORD i=0;i<n;i+=2){sum+=(DWORD)b[i]+(i+1<n?((DWORD)b[i+1]<<8):0);sum=(sum&0xffff)+(sum>>16);}
    sum=(sum&0xffff)+(sum>>16);pe->OptionalHeader.CheckSum=sum+n;
    ok=writefile(output,b,n);GlobalFree(b);return ok;
}
/* Case-insensitive: does boot.ini already carry the USOS PAE entry? */
static BOOL pae_entry_present(const char *ini){
    DWORD n=0;BYTE *b=readfile(ini,&n);if(!b)return FALSE;
    static const char needle[]="/kernel=usospae.exe";DWORD k=sizeof(needle)-1;BOOL found=FALSE;
    for(DWORD i=0;!found&&i+k<=n;i++){DWORD j=0;while(j<k){BYTE c=b[i+j];if(c>='A'&&c<='Z')c+=32;if(c!=(BYTE)needle[j])break;j++;}found=j==k;}
    GlobalFree(b);return found;
}
/* Write staged = boot.ini with the PAE entry first in [operating systems] and
   timeout=0. All original entries are retained byte-for-byte.
   NTLDR selects the FIRST entry whose ARC path equals default=, so the PAE
   entry (same ARC path) becomes the default and timeout=0 boots it without a
   menu; the original entry stays reachable via F8 -> "Return to OS Choices Menu". */
static BOOL stage_bootini(const char *ini,const char *staged){
    static char original[4096],arc[512];
    GetPrivateProfileStringA("boot loader","default","",arc,sizeof(arc),ini);
    if(!arc[0]){logline("REFUSED: boot.ini has no default entry");return FALSE;}
    GetPrivateProfileStringA("operating systems",arc,"",original,sizeof(original),ini);
    if(!original[0]){logline("REFUSED: default entry missing from [operating systems]");return FALSE;}
    DWORD n=0;BYTE *old=readfile(ini,&n);if(!old)return FALSE;
    char *out=GlobalAlloc(GPTR,n+2048);if(!out){GlobalFree(old);return FALSE;}
    DWORD p=0;BOOL inserted=FALSE;
    for(DWORD i=0;i<n;){DWORD end=i;while(end<n&&old[end]!='\n')end++;
        DWORD line_len=end-i;
        for(DWORD j=i;j<end;j++)out[p++]=old[j];out[p++]='\n';
        if(line_len>=19&&line_len<=20){char line[24]={0};for(DWORD j=0;j<line_len;j++)line[j]=old[i+j];if(line[line_len-1]=='\r')line[line_len-1]=0;
            if(lstrcmpiA(line,"[operating systems]")==0){
                if(inserted){GlobalFree(out);GlobalFree(old);logline("REFUSED: duplicate operating systems section");return FALSE;}
                p+=wsprintfA(out+p,"%s=\"Windows XP - USOS PAE (experimental)\" /fastdetect /pae /noexecute=optin /kernel=usospae.exe /hal=usoshal.dll\r\n",arc);inserted=TRUE;
            }}i=end<n?end+1:end;
    }
    DeleteFileA(staged);
    BOOL ok=inserted&&writefile(staged,(BYTE*)out,p)&&WritePrivateProfileStringA("boot loader","timeout","0",staged);
    GlobalFree(out);GlobalFree(old);return ok;
}
enum { RUN_FAILED=0, RUN_ENABLED=1, RUN_ALREADY=2 };
static int run(BOOL fallback){
    OSVERSIONINFOA version={sizeof(version)};if(!GetVersionExA(&version)||version.dwMajorVersion!=5||version.dwMinorVersion!=1||version.dwBuildNumber!=2600){logline("REFUSED: not Windows XP 5.1.2600");return RUN_FAILED;}
    static char system[MAX_PATH],kernel[MAX_PATH],hal[MAX_PATH],newkernel[MAX_PATH],newhal[MAX_PATH],ini[MAX_PATH],backup[MAX_PATH],staged[MAX_PATH];
    if(!GetSystemDirectoryA(system,sizeof(system))||lstrlenA(system)>200||system[1]!=':')return RUN_FAILED;
    wsprintfA(kernel,"%s\\ntkrnlpa.exe",system);wsprintfA(hal,"%s\\hal.dll",system);
    /* Own output names: no Setup- or WFP-protected file is replaced or created. */
    wsprintfA(newkernel,"%s\\usospae.exe",system);wsprintfA(newhal,"%s\\usoshal.dll",system);
    wsprintfA(ini,"%c:\\boot.ini",system[0]);wsprintfA(backup,"%c:\\USOS\\XP\\boot-original.ini",system[0]);
    wsprintfA(staged,"%c:\\USOS\\XP\\boot-pae.ini",system[0]);
    if(pae_entry_present(ini)){logline("PAE entry already present in boot.ini; nothing changed");return RUN_ALREADY;}
    BOOL have_backup=GetFileAttributesA(backup)!=INVALID_FILE_ATTRIBUTES;
    if(have_backup){
        /* Only the first-logon fallback may re-apply after an earlier run whose
           entry did not survive; the first backup (true original) is kept. */
        if(!fallback){logline("REFUSED: previous PAE backup exists; inspect before retry");return RUN_FAILED;}
        logline("fallback: backup exists but PAE entry missing; re-applying, original backup kept");
        DeleteFileA(newkernel);DeleteFileA(newhal);
    }
    if(!patch(kernel,newkernel,FALSE)||!patch(hal,newhal,TRUE))return RUN_FAILED;
    if(!have_backup){
        DWORD n=0;BYTE *old=readfile(ini,&n);if(!old)return RUN_FAILED;
        BOOL saved=writefile(backup,old,n);GlobalFree(old);if(!saved){logline("REFUSED: cannot write boot.ini backup");return RUN_FAILED;}
    }
    if(!stage_bootini(ini,staged))return RUN_FAILED;
    /* boot.ini is read-only/hidden/system: clear, replace atomically, restore. */
    BOOL ok=FALSE;DWORD attrs=GetFileAttributesA(ini);
    if(attrs!=INVALID_FILE_ATTRIBUTES&&SetFileAttributesA(ini,FILE_ATTRIBUTE_NORMAL)){
        ok=MoveFileExA(staged,ini,MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH);
        SetFileAttributesA(ini,attrs);
    }
    if(!ok)logline("REFUSED: could not replace boot.ini");
    return ok&&pae_entry_present(ini)?RUN_ENABLED:RUN_FAILED;
}
/* Modes: setup-end (default, also /silent /quiet; [SetupParams] UserExecute),
   first-logon check/fallback (/firstlogon; GuiRunOnce), interactive (/interactive). */
enum { MODE_SETUP_END=0, MODE_FIRST_LOGON=1, MODE_INTERACTIVE=2 };
static int parse_mode(const char *c){
    int mode=MODE_SETUP_END;if(!c)return mode;
    if(*c=='"'){c++;while(*c&&*c!='"')c++;if(*c)c++;}else{while(*c&&*c!=' '&&*c!='\t')c++;}
    for(;;){
        while(*c==' '||*c=='\t')c++;
        if(!*c)return mode;
        char token[16];int n=0;while(*c&&*c!=' '&&*c!='\t'){if(n<15)token[n]=*c;n++;c++;}
        if(n>=16)continue;
        token[n]=0;
        if(lstrcmpiA(token,"/firstlogon")==0)mode=MODE_FIRST_LOGON;
        else if(lstrcmpiA(token,"/interactive")==0)mode=MODE_INTERACTIVE;
        else if(lstrcmpiA(token,"/silent")==0||lstrcmpiA(token,"/quiet")==0)mode=MODE_SETUP_END;
    }
}
static void reboot_now(void){
    HANDLE token;TOKEN_PRIVILEGES tp;
    if(OpenProcessToken(GetCurrentProcess(),TOKEN_ADJUST_PRIVILEGES|TOKEN_QUERY,&token)){
        if(LookupPrivilegeValueA(0,"SeShutdownPrivilege",&tp.Privileges[0].Luid)){
            tp.PrivilegeCount=1;tp.Privileges[0].Attributes=SE_PRIVILEGE_ENABLED;AdjustTokenPrivileges(token,FALSE,&tp,0,0,0);
        }
        CloseHandle(token);
    }
    /* Planned, operating-system reconfiguration. */
    ExitWindowsEx(EWX_REBOOT,0x80000000|0x00020000|0x00000004);
}
/* User-visible strings: the chosen language comes from pae-strings.ini next to
   pae.exe (UTF-16LE INI, [xp_pae]; written by the USB flow from the installer's
   language choice, only that language). Missing file/key: built-in English. */
static void ini_string(const WCHAR *ini,const WCHAR *key,const WCHAR *fallback,WCHAR *out,DWORD size){
    DWORD n=ini?GetPrivateProfileStringW(L"xp_pae",key,L"",out,size,ini):0;
    if(n==0||n>=size-2||!out[0])lstrcpynW(out,fallback,size);
}
static BOOL strings_path(WCHAR *p){
    DWORD n=GetModuleFileNameW(0,p,MAX_PATH);if(n==0||n>=MAX_PATH)return FALSE;
    while(n&&p[n-1]!=L'\\')n--;
    if(n+16>=MAX_PATH)return FALSE;
    p[n]=0;lstrcatW(p,L"pae-strings.ini");return GetFileAttributesW(p)!=INVALID_FILE_ATTRIBUTES;
}
static void open_log(void){
    char p[MAX_PATH];GetModuleFileNameA(0,p,sizeof(p));int i=lstrlenA(p);while(i&&p[i-1]!='\\')i--;p[i]=0;lstrcatA(p,"pae-install.log");
    /* Append: the setup-end run and the first-logon check share one log. */
    log_file=CreateFileA(p,GENERIC_WRITE,FILE_SHARE_READ,0,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,0);
    if(log_file!=INVALID_HANDLE_VALUE)SetFilePointer(log_file,0,0,FILE_END);
}
void entry(void){
    int mode=parse_mode(GetCommandLineA());
    open_log();
    logline("USOS XP PAE v3: originals retained; separate kernel/HAL; no host patching");
    logline(mode==MODE_FIRST_LOGON?"path=first-logon (GuiRunOnce check)":mode==MODE_INTERACTIVE?"path=interactive":"path=setup-end (UserExecute, silent)");
    int r=run(mode==MODE_FIRST_LOGON);
    if(r==RUN_ENABLED)logline(mode==MODE_FIRST_LOGON?"RESULT: enabled by FIRST-LOGON FALLBACK; restart required":"RESULT: PAE ENTRY READY; default entry, timeout=0; used from the next boot");
    else if(r==RUN_ALREADY)logline(mode==MODE_FIRST_LOGON?"RESULT: already enabled at setup end; nothing shown":"RESULT: already enabled");
    else logline(mode==MODE_SETUP_END?"RESULT: PAE NOT ENABLED at setup end; first-logon fallback will retry":"RESULT: PAE NOT ENABLED; original XP entry retained");
    if(mode==MODE_FIRST_LOGON&&r==RUN_ENABLED){
        static WCHAR ini[MAX_PATH],prompt[1024],title[128];
        BOOL localized=strings_path(ini);
        logline(localized?"strings=pae-strings.ini":"strings=built-in English");
        ini_string(localized?ini:0,L"restart_prompt",USOS_XP_PAE_RESTART_PROMPT_EN,prompt,1024);
        ini_string(localized?ini:0,L"title",USOS_XP_PAE_TITLE_EN,title,128);
        int answer=MessageBoxW(0,prompt,title,MB_YESNO|MB_ICONQUESTION|MB_SETFOREGROUND);
        logline(answer==IDYES?"user chose restart now":"user postponed restart");
        if(log_file!=INVALID_HANDLE_VALUE){CloseHandle(log_file);log_file=INVALID_HANDLE_VALUE;}
        if(answer==IDYES)reboot_now();
    }else if(mode==MODE_INTERACTIVE){
        MessageBoxA(0,r!=RUN_FAILED?"PAE entry is the default boot entry (timeout=0). The original XP entry stays available via F8 -> Return to OS Choices Menu.":"PAE was not enabled. The original XP entry remains available. See USOS\\XP\\pae-install.log.","USOS XP PAE",MB_OK|(r!=RUN_FAILED?MB_ICONINFORMATION:MB_ICONWARNING));
    }
    if(log_file!=INVALID_HANDLE_VALUE)CloseHandle(log_file);
    ExitProcess(r!=RUN_FAILED?0:1);
}
