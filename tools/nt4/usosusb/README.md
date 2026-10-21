# usosusb

USB keyboard and mouse driver for Windows NT 4.0 (i386) on machines that have
only xHCI USB controllers, such as the X470 run without CSM through CSMWrap.
NT 4.0 has no USB stack, and its `i8042prt` needs a real keyboard controller.
Under CSMWrap a USB keyboard works only while BIOS code runs, because SeaBIOS
polls xHCI from INT 08h. NT never calls that code.

`usosusb.sys` is a legacy (non-PnP) NT 4.0 keyboard and pointer port driver:

* At load it creates `\Device\KeyboardPortN` and `\Device\PointerPortN`. N is the
  first free number, so it comes after any ports `i8042prt` made. It lists both in
  `HARDWARE\DEVICEMAP` and answers the `kbdclass`/`mouclass` connect, enable and
  query IOCTLs the way `i8042prt` does. The pointer port always exists, so
  `mouclass` always has a port to connect to, even with no PS/2 mouse.
* A system thread finds every xHCI controller (PCI class 0C0330) through
  configuration mechanism 1. For each one it takes ownership from the firmware
  (USBLEGSUP, forced if the firmware does not answer within 1 s), resets the
  controller and runs it without interrupts. It uses one command ring and one
  event ring and polls them every 8 to 10 ms.
* Devices on root ports and behind hubs are enumerated: enable slot, address
  device, read the device and configuration descriptors, then take the first HID
  boot keyboard and the first boot mouse interface. For each it configures the
  interrupt IN endpoint and sends SET_CONFIGURATION, SET_PROTOCOL(boot) and
  SET_IDLE(0). Port status events handle plugging and unplugging (see "Hubs").
* Keyboard boot reports become scan code set 1 make/break codes. Pause sends
  E1 1D 45, and AltGr sends E0 38. Typematic repeat is done in the driver
  (`IOCTL_KEYBOARD_SET_TYPEMATIC`). The Caps, Num and Scroll Lock LEDs follow
  `IOCTL_KEYBOARD_SET_INDICATORS` through a HID SET_REPORT. Mouse boot reports
  become relative mouse input with three buttons, plus the wheel when the
  device sends a fourth byte.
* `HKLM\SYSTEM\CurrentControlSet\Services\usosusb\Parameters\Diag` (REG_SZ)
  holds one status line: the controllers found (bus:device.function, port count),
  then one entry per port, such as `p5:s1K-` for slot 1 with a keyboard on
  port 5, or an error tag like `p3-addr4` or `p2-nohid`. Devices behind hubs
  are named by their path, e.g. `p5.2:s3K-` (port 2 of the hub on root port 5).

Not supported: non-boot HID devices, xHCI registers above 4 GiB, and more than 4
controllers or 16 devices (hubs included) per controller.

## Hubs (all builds, 2026-10-21)

USB 2.0 and USB 3.x hubs on root ports and behind other hubs (hubs at tiers
0..3, so devices up to 4 hubs deep): front-panel ports wired through a board
hub, keyboards with a built-in hub, monitor hubs. Written from the public
xHCI 1.2 (Route String, Slot Context hub / TT fields) and USB 2.0 chapter 11 /
USB 3.2 chapter 10 (hub class) descriptions.

* A device with class 09h and a hub interface (alternate setting 0, so a
  multi-TT hub runs single-TT) gets its status change endpoint configured,
  SET_CONFIGURATION, GET_HUB_DESCRIPTOR (29h, or 2Ah for SuperSpeed), then a
  slot-only Configure Endpoint with Hub = 1, Number of Ports and TT Think Time,
  SET_HUB_DEPTH (SuperSpeed hubs), SET_PORT_FEATURE(PORT_POWER) on every port
  and the bPwrOn2PwrGood wait.
* Children get the Route String (4 bits per tier), the root hub port of the
  chain, and for low / full-speed devices on a high-speed hub the TT Hub Slot
  ID / TT Port Number (inherited behind a full-speed hub). Speed from
  wPortStatus (low / full / high; SuperSpeed on a SuperSpeed hub).
* Port changes: the hub's status change endpoint is kept queued (bitmap,
  handled in the worker loop, never inside the event poll), and every hub
  port is read again with GET_PORT_STATUS every 2 s (a hub whose endpoint
  stopped is re-armed). Change bits are cleared with CLEAR_PORT_FEATURE(C_*);
  connect: 100 ms debounce, PORT_RESET, wait for C_PORT_RESET, enumerate.
  Disconnect (or a connect change) drops the device; dropping a hub drops
  everything behind it. A port whose device could not be used is retried only
  after its next connect change (no repeated Diag entries).
* A USB 3 hub is two hubs to xHCI: its SuperSpeed half on a USB 3 root port
  and its USB 2 half on the paired USB 2 root port. Each shows up on its own,
  e.g. `p1:s1H4ss p9:s2H4hs`, and devices appear on the half that matches
  their speed.
