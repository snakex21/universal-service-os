/*
 * harness.c - runs the real usosusb.c (xHCI, hubs, HID, mass storage) on
 * bare QEMU hardware: multiboot entry, the NT routines it imports come from
 * shim.c. Test harness only (tools/tests/usosusb_hub/run_hub_qemu.py).
 *
 * Universal Service OS (USOS)
 * Copyright (C) 2026 Maksymilian and the USOS Authors (see NOTICE)
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * DriverEntry runs as on Windows; the class drivers are stood in for by
 * two service callbacks that print every keyboard / mouse record ("KBD
 * <make> d|u", "MOU <dx> <dy> <buttons>"), then the worker thread runs on
 * the boot CPU. The mount thread does not run (no mount manager), so
 * sticks stop at their Diag entry "(<MiB>M wp<n> <n>v)", which needs the
 * BOT bring-up and an LBA 0 read through the hub.
 */
#pragma warning(disable:4505)   /* driver routines the harness does not reach */
#include "usosusb.c"

void __stdcall harness_init(void);
void __stdcall harness_puts(const char *s);
void __stdcall harness_puthex(ULONG v);
void __stdcall harness_putdec(LONG v);
void *__stdcall harness_alloc(ULONG n, ULONG align);
ULONG __stdcall harness_ms(void);

NTSTATUS __stdcall harness_create_device(PDRIVER_OBJECT drv, ULONG ext, PUNICODE_STRING name, ULONG type,
                                         PDEVICE_OBJECT *out)
{
    PDEVICE_OBJECT d = (PDEVICE_OBJECT)harness_alloc(sizeof(DEVICE_OBJECT) + ext, 16);
    UNREFERENCED_PARAMETER(name);
    d->Type = 3;
    d->Size = (USHORT)(sizeof(DEVICE_OBJECT) + ext);
    d->DriverObject = drv;
    d->DeviceType = type;
    d->DeviceExtension = d + 1;
    d->Flags = DO_DEVICE_INITIALIZING;
    *out = d;
    return STATUS_SUCCESS;
}

static VOID kbd_cb(PDEVICE_OBJECT dev, PKEYBOARD_INPUT_DATA s, PKEYBOARD_INPUT_DATA e, PULONG n)
{
    ULONG c = 0;
    UNREFERENCED_PARAMETER(dev);
    for (; s < e; s++, c++) {
        harness_puts("KBD ");
        if (s->Flags & KEY_E0)
            harness_puts("e0 ");
        harness_puthex(s->MakeCode);
        harness_puts((s->Flags & KEY_BREAK) ? " u\n" : " d\n");
    }
    *n = c;
}

static VOID mou_cb(PDEVICE_OBJECT dev, PMOUSE_INPUT_DATA s, PMOUSE_INPUT_DATA e, PULONG n)
{
    ULONG c = 0;
    UNREFERENCED_PARAMETER(dev);
    for (; s < e; s++, c++) {
        harness_puts("MOU ");
        harness_putdec(s->LastX);
        harness_puts(" ");
        harness_putdec(s->LastY);
        harness_puts(" ");
        harness_puthex(s->ButtonFlags);
        harness_puts("\n");
    }
    *n = c;
}

static void connect(PDEVICE_OBJECT d, PVOID cb)
{
    PORTEXT *x;
    if (!d)
        return;
    x = (PORTEXT *)d->DeviceExtension;
    x->conn.ClassDeviceObject = d;
    x->conn.ClassService = cb;
    x->connected = 1;
    x->enabled = 1;
    x->enable_seen = 1;
}

typedef struct _MBMARK { char tag[8]; void (__cdecl *entry)(void); } MBMARK;
extern const MBMARK g_mbmark;

void __stdcall harness_main(void)
{
    static DRIVER_OBJECT drv;
    static UNICODE_STRING reg;
    NTSTATUS st;
    harness_init();
    harness_puts("HARNESS usosusb start ");
    harness_puthex((ULONG)(ULONG_PTR)g_mbmark.entry);
    harness_puts("\n");
    RtlInitUnicodeString(&reg, L"\\Registry\\Machine\\System\\CurrentControlSet\\Services\\usosusb");
    st = DriverEntry(&drv, &reg);
    harness_puts("HARNESS DriverEntry ");
    harness_puthex((ULONG)st);
    harness_puts("\n");
    connect(g_kbd, (PVOID)kbd_cb);
    connect(g_mou, (PVOID)mou_cb);
    harness_puts("HARNESS worker\n");
    worker(NULL);
}

static UCHAR g_stack[65536];
void __cdecl mb_start(void);

/* run_hub_qemu.py finds the multiboot entry through this marker */
const MBMARK g_mbmark = { "USOSMBH", mb_start };

__declspec(naked) void __cdecl mb_start(void)
{
    __asm {
        cli
        mov esp, offset g_stack
        add esp, 65536
        call harness_main
    hang:
        hlt
        jmp hang
    }
}
