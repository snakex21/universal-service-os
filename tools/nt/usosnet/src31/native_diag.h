/* SPDX-License-Identifier: GPL-3.0-or-later
 * Own NT31 full-MAC diagnostics. ZwFlushKey and MmMapIoSpace are confirmed
 * exports of the original NT31 CD, not inferred from an NDIS miniport ABI.
 * All callers are at PASSIVE_LEVEL (initialization or the polling thread
 * after KeLowerIrql). No registry work while holding an NDIS spin lock.
 */
#pragma warning(disable:4996)
static WCHAR g_31Key[256];
static BOOLEAN g_31Ready;
static ULONG g_31Sequence;
static KMUTEX g_31Mutex;

static void D31String(PUNICODE_STRING u, PCWSTR s)
{
    USHORT n=0;
    while(s[n])n++;
    u->Buffer=(PWSTR)s;u->Length=n*2;u->MaximumLength=u->Length+2;
}
static void D31Init(PUNICODE_STRING path)
{
    static const WCHAR suffix[]=L"\\Parameters\\NativeDiag";
    ULONG n=path->Length/2,i;
    if(path->Length%2 || n+sizeof(suffix)/2>sizeof(g_31Key)/2)return;
    for(i=0;i<n;i++)g_31Key[i]=path->Buffer[i];
    for(i=0;i<sizeof(suffix)/2;i++)g_31Key[n+i]=suffix[i];
    KeInitializeMutex(&g_31Mutex,0);g_31Ready=TRUE;
}
static void D31Point(ULONG point,ULONG status,ULONG value)
{
    static const PCWSTR names[]={L"Stage",L"Status",L"Value",L"Sequence"};
    ULONG values[4],i,disposition;
    UNICODE_STRING key,name;OBJECT_ATTRIBUTES oa;HANDLE h;
    if(!g_31Ready || KeGetCurrentIrql()!=PASSIVE_LEVEL)return;
    KeWaitForSingleObject(&g_31Mutex,Executive,KernelMode,FALSE,NULL);
    values[0]=point;values[1]=status;values[2]=value;values[3]=++g_31Sequence;
    D31String(&key,g_31Key);InitializeObjectAttributes(&oa,&key,OBJ_CASE_INSENSITIVE,NULL,NULL);
    if(!NT_SUCCESS(ZwCreateKey(&h,KEY_SET_VALUE,&oa,0,NULL,REG_OPTION_NON_VOLATILE,&disposition))){KeReleaseMutex(&g_31Mutex,FALSE);return;}
    for(i=0;i<4;i++){D31String(&name,names[i]);ZwSetValueKey(h,&name,0,REG_DWORD,values+i,4);}
    ZwFlushKey(h);ZwClose(h);KeReleaseMutex(&g_31Mutex,FALSE);
}
