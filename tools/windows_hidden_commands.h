/* Answers rendered from a USOS profile (src/flow/answer/autounattend.zig):
 * their RunSynchronous commands (the specialize tweaks, Windows 11's
 * LabConfig checks in windowsPE) start console programs (reg.exe, powercfg,
 * dism, cmd), and Windows Setup gives each one a visible console window.
 * usos_hidden_wrap() prefixes each such command with usos-run-hidden.exe
 * (tools/windows_hidden_run.c): a GUI-subsystem runner that starts the
 * command with CREATE_NO_WINDOW and logs its output and exit code to
 * %WINDIR%\Panther\usos-hidden-commands.log. The runner is found through the
 * search path: X:\Windows\System32 in WinPE, the target's System32 (copied
 * there after Setup applied the image) for specialize.
 *
 * Only answers carrying the renderer's marker comment are changed: a DATA
 * answer file keeps its own commands as they are. Text level, byte for byte
 * otherwise: "<Path>" directly inside a <RunSynchronousCommand> element gets
 * the prefix when the command stays within the schema's 259 characters
 * (XML entities count as one character). No C runtime. */
#ifndef USOS_HIDDEN_COMMANDS_H
#define USOS_HIDDEN_COMMANDS_H
#define USOS_HIDDEN_RUNNER "usos-run-hidden.exe"
#define USOS_HIDDEN_RUNNER_W L"usos-run-hidden.exe"
static const char usos_hidden_marker[]="<!-- USOS answer profile rendered for ";
static const char usos_hidden_prefix[]=USOS_HIDDEN_RUNNER " ";
static int uh_at(const char *t,DWORD n,DWORD i,const char *s){for(DWORD k=0;s[k];k++)if(i+k>=n||t[i+k]!=s[k])return 0;return 1;}
static int uh_find(const char *t,DWORD n,const char *s){for(DWORD i=0;i<n;i++)if(uh_at(t,n,i,s))return 1;return 0;}
/* Characters of the Path text starting at `i` (up to "</Path>"); entities
 * count once. 0xFFFFFFFF: no end tag. */
static DWORD uh_path_chars(const char *t,DWORD n,DWORD i){
 DWORD chars=0;
 while(i<n){
  if(uh_at(t,n,i,"</Path>"))return chars;
  if(t[i]=='<')return 0xFFFFFFFF;
  if(t[i]=='&'){while(i<n&&t[i]!=';')i++;}
  else if(((BYTE)t[i]&0xC0)==0x80){i++;continue;}
  i++;chars++;
 }
 return 0xFFFFFFFF;
}
/* in[0..n) -> out (cap bytes). Returns the output size, 0 on overflow or a
 * malformed Path. *wrapped: commands prefixed (0 for a non-USOS answer or an
 * answer without commands; out is then a copy of in). */
static DWORD usos_hidden_wrap(const char *in,DWORD n,char *out,DWORD cap,DWORD *wrapped){
 DWORD o=0,prefix=sizeof(usos_hidden_prefix)-1;int command=0,usos=uh_find(in,n,usos_hidden_marker);
 *wrapped=0;
 for(DWORD i=0;i<n;){
  if(usos&&uh_at(in,n,i,"<RunSynchronousCommand")&&i+22<n&&(in[i+22]==' '||in[i+22]=='>'))command=1;
  else if(uh_at(in,n,i,"</RunSynchronousCommand>"))command=0;
  else if(command&&uh_at(in,n,i,"<Path>")){
   for(DWORD k=0;k<6;k++){if(o>=cap)return 0;out[o++]=in[i++];}
   DWORD chars=uh_path_chars(in,n,i);if(chars==0xFFFFFFFF)return 0;
   if(chars&&chars+prefix<=259&&!uh_at(in,n,i,usos_hidden_prefix)){
    for(DWORD k=0;k<prefix;k++){if(o>=cap)return 0;out[o++]=usos_hidden_prefix[k];}
    (*wrapped)++;
   }
   continue;
  }
  if(o>=cap)return 0;out[o++]=in[i++];
 }
 return o;
}
#endif
