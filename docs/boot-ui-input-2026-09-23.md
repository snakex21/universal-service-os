# Boot UI and installer input: wheel, touch, gamepad (2026-09-23)

Shared logic: `src/gui/input_map.zig` (wheel notches, tap vs drag, drag to
rows, stick deadzone + hysteresis, hold-to-repeat, touch mapping/rotation).
Installer: `installer/internal/ui/{wheel,gamepad,touch}.go` and their
`*_windows.go` counterparts.

## UEFI menu

| Input | How |
|---|---|
| Mouse / touchpad | every `EFI_SIMPLE_POINTER_PROTOCOL` handle (the ConIn console splitter is skipped once physical handles exist); wheel = `RelativeMovementZ`, notch size learned per device |
| Touchscreen / tablet | every `EFI_ABSOLUTE_POINTER_PROTOCOL` handle, `AbsoluteMin/Max` mapped to the screen, portrait panels auto-rotated 90; a non-pressure Z axis scrolls |
| PS/2 mouse | direct 8042 with the IntelliMouse wheel, only when the firmware has no PS/2 mouse driver |
| Tap / click | press + release within 1.5% of the short screen side (16 px at 1080p); reported on release |
| Drag | lists scroll with the finger (also a mouse drag); lists that fit move the selection |
| Footer hints | tapping `Enter` / `Esc` acts like the key |
| Keys | arrows, Enter/Space/LF, Esc/Backspace, Page Up/Down, Home/End |

Gamepads have no UEFI protocol. Handheld firmware that supports its
controls pre-boot presents them as keyboard keys (arrows/Enter/Esc) or a
pointer; both work. USB pads are also read directly (next section).

### USB gamepads (2026-09-24)

`src/platform/uefi/usb_gamepad.zig` talks to pads through the firmware's own
USB stack (`EFI_USB_IO_PROTOCOL`, one handle per USB interface); protocol
parsing and the mapping are in `src/gui/usb_gamepad.zig` (unit tested). No
host controller driver, no third-party code.

