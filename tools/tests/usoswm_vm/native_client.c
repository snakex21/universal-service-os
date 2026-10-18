/* SPDX-License-Identifier: GPL-3.0-or-later
 * Lab-only ActiveX RDP host. No MSTSC settings/history wrapper, persistent
 * bitmap cache, credentials, registry configuration or redirected devices.
 * All evidence is written to the explicit application output directory.
 */
#define UNICODE
#define _UNICODE
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0601
#endif
#include <windows.h>
#include <ole2.h>
#include <ocidl.h>
#include <shellapi.h>
#include <stddef.h>
/* Public COM interface IDs, local constants: no UUID helper/CRT dependency. */
static const IID local_null={0};
static const IID local_unknown={0,0,0,{0xc0,0,0,0,0,0,0,0x46}};
static const IID local_dispatch={0x20400,0,0,{0xc0,0,0,0,0,0,0,0x46}};
static const IID local_points={0xb196b284,0xbab4,0x101a,{0xb6,0x9c,0,0xaa,0,0x34,0x1d,7}};
static const IID local_window={0x114,0,0,{0xc0,0,0,0,0,0,0,0x46}};
static const IID local_view={0x10d,0,0,{0xc0,0,0,0,0,0,0,0x46}};
#undef IID_NULL
#define IID_NULL local_null
#define IID_IUnknown local_unknown
#define IID_IDispatch local_dispatch
#define IID_IConnectionPointContainer local_points
#define IID_IOleWindow local_window
static BOOL same_iid(REFIID a,REFIID b){const BYTE*x=(const BYTE*)a,*y=(const BYTE*)b;for(unsigned i=0;i<16;i++)if(x[i]!=y[i])return FALSE;return TRUE;}
static void guid_log(REFIID g){char out[80];wsprintfA(out,"NATIVE_POINT=%08lX-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X",g->Data1,g->Data2,g->Data3,g->Data4[0],g->Data4[1],g->Data4[2],g->Data4[3],g->Data4[4],g->Data4[5],g->Data4[6],g->Data4[7]);DWORD n;WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),out,lstrlenA(out),&n,0);WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),"\n",1,&n,0);}
void *memcpy(void*d,const void*s,size_t n){BYTE*a=d;const BYTE*b=s;while(n--)*a++=*b++;return d;}
void *memset(void*d,int v,size_t n){BYTE*a=d;while(n--)*a++=(BYTE)v;return d;}
static HWND window,rdp_window;static IDispatch *control;static WCHAR output[MAX_PATH];
static IViewObject *view;
static IUnknown *keys;static UINT send_offset;static LONG exit_code=1;
static void say(const char*s){DWORD n;WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),s,lstrlenA(s),&n,0);WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),"\n",1,&n,0);}
static void error(HRESULT h){char s[]="NATIVE_ERROR=00000000";for(unsigned i=0;i<8;i++)s[13+i]="0123456789ABCDEF"[((DWORD)h>>(28-4*i))&15];say(s);}
static HRESULT invoke(IDispatch*d,WCHAR*name,WORD flags,VARIANT*arg,VARIANT*value){
 DISPID id,put=DISPID_PROPERTYPUT;HRESULT h=IDispatch_GetIDsOfNames(d,&IID_NULL,&name,1,LOCALE_USER_DEFAULT,&id);if(FAILED(h))return h;
 DISPPARAMS p={arg,flags==DISPATCH_PROPERTYPUT?&put:0,arg?1:0,flags==DISPATCH_PROPERTYPUT?1:0};EXCEPINFO ex={0};UINT bad=0;
 h=IDispatch_Invoke(d,id,&IID_NULL,LOCALE_USER_DEFAULT,flags,&p,value,&ex,&bad);if(ex.bstrSource)SysFreeString(ex.bstrSource);if(ex.bstrDescription)SysFreeString(ex.bstrDescription);if(ex.bstrHelpFile)SysFreeString(ex.bstrHelpFile);return h;
}
static HRESULT number(IDispatch*d,WCHAR*n,LONG v){VARIANT a={0};a.vt=VT_I4;a.lVal=v;return invoke(d,n,DISPATCH_PROPERTYPUT,&a,0);}
static HRESULT bool_property(IDispatch*d,WCHAR*n,BOOL v){VARIANT a={0};a.vt=VT_BOOL;a.boolVal=v?VARIANT_TRUE:VARIANT_FALSE;return invoke(d,n,DISPATCH_PROPERTYPUT,&a,0);}
static HRESULT string(IDispatch*d,WCHAR*n,const WCHAR*v){VARIANT a={0};a.vt=VT_BSTR;a.bstrVal=SysAllocString(v);if(!a.bstrVal)return E_OUTOFMEMORY;HRESULT h=invoke(d,n,DISPATCH_PROPERTYPUT,&a,0);VariantClear(&a);return h;}
static BOOL locate_keys(void){
 WCHAR path[MAX_PATH];GetSystemDirectoryW(path,MAX_PATH);lstrcatW(path,L"\\mstscax.dll");ITypeLib *library=0;
 HRESULT h=LoadTypeLibEx(path,REGKIND_NONE,&library);if(FAILED(h))return FALSE;
 for(UINT i=0;i<ITypeLib_GetTypeInfoCount(library)&&!keys;i++){
  ITypeInfo *info=0;BSTR name=0;TYPEATTR *attr=0;if(FAILED(ITypeLib_GetTypeInfo(library,i,&info)))continue;
  ITypeInfo_GetDocumentation(info,MEMBERID_NIL,&name,0,0,0);
  if(name&&!lstrcmpW(name,L"IMsRdpClientNonScriptable")&&SUCCEEDED(ITypeInfo_GetTypeAttr(info,&attr))){
   for(UINT j=0;j<attr->cFuncs;j++){FUNCDESC*f=0;BSTR method=0;if(FAILED(ITypeInfo_GetFuncDesc(info,j,&f)))continue;
    ITypeInfo_GetDocumentation(info,f->memid,&method,0,0,0);
    if(method&&!lstrcmpW(method,L"SendKeys")&&f->cParams==3&&SUCCEEDED(IDispatch_QueryInterface(control,&attr->guid,(void**)&keys)))send_offset=f->oVft;
    if(method)SysFreeString(method);ITypeInfo_ReleaseFuncDesc(info,f);
   }ITypeInfo_ReleaseTypeAttr(info,attr);
  }if(name)SysFreeString(name);ITypeInfo_Release(info);
 }ITypeLib_Release(library);return keys&&send_offset;
}
static HRESULT key(UINT vk,BOOL up,BOOL extended){
 typedef HRESULT(STDMETHODCALLTYPE *Send)(IUnknown*,LONG,VARIANT_BOOL*,LONG*);
 UINT scan=MapVirtualKeyW(vk,MAPVK_VK_TO_VSC);LONG data=1|(scan<<16)|(extended?1<<24:0)|(up?0xc0000000:0);VARIANT_BOOL released=up?VARIANT_TRUE:VARIANT_FALSE;
 void **table=*(void***)keys;return ((Send)table[send_offset/sizeof(void*)])(keys,1,&released,&data);
}
static BOOL type_command(void){
 const WCHAR *text=L"c:\\usos\\wmtest\\wm-full.exe --rdp-session";
 for(;*text;text++){SHORT v=VkKeyScanW(*text);if(v==-1)return FALSE;BOOL shift=(v&0x100)!=0;if(shift&&FAILED(key(VK_SHIFT,FALSE,FALSE)))return FALSE;
  if(FAILED(key(v&255,FALSE,FALSE))||FAILED(key(v&255,TRUE,FALSE)))return FALSE;if(shift)key(VK_SHIFT,TRUE,FALSE);
 }return SUCCEEDED(key(VK_RETURN,FALSE,FALSE))&&SUCCEEDED(key(VK_RETURN,TRUE,FALSE));
}
static BOOL capture(const WCHAR *name){
 RECT r;GetClientRect(window,&r);HDC screen=GetDC(window),dc=CreateCompatibleDC(screen);BITMAPINFO info={0};void*pixels=0;
 info.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);info.bmiHeader.biWidth=r.right;info.bmiHeader.biHeight=-r.bottom;info.bmiHeader.biPlanes=1;info.bmiHeader.biBitCount=32;info.bmiHeader.biCompression=BI_RGB;
 HBITMAP bitmap=CreateDIBSection(screen,&info,DIB_RGB_COLORS,&pixels,0,0);BOOL ok=FALSE;if(bitmap&&dc){HGDIOBJ old=SelectObject(dc,bitmap);
  RECTL bounds={0,0,r.right,r.bottom};BOOL drawn=view&&SUCCEEDED(IViewObject_Draw(view,DVASPECT_CONTENT,-1,0,0,0,dc,&bounds,0,0,0));
  BOOL visible=FALSE;for(LONG i=0;i<r.right*r.bottom;i++)if(((DWORD*)pixels)[i]&0xffffff){visible=TRUE;break;}
  if(!drawn||!visible)drawn=PrintWindow(rdp_window?rdp_window:window,dc,2);
  if(drawn){WCHAR path[MAX_PATH];lstrcpyW(path,output);lstrcatW(path,L"\\");lstrcatW(path,name);lstrcatW(path,L".bmp");HANDLE file=CreateFileW(path,GENERIC_WRITE,0,0,CREATE_ALWAYS,0,0);
   if(file!=INVALID_HANDLE_VALUE){DWORD n,size=r.right*r.bottom*4;BITMAPFILEHEADER header={0};header.bfType=0x4d42;header.bfOffBits=sizeof(header)+sizeof(info.bmiHeader);header.bfSize=header.bfOffBits+size;
    ok=WriteFile(file,&header,sizeof(header),&n,0)&&WriteFile(file,&info.bmiHeader,sizeof(info.bmiHeader),&n,0)&&WriteFile(file,pixels,size,&n,0)&&FlushFileBuffers(file);CloseHandle(file);}
  }SelectObject(dc,old);
 }if(bitmap)DeleteObject(bitmap);if(dc)DeleteDC(dc);ReleaseDC(window,screen);return ok;
}
static DWORD WINAPI commands(void*unused){(void)unused;char line[32];DWORD n;UINT count=0;HANDLE input=GetStdHandle(STD_INPUT_HANDLE);
 while(ReadFile(input,line+count,1,&n,0)&&n){if(line[count]=='\n'){line[count]=0;if(!lstrcmpA(line,"desktop"))PostMessageW(window,WM_APP+2,0,0);else if(!lstrcmpA(line,"winver"))PostMessageW(window,WM_APP+3,0,0);else if(!lstrcmpA(line,"quit"))PostMessageW(window,WM_CLOSE,0,0);count=0;}else if(count<30)count++;}return 0;}
