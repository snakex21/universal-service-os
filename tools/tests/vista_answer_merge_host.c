/* Exercise the production Vista CSMWrap answer merge (windows_vista_install.c,
 * merge_user_answer) on a disposable directory: the exe's folder stands for
 * the PE's X:\Windows\System32 and holds usos-unattend.xml; the result is the
 * vista-answer.xml the installer hands to Setup. The cab path is the PE one
 * (servicing_cab, set by prepare_servicing_answer in production). With
 * --hidden the profile's commands are wrapped first (hide_answer_commands, as
 * the installer does before the merge). Exit: 0 merged, 1 refused (the
 * installer then stops before Setup), 2 no answer. */
#define entry unused_vista_entry
#include "../windows_vista_install.c"
#undef entry
void entry(void){
 unsigned n=GetModuleFileNameW(0,base,MAX_PATH);
 if(!n||n>=MAX_PATH-48)ExitProcess(3);
 while(n&&base[n-1]!=L'\\')n--;base[n]=0;
 lstrcpyW(servicing_cab,L"X:\\Windows\\System32\\Windows6.0-KB2864202-x64.cab");
 static WCHAR answer[MAX_PATH];lstrcpyW(answer,L"vista-servicing.xml");
 const WCHAR *c=GetCommandLineW();BOOL hidden=FALSE;for(;*c;c++)if(c[0]==L'-'&&c[1]==L'-'&&c[2]==L'h')hidden=TRUE;
 if(hidden&&!hide_answer_commands())ExitProcess(1);
 if(!merge_user_answer(answer))ExitProcess(1);
 ExitProcess(lstrcmpW(answer,L"vista-servicing.xml")?0:2);
}
