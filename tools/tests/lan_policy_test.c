/* Exercises target parsing/state only, in this executable's test directory.
 * No desktop enumeration, COM, network, setup or target entry is executed. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
static DWORD test_os_version=0x08ae5a04UL;
static DWORD WINAPI test_version(void){return test_os_version;}
static LONG test_setup_status=ERROR_FILE_NOT_FOUND;
static unsigned test_setup_opens,test_setup_closes;
static LONG WINAPI test_reg_open(HKEY root,LPCSTR key,DWORD options,REGSAM access,PHKEY result){
  (void)root;(void)key;(void)options;(void)access;test_setup_opens++;
  if(test_setup_status==ERROR_SUCCESS)*result=(HKEY)(ULONG_PTR)1;
  return test_setup_status;}
static LONG WINAPI test_reg_close(HKEY key){(void)key;test_setup_closes++;return ERROR_SUCCESS;}
static char *test_command="unit.exe";
static LPSTR WINAPI test_command_line(void){return test_command;}
#define GetVersion test_version
#define GetCommandLineA test_command_line
#define RegOpenKeyExA test_reg_open
#define RegCloseKey test_reg_close
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
  copy(system_id,"98");CHECK(!native95_handoff());copy(system_id,"95");
  test_os_version=0x84570004UL;CHECK(!native95_handoff());
  test_os_version=0x03b60004UL;CHECK(!native95_handoff());
  test_os_version=0x08ae5a04UL;local(path,"PHASE1.OK");DeleteFileA(path);
  local(ini,"NETCFG.INI");DeleteFileA(ini);fixture("MSBATCH.INF","[Install]\r\n;USOS-NETWORK=on\r\n;USOS-HOME=http://example.test/?a=1&b=2\r\n");
  CHECK(read_config()&&eq(system_id,"ME")&&eq(home,"http://example.test/?a=1&b=2"));
  local(path,"NETSTATE.DAT");DeleteFileA(path);CHECK(load_state(0));CHECK(usos_lan_attempt(&state));state.done=USOS_LAN_IE;CHECK(save_state());
  state.tries=99;CHECK(load_state(0)&&state.tries==1&&state.done==USOS_LAN_IE);
  fixture("NETSTATE.DAT","broken");CHECK(!load_state(0)&&load_state(1));
  fixture("NETCFG.INI","system=ME\nnetwork=on\nhome_page=about:blank\nnetwork=on\n");CHECK(!read_config());
  local(path,"NETSTATE.DAT");DeleteFileA(path);DeleteFileA(ini);local(path,"MSBATCH.INF");DeleteFileA(path);ExitProcess(0);
}
