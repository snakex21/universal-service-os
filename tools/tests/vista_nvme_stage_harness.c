#include <windows.h>
#include <wincrypt.h>
#include <assert.h>
static int scenario;
static WCHAR windows[MAX_PATH]=L"C:\\Windows";
static void report(const char *text,DWORD code){(void)text;(void)code;}
static DWORD attrs(LPCWSTR p){(void)p;return scenario==4?INVALID_FILE_ATTRIBUTES:0;}
static HANDLE file(LPCWSTR a,DWORD b,DWORD c,LPSECURITY_ATTRIBUTES d,DWORD e,DWORD f,HANDLE g){(void)a;(void)b;(void)c;(void)d;(void)e;(void)f;(void)g;return scenario==3?INVALID_HANDLE_VALUE:(HANDLE)1;}
static BOOL read_data(HANDLE a,LPVOID b,DWORD c,LPDWORD n,LPOVERLAPPED e){(void)a;(void)c;(void)e;((BYTE*)b)[0]=1;*n=1;return TRUE;}
static BOOL close_handle(HANDLE h){(void)h;return TRUE;}
static HCERTSTORE open_store(LPCSTR a,DWORD b,HCRYPTPROV_LEGACY c,DWORD d,const void *e){(void)a;(void)b;(void)c;(void)d;(void)e;return scenario==1?0:(HCERTSTORE)1;}
static BOOL add_cert(HCERTSTORE a,DWORD b,const BYTE*c,DWORD d,DWORD e,PCCERT_CONTEXT*f){(void)a;(void)b;(void)c;(void)d;(void)e;(void)f;return TRUE;}
static BOOL close_store(HCERTSTORE a,DWORD b){(void)a;(void)b;return TRUE;}
static BOOL process(LPCWSTR a,LPWSTR b,LPSECURITY_ATTRIBUTES c,LPSECURITY_ATTRIBUTES d,BOOL e,DWORD f,LPVOID g,LPCWSTR h,LPSTARTUPINFOW i,LPPROCESS_INFORMATION j){(void)a;(void)b;(void)c;(void)d;(void)e;(void)f;(void)g;(void)h;(void)i;j->hThread=(HANDLE)1;j->hProcess=(HANDLE)2;return TRUE;}
static DWORD wait_process(HANDLE a,DWORD b){(void)a;(void)b;return WAIT_OBJECT_0;}
static BOOL exit_code(HANDLE a,LPDWORD b){(void)a;*b=scenario==2?5:0;return TRUE;}
static BOOL terminate_process(HANDLE a,UINT b){(void)a;(void)b;return TRUE;}
static DWORD last_error(void){return ERROR_ACCESS_DENIED;}
#define GetFileAttributesW attrs
#define CreateFileW file
#define ReadFile read_data
#define CloseHandle close_handle
#define CertOpenStore open_store
#define CertAddEncodedCertificateToStore add_cert
#define CertCloseStore close_store
#define CreateProcessW process
#define WaitForSingleObject wait_process
#define GetExitCodeProcess exit_code
#define TerminateProcess terminate_process
#define GetLastError last_error
#include "nvme_stage_under_test.h"
int main(void){
 scenario=0;assert(nvme_stage());
 scenario=1;assert(!nvme_stage()); /* certificate-store failure */
 scenario=2;assert(!nvme_stage()); /* pnputil failure */
 scenario=3;assert(!nvme_stage()); /* missing certificate */
 scenario=4;assert(nvme_stage()); /* no NVMe package on a SATA install */
 return 0;
}
