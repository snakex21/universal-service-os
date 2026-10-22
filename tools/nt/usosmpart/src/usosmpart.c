/*
 * usosmpart - USB multi-partition disk filter for Windows 2000 to 8.1 /
 * 10 before 1703 (x86 and x64), part of Universal Service OS (USOS).
 *
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * What it does
 * ------------
 * Windows before 10 1703 shows only one volume of a disk that reports
 * removable media (SCSI INQUIRY RMB = 1, most USB sticks): the disk class
 * driver decides "removable" from STORAGE_DEVICE_DESCRIPTOR.RemovableMedia,
 * which the USB mass-storage port driver (usbstor) fills from INQUIRY, and a
 * removable disk gets one partition device only. USB hard disks (RMB = 0)
 * get every partition.
 *
 * This is a lower filter of the disk class (between disk.sys and the
 * USBSTOR PDO). It attaches only to disks enumerated by USBSTOR (every
 * other disk, the boot disk included, never sees it). When the disk class
 * driver asks for the device descriptor and the answer says
 * BusType = USB + RemovableMedia = TRUE, the filter reads the media's
 * partition table itself (READ CAPACITY + READ(10) through the PDO) and
 * clears RemovableMedia only when the media holds MORE THAN ONE partition.
 * The disk then starts like a USB hard disk: every partition gets its own
 * device and drive letter.
 *
 * What stays as it is
 * -------------------
 *  - single-partition sticks, superfloppies, empty card-reader slots and
 *    every non-USB disk: no change at all;
 *  - hot plug / safe removal: the USB device's PnP capabilities (Removable,
 *    SurpriseRemovalOK) and its removal policy come from the bus driver and
 *    the PnP manager, not from RemovableMedia, so "Safely Remove Hardware"
 *    lists the device as before and surprise removal tears the whole stack
 *    down (every volume dismounts, every letter goes away);
 *  - write caching: the class driver's "quick removal" decision (no device
 *    write cache, file-system deferred flush) follows the removal policy
 *    (DeviceHotplug), which is unchanged; this is the policy USB hard disks
 *    already get.
 *
 * GPT sticks on Windows 2000 / XP x86 (no GPT data disks): disk.sys there
 * hands out the protective MBR's 0xEE entry, and on a removable disk that
 * single partition gets a drive letter and mounts RAW ("0 bytes", Explorer
 * offers to format it; a format would overwrite the GPT and the stick's
 * partitions, the USOS stick's DATA among them). A stick whose MBR holds
 * nothing but the 0xEE entry is therefore started as a fixed disk too: on a
 * fixed disk the volume manager keeps a partition of an unknown type hidden
 * (no drive letter, as for any GPT disk on these systems), and the filter
 * fails every write command to it with "write protected", so no tool of
 * the old system can damage the GPT data the system cannot read.
 *
 * Limits: a card reader that held a multi-partition card at plug-in time
 * becomes a fixed disk until it is unplugged (a card swap is not seen).
 * GPT media count only on NT 5.2 and later (2000 / XP x86 cannot use GPT
 * data disks). Opt-out: Services\usosmpart\Parameters\Disabled = 1.
 *
 * Provenance: own code from the public WDK documentation of filter
 * drivers, IOCTL_STORAGE_QUERY_PROPERTY, SCSI_REQUEST_BLOCK and the
 * MBR / UEFI GPT on-disk formats. Which descriptor field drives the
 * removable path and the quick-removal policy was confirmed by reading the
 * user-supplied NT 5 sources (disk, classpnp, fastfat, PnP manager) for
 * local diagnosis; no code from them is in this file (README.md).
 */

#include <ntddk.h>
#include <ntddstor.h>
#include <srb.h>
#include <scsi.h>

#define MP_TAG          'pMsU'
#define MP_MAX_SECTOR   4096
#define MP_GPT_ENTRIES  128

