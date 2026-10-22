/* Host-only fake Win32 lifecycle; never creates a process or opens a COM port. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
static DWORD supplied_exit,recorded_exit,wait_value,read_calls,com_open_failed,create_calls;
static DWORD observation_mode,file_end_seen;
static int race_mode;
static HANDLE race_native,race_begin,race_release,race_unblocked,race_mutex,race_observer;
static char race_log[16384];static unsigned race_log_used;
static int command_exact;static const WCHAR *fake_class=L"Edit";
static HANDLE WINAPI fake_file(LPCSTR a,DWORD b,DWORD c,LPSECURITY_ATTRIBUTES e,DWORD f,DWORD g,HANDLE h){(void)b;(void)c;(void)e;(void)f;(void)g;(void)h;if(lstrcmpA(a,"\\\\.\\COM1")==0){com_open_failed=1;return INVALID_HANDLE_VALUE;}return race_mode?(HANDLE)7:INVALID_HANDLE_VALUE;}
static BOOL WINAPI fake_create(LPCSTR app,LPSTR command,LPSECURITY_ATTRIBUTES a,LPSECURITY_ATTRIBUTES b,BOOL inherit,DWORD flags,LPVOID env,LPCSTR cwd,LPSTARTUPINFOA start,LPPROCESS_INFORMATION process){
 (void)app;(void)a;(void)b;(void)env;(void)cwd;
 create_calls++;command_exact=lstrcmpA(command,"setup -newsetup")==0&&!inherit&&!flags&&start->cb==sizeof(*start);
 process->hProcess=race_mode?race_native:(HANDLE)3;process->hThread=(HANDLE)4;return TRUE;
}
static HANDLE WINAPI fake_thread(LPSECURITY_ATTRIBUTES a,SIZE_T b,LPTHREAD_START_ROUTINE c,LPVOID e,DWORD f,LPDWORD g){if(race_mode){race_observer=CreateThread(a,b,c,e,f,g);return race_observer;}return 0;}
static DWORD WINAPI fake_wait(HANDLE h,DWORD duration){
 DWORD result;if(race_mode){
  if(h==race_native&&duration!=INFINITE)return WAIT_TIMEOUT;
  result=WaitForSingleObject(h,duration);if(h==race_native&&duration==INFINITE)SetEvent(race_unblocked);return result;
 }
 if(h==(HANDLE)11)return WAIT_OBJECT_0;wait_value=duration;return observation_mode?WAIT_TIMEOUT:WAIT_OBJECT_0;
}
static HANDLE WINAPI fake_mutex(LPSECURITY_ATTRIBUTES a,BOOL b,LPCSTR c){if(race_mode){race_mutex=CreateMutexA(a,b,c);return race_mutex;}return (HANDLE)11;}
static BOOL WINAPI fake_release(HANDLE h){return race_mode?ReleaseMutex(h):TRUE;}
static BOOL WINAPI fake_flush(HANDLE h){(void)h;return TRUE;}
static HANDLE real_thread(LPTHREAD_START_ROUTINE start){return CreateThread(0,0,start,0,0,0);}
static DWORD real_wait(HANDLE h,DWORD ms){return WaitForSingleObject(h,ms);}
static void real_close(HANDLE h){if(h)CloseHandle(h);}
static BOOL WINAPI fake_exit_code(HANDLE h,LPDWORD code){(void)h;*code=supplied_exit;return TRUE;}
static BOOL WINAPI fake_close(HANDLE h){(void)h;return TRUE;}
static void WINAPI fake_exit(UINT code){recorded_exit=code;}
static BOOL WINAPI fake_visible(HWND h){(void)h;return TRUE;}
static int WINAPI fake_class_name(HWND h,LPWSTR out,int maximum){(void)h;if(lstrlenW(fake_class)>=maximum)return 0;lstrcpyW(out,fake_class);return lstrlenW(out);}
static LRESULT WINAPI fake_message(HWND h,UINT msg,WPARAM cap,LPARAM target,UINT flags,UINT timeout,PDWORD_PTR result){
 (void)h;(void)msg;(void)flags;(void)timeout;
 read_calls++;if(cap<32)return 0;lstrcpyW((LPWSTR)target,L"Public static label");*result=19;return 1;
}
static HMODULE WINAPI fake_load(LPCWSTR name,HANDLE file,DWORD flags){(void)name;(void)file;(void)flags;return 0;}
static HDESK WINAPI fake_desktop(DWORD flags,BOOL inherit,ACCESS_MASK rights){(void)flags;(void)inherit;(void)rights;return 0;}
static BOOL WINAPI fake_enum_child(HWND parent,WNDENUMPROC callback,LPARAM context){(void)parent;fake_class=L"Static";return callback((HWND)9,context);}
static BOOL WINAPI fake_enum_top(WNDENUMPROC callback,LPARAM context){fake_class=L"#32770";return callback((HWND)8,context);}
static BOOL WINAPI fake_write(HANDLE file,LPCVOID data,DWORD count,LPDWORD written,LPOVERLAPPED overlapped){
 DWORD i;(void)file;(void)overlapped;*written=count;
 if(race_mode){
  for(i=0;i<count&&race_log_used+1<sizeof(race_log);i++)race_log[race_log_used++]=((const char*)data)[i];race_log[race_log_used]=0;
  if(lstrcmpA((const char*)data,"NT4PAGE BEGIN\r\n")==0){SetEvent(race_begin);WaitForSingleObject(race_release,3000);}
 }
 if(lstrcmpA((const char*)data,"NT4PAGE END\r\n")==0)file_end_seen=1;return TRUE;
}
#define CreateFileA fake_file
#define CreateProcessA fake_create
#define CreateThread fake_thread
#define WaitForSingleObject fake_wait
#define GetExitCodeProcess fake_exit_code
#define CloseHandle fake_close
#define ExitProcess fake_exit
#define IsWindowVisible fake_visible
#define IsWindowEnabled fake_visible
#define GetClassNameW fake_class_name
#define SendMessageTimeoutW fake_message
#define LoadLibraryExW fake_load
#define OpenInputDesktop fake_desktop
#define EnumWindows fake_enum_top
#define EnumChildWindows fake_enum_child
#define WriteFile fake_write
#define CreateMutexA fake_mutex
#define ReleaseMutex fake_release
#define FlushFileBuffers fake_flush
#include "page.c"
__declspec(dllexport) unsigned long test_child_exit(unsigned long code){
 supplied_exit=code;recorded_exit=0;wait_value=0;command_exact=0;com_open_failed=0;create_calls=0;observation_mode=0;entry();
 if(!com_open_failed||create_calls!=1||!command_exact||wait_value!=INFINITE)return 0xffffffffu;
 return recorded_exit;
}
__declspec(dllexport) unsigned long test_file_observation_without_com(void){
 serial=INVALID_HANDLE_VALUE;public_file=(HANDLE)7;output_lock=(HANDLE)11;stopping=0;observation_mode=1;file_end_seen=0;
 observe(0);observation_mode=0;public_file=INVALID_HANDLE_VALUE;
 return file_end_seen&&text_count>0&&wait_value==OBSERVE_AFTER_MS;
}
static DWORD WINAPI race_entry(void *ignored){(void)ignored;entry();return 0;}
static int position(const char *needle){unsigned a,b;for(a=0;a<race_log_used;a++){for(b=0;needle[b]&&race_log[a+b]&&needle[b]==race_log[a+b];b++);if(!needle[b])return (int)a;}return -1;}
__declspec(dllexport) unsigned long test_childexit_during_capture(void){
 HANDLE thread;int begin,end,flag;unsigned result=0;
 race_mode=1;observation_mode=0;race_log_used=0;race_log[0]=0;recorded_exit=0;supplied_exit=19;
 race_native=CreateEventA(0,TRUE,FALSE,0);race_begin=CreateEventA(0,TRUE,FALSE,0);race_release=CreateEventA(0,TRUE,FALSE,0);race_unblocked=CreateEventA(0,TRUE,FALSE,0);race_mutex=0;race_observer=0;
 thread=real_thread(race_entry);
 if(real_wait(race_begin,2000)==WAIT_OBJECT_0){
  SetEvent(race_native);
  if(real_wait(race_unblocked,2000)==WAIT_OBJECT_0){SetEvent(race_release);if(real_wait(thread,3000)==WAIT_OBJECT_0){
   begin=position("NT4PAGE BEGIN\r\n");end=position("NT4PAGE END\r\n");flag=position("NATIVE_CHILD_EXIT_ZERO");
   result=begin>=0&&end>begin&&flag>end&&recorded_exit==19;
  }}
 }
 SetEvent(race_native);SetEvent(race_release);real_wait(thread,3000);if(race_observer)real_wait(race_observer,3000);
 real_close(thread);real_close(race_observer);real_close(race_mutex);real_close(race_native);real_close(race_begin);real_close(race_release);real_close(race_unblocked);race_mode=0;return result;
}
__declspec(dllexport) unsigned long test_read_gate(const WCHAR *name,int is_top){
 fake_class=name;read_calls=0;text_count=0;excluded_edit=0;capture_started=GetTickCount();
 remember((HWND)1,(HWND)2,is_top);
 return read_calls|(excluded_edit<<8)|(text_count<<16);
}
__declspec(dllexport) int test_public_match(const WCHAR *a,const WCHAR *b){WCHAR left[128],right[128];if(!n4_normalize((const N4W*)a,(N4W*)left,128)||!n4_normalize((const N4W*)b,(N4W*)right,128))return 0;return n4_public_exact((const N4W*)left,(const N4W*)right);}
BOOL WINAPI DllMain(HINSTANCE a,DWORD b,LPVOID c){(void)a;(void)b;(void)c;return TRUE;}
