/* Host-only harness for usos-log --previous-install: scans one fake volume
 * root (argv[1], trailing backslash) into a fake USB session folder (argv[2]). */
#define entry logger_entry
#include "../windows_setup_logging.c"
#undef entry
int main(int argc,char **argv){
 WCHAR drive[MAX_PATH];if(argc!=3)return 2;
 if(!MultiByteToWideChar(CP_UTF8,0,argv[1],-1,drive,MAX_PATH)||!MultiByteToWideChar(CP_UTF8,0,argv[2],-1,root,MAX_PATH))return 2;
 return scan_volume(drive,L"T",GetStdHandle(STD_OUTPUT_HANDLE))?0:1;
}
