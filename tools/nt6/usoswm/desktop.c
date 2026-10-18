/* SPDX-License-Identifier: GPL-3.0-or-later
 * Own shell-only renderer. The kernel, code integrity, Microsoft files and
 * secure desktops are never patched. Unsupported states retain native paint.
 */
#include "common.h"
#include <wininet.h>
#include <shlobj.h>
#include <objbase.h>
typedef BOOL (WINAPI *PaintDesktopFn)(HDC);
typedef BOOL (WINAPI *PaintMonitorFn)(HMONITOR,HDC,const RECT *);
typedef HRESULT (WINAPI *LicenseValueFn)(PCWSTR,DWORD *);
static HMODULE self;
static PaintDesktopFn native_desktop;
static PaintMonitorFn native_monitor;
static HBITMAP wallpaper;
static BITMAP wallpaper_info;
static DWORD wallpaper_style;
static BOOL background_ready;
static LONG initialized;
static LONG render_state=-1;
static DWORD desktop_thread;
static const GUID active_desktop_class={0x75048700,0xef1f,0x11d0,{0x98,0x88,0x00,0x60,0x97,0xde,0xac,0xf9}};
static const GUID active_desktop_interface={0xf490eb00,0x1240,0x11d1,{0x98,0x88,0x00,0x60,0x97,0xde,0xac,0xf9}};

static BOOL only_test_mode(void){
 /* The import table belongs to the process; only the actual desktop thread
  * may use our renderer. Other Explorer threads always call native USER32. */
 if(GetCurrentThreadId()!=desktop_thread||!wm_supported()||GetSystemMetrics(SM_CLEANBOOT)||wm_visible(self))return FALSE;
 HKEY key;DWORD size=sizeof(DWORD),type=0,paint_version=0;LONG result;
 if(RegOpenKeyExW(HKEY_CURRENT_USER,L"Control Panel\\Desktop",0,KEY_QUERY_VALUE,&key)!=ERROR_SUCCESS)return FALSE;
 result=RegQueryValueExW(key,L"PaintDesktopVersion",0,&type,(BYTE*)&paint_version,&size);RegCloseKey(key);
 if(result!=ERROR_FILE_NOT_FOUND&&(result!=ERROR_SUCCESS||type!=REG_DWORD||size!=sizeof(DWORD)||paint_version))return FALSE;
 /* Query the same named licensing value as the original desktop renderer.
  * This is read-only. An unknown or non-genuine state always keeps native UI. */
 WCHAR dll[MAX_PATH];DWORD n=GetSystemDirectoryW(dll,MAX_PATH);if(!n||n>=MAX_PATH-16)return FALSE;lstrcatW(dll,L"\\slc.dll");
 HMODULE licensing=LoadLibraryW(dll);if(!licensing)return FALSE;
 LicenseValueFn query=(LicenseValueFn)GetProcAddress(licensing,"SLGetWindowsInformationDWORD");
 DWORD genuine=0;BOOL ok=query&&SUCCEEDED(query(L"Security-Licensing-SLC-GenuineLocalStatus",&genuine))&&genuine!=0;FreeLibrary(licensing);
 return ok;
}
static void reset_background(void){if(wallpaper)DeleteObject(wallpaper);wallpaper=0;background_ready=FALSE;}
static BOOL load_background(void){
 if(background_ready)return TRUE;
 WCHAR pattern[128]={0};HKEY key;DWORD bytes=sizeof(pattern),type=0;
 if(RegOpenKeyExW(HKEY_CURRENT_USER,L"Control Panel\\Desktop",0,KEY_QUERY_VALUE,&key)!=ERROR_SUCCESS)return FALSE;
 LONG r=RegQueryValueExW(key,L"Pattern",0,&type,(BYTE*)pattern,&bytes);RegCloseKey(key);
 if(r!=ERROR_FILE_NOT_FOUND&&(r!=ERROR_SUCCESS||type!=REG_SZ||bytes>sizeof(pattern)||pattern[0]))return FALSE;
 IActiveDesktop *desktop=0;HRESULT hr=CoCreateInstance(&active_desktop_class,0,CLSCTX_INPROC_SERVER,&active_desktop_interface,(void**)&desktop);
 if(FAILED(hr)||!desktop)return FALSE;
 WCHAR file[MAX_PATH]={0};WALLPAPEROPT options={sizeof(options),0};
 hr=desktop->lpVtbl->GetWallpaper(desktop,file,MAX_PATH,AD_GETWP_BMP);
 if(SUCCEEDED(hr))hr=desktop->lpVtbl->GetWallpaperOptions(desktop,&options,0);
 desktop->lpVtbl->Release(desktop);if(FAILED(hr)||options.dwStyle>WPSTYLE_STRETCH)return FALSE;
 if(file[0]){
  wallpaper=(HBITMAP)LoadImageW(0,file,IMAGE_BITMAP,0,0,LR_LOADFROMFILE|LR_CREATEDIBSECTION);
  if(!wallpaper||GetObjectW(wallpaper,sizeof(wallpaper_info),&wallpaper_info)!=sizeof(wallpaper_info)||wallpaper_info.bmWidth<=0||wallpaper_info.bmHeight<=0||wallpaper_info.bmWidth>20000||wallpaper_info.bmHeight>20000){reset_background();return FALSE;}
 }
 wallpaper_style=options.dwStyle;background_ready=TRUE;return TRUE;
}
static BOOL paint_background(HMONITOR monitor,HDC dc,const RECT *update){
 MONITORINFO info={sizeof(info)};if(!GetMonitorInfoW(monitor,&info)||GetMapMode(dc)!=MM_TEXT)return FALSE;
 int saved=SaveDC(dc);if(!saved)return FALSE;
 if(update)IntersectClipRect(dc,update->left,update->top,update->right,update->bottom);
 IntersectClipRect(dc,info.rcMonitor.left,info.rcMonitor.top,info.rcMonitor.right,info.rcMonitor.bottom);
 BOOL ok=FillRect(dc,&info.rcMonitor,GetSysColorBrush(COLOR_DESKTOP))!=0;
 if(ok&&wallpaper){
  HDC source=CreateCompatibleDC(dc);if(!source){RestoreDC(dc,saved);return FALSE;}
  HGDIOBJ old=SelectObject(source,wallpaper);RECT r=info.rcMonitor;
  int width=r.right-r.left,height=r.bottom-r.top,bw=wallpaper_info.bmWidth,bh=wallpaper_info.bmHeight;
  if(wallpaper_style==WPSTYLE_STRETCH){SetStretchBltMode(dc,HALFTONE);SetBrushOrgEx(dc,0,0,0);ok=StretchBlt(dc,r.left,r.top,width,height,source,0,0,bw,bh,SRCCOPY);}
  else if(wallpaper_style==WPSTYLE_TILE){
   HBRUSH tile=CreatePatternBrush(wallpaper);ok=tile!=0;
   /* Shell32 can change the DC's window origin before painting. Brush
    * origins use device coordinates, unlike the monitor/update rectangles. */
   if(tile){POINT origin={r.left,r.top};ok=LPtoDP(dc,&origin,1)&&SetBrushOrgEx(dc,origin.x,origin.y,0)&&FillRect(dc,&r,tile)!=0;DeleteObject(tile);}
  }else ok=BitBlt(dc,r.left+(width-bw)/2,r.top+(height-bh)/2,bw,bh,source,0,0,SRCCOPY);
  SelectObject(source,old);DeleteDC(source);
 }
 RestoreDC(dc,saved);return ok;
}
static BOOL CALLBACK paint_one(HMONITOR monitor,HDC dc,RECT *rect,LPARAM param){(void)param;return paint_background(monitor,dc,rect);}
static void record_render(BOOL active){if(render_state!=active){render_state=active;wm_log(self,active?"Own background renderer active":"Native background renderer retained");}}
static BOOL WINAPI filtered_desktop(HDC dc){if(only_test_mode()&&load_background()&&EnumDisplayMonitors(dc,0,paint_one,0)){record_render(TRUE);return TRUE;}record_render(FALSE);return native_desktop(dc);}
static BOOL WINAPI filtered_monitor(HMONITOR monitor,HDC dc,const RECT *rect){if(only_test_mode()&&load_background()&&paint_background(monitor,dc,rect)){record_render(TRUE);return TRUE;}record_render(FALSE);return native_monitor(monitor,dc,rect);}

