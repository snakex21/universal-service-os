/*
 * usosusb - USOS USB disk service (UDS) SCSI miniport for Windows 95 OSR2 /
 * 98 / 98 SE / Me: USOSUSB.MPD, loaded by SCSIPORT.PDR under IOS.
 *
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Own implementation from the public SCSI SPC / SBC definitions, the public
 * DDK documentation of the SCSI port / miniport interface and the USOS UDS
 * ABI (src/platform/bios/win9x/usosuds.h). No Microsoft source code.
 * docs/usb9x-hotswap-design-2026-10-19.md, section 1 (A) and stage 1.
 *
 * SeaBIOS inside CSMWrap stays the only xHCI owner. Its helper core serves
 * UDS channel 1 (struct uds_channel at "CSMPPrxy" + 48 in the F-segment);
 * this miniport never touches PCI or the xHCI. It is registered for the Isa
 * bus on a root devnode (Root\SCSIAdapter\USOSUSB), has no access ranges and
 * no interrupt, and polls the channel:
 *   - one request at a time from a physically contiguous uncached block
 *     (request, status page, ENUM table, 64 KiB bounce buffer);
 *   - HwStartIo spins up to ~2 ms on channel->done, then the request is
 *     polled from a 1 ms RequestTimerCall; NextRequest only after the SRB
 *     completed; a 15 s watchdog per posted request;
 *   - each SCSI target 0..Slots-1 is a removable slot, run by the slot state
 *     machine of src/platform/bios/win9x/usosuds_slot.c (compiled into this
 *     binary): fixed INQUIRY identity, NOT READY / 3Ah when empty, one
 *     UNIT ATTENTION / 28h after a stick change.
 */
#include "usosusb.h"

ULONG DriverEntry(IN PVOID DriverObject, IN PVOID Argument2);
static ULONG UsbFindAdapter(IN PVOID DeviceExtension, IN PVOID Context, IN PVOID BusInformation,
                            IN PCHAR ArgumentString, IN OUT PPORT_CONFIGURATION_INFORMATION ConfigInfo,
                            OUT PBOOLEAN Again);
static BOOLEAN UsbHwInitialize(IN PVOID DeviceExtension);
static BOOLEAN UsbStartIo(IN PVOID DeviceExtension, IN PSCSI_REQUEST_BLOCK Srb);
static BOOLEAN UsbResetBus(IN PVOID DeviceExtension, IN ULONG PathId);
static BOOLEAN UsbAdapterState(IN PVOID DeviceExtension, IN PVOID Context, IN BOOLEAN SaveState);
static VOID UsbTimer(IN PVOID DeviceExtension);

/* one adapter per system: the channel has one OS client */
static BOOLEAN UsbClaimed = FALSE;

/* ------------------------------------------------------------------ */
/* small helpers (no CRT)                                               */
/* ------------------------------------------------------------------ */

static VOID UsbZero(PVOID Buffer, ULONG Length)
{
    volatile UCHAR *p = (volatile UCHAR *)Buffer;
    while (Length--) *p++ = 0;
}

/* ------------------------------------------------------------------ */
/* platform: VMM, port E9h, TSC, store barrier                          */
/* ------------------------------------------------------------------ */

#ifndef USOSUSB_HOST
unsigned __int64 __emulu(unsigned int a, unsigned int b);
#pragma intrinsic(__emulu)
#define UsbMul(a, b) __emulu((unsigned int)(a), (unsigned int)(b))

/* VxD service call: INT 20h + dword (VMM = 0001h, _MapPhysToLinear = 006Ch,
   C convention; as usosnvme's W9X build). Returns the linear address or NULL. */
static PVOID UsbMapPhys(ULONG Phys, ULONG Bytes)
{
    ULONG lin;
    __asm {
        push 0
        push Bytes
        push Phys
        int 20h
        _emit 06Ch
        _emit 000h
        _emit 001h
        _emit 000h
        add esp, 12
        mov lin, eax
    }
    return lin == 0xFFFFFFFFUL ? NULL : (PVOID)lin;
}

/* Bochs / QEMU debug console (-debugcon): port E9h reads back E9h there and
   FFh on real hardware, where nothing is written. */
static LONG UsbE9 = -1;

static VOID UsbDbgStr(const CHAR *s)
{
    if (UsbE9 < 0) {
        UCHAR v;
        __asm {
            in al, 0E9h
            mov v, al
        }
        UsbE9 = (v == 0xE9) ? 1 : 0;
    }
    if (!UsbE9) return;
    while (*s) {
        CHAR c = *s++;
        __asm {
            mov al, c
            out 0E9h, al
        }
    }
}

/* full fence for the request block vs. the doorbell (x86: locked op) */
static VOID UsbBarrier(VOID)
{
    __asm lock add dword ptr [esp], 0
}

/* CPUID present (EFLAGS.ID toggles) and leaf 1 EDX bit 4 (TSC) */
static BOOLEAN UsbHasTsc(VOID)
{
    ULONG has = 0;
    __asm {
        pushfd
        pop eax
        mov ecx, eax
        xor eax, 200000h
        push eax
        popfd
        pushfd
        pop eax
        push ecx
        popfd
        xor eax, ecx
        test eax, 200000h
        jz no_cpuid
        push ebx
        xor eax, eax
        cpuid
        cmp eax, 1
        jb no_leaf
        mov eax, 1
        cpuid
        and edx, 10h
        mov has, edx
    no_leaf:
        pop ebx
    no_cpuid:
    }
    return has ? TRUE : FALSE;
}

static ULONGLONG UsbRdtsc(VOID)
{
    ULONG lo, hi;
    __asm {
        rdtsc
        mov lo, eax
        mov hi, edx
    }
    return ((ULONGLONG)hi << 32) | lo;
}
#else
#define UsbMul(a, b) ((ULONGLONG)(ULONG)(a) * (ULONG)(b))
#define UsbMapPhys host_map_phys
#define UsbDbgStr host_dbg_str
#define UsbBarrier host_barrier
#define UsbHasTsc host_has_tsc
#define UsbRdtsc host_rdtsc
#endif