* Diag: `p5:s1H4hs` (hub, slot 1, 4 ports, high speed; `fs` / `ss`),
  `p5.2:s3K-/tt1.2` (keyboard behind it through the TT of slot 1 port 2),
  `p5.2-gone`, `p5.3-noen` (port did not enable after reset), `p5-hubd`
  (no hub descriptor), `p5-hubctx<cc>` (hub slot fields refused),
  `p5.1.1.1.1-deep` (a fifth hub tier), `p5.4-full` (no free device entry).
  The Diag value holds up to 1024 characters.
* QEMU harness: `tools/tests/usosusb_hub/run_hub_qemu.py` boots the real
  driver source on QEMU (multiboot, kernel routines from a test shim) with
  qemu-xhci and two nested usb-hubs (keyboard, mouse, stick, hot plug).
  QEMU's usb-hub is a full-speed hub, so the TT fields and SuperSpeed hubs
  are not exercised there (docs/usosusb-hubs-2026-10-21.md).

## Installation (USOS NT4 flow)

`tools/nt4_csmwrap_target.sh` places the driver in `C:\USOS\NT4`. The first logon
in the install VM runs `POST.CMD`, which copies it to `system32\drivers` and
imports `DRIVERS.REG`:

    [HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\usosusb]
    Type=1 (kernel driver), Start=1 (system), ErrorControl=0, Group="Keyboard Port"
    [...\Services\Kbdclass\Parameters] ConnectMultiplePorts=1
    [...\Services\Mouclass\Parameters] ConnectMultiplePorts=1

