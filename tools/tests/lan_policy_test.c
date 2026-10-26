/* Exercises target parsing/state only, in this executable's test directory.
 * No desktop enumeration, COM, network, setup or target entry is executed. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
static DWORD test_os_version=0x08ae5a04UL;
static DWORD WINAPI test_version(void){return test_os_version;}
static DWORD test_build_number=0x040003b6UL,test_platform=VER_PLATFORM_WIN32_WINDOWS,test_minor;
static BOOL test_version_available=TRUE;
static BOOL WINAPI test_version_ex(LPOSVERSIONINFOA version){
  if(!test_version_available)return FALSE;
  version->dwPlatformId=test_platform;version->dwMajorVersion=4;version->dwMinorVersion=test_minor;version->dwBuildNumber=test_build_number;return TRUE;}
static LONG test_setup_status=ERROR_FILE_NOT_FOUND;
static unsigned test_setup_opens,test_setup_closes;
static const char *test_ie_version;
static LONG WINAPI test_reg_open(HKEY root,LPCSTR key,DWORD options,REGSAM access,PHKEY result){
  (void)root;(void)options;(void)access;
  if(!lstrcmpA(key,"Software\\Microsoft\\Internet Explorer")){
    if(test_ie_version){*result=(HKEY)(ULONG_PTR)2;return ERROR_SUCCESS;}return ERROR_FILE_NOT_FOUND;}
  test_setup_opens++;
  if(test_setup_status==ERROR_SUCCESS)*result=(HKEY)(ULONG_PTR)1;
  return test_setup_status;}
static LONG WINAPI test_reg_close(HKEY key){(void)key;test_setup_closes++;return ERROR_SUCCESS;}
static LONG WINAPI test_reg_query(HKEY key,LPCSTR name,LPDWORD reserved,LPDWORD type,LPBYTE data,LPDWORD size){
  DWORD needed;(void)reserved;
  if(key!=(HKEY)(ULONG_PTR)2||lstrcmpA(name,"Version")||!test_ie_version)return ERROR_FILE_NOT_FOUND;
  needed=(DWORD)lstrlenA(test_ie_version)+1;if(*size<needed)return ERROR_MORE_DATA;
  lstrcpyA((char*)data,test_ie_version);*size=needed;*type=REG_SZ;return ERROR_SUCCESS;}
static char *test_command="unit.exe";
static LPSTR WINAPI test_command_line(void){return test_command;}
#define GetVersion test_version
#define GetVersionExA test_version_ex
#define GetCommandLineA test_command_line
#define RegOpenKeyExA test_reg_open
#define RegCloseKey test_reg_close
#define RegQueryValueExA test_reg_query
#define entry target_entry_not_called
#define USOS_LAN_9X
#include "../windows_usos_lan.c"
#undef entry
#define CHECK(x) do{if(!(x))ExitProcess(__LINE__);}while(0)
static int calls[2];
static int successful(void *p){calls[*(unsigned*)p]++;return 1;}
static int unsuccessful(void *p){calls[*(unsigned*)p]++;return 0;}
static void fixture(const char *name,const char *text){HANDLE f;DWORD n;
  local(path,name);f=CreateFileA(path,GENERIC_WRITE,0,0,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,0);CHECK(f!=INVALID_HANDLE_VALUE);
  CHECK(WriteFile(f,text,len(text),&n,0)&&n==len(text));CloseHandle(f);}
void entry(void){unsigned i,slot;DWORD n;char *p;UsosLanState fake={0,0,0,0};
  CHECK(sizeof(UsosLanState)==16);
  for(i=0;i<3;i++){CHECK(usos_lan_attempt(&fake));slot=0;CHECK(usos_lan_step(&fake,USOS_LAN_IE,successful,&slot));slot=1;CHECK(!usos_lan_step(&fake,USOS_LAN_FAVORITE,unsuccessful,&slot));}
  CHECK(!usos_lan_attempt(&fake)&&calls[0]==1&&calls[1]==3);
  fake.done|=USOS_LAN_FAVORITE;usos_lan_refresh(&fake);CHECK(fake.tries==0&&(fake.done&USOS_LAN_FAVORITE)&&!(fake.done&USOS_LAN_IE));
  CHECK(icw_target("C:\\Program Files\\Internet Explorer\\Connection Wizard\\ICWCONN1.EXE"));
  CHECK(icw_target("c:/x/icwconn1.exe")&&!icw_target("C:\\x\\ICWCONN1.EXE.txt")&&!icw_target("unrelated.exe"));
  test_command="unit.exe /refresh";CHECK(refresh_requested());test_command="unit.exe /r";CHECK(!refresh_requested());
  n=GetModuleFileNameA(0,dir,sizeof dir);CHECK(n&&n<sizeof dir);p=dir+n;while(p>dir&&p[-1]!='\\')p--;*p=0;
  copy(system_id,"95");test_os_version=0x83b60004UL;
  local(path,"PHASE1.OK");DeleteFileA(path);CHECK(!native95_handoff()&&test_setup_opens==0);
  fixture("PHASE1.OK","phase1=qemu elapsed=123\r\n");CHECK(native95_handoff());
  test_setup_status=ERROR_SUCCESS;CHECK(!native95_handoff()&&test_setup_closes==1);
  test_setup_status=ERROR_ACCESS_DENIED;CHECK(!native95_handoff());
  test_setup_status=ERROR_FILE_NOT_FOUND;
  fixture("PHASE1.OK","phase1=qemu elapsed=x\r\n");CHECK(!native95_handoff());
  fixture("PHASE1.OK","phase1=qemu elapsed=123\r\nextra");CHECK(!native95_handoff());
  fixture("PHASE1.OK","phase1=qemu elapsed=0\r\n");CHECK(native95_handoff());
  fixture("PHASE1.OK","phase1=native\r\n");CHECK(native95_handoff());
  fixture("PHASE1.OK","phase1=native");CHECK(!native95_handoff());
  fixture("PHASE1.OK","phase1=native\n");CHECK(!native95_handoff());
  fixture("PHASE1.OK","phase1=native \r\n");CHECK(!native95_handoff());
  fixture("PHASE1.OK","phase1=native\r\nx");CHECK(!native95_handoff());
  fixture("PHASE1.OK","phase1=nativ\r\n");CHECK(!native95_handoff());
  test_setup_status=ERROR_SUCCESS;fixture("PHASE1.OK","phase1=native\r\n");CHECK(!native95_handoff());test_setup_status=ERROR_FILE_NOT_FOUND;
  copy(system_id,"98");CHECK(!native95_handoff());copy(system_id,"95");
  test_build_number=1111;CHECK(!native95_handoff());test_build_number=0x040003b6UL;
  test_platform=VER_PLATFORM_WIN32_NT;CHECK(!native95_handoff());test_platform=VER_PLATFORM_WIN32_WINDOWS;
  test_version_available=FALSE;CHECK(!native95_handoff());test_version_available=TRUE;
  test_os_version=0x80005a04UL;test_minor=90;test_build_number=0x045a0bb8UL;local(path,"PHASE1.OK");DeleteFileA(path);
  copy(system_id,"95");lstrcpyA(home,"about:blank");fixture("START.HTM","own local legacy page");
  CHECK(!memcmp(start_page(),"file://",7));
  test_ie_version="4.70.1158";CHECK(!memcmp(start_page(),"file://",7));
  test_ie_version="5.50.4807.2300";CHECK(!lstrcmpA(start_page(),"about:blank"));
  test_ie_version="6.00.2800.1106";CHECK(!lstrcmpA(start_page(),"about:blank"));
  test_ie_version="5.invalid";CHECK(!memcmp(start_page(),"file://",7));
  test_ie_version="5..50";CHECK(!memcmp(start_page(),"file://",7));
  test_ie_version=0;lstrcpyA(home,"http://example.test");CHECK(!lstrcmpA(start_page(),home));
  copy(system_id,"ME");lstrcpyA(home,"about:blank");CHECK(!lstrcmpA(start_page(),home));
  local(path,"START.HTM");DeleteFileA(path);
  local(ini,"NETCFG.INI");DeleteFileA(ini);fixture("MSBATCH.INF","[Install]\r\n;USOS-NETWORK=on\r\n;USOS-HOME=http://example.test/?a=1&b=2\r\n");
  CHECK(read_config()&&eq(system_id,"ME")&&eq(home,"http://example.test/?a=1&b=2"));
  /* The simulated GetVersion high word carries only the Win9x flag.
     GetVersionEx carries the build in LOWORD (the high word is nonzero).
     Exercise the production config writer and source950 gate for all six. */
  { static const struct {DWORD legacy,minor,build;const char *id;} cases[]={
      {0x80000004UL,0,0x040003b6UL,"95"}, /* 95 RTM 950 */
      {0x80000004UL,0,0x040003b6UL,"95"}, /* OSR1 950a */
      {0x80000004UL,0,0x04000457UL,"95"}, /* OSR2 1111 */
      {0x80000a04UL,10,0x040a07ceUL,"98"}, /* FE 1998 */
      {0x80000a04UL,10,0x040a08aeUL,"98SE"}, /* SE 2222 */
      {0x80005a04UL,90,0x045a0bb8UL,"ME"} /* ME 3000 */
    };
    fixture("PHASE1.OK","phase1=qemu elapsed=123\r\n");
    for(i=0;i<sizeof(cases)/sizeof(cases[0]);i++){
      DeleteFileA(ini);test_os_version=cases[i].legacy;test_minor=cases[i].minor;test_build_number=cases[i].build;
      CHECK(read_config()&&eq(system_id,cases[i].id));CHECK(native95_handoff()==(i<2));
    }
    DeleteFileA(ini);test_version_available=FALSE;CHECK(!read_config()&&GetFileAttributesA(ini)==INVALID_FILE_ATTRIBUTES);test_version_available=TRUE;
    test_platform=VER_PLATFORM_WIN32_NT;CHECK(!read_config());test_platform=VER_PLATFORM_WIN32_WINDOWS;
    test_minor=1;CHECK(!read_config());test_minor=90;CHECK(read_config());
    local(path,"PHASE1.OK");DeleteFileA(path);
  }
  local(path,"NETSTATE.DAT");DeleteFileA(path);CHECK(load_state(0));CHECK(usos_lan_attempt(&state));state.done=USOS_LAN_IE;CHECK(save_state());
  state.tries=99;CHECK(load_state(0)&&state.tries==1&&state.done==USOS_LAN_IE);
  fixture("NETSTATE.DAT","broken");CHECK(!load_state(0)&&load_state(1));
  fixture("NETCFG.INI","system=ME\nnetwork=on\nhome_page=about:blank\nnetwork=on\n");CHECK(!read_config());
  local(path,"NETSTATE.DAT");DeleteFileA(path);DeleteFileA(ini);local(path,"MSBATCH.INF");DeleteFileA(path);ExitProcess(0);
}
