#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include "core.h"
#include "template.h"
#include "message_table.h"
#include "public_ids.h"
#define TEXT_CAP 768u
#define CONTROL_CAP 128u
#define CAPTURE_BUDGET_MS 15000u
#define OBSERVE_AFTER_MS 60000u
static HANDLE serial=INVALID_HANDLE_VALUE;
static HANDLE public_file=INVALID_HANDLE_VALUE;
static HANDLE output_lock;
static volatile LONG stopping;
static HANDLE native_process;
static HMODULE modules[N4_MODULE_COUNT];
static WCHAR texts[CONTROL_CAP][TEXT_CAP];
static HWND windows[CONTROL_CAP],owners[CONTROL_CAP];
static unsigned roles[CONTROL_CAP],text_count;
static WCHAR message[TEXT_CAP],prepared[TEXT_CAP],normalized[TEXT_CAP];
static unsigned message1010_read,modules_complete,matched_static[CONTROL_CAP];
static HWND ok_button,next_button;
static HWND error_owner;
static unsigned ambiguous_error;
static unsigned error_match_count;
static unsigned excluded_edit,has_next,has_ok;
static DWORD capture_started;
static unsigned capture_timed_out;
static char native_command[]=N4_NATIVE_COMMAND;
static void emit(const char *s){
 DWORD written,length=(DWORD)lstrlenA(s);
 if(public_file!=INVALID_HANDLE_VALUE)WriteFile(public_file,s,length,&written,0);
 if(serial!=INVALID_HANDLE_VALUE)WriteFile(serial,s,length,&written,0);
}
static void number(unsigned long n){char b[12];unsigned k=0;do{b[k++]=(char)('0'+n%10);n/=10;}while(n&&k<10);while(k){char out[2];out[0]=b[--k];out[1]=0;emit(out);}}
static void fixed(const char *name,unsigned value){emit("NT4PAGE ");emit(name);emit("=");emit(value?"YES\r\n":"NO\r\n");}
static int lock_output(void){DWORD result;if(!output_lock)return 0;result=WaitForSingleObject(output_lock,INFINITE);return result==WAIT_OBJECT_0||result==WAIT_ABANDONED;}
static void worker_state(const char *s){if(lock_output()){if(!stopping)emit(s);ReleaseMutex(output_lock);}}
static unsigned read_caption(void *context,N4W *out,unsigned cap){
 HWND hwnd=(HWND)context;DWORD_PTR count=0;DWORD used=GetTickCount()-capture_started;UINT timeout;
 if(used>=CAPTURE_BUDGET_MS){capture_timed_out=1;return 0;}
 timeout=(UINT)(CAPTURE_BUDGET_MS-used);if(timeout>2000)timeout=2000;
 if(!SendMessageTimeoutW(hwnd,WM_GETTEXT,(WPARAM)cap,(LPARAM)out,SMTO_ABORTIFHUNG|SMTO_BLOCK,timeout,&count))return 0;
 if(count>=cap-1)return 0;return (unsigned)count;
}
static int class_is(const WCHAR *a,const WCHAR *b){return n4_equal((const N4W*)a,(const N4W*)b);}
static void remember(HWND hwnd,HWND owner,int top){
 WCHAR cls[48],raw[TEXT_CAP];unsigned n;
 if(!IsWindowVisible(hwnd)||text_count>=CONTROL_CAP)return;
 if(!GetClassNameW(hwnd,cls,48))return;
 if(class_is(cls,L"Edit")){excluded_edit=1;return;}
 n=n4_guarded_read((const N4W*)cls,top,read_caption,(void*)hwnd,(N4W*)raw,TEXT_CAP);
 if(!n)return;
 n=n4_normalize((const N4W*)raw,(N4W*)texts[text_count],TEXT_CAP);
 if(!n)return;
 roles[text_count]=top?0u:(class_is(cls,L"Button")?2u:1u);windows[text_count]=hwnd;owners[text_count]=owner;
 if(class_is(cls,L"Button")&&IsWindowEnabled(hwnd)){
  if(class_is(texts[text_count],L"dalej >")){next_button=hwnd;has_next=1;}
  if(class_is(texts[text_count],L"ok")){ok_button=hwnd;has_ok=1;}
 }
 text_count++;
}
static BOOL CALLBACK child(HWND hwnd,LPARAM owner){
 if(GetTickCount()-capture_started>=CAPTURE_BUDGET_MS){capture_timed_out=1;return FALSE;}
 remember(hwnd,(HWND)owner,0);return TRUE;
}
static BOOL CALLBACK top(HWND hwnd,LPARAM unused){
 WCHAR cls[48];(void)unused;
 if(GetTickCount()-capture_started>=CAPTURE_BUDGET_MS){capture_timed_out=1;return FALSE;}
 if(!IsWindowVisible(hwnd)||!GetClassNameW(hwnd,cls,48)||!class_is(cls,L"#32770"))return TRUE;
 remember(hwnd,hwnd,1);EnumChildWindows(hwnd,child,(LPARAM)hwnd);return TRUE;
}
static int read_resource(const N4ID *id){
 DWORD n=0;
 if(!modules[id->module])return 0;
 if(id->message){
  HRSRC resource;HGLOBAL loaded;const BYTE *data;DWORD size;N4MESSAGE view;
  resource=FindResourceW(modules[id->module],MAKEINTRESOURCEW(1),MAKEINTRESOURCEW(11));if(!resource)return 0;
  size=SizeofResource(modules[id->module],resource);if(size>1024u*1024u)return 0;
  loaded=LoadResource(modules[id->module],resource);if(!loaded)return 0;data=(const BYTE*)LockResource(loaded);
  if(!n4_message_view(data,(unsigned)size,id->id,&view))return 0;
  if(view.unicode){unsigned i;n=view.bytes/2;if(n>=TEXT_CAP-1)return 0;for(i=0;i<n;i++)message[i]=(WCHAR)n4_msg16(view.text+2*i);message[n]=0;}
  else {int count;if(view.bytes>TEXT_CAP*2)return 0;count=MultiByteToWideChar(CP_ACP,0,(const char*)view.text,(int)view.bytes,message,TEXT_CAP-1);if(count<=0)return 0;n=(DWORD)count;message[n]=0;}
  if(!n4_message_controls((const N4W*)message,(N4W*)prepared,TEXT_CAP))return 0;
  n=n4_normalize((const N4W*)prepared,(N4W*)normalized,TEXT_CAP);
  if(id->id==1010&&lstrcmpA(n4_module_names[id->module],"KERNEL32")==0)message1010_read=n!=0;
  return n!=0;
 }
 n=(DWORD)LoadStringW(modules[id->module],id->id,message,TEXT_CAP);
 if(!n||n>=TEXT_CAP-1)return 0;
 return n4_normalize((const N4W*)message,(N4W*)normalized,TEXT_CAP)!=0;
}
static unsigned read16(const BYTE *p){return (unsigned)p[0]|((unsigned)p[1]<<8);}
static DWORD read32(const BYTE *p){return (DWORD)read16(p)|((DWORD)read16(p+2)<<16);}
static const WCHAR *field(const BYTE *data,DWORD size,DWORD *pos){
 DWORD start;unsigned value;
 if(*pos+2>size){*pos=size+1;return 0;}
 value=read16(data+*pos);*pos+=2;
 if(value==0)return 0;
 if(value==0xffff){*pos+=2;if(*pos>size)*pos=size+1;return 0;}
 start=*pos-2;
 while(*pos+2<=size){value=read16(data+*pos);*pos+=2;if(!value)return (const WCHAR*)(data+start);}
 *pos=size+1;return 0;
}
static void compare_dialog_text(const N4DIALOG *id,unsigned slot,const WCHAR *source){
 unsigned j;
 if(!source||!n4_normalize((const N4W*)source,(N4W*)normalized,TEXT_CAP))return;
 for(j=0;j<text_count;j++)if(n4_public_exact((const N4W*)texts[j],(const N4W*)normalized)){
  if(roles[j]==1)matched_static[j]=1;
  emit(id->name?"NT4PAGE DIALOGNAME ":"NT4PAGE DIALOG ");emit(n4_module_names[id->module]);emit(" ");if(id->name)emit(id->public_name);else number(id->id);emit(" ");number(slot);emit(" ");emit(roles[j]==0?"TITLE\r\n":roles[j]==1?"STATIC\r\n":"BUTTON\r\n");
 }
}
static void compare_dialog(const N4DIALOG *id){
 HRSRC resource;HGLOBAL loaded;const BYTE *data;DWORD size,pos,style;unsigned extended,count,i;const WCHAR *text;
 if(!modules[id->module])return;
 resource=FindResourceW(modules[id->module],id->name?id->name:MAKEINTRESOURCEW(id->id),MAKEINTRESOURCEW(5));if(!resource)return;
 size=SizeofResource(modules[id->module],resource);if(size<18||size>1024*1024)return;
 loaded=LoadResource(modules[id->module],resource);if(!loaded)return;data=(const BYTE*)LockResource(loaded);if(!data)return;
 extended=read16(data+2)==0xffff;
 if(extended){if(size<26)return;style=read32(data+12);count=read16(data+16);pos=26;}
 else{style=read32(data);count=read16(data+8);pos=18;}
 if(count>256)return;
 field(data,size,&pos);field(data,size,&pos);text=field(data,size,&pos);compare_dialog_text(id,0,text);
 if(style&DS_SETFONT){pos+=extended?6u:2u;field(data,size,&pos);}
 for(i=0;i<count&&pos<=size;i++){
  pos=(pos+3u)&~3u;pos+=extended?24u:18u;
  field(data,size,&pos);text=field(data,size,&pos);compare_dialog_text(id,i+1,text);
  if(pos+2>size)return;{unsigned extra=read16(data+pos);pos+=2+extra;}
 }
}
static void compare_cached(void){
 unsigned i,j;
 if(!lock_output())return;
 if(stopping){ReleaseMutex(output_lock);return;}
 error_match_count=0;error_owner=0;ambiguous_error=0;ok_button=0;message1010_read=0;
 for(j=0;j<CONTROL_CAP;j++)matched_static[j]=0;
 emit("NT4PAGE BEGIN\r\n");
 for(i=0;i<N4_ID_COUNT;i++){
  if(!read_resource(&n4_ids[i]))continue;
  for(j=0;j<text_count;j++){
   if(!n4_public_template((const N4W*)texts[j],(const N4W*)normalized)){
    if(roles[j]==1&&n4_public_fragment((const N4W*)texts[j],(const N4W*)normalized)){
     emit("NT4PAGE FRAGMENT ");emit(n4_module_names[n4_ids[i].module]);emit(n4_ids[i].message?" MSG ":" STR ");number(n4_ids[i].id);emit(" STATIC\r\n");
    }
    continue;
   }
   if(roles[j]==1)matched_static[j]=1;
   emit("NT4PAGE MATCH ");emit(n4_module_names[n4_ids[i].module]);emit(n4_ids[i].message?" MSG ":" STR ");number(n4_ids[i].id);emit(" ");emit(roles[j]==0?"TITLE\r\n":roles[j]==1?"STATIC\r\n":"BUTTON\r\n");
   if(roles[j]==1&&n4_ids[i].error){
    error_match_count++;
    if(error_owner&&error_owner!=owners[j])ambiguous_error=1;
    else error_owner=owners[j];
   }
  }
 }
 for(i=0;i<N4_DIALOG_COUNT;i++)compare_dialog(&n4_dialogs[i]);
 if(error_owner&&!ambiguous_error)for(j=0;j<text_count;j++){
  if(roles[j]==2&&owners[j]==error_owner&&class_is(texts[j],L"ok")&&IsWindowEnabled(windows[j]))ok_button=windows[j];
 }
 fixed("EXCLUDED_EDIT_PRESENT",excluded_edit);fixed("POLISH_NEXT_PRESENT",has_next);fixed("OK_PRESENT",has_ok);fixed("PUBLIC_ERROR_MATCH",error_match_count!=0);fixed("ERROR_OWNER_UNIQUE",error_owner&&!ambiguous_error);
 fixed("CAPTURE_BUDGET_EXHAUSTED",capture_timed_out);
 fixed("ORACLE_MODULES_COMPLETE",modules_complete);fixed("ORACLE_MESSAGE1010_READ",message1010_read);fixed("ORACLE_CODEPAGE1250",GetACP()==1250);
 {unsigned unmatched=0;for(j=0;j<text_count;j++)if(roles[j]==1&&!matched_static[j])unmatched=1;fixed("UNMATCHED_STATIC_PRESENT",unmatched);}
 emit("NT4PAGE END\r\n");
 if(public_file!=INVALID_HANDLE_VALUE)FlushFileBuffers(public_file);
 ReleaseMutex(output_lock);
}
static void capture_controls(void){
 text_count=0;excluded_edit=0;has_next=0;has_ok=0;ok_button=0;next_button=0;capture_timed_out=0;capture_started=GetTickCount();EnumWindows(top,0);compare_cached();
}
static void click(HWND button){
 HWND owner=GetParent(button);if(owner)SetForegroundWindow(owner);PostMessageW(button,BM_CLICK,0,0);
}
static void open_serial(void){
 unsigned i;DCB state;COMMTIMEOUTS timeout;
 serial=CreateFileA("\\\\.\\COM1",GENERIC_READ|GENERIC_WRITE,0,0,OPEN_EXISTING,0,0);
 if(serial==INVALID_HANDLE_VALUE)return;
 for(i=0;i<sizeof(state);i++)((BYTE*)&state)[i]=0;
 for(i=0;i<sizeof(timeout);i++)((BYTE*)&timeout)[i]=0;
 state.DCBlength=sizeof(state);
 if(GetCommState(serial,&state)){
  state.BaudRate=115200;state.ByteSize=8;state.Parity=NOPARITY;state.StopBits=ONESTOPBIT;
  state.fBinary=1;state.fParity=0;state.fOutxCtsFlow=0;state.fOutxDsrFlow=0;state.fDtrControl=DTR_CONTROL_ENABLE;state.fDsrSensitivity=0;state.fOutX=0;state.fInX=0;state.fRtsControl=RTS_CONTROL_ENABLE;state.fAbortOnError=0;
  SetCommState(serial,&state);
 }
 timeout.WriteTotalTimeoutConstant=2000;SetCommTimeouts(serial,&timeout);
}
static DWORD WINAPI observe(void *unused){
 unsigned i,pos=0;char command[32];DWORD got;HDESK input;(void)unused;
 if(serial==INVALID_HANDLE_VALUE&&public_file==INVALID_HANDLE_VALUE)return 1;
 modules_complete=1;for(i=0;i<N4_MODULE_COUNT;i++){modules[i]=LoadLibraryExW(n4_module_paths[i],0,LOAD_LIBRARY_AS_DATAFILE);if(!modules[i])modules_complete=0;}
 worker_state("NT4PAGE READY\r\n");
 if(WaitForSingleObject(native_process,OBSERVE_AFTER_MS)!=WAIT_TIMEOUT)return 0;
 input=OpenInputDesktop(0,FALSE,DESKTOP_READOBJECTS|DESKTOP_WRITEOBJECTS|DESKTOP_ENUMERATE);
 if(stopping)return 0;
 if(input){if(SetThreadDesktop(input))worker_state("NT4PAGE INPUT_DESKTOP_ATTACHED=YES\r\n");else{CloseDesktop(input);worker_state("NT4PAGE INPUT_DESKTOP_ATTACHED=NO\r\n");}}
 else worker_state("NT4PAGE INPUT_DESKTOP_ATTACHED=NO\r\n");
 capture_controls();
 if(serial==INVALID_HANDLE_VALUE)return 0; /* File observation is independent of COM. */
 for(;;){
  char c;
  if(stopping)return 0;
  if(!ReadFile(serial,&c,1,&got,0)||got!=1)return 2;
  if(stopping)return 0;
  if(c=='\r')continue;
  if(c!='\n'){if(pos+1<sizeof(command))command[pos++]=c;else pos=0;continue;}
  command[pos]=0;pos=0;
  if(lstrcmpA(command,"QUERY")==0){compare_cached();continue;}
  if(lstrcmpA(command,"ACK_ERROR")==0&&error_match_count&&ok_button){click(ok_button);worker_state("NT4PAGE ACTION ACK_ERROR\r\n");}
  else if(lstrcmpA(command,"NEXT_PL")==0&&has_next&&!error_match_count&&next_button){click(next_button);worker_state("NT4PAGE ACTION NEXT_PL\r\n");}
  else{worker_state("NT4PAGE REJECTED\r\n");continue;}
  if(WaitForSingleObject(native_process,2000)!=WAIT_TIMEOUT)return 0;
  capture_controls();
 }
}
void entry(void){
 STARTUPINFOA startup;PROCESS_INFORMATION process;DWORD code=1;HANDLE observer=0;unsigned i;int locked;
 for(i=0;i<sizeof(startup);i++)((BYTE*)&startup)[i]=0;
 for(i=0;i<sizeof(process);i++)((BYTE*)&process)[i]=0;
 startup.cb=sizeof(startup);
 stopping=0;output_lock=CreateMutexA(0,FALSE,0);
 public_file=CreateFileA("C:\\USOS\\NT4\\NT4PAGE.LOG",GENERIC_WRITE,0,0,CREATE_NEW,FILE_ATTRIBUTE_NORMAL|FILE_FLAG_WRITE_THROUGH,0);
 open_serial();emit("NT4PAGE WRAPPER_READY\r\n");fixed("COM_CHANNEL_AVAILABLE",serial!=INVALID_HANDLE_VALUE);fixed("FILE_CHANNEL_AVAILABLE",public_file!=INVALID_HANDLE_VALUE);fixed("OBSERVER_SYNC_READY",output_lock!=0);
 if(!CreateProcessA(0,native_command,0,0,FALSE,0,0,0,&startup,&process)){emit("NT4PAGE NATIVE_CHILD_CREATE_FAILED\r\n");ExitProcess(240);}
 emit("NT4PAGE NATIVE_CHILD_STARTED\r\n");
 native_process=process.hProcess;CloseHandle(process.hThread);
 if(output_lock)observer=CreateThread(0,0,observe,0,0,0);
 WaitForSingleObject(native_process,INFINITE);GetExitCodeProcess(native_process,&code);
 InterlockedExchange(&stopping,1);
 locked=lock_output();
 fixed("NATIVE_CHILD_EXIT_ZERO",code==0);
 if(public_file!=INVALID_HANDLE_VALUE){FlushFileBuffers(public_file);CloseHandle(public_file);public_file=INVALID_HANDLE_VALUE;}
 if(serial!=INVALID_HANDLE_VALUE){CloseHandle(serial);serial=INVALID_HANDLE_VALUE;}
 if(locked)ReleaseMutex(output_lock);
 if(observer){WaitForSingleObject(observer,1000);CloseHandle(observer);} /* Never wait indefinitely for COM ReadFile. */
 CloseHandle(native_process);ExitProcess(code);
}