/* ------------------------------------------------------------------ */
/* debug lines (port E9h only)                                          */
/* ------------------------------------------------------------------ */

typedef struct _USB_LINE {
    CHAR Text[96];
    ULONG Len;
} USB_LINE;

static VOID LineStr(USB_LINE *l, const CHAR *s)
{
    while (*s && l->Len < 95) l->Text[l->Len++] = *s++;
}

static VOID LineHex(USB_LINE *l, ULONG v, ULONG digits)
{
    static const CHAR hex[] = "0123456789ABCDEF";
    while (digits-- && l->Len < 95) l->Text[l->Len++] = hex[(v >> (digits * 4)) & 0xF];
}

static VOID LineDec(USB_LINE *l, ULONG v)
{
    CHAR tmp[11];
    ULONG n = 0;
    do { tmp[n++] = (CHAR)('0' + (v % 10)); v /= 10; } while (v && n < 10);
    while (n && l->Len < 95) l->Text[l->Len++] = tmp[--n];
}

static VOID LineOut(USB_LINE *l)
{
    l->Text[l->Len] = 0;
    UsbDbgStr(l->Text);
    UsbDbgStr("\n");
}

static VOID UsbSay(const CHAR *Msg, ULONG Value)
{
    USB_LINE l;
    l.Len = 0;
    LineStr(&l, "USOSUSB " USOSUSB_VERSION " 9x: ");
    LineStr(&l, Msg);
    if (Value != 0xFFFFFFFFUL) {
        LineStr(&l, " ");
        LineHex(&l, Value, 8);
    }
    LineOut(&l);
}

/* ------------------------------------------------------------------ */
/* clock                                                                */
/* ------------------------------------------------------------------ */

static ULONGLONG UsbNow(PHW_DEVICE_EXTENSION Ext)
{
    return Ext->Tsc ? UsbRdtsc() : Ext->Soft;
}

static ULONGLONG UsbAfterMs(PHW_DEVICE_EXTENSION Ext, ULONG Ms)
{
    return UsbNow(Ext) + UsbMul(Ms, Ext->TicksPerMs);
}

static VOID UsbStall(PHW_DEVICE_EXTENSION Ext, ULONG Us)
{
    ScsiPortStallExecution(Us);
    if (!Ext->Tsc) Ext->Soft += Us;
}

static VOID UsbClockInit(PHW_DEVICE_EXTENSION Ext)
{
    Ext->Tsc = FALSE;
    Ext->TicksPerMs = 1000;     /* Soft counts microseconds */
    Ext->Soft = 0;
    if (UsbHasTsc()) {
        ULONGLONG t0 = UsbRdtsc(), t1;
        ULONG i;
        for (i = 0; i < 10; i++) ScsiPortStallExecution(1000);
        t1 = UsbRdtsc();
        if (t1 > t0 && t1 - t0 >= 10000 && t1 - t0 < 0xFFFFFFFFUL) {
            Ext->Tsc = TRUE;
            Ext->TicksPerMs = (ULONG)(t1 - t0) / 10;
        }
    }
}

/* ------------------------------------------------------------------ */
/* status page                                                          */
/* ------------------------------------------------------------------ */

static VOID UsbMpSlots(PHW_DEVICE_EXTENSION Ext)
{
    ULONG i;
    for (i = 0; i < Ext->Slots; i++) {
        struct uds_mp_slot *m = &Ext->Mp->slot[i];
        m->dev = Ext->Slot[i].dev;
        m->present = Ext->Slot[i].present;
        m->ua_pending = Ext->Slot[i].ua_pending;
        m->generation = Ext->Slot[i].generation;
    }
}

static VOID UsbMpInit(PHW_DEVICE_EXTENSION Ext)
{
    struct uds_mp_status *m = Ext->Mp;
    UsbZero(m, sizeof(*m));
    m->sig[0] = UDS_MP_SIG0;
    m->sig[1] = UDS_MP_SIG1;
    m->version = UDS_MP_VERSION;
    m->slots = (uds_u8)Ext->Slots;
    m->mp_major = USOSUSB_MAJOR;
    m->mp_minor = USOSUSB_MINOR;
    UsbMpSlots(Ext);
}

/* ------------------------------------------------------------------ */
/* channel                                                              */
/* ------------------------------------------------------------------ */

/* the block is ours again (no request out, or the stale one finished) */
static BOOLEAN UsbChannelFree(PHW_DEVICE_EXTENSION Ext)
{
    if (Ext->Posted) return FALSE;
    if (Ext->Stale) {
        if (Ext->Ch->done != Ext->StaleSeq) return FALSE;
        Ext->Stale = FALSE;
        UsbSay("stale request finished; seq", Ext->StaleSeq);
    }
    return TRUE;
}

/* Ext->Req is filled (seq is set here): store barrier, doorbell */
static VOID UsbPost(PHW_DEVICE_EXTENSION Ext, UCHAR Slot)
{
    Ext->Seq++;
    if (Ext->Seq == 0 || Ext->Seq == Ext->Ch->done) Ext->Seq++;   /* never equal to done before the helper ran */
    Ext->Req->seq = Ext->Seq;
    Ext->Req->status = UDS_S_PENDING;
    Ext->PostOp = Ext->Req->op;
    Ext->PostSlot = Slot;
    Ext->Posted = TRUE;
    Ext->Deadline = UsbAfterMs(Ext, USB_WATCHDOG_MS);
    Ext->Mp->posted++;
    if (Ext->PostOp == UDS_OP_ENUM) Ext->Mp->enums++;
    UsbBarrier();
    Ext->Ch->doorbell = Ext->Seq;
    UsbBarrier();
}

static VOID UsbReqHeader(PHW_DEVICE_EXTENSION Ext, UCHAR Op, UCHAR Dev)
{
    struct uds_req *r = Ext->Req;
    UsbZero(r, sizeof(*r));
    r->magic = UDS_REQ_MAGIC;
    r->version = UDS_VERSION;
    r->size = (uds_u16)sizeof(struct uds_req);
    r->op = Op;
    r->dev = Dev;
    r->dir = UDS_DIR_NONE;
    r->status = UDS_S_PENDING;
}