/* MpHide: GPT stick on a system without GPT data disks (fixed + no writes). */
typedef enum { MpUnknown = 0, MpFlip, MpKeep, MpHide } MP_DECISION;

typedef struct _MP_EXT {
    PDEVICE_OBJECT  Self;
    PDEVICE_OBJECT  Lower;
    PDEVICE_OBJECT  Pdo;
    IO_REMOVE_LOCK  RemoveLock;
    MP_DECISION     Decision;
    ULONG           Partitions;
} MP_EXT, *PMP_EXT;

static BOOLEAN MpDisabled;
static BOOLEAN MpGptOk;

DRIVER_INITIALIZE DriverEntry;
static DRIVER_ADD_DEVICE MpAddDevice;
static DRIVER_UNLOAD MpUnload;
static DRIVER_DISPATCH MpPass;
static DRIVER_DISPATCH MpDeviceControl;
static DRIVER_DISPATCH MpScsiRequest;
static DRIVER_DISPATCH MpPnp;
static DRIVER_DISPATCH MpPower;

#ifdef ALLOC_PRAGMA
#pragma alloc_text(INIT, DriverEntry)
#pragma alloc_text(PAGE, MpAddDevice)
#pragma alloc_text(PAGE, MpUnload)
#endif

static IO_COMPLETION_ROUTINE MpSignal;
static NTSTATUS MpSignal(PDEVICE_OBJECT Dev, PIRP Irp, PVOID Ctx)
{
    UNREFERENCED_PARAMETER(Dev);
    UNREFERENCED_PARAMETER(Irp);
    KeSetEvent((PKEVENT)Ctx, IO_NO_INCREMENT, FALSE);
    return STATUS_MORE_PROCESSING_REQUIRED;
}

/* Forward and wait (PASSIVE_LEVEL only); the caller completes the IRP. */
static NTSTATUS MpForwardSync(PMP_EXT Ext, PIRP Irp)
{
    KEVENT ev;
    NTSTATUS st;
    KeInitializeEvent(&ev, NotificationEvent, FALSE);
    IoCopyCurrentIrpStackLocationToNext(Irp);
    IoSetCompletionRoutine(Irp, MpSignal, &ev, TRUE, TRUE, TRUE);
    st = IoCallDriver(Ext->Lower, Irp);
    if (st == STATUS_PENDING) {
        KeWaitForSingleObject(&ev, Executive, KernelMode, FALSE, NULL);
        st = Irp->IoStatus.Status;
    }
    return st;
}

static IO_COMPLETION_ROUTINE MpSrbDone;
static NTSTATUS MpSrbDone(PDEVICE_OBJECT Dev, PIRP Irp, PVOID Ctx)
{
    UNREFERENCED_PARAMETER(Dev);
    if (Irp->MdlAddress) {
        IoFreeMdl(Irp->MdlAddress);
        Irp->MdlAddress = NULL;
    }
    KeSetEvent((PKEVENT)Ctx, IO_NO_INCREMENT, FALSE);
    return STATUS_MORE_PROCESSING_REQUIRED;
}

/* One SCSI command to the PDO, data-in into Buf (nonpaged, Len bytes, 0 =
 * no data). TRUE when the command completed successfully. */
