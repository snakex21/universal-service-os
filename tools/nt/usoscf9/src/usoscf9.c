/* usoscf9.sys - full cold reset through port CF9h for the 32-bit Windows 8 /
 * 8.1 / 10 WinPE on the win-x86-uefi-csmwrap route (docs/nvme-nt6-2026-10-12.md
 * section 21.3). Own code; NT legacy (non-PnP) kernel driver, demand start,
 * loaded only by "usos-x86-csmwrap coldreset check" at the very end of the
 * WinPE, after Setup and every offline step.
 *
 * Why: "wpeutil reboot" resets through the FADT reset register (on the X470
 * CF9h = 06h, a warm / hard reset); after it the installed Windows 10 x86 lost
 * the GPU branch (GPP bridge 00:03.1) and reset itself ~30 s into its first
 * boot. A power-off + power button worked (B261031-200222). CF9h 02h then
 * 0Eh (SysRst + RstCmd + FullRst) is the chipset's full reset: the platform
 * goes through S5-like power cycling, PCIe included, without a user action.
 *
 * Device \\.\USOSCF9 (administrators / SYSTEM; WinPE runs as SYSTEM):
 *   IOCTL_USOSCF9_QUERY  out ULONG[2] = { vendor:device of PCI 00:00.0,
 *                        1 if the full reset is supported (AMD 1022h /
 *                        Intel 8086h host bridge) else 0 }
 *   IOCTL_USOSCF9_RESET  in = the 16-byte magic "USOSCF9FULLRESET";
 *                        supported chipset only; writes CF9h 02h, 0Eh and
 *                        returns STATUS_UNSUCCESSFUL if the machine is still
 *                        running 2 s later (the caller falls back to the
 *                        power-off). The caller flushes and dismounts first.
 */
#include <ntddk.h>

#define USOSCF9_TYPE 0x8F39
#define IOCTL_USOSCF9_QUERY CTL_CODE(USOSCF9_TYPE, 0x900, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_USOSCF9_RESET CTL_CODE(USOSCF9_TYPE, 0x901, METHOD_BUFFERED, FILE_WRITE_ACCESS)

static const UCHAR g_Magic[16] = { 'U','S','O','S','C','F','9','F','U','L','L','R','E','S','E','T' };
static PDEVICE_OBJECT g_Device;

DRIVER_INITIALIZE DriverEntry;
DRIVER_UNLOAD UsosCf9Unload;
__drv_dispatchType(IRP_MJ_CREATE) __drv_dispatchType(IRP_MJ_CLOSE) DRIVER_DISPATCH UsosCf9CreateClose;
__drv_dispatchType(IRP_MJ_DEVICE_CONTROL) DRIVER_DISPATCH UsosCf9Control;

static ULONG HostBridgeId(void)
{
    ULONG id = 0xFFFFFFFF;
    PCI_SLOT_NUMBER slot;
    slot.u.AsULONG = 0;  /* device 0, function 0 */
    if (HalGetBusDataByOffset(PCIConfiguration, 0, slot.u.AsULONG, &id, 0, sizeof(id)) != sizeof(id)) id = 0xFFFFFFFF;
    return id;
}

static BOOLEAN Supported(ULONG id)
{
    USHORT vendor = (USHORT)(id & 0xFFFF);
    return vendor == 0x1022 || vendor == 0x8086;
}

static BOOLEAN SameMagic(const UCHAR *p)
{
    ULONG i;
    for (i = 0; i < sizeof(g_Magic); i++) if (p[i] != g_Magic[i]) return FALSE;
    return TRUE;
}

NTSTATUS UsosCf9CreateClose(PDEVICE_OBJECT Device, PIRP Irp)
{
    UNREFERENCED_PARAMETER(Device);
    Irp->IoStatus.Status = STATUS_SUCCESS;
    Irp->IoStatus.Information = 0;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return STATUS_SUCCESS;
}

NTSTATUS UsosCf9Control(PDEVICE_OBJECT Device, PIRP Irp)
{
    PIO_STACK_LOCATION sp = IoGetCurrentIrpStackLocation(Irp);
    ULONG code = sp->Parameters.DeviceIoControl.IoControlCode;
    ULONG in = sp->Parameters.DeviceIoControl.InputBufferLength, out = sp->Parameters.DeviceIoControl.OutputBufferLength;
    PULONG buffer = (PULONG)Irp->AssociatedIrp.SystemBuffer;
    NTSTATUS status = STATUS_INVALID_DEVICE_REQUEST;
    ULONG info = 0, id;
    LARGE_INTEGER wait;
    UNREFERENCED_PARAMETER(Device);
    if (code == IOCTL_USOSCF9_QUERY) {
        if (out < 2 * sizeof(ULONG) || !buffer) status = STATUS_BUFFER_TOO_SMALL;
        else { id = HostBridgeId(); buffer[0] = id; buffer[1] = Supported(id) ? 1 : 0; info = 2 * sizeof(ULONG); status = STATUS_SUCCESS; }
    } else if (code == IOCTL_USOSCF9_RESET) {
        if (in != sizeof(g_Magic) || !buffer || !SameMagic((const UCHAR *)buffer)) status = STATUS_ACCESS_DENIED;
        else if (!Supported(HostBridgeId())) status = STATUS_NOT_SUPPORTED;
        else {
            DbgPrint("usoscf9: CF9h full reset (02h, 0Eh)\n");
            WRITE_PORT_UCHAR((PUCHAR)0xCF9, 0x02);
            KeStallExecutionProcessor(50);
            WRITE_PORT_UCHAR((PUCHAR)0xCF9, 0x0E);
            wait.QuadPart = -20000000LL;  /* 2 s */
            KeDelayExecutionThread(KernelMode, FALSE, &wait);
            status = STATUS_UNSUCCESSFUL;  /* still running: no full reset */
        }
    }
    Irp->IoStatus.Status = status;
    Irp->IoStatus.Information = info;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return status;
}

VOID UsosCf9Unload(PDRIVER_OBJECT Driver)
{
    UNICODE_STRING link;
    UNREFERENCED_PARAMETER(Driver);
    RtlInitUnicodeString(&link, L"\\DosDevices\\USOSCF9");
    IoDeleteSymbolicLink(&link);
    if (g_Device) IoDeleteDevice(g_Device);
    g_Device = NULL;
}

NTSTATUS DriverEntry(PDRIVER_OBJECT Driver, PUNICODE_STRING Registry)
{
    UNICODE_STRING name, link;
    NTSTATUS status;
    UNREFERENCED_PARAMETER(Registry);
    RtlInitUnicodeString(&name, L"\\Device\\USOSCF9");
    RtlInitUnicodeString(&link, L"\\DosDevices\\USOSCF9");
    status = IoCreateDevice(Driver, 0, &name, FILE_DEVICE_UNKNOWN, FILE_DEVICE_SECURE_OPEN, TRUE, &g_Device);
    if (!NT_SUCCESS(status)) return status;
    status = IoCreateSymbolicLink(&link, &name);
    if (!NT_SUCCESS(status)) { IoDeleteDevice(g_Device); g_Device = NULL; return status; }
    Driver->MajorFunction[IRP_MJ_CREATE] = UsosCf9CreateClose;
    Driver->MajorFunction[IRP_MJ_CLOSE] = UsosCf9CreateClose;
    Driver->MajorFunction[IRP_MJ_DEVICE_CONTROL] = UsosCf9Control;
    Driver->DriverUnload = UsosCf9Unload;
    return STATUS_SUCCESS;
}
