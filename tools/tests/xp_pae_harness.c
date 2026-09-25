#include "../windows_xp_pae.c"
__declspec(dllexport) int patch_copy(const char *input,const char *output,int hal){log_file=INVALID_HANDLE_VALUE;return patch(input,output,hal);}
__declspec(dllexport) LONG find_pattern(BYTE *b,DWORD n,const BYTE *p,DWORD len){return match(b,n,p,len);}
__declspec(dllexport) int mode_of(const char *command_line){return parse_mode(command_line);}
__declspec(dllexport) int stage_copy(const char *ini,const char *staged){log_file=INVALID_HANDLE_VALUE;return stage_bootini(ini,staged);}
__declspec(dllexport) int crash_dump_off(const char *subkey){log_file=INVALID_HANDLE_VALUE;return disable_crash_dump(HKEY_CURRENT_USER,subkey);}
__declspec(dllexport) int entry_present(const char *ini){return pae_entry_present(ini);}
__declspec(dllexport) void pae_string(const WCHAR *ini,const WCHAR *key,WCHAR *out,DWORD size){ini_string(ini,key,lstrcmpW(key,L"title")==0?USOS_XP_PAE_TITLE_EN:USOS_XP_PAE_RESTART_PROMPT_EN,out,size);}
__declspec(dllexport) int accounts_script(const char *script){log_file=INVALID_HANDLE_VALUE;return run_accounts_script(script);}
BOOL WINAPI DllMain(HINSTANCE h,DWORD reason,void *unused){(void)h;(void)reason;(void)unused;return TRUE;}
