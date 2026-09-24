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

### Footer hints: last input wins (2026-09-24)

The footer names Enter/Esc after keyboard input and A/B after pad input
(same key names as micro-Linux `footerHints`), and redraws as soon as the
style changes. Rules and IDs: `src/gui/handheld.zig` (unit tested, shared
with micro-Linux); UEFI device side: `src/platform/uefi/text_input.zig`.

Evidence (ROG Ally, `artifacts/ally-logs/input-devices.txt`): AMI delivers
the built-in pad as keys from the controller MCU 0B05:1ABE interface 0 (HID
boot keyboard, `USB(0x2,0x0)`), while the XInput interface 045E:028E stays
silent (reports_so_far=0). Reading only ConIn cannot tell that apart from a
keyboard, so:

- Every `EFI_SIMPLE_TEXT_INPUT_EX` handle except the ConIn splitter
  (`console_in_handle`) is read directly with ReadKeyStrokeEx; ConIn is read
  afterwards for anything else (e.g. devices with only SimpleTextInput).
  Handles are re-listed every ~2 s (hot-plug) and re-validated before each
  read.
- Classification per handle: `EFI_USB_IO_PROTOCOL` on the same handle (EDK2
  and AMI install text input on the USB interface handle), else
  LocateDevicePath to an exact USB_IO match; the device descriptor VID/PID
  of a known handheld controller = pad: 0B05:1ABE ROG Ally, 0B05:1B4C ROG
  Ally X, 28DE:1205 Steam Deck, 17EF:6182..6185 Legion Go, 0DB0:1901..1903
  MSI Claw (Legion Go and Claw IDs from Linux drivers / Handheld Daemon,
  not verified on hardware). An ACPI PNP03xx node = the PS/2 (EC) keyboard.
- SMBIOS (SMBIOS3 first, then 2.x) type 1/2: ROG Ally RC71L / Ally X
  RC72LA, Valve Jupiter/Galileo, Lenovo 83E1 or "Legion Go" (Legion Go S:
  83L3/83N6/83Q2/83Q3), MSI "Claw ...". On such a handheld the hints start
  as A/B.
- Key from a pad handle = A/B; from any other identified keyboard =
  Enter/Esc. Unattributed keys (ConIn only, a handle without a device path,
  or the PS/2 keyboard on a handheld) keep the current style on a handheld
  unless a pad cannot produce them (printable characters other than Space);
  on other machines they mean Enter/Esc as before.
- A claimed USB pad (XInput/GIP/HID path) = A/B. Mouse clicks and wheel =
  Enter/Esc, except a touch tap on a handheld (keeps the style) and clicks
  from a handheld controller's own pointer interface (e.g. the Ally MCU's
  `USB(0x2,0x1)` stick-as-mouse) = A/B. Footer hint taps keep the style.
- The same menu action from the keyboard channel and the USB pad path within
  150 ms is still dropped once (dedupe by channel, whatever the key's origin).
- `input-devices.txt` adds `smbios:`, `handheld=yes (name)|no`,
  `hints_now=`, and per text input handle `read_directly=yes class=pad|
  keyboard (...) vid= pid=` (or `class=fallback` for the splitter).

micro-Linux (`fb_menu_input.zig`): EVIOCGID gives each evdev device's bus
and VID/PID; keys from a known handheld controller (USB/Bluetooth) = A/B,
other keyboards = Enter/Esc, the i8042 keyboard on a handheld is
unattributed (same rule as UEFI, `evdevKeyboardOnly`); gamepad buttons and
sticks = A/B; keys without a menu action (volume, power) change nothing. The
handheld default comes from `/sys/class/dmi/id` (sys_vendor, product_name,
product_version, board_vendor, board_name; logged as `[FB_MENU] dmi ...`).
Pointer moves switch to Enter/Esc except touch on a handheld and a handheld
controller's pointer. The menu redraws when the style changes; footer taps
are hit-tested against the hints on screen.

### Controller glyphs in the footer (2026-09-24)

`src/gui/ui.zig` (`PadButton`, `padButtons`, `Ui.keycap`) draws a hint key
made only of controller button names, joined with `/`, the way the Windows
installer does (`installer/internal/ui/pad_hints_windows.go`):

| Key | Drawn as |
|---|---|
| `A` `B` `X` `Y` | round face button, Xbox colours from the installer palette: A green (Success `#4AD68C`), B red (Danger `#F05A5F`), X blue `#4A9BF0`, Y yellow (Warning `#F2B13C`), dark letter `#0B0F14` |
| `LB` `RB` `LT` `RT` `LS` `RS` | pill (fully rounded, PanelAlt fill, BorderStrong ring), `LB/RB` = two pills |
| `Start` / `Menu` | pill with three bars |
| `View` | pill with two overlapping windows |
| `DPad` | cross |

Everything is anti-aliased with the `paint.zig` primitives (4x4 coverage,
integer maths, so the i386 BIOS Core can use it) and sized with `px()`
(24 logical px face buttons, 22 px pills). Any other key (`Enter`, `Esc`,
`PgUp/PgDn`, arrows, `D`) keeps the key-cap style. `footerHit` uses the same
widths, so tapping a glyph still works. While a pad is in use the UEFI menu
(`input.moveKey`) and micro-Linux (`fb_menu_render.footerHints`) show the
D-pad glyph instead of the arrow key cap; the BIOS menu has no pad input and
is unchanged. Previews: `zig build ui-preview`, screens `07-pad-hints` and
`08-pad-glyphs` (artifacts/boot-ui/pad-hints).

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