NT 4.0's ServiceGroupOrder is `... Pointer Port, Keyboard Port, Pointer Class,
Keyboard Class ...`. `i8042prt` is in "Keyboard Port" with tag 2, which
GroupOrderList puts first. usosusb has no tag, so it loads after `i8042prt` and
before both class drivers. The NT 4.0 default is already
`ConnectMultiplePorts=1` for Mouclass but 0 for Kbdclass. Because of `ConnectMultiplePorts`, `KeyboardClass0` and
`PointerClass0`, the only devices NT 4.0's Win32 input thread opens, take input
from both the PS/2 and the USB ports.

## Build

WDK 7.1 in `tools\WinDDK71` or `%WDKROOT%`:

    tools\nt4\usosusb\build.cmd [workdir]

This writes `bin\i386\usosusb.sys`, marked as PE 4.00 by `tools\nt4\pe_nt4_version.py`.
The driver has no C runtime: it uses its own small formatter and inline `cli`/`sti`
around the CF8h/CFCh accesses. `tools/tests/test_nt4_usosusb.py` checks the
imports against the NT 4.0 RTM and SP6a kernels and HALs (export-name fixtures),
the scan code table and the flow wiring.

Licence: GPL-3.0-or-later. Copyright (C) 2026 Maksymilian and the USOS Authors.
Own code, written from the public xHCI 1.2, USB 2.0 and HID 1.11 specifications.

## Vista / Server 2008 SP2 x86 build (NT 6.0)

`build-nt6.cmd` (`-DUSOSUSB_NT6`, WXP environment, PE 5.01) ->
`bin/nt6/i386/usosusb.sys`, for the installed 32-bit Vista / Server 2008 SP2
on xHCI-only machines (no 32-bit NT 6.0 xHCI driver exists). Same port devices
and xHCI code; differences:

* PCI configuration space through `HalGetBusDataByOffset` /
  `HalSetBusDataByOffset` (the HAL's lock; NT 6.0 runs every CPU).
* NT 6.0 `kbdclass` / `mouclass` connect the ports as legacy ports
  (`\Device\KeyboardClassLegacyN`, `\Device\PointerClassLegacyN`, which
  win32k opens); input is passed on once a class driver connected, also
  before its first ENABLE.
* `Parameters\Conn` (REG_SZ), e.g. `kbd c1 e1/1 n42 mou c1 e1/1 n7`:
  connected, ENABLE seen / count, input records passed to the class driver.

Installed offline by the `nt60_usb` step of `tools/windows_x86_csmwrap.cmd`
(x86 CSMWrap WinPE, NT 6.0.6002 only): `system32\drivers\usosusb.sys`, service
Type 1, Start 1, ErrorControl 0, Group "Keyboard Port" (before "Keyboard
Class" / "Pointer Class", where `kbdclass` and `mouclass` are system-start
services). 32-bit NT 6.0 does not enforce kernel-mode signatures, so the
unsigned driver loads. `tools/tests/test_nt60_usosusb.py` checks the imports
against the Server 2008 SP2 x86 kernels and HALs (export-name fixture) and
the flow wiring.

### USB mass storage (NT 6.0 build only)

The same bundled NT6 binary is also used by Windows 7 SP1 x86 when the
optional DATA USB package was not installed and the offline SYSTEM has no
competing xHCI service. Windows 7 has no inbox xHCI stack; the PE10 donor's
USB support does not migrate to the installed OS. This path needs neither
KMDF nor a user driver package. Its 42 imports resolve against both Win7
SP1 x86 kernels and all three HAL variants in the export-name fixture
`tools/tests/data/nt61sp1_x86_exports.txt` (checked by
`tools/tests/test_nt60_usosusb.py`). The HID/BOT limits below
also apply to Windows 7. To install another xHCI stack later, disable the
legacy `usosusb` service first: two drivers must not own the controller.

The NT6 build also drives USB sticks (`USOSUSB_MSC`): the same worker thread
owns the controller for keyboard, mouse and storage, so there is no second
driver and no hand-off between drivers. Written from the public USB Mass
Storage Class Bulk-Only Transport 1.0 and SCSI (SPC / SBC) command
descriptions.

* Enumeration picks interface class 08h, subclass 06h (SCSI transparent),
  protocol 50h (bulk-only), alternate setting 0, with one bulk IN and one bulk
  OUT endpoint (SuperSpeed burst from the companion descriptor). LUN 0 only.
* Bring-up: INQUIRY (direct-access device only), TEST UNIT READY with
  REQUEST SENSE (up to about 10 s), READ CAPACITY(10) (512-byte sectors only,
  up to 2 TiB), MODE SENSE(6) for the write-protect bit. Then LBA 0: a
  superfloppy (boot sector at LBA 0) is one volume; an MBR gives one volume per
  primary partition; a protective MBR leads to the GPT entries. EFI system
  partitions (GPT type or MBR EFh), Microsoft reserved and GPT entries marked
  "no drive letter" / hidden get no volume, as in Windows itself (so the USOS
  stick shows DATA and WORK, its ESP stays untouched). At most 4 volumes per
  stick.
* Transfers: CBW / data / CSW as single-TRB TDs through a 64 KiB bounce
  buffer (READ(10) / WRITE(10) of up to 128 sectors), reset recovery
  (class reset + CLEAR_FEATURE(HALT)) after a transport error, up to 4
  attempts; sense 3Ah = no medium, sense key 7 = write protected.
* Each volume is a non-PnP `\Device\UsosUsbDiskN` (FILE_DEVICE_DISK,
  removable media, direct I/O) answering the disk / mountdev IOCTLs the file
  systems and the mount manager use. READ / WRITE IRPs queue to the worker. A
  second thread tells the mount manager about arrivals
  (`IOCTL_MOUNTMGR_VOLUME_ARRIVAL_NOTIFICATION`; if that gives no drive letter,
  `IOCTL_MOUNTMGR_CREATE_POINT` with the first free letter from D: that
  `MountedDevices` keeps for no other volume) and removals
  (`IOCTL_MOUNTMGR_DELETE_POINTS`). FAT / FAT32 / NTFS mount through the
  normal file system recognizer; Explorer lists the volume as a removable
  disk.
* Hot plug: port status events. Unplug marks the volumes gone (I/O fails with
  STATUS_NO_MEDIA_IN_DEVICE, letter removed); plugging a stick in creates new
  volume devices (32 per boot; device objects are never deleted because a file
  system may still hold the old one).
* `Parameters\Diag` shows `S` and `(<MiB>M wp<0|1> <n>v)` per stick, e.g.
  `p3:s1--S(512M wp0 1v)`; `Parameters\Msc` the mount manager results, e.g.
  `UsosUsbDisk0:0=E` (`=` letter from the mount manager, `+` set by usosusb,
  `UsosUsbDisk0:gone0` after removal).
* Explorer: the volumes are not PnP, so nothing broadcasts
  `DBT_DEVICEARRIVAL` and an open shell does not add the letter. X470
  2026-10-21 (Windows 7 SP1 x86): two hot plugs got `UsosUsbDisk0:0=D` /
  `UsosUsbDisk1:0=D` from the mount manager, but no drive showed in
  Explorer. The usosusb step therefore also installs `usos-drivenotify.exe`
  (`tools/windows_drive_notify.c`, HKLM Run at every logon): it polls the
  drive letters once a second, sends `DBT_DEVICEARRIVAL` /
  `DBT_DEVICEREMOVECOMPLETE` and `SHCNE_DRIVEADD` / `SHCNE_DRIVEREMOVED`, and
  logs each removable letter (file system, label, size or the open error)
  plus `Diag` / `Conn` / `Msc` to `C:\USOS\Logs\usos-drivenotify.log`
  (history across boots; `Diag` itself is rewritten at each boot).
* Limits: sticks behind full-speed hubs run at full speed; polling (no interrupts; about
  40 MB/s read under QEMU TCG), no safe-removal UI (unplug after the copy has
  finished), Explorer may need F5 / reopening after a hot plug (a kernel
  driver cannot broadcast WM_DEVICECHANGE), no media change polling for card
  readers.

## NT 3.1 build

`build-nt31.cmd` (`-DUSOSUSB_NT31`, PE version 3.10) -> `bin/nt31/i386/usosusb.sys`:
`IoCompleteRequest`, `KeRaiseIrql` and `KeLowerIrql` as the NT 3.1 kernel and HAL
export them, plus a Diag line written at once in `DriverEntry`. NT 3.1 needs it as
a boot driver (Start 0): as a system driver its DriverEntry never ran. QEMU
2026-10-10: USB keyboard logon on NT 3.1 (docs/nt31-2026-10-09.md).
