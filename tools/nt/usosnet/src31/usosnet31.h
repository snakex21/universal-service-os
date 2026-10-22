/* Own NT3.1 full-MAC ABI. Original-media evidence: lifecycle-04/05/06.
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef USOSNET31_H
#define USOSNET31_H
#include "usosnet.h"

/* NT31 exports the stdcall HAL forms, not modern Kf* macros. */
#undef KeRaiseIrql
#undef KeLowerIrql
__declspec(dllimport) VOID __stdcall KeRaiseIrql(KIRQL, PKIRQL);
__declspec(dllimport) VOID __stdcall KeLowerIrql(KIRQL);
#undef NdisAllocateSpinLock
#undef NdisAcquireSpinLock
#undef NdisReleaseSpinLock
#undef NdisQueryBuffer
#undef KeAcquireSpinLock
#undef KeReleaseSpinLock
#undef ObDereferenceObject
__declspec(dllimport) VOID __stdcall KeAcquireSpinLock(PKSPIN_LOCK,PKIRQL);
__declspec(dllimport) VOID __stdcall KeReleaseSpinLock(PKSPIN_LOCK,KIRQL);
NTSYSAPI VOID NTAPI ObDereferenceObject(PVOID);
#define NdisAllocateSpinLock(L) KeInitializeSpinLock(&(L)->SpinLock)
#define NdisAcquireSpinLock(L) KeAcquireSpinLock(&(L)->SpinLock,&(L)->OldIrql)
#define NdisReleaseSpinLock(L) KeReleaseSpinLock(&(L)->SpinLock,(L)->OldIrql)
EXPORT VOID NdisQueryBuffer(PNDIS_BUFFER,PVOID *,PUINT);

typedef NDIS_STATUS (__stdcall *U31_OPEN)(PNDIS_STATUS,NDIS_HANDLE *,PUINT,
    PNDIS_MEDIUM,UINT,NDIS_HANDLE,NDIS_HANDLE,UINT,PSTRING);
typedef NDIS_STATUS (__stdcall *U31_CLOSE)(NDIS_HANDLE);
typedef NDIS_STATUS (__stdcall *U31_SEND)(NDIS_HANDLE,PNDIS_PACKET);
typedef NDIS_STATUS (__stdcall *U31_TRANSFER)(NDIS_HANDLE,NDIS_HANDLE,UINT,UINT,PNDIS_PACKET,PUINT);
typedef NDIS_STATUS (__stdcall *U31_RESET)(NDIS_HANDLE);
typedef NDIS_STATUS (__stdcall *U31_REQUEST)(NDIS_HANDLE,PNDIS_REQUEST);
typedef VOID (__stdcall *U31_UNLOAD)(NDIS_HANDLE);
typedef NDIS_STATUS (__stdcall *U31_ADD)(NDIS_HANDLE,NDIS_HANDLE,PNDIS_STRING);
typedef VOID (__stdcall *U31_REMOVE)(NDIS_HANDLE);
typedef struct _U31_MAC {
    UCHAR Major,Minor; USHORT Filler; UINT Reserved;
    U31_OPEN Open; U31_CLOSE Close; U31_SEND Send; U31_TRANSFER Transfer;
    U31_RESET Reset; U31_REQUEST Request,GlobalQuery; U31_UNLOAD Unload;
    U31_ADD Add; U31_REMOVE Remove; NDIS_STRING Name;
} U31_MAC;
typedef struct _U31_INFO {
    ULONG DmaChannel; BOOLEAN Master,Dma32; USHORT Padding;
    ULONG Reserved8,InterfaceType,MapRegisters,MaximumMapping,PortCount;
} U31_INFO;
C_ASSERT(sizeof(U31_MAC)==0x38);
C_ASSERT(sizeof(U31_INFO)==0x1c);
C_ASSERT(FIELD_OFFSET(NDIS_PACKET,Private.Head)==8);
C_ASSERT(FIELD_OFFSET(NDIS_REQUEST,RequestType)==0x10);
C_ASSERT(FIELD_OFFSET(NDIS_REQUEST,DATA.QUERY_INFORMATION.Oid)==0x14);
C_ASSERT(FIELD_OFFSET(NDIS_REQUEST,DATA.QUERY_INFORMATION.BytesWritten)==0x20);

/* Original NT31 callee2567..2633 and NE2000 caller510..524: wrapper is
 * argument3, MacMacContext argument4. Equal handle types do not prove order. */
EXPORT VOID NdisRegisterMac(PNDIS_STATUS Status,NDIS_HANDLE *MacOut,
    NDIS_HANDLE WrapperHandle,NDIS_HANDLE MacMacContext,U31_MAC *Characteristics,UINT Length);
EXPORT VOID NdisDeregisterMac(PNDIS_STATUS,NDIS_HANDLE);
EXPORT NDIS_STATUS NdisRegisterAdapter(NDIS_HANDLE *,NDIS_HANDLE,NDIS_HANDLE,NDIS_HANDLE,PNDIS_STRING,U31_INFO *);
EXPORT NDIS_STATUS NdisDeregisterAdapter(NDIS_HANDLE);
EXPORT NDIS_STATUS NdisReleaseAdapterResources(NDIS_HANDLE);
EXPORT VOID NdisMapIoSpace(PNDIS_STATUS,PVOID *,NDIS_HANDLE,NDIS_PHYSICAL_ADDRESS,UINT);
EXPORT VOID NdisAllocateSharedMemory(NDIS_HANDLE,ULONG,BOOLEAN,PVOID *,PNDIS_PHYSICAL_ADDRESS);
EXPORT VOID NdisFreeSharedMemory(NDIS_HANDLE,ULONG,BOOLEAN,PVOID,NDIS_PHYSICAL_ADDRESS);
EXPORT BOOLEAN EthCreateFilter(UINT,PVOID,PVOID,PVOID,PUCHAR,PNDIS_SPIN_LOCK,PVOID *);
EXPORT VOID EthDeleteFilter(PVOID);
EXPORT BOOLEAN EthNoteFilterOpenAdapter(PVOID,NDIS_HANDLE,NDIS_HANDLE,NDIS_HANDLE *);
EXPORT NDIS_STATUS EthDeleteFilterOpenAdapter(PVOID,NDIS_HANDLE,PNDIS_REQUEST);
EXPORT NDIS_STATUS EthFilterAdjust(PVOID,NDIS_HANDLE,PNDIS_REQUEST,UINT,BOOLEAN);
EXPORT NDIS_STATUS EthChangeFilterAddresses(PVOID,NDIS_HANDLE,PNDIS_REQUEST,UINT,PUCHAR,BOOLEAN);
EXPORT VOID EthFilterIndicateReceive(PVOID,NDIS_HANDLE,PCHAR,PVOID,UINT,PVOID,UINT,UINT);
EXPORT VOID EthFilterIndicateReceiveComplete(PVOID);
EXPORT VOID NdisCompleteCloseAdapter(NDIS_HANDLE,NDIS_STATUS);
NTSYSAPI NTSTATUS NTAPI NtWaitForSingleObject(HANDLE,BOOLEAN,PLARGE_INTEGER);

/* Only the 82576 branch of the unchanged own backend is supported. Its
 * optional I210 PCI helpers are routed to our actual bounded PCI mechanism,
 * not to nonexistent NT31 exports. No miniport-handle aliases. */
ULONG Us31PciRead(NDIS_HANDLE,ULONG,ULONG,PVOID,ULONG);
ULONG Us31PciWrite(NDIS_HANDLE,ULONG,ULONG,PVOID,ULONG);
#endif
