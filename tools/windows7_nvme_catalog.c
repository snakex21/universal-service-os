/* Register the original Microsoft inbox-driver catalog in disposable WinPE.
 * The package hash is pinned by the build; normal Windows is never serviced.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wincrypt.h>
#include <mscat.h>
static int say(const char *s){DWORD n=0,w;while(s[n])n++;WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),s,n,&w,0);return 1;}
void entry(void){
 HKEY key;
 if(RegOpenKeyExW(HKEY_LOCAL_MACHINE,L"SYSTEM\\CurrentControlSet\\Control\\MiniNT",0,KEY_READ,&key)!=ERROR_SUCCESS)ExitProcess(1);
 RegCloseKey(key);
 WCHAR path[MAX_PATH];unsigned n=GetModuleFileNameW(0,path,MAX_PATH);
 if(!n||n>=MAX_PATH-32)ExitProcess(1);
 while(n&&path[n-1]!='\\')n--;if(!n)ExitProcess(1);
 const WCHAR *tail=L"nvme\\MicrosoftNVMe.cat";while((path[n++]=*tail++));
 HCATADMIN context=0;
 if(!CryptCATAdminAcquireContext(&context,0,0))ExitProcess(say("NVMe: cannot open the WinPE catalog store.\r\n"));
 HCATINFO catalog=CryptCATAdminAddCatalog(context,path,L"usos-microsoft-nvme.cat",0);
 if(catalog)CryptCATAdminReleaseCatalogContext(context,catalog,0);
 CryptCATAdminReleaseContext(context,0);
 if(!catalog)ExitProcess(say("NVMe: cannot register the original Microsoft catalog.\r\n"));
 say("NVMe: original Microsoft driver catalog registered.\r\n");ExitProcess(0);
}
