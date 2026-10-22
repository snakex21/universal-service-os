/* NT3.1 NDIS3 full-MAC for one explicitly staged QEMU 82576, UP only.
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * No private wrapper fields, miniport aliases, PCI scanning or IRQ/MSI.
 * Original full-MAC/adapter/filter contracts: lifecycle-04/05/06 metadata.
 */
#include "usosnet31.h"
#include "u31_policy.h"
#pragma warning(disable:4054 4055 4152 4201 4214)
unsigned long __cdecl __indword(unsigned short);
unsigned short __cdecl __inword(unsigned short);
void __cdecl __outdword(unsigned short,unsigned long);
void __cdecl __outword(unsigned short,unsigned short);
void __cdecl __outbyte(unsigned short,unsigned char);
unsigned int __cdecl __readeflags(void);
void __cdecl __writeeflags(unsigned int);
void __cdecl _disable(void);
#pragma intrinsic(__indword,__inword,__outdword,__outword,__outbyte,__readeflags,__writeeflags,_disable)

#define U31_MMIO_LEN 0x20000UL
#define U31_CLOSING_RX ((NDIS_STATUS)0xc001000e)
#define U31_BUGCHECK 0xe0553101UL
typedef struct _U31_BIND U31_BIND;
typedef struct _U31_FULL {
    ADAPTER Hw;
    NDIS_SPIN_LOCK HardwareLock,FilterLock;
    KEVENT StopEvent;
    PVOID ThreadObject,Filter;
    volatile BOOLEAN Removing;
    BOOLEAN Registered,CommandChanged,HardwareTouched;
    ULONG Bus,Device,Function,ConfigAddress;
    USHORT OriginalCommand;
    ULONG CapabilityCount,CapabilityOffset[2];
    USHORT CapabilityOriginal[2];
    BOOLEAN CapabilitiesChanged;
    ULONG QueueCount,QueueLen[RX_COUNT];
    UCHAR Queue[RX_COUNT][ETH_MAX_FRAME];
    ULONG LoopRead,LoopWrite,LoopCount,LoopLen[32];
    UCHAR LoopQueue[32][ETH_MAX_FRAME];
    PUCHAR CurrentRx;
    ULONG CurrentRxLen;
    U31_BIND *Bindings;
} U31_FULL;
struct _U31_BIND {
    U31_FULL *A; U31_BIND *Next;
    NDIS_HANDLE Protocol,FilterHandle;
    ULONG PacketFilter,Lookahead,McCount;
    UCHAR McList[MAX_MCAST][ETH_ALEN];
    BOOLEAN Closing,DeferredReady;
};
static NDIS_HANDLE Wrapper,Mac;
static U31_FULL *OnlyAdapter;
static const USOSNET_CHIP Chip={0x8086,0x10c9,CHIP_IGB_82576,"82576 NT31 UP",&IgbOps};

void UsZero(void *D,ULONG N) { UCHAR *p=D;while(N--)*p++=0; }
void UsCopy(void *D,const void *S,ULONG N) { UCHAR *d=D;const UCHAR *s=S;while(N--)*d++=*s++; }
BOOLEAN UsEqual(const void *A,const void *B,ULONG N) { const UCHAR *a=A,*b=B;while(N--)if(*a++!=*b++)return FALSE;return TRUE; }
void UsStall(ULONG Us) { NdisStallExecution(Us); }
static void Hex(ULONG v) { int n;for(n=28;n>=0;n-=4)__outbyte(0xe9,"0123456789ABCDEF"[(v>>n)&15]); }
void UsLog(PADAPTER A,const char *Text,ULONG V1,ULONG V2)
{
    if(!A || A->DebugPort!=0xe9)return;
    while(*Text)__outbyte(0xe9,(UCHAR)*Text++);
    __outbyte(0xe9,' ');Hex(V1);__outbyte(0xe9,' ');Hex(V2);__outbyte(0xe9,'\n');
}
static void *Alloc(ULONG n)
{
    PVOID p=NULL;NDIS_PHYSICAL_ADDRESS max;max.LowPart=0xffffffff;max.HighPart=0;
    if(NdisAllocateMemory(&p,n,0,max)!=NDIS_STATUS_SUCCESS)return NULL;
    UsZero(p,n);return p;
}
static void Free(PVOID p,ULONG n) { if(p)NdisFreeMemory(p,n,0); }
static ULONG Cfg(NDIS_HANDLE h,PWCHAR key,ULONG fallback)
{
    NDIS_STRING name;NDIS_STATUS st;PNDIS_CONFIGURATION_PARAMETER value=NULL;
    name.Buffer=key;name.Length=0;while(key[name.Length/2])name.Length+=2;name.MaximumLength=name.Length+2;
    NdisReadConfiguration(&st,&value,h,&name,NdisParameterInteger);
    return st==NDIS_STATUS_SUCCESS && value && value->ParameterType==NdisParameterInteger ? value->ParameterData.IntegerData:fallback;
}
/* The candidate is explicitly UP. IRQ-off protects CF8/CFC against preemption
 * and local interrupt users; no SMP claim is made. Never leave CF8 changed. */
