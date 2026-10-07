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
* Devices on root ports are enumerated: enable slot, address device, read the
  device and configuration descriptors, then take the first HID boot keyboard and
  the first boot mouse interface. For each it configures the interrupt IN
  endpoint and sends SET_CONFIGURATION, SET_PROTOCOL(boot) and SET_IDLE(0).
  Port status events handle plugging and unplugging.
* Keyboard boot reports become scan code set 1 make/break codes. Pause sends
  E1 1D 45, and AltGr sends E0 38. Typematic repeat is done in the driver
  (`IOCTL_KEYBOARD_SET_TYPEMATIC`). The Caps, Num and Scroll Lock LEDs follow
  `IOCTL_KEYBOARD_SET_INDICATORS` through a HID SET_REPORT. Mouse boot reports
  become relative mouse input with three buttons, plus the wheel when the
  device sends a fourth byte.
* `HKLM\SYSTEM\CurrentControlSet\Services\usosusb\Parameters\Diag` (REG_SZ)
  holds one status line: the controllers found (bus:device.function, port count),
  then one entry per port, such as `p5:s1K-` for slot 1 with a keyboard on
  port 5, or an error tag like `p3-addr4` or `p2-nohid`.

Not supported: devices behind a USB hub (this includes keyboards with a
built-in hub), non-boot HID devices, xHCI registers above 4 GiB, and more than 4
controllers or 16 devices per controller.

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