static BOOLEAN MpScsi(PMP_EXT Ext, const UCHAR *Cdb, UCHAR CdbLen, PVOID Buf, ULONG Len)
{
    PSCSI_REQUEST_BLOCK srb;
    PUCHAR sense;
    PIRP irp;
    PIO_STACK_LOCATION sp;
    KEVENT ev;
    NTSTATUS st;
    UCHAR status;
    BOOLEAN ok = FALSE;

    srb = (PSCSI_REQUEST_BLOCK)ExAllocatePoolWithTag(NonPagedPool, sizeof(*srb) + SENSE_BUFFER_SIZE, MP_TAG);
    if (!srb)
        return FALSE;
    RtlZeroMemory(srb, sizeof(*srb) + SENSE_BUFFER_SIZE);
    sense = (PUCHAR)(srb + 1);
    irp = IoAllocateIrp(Ext->Lower->StackSize, FALSE);
    if (!irp) {
        ExFreePool(srb);
        return FALSE;
    }
    if (Len) {
        if (!IoAllocateMdl(Buf, Len, FALSE, FALSE, irp)) {
            IoFreeIrp(irp);
            ExFreePool(srb);
            return FALSE;
        }
        MmBuildMdlForNonPagedPool(irp->MdlAddress);
    }
    srb->Length = sizeof(SCSI_REQUEST_BLOCK);
    srb->Function = SRB_FUNCTION_EXECUTE_SCSI;
    srb->SrbFlags = SRB_FLAGS_DISABLE_SYNCH_TRANSFER | SRB_FLAGS_NO_QUEUE_FREEZE |
                    (Len ? SRB_FLAGS_DATA_IN : SRB_FLAGS_NO_DATA_TRANSFER);
    srb->DataBuffer = Len ? Buf : NULL;
    srb->DataTransferLength = Len;
    srb->TimeOutValue = 10;
    srb->QueueTag = SP_UNTAGGED;
    srb->QueueAction = SRB_SIMPLE_TAG_REQUEST;
    srb->SenseInfoBuffer = sense;
    srb->SenseInfoBufferLength = SENSE_BUFFER_SIZE;
    srb->CdbLength = CdbLen;
    RtlCopyMemory(srb->Cdb, Cdb, CdbLen);
    srb->OriginalRequest = irp;

    KeInitializeEvent(&ev, NotificationEvent, FALSE);
    sp = IoGetNextIrpStackLocation(irp);
    sp->MajorFunction = IRP_MJ_SCSI;
    sp->Parameters.Scsi.Srb = srb;
    IoSetCompletionRoutine(irp, MpSrbDone, &ev, TRUE, TRUE, TRUE);
    st = IoCallDriver(Ext->Lower, irp);
    if (st == STATUS_PENDING)
        KeWaitForSingleObject(&ev, Executive, KernelMode, FALSE, NULL);
    st = irp->IoStatus.Status;
    status = SRB_STATUS(srb->SrbStatus);
    ok = NT_SUCCESS(st) && status == SRB_STATUS_SUCCESS &&
         (!Len || srb->DataTransferLength == Len);

    if (srb->SrbStatus & SRB_STATUS_QUEUE_FROZEN) {
        /* Not expected with SRB_FLAGS_NO_QUEUE_FREEZE; release anyway. */
        RtlZeroMemory(srb, sizeof(*srb));
        srb->Length = sizeof(SCSI_REQUEST_BLOCK);
        srb->Function = SRB_FUNCTION_RELEASE_QUEUE;
        srb->OriginalRequest = irp;
        IoReuseIrp(irp, STATUS_SUCCESS);
        KeClearEvent(&ev);
        sp = IoGetNextIrpStackLocation(irp);
        sp->MajorFunction = IRP_MJ_SCSI;
        sp->Parameters.Scsi.Srb = srb;
        IoSetCompletionRoutine(irp, MpSrbDone, &ev, TRUE, TRUE, TRUE);
        if (IoCallDriver(Ext->Lower, irp) == STATUS_PENDING)
            KeWaitForSingleObject(&ev, Executive, KernelMode, FALSE, NULL);
    }
    IoFreeIrp(irp);
    ExFreePool(srb);
    return ok;
}

static ULONG MpBe32(const UCHAR *p)
{
    return ((ULONG)p[0] << 24) | ((ULONG)p[1] << 16) | ((ULONG)p[2] << 8) | p[3];
}

static ULONG MpLe32(const UCHAR *p)
{
    return (ULONG)p[0] | ((ULONG)p[1] << 8) | ((ULONG)p[2] << 16) | ((ULONG)p[3] << 24);
}

