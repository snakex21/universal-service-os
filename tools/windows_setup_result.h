/* Records the exit code of the setup.exe process a WinPE helper started, as
 * "exit=<decimal>" in usos-setup-result.txt beside the helper (WinPE RAM).
 * The launcher (windows_setup_launcher.c) uses it to tell a Setup that the
 * user cancelled from a USOS failure before or after Setup. No C runtime. */
#ifndef USOS_SETUP_RESULT_H
#define USOS_SETUP_RESULT_H
static void usos_record_setup_result(DWORD code){
 static WCHAR where[MAX_PATH+32];
 DWORD n=GetModuleFileNameW(0,where,MAX_PATH);
 if(!n||n>=MAX_PATH)return;
 while(n&&where[n-1]!='\\')n--;
 if(!n)return;
 const WCHAR *name=L"usos-setup-result.txt";
 for(unsigned i=0;name[i];i++)where[n++]=name[i];
 where[n]=0;
 char text[24];unsigned at=0;
 text[at++]='e';text[at++]='x';text[at++]='i';text[at++]='t';text[at++]='=';
 char digits[12];unsigned d=0;do{digits[d++]=(char)('0'+code%10);code/=10;}while(code);
 while(d)text[at++]=digits[--d];
 text[at++]='\r';text[at++]='\n';
 HANDLE file=CreateFileW(where,GENERIC_WRITE,FILE_SHARE_READ,0,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,0);
 if(file==INVALID_HANDLE_VALUE)return;
 DWORD written=0;WriteFile(file,text,at,&written,0);FlushFileBuffers(file);CloseHandle(file);
}
#endif