static const IID events_iid={0x336d5562,0xefa8,0x482e,{0x8c,0xb3,0xc5,0xc0,0xfc,0x7a,0x7d,0xb6}};
static HRESULT STDMETHODCALLTYPE query(IDispatch*s,REFIID iid,void**out){if(same_iid(iid,&IID_IUnknown)||same_iid(iid,&IID_IDispatch)||same_iid(iid,&events_iid)){*out=s;return S_OK;}*out=0;return E_NOINTERFACE;}
static ULONG STDMETHODCALLTYPE ref(IDispatch*s){(void)s;return 1;}
static HRESULT STDMETHODCALLTYPE typecount(IDispatch*s,UINT*n){(void)s;*n=0;return S_OK;}
static HRESULT STDMETHODCALLTYPE typeinfo(IDispatch*s,UINT i,LCID l,ITypeInfo**t){(void)s;(void)i;(void)l;(void)t;return E_NOTIMPL;}
static HRESULT STDMETHODCALLTYPE names(IDispatch*s,REFIID i,LPOLESTR*n,UINT c,LCID l,DISPID*d){(void)s;(void)i;(void)n;(void)c;(void)l;(void)d;return E_NOTIMPL;}
static HRESULT STDMETHODCALLTYPE event(IDispatch*s,DISPID id,REFIID i,LCID l,WORD f,DISPPARAMS*p,VARIANT*v,EXCEPINFO*e,UINT*b){(void)s;(void)i;(void)l;(void)f;(void)p;(void)v;(void)e;(void)b;
 if(id==2)say("NATIVE_RDP_CONNECTED");if(id==3)PostMessageW(window,WM_APP+1,0,0);if(id==4){say("NATIVE_RDP_DISCONNECTED");PostMessageW(window,WM_CLOSE,0,0);}return S_OK;}
