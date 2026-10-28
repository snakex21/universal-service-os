/* Actual production header, fake OS: no host registry or services touched. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#define WINAPI
typedef uint32_t DWORD;
typedef int32_t LONG;
typedef unsigned char BYTE;
typedef void *HKEY;
#define MAX_PATH 260
#define DIR "C:\\USOS\\NT3\\"
#define SVC_KEY "SYSTEM\\CurrentControlSet\\Services\\"
#define SVC_NAME "usosnt3"
#define ERROR_FILE_NOT_FOUND 2
#define ERROR_PATH_NOT_FOUND 3
#define FILE_ATTRIBUTE_DIRECTORY 16
#define REG_DWORD 4
#define REG_SZ 1
#define KEY_READ 0x20019
#define KEY_WRITE 0x20006
#define SERVICE_WIN32_SHARE_PROCESS 32
#define SERVICE_KERNEL_DRIVER 1
#define SERVICE_AUTO_START 2
#define SERVICE_DEMAND_START 3
#define SERVICE_DISABLED 4
#define HKEY_LOCAL_MACHINE ((HKEY)123)

struct Service { const char *name; DWORD start, type; int exists; };
static struct Service services[5];
static DWORD last_error, version;
static unsigned test_minor = 50;
static int req, fail_record, status_write, done_write, write_fail, readback_bad;
static int product_server, access_bad, change_fail, writes, readonly_bad, closes, value_kind_bad, value_size_bad;
static const char *request_text;
static int len(const char *s) { return (int)strlen(s); }
static void say(const char *s) { (void)s; }
static int lstrcmpA(const char *a,const char *b) { return strcmp(a,b); }
static int lstrcmpiA(const char *a,const char *b) { return strcmp(a,b); }
static void lstrcpyA(char *a,const char *b) { strcpy(a,b); }
static void lstrcatA(char *a,const char *b) { strcat(a,b); }
static DWORD GetLastError(void) { return last_error; }
static DWORD GetFileAttributesA(const char *path) {
    last_error=ERROR_FILE_NOT_FOUND;
    if ((strstr(path,"CLNT35.REQ") && (req&1)) || (strstr(path,"CLNT351.REQ") && (req&2))) return 0;
    if ((strstr(path,"CLNT35.ERR") && (fail_record&1)) || (strstr(path,"CLNT351.ERR") && (fail_record&2))) return 0;
    return 0xffffffff;
}
static int read_text(const char *name,char *out,int cap) {
    (void)name;
    if (!req) return -1;
    if ((int)strlen(request_text)>=cap) return 0;
    strcpy(out,request_text); return (int)strlen(out);
}
static DWORD fake_version(void) { return version; }
static void *GetModuleHandleA(const char *name) { (void)name; return (void *)1; }
static void *GetProcAddress(void *module,const char *name) { (void)module;(void)name;return (void *)fake_version; }
static LONG RegOpenKeyExA(HKEY root,const char *path,DWORD zero,DWORD rights,HKEY *out) {
    int i;
    (void)root;(void)zero;
    if (!strcmp(path,"SYSTEM\\CurrentControlSet\\Control\\ProductOptions")) {
        *out=(HKEY)99; return 0;
    }
    if (strncmp(path,SVC_KEY,strlen(SVC_KEY))) return 5;
    for(i=0;i<5;i++) if(!strcmp(path+strlen(SVC_KEY),services[i].name)) {
        if (!services[i].exists) return ERROR_FILE_NOT_FOUND;
        if (access_bad && i==1) return 5;
        if ((i==2||i==3) && rights!=KEY_READ) readonly_bad=1;
        *out=&services[i]; return 0;
    }
    return ERROR_FILE_NOT_FOUND;
}
static LONG RegQueryValueExA(HKEY key,const char *name,void *zero,DWORD *type,BYTE *out,DWORD *size) {
    struct Service *s=(struct Service *)key;
    DWORD value;
    (void)zero;
    if(key==(HKEY)99) {
        const char *p=product_server?"ServerNT":"WinNT";
        *type=REG_SZ;*size=(DWORD)strlen(p)+1;strcpy((char *)out,p);return 0;
    }
    if(strcmp(name,"Start") && strcmp(name,"Type")) return 2;
    value=!strcmp(name,"Start")?s->start:s->type;
    if (readback_bad && writes && s==&services[1] && !strcmp(name,"Start")) value=2;
    *type=value_kind_bad?REG_SZ:REG_DWORD;*size=value_size_bad?3:4;memcpy(out,&value,4);return 0;
}
static int RegCloseKey(HKEY key) { (void)key;closes++;return 0; }
static int net351_dword(HKEY key,const char *name,DWORD value) {
    struct Service *s=(struct Service *)key;
    if (strcmp(name,"Start") || value!=SERVICE_DISABLED || s==&services[2] || s==&services[3]) return 0;
    if (change_fail && s==&services[1]) return 0;
    s->start=value;writes++;return 1;
}
static int write_file_checked(const char *name,const char *text) {
    (void)text;
    if (!strcmp(name,"CLNT35.ERR")) { fail_record|=1;return 1; }
    if (!strcmp(name,"CLNT351.ERR")) { fail_record|=2;return 1; }
    if (write_fail) return 0;
    if (!strcmp(name,"CLNT35.LOG") || !strcmp(name,"CLNT351.LOG")) status_write++;
    else if (!strcmp(name,"DONE.TXT")) done_write++;
    else return 0;
    return 1;
}
#include "../nt3/usosnt3/src/client_prepare.h"

static void reset(void) {
    const struct Service initial[5]={{"Browser",2,32,1},{"LanmanServer",2,32,1},
      {"LanmanWorkstation",2,32,1},{"Tcpip",3,1,1},{"usosnt3",2,16,1}};
    memcpy(services,initial,sizeof services);
    last_error=0;version=(test_minor<<8)|3;req=test_minor==50?1:2;fail_record=0;status_write=0;done_write=0;
    write_fail=0;readback_bad=0;product_server=0;access_bad=0;change_fail=0;
    writes=0;readonly_bad=0;closes=0;value_kind_bad=value_size_bad=0;g_client_requested=0;request_text=test_minor==50?CLIENT35_REQUEST:CLIENT351_REQUEST;
}
#define REQUIRE(x) do { if(!(x)){fprintf(stderr,"line%d: %s\n",__LINE__,#x);return 1;} }while(0)
static int cases(void) {
    reset(); REQUIRE(client_request()); REQUIRE(client_prepare(2));
    REQUIRE(services[0].start==4 && services[1].start==4 && services[2].start==2 && services[3].start==3);
    REQUIRE(writes==2 && !readonly_bad && status_write==1 && !fail_record);
    REQUIRE(client_commit_installer() && done_write==1 && services[4].start==4);
    reset();req=0;REQUIRE(client_request() && !g_client_requested && client_prepare(1) && !writes);
    reset();request_text="";REQUIRE(!client_request() && fail_record && !writes);
    reset();request_text="USOS NT35 client-no-sharing\r\nextra";REQUIRE(!client_request() && !writes);
    reset();version=((test_minor==50?51:50)<<8)|3;REQUIRE(!client_request() && !writes);
    reset();version|=0x80000000;REQUIRE(!client_request() && !writes);
    reset();product_server=1;REQUIRE(!client_request() && !writes);
    reset();fail_record=test_minor==50?1:2;REQUIRE(!client_request() && !writes);
    reset();REQUIRE(client_request());REQUIRE(!client_prepare(1) && !writes && fail_record);
    reset();services[0].exists=0;REQUIRE(client_request() && client_prepare(2) && writes==1);
    reset();services[1].exists=0;REQUIRE(client_request() && !client_prepare(2) && !writes);
    reset();services[1].type=16;REQUIRE(client_request() && !client_prepare(2) && !writes);
    reset();services[2].start=4;REQUIRE(client_request() && !client_prepare(2) && !writes);
    reset();services[3].type=32;REQUIRE(client_request() && !client_prepare(2) && !writes);
    reset();access_bad=1;REQUIRE(client_request() && !client_prepare(2) && !writes);
    reset();change_fail=1;REQUIRE(client_request() && !client_prepare(2) && fail_record && !done_write);
    reset();readback_bad=1;REQUIRE(client_request() && !client_prepare(2) && fail_record && !done_write);
    reset();write_fail=1;REQUIRE(client_request() && !client_prepare(2) && fail_record && !done_write);
    reset();write_fail=1;REQUIRE(!client_commit_installer() && fail_record && !done_write);
    reset();req=3;REQUIRE(!client_request() && fail_record==3 && !writes && !done_write);
    reset();version=0x1f03;REQUIRE(!client_request() && !writes); /* NT31 excluded */
    reset();version=0x0004;REQUIRE(!client_request() && !writes); /* NT4 excluded */
    reset();REQUIRE(client_request() && g_client_config->minor==test_minor);
    reset();value_kind_bad=1;REQUIRE(client_request() && !client_prepare(2) && !writes && fail_record);
    reset();value_size_bad=1;REQUIRE(client_request() && !client_prepare(2) && !writes && fail_record);
    return 0;
}

int main(void) {
 for(test_minor=50;test_minor<=51;test_minor++) if(cases())return 1;
 puts("SHARED actual production header: both minors,50 cases PASS");return 0;
}