static BOOL in_image(DWORD offset,SIZE_T size,DWORD image_size){return offset<image_size&&size<=image_size-offset;}
static BOOL text_equal(const char *a,const char *b,DWORD maximum){for(DWORD i=0;i<maximum;i++){if(a[i]!=b[i])return FALSE;if(!a[i])return TRUE;}return FALSE;}
typedef struct {void **slot;void *original;void *replacement;} ImportChange;
static BOOL vista_syscall(const void *function){
 /* Original NT 6.0 x64 USER32 stubs: mov r10,rcx; mov eax,service;
  * syscall; ret. Unknown dispatchers/third-party hooks retain native paint. */
 const BYTE *code=function;
 return code[0]==0x4c&&code[1]==0x8b&&code[2]==0xd1&&code[3]==0xb8&&code[8]==0x0f&&code[9]==0x05&&code[10]==0xc3;
}
static BOOL exchange_import(ImportChange *item,BOOL restore){
 DWORD protection,unused;if(!VirtualProtect(item->slot,sizeof(void*),PAGE_READWRITE,&protection))return FALSE;
 void *expected=restore?item->replacement:item->original,*value=restore?item->original:item->replacement;
 BOOL ok=InterlockedCompareExchangePointer(item->slot,value,expected)==expected;
 VirtualProtect(item->slot,sizeof(void*),protection,&unused);return ok;
}
static BOOL attach_imports(void){
 BYTE *base=(BYTE*)GetModuleHandleW(L"shell32.dll");if(!base)return FALSE;
 IMAGE_DOS_HEADER *dos=(void*)base;if(dos->e_magic!=IMAGE_DOS_SIGNATURE||dos->e_lfanew<0||dos->e_lfanew>1024*1024)return FALSE;
 IMAGE_NT_HEADERS *pe=(void*)(base+dos->e_lfanew);if(pe->Signature!=IMAGE_NT_SIGNATURE||pe->FileHeader.Machine!=IMAGE_FILE_MACHINE_AMD64||pe->OptionalHeader.Magic!=IMAGE_NT_OPTIONAL_HDR64_MAGIC)return FALSE;
 DWORD size=pe->OptionalHeader.SizeOfImage;IMAGE_DATA_DIRECTORY dir=pe->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
 if(!dir.Size||!in_image(dir.VirtualAddress,dir.Size,size))return FALSE;
 HMODULE user=GetModuleHandleW(L"user32.dll");native_desktop=(PaintDesktopFn)GetProcAddress(user,"PaintDesktop");native_monitor=(PaintMonitorFn)GetProcAddress(user,"PaintMonitor");if(!native_desktop||!native_monitor||!vista_syscall((const void*)native_desktop)||!vista_syscall((const void*)native_monitor))return FALSE;
 ImportChange changes[2];DWORD count=0;
 for(DWORD offset=0;offset+sizeof(IMAGE_IMPORT_DESCRIPTOR)<=dir.Size;offset+=sizeof(IMAGE_IMPORT_DESCRIPTOR)){
  IMAGE_IMPORT_DESCRIPTOR *imp=(void*)(base+dir.VirtualAddress+offset);if(!imp->Name)break;
  if(!in_image(imp->Name,12,size)||!text_equal((char*)base+imp->Name,"USER32.dll",12))continue;
  if(!imp->OriginalFirstThunk||!imp->FirstThunk)return FALSE;
  for(DWORD j=0;j<size/sizeof(IMAGE_THUNK_DATA);j++){
   SIZE_T delta=(SIZE_T)j*sizeof(IMAGE_THUNK_DATA);
   if(delta>size||!in_image(imp->OriginalFirstThunk,delta+sizeof(IMAGE_THUNK_DATA),size)||!in_image(imp->FirstThunk,delta+sizeof(IMAGE_THUNK_DATA),size))return FALSE;
   IMAGE_THUNK_DATA *name=(void*)(base+imp->OriginalFirstThunk+delta),*slot=(void*)(base+imp->FirstThunk+delta);if(!name->u1.AddressOfData)break;if(IMAGE_SNAP_BY_ORDINAL(name->u1.Ordinal))continue;
   ULONGLONG address=name->u1.AddressOfData;if(address>size||!in_image((DWORD)address,32,size))return FALSE;
   char *text=(char*)((IMAGE_IMPORT_BY_NAME*)(base+(DWORD)address))->Name;
   void *original=0,*replacement=0;
   if(text_equal(text,"PaintDesktop",30)){original=(void*)native_desktop;replacement=(void*)filtered_desktop;}
   if(text_equal(text,"PaintMonitor",30)){original=(void*)native_monitor;replacement=(void*)filtered_monitor;}
   if(original){if(count>=2||(void*)slot->u1.Function!=original)return FALSE;changes[count++]=(ImportChange){(void**)&slot->u1.Function,original,replacement};}
  }
 }
 if(count!=2)return FALSE;
 /* Pin before exposing our functions. No code bytes or kernel pages change. */
 HMODULE pin;if(!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_PIN,(LPCWSTR)&attach_imports,&pin))return FALSE;
 desktop_thread=GetCurrentThreadId();
 if(!exchange_import(&changes[0],FALSE))return FALSE;
 if(!exchange_import(&changes[1],FALSE)){exchange_import(&changes[0],TRUE);return FALSE;}
 return TRUE;
}
__declspec(dllexport) LRESULT CALLBACK WmHook(int code,WPARAM w,LPARAM l){
 if(code>=0){
  if(InterlockedCompareExchange(&initialized,1,0)==0){
   if(wm_default_desktop()&&wm_explorer()&&wm_supported()&&!wm_visible(self)&&attach_imports())wm_log(self,"Attached: shell32 desktop imports; code integrity and Microsoft files unchanged");
   else wm_log(self,"Native rendering retained: unsupported or opted-out shell");
  }
  const CWPSTRUCT *message=(const CWPSTRUCT*)l;
  if(message&&(message->message==WM_SETTINGCHANGE||message->message==WM_THEMECHANGED||message->message==WM_DISPLAYCHANGE))reset_background();
 }
 return CallNextHookEx(0,code,w,l);
}
BOOL WINAPI DllMain(HINSTANCE module,DWORD reason,void *reserved){(void)reserved;if(reason==DLL_PROCESS_ATTACH){self=module;DisableThreadLibraryCalls(module);}return TRUE;}
