/* Host executes the actual extracted DriverEntry, not a mirrored call. */
__declspec(dllimport) void __stdcall ExitProcess(unsigned long);
#define CHECK(x) do{if(!(x))ExitProcess(__LINE__);}while(0)
typedef unsigned long ULONG,NDIS_STATUS;
typedef long NTSTATUS;
typedef unsigned int UINT;
typedef unsigned char UCHAR;
typedef unsigned short USHORT;
typedef void *NDIS_HANDLE,*PDRIVER_OBJECT,*PUNICODE_STRING;
typedef struct {USHORT Length,MaximumLength;const unsigned short *Buffer;} NDIS_STRING;
#define NDIS_STRING_CONST(s) {18,20,L"USOSNET31"}
#define STATUS_NOT_SUPPORTED ((NTSTATUS)0xc00000bb)
#define STATUS_INSUFFICIENT_RESOURCES ((NTSTATUS)0xc000009a)
#define NDIS_STATUS_SUCCESS 0
#define NULL ((void *)0)
typedef void *U31_OPEN,*U31_CLOSE,*U31_SEND,*U31_TRANSFER,*U31_RESET;
typedef void *U31_REQUEST,*U31_UNLOAD,*U31_ADD,*U31_REMOVE;
/* The real U31_MAC declaration is extracted with DriverEntry at build time. */
#include "mac_characteristics_actual.inc"
static NDIS_HANDLE Wrapper,Mac;
static char KeNumberProcessors=1;
static int initCalls,registerCalls,terminateCalls,initFailure,registrationFailure;
static int DriverToken,PathToken;
static struct {void *DriverObject;} WrapperObject;
static unsigned int KeGetCurrentIrql(void){return 0;}
static void InitialTrace(const char *text,ULONG a,ULONG b){(void)text;(void)a;(void)b;}
static void D31Init(PUNICODE_STRING path){(void)path;}
static void D31Point(ULONG point,ULONG status,ULONG value){(void)point;(void)status;(void)value;}
static void UsZero(void *buffer,ULONG length){volatile unsigned char *p=buffer;while(length--)*p++=0;}
static void Open(void){}static void Close(void){}static void Send(void){}static void Transfer(void){}
static void Reset(void){}static void Request(void){}static void GlobalQuery(void){}static void Unload(void){}
static void Add(void){}static void Remove(void){}
static void NdisInitializeWrapper(NDIS_HANDLE *out,PDRIVER_OBJECT driver,PUNICODE_STRING path,void *reserved)
{
    CHECK(driver==&DriverToken&&path==&PathToken&&!reserved);initCalls++;
    WrapperObject.DriverObject=driver;*out=initFailure?0:&WrapperObject;
}
static void NdisRegisterMac(NDIS_STATUS *status,NDIS_HANDLE *out,NDIS_HANDLE wrapper,NDIS_HANDLE context,U31_MAC *chars,UINT length)
{
    *out=0;registerCalls++;
    CHECK(wrapper==&WrapperObject);CHECK(context==&Mac);CHECK(wrapper!=context);
    CHECK(((void **)wrapper)[0]==&DriverToken);
    CHECK(length==0x38&&sizeof(*chars)==0x38&&chars->Major==3&&chars->Minor==0);
    CHECK(chars->Open&&chars->Add&&chars->Remove&&chars->Name.Buffer);
    *status=registrationFailure?0xc0000001:0;
    if(!registrationFailure)*out=(void *)0x12345678;
}
static void NdisTerminateWrapper(NDIS_HANDLE wrapper,void *reserved)
{CHECK(wrapper==&WrapperObject&&!reserved);terminateCalls++;}
#pragma warning(disable:4054 4055 4152)
#include "driver_entry_actual.inc"
static void reset_case(void)
{Wrapper=Mac=0;initCalls=registerCalls=terminateCalls=initFailure=registrationFailure=0;KeNumberProcessors=1;}
void __cdecl entry(void)
{
    reset_case();CHECK(DriverEntry(&DriverToken,&PathToken)==0);
    CHECK(initCalls==1&&registerCalls==1&&terminateCalls==0&&Mac==(void *)0x12345678);
    reset_case();KeNumberProcessors=2;CHECK(DriverEntry(&DriverToken,&PathToken)==STATUS_NOT_SUPPORTED);
    CHECK(initCalls==0&&registerCalls==0&&terminateCalls==0);
    reset_case();initFailure=1;CHECK(DriverEntry(&DriverToken,&PathToken)==STATUS_INSUFFICIENT_RESOURCES);
    CHECK(initCalls==1&&registerCalls==0&&terminateCalls==0);
    reset_case();registrationFailure=1;CHECK(DriverEntry(&DriverToken,&PathToken)==(NTSTATUS)0xc0000001);
    CHECK(initCalls==1&&registerCalls==1&&terminateCalls==1);
    ExitProcess(0);
}