static VOID UsbPostEnum(PHW_DEVICE_EXTENSION Ext)
{
    UsbReqHeader(Ext, UDS_OP_ENUM, 0);
    Ext->Req->dir = UDS_DIR_IN;
    Ext->Req->data_phys = Ext->InfoPhys;
    Ext->Req->data_len = USB_ENUM_BYTES;
    UsbZero(Ext->Info, USB_ENUM_BYTES);
    UsbPost(Ext, 0xFF);
}

static VOID UsbPostDevOp(PHW_DEVICE_EXTENSION Ext, UCHAR Op, UCHAR Slot)
{
    UsbReqHeader(Ext, Op, Ext->Slot[Slot].dev);
    Ext->Req->generation = Ext->Slot[Slot].generation;
    UsbPost(Ext, Slot);
}

/*
 * ENUM result -> slots. Slot i serves the i-th device table entry (in table
 * order) that is UDS_DEV_PRESENT with bios_drive == 0 and a non-zero
 * generation; a slot without such an entry gets NULL (empty). Entries with
 * a BIOS number belong to INT 13h and are never offered.
 */
static VOID UsbEnumDone(PHW_DEVICE_EXTENSION Ext, BOOLEAN Ok)
{
    ULONG i, d = 0;
    Ext->NeedEnum = FALSE;
    Ext->NextTurEnum = UsbAfterMs(Ext, USB_TUR_ENUM_MS);
    for (i = 0; i < Ext->Slots; i++) {
        BOOLEAN found = FALSE;
        if (Ok) {
            while (d < UDS_MAX_DEVS) {
                const struct uds_dev_info *e = &Ext->Info[d];
                if (e->state == UDS_DEV_PRESENT && e->bios_drive == 0 && e->generation != 0) {
                    uds_slot_update(&Ext->Slot[i], (uds_u8)d, e);
                    found = TRUE;
                    d++;
                    break;
                }
                d++;
            }
        }
        if (!found) uds_slot_update(&Ext->Slot[i], 0xFF, NULL);
    }
    UsbMpSlots(Ext);
    if (Ext->DbgLines < 64) {
        USB_LINE l;
        Ext->DbgLines++;
        l.Len = 0;
        LineStr(&l, "USOSUSB 9x: enum ");
        LineStr(&l, Ok ? "ok" : "failed");
        for (i = 0; i < Ext->Slots; i++) {
            LineStr(&l, " s");
            LineDec(&l, i);
            LineStr(&l, Ext->Slot[i].present ? "=dev" : "=empty");
            if (Ext->Slot[i].present) {
                LineDec(&l, Ext->Slot[i].dev);
                LineStr(&l, "/g");
                LineDec(&l, Ext->Slot[i].generation);
            }
        }
        LineOut(&l);
    }
}

/* ------------------------------------------------------------------ */
/* SRB completion                                                       */
/* ------------------------------------------------------------------ */

static VOID UsbFinish(PHW_DEVICE_EXTENSION Ext)
{
    PSCSI_REQUEST_BLOCK srb = Ext->Srb;
    UCHAR st = (UCHAR)SRB_STATUS(srb->SrbStatus);
    Ext->Mp->srbs++;
    if (st != SRB_STATUS_SUCCESS && st != SRB_STATUS_DATA_OVERRUN) Ext->Mp->errors++;
    if (srb->Function == SRB_FUNCTION_EXECUTE_SCSI && srb->TargetId < Ext->Slots) {
        struct uds_mp_slot *m = &Ext->Mp->slot[srb->TargetId];
        m->last_op = srb->Cdb[0];
        m->last_srb_status = srb->SrbStatus;
        m->last_key = Ext->Res.key;
        m->last_asc = Ext->Res.asc;
        m->last_ascq = Ext->Res.ascq;
        m->srbs++;
    }
    UsbMpSlots(Ext);
    if (srb->Function == SRB_FUNCTION_EXECUTE_SCSI && st != SRB_STATUS_SUCCESS && Ext->DbgLines < 256) {
        USB_LINE l;
        Ext->DbgLines++;
        l.Len = 0;
        LineStr(&l, "USOSUSB 9x: cdb ");
        LineHex(&l, srb->Cdb[0], 2);
        LineStr(&l, " t");
        LineDec(&l, srb->TargetId);
        LineStr(&l, " srb ");
        LineHex(&l, srb->SrbStatus, 2);
        LineStr(&l, " sense ");
        LineHex(&l, Ext->Res.key, 1);
        LineStr(&l, "/");
        LineHex(&l, Ext->Res.asc, 2);
        LineStr(&l, "/");
        LineHex(&l, Ext->Res.ascq, 2);
        LineStr(&l, " uds ");
        LineDec(&l, Ext->Mp->last_status);
        LineOut(&l);
    }
    Ext->DoneSrb = srb;
    Ext->Srb = NULL;
    Ext->Step = STEP_IDLE;
}

/* CHECK CONDITION with fixed-format sense (autosense when IOS allows it) */
static VOID UsbCheck(PSCSI_REQUEST_BLOCK Srb, UCHAR Key, UCHAR Asc, UCHAR Ascq)
{
    Srb->ScsiStatus = SCSISTAT_CHECK_CONDITION;
    Srb->SrbStatus = SRB_STATUS_ERROR;
    if (Srb->SenseInfoBuffer != NULL && Srb->SenseInfoBufferLength != 0 &&
        !(Srb->SrbFlags & SRB_FLAGS_DISABLE_AUTOSENSE)) {
        UCHAR s[18];
        ULONG n = Srb->SenseInfoBufferLength < sizeof(s) ? Srb->SenseInfoBufferLength : (ULONG)sizeof(s);
        UsbZero(s, sizeof(s));
        s[0] = 0x70;
        s[2] = Key;
        s[7] = 10;
        s[12] = Asc;
        s[13] = Ascq;
        ScsiPortMoveMemory(Srb->SenseInfoBuffer, s, n);
        Srb->SrbStatus |= SRB_STATUS_AUTOSENSE_VALID;
    }
}