static BOOLEAN MpRead(PMP_EXT Ext, ULONG Lba, USHORT Blocks, ULONG BlockSize, PUCHAR Buf)
{
    UCHAR cdb[10];
    RtlZeroMemory(cdb, sizeof(cdb));
    cdb[0] = 0x28; /* READ(10) */
    cdb[2] = (UCHAR)(Lba >> 24);
    cdb[3] = (UCHAR)(Lba >> 16);
    cdb[4] = (UCHAR)(Lba >> 8);
    cdb[5] = (UCHAR)Lba;
    cdb[7] = (UCHAR)(Blocks >> 8);
    cdb[8] = (UCHAR)Blocks;
    return MpScsi(Ext, cdb, 10, Buf, (ULONG)Blocks * BlockSize);
}

/* Partitions on the media: 0 = no media / unreadable / no partition
 * table, else the count (an MBR extended entry counts as two: it holds at
 * least one logical drive next to the primary that brought it).
 * *GptHidden: TRUE when the MBR holds only a protective 0xEE entry and this
 * system cannot use GPT data disks (NT 5.0 / 5.1). */
static ULONG MpCountPartitions(PMP_EXT Ext, BOOLEAN *GptHidden)
{
    UCHAR cdb[10];
    PUCHAR buf;
    ULONG blockSize = 0, lastLba = 0, count = 0, i, attempt;
    BOOLEAN gpt = FALSE;

    *GptHidden = FALSE;
    buf = (PUCHAR)ExAllocatePoolWithTag(NonPagedPool, MP_MAX_SECTOR * 4, MP_TAG);
    if (!buf)
        return 0;
    /* READ CAPACITY(10); a fresh device may first report a unit attention. */
    for (attempt = 0; attempt < 3 && !blockSize; attempt++) {
        RtlZeroMemory(cdb, sizeof(cdb));
        cdb[0] = 0x25;
        RtlZeroMemory(buf, 8);
        if (MpScsi(Ext, cdb, 10, buf, 8)) {
            lastLba = MpBe32(buf);
            blockSize = MpBe32(buf + 4);
        } else {
            RtlZeroMemory(cdb, sizeof(cdb)); /* TEST UNIT READY */
            MpScsi(Ext, cdb, 6, NULL, 0);
        }
    }
    if (blockSize < 512 || blockSize > MP_MAX_SECTOR || (blockSize & (blockSize - 1)) || lastLba < 2)
        goto out;
    if (!MpRead(Ext, 0, 1, blockSize, buf) || buf[510] != 0x55 || buf[511] != 0xAA)
        goto out;
    for (i = 0; i < 4; i++) {
        const UCHAR *e = buf + 446 + 16 * i;
        UCHAR type = e[4];
        if (!type || !MpLe32(e + 12))
            continue;
        if (type == 0xEE) {
            gpt = TRUE;
            continue;
        }
        count += (type == 0x05 || type == 0x0F || type == 0x85) ? 2 : 1;
    }
    if (gpt) {
        ULONG entriesLba, entries, entrySize, perBlock, blocks, b, j;
        if (!MpGptOk) {
            /* Pure protective MBR only; a hybrid MBR keeps today's path. */
            *GptHidden = (BOOLEAN)(count == 0);
            count = 0;
            goto out;
        }
        count = 0;
        if (!MpRead(Ext, 1, 1, blockSize, buf) || RtlCompareMemory(buf, "EFI PART", 8) != 8)
            goto out;
        entriesLba = MpLe32(buf + 72);   /* high dword must be 0 */
        entries = MpLe32(buf + 80);
        entrySize = MpLe32(buf + 84);
        if (MpLe32(buf + 76) || entrySize < 128 || entrySize > blockSize || (blockSize % entrySize) ||
            !entriesLba || entriesLba > lastLba)
            goto out;
        if (entries > MP_GPT_ENTRIES)
            entries = MP_GPT_ENTRIES;
        perBlock = blockSize / entrySize;
        blocks = (entries + perBlock - 1) / perBlock;
        for (b = 0; b < blocks; b++) {
            if (!MpRead(Ext, entriesLba + b, 1, blockSize, buf))
                break;
            for (j = 0; j < perBlock && b * perBlock + j < entries; j++) {
                const ULONG *g = (const ULONG *)(buf + j * entrySize);
                if (g[0] | g[1] | g[2] | g[3])
                    count++;
            }
        }
    }
out:
    ExFreePool(buf);
    return count;
}

