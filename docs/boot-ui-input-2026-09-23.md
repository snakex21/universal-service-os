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
pointer; both work.

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

    powershell -File tools/render_boot_ui_screenshots.ps1 -InputTest [-InputDevices ps2,mouse,tablet,bios]
    python tools/boot_input_linux_qemu.py --out artifacts/boot-input

The bundled OVMF has no USB mouse/tablet driver (its input report lists only
the console splitter), so UEFI pointer tests in QEMU run through the PS/2
mouse; the absolute-pointer path is covered by unit tests only.
