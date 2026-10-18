/* SPDX-License-Identifier: GPL-3.0-or-later
 * WinPE-only test automation: choose Vista's built-in installation without
 * a product key. No licensing state, activation or validation is patched.
 * Adapted from our earlier Vista NVMe test helper. Events, not polling.
 */
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0600
#include <windows.h>
static int skipped,confirmed,busy;
static void report(const char *text){HANDLE port=CreateFileW(L"\\\\.\\COM1",GENERIC_WRITE,0,0,OPEN_EXISTING,0,0);if(port!=INVALID_HANDLE_VALUE){DWORD count;WriteFile(port,text,lstrlenA(text),&count,0);CloseHandle(port);}}
static BOOL has(const WCHAR *s,const WCHAR *word){for(;*s;s++){unsigned i=0;while(word[i]){WCHAR a=s[i],b=word[i];if(a>='A'&&a<='Z')a+=32;if(b>='A'&&b<='Z')b+=32;if(a!=b)break;i++;}if(!word[i])return TRUE;}return FALSE;}
typedef struct {HWND next,no,edit;unsigned edits;BOOL key;} Page;
static BOOL CALLBACK child(HWND w,LPARAM value){
 Page *p=(Page*)value;WCHAR cls[40],text[600];if(!IsWindowVisible(w))return TRUE;
 GetClassNameW(w,cls,40);GetWindowTextW(w,text,600);
 if(has(text,L"klucz produktu")||has(text,L"product key"))p->key=TRUE;
 if(!lstrcmpiW(cls,L"Edit")){p->edit=w;p->edits++;}
 if(!lstrcmpiW(cls,L"Button")){
  if(has(text,L"dalej")||has(text,L"next"))p->next=w;
  if(GetDlgCtrlID(w)==IDNO||!lstrcmpiW(text,L"Nie")||!lstrcmpiW(text,L"&Nie")||!lstrcmpiW(text,L"No")||!lstrcmpiW(text,L"&No"))p->no=w;
 }return TRUE;
}
static void CALLBACK event(HWINEVENTHOOK hook,DWORD what,HWND window,LONG object,LONG item,DWORD thread,DWORD time){
 (void)hook;(void)what;(void)object;(void)item;(void)thread;(void)time;
 if(busy||!window)return;busy=1;
 window=GetAncestor(window,GA_ROOT);
 WCHAR title[200];GetWindowTextW(window,title,200);
 if(has(title,L"windows")){
  static Page page;page.next=page.no=page.edit=0;page.edits=0;page.key=FALSE;EnumChildWindows(window,child,(LPARAM)&page);
  if(page.key&&!skipped&&page.edits==1&&GetWindowTextLengthW(page.edit)==0&&page.next&&IsWindowEnabled(page.next)){
   skipped=1;report("WM_PE_EMPTY_KEY_NEXT\n");PostMessageW(page.next,BM_CLICK,0,0);
  }else if(skipped&&!confirmed&&page.no){confirmed=1;report("WM_PE_WITHOUT_KEY_CONFIRMED\n");PostMessageW(page.no,BM_CLICK,0,0);}
 }
 busy=0;
}
static BOOL CALLBACK initial_window(HWND window,LPARAM ignored){(void)ignored;event(0,0,window,0,0,0,0);return TRUE;}
void entry(void){
 HKEY pe;if(RegOpenKeyExW(HKEY_LOCAL_MACHINE,L"SYSTEM\\CurrentControlSet\\Control\\MiniNT",0,KEY_READ,&pe)!=ERROR_SUCCESS)ExitProcess(2);RegCloseKey(pe);
 HANDLE mutex=CreateMutexW(0,TRUE,L"Local\\USOSWM.OptionalKey.Test");if(!mutex||GetLastError()==ERROR_ALREADY_EXISTS)ExitProcess(0);
 HWINEVENTHOOK a=SetWinEventHook(EVENT_SYSTEM_DIALOGSTART,EVENT_SYSTEM_DIALOGSTART,0,event,0,0,WINEVENT_OUTOFCONTEXT);
 HWINEVENTHOOK b=SetWinEventHook(EVENT_OBJECT_SHOW,EVENT_OBJECT_SHOW,0,event,0,0,WINEVENT_OUTOFCONTEXT);
 HWINEVENTHOOK c=SetWinEventHook(EVENT_OBJECT_NAMECHANGE,EVENT_OBJECT_NAMECHANGE,0,event,0,0,WINEVENT_OUTOFCONTEXT);
 if(!a||!b||!c)ExitProcess(3);
 report("WM_PE_UI_HELPER_STARTED\n");
 EnumWindows(initial_window,0);
 MSG message;while(GetMessageW(&message,0,0,0)>0){TranslateMessage(&message);DispatchMessageW(&message);}ExitProcess(0);
}
