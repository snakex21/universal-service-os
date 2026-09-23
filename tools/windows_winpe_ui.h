/* USOS dialogs inside Windows PE: localized text and button labels.
 *
 * Only the language chosen in the installer is on the drive, as
 * EFI\USOS\lang-winpe.ini on the source ESP (UTF-16LE with BOM, written by
 * installer/internal/i18n WinPEINI). The ESP is found through
 * usos-log-root.txt, which usos-source --log-root writes beside the helpers
 * after verifying the source disk; without it (or for a missing key) the
 * English text from windows_winpe_strings.h is used.
 *
 * No C runtime: only kernel32/user32 (and gdi32 for usos_ui_dialog).
 * Define USOS_UI_DIALOG before including to get usos_ui_dialog. */
#ifndef USOS_WINPE_UI_H
#define USOS_WINPE_UI_H
#include "windows_winpe_strings.h"

#define USOS_UI_TEXT(name) usos_ui_string(USOS_WINPE_##name##_KEY, USOS_WINPE_##name##_EN)

static WCHAR usos_ui_ini[16384];
static unsigned usos_ui_ini_len;
static int usos_ui_loaded;
static WCHAR usos_ui_pool[8192];
static unsigned usos_ui_pool_used;

static unsigned usos_ui_len(const WCHAR *s){unsigned n=0;while(s[n])n++;return n;}

/* Reads EFI\USOS\lang-winpe.ini from the verified source ESP once. */
static void usos_ui_load(void){
 if(usos_ui_loaded)return;
 usos_ui_loaded=1;
 static WCHAR path[MAX_PATH+32];
 DWORD n=GetModuleFileNameW(0,path,MAX_PATH);
 if(!n||n>=MAX_PATH-32)return;
 while(n&&path[n-1]!='\\')n--;
 if(!n)return;
 const WCHAR *name=L"usos-log-root.txt";
 for(unsigned i=0;name[i];i++)path[n++]=name[i];
 path[n]=0;
 HANDLE file=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,0,OPEN_EXISTING,0,0);
 if(file==INVALID_HANDLE_VALUE)return;
 static char root[MAX_PATH];
 DWORD got=0;
 BOOL ok=ReadFile(file,root,MAX_PATH-1,&got,0);
 CloseHandle(file);
 if(!ok)return;
 /* \\?\GLOBALROOT\Device\HarddiskN\PartitionM\EFI\USOS\Logs\WinSetup-... */
 const char *marker="\\EFI\\USOS\\Logs\\WinSetup-";
 const char *prefix="\\\\?\\GLOBALROOT\\Device\\Harddisk";
 for(unsigned i=0;prefix[i];i++)if(i>=got||root[i]!=prefix[i])return;
 unsigned cut=0;
 for(unsigned i=0;i<got&&!cut;i++){
  if(root[i]=='\r'||root[i]=='\n'||root[i]<32||root[i]>126)return;
  unsigned j=0;while(marker[j]&&i+j<got&&root[i+j]==marker[j])j++;
  if(!marker[j])cut=i+9; /* keep "\EFI\USOS" */
 }
 if(!cut||cut>=MAX_PATH-20)return;
 for(unsigned i=0;i<cut;i++)path[i]=(WCHAR)root[i];
 const WCHAR *ini=L"\\lang-winpe.ini";
 n=cut;for(unsigned i=0;ini[i];i++)path[n++]=ini[i];
 path[n]=0;
 file=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,0,OPEN_EXISTING,0,0);
 if(file==INVALID_HANDLE_VALUE)return;
 got=0;
 ok=ReadFile(file,usos_ui_ini,sizeof(usos_ui_ini)-2,&got,0);
 CloseHandle(file);
 if(!ok||got<4||(got&1)||usos_ui_ini[0]!=0xfeff)return;
 usos_ui_ini_len=got/2;
}

/* The localized value of key in [winpe], else english. Values decode \n and \\. */
static const WCHAR *usos_ui_string(const WCHAR *key,const WCHAR *english){
 usos_ui_load();
 unsigned key_len=usos_ui_len(key),at=1;
 int section=0;
 while(at<usos_ui_ini_len){
  unsigned end=at;while(end<usos_ui_ini_len&&usos_ui_ini[end]!='\n')end++;
  unsigned stop=end;if(stop>at&&usos_ui_ini[stop-1]=='\r')stop--;
  if(stop>at&&usos_ui_ini[at]=='['){
   const WCHAR *want=L"[winpe]";unsigned i=0;
   while(want[i]&&at+i<stop&&usos_ui_ini[at+i]==want[i])i++;
   section=!want[i]&&at+i==stop;
  }else if(section&&stop>at+key_len&&usos_ui_ini[at+key_len]=='='){
   unsigned i=0;while(i<key_len&&usos_ui_ini[at+i]==key[i])i++;
   if(i==key_len){
    unsigned from=at+key_len+1;
    if(usos_ui_pool_used+(stop-from)+1>sizeof(usos_ui_pool)/sizeof(WCHAR))return english;
    WCHAR *out=usos_ui_pool+usos_ui_pool_used;unsigned o=0;
    for(unsigned p=from;p<stop;p++){
     WCHAR c=usos_ui_ini[p];
     if(c=='\\'&&p+1<stop){p++;c=usos_ui_ini[p]=='n'?'\n':usos_ui_ini[p];}
     out[o++]=c;
    }
    out[o++]=0;usos_ui_pool_used+=o;
    return o>1?out:english;
   }
  }
  at=end+1;
 }
 return english;
}

