/* Fake desktop APIs: no host GUI or registry operations. Own kernel events
 * are used only as disposable handles. Notifications, timeout and old-shell
 * fallback run through the production wait implementation. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
typedef void (CALLBACK *FakeCallback)(HANDLE,DWORD,HWND,LONG,LONG,DWORD,DWORD);
static int scenario,ready_state,checks,waits,idles,errors;
static DWORD clock_ms,first_timeout;
static FakeCallback callback;
static HMODULE WINAPI fake_load(LPCSTR name){(void)name;return (HMODULE)1;}
static BOOL WINAPI fake_free(HMODULE module){(void)module;return TRUE;}
static DWORD WINAPI fake_tick(void){return clock_ms;}
static LONG WINAPI fake_open_key(HKEY root,LPCSTR path,DWORD options,REGSAM access,PHKEY out){(void)root;(void)path;(void)options;(void)access;(void)out;return ERROR_FILE_NOT_FOUND;}
static HWND WINAPI fake_find(LPCSTR name,LPCSTR caption){(void)name;(void)caption;return (HWND)1;}
static DWORD WINAPI fake_pid(HWND window,LPDWORD pid){(void)window;*pid=42;return 1;}
static HANDLE WINAPI fake_process(DWORD access,BOOL inherit,DWORD pid){(void)access;(void)inherit;(void)pid;return CreateEventA(0,FALSE,FALSE,0);}
static DWORD WINAPI fake_idle(HANDLE process,DWORD timeout){(void)process;(void)timeout;idles++;if(scenario==2)ready_state=1;return 0;}
static HANDLE WINAPI fake_hook(DWORD min,DWORD max,HMODULE module,FakeCallback cb,DWORD pid,DWORD thread,DWORD flags){
 (void)module;(void)pid;(void)thread;if(min!=0x8000||max!=0x8002||flags!=2)errors++;callback=cb;return (HANDLE)2;}
static BOOL WINAPI fake_unhook(HANDLE hook){(void)hook;return TRUE;}
static int WINAPI fake_class(HWND window,LPSTR out,int cap){(void)window;(void)cap;lstrcpyA(out,"Shell_TrayWnd");return 13;}
static BOOL WINAPI fake_peek(LPMSG m,HWND w,UINT first,UINT last,UINT remove){(void)m;(void)w;(void)first;(void)last;(void)remove;return FALSE;}
static BOOL WINAPI fake_translate(const MSG *m){(void)m;return TRUE;}
static LRESULT WINAPI fake_dispatch(const MSG *m){(void)m;return 0;}
static DWORD WINAPI fake_wait(DWORD count,const HANDLE *events,BOOL all,DWORD timeout,DWORD mask){
 (void)events;(void)all;(void)mask;waits++;
 if(waits==1)first_timeout=timeout;else if(timeout>=first_timeout)errors++;
 if(scenario==1){clock_ms+=timeout;return WAIT_TIMEOUT;}
 clock_ms+=100;if(waits==1)return WAIT_OBJECT_0+count; /* unrelated GUI message */
 ready_state=1;callback((HANDLE)2,0x8002,(HWND)1,0,0,0,0);return WAIT_OBJECT_0;
}
static FARPROC WINAPI fake_proc(HMODULE module,LPCSTR name){(void)module;
#define API(n,fn) if(lstrcmpA(name,n)==0)return (FARPROC)(fn)
 API("FindWindowA",fake_find);API("GetWindowThreadProcessId",fake_pid);API("WaitForInputIdle",fake_idle);
 API("MsgWaitForMultipleObjects",fake_wait);API("PeekMessageA",fake_peek);API("TranslateMessage",fake_translate);API("DispatchMessageA",fake_dispatch);API("GetClassNameA",fake_class);
 if(scenario!=2){API("SetWinEventHook",fake_hook);API("UnhookWinEvent",fake_unhook);}
#undef API
 return 0;
}
#define LoadLibraryA fake_load
#define FreeLibrary fake_free
#define GetTickCount fake_tick
#define RegOpenKeyExA fake_open_key
#define OpenProcess fake_process
#define GetProcAddress fake_proc
#include "../legacy_desktop_wait.h"
#define CHECK(x) do{if(!(x))ExitProcess(__LINE__);}while(0)
static int ready(void){checks++;return ready_state;}
static void reset(int mode){scenario=mode;ready_state=checks=waits=idles=errors=0;clock_ms=0;}
void entry(void){
 reset(0);CHECK(usos_wait_desktop(ready,300000)&&checks==4&&waits==2&&idles==1&&!errors);
 reset(1);CHECK(!usos_wait_desktop(ready,300000)&&checks==3&&waits==1&&clock_ms==300000&&!errors);
 reset(2);CHECK(usos_wait_desktop(ready,300000)&&idles==1&&waits==0);
 reset(0);ready_state=1;CHECK(usos_wait_desktop(ready,300000)&&checks==1&&idles==0&&waits==0);
 ExitProcess(0);
}