static VOID UsbApplyRes(PHW_DEVICE_EXTENSION Ext, PSCSI_REQUEST_BLOCK Srb)
{
    if (Ext->Res.scsi_status == SCSISTAT_GOOD) {
        Srb->ScsiStatus = SCSISTAT_GOOD;
        Srb->SrbStatus = SRB_STATUS_SUCCESS;
    } else {
        UsbCheck(Srb, Ext->Res.key, Ext->Res.asc, Ext->Res.ascq);
    }
}

static VOID UsbSetRes(PHW_DEVICE_EXTENSION Ext, UCHAR Key, UCHAR Asc, UCHAR Ascq)
{
    Ext->Res.scsi_status = SCSISTAT_CHECK_CONDITION;
    Ext->Res.key = Key;
    Ext->Res.asc = Asc;
    Ext->Res.ascq = Ascq;
}

static BOOLEAN UsbIsRw(UCHAR Op)
{
    return (BOOLEAN)(Op == 0x08 || Op == 0x0A || Op == 0x28 || Op == 0x2A || Op == 0xA8 || Op == 0xAA ||
                     Op == 0x88 || Op == 0x8A || Op == 0x2E);
}

/* host-to-device opcodes, for an SRB with an unspecified direction */
static BOOLEAN UsbIsOut(UCHAR Op)
{
    return (BOOLEAN)(Op == 0x0A || Op == 0x2A || Op == 0xAA || Op == 0x8A || Op == 0x2E || Op == 0x15 ||
                     Op == 0x55 || Op == 0x3B || Op == 0x04);
}

/* ------------------------------------------------------------------ */
/* the SRB state machine                                                */
/* ------------------------------------------------------------------ */

/* EXECUTE_SCSI after the slot logic said "send": bounce, fill, post */
static VOID UsbSendScsi(PHW_DEVICE_EXTENSION Ext, PSCSI_REQUEST_BLOCK Srb)
{
    UCHAR slot = Srb->TargetId;
    ULONG len = Srb->DataTransferLength;
    UCHAR dir = UDS_DIR_NONE;

    if (len) {
        ULONG f = Srb->SrbFlags & (SRB_FLAGS_DATA_IN | SRB_FLAGS_DATA_OUT);
        if (f == SRB_FLAGS_DATA_IN) dir = UDS_DIR_IN;
        else if (f == SRB_FLAGS_DATA_OUT) dir = UDS_DIR_OUT;
        else dir = UsbIsOut(Srb->Cdb[0]) ? UDS_DIR_OUT : UDS_DIR_IN;
        if (Srb->DataBuffer == NULL) {
            dir = UDS_DIR_NONE;
            len = 0;
        }
    }
    if (len > Ext->BounceLen || Srb->CdbLength > UDS_MAX_CDB) {
        UsbSetRes(Ext, 0x05, 0x24, 0x00);   /* ILLEGAL REQUEST, invalid field in CDB */
        UsbApplyRes(Ext, Srb);
        Srb->DataTransferLength = 0;
        UsbFinish(Ext);
        return;
    }
    if (!UsbChannelFree(Ext)) {
        UsbSetRes(Ext, 0x02, 0x04, 0x00);   /* NOT READY, cause not reportable */
        UsbApplyRes(Ext, Srb);
        Srb->DataTransferLength = 0;
        UsbFinish(Ext);
        return;
    }
    if (dir == UDS_DIR_OUT) ScsiPortMoveMemory(Ext->Bounce, Srb->DataBuffer, len);
    Ext->Dir = dir;
    Ext->DataLen = len;
    uds_slot_fill(&Ext->Slot[slot], Ext->Req, 0, Srb->Cdb, Srb->CdbLength, dir, Ext->BouncePhys, len);
    UsbPost(Ext, slot);
}

static VOID UsbScsiDone(PHW_DEVICE_EXTENSION Ext)
{
    PSCSI_REQUEST_BLOCK srb = Ext->Srb;
    const struct uds_req *r = Ext->Req;
    UCHAR slot = Ext->PostSlot;
    ULONG got = 0;

    uds_slot_after(&Ext->Slot[slot], r, &Ext->Res);
    if (r->status == UDS_S_NODEV || r->status == UDS_S_GONE || r->status == UDS_S_OWNED) Ext->NeedEnum = TRUE;
    if (r->status == UDS_S_OK || r->status == UDS_S_CHECK) {
        ULONG res = r->residue > Ext->DataLen ? Ext->DataLen : r->residue;
        got = Ext->DataLen - res;
    }
    if (Ext->Dir == UDS_DIR_IN && got) ScsiPortMoveMemory(srb->DataBuffer, Ext->Bounce, got);
    srb->DataTransferLength = got;
    UsbApplyRes(Ext, srb);
    /* a short READ / WRITE is not a success; short INQUIRY / MODE SENSE data is */
    if (srb->SrbStatus == SRB_STATUS_SUCCESS && got < Ext->DataLen && UsbIsRw(srb->Cdb[0]))
        srb->SrbStatus = SRB_STATUS_DATA_OVERRUN;
    if (Ext->Res.reset && Ext->Slot[slot].dev < UDS_MAX_DEVS) {
        Ext->ResetNeeded[slot] = 1;
        Ext->Step = STEP_FINISH;
        return;
    }
    UsbFinish(Ext);
}