static IDispatchVtbl sink_vtable={query,ref,ref,typecount,typeinfo,names,event};static IDispatch sink={&sink_vtable};
static LRESULT CALLBACK procedure(HWND w,UINT msg,WPARAM a,LPARAM b){
 if(msg==WM_APP+1){say("NATIVE_RDP_LOGON_COMPLETE");KillTimer(w,1);return 0;}
 if(msg==WM_APP+2||msg==WM_APP+3){BOOL ok=capture(msg==WM_APP+2?L"native-desktop":L"native-winver");say(ok?(msg==WM_APP+2?"NATIVE_CAPTURED_DESKTOP":"NATIVE_CAPTURED_WINVER"):"NATIVE_CAPTURE_FAILED");return 0;}
 if(msg==WM_TIMER){KillTimer(w,a);if(a==1){capture(L"native-timeout");say("NATIVE_RDP_TIMEOUT");DestroyWindow(w);}
  else if(a==2){capture(L"native-connected");if(!keys){say("NATIVE_KEYS_UNAVAILABLE");DestroyWindow(w);return 0;}SetFocus(rdp_window);key(VK_LWIN,FALSE,TRUE);key('R',FALSE,FALSE);key('R',TRUE,FALSE);key(VK_LWIN,TRUE,TRUE);SetTimer(w,3,1500,0);}
  else if(a==3)say(type_command()?"NATIVE_PROBE_REQUESTED":"NATIVE_KEYS_FAILED");return 0;}
 if(msg==WM_CLOSE){exit_code=0;DestroyWindow(w);return 0;}if(msg==WM_DESTROY){PostQuitMessage(0);return 0;}return DefWindowProcW(w,msg,a,b);
}
void entry(void){int argc=0;WCHAR **argv=CommandLineToArgvW(GetCommandLineW(),&argc);if(argc!=3||lstrlenW(argv[2])>MAX_PATH-32)ExitProcess(2);LONG port=0;for(WCHAR*p=argv[1];*p;p++){if(*p<L'0'||*p>L'9')ExitProcess(2);port=port*10+*p-L'0';}if(port<1024||port>65535)ExitProcess(2);lstrcpyW(output,argv[2]);
 if(FAILED(CoInitializeEx(0,COINIT_APARTMENTTHREADED)))ExitProcess(3);HMODULE atl=LoadLibraryW(L"atl.dll");if(!atl)ExitProcess(4);
 typedef BOOL(WINAPI*Init)(void);typedef HRESULT(WINAPI*Create)(LPCOLESTR,HWND,IStream*,IUnknown**,IUnknown**,REFIID,IUnknown*);
 Init init=(Init)GetProcAddress(atl,"AtlAxWinInit");Create create=(Create)GetProcAddress(atl,"AtlAxCreateControlEx");if(!init||!create||!init())ExitProcess(5);
 WNDCLASSW cls={0};cls.lpfnWndProc=procedure;cls.hInstance=GetModuleHandleW(0);cls.lpszClassName=L"USOS.Lab.RDP";RegisterClassW(&cls);
 window=CreateWindowExW(WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE,cls.lpszClassName,L"USOS lab RDP",WS_POPUP|WS_VISIBLE,-16000,-16000,800,600,0,0,cls.hInstance,0);if(!window)ExitProcess(6);
 /* Use the documented CLSID explicitly. A C++ class name is not a ProgID;
  * ATL otherwise interprets an unregistered string as a browser URL. */
 IUnknown *container=0,*unknown=0;HRESULT h=create(L"{8B918B82-7985-4C24-89DF-C33AD2BBFBCD}",window,0,&container,&unknown,&IID_NULL,0);if(FAILED(h)||!unknown){say("NATIVE_STAGE_CREATE");error(h);ExitProcess(7);}h=IUnknown_QueryInterface(unknown,&IID_IDispatch,(void**)&control);if(FAILED(h))ExitProcess(8);
 IConnectionPointContainer*points=0;IConnectionPoint*point=0;DWORD cookie=0;
 h=IUnknown_QueryInterface(unknown,&IID_IConnectionPointContainer,(void**)&points);if(FAILED(h)){say("NATIVE_STAGE_POINTS");error(h);ExitProcess(9);}
 h=IConnectionPointContainer_FindConnectionPoint(points,&events_iid,&point);if(FAILED(h)){IEnumConnectionPoints*list=0;if(SUCCEEDED(IConnectionPointContainer_EnumConnectionPoints(points,&list))){IConnectionPoint*p=0;while(IEnumConnectionPoints_Next(list,1,&p,0)==S_OK){IID g;if(SUCCEEDED(IConnectionPoint_GetConnectionInterface(p,&g)))guid_log(&g);IConnectionPoint_Release(p);}IEnumConnectionPoints_Release(list);}say("NATIVE_STAGE_FIND_EVENTS");error(h);ExitProcess(9);}
 h=IConnectionPoint_Advise(point,(IUnknown*)&sink,&cookie);if(FAILED(h)){say("NATIVE_STAGE_ADVISE");error(h);ExitProcess(9);}
 VARIANT advanced={0};h=invoke(control,L"AdvancedSettings7",DISPATCH_PROPERTYGET,0,&advanced);if(FAILED(h)||advanced.vt!=VT_DISPATCH)ExitProcess(10);IDispatch*d=advanced.pdispVal;
 h=number(d,L"CachePersistenceActive",0);if(SUCCEEDED(h))h=number(d,L"BitmapPersistence",0);if(FAILED(h)){error(h);ExitProcess(11);}
 h=number(d,L"allowBackgroundInput",1);if(FAILED(h)){error(h);ExitProcess(11);}
 bool_property(d,L"EnableCredSspSupport",FALSE);bool_property(d,L"NegotiateSecurityLayer",FALSE);number(d,L"AuthenticationLevel",0);number(d,L"RDPPort",port);
 bool_property(d,L"RedirectDrives",FALSE);bool_property(d,L"RedirectClipboard",FALSE);bool_property(d,L"RedirectPrinters",FALSE);bool_property(d,L"RedirectPorts",FALSE);bool_property(d,L"RedirectSmartCards",FALSE);number(d,L"AudioRedirectionMode",2);number(d,L"KeyboardHookMode",1);
 string(control,L"Server",L"127.0.0.1");string(control,L"UserName",L"USOS");string(control,L"Domain",L"USOS-WM-VM");number(control,L"DesktopWidth",800);number(control,L"DesktopHeight",600);number(control,L"ColorDepth",32);h=string(d,L"ClearTextPassword",L"Local-VM-Only-2026!");if(FAILED(h)){error(h);ExitProcess(12);}
 IOleWindow*ole=0;if(SUCCEEDED(IUnknown_QueryInterface(unknown,&IID_IOleWindow,(void**)&ole))){IOleWindow_GetWindow(ole,&rdp_window);IOleWindow_Release(ole);}IUnknown_QueryInterface(unknown,&local_view,(void**)&view);if(rdp_window)MoveWindow(rdp_window,0,0,800,600,TRUE);say("NATIVE_CLIENT_READY");
 HANDLE reader=CreateThread(0,0,commands,0,0,0);if(reader)CloseHandle(reader);SetTimer(window,1,300000,0);h=invoke(control,L"Connect",DISPATCH_METHOD,0,0);if(FAILED(h)){error(h);ExitProcess(13);}MSG msg;while(GetMessageW(&msg,0,0,0)>0){TranslateMessage(&msg);DispatchMessageW(&msg);}ExitProcess(exit_code);
}