static ULONG ConfigRead(U31_FULL *a,ULONG offset)
{
    ULONG flags,saved,value;
    flags=__readeflags();_disable();saved=__indword(0xcf8);
    __outdword(0xcf8,a->ConfigAddress|(offset&0xfc));value=__indword(0xcfc);
    __outdword(0xcf8,saved);__writeeflags(flags);return value;
}
static void ConfigWrite16(U31_FULL *a,ULONG offset,USHORT value)
{
    ULONG flags,saved;
    flags=__readeflags();_disable();saved=__indword(0xcf8);
    __outdword(0xcf8,a->ConfigAddress|(offset&0xfc));__outword((USHORT)(0xcfc+(offset&2)),value);
    __outdword(0xcf8,saved);__writeeflags(flags);
}
static void CommandWrite(U31_FULL *a,USHORT command) { ConfigWrite16(a,4,command); }
static BOOLEAN Capabilities(U31_FULL *a,BOOLEAN restore)
{
    ULONG p,n,v,i;UCHAR seen[64];USHORT control,mask;
    if(restore) {
        if(a->CapabilitiesChanged)for(i=0;i<a->CapabilityCount;i++)ConfigWrite16(a,a->CapabilityOffset[i],a->CapabilityOriginal[i]);
        a->CapabilitiesChanged=FALSE;return TRUE;
    }
    if(!(ConfigRead(a,4)&0x100000))return TRUE;
    UsZero(seen,sizeof(seen));p=ConfigRead(a,0x34)&0xff;
    for(n=0;p && n<48;n++) {
        if(p<0x40 || p>0xfc || (p&3) || seen[p/4])return FALSE;
        seen[p/4]=1;v=ConfigRead(a,p);
        if((v&0xff)==5 || (v&0xff)==0x11) {
            if(a->CapabilityCount>=2)return FALSE;
            i=a->CapabilityCount++;a->CapabilityOffset[i]=p+2;a->CapabilityOriginal[i]=(USHORT)(v>>16);
        }
        p=(v>>8)&0xff;
    }
    if(p)return FALSE;
    a->CapabilitiesChanged=TRUE;
    for(i=0;i<a->CapabilityCount;i++) {
        p=a->CapabilityOffset[i]-2;v=ConfigRead(a,p);mask=(v&0xff)==5?1:0x8000;
        control=(USHORT)(a->CapabilityOriginal[i]&~mask);ConfigWrite16(a,p+2,control);
        if((ConfigRead(a,p)>>16)&mask)return FALSE;
    }
    return TRUE;
}
ULONG Us31PciRead(NDIS_HANDLE h,ULONG slot,ULONG offset,PVOID buffer,ULONG length)
{
    U31_FULL *a=OnlyAdapter;ULONG value;
    if(!a || h!=a->Hw.Handle || slot!=a->Hw.PciSlot || offset>252 || !length || length>4 || (offset&3)+length>4)return 0;
    value=ConfigRead(a,offset)>>((offset&3)*8);UsCopy(buffer,&value,length);return length;
}
ULONG Us31PciWrite(NDIS_HANDLE h,ULONG slot,ULONG offset,PVOID buffer,ULONG length)
{
    U31_FULL *a=OnlyAdapter;USHORT value;
    /* The only supported device is 82576; its path never needs PM/BAR writes. */
    if(!a || h!=a->Hw.Handle || slot!=a->Hw.PciSlot || offset!=4 || length!=2)return 0;
    UsCopy(&value,buffer,2);CommandWrite(a,value);return 2;
}
static BOOLEAN ValidatePci(U31_FULL *a)
{
    ULONG id,cls,bar,high=0;
    if(KeNumberProcessors!=1 || a->Bus>255 || a->Device>31 || a->Function>7)return FALSE;
    a->ConfigAddress=0x80000000UL|(a->Bus<<16)|(a->Device<<11)|(a->Function<<8);
    id=ConfigRead(a,0);cls=ConfigRead(a,8);bar=ConfigRead(a,0x10);
    if((bar&6)==4)high=ConfigRead(a,0x14);
    if(!U31PciValid(KeNumberProcessors,a->Bus,a->Device,a->Function,id,cls,ConfigRead(a,0xc),bar,high))return FALSE;
    bar&=~15UL;
    a->Hw.VendorId=0x8086;a->Hw.DeviceId=0x10c9;a->Hw.RevId=(UCHAR)cls;
    a->Hw.MmioPa.LowPart=bar;a->Hw.MmioPa.HighPart=0;a->Hw.MmioLen=U31_MMIO_LEN;
    a->Hw.PciBus=a->Bus;a->Hw.PciSlot=a->Device|(a->Function<<5);
    a->OriginalCommand=(USHORT)ConfigRead(a,4);return TRUE;
}
static BOOLEAN DmaAlloc31(U31_FULL *a,DMAMEM *m,ULONG n,ULONG align)
{
    ULONG delta;
    m->AllocLen=n+align-1;
    NdisAllocateSharedMemory(a->Hw.Handle,m->AllocLen,FALSE,&m->AllocVa,&m->AllocPa);
    if(!m->AllocVa)return FALSE;
    if(!U31DmaValid(m->AllocPa.LowPart,m->AllocPa.HighPart,m->AllocLen))return FALSE;
    delta=(0-m->AllocPa.LowPart)&(align-1);
    m->Va=(PUCHAR)m->AllocVa+delta;m->Pa=m->AllocPa.LowPart+delta;UsZero(m->Va,n);return TRUE;
}
static void DmaFree31(U31_FULL *a,DMAMEM *m)
{
    if(m->AllocVa)NdisFreeSharedMemory(a->Hw.Handle,m->AllocLen,FALSE,m->AllocVa,m->AllocPa);
    UsZero(m,sizeof(*m));
}
static BOOLEAN Rings(U31_FULL *a)
{
    ULONG i,j;PADAPTER h=&a->Hw;
    if(!DmaAlloc31(a,&h->RxRing,RX_COUNT*16,128) || !DmaAlloc31(a,&h->TxRing,TX_COUNT*16,128))return FALSE;
    for(i=0;i<RX_COUNT/2;i++) {
        if(!DmaAlloc31(a,&h->RxPage[i],4096,4096) || !DmaAlloc31(a,&h->TxPage[i],4096,4096))return FALSE;
        for(j=0;j<2;j++) {
            h->RxBuf[i*2+j]=h->RxPage[i].Va+j*BUF_SIZE;h->RxBufPa[i*2+j]=h->RxPage[i].Pa+j*BUF_SIZE;
            h->TxBuf[i*2+j]=h->TxPage[i].Va+j*BUF_SIZE;h->TxBufPa[i*2+j]=h->TxPage[i].Pa+j*BUF_SIZE;
        }
    }
    return TRUE;
}
/* Backend callbacks execute under HardwareLock. Copy into owned bounded
 * storage; never invoke a protocol while that lock is held. */
