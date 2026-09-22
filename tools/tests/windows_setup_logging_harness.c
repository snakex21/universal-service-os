/* Host-only file-copy harness. It cannot resolve disks or enter the PE watcher. */
#define entry logger_entry
#include "../windows_setup_logging.c"
#undef entry
int main(int argc,char **argv){
 WCHAR from[MAX_PATH];if(argc!=3)return 2;
 if(!MultiByteToWideChar(CP_UTF8,0,argv[1],-1,from,MAX_PATH)||!MultiByteToWideChar(CP_UTF8,0,argv[2],-1,root,MAX_PATH))return 2;
 HANDLE writer=CreateFileW(from,GENERIC_WRITE,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);if(writer==INVALID_HANDLE_VALUE)return 3;
 save(from,L"snapshot.log");CloseHandle(writer);
 return GetFileAttributesW(dst)==INVALID_FILE_ATTRIBUTES?1:0;
}