/* one step while no request is out; may post a request or finish the SRB */
static VOID UsbStep(PHW_DEVICE_EXTENSION Ext)
{
    PSCSI_REQUEST_BLOCK srb = Ext->Srb;
    UCHAR slot = srb->TargetId;

    switch (Ext->Step) {
    case STEP_BEGIN:
        Ext->Step = STEP_SLOT;
        if (UsbChannelFree(Ext)) {
            if (Ext->ResetNeeded[slot] && Ext->Slot[slot].dev < UDS_MAX_DEVS) {
                Ext->ResetNeeded[slot] = 0;
                Ext->Step = STEP_BEGIN;
                UsbPostDevOp(Ext, UDS_OP_RESET, slot);
                return;
            }
            if (srb->Cdb[0] == 0x00 /* TEST UNIT READY */) {
                Ext->TurCount++;
                if (Ext->Tsc ? UsbNow(Ext) >= Ext->NextTurEnum : (Ext->TurCount % USB_TUR_ENUM_EVERY) == 0)
                    Ext->NeedEnum = TRUE;
            }
            if (Ext->NeedEnum) {
                UsbPostEnum(Ext);
                return;
            }
        }
        /* fall through */
    case STEP_SLOT:
        uds_slot_before(&Ext->Slot[slot], srb->Cdb, srb->CdbLength, &Ext->Res);
        switch (Ext->Res.action) {
        case UDS_ACT_LOCAL:
            if (srb->Cdb[0] == 0x12 /* INQUIRY */) {
                ULONG n = srb->DataTransferLength < 36 ? srb->DataTransferLength : 36;
                if ((srb->Cdb[1] & 0x01) || srb->Cdb[2]) {   /* no VPD pages */
                    UsbSetRes(Ext, 0x05, 0x24, 0x00);
                    UsbApplyRes(Ext, srb);
                    srb->DataTransferLength = 0;
                    break;
                }
                if (srb->DataBuffer != NULL && n) uds_local_inquiry((uds_u8 *)srb->DataBuffer, n, slot);
                srb->DataTransferLength = n;
            } else {
                ULONG n = srb->DataTransferLength < 18 ? srb->DataTransferLength : 18;
                if (srb->DataBuffer != NULL && n) uds_local_sense(&Ext->Slot[slot], (uds_u8 *)srb->DataBuffer, n);
                srb->DataTransferLength = n;
                /* reported once (SPC): the next REQUEST SENSE sees NO SENSE */
                Ext->Slot[slot].last_key = Ext->Slot[slot].last_asc = Ext->Slot[slot].last_ascq = 0;
            }
            srb->ScsiStatus = SCSISTAT_GOOD;
            srb->SrbStatus = SRB_STATUS_SUCCESS;
            break;
        case UDS_ACT_GOOD:
            srb->DataTransferLength = 0;
            UsbApplyRes(Ext, srb);
            break;
        case UDS_ACT_CHECK:
            srb->DataTransferLength = 0;
            UsbApplyRes(Ext, srb);
            break;
        case UDS_ACT_EJECT:
            srb->DataTransferLength = 0;
            if (UsbChannelFree(Ext) && Ext->Slot[slot].dev < UDS_MAX_DEVS) {
                srb->ScsiStatus = SCSISTAT_GOOD;
                srb->SrbStatus = SRB_STATUS_SUCCESS;
                UsbPostDevOp(Ext, UDS_OP_EJECT, slot);
                return;
            }
            UsbSetRes(Ext, 0x02, 0x04, 0x00);
            UsbApplyRes(Ext, srb);
            break;
        default:   /* UDS_ACT_SEND */
            UsbSendScsi(Ext, srb);
            return;
        }
        UsbFinish(Ext);
        return;
    case STEP_FINISH:
        if (Ext->ResetNeeded[slot] && Ext->Slot[slot].dev < UDS_MAX_DEVS && UsbChannelFree(Ext)) {
            Ext->ResetNeeded[slot] = 0;
            UsbPostDevOp(Ext, UDS_OP_RESET, slot);
            Ext->Step = STEP_IDLE;   /* RESET done -> finish */
            return;
        }
        UsbFinish(Ext);
        return;
    case STEP_FLUSH:
        while (Ext->Iter < Ext->Slots) {
            struct uds_slot *s = &Ext->Slot[Ext->Iter];
            UCHAR i = (UCHAR)Ext->Iter++;
            /* a slot with a pending UNIT ATTENTION holds a stick IOS never wrote to */
            if (s->present && !s->ua_pending && s->dev < UDS_MAX_DEVS && UsbChannelFree(Ext)) {
                static const UCHAR sync10[10] = { 0x35, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
                Ext->SavedSense[0] = s->last_key;
                Ext->SavedSense[1] = s->last_asc;
                Ext->SavedSense[2] = s->last_ascq;
                uds_slot_fill(s, Ext->Req, 0, sync10, 10, UDS_DIR_NONE, 0, 0);
                UsbPost(Ext, i);
                return;
            }
        }
        srb->SrbStatus = SRB_STATUS_SUCCESS;
        UsbFinish(Ext);
        return;
    case STEP_RESETS:
        while (Ext->Iter < Ext->Slots) {
            UCHAR i = (UCHAR)Ext->Iter++;
            if (srb->Function == SRB_FUNCTION_RESET_DEVICE && i != srb->TargetId) continue;
            if (Ext->Slot[i].present && Ext->Slot[i].dev < UDS_MAX_DEVS && UsbChannelFree(Ext)) {
                Ext->ResetNeeded[i] = 0;
                UsbPostDevOp(Ext, UDS_OP_RESET, i);
                return;
            }
        }
        srb->SrbStatus = SRB_STATUS_SUCCESS;
        UsbFinish(Ext);
        return;
    default:
        UsbFinish(Ext);
        return;
    }
}

/* the posted request completed: read the results */
static VOID UsbDone(PHW_DEVICE_EXTENSION Ext)
{
    UCHAR op = Ext->PostOp;
    Ext->Posted = FALSE;
    UsbBarrier();
    Ext->Mp->last_status = Ext->Req->status;
    switch (op) {
    case UDS_OP_ENUM:
        UsbEnumDone(Ext, (BOOLEAN)(Ext->Req->status == UDS_S_OK));
        return;
    case UDS_OP_SCSI:
        if (Ext->Srb == NULL) return;
        if (Ext->Step == STEP_FLUSH) {
            struct uds_slot *s = &Ext->Slot[Ext->PostSlot];
            struct uds_scsi_res res;
            uds_slot_after(s, Ext->Req, &res);
            if (Ext->Req->status == UDS_S_NODEV || Ext->Req->status == UDS_S_GONE) Ext->NeedEnum = TRUE;
            if (res.reset) Ext->ResetNeeded[Ext->PostSlot] = 1;
            s->last_key = Ext->SavedSense[0];
            s->last_asc = Ext->SavedSense[1];
            s->last_ascq = Ext->SavedSense[2];
            return;
        }
        UsbScsiDone(Ext);
        return;
    case UDS_OP_EJECT:
        Ext->NeedEnum = TRUE;
        if (Ext->Srb != NULL) UsbFinish(Ext);   /* GOOD was set when posting */
        return;
    default:   /* UDS_OP_RESET */
        if (Ext->Srb != NULL && Ext->Step == STEP_IDLE) UsbFinish(Ext);   /* the RESET after a SCSI error */
        return;
    }
}

/* the watchdog gave up on the posted request */
static VOID UsbWatchdog(PHW_DEVICE_EXTENSION Ext)
{
    UsbSay("request timed out (watchdog); seq", Ext->Seq);
    Ext->Posted = FALSE;
    Ext->Stale = TRUE;
    Ext->StaleSeq = Ext->Seq;
    Ext->Mp->last_status = UDS_S_TIMEOUT;
    if (Ext->PostSlot < Ext->Slots) Ext->ResetNeeded[Ext->PostSlot] = 1;
    Ext->NeedEnum = TRUE;
    if (Ext->Srb != NULL) {
        Ext->Srb->SrbStatus = SRB_STATUS_TIMEOUT;
        Ext->Srb->DataTransferLength = 0;
        Ext->Res.key = Ext->Res.asc = Ext->Res.ascq = 0;
        UsbFinish(Ext);
    }
}

/*
 * Run the SRB as far as possible: spin up to SpinUs on a posted request.
 * Returns TRUE when nothing more is to be done now (the SRB finished, or no
 * SRB), FALSE when a request is still out (poll again from the timer).
 */
static BOOLEAN UsbPump(PHW_DEVICE_EXTENSION Ext, ULONG SpinUs, BOOLEAN FromTimer)
{
    for (;;) {
        if (Ext->Posted) {
            if (Ext->Ch->done == Ext->Seq) {
                if (FromTimer) Ext->Mp->polled++;
                UsbDone(Ext);
                continue;
            }
            if (SpinUs >= USB_SPIN_STEP_US) {
                UsbStall(Ext, USB_SPIN_STEP_US);
                SpinUs -= USB_SPIN_STEP_US;
                continue;
            }
            if (UsbNow(Ext) >= Ext->Deadline) {
                UsbWatchdog(Ext);
                continue;
            }
            return FALSE;
        }
        if (Ext->Srb == NULL) return TRUE;
        UsbStep(Ext);
    }
}

static VOID UsbNotifyDone(PHW_DEVICE_EXTENSION Ext)
{
    if (Ext->DoneSrb != NULL) {
        PSCSI_REQUEST_BLOCK srb = Ext->DoneSrb;
        Ext->DoneSrb = NULL;
        ScsiPortNotification(RequestComplete, Ext, srb);
        ScsiPortNotification(NextRequest, Ext, NULL);
    }
}

static VOID UsbArmTimer(PHW_DEVICE_EXTENSION Ext)
{
    Ext->TimerArmed = TRUE;
    ScsiPortNotification(RequestTimerCall, Ext, UsbTimer, USB_TIMER_US);
}

static VOID UsbTimer(IN PVOID DeviceExtension)
{
    PHW_DEVICE_EXTENSION ext = (PHW_DEVICE_EXTENSION)DeviceExtension;
    BOOLEAN idle;
    ext->TimerArmed = FALSE;
    if (ext->Srb == NULL && !ext->Posted) return;
    if (!ext->Tsc) ext->Soft += USB_TIMER_US;
    idle = UsbPump(ext, 0, TRUE);
    UsbNotifyDone(ext);
    if (!idle && ext->Srb != NULL) UsbArmTimer(ext);
}

/* ------------------------------------------------------------------ */
/* DriverEntry                                                          */
/* ------------------------------------------------------------------ */

ULONG DriverEntry(IN PVOID DriverObject, IN PVOID Argument2)
{
    HW_INITIALIZATION_DATA init;

    UsbZero(&init, sizeof(init));
    /* the NT 4.0-sized structure (everything before HwAdapterControl), as
       usosnvme's W9X build hands it to SCSIPORT.PDR */
    init.HwInitializationDataSize = FIELD_OFFSET(HW_INITIALIZATION_DATA, HwAdapterControl);
    init.AdapterInterfaceType = Isa;
    init.HwInitialize = UsbHwInitialize;
    init.HwStartIo = UsbStartIo;
    init.HwInterrupt = NULL;            /* polled */
    init.HwFindAdapter = UsbFindAdapter;
    init.HwResetBus = UsbResetBus;
    init.HwAdapterState = UsbAdapterState;   /* SCSIPORT.PDR reports "Init Failure" without it */
    init.DeviceExtensionSize = sizeof(HW_DEVICE_EXTENSION);
    init.NumberOfAccessRanges = 0;
    init.MapBuffers = TRUE;
    init.NeedPhysicalAddresses = TRUE;
    init.AutoRequestSense = TRUE;
    init.MultipleRequestPerLu = FALSE;
    UsbSay("DriverEntry", 0xFFFFFFFFUL);
    return ScsiPortInitialize(DriverObject, Argument2, &init, NULL);
}

/* ------------------------------------------------------------------ */
/* HwFindAdapter                                                        */
/* ------------------------------------------------------------------ */

/* "SLOTS=n" (1..UDS_MP_SLOTS) in the argument string, if the port passes one */
static ULONG UsbSlotsArg(const CHAR *s)
{
    static const CHAR key[] = "SLOTS=";
    if (s == NULL) return 1;
    for (; *s; s++) {
        ULONG k = 0;
        while (key[k] && (s[k] == key[k] || s[k] == key[k] + ('a' - 'A'))) k++;
        if (!key[k]) {
            CHAR c = s[k];
            if (c >= '1' && c <= '0' + UDS_MP_SLOTS) return (ULONG)(c - '0');
            return 1;
        }
    }
    return 1;
}

static ULONG UsbFindAdapter(IN PVOID DeviceExtension, IN PVOID Context, IN PVOID BusInformation,
                            IN PCHAR ArgumentString, IN OUT PPORT_CONFIGURATION_INFORMATION ConfigInfo,
                            OUT PBOOLEAN Again)
{
    PHW_DEVICE_EXTENSION ext = (PHW_DEVICE_EXTENSION)DeviceExtension;
    PUCHAR fseg, va;
    SCSI_PHYSICAL_ADDRESS pa;
    ULONG off, len, i, run;
    struct uds_channel *ch = NULL;

    (VOID)Context;
    (VOID)BusInformation;
    *Again = FALSE;
    if (UsbClaimed) return SP_RETURN_NOT_FOUND;

    /* the CSMWrap helper mailbox: "CSMPPrxy", 8-byte aligned, F0000h-FFFFFh */
    fseg = (PUCHAR)UsbMapPhys(0xF0000UL, 0x10000UL);
    if (fseg == NULL) {
        UsbSay("F-segment not mapped; not present", 0xFFFFFFFFUL);
        return SP_RETURN_NOT_FOUND;
    }
    for (off = 0; off + UDS_CH1_OFFSET + sizeof(struct uds_channel) <= 0x10000UL; off += 8) {
        const UCHAR *p = fseg + off;
        if (p[0] == 'C' && p[1] == 'S' && p[2] == 'M' && p[3] == 'P' && p[4] == 'P' && p[5] == 'r' &&
            p[6] == 'x' && p[7] == 'y') {
            struct uds_channel *c = (struct uds_channel *)(fseg + off + UDS_CH1_OFFSET);
            if (c->magic == UDS_CH1_MAGIC) { ch = c; break; }
            UsbSay("CSMPPrxy without UDS channel 1 (CSMWrap older than 3.1.2-usos16?); at", 0xF0000UL + off);
        }
    }
    if (ch == NULL) {
        UsbSay("no UDS channel (firmware CSM or old CSMWrap); not present", 0xFFFFFFFFUL);
        return SP_RETURN_NOT_FOUND;
    }
    ext->Ch = ch;
    ext->ChPhys = 0xF0000UL + off + UDS_CH1_OFFSET;
    ext->Slots = UsbSlotsArg(ArgumentString);

    ConfigInfo->NumberOfBuses = 1;
    ConfigInfo->MaximumNumberOfTargets = (UCHAR)ext->Slots;
    ConfigInfo->InitiatorBusId[0] = USB_INITIATOR_ID;
    ConfigInfo->ScatterGather = FALSE;
    ConfigInfo->Master = TRUE;
    ConfigInfo->Dma32BitAddresses = TRUE;
    ConfigInfo->CachesData = FALSE;
    ConfigInfo->AlignmentMask = 0;
    ConfigInfo->MaximumTransferLength = USB_BOUNCE_PAGES * USB_PAGE;
    ConfigInfo->NumberOfPhysicalBreaks = 0;
    ConfigInfo->BusInterruptLevel = 0;
    ConfigInfo->BusInterruptVector = 0;

    va = (PUCHAR)ScsiPortGetUncachedExtension(ext, ConfigInfo, USB_UNCACHED_SIZE);
    if (va == NULL) {
        UsbSay("no uncached extension", 0xFFFFFFFFUL);
        return SP_RETURN_ERROR;
    }
    pa = ScsiPortGetPhysicalAddress(ext, NULL, va, &len);
    i = (USB_PAGE - (pa.LowPart & (USB_PAGE - 1))) & (USB_PAGE - 1);
    ext->Block = va + i;
    pa = ScsiPortGetPhysicalAddress(ext, NULL, ext->Block, &len);
    if (pa.HighPart != 0 || pa.LowPart == 0 || pa.LowPart > 0xFFFFFFFFUL - USB_UNCACHED_SIZE) {
        UsbSay("uncached extension not below 4 GiB; high", (ULONG)pa.HighPart);
        return SP_RETURN_ERROR;
    }
    ext->BlockPhys = pa.LowPart;
    /* the bounce pages need physically contiguous memory (the helper DMAs
       one range); a split allocation gives a shorter bounce buffer */
    pa = ScsiPortGetPhysicalAddress(ext, NULL, ext->Block + USB_PAGE, &len);
    if (pa.HighPart != 0) {
        UsbSay("bounce buffer above 4 GiB", 0xFFFFFFFFUL);
        return SP_RETURN_ERROR;
    }
    ext->BouncePhys = pa.LowPart;
    for (run = 1; run < USB_BOUNCE_PAGES; run++) {
        SCSI_PHYSICAL_ADDRESS p2 = ScsiPortGetPhysicalAddress(ext, NULL, ext->Block + (1 + run) * USB_PAGE, &len);
        if (p2.HighPart != 0 || p2.LowPart != ext->BouncePhys + run * USB_PAGE) break;
    }
    if (run < USB_BOUNCE_PAGES) UsbSay("uncached extension not contiguous; bounce pages", run);
    ext->BounceLen = run * USB_PAGE;
    ConfigInfo->MaximumTransferLength = ext->BounceLen;

    ext->Req = (struct uds_req *)ext->Block;
    ext->Mp = (struct uds_mp_status *)(ext->Block + UDS_MP_STATUS_OFFSET);
    ext->Info = (struct uds_dev_info *)(ext->Block + USB_ENUM_OFFSET);
    ext->InfoPhys = ext->BlockPhys + USB_ENUM_OFFSET;
    ext->Bounce = ext->Block + USB_PAGE;
    UsbZero(ext->Block, USB_PAGE);
    for (i = 0; i < UDS_MP_SLOTS; i++) {
        uds_slot_init(&ext->Slot[i]);
        ext->ResetNeeded[i] = 0;
    }
    ext->Posted = FALSE;
    ext->Stale = FALSE;
    ext->Srb = NULL;
    ext->DoneSrb = NULL;
    ext->Step = STEP_IDLE;
    ext->NeedEnum = TRUE;
    /* the helper may have served an earlier client (a previous Windows
       session): continue after its last sequence number */
    ext->Seq = ch->done;
    if (ch->doorbell != ch->done) {
        /* a request of the earlier client is still being served: wait for it */
        ext->Stale = TRUE;
        ext->StaleSeq = ch->doorbell;
        ext->Seq = ch->doorbell;
    }
    UsbMpInit(ext);
    ch->req_phys = ext->BlockPhys;
    UsbBarrier();
    UsbClaimed = TRUE;
    {
        USB_LINE l;
        l.Len = 0;
        LineStr(&l, "USOSUSB 9x: UDS channel at ");
        LineHex(&l, ext->ChPhys, 5);
        LineStr(&l, " req ");
        LineHex(&l, ext->BlockPhys, 8);
        LineStr(&l, " bounce ");
        LineHex(&l, ext->BouncePhys, 8);
        LineStr(&l, "+");
        LineHex(&l, ext->BounceLen, 5);
        LineStr(&l, " slots ");
        LineDec(&l, ext->Slots);
        LineStr(&l, " done ");
        LineDec(&l, ch->done);
        LineOut(&l);
    }
    return SP_RETURN_FOUND;
}

/* ------------------------------------------------------------------ */
/* HwInitialize, HwStartIo, HwResetBus, HwAdapterState                  */
/* ------------------------------------------------------------------ */

static BOOLEAN UsbHwInitialize(IN PVOID DeviceExtension)
{
    PHW_DEVICE_EXTENSION ext = (PHW_DEVICE_EXTENSION)DeviceExtension;
    ULONG waited = 0;

    UsbClockInit(ext);
    ext->NextTurEnum = UsbNow(ext);
    UsbSay(ext->Tsc ? "HwInitialize, TSC ticks/ms" : "HwInitialize, no TSC", ext->TicksPerMs);
    if (UsbChannelFree(ext)) {
        UsbPostEnum(ext);
        /* a present stick is enumerated at POST already: the answer is fast */
        while (ext->Ch->done != ext->Seq && waited < USB_INIT_ENUM_MS * 1000UL) {
            UsbStall(ext, 100);
            waited += 100;
        }
        if (ext->Ch->done == ext->Seq) UsbDone(ext);
        else UsbSay("first ENUM still out after 1 s; seq", ext->Seq);   /* finished by the first SRB */
    }
    return TRUE;
}

static BOOLEAN UsbStartIo(IN PVOID DeviceExtension, IN PSCSI_REQUEST_BLOCK Srb)
{
    PHW_DEVICE_EXTENSION ext = (PHW_DEVICE_EXTENSION)DeviceExtension;

    ext->Res.key = ext->Res.asc = ext->Res.ascq = 0;
    ext->Res.scsi_status = SCSISTAT_GOOD;
    switch (Srb->Function) {
    case SRB_FUNCTION_EXECUTE_SCSI:
        if (Srb->PathId != 0 || Srb->TargetId >= ext->Slots || Srb->Lun != 0) {
            Srb->SrbStatus = SRB_STATUS_SELECTION_TIMEOUT;
            Srb->DataTransferLength = 0;
            break;
        }
        ext->Srb = Srb;
        ext->Step = STEP_BEGIN;
        goto run;
    case SRB_FUNCTION_FLUSH:
    case SRB_FUNCTION_SHUTDOWN:
        ext->Srb = Srb;
        ext->Step = STEP_FLUSH;
        ext->Iter = 0;
        goto run;
    case SRB_FUNCTION_RESET_BUS:
    case SRB_FUNCTION_RESET_DEVICE:
        ext->Srb = Srb;
        ext->Step = STEP_RESETS;
        ext->Iter = 0;
        goto run;
    case SRB_FUNCTION_ABORT_COMMAND:
    case SRB_FUNCTION_TERMINATE_IO:
    case SRB_FUNCTION_RELEASE_RECOVERY:
        Srb->SrbStatus = SRB_STATUS_SUCCESS;
        break;
    default:
        Srb->SrbStatus = SRB_STATUS_INVALID_REQUEST;
        break;
    }
    ext->Mp->srbs++;
    ScsiPortNotification(RequestComplete, ext, Srb);
    ScsiPortNotification(NextRequest, ext, NULL);
    return TRUE;

run:
    if (!UsbPump(ext, USB_SPIN_US, FALSE) && ext->Srb != NULL && !ext->TimerArmed) UsbArmTimer(ext);
    UsbNotifyDone(ext);
    return TRUE;
}

/* SCSIPORT's bus reset: complete what is outstanding; a request still out
   keeps the block until the helper answers it (stale), and every present
   slot gets a UDS RESET before its next command. */
static BOOLEAN UsbResetBus(IN PVOID DeviceExtension, IN ULONG PathId)
{
    PHW_DEVICE_EXTENSION ext = (PHW_DEVICE_EXTENSION)DeviceExtension;
    ULONG i;
    UsbSay("HwResetBus", PathId);
    if (ext->Posted) {
        ext->Posted = FALSE;
        ext->Stale = TRUE;
        ext->StaleSeq = ext->Seq;
    }
    for (i = 0; i < ext->Slots; i++)
        if (ext->Slot[i].present) ext->ResetNeeded[i] = 1;
    ext->NeedEnum = TRUE;
    ext->Srb = NULL;
    ext->DoneSrb = NULL;
    ext->Step = STEP_IDLE;
    ScsiPortCompleteRequest(ext, (UCHAR)PathId, SP_UNTAGGED, SP_UNTAGGED, SRB_STATUS_BUS_RESET);
    ScsiPortNotification(NextRequest, ext, NULL);
    return TRUE;
}

/* real-mode transitions: nothing to save, the helper core owns the hardware */
static BOOLEAN UsbAdapterState(IN PVOID DeviceExtension, IN PVOID Context, IN BOOLEAN SaveState)
{
    PHW_DEVICE_EXTENSION ext = (PHW_DEVICE_EXTENSION)DeviceExtension;
    (VOID)Context;
    if (ext->Mp != NULL) {
        USB_LINE l;
        l.Len = 0;
        LineStr(&l, "USOSUSB 9x: AdapterState ");
        LineStr(&l, SaveState ? "save" : "restore");
        LineStr(&l, " srbs ");
        LineDec(&l, ext->Mp->srbs);
        LineStr(&l, " posted ");
        LineDec(&l, ext->Mp->posted);
        LineStr(&l, " polled ");
        LineDec(&l, ext->Mp->polled);
        LineStr(&l, " err ");
        LineDec(&l, ext->Mp->errors);
        LineStr(&l, " enums ");
        LineDec(&l, ext->Mp->enums);
        LineOut(&l);
    }
    return TRUE;
}