void UsIndicateRx(PADAPTER h,PUCHAR frame,ULONG len,ULONG status)
{
    U31_FULL *a=CONTAINING_RECORD(h,U31_FULL,Hw);ULONG i=a->QueueCount;
    UNREFERENCED_PARAMETER(status);
    if(len<ETH_HDR || len>ETH_MAX_FRAME || i>=RX_COUNT){h->RxNoBuf++;return;}
    UsCopy(a->Queue[i],frame,len);a->QueueLen[i]=len;a->QueueCount++;h->RxOk++;
}
void UsIndicateRxComplete(PADAPTER h) { UNREFERENCED_PARAMETER(h); }
void UsRxDropped(PADAPTER h,PUCHAR frame,ULONG len,ULONG status)
{ UNREFERENCED_PARAMETER(h);UNREFERENCED_PARAMETER(frame);UNREFERENCED_PARAMETER(len);UNREFERENCED_PARAMETER(status); }

/* Address-change has seven args; FilterChange has five. The hardware stays
 * in a superset (promiscuous) mode. The original NDIS Ethernet filter owns
 * per-binding destination/multicast policy and its receive references. */
static NDIS_STATUS __stdcall AddressChange(UINT oldN,PUCHAR oldA,UINT newN,PUCHAR newA,NDIS_HANDLE binding,PNDIS_REQUEST req,BOOLEAN set)
{
    UNREFERENCED_PARAMETER(oldN);UNREFERENCED_PARAMETER(oldA);UNREFERENCED_PARAMETER(newN);UNREFERENCED_PARAMETER(newA);
    UNREFERENCED_PARAMETER(binding);UNREFERENCED_PARAMETER(req);UNREFERENCED_PARAMETER(set);return NDIS_STATUS_SUCCESS;
}
static NDIS_STATUS __stdcall FilterChange(UINT oldF,UINT newF,NDIS_HANDLE binding,PNDIS_REQUEST req,BOOLEAN set)
{
    UNREFERENCED_PARAMETER(oldF);UNREFERENCED_PARAMETER(newF);UNREFERENCED_PARAMETER(binding);
    UNREFERENCED_PARAMETER(req);UNREFERENCED_PARAMETER(set);return NDIS_STATUS_SUCCESS;
}
static VOID __stdcall DeferredClose(NDIS_HANDLE context)
{
    U31_BIND *b=context;
    /* Called under FilterLock after the filter's final receive ref. Complete
     * and free only after the indication/filter routine itself has returned. */
    b->DeferredReady=TRUE;
}
static void Unlink(U31_FULL *a,U31_BIND *b)
{
    U31_BIND **p=&a->Bindings;while(*p && *p!=b)p=&(*p)->Next;if(*p)*p=b->Next;
}
static void CompleteCloses(U31_FULL *a)
{
    U31_BIND *b,*ready;
    for(;;) {
        ready=NULL;NdisAcquireSpinLock(&a->FilterLock);
        for(b=a->Bindings;b;b=b->Next)if(b->Closing && b->DeferredReady){ready=b;Unlink(a,b);break;}
        NdisReleaseSpinLock(&a->FilterLock);if(!ready)break;
        NdisCompleteCloseAdapter(ready->Protocol,NDIS_STATUS_SUCCESS);Free(ready,sizeof(*ready));
    }
}
static VOID Worker(PVOID context)
{
    U31_FULL *a=context;LARGE_INTEGER interval;KIRQL old;ULONG i;
    interval.QuadPart=-200000; /* relative20ms; no driver-owned timer/DPC */
    for(;;) {
        if(KeWaitForSingleObject(&a->StopEvent,Executive,KernelMode,FALSE,&interval)==STATUS_SUCCESS)break;
        KeRaiseIrql(DISPATCH_LEVEL,&old);
        NdisAcquireSpinLock(&a->HardwareLock);a->QueueCount=0;
        if(!a->Removing && a->Hw.Started){
            while(a->LoopCount && a->QueueCount<RX_COUNT) {
                UsIndicateRx(&a->Hw,a->LoopQueue[a->LoopRead],a->LoopLen[a->LoopRead],0);
                a->LoopRead=(a->LoopRead+1)%32;a->LoopCount--;
            }
            IgbOps.TxReclaim(&a->Hw);IgbOps.RxPoll(&a->Hw);
        }
        NdisReleaseSpinLock(&a->HardwareLock);
        for(i=0;i<a->QueueCount && !a->Removing;i++) {
            a->CurrentRx=a->Queue[i];a->CurrentRxLen=a->QueueLen[i];
            EthFilterIndicateReceive(a->Filter,a,(PCHAR)a->CurrentRx,a->CurrentRx,ETH_HDR,
                a->CurrentRx+ETH_HDR,a->CurrentRxLen-ETH_HDR,a->CurrentRxLen-ETH_HDR);
            a->CurrentRx=NULL;a->CurrentRxLen=0;
        }
        if(a->QueueCount && !a->Removing)EthFilterIndicateReceiveComplete(a->Filter);
        CompleteCloses(a);KeLowerIrql(old);
    }
    PsTerminateSystemThread(STATUS_SUCCESS);
}
static NTSTATUS StartWorker(U31_FULL *a)
{
    HANDLE handle=NULL;NTSTATUS st;
    st=PsCreateSystemThread(&handle,SYNCHRONIZE,NULL,NULL,NULL,Worker,a);
    if(!NT_SUCCESS(st))return st;
    st=ObReferenceObjectByHandle(handle,0,NULL,KernelMode,&a->ThreadObject,NULL);
    if(!NT_SUCCESS(st)) {
        KeSetEvent(&a->StopEvent,0,FALSE);
        /* Original NT31 NtWait exists, ZwWait does not. Handle has the
         * SYNCHRONIZE access required even when PreviousMode is UserMode. */
        if(NtWaitForSingleObject(handle,FALSE,NULL)!=STATUS_SUCCESS)
            KeBugCheckEx(U31_BUGCHECK,1,(ULONG)st,0,0); /* never free live worker */
    }
    ZwClose(handle);return st;
}
static void JoinWorker(U31_FULL *a)
{
    a->Removing=TRUE;KeSetEvent(&a->StopEvent,0,FALSE);
    if(a->ThreadObject) {
        KeWaitForSingleObject(a->ThreadObject,Executive,KernelMode,FALSE,NULL);
        ObDereferenceObject(a->ThreadObject);a->ThreadObject=NULL;
    }
}
static void Cleanup(U31_FULL *a)
{
    ULONG i;NDIS_STATUS release;
    if(KeGetCurrentIrql()!=PASSIVE_LEVEL)KeBugCheckEx(U31_BUGCHECK,2,KeGetCurrentIrql(),0,0);
    JoinWorker(a);
    if(a->HardwareTouched)IgbOps.Stop(&a->Hw);
    if(a->CommandChanged) {
        CommandWrite(a,(USHORT)(a->OriginalCommand&~4));
        if(ConfigRead(a,4)&4)KeBugCheckEx(U31_BUGCHECK,3,ConfigRead(a,4),0,0);
        if(a->HardwareTouched) {
            WR32(&a->Hw,0,RD32(&a->Hw,0)|4); /* GIO_MASTER_DISABLE after reset */
            for(i=0;i<1000 && (RD32(&a->Hw,8)&(1UL<<19));i++)UsStall(1000);
            if(RD32(&a->Hw,8)&(1UL<<19))KeBugCheckEx(U31_BUGCHECK,4,RD32(&a->Hw,8),0,0);
        }
        /* Bus master disabled before any backing DMA allocation is freed. */
    }
    CompleteCloses(a);
    for(i=0;i<RX_COUNT/2;i++){DmaFree31(a,&a->Hw.RxPage[i]);DmaFree31(a,&a->Hw.TxPage[i]);}
    DmaFree31(a,&a->Hw.RxRing);DmaFree31(a,&a->Hw.TxRing);
    if(a->Hw.Mmio){MmUnmapIoSpace((PVOID)a->Hw.Mmio,a->Hw.MmioLen);a->Hw.Mmio=NULL;}
    Capabilities(a,TRUE);
    if(a->CommandChanged){CommandWrite(a,a->OriginalCommand);a->CommandChanged=FALSE;}
    if(a->Registered) {
        /* MapIoSpace retains its new list even on conflict/failure. Release
         * the wrapper's actual claim on every registered unwind path. */
        release=NdisReleaseAdapterResources(a->Hw.Handle);UsLog(&a->Hw,"US31 release",release,0);
        NdisDeregisterAdapter(a->Hw.Handle);a->Registered=FALSE;
    }
    if(a->Filter){EthDeleteFilter(a->Filter);a->Filter=NULL;}
    while(a->Bindings){U31_BIND *b=a->Bindings;a->Bindings=b->Next;Free(b,sizeof(*b));}
    OnlyAdapter=NULL;Free(a,sizeof(*a));
}
static int __cdecl NoteBinding(void *filter,void *context)
{
    U31_BIND *b=context;return EthNoteFilterOpenAdapter(filter,b,b->Protocol,&b->FilterHandle);
}
static NDIS_STATUS __stdcall Open(PNDIS_STATUS error,NDIS_HANDLE *out,PUINT selected,PNDIS_MEDIUM media,UINT count,NDIS_HANDLE protocol,NDIS_HANDLE context,UINT options,PSTRING address)
{
    U31_FULL *a=context;U31_BIND *b;UINT i;
    UNREFERENCED_PARAMETER(options);UNREFERENCED_PARAMETER(address);*error=NDIS_STATUS_SUCCESS;*selected=(UINT)-1;*out=NULL;
    for(i=0;i<count;i++)if(media[i]==NdisMedium802_3){*selected=i;break;}
    if(*selected==(UINT)-1)return NDIS_STATUS_UNSUPPORTED_MEDIA;
    b=Alloc(sizeof(*b));if(!b)return NDIS_STATUS_RESOURCES;b->A=a;b->Protocol=protocol;b->Lookahead=ETH_MAX_DATA;
    NdisAcquireSpinLock(&a->FilterLock);
    if(!U31NoteOpenIfReady(a->Removing,a->Filter,a->Hw.Started,NoteBinding,b)) {
        NdisReleaseSpinLock(&a->FilterLock);Free(b,sizeof(*b));return NDIS_STATUS_RESOURCES;
    }
    b->Next=a->Bindings;a->Bindings=b;*out=b;NdisReleaseSpinLock(&a->FilterLock);return NDIS_STATUS_SUCCESS;
}
static NDIS_STATUS __stdcall Close(NDIS_HANDLE context)
{
    U31_BIND *b=context;U31_FULL *a=b->A;NDIS_STATUS st;
    NdisAcquireSpinLock(&a->FilterLock);
    if(b->Closing){NdisReleaseSpinLock(&a->FilterLock);return NDIS_STATUS_CLOSING;}
    b->Closing=TRUE;st=EthDeleteFilterOpenAdapter(a->Filter,b->FilterHandle,NULL);
    if(st==NDIS_STATUS_SUCCESS)Unlink(a,b);
    else if(st!=U31_CLOSING_RX){b->Closing=FALSE;NdisReleaseSpinLock(&a->FilterLock);return st;}
    NdisReleaseSpinLock(&a->FilterLock);
    if(st==NDIS_STATUS_SUCCESS){Free(b,sizeof(*b));return st;}
    return NDIS_STATUS_PENDING;
}
static NDIS_STATUS __stdcall Send(NDIS_HANDLE context,PNDIS_PACKET packet)
{
    U31_BIND *b=context;U31_FULL *a=b->A;PADAPTER h=&a->Hw;PNDIS_BUFFER p;PVOID va;UINT n;ULONG total=0,buffers=0;NDIS_STATUS st=NDIS_STATUS_SUCCESS;
    NdisAcquireSpinLock(&a->HardwareLock);
    if(a->Removing || !h->Started || b->Closing){st=NDIS_STATUS_CLOSING;goto done;}
    IgbOps.TxReclaim(h);if(h->TxBusy>=TX_COUNT-1){h->TxFull++;st=NDIS_STATUS_RESOURCES;goto done;}
    for(p=packet->Private.Head;p;p=p->Next) {
        if(++buffers>256){st=NDIS_STATUS_INVALID_PACKET;goto done;}
        va=NULL;n=0;NdisQueryBuffer(p,&va,&n);
        if(n>ETH_MAX_FRAME-total || (n && !va)){st=NDIS_STATUS_INVALID_PACKET;goto done;}
        UsCopy(h->TxBuf[h->TxNext]+total,va,n);total+=n;
    }
    if(total<ETH_HDR){st=NDIS_STATUS_INVALID_PACKET;goto done;}
    if(U31NeedsLoopback(h->TxBuf[h->TxNext],h->CurAddr) && a->LoopCount>=32){st=NDIS_STATUS_RESOURCES;goto done;}
    if(total<60){UsZero(h->TxBuf[h->TxNext]+total,60-total);total=60;}
    if(U31NeedsLoopback(h->TxBuf[h->TxNext],h->CurAddr)) {
        UsCopy(a->LoopQueue[a->LoopWrite],h->TxBuf[h->TxNext],total);a->LoopLen[a->LoopWrite]=total;
        a->LoopWrite=(a->LoopWrite+1)%32;a->LoopCount++;
    }
    IgbOps.Transmit(h,total);h->TxOk++;
done:NdisReleaseSpinLock(&a->HardwareLock);return st;
}
static NDIS_STATUS __stdcall Transfer(NDIS_HANDLE context,NDIS_HANDLE receive,UINT offset,UINT wanted,PNDIS_PACKET packet,PUINT copied)
{
    U31_BIND *b=context;U31_FULL *a=b->A;PNDIS_BUFFER p;PVOID va;UINT n,take;ULONG done=0,buffers=0;
    *copied=0;if(receive!=a || !a->CurrentRx || a->CurrentRxLen<ETH_HDR)return NDIS_STATUS_FAILURE;
    if(offset>a->CurrentRxLen-ETH_HDR)return NDIS_STATUS_SUCCESS;
    if(wanted>a->CurrentRxLen-ETH_HDR-offset)wanted=a->CurrentRxLen-ETH_HDR-offset;
    for(p=packet->Private.Head;p && done<wanted;p=p->Next) {
        if(++buffers>256)return NDIS_STATUS_INVALID_PACKET;
        va=NULL;n=0;NdisQueryBuffer(p,&va,&n);if(n && !va)return NDIS_STATUS_INVALID_PACKET;
        take=wanted-done;if(take>n)take=n;UsCopy(va,a->CurrentRx+ETH_HDR+offset+done,take);done+=take;
    }
    *copied=done;return NDIS_STATUS_SUCCESS;
}
static const NDIS_OID Oids[]={OID_GEN_SUPPORTED_LIST,OID_GEN_HARDWARE_STATUS,OID_GEN_MEDIA_SUPPORTED,OID_GEN_MEDIA_IN_USE,
 OID_GEN_MAXIMUM_LOOKAHEAD,OID_GEN_MAXIMUM_FRAME_SIZE,OID_GEN_MAXIMUM_TOTAL_SIZE,OID_GEN_LINK_SPEED,
 OID_GEN_TRANSMIT_BUFFER_SPACE,OID_GEN_RECEIVE_BUFFER_SPACE,OID_GEN_TRANSMIT_BLOCK_SIZE,OID_GEN_RECEIVE_BLOCK_SIZE,
 OID_GEN_VENDOR_ID,OID_GEN_VENDOR_DESCRIPTION,OID_GEN_CURRENT_PACKET_FILTER,OID_GEN_CURRENT_LOOKAHEAD,OID_GEN_DRIVER_VERSION,
 OID_GEN_MAC_OPTIONS,OID_GEN_PROTOCOL_OPTIONS,OID_GEN_XMIT_OK,OID_GEN_RCV_OK,OID_GEN_XMIT_ERROR,OID_GEN_RCV_ERROR,OID_GEN_RCV_NO_BUFFER,
 OID_802_3_PERMANENT_ADDRESS,OID_802_3_CURRENT_ADDRESS,OID_802_3_MULTICAST_LIST,OID_802_3_MAXIMUM_LIST_SIZE,
 OID_802_3_RCV_ERROR_ALIGNMENT,OID_802_3_XMIT_ONE_COLLISION,OID_802_3_XMIT_MORE_COLLISIONS};