static NTSTATUS MpDeviceControl(PDEVICE_OBJECT Dev, PIRP Irp)
{
    PMP_EXT ext = (PMP_EXT)Dev->DeviceExtension;
    PIO_STACK_LOCATION sp = IoGetCurrentIrpStackLocation(Irp);
    PSTORAGE_PROPERTY_QUERY q;
    PSTORAGE_DEVICE_DESCRIPTOR d;
    NTSTATUS st;

    st = IoAcquireRemoveLock(&ext->RemoveLock, Irp);
    if (!NT_SUCCESS(st)) {
        Irp->IoStatus.Status = st;
        Irp->IoStatus.Information = 0;
        IoCompleteRequest(Irp, IO_NO_INCREMENT);
        return st;
    }
    q = (PSTORAGE_PROPERTY_QUERY)Irp->AssociatedIrp.SystemBuffer;
    if (MpDisabled || KeGetCurrentIrql() != PASSIVE_LEVEL ||
        sp->Parameters.DeviceIoControl.IoControlCode != IOCTL_STORAGE_QUERY_PROPERTY ||
        sp->Parameters.DeviceIoControl.InputBufferLength < FIELD_OFFSET(STORAGE_PROPERTY_QUERY, AdditionalParameters) ||
        !q || q->PropertyId != StorageDeviceProperty || q->QueryType != PropertyStandardQuery) {
        IoSkipCurrentIrpStackLocation(Irp);
        st = IoCallDriver(ext->Lower, Irp);
        IoReleaseRemoveLock(&ext->RemoveLock, Irp);
        return st;
    }
    st = MpForwardSync(ext, Irp);
    d = (PSTORAGE_DEVICE_DESCRIPTOR)Irp->AssociatedIrp.SystemBuffer;
    if (NT_SUCCESS(st) && d &&
        Irp->IoStatus.Information >= FIELD_OFFSET(STORAGE_DEVICE_DESCRIPTOR, RawPropertiesLength) &&
        d->BusType == BusTypeUsb && d->RemovableMedia) {
        if (ext->Decision != MpFlip && ext->Decision != MpHide) {
            BOOLEAN gptHidden;
            ext->Partitions = MpCountPartitions(ext, &gptHidden);
            ext->Decision = ext->Partitions > 1 ? MpFlip : gptHidden ? MpHide : MpKeep;
        }
        if (ext->Decision == MpFlip || ext->Decision == MpHide) {
            PDEVICE_OBJECT o;
            d->RemovableMedia = FALSE;
            /* Windows 7 and later: the port driver's PDO carries
             * FILE_REMOVABLE_MEDIA and the PnP manager has already copied
             * it to every device of this stack (disk.sys only ever sets the
             * bit), so the disk would still enumerate one partition. Clear
             * it from the PDO up, while the disk is starting. The device
             * node's removal policy (hot plug, quick removal) is separate
             * and stays. */
            for (o = ext->Pdo; o; o = o->AttachedDevice)
                o->Characteristics &= ~FILE_REMOVABLE_MEDIA;
        }
    }
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    IoReleaseRemoveLock(&ext->RemoveLock, Irp);
    return st;
}

/* SCSI write commands: WRITE 6/10/12/16, WRITE AND VERIFY 10/12/16,
 * WRITE SAME 10/16. */