| Pad | Detected by | Start-up | Reports |
|---|---|---|---|
| Xbox 360 wired and clones, handheld pads that present XInput | interface FF/5D/01 | vendor request C1/01 wValue 0x100 (xpad), LED `01 03 02` | 20 bytes: type 00, len 14 |
| Xbox 360 wireless receiver | FF/5D/81 (one per pad slot) | presence inquiry `08 00 0F C0 ...` | 29 bytes, wired layout from byte 4 |
| Xbox One / Series wired (USB-C) | FF/47/D0, interface 0 only | GIP power-on `05 20 seq 01 00` (+ xpad's vendor quirks: One S/Elite 2, PDP, PowerA, Hori), resent up to 4x every 1.5 s until input arrives | GIP `20` input packets; the guide-button packet is ACKed |
| Generic HID gamepad / joystick (8BitDo, DragonRise, DualShock 4, DualSense, ...) | class 03, not a boot keyboard/mouse, report descriptor with a Joystick/Gamepad/Multi-axis application collection | none | minimal descriptor parser: buttons 1-16, X/Y, hat, D-pad usages, report IDs |

ROG Ally (0B05:1ABE) and Ally X (0B05:1B4C): detection is by interface
class, not by VID/PID, so whichever XInput or GIP interface the built-in
controller exposes is used (Linux drives it with xpad; the MCU's HID
interfaces for hid-asus carry configuration and macro keys, not the
sticks). An 045E:028E XInput pad seen next to the Ally MCU is labelled
"ROG Ally built-in controller". Unverified on the hardware so far: the
report shows exactly what the Ally exposes pre-boot.

Rules:
- The protocol is opened with GET_PROTOCOL only. Interfaces a firmware
  driver holds BY_DRIVER/EXCLUSIVE (`OpenProtocolInformation`) and HID boot
  keyboards/mice are never touched, only listed; DisconnectController is
  never called.
- Reports arrive through `UsbAsyncInterruptTransfer` (callback queues up to
  16 reports per pad; the menu drains them with the TPL raised to NOTIFY).
  If the firmware refuses async transfers the pad is polled with
  `UsbSyncInterruptTransfer` (1 ms timeout, every 8 ms). Transfer errors are
  recovered (cancel, CLEAR_FEATURE(ENDPOINT_HALT), restart) up to 5 times.
- Hot-plug: the handle list is re-read every 2 s; new interfaces are
  inspected, vanished ones are dropped without calling their protocol.
  `input-devices.txt` is rewritten when the set changes.
- All transfers are cancelled before any launch (`manual_summary.start`,
  `manual_view.handover`); a failed launch returning to the menu rescans.
- Layout = micro-Linux: D-pad or left stick move (deadzone 50%/35%
  hysteresis, repeat 400 ms then 90 ms), A and Start = Enter, B and
  Back/View = Esc, LB/RB = Page Up/Down. HID button numbers: Gamepad usage
  uses the Linux BTN_GAMEPAD order (1 A, 2 B, 7/8 LB/RB, 11 Back, 12 Start),
  Joystick usage the DirectInput order (1 A, 2 B, 5/6 LB/RB, 9 Back,
  10 Start), Sony and Logitech D-mode pads square-first (2 = A/Cross,
  3 = B/Circle).
- While a pad is in use the footer names A/B instead of Enter/Esc (tapping
  them still works). The same action from the keyboard within 150 ms of the
  pad (or the reverse) is dropped: handheld firmware can send a pad press
  as a key as well.
- Input test (Power -> Input test) shows the claimed pads with type,
  VID:PID and report counts, and every pad event as
  `pad GIP Xbox Series X|S Controller 045E:0B12: a -> enter`; B twice leaves.

Not supported: Bluetooth pads (no Bluetooth stack pre-boot; the user's
Xbox Wireless Controller 045E:0B13 must be connected with a USB-C cable,
where it is 045E:0B12 GIP), the Xbox Wireless Adapter dongle (proprietary
Wi-Fi protocol with firmware upload), Switch Pro (needs a handshake), pads
whose interface a firmware driver already owns (reported), and the ROG Ally
touch panel (see below).

`input-devices.txt` gains an `[EFI_USB_IO_PROTOCOL]` section: every
interface with handle, VID/PID, device class, interface number, class,
subclass, protocol, endpoints, device path, product name when known,
whether a firmware driver has it open, and what USOS did with it (and for
claimed pads the endpoints, async/polled and the report count).

Handheld touch panels (ROG Ally and similar) are usually I2C-HID devices
(ACPI `PNP0C50` on an AMD/Intel DesignWare I2C controller). Most firmware
has no pre-boot driver for them, so no absolute pointer exists and the
report shows `EFI_ABSOLUTE_POINTER_PROTOCOL handles=0`. Using the panel
there would need an I2C controller driver, ACPI resource lookup and a HID
report parser in USOS; that is not implemented. Touch works in micro-Linux
(i2c-hid-acpi + hid-multitouch) and the installer.

Optional `EFI\USOS\usos-settings.ini` keys (the installer rewrites this file
on install/update/repair, so they must be re-added afterwards):

    wheel_invert=1
    touch_rotation=0|90|180|270

Diagnostics:
- `EFI\USOS\Logs\input-devices.txt` is written at every boot (also printed to
  the serial console between `[INPUT_REPORT BEGIN]`/`END`): every pointer,
  absolute pointer and text input handle with device path, ranges,
  resolution, attributes and whether it is polled.
- Power -> Input test (Test wejścia): live pointer/touch/wheel/key events;
  Esc twice leaves.

## Legacy BIOS menu

PS/2 only (the Core talks to the 8042). The IntelliMouse knock enables the
wheel when the mouse, or the firmware's USB-legacy 8042 emulation, answers
device ID 3/4; each notch moves the selection like an arrow key. Emulations
that answer ID 0 have no wheel. No touch and no gamepad (keyboard only).

## micro-Linux menus (usos-fb-ui --menu)

evdev per SYN_REPORT frame: `REL_WHEEL_HI_RES` (120/notch) or `REL_WHEEL`;
touch via `BTN_TOUCH` + `ABS_X/Y` (or `ABS_MT_*` slot 0); gamepads via
`BTN_SOUTH` (A, accept), `BTN_EAST` (B, back), `BTN_START` (accept),
`BTN_SELECT` (back), `BTN_TL/TR` (page details), D-pad / `ABS_HAT0X/Y` /
left stick (move, repeat 400 ms then 90 ms). Modules in the initramfs:
`xpad`, `hid-multitouch`, `i2c-hid-acpi`, `hid-asus` (loaded on ASUS only);
the AMD GPIO and DesignWare I2C drivers are built into the Alpine
6.18.35 LTS kernel.

## Scale on a 7" 1920x1080 handheld

1080p uses the 1.5x tier: body text 23 px, list rows 69/87 px, buttons and
the footer 66 px. That is the same logical size as Windows at its default
150% on the ROG Ally (text slightly larger than Windows' own 18 px UI font),
and every touch target exceeds 40 effective px at 150% (60 device px).

## QEMU tests

    powershell -File tools/render_boot_ui_screenshots.ps1 -InputTest [-InputDevices ps2,mouse,tablet,usb,bios]
    python tools/boot_input_linux_qemu.py --out artifacts/boot-input

The bundled OVMF has no USB mouse/tablet driver (its input report lists only
the console splitter), so UEFI pointer tests in QEMU run through the PS/2
mouse; the absolute-pointer path is covered by unit tests only.

`usb` boots with QEMU's usb-kbd, usb-mouse, usb-tablet, usb-wacom-tablet and
u2f-emulated on an xHCI controller (QEMU has no gamepad): the report must
list them all (6 interfaces with the hub), claim none, show the keyboard as
bound by OVMF's UsbKbDxe, read the HID report descriptors (tablet 0001:0002,
U2F F1D0:0001), and keyboard navigation must still move the list. The pad
protocols themselves are covered by the unit tests in
`src/gui/usb_gamepad.zig`; `usb-host` passthrough would need the WinUSB
driver on the pad, so it is not used.