static NDIS_STATUS Query(U31_FULL *a,U31_BIND *b,PNDIS_REQUEST r)
{
    ULONG v=0,n=4;USHORT version=0x300;PVOID src=&v;NDIS_OID oid=r->DATA.QUERY_INFORMATION.Oid;
    ULONG len=r->DATA.QUERY_INFORMATION.InformationBufferLength;PVOID dst=r->DATA.QUERY_INFORMATION.InformationBuffer;
    r->DATA.QUERY_INFORMATION.BytesWritten=0;r->DATA.QUERY_INFORMATION.BytesNeeded=0;
    switch(oid) {
    case OID_GEN_SUPPORTED_LIST:src=(PVOID)Oids;n=sizeof(Oids);break;
    case OID_GEN_HARDWARE_STATUS:v=NdisHardwareStatusReady;break;
    case OID_GEN_MEDIA_SUPPORTED:case OID_GEN_MEDIA_IN_USE:v=NdisMedium802_3;break;
    case OID_GEN_CURRENT_LOOKAHEAD:v=b?b->Lookahead:ETH_MAX_DATA;break;
    case OID_GEN_MAXIMUM_LOOKAHEAD:case OID_GEN_MAXIMUM_FRAME_SIZE:v=ETH_MAX_DATA;break;
    case OID_GEN_MAXIMUM_TOTAL_SIZE:case OID_GEN_TRANSMIT_BLOCK_SIZE:case OID_GEN_RECEIVE_BLOCK_SIZE:v=ETH_MAX_FRAME;break;
    case OID_GEN_LINK_SPEED:v=10000000;break;
    case OID_GEN_TRANSMIT_BUFFER_SPACE:v=TX_COUNT*BUF_SIZE;break;
    case OID_GEN_RECEIVE_BUFFER_SPACE:v=RX_COUNT*BUF_SIZE;break;
    case OID_GEN_VENDOR_ID:v=a->Hw.PermAddr[0]|((ULONG)a->Hw.PermAddr[1]<<8)|((ULONG)a->Hw.PermAddr[2]<<16);break;
    case OID_GEN_VENDOR_DESCRIPTION:src="USOS NT31 Intel82576 UP";n=23;break;
    case OID_GEN_CURRENT_PACKET_FILTER:v=b?b->PacketFilter:0;break;
    case OID_GEN_PROTOCOL_OPTIONS:v=0;break;
    case OID_GEN_DRIVER_VERSION:src=&version;n=2;break;
    case OID_GEN_MAC_OPTIONS:v=NDIS_MAC_OPTION_COPY_LOOKAHEAD_DATA|NDIS_MAC_OPTION_TRANSFERS_NOT_PEND;break;
    case OID_GEN_XMIT_OK:v=a->Hw.TxOk;break;
    case OID_GEN_RCV_OK:v=a->Hw.RxOk;break;
    case OID_GEN_XMIT_ERROR:v=a->Hw.TxErr;break;
    case OID_GEN_RCV_ERROR:v=a->Hw.RxErr;break;
    case OID_GEN_RCV_NO_BUFFER:v=a->Hw.RxNoBuf;break;
    case OID_802_3_PERMANENT_ADDRESS:src=a->Hw.PermAddr;n=6;break;
    case OID_802_3_CURRENT_ADDRESS:src=a->Hw.CurAddr;n=6;break;
    case OID_802_3_MULTICAST_LIST:src=b?(PVOID)b->McList:NULL;n=b?b->McCount*6:0;break;
    case OID_802_3_MAXIMUM_LIST_SIZE:v=MAX_MCAST;break;
    case OID_802_3_RCV_ERROR_ALIGNMENT:case OID_802_3_XMIT_ONE_COLLISION:case OID_802_3_XMIT_MORE_COLLISIONS:break;
    default:return NDIS_STATUS_NOT_SUPPORTED;
    }
    if(len<n){r->DATA.QUERY_INFORMATION.BytesNeeded=n;return NDIS_STATUS_INVALID_LENGTH;}
    UsCopy(dst,src,n);r->DATA.QUERY_INFORMATION.BytesWritten=n;return NDIS_STATUS_SUCCESS;
}
static NDIS_STATUS __stdcall Request(NDIS_HANDLE context,PNDIS_REQUEST r)
{
    U31_BIND *b=context;U31_FULL *a=b->A;NDIS_STATUS st;ULONG v,n;PVOID buf;
    NdisAcquireSpinLock(&a->FilterLock);
    if(b->Closing || a->Removing){st=NDIS_STATUS_CLOSING;goto done;}
    if(r->RequestType==NdisRequestQueryInformation){st=Query(a,b,r);goto done;}
    if(r->RequestType!=NdisRequestSetInformation){st=NDIS_STATUS_NOT_SUPPORTED;goto done;}
    n=r->DATA.SET_INFORMATION.InformationBufferLength;buf=r->DATA.SET_INFORMATION.InformationBuffer;
    r->DATA.SET_INFORMATION.BytesRead=0;r->DATA.SET_INFORMATION.BytesNeeded=0;st=NDIS_STATUS_SUCCESS;
    switch(r->DATA.SET_INFORMATION.Oid) {
    case OID_GEN_CURRENT_PACKET_FILTER:
        if(n!=4){r->DATA.SET_INFORMATION.BytesNeeded=4;st=NDIS_STATUS_INVALID_LENGTH;break;}
        UsCopy(&v,buf,4);
        if(v&~(NDIS_PACKET_TYPE_DIRECTED|NDIS_PACKET_TYPE_MULTICAST|NDIS_PACKET_TYPE_ALL_MULTICAST|NDIS_PACKET_TYPE_BROADCAST|NDIS_PACKET_TYPE_PROMISCUOUS)){st=NDIS_STATUS_NOT_SUPPORTED;break;}
        st=EthFilterAdjust(a->Filter,b->FilterHandle,r,v,TRUE);if(st==NDIS_STATUS_SUCCESS)b->PacketFilter=v;break;
    case OID_GEN_CURRENT_LOOKAHEAD:
        if(n!=4){r->DATA.SET_INFORMATION.BytesNeeded=4;st=NDIS_STATUS_INVALID_LENGTH;break;}
        UsCopy(&v,buf,4);if(v>ETH_MAX_DATA){st=NDIS_STATUS_INVALID_LENGTH;break;}b->Lookahead=v;break;
    case OID_802_3_MULTICAST_LIST:
        if(n%6 || n>MAX_MCAST*6){st=NDIS_STATUS_INVALID_LENGTH;break;}
        st=EthChangeFilterAddresses(a->Filter,b->FilterHandle,r,n/6,buf,TRUE);
        if(st==NDIS_STATUS_SUCCESS){b->McCount=n/6;UsCopy(b->McList,buf,n);}break;
    case OID_GEN_PROTOCOL_OPTIONS:
        if(n!=4){r->DATA.SET_INFORMATION.BytesNeeded=4;st=NDIS_STATUS_INVALID_LENGTH;}break;
    default:st=NDIS_STATUS_NOT_SUPPORTED;
    }
    if(st==NDIS_STATUS_SUCCESS)r->DATA.SET_INFORMATION.BytesRead=n;
done:NdisReleaseSpinLock(&a->FilterLock);return st;
}
static NDIS_STATUS __stdcall GlobalQuery(NDIS_HANDLE context,PNDIS_REQUEST r)
{
    U31_FULL *a=context;NDIS_STATUS st;NdisAcquireSpinLock(&a->FilterLock);
    st=r->RequestType==NdisRequestQueryStatistics?Query(a,NULL,r):NDIS_STATUS_NOT_SUPPORTED;
    NdisReleaseSpinLock(&a->FilterLock);return st;
}
static NDIS_STATUS __stdcall Reset(NDIS_HANDLE context)
{
    /* This minimal full-MAC reports the real unsupported-reset status;
     * there is no invented successful reset or missing completion stub. */
    U31_BIND *b=context;U31_FULL *a=b->A;
    if(a->Removing)return NDIS_STATUS_CLOSING;
    return NDIS_STATUS_NOT_RESETTABLE;
}
static NDIS_STATUS __stdcall Add(NDIS_HANDLE macContext,NDIS_HANDLE configuration,PNDIS_STRING name)
{
    U31_FULL *a;NDIS_HANDLE cfg=NULL;NDIS_STATUS st;U31_INFO info;USHORT command;
    UNREFERENCED_PARAMETER(macContext);
    if(KeNumberProcessors!=1 || OnlyAdapter || KeGetCurrentIrql()!=PASSIVE_LEVEL)return NDIS_STATUS_NOT_SUPPORTED;
    a=Alloc(sizeof(*a));if(!a)return NDIS_STATUS_RESOURCES;
    a->Hw.Chip=&Chip;a->Hw.DebugPort=0xe9;
    NdisAllocateSpinLock(&a->HardwareLock);NdisAllocateSpinLock(&a->FilterLock);KeInitializeEvent(&a->StopEvent,NotificationEvent,FALSE);
    NdisOpenConfiguration(&st,&cfg,configuration);if(st!=NDIS_STATUS_SUCCESS)goto failed;
    a->Bus=Cfg(cfg,L"PciBus",0xffffffff);a->Device=Cfg(cfg,L"PciDevice",0xffffffff);a->Function=Cfg(cfg,L"PciFunction",0xffffffff);
    a->Hw.DebugPort=Cfg(cfg,L"DebugPort",0);NdisCloseConfiguration(cfg);cfg=NULL;
    if(a->Hw.DebugPort!=0 && a->Hw.DebugPort!=0xe9){st=NDIS_STATUS_NOT_SUPPORTED;goto failed;}
    if(!ValidatePci(a)){st=NDIS_STATUS_ADAPTER_NOT_FOUND;goto failed;}
    UsLog(&a->Hw,"US31 pci",a->ConfigAddress,a->Hw.MmioPa.LowPart);
    UsZero(&info,sizeof(info));info.Master=TRUE;info.InterfaceType=5;info.MapRegisters=1;info.MaximumMapping=4096;
    st=NdisRegisterAdapter(&a->Hw.Handle,Mac,a,configuration,name,&info);UsLog(&a->Hw,"US31 register",st,0);
    if(st!=NDIS_STATUS_SUCCESS)goto failed;a->Registered=TRUE;OnlyAdapter=a;
    NdisMapIoSpace(&st,(PVOID *)&a->Hw.Mmio,a->Hw.Handle,a->Hw.MmioPa,a->Hw.MmioLen);UsLog(&a->Hw,"US31 map",st,(ULONG)a->Hw.Mmio);
    if(st!=NDIS_STATUS_SUCCESS || !a->Hw.Mmio)goto failed;
    /* Enable MMIO with DMA still disabled, then reset before allocating or
     * handing any buffer to the controller. Writes preserve PCI Status. */
    if(!Capabilities(a,FALSE)){st=NDIS_STATUS_HARD_ERRORS;goto failed;}
    command=(USHORT)((a->OriginalCommand|2|0x400)&~4);CommandWrite(a,command);a->CommandChanged=TRUE;
    if(((USHORT)ConfigRead(a,4)&6)!=2){st=NDIS_STATUS_HARD_ERRORS;goto failed;}
    a->HardwareTouched=TRUE;st=IgbOps.Reset(&a->Hw);if(st!=NDIS_STATUS_SUCCESS)goto failed;
    if(!IgbOps.ReadMac(&a->Hw,a->Hw.PermAddr) || a->Hw.MacSource==6){st=NDIS_STATUS_INVALID_ADDRESS;goto failed;}
    UsCopy(a->Hw.CurAddr,a->Hw.PermAddr,6);IgbOps.SetMac(&a->Hw,a->Hw.CurAddr);
    if(!Rings(a)){st=NDIS_STATUS_RESOURCES;goto failed;}
    if(!EthCreateFilter(MAX_MCAST,AddressChange,FilterChange,DeferredClose,a->Hw.CurAddr,&a->FilterLock,&a->Filter)){st=NDIS_STATUS_RESOURCES;goto failed;}
    CommandWrite(a,(USHORT)(a->OriginalCommand|6|0x400));
    if(((USHORT)ConfigRead(a,4)&6)!=6){st=NDIS_STATUS_HARD_ERRORS;goto failed;}
    IgbOps.PhyInit(&a->Hw);IgbOps.Start(&a->Hw);
    a->Hw.PacketFilter=NDIS_PACKET_TYPE_PROMISCUOUS|NDIS_PACKET_TYPE_BROADCAST|NDIS_PACKET_TYPE_ALL_MULTICAST;IgbOps.SetFilter(&a->Hw);IgbOps.IrqDisable(&a->Hw);a->Hw.Started=TRUE;
    st=StartWorker(a);if(!NT_SUCCESS(st))goto failed;
    UsLog(&a->Hw,"US31 started20ms",a->Hw.RxRing.Pa,a->Hw.TxRing.Pa);return NDIS_STATUS_SUCCESS;
failed:
    if(cfg)NdisCloseConfiguration(cfg);UsLog(&a->Hw,"US31 init-failed",st,0);Cleanup(a);return st;
}
static VOID __stdcall Remove(NDIS_HANDLE context) { Cleanup(context); }
static VOID __stdcall Unload(NDIS_HANDLE context)
{
    NDIS_STATUS st;UNREFERENCED_PARAMETER(context);NdisDeregisterMac(&st,Mac);NdisTerminateWrapper(Wrapper,NULL);
}
NTSTATUS DriverEntry(PDRIVER_OBJECT driver,PUNICODE_STRING path)
{
    U31_MAC chars;NDIS_STATUS st;NDIS_STRING name=NDIS_STRING_CONST("USOSNET31");
    if(KeNumberProcessors!=1)return STATUS_NOT_SUPPORTED;
    UsZero(&chars,sizeof(chars));chars.Major=3;chars.Minor=0;chars.Open=Open;chars.Close=Close;chars.Send=Send;chars.Transfer=Transfer;
    chars.Reset=Reset;chars.Request=Request;chars.GlobalQuery=GlobalQuery;chars.Unload=Unload;chars.Add=Add;chars.Remove=Remove;chars.Name=name;
    NdisInitializeWrapper(&Wrapper,driver,path,NULL);if(!Wrapper)return STATUS_INSUFFICIENT_RESOURCES;
    NdisRegisterMac(&st,&Mac,&Mac,Wrapper,&chars,sizeof(chars));
    if(st!=NDIS_STATUS_SUCCESS)NdisTerminateWrapper(Wrapper,NULL);return st;
}