static BOOLEAN MpIsWrite(UCHAR Op)
{
    return (BOOLEAN)(Op == 0x0A || Op == 0x2A || Op == 0xAA || Op == 0x8A ||
                     Op == 0x2E || Op == 0xAE || Op == 0x8E || Op == 0x41 || Op == 0x93);
}

/* IRP_MJ_SCSI from disk.sys. On a hidden GPT stick (MpHide) every write
 * command fails as CHECK CONDITION, DATA PROTECT / WRITE PROTECTED (sense
 * 07/27/00), which the class driver reports as STATUS_MEDIA_WRITE_PROTECTED
 * without retries; everything else passes down unchanged. */
static NTSTATUS MpScsiRequest(PDEVICE_OBJECT Dev, PIRP Irp)
{
    PMP_EXT ext = (PMP_EXT)Dev->DeviceExtension;
    PIO_STACK_LOCATION sp = IoGetCurrentIrpStackLocation(Irp);
    PSCSI_REQUEST_BLOCK srb = (PSCSI_REQUEST_BLOCK)sp->Parameters.Scsi.Srb;
    NTSTATUS st = IoAcquireRemoveLock(&ext->RemoveLock, Irp);
    if (!NT_SUCCESS(st)) {
        Irp->IoStatus.Status = st;
        Irp->IoStatus.Information = 0;
        IoCompleteRequest(Irp, IO_NO_INCREMENT);
        return st;
    }
    if (ext->Decision == MpHide && srb && srb->Function == SRB_FUNCTION_EXECUTE_SCSI &&
        srb->CdbLength && MpIsWrite(srb->Cdb[0])) {
        srb->SrbStatus = SRB_STATUS_ERROR;
        srb->ScsiStatus = SCSISTAT_CHECK_CONDITION;
        srb->DataTransferLength = 0;
        if (srb->SenseInfoBuffer && srb->SenseInfoBufferLength >= 14 &&
            !(srb->SrbFlags & SRB_FLAGS_DISABLE_AUTOSENSE)) {
            PUCHAR sense = (PUCHAR)srb->SenseInfoBuffer;
            UCHAR len = srb->SenseInfoBufferLength > 18 ? 18 : srb->SenseInfoBufferLength;
            RtlZeroMemory(sense, len);
            sense[0] = 0x70;            /* current error, fixed format */
            sense[2] = 0x07;            /* DATA PROTECT */
            sense[7] = (UCHAR)(len - 8); /* additional sense length */
            sense[12] = 0x27;           /* WRITE PROTECTED */
            srb->SenseInfoBufferLength = len;
            srb->SrbStatus |= SRB_STATUS_AUTOSENSE_VALID;
        }
        Irp->IoStatus.Status = STATUS_MEDIA_WRITE_PROTECTED;
        Irp->IoStatus.Information = 0;
        IoCompleteRequest(Irp, IO_NO_INCREMENT);
        IoReleaseRemoveLock(&ext->RemoveLock, Irp);
        return STATUS_MEDIA_WRITE_PROTECTED;
    }
    IoSkipCurrentIrpStackLocation(Irp);
    st = IoCallDriver(ext->Lower, Irp);
    IoReleaseRemoveLock(&ext->RemoveLock, Irp);
    return st;
}

static NTSTATUS MpPass(PDEVICE_OBJECT Dev, PIRP Irp)
{
    PMP_EXT ext = (PMP_EXT)Dev->DeviceExtension;
    NTSTATUS st = IoAcquireRemoveLock(&ext->RemoveLock, Irp);
    if (!NT_SUCCESS(st)) {
        Irp->IoStatus.Status = st;
        Irp->IoStatus.Information = 0;
        IoCompleteRequest(Irp, IO_NO_INCREMENT);
        return st;
    }
    IoSkipCurrentIrpStackLocation(Irp);
    st = IoCallDriver(ext->Lower, Irp);
    IoReleaseRemoveLock(&ext->RemoveLock, Irp);
    return st;
}