/* Copies pattern to out with {0} replaced by value (decimal). */
static void usos_ui_format(WCHAR *out,unsigned size,const WCHAR *pattern,DWORD value){
 WCHAR digits[12];unsigned d=0;do{digits[d++]=(WCHAR)('0'+value%10);value/=10;}while(value);
 unsigned o=0;
 for(unsigned i=0;pattern[i]&&o+1<size;i++){
  if(pattern[i]=='{'&&pattern[i+1]=='0'&&pattern[i+2]=='}'){
   unsigned k=d;while(k&&o+1<size)out[o++]=digits[--k];i+=2;continue;
  }
  out[o++]=pattern[i];
 }
 out[o]=0;
}

#ifdef USOS_UI_DIALOG
/* A MessageBox whose buttons carry our (localized) labels instead of the
 * WinPE system language's Yes/No/Cancel, widened to fit longer labels.
 * labels follow the buttons of `type`: MB_OK {ok}, MB_YESNO {yes,no},
 * MB_YESNOCANCEL {yes,no,cancel}. */
static const WCHAR *usos_ui_labels[3];
static HHOOK usos_ui_hook;

static LRESULT CALLBACK usos_ui_cbt(int code,WPARAM w,LPARAM l){
 if(code!=HCBT_ACTIVATE)return CallNextHookEx(usos_ui_hook,code,w,l);
 HWND dialog=(HWND)w;
 UnhookWindowsHookEx(usos_ui_hook);usos_ui_hook=0;
 static const int order[4]={IDOK,IDYES,IDNO,IDCANCEL};
 HWND buttons[3];const WCHAR *labels[3];unsigned count=0,next=0;
 for(unsigned i=0;i<4&&count<3;i++){
  HWND button=GetDlgItem(dialog,order[i]);
  if(!button)continue;
  buttons[count]=button;labels[count]=usos_ui_labels[next++];count++;
 }
 if(!count)return 0;
 RECT first,last,client;
 GetWindowRect(buttons[0],&first);GetWindowRect(buttons[count-1],&last);
 MapWindowPoints(HWND_DESKTOP,dialog,(POINT *)&first,2);MapWindowPoints(HWND_DESKTOP,dialog,(POINT *)&last,2);
 GetClientRect(dialog,&client);
 int height=first.bottom-first.top,gap=8,margin=client.right-last.right;
 if(count>1){RECT second;GetWindowRect(buttons[1],&second);MapWindowPoints(HWND_DESKTOP,dialog,(POINT *)&second,2);gap=second.left-first.right;}
 if(gap<4)gap=8;if(margin<8)margin=12;
 int widths[3],total=0;
 HDC dc=GetDC(dialog);
 HFONT font=(HFONT)SendMessageW(buttons[0],WM_GETFONT,0,0);
 HGDIOBJ old=font?SelectObject(dc,font):0;
 for(unsigned i=0;i<count;i++){
  if(labels[i])SetWindowTextW(buttons[i],labels[i]);
  SIZE size={0,0};
  WCHAR text[128];int n=GetWindowTextW(buttons[i],text,128);
  if(n>0)GetTextExtentPoint32W(dc,text,n,&size);
  RECT r;GetWindowRect(buttons[i],&r);
  widths[i]=r.right-r.left;
  if(size.cx+24>widths[i])widths[i]=size.cx+24;
  total+=widths[i];
 }
 if(old)SelectObject(dc,old);
 ReleaseDC(dialog,dc);
 total+=gap*(int)(count-1);
 int grow=total+2*margin-(client.right-client.left);
 if(grow>0){
  RECT window;GetWindowRect(dialog,&window);
  SetWindowPos(dialog,0,window.left-grow/2,window.top,window.right-window.left+grow,window.bottom-window.top,SWP_NOZORDER|SWP_NOACTIVATE);
  GetClientRect(dialog,&client);
 }
 int x=client.right-margin-total;
 for(unsigned i=0;i<count;i++){
  SetWindowPos(buttons[i],0,x,first.top,widths[i],height,SWP_NOZORDER|SWP_NOACTIVATE);
  x+=widths[i]+gap;
 }
 return 0;
}

static int usos_ui_dialog(const WCHAR *text,const WCHAR *title,UINT type,const WCHAR *a,const WCHAR *b,const WCHAR *c){
 usos_ui_labels[0]=a;usos_ui_labels[1]=b;usos_ui_labels[2]=c;
 usos_ui_hook=SetWindowsHookExW(WH_CBT,usos_ui_cbt,0,GetCurrentThreadId());
 int result=MessageBoxW(0,text,title,type|MB_SETFOREGROUND|MB_TOPMOST);
 if(usos_ui_hook){UnhookWindowsHookEx(usos_ui_hook);usos_ui_hook=0;}
 return result;
}
#endif
#endif