static NTSTATUS MpPower(PDEVICE_OBJECT Dev, PIRP Irp)
{
    PMP_EXT ext = (PMP_EXT)Dev->DeviceExtension;
    NTSTATUS st;
    PoStartNextPowerIrp(Irp);
    st = IoAcquireRemoveLock(&ext->RemoveLock, Irp);
    if (!NT_SUCCESS(st)) {
        Irp->IoStatus.Status = st;
        IoCompleteRequest(Irp, IO_NO_INCREMENT);
        return st;
    }
    IoSkipCurrentIrpStackLocation(Irp);
    st = PoCallDriver(ext->Lower, Irp);
    IoReleaseRemoveLock(&ext->RemoveLock, Irp);
    return st;
}

static NTSTATUS MpPnp(PDEVICE_OBJECT Dev, PIRP Irp)
{
    PMP_EXT ext = (PMP_EXT)Dev->DeviceExtension;
    PIO_STACK_LOCATION sp = IoGetCurrentIrpStackLocation(Irp);
    NTSTATUS st = IoAcquireRemoveLock(&ext->RemoveLock, Irp);
    if (!NT_SUCCESS(st)) {
        Irp->IoStatus.Status = st;
        IoCompleteRequest(Irp, IO_NO_INCREMENT);
        return st;
    }
    switch (sp->MinorFunction) {
    case IRP_MN_REMOVE_DEVICE:
        IoReleaseRemoveLockAndWait(&ext->RemoveLock, Irp);
        IoSkipCurrentIrpStackLocation(Irp);
        st = IoCallDriver(ext->Lower, Irp);
        IoDetachDevice(ext->Lower);
        IoDeleteDevice(Dev);
        return st;
    case IRP_MN_DEVICE_USAGE_NOTIFICATION:
        /* Paging path: be pageable-power only when the lower stack is. */
        if (!Dev->AttachedDevice || (Dev->AttachedDevice->Flags & DO_POWER_PAGABLE))
            Dev->Flags |= DO_POWER_PAGABLE;
        st = MpForwardSync(ext, Irp);
        if (!(ext->Lower->Flags & DO_POWER_PAGABLE))
            Dev->Flags &= ~DO_POWER_PAGABLE;
        IoCompleteRequest(Irp, IO_NO_INCREMENT);
        IoReleaseRemoveLock(&ext->RemoveLock, Irp);
        return st;
    case IRP_MN_START_DEVICE:
        /* A restart re-reads the media. */
        ext->Decision = MpUnknown;
        break;
    default:
        break;
    }
    IoSkipCurrentIrpStackLocation(Irp);
    st = IoCallDriver(ext->Lower, Irp);
    IoReleaseRemoveLock(&ext->RemoveLock, Irp);
    return st;
}

/* Only disks enumerated by USBSTOR get the filter. */
static BOOLEAN MpIsUsbStor(PDEVICE_OBJECT Pdo)
{
    WCHAR name[16];
    ULONG len = 0;
    NTSTATUS st;
    RtlZeroMemory(name, sizeof(name));
    st = IoGetDeviceProperty(Pdo, DevicePropertyEnumeratorName, sizeof(name) - sizeof(WCHAR), name, &len);
    if (!NT_SUCCESS(st))
        return FALSE;
    return (BOOLEAN)(len == 8 * sizeof(WCHAR) &&
        (name[0] | 0x20) == L'u' && (name[1] | 0x20) == L's' && (name[2] | 0x20) == L'b' &&
        (name[3] | 0x20) == L's' && (name[4] | 0x20) == L't' && (name[5] | 0x20) == L'o' &&
        (name[6] | 0x20) == L'r' && name[7] == 0);
}

static NTSTATUS MpAddDevice(PDRIVER_OBJECT Drv, PDEVICE_OBJECT Pdo)
{
    PDEVICE_OBJECT dev;
    PMP_EXT ext;
    NTSTATUS st;

    PAGED_CODE();
    if (MpDisabled || !MpIsUsbStor(Pdo))
        return STATUS_SUCCESS; /* not attached: the stack builds without us */
    st = IoCreateDevice(Drv, sizeof(MP_EXT), NULL, FILE_DEVICE_DISK, FILE_DEVICE_SECURE_OPEN, FALSE, &dev);
    if (!NT_SUCCESS(st))
        return STATUS_SUCCESS;
    ext = (PMP_EXT)dev->DeviceExtension;
    RtlZeroMemory(ext, sizeof(*ext));
    ext->Self = dev;
    ext->Pdo = Pdo;
    IoInitializeRemoveLock(&ext->RemoveLock, MP_TAG, 0, 0);
    ext->Lower = IoAttachDeviceToDeviceStack(dev, Pdo);
    if (!ext->Lower) {
        IoDeleteDevice(dev);
        return STATUS_SUCCESS;
    }
    dev->DeviceType = ext->Lower->DeviceType;
    dev->Characteristics = ext->Lower->Characteristics;
    dev->Flags |= ext->Lower->Flags & (DO_DIRECT_IO | DO_BUFFERED_IO | DO_POWER_PAGABLE);
    dev->Flags &= ~DO_DEVICE_INITIALIZING;
    return STATUS_SUCCESS;
}

static VOID MpUnload(PDRIVER_OBJECT Drv)
{
    UNREFERENCED_PARAMETER(Drv);
    PAGED_CODE();
}

NTSTATUS DriverEntry(PDRIVER_OBJECT Drv, PUNICODE_STRING RegistryPath)
{
    RTL_QUERY_REGISTRY_TABLE table[2];
    ULONG disabled = 0, zero = 0, major = 0, minor = 0, i;
    WCHAR path[200];
    UNICODE_STRING params;

    PsGetVersion(&major, &minor, NULL, NULL);
    MpGptOk = (BOOLEAN)(major > 5 || (major == 5 && minor >= 2));

    /* <service key>\Parameters, value Disabled (REG_DWORD). */
    RtlZeroMemory(path, sizeof(path));
    params.Buffer = path;
    params.Length = 0;
    params.MaximumLength = sizeof(path) - sizeof(WCHAR); /* keeps a NUL */
    if (NT_SUCCESS(RtlAppendUnicodeStringToString(&params, RegistryPath)) &&
        NT_SUCCESS(RtlAppendUnicodeToString(&params, L"\\Parameters"))) {
        RtlZeroMemory(table, sizeof(table));
        table[0].Flags = RTL_QUERY_REGISTRY_DIRECT;
        table[0].Name = L"Disabled";
        table[0].EntryContext = &disabled;
        table[0].DefaultType = REG_DWORD;
        table[0].DefaultData = &zero;
        table[0].DefaultLength = sizeof(ULONG);
        if (NT_SUCCESS(RtlQueryRegistryValues(RTL_REGISTRY_ABSOLUTE | RTL_REGISTRY_OPTIONAL,
                                              params.Buffer, table, NULL, NULL)))
            MpDisabled = (BOOLEAN)(disabled != 0);
    }
    for (i = 0; i <= IRP_MJ_MAXIMUM_FUNCTION; i++)
        Drv->MajorFunction[i] = MpPass;
    Drv->MajorFunction[IRP_MJ_DEVICE_CONTROL] = MpDeviceControl;
    Drv->MajorFunction[IRP_MJ_SCSI] = MpScsiRequest;
    Drv->MajorFunction[IRP_MJ_PNP] = MpPnp;
    Drv->MajorFunction[IRP_MJ_POWER] = MpPower;
    Drv->DriverExtension->AddDevice = MpAddDevice;
    Drv->DriverUnload = MpUnload;
    return STATUS_SUCCESS;
}
