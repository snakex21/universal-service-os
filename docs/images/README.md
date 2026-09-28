# Documentation screenshots

All images come from the preview renderer (fake data), QEMU/OVMF/SeaBIOS
test runs on virtual disks, or the installer UI demo (fake drives, never
opens a disk). No photos of a monitor, no data from a real PC. Names
ending in `-pl` are the Polish UI; the rest are English.

Sources, as referenced in the table:

- **renderer**: `tools\zig\zig.exe build ui-preview --cache-dir tools/cache/zig --prefix zig-out/ui-preview-docs`
  (with `ZIG_GLOBAL_CACHE_DIR=tools/cache/zig-global`), then
  `zig-out/ui-preview-docs/bin/usos-ui-preview.exe <dir> 1280 800 <lang.bin|-> <theme>`.
  Polish `lang.bin`: `go run ./cmd/usos-i18n-gen -root .. -export pl -out DIR` in `installer/`
  (file `DIR/EFI/USOS/lang.bin`). Themes: built-in names (`default`, `dark`, `light`,
  `high-contrast`, `retro`) or `src/gui/themes/usos-*.ini`. Screen file in brackets.
- **answer-screen**: `tools/tests/run_uefi_answer_screen.ps1` (QEMU + OVMF, copy of the
  boot-ui test VHD; `-Language pl -OutputDirectory <dir>` for Polish). Shot in brackets.
- **linux-iso**: `tools/tests/linux_iso/` QEMU runs, `tools/tests/artifacts/linux-iso/menu/<run>/NN.png`.
- **vista-ux**: CSMWrap Vista UX run on the test VHD in `tools/tests/artifacts/csmwrap-vista-ux`
  (QEMU, target disk `target.qcow2`, S/N `USOSTARGET`).
- **uefi-shell**: UEFI Shell QEMU run, `artifacts/uefi-shell/shell-sb-off-*.png`.
- **boot-ui (BIOS)**: `tools/render_boot_ui_screenshots.ps1` (SeaBIOS, Legacy BIOS Core UI),
  `artifacts/boot-ui/bios-*.png`.
- **uidemo**: `go build ./cmd/usos-installer-uidemo` in `installer/`, then
  `usos-installer-uidemo.exe -shots <dir> -dpi 96 -lang en|pl -suffix -en|-pl`.

PNG post-processing: 256-colour palette (no dither) + `optimize=True` with Pillow, except
the two distro desktop screens (full colour).

| File | What it shows | Source | Language |
|---|---|---|---|
| menu-home.png | Main menu (home), default theme | renderer, default [01-home] | en |
| menu-home-pl.png | Main menu (home), default theme | renderer, default, pl lang.bin [01-home] | pl |
| menu-home-dark.png | Main menu, built-in Dark theme | renderer, `dark` [01-home] | en |
| menu-home-light.png | Main menu, built-in Light theme | renderer, `light` [01-home] | en |
| menu-home-retro.png | Main menu, built-in Retro (BIOS blue) theme | renderer, `retro` [01-home] | en |
| menu-home-high-contrast.png | Main menu, built-in High contrast theme | renderer, `high-contrast` [01-home] | en |
| menu-home-sunset.png | Main menu, user theme usos-sunset | renderer, `src/gui/themes/usos-sunset.ini` [01-home] | en |
| menu-home-sunset-pl.png | Main menu, user theme usos-sunset | renderer, usos-sunset.ini, pl lang.bin [01-home] | pl |
| menu-home-ocean.png | Main menu, user theme usos-ocean | renderer, `src/gui/themes/usos-ocean.ini` [01-home] | en |
| menu-home-forest.png | Main menu, user theme usos-forest | renderer, `src/gui/themes/usos-forest.ini` [01-home] | en |
| themes-grid.png | 2x2 grid: Dark, Light, Retro, Sunset (top-left to bottom-right) | renderer, composed with Pillow | en |
| windows-list.png | Windows systems list (ready / no image / requires BIOS / experimental badges) | renderer, default [02-systems] | en |
| windows-list-pl.png | Windows systems list | renderer, pl [02-systems] | pl |
| windows-list-qemu.png | Windows systems list on a real boot (test disk) | answer-screen [answer-19-systems] | en |
| windows-list-qemu-pl.png | Windows systems list on a real boot (test disk) | answer-screen `-Language pl` [answer-19-systems] | pl |
| windows-xp-images.png | Image list of one system (Windows XP ISO found on DATA) | answer-screen [answer-01-xp-images] | en |
| windows-boot-method.png | Boot method for a Windows ISO (Automatic / ISO / WIMBoot / Chainload) | renderer [03-methods] | en |
| windows-boot-method-pl.png | Boot method for a Windows ISO | renderer, pl [03-methods] | pl |
| windows-summary.png | "Ready to start" summary | renderer [04-summary] | en |
| windows-summary-pl.png | "Ready to start" summary | renderer, pl [04-summary] | pl |
| windows-progress.png | Preparation progress (copying WIM, bytes, speed, ETA) | renderer [05-progress] | en |
| windows-progress-pl.png | Preparation progress | renderer, pl [05-progress] | pl |
| answer-profiles.png | Unattended setup: no answer file / usos-xp.ini / .sif / add a profile | answer-screen [answer-02-answer-default] | en |
| answer-profiles-pl.png | Unattended setup (answer profiles) | answer-screen `-Language pl` [answer-02-answer-default] | pl |
| profile-editor.png | Answer-profile editor, accounts and regional fields filled | answer-screen [answer-13-profile-filled] | en |
| profile-editor-pl.png | Answer-profile editor, accounts and regional fields filled | answer-screen `-Language pl` [answer-13-profile-filled] | pl |
| profile-editor-appearance.png | Answer-profile editor: edition, local account, "Appearance and extras" section | answer-screen [answer-22-edition-typed] | en |
| profile-editor-extras.png | Answer-profile editor: appearance and extras toggles, theme, screen resolution | answer-screen [answer-14-profile-extras] | en |
| profile-editor-extras-pl.png | Answer-profile editor: "Wygląd i dodatki" toggles, theme, screen resolution (section heading scrolled off) | answer-screen `-Language pl` [answer-14-profile-extras] | pl |
| profile-keyboard.png | Answer-profile editor with the on-screen keyboard | answer-screen [answer-12-profile-keyboard] | en |
| profile-keyboard-pl.png | Answer-profile editor with the on-screen keyboard | answer-screen `-Language pl` [answer-12-profile-keyboard] | pl |
| theme-editor.png | Theme editor with live preview and contrast check | answer-screen [answer-25-theme-contrast-ok] | en |
| theme-editor-pl.png | Theme editor with live preview and contrast check | answer-screen `-Language pl` [answer-23-theme-contrast-ok; numbering differs from en] | pl |
| tools-theme.png | Utilities -> Theme list (built-in themes + user theme) | renderer [15-tools-theme] | en |
| tools-theme-pl.png | Utilities -> Theme list | renderer, pl [15-tools-theme] | pl |
| linux-list.png | Linux distributions list (UEFI) | linux-iso [nav/01] | en |
| linux-ubuntu-images.png | Ubuntu image list (server and desktop ISOs) | linux-iso [nav/02] | en |
| linux-answer-profiles.png | Linux unattended setup (USOS profile for Ubuntu autoinstall) | linux-iso [ans-ubuntu/01] | en |
| linux-fedora-live.png | Fedora Workstation Live booted from its ISO by USOS | linux-iso [fedora/03] | en (distro UI) |
| linux-ubuntu-installer.png | Ubuntu Desktop installer booted from its ISO by USOS | linux-iso [ubuntu-desktop/04] | en (distro UI) |
| disk-pick-pl.png | Target disk choice in the preparation environment (Windows Vista, QEMU disk) | vista-ux [shots/10-run-04] | pl |
| disk-confirm-pl.png | XP-style "Format the whole disk?" confirmation with disk details | vista-ux [shots/21-confirm] | pl |
| utilities-uefi-shell.png | Utilities menu with the UEFI Shell entry | uefi-shell [shell-sb-off-01-utilities] | en |
| uefi-shell.png | UEFI Shell started from USOS (help banner, `map -r`, `ls` of the tools folder), cropped | uefi-shell [shell-sb-off-04-ls-tools] | en |
| bios-menu.png | Legacy BIOS menu (Core UI), home | boot-ui BIOS [bios-en-01-home] | en |
| bios-menu-pl.png | Legacy BIOS menu (Core UI), home | boot-ui BIOS [bios-pl-01-home] | pl |
| bios-windows-list.png | Legacy BIOS menu, Windows list | boot-ui BIOS [bios-en-02-systems] | en |
| installer-mode.png | Windows installer: choose an operation (install / update / repair / uninstall) | uidemo [01-mode] | en |
| installer-mode-pl.png | Windows installer: choose an operation | uidemo `-lang pl` [01-mode] | pl |
| installer-devices.png | Windows installer: drive list with safety-policy rejections | uidemo [07-install-devices-selected] | en |
| installer-devices-pl.png | Windows installer: drive list | uidemo `-lang pl` [07-install-devices-selected] | pl |
| installer-confirm.png | Windows installer: destructive-operation confirmation (type the drive name) | uidemo [09-install-confirm-ready] | en |
| installer-confirm-pl.png | Windows installer: destructive-operation confirmation | uidemo `-lang pl` [09-install-confirm-ready] | pl |
| installer-progress.png | Windows installer: installation progress | uidemo [10-install-progress] | en |
| installer-progress-pl.png | Windows installer: installation progress | uidemo `-lang pl` [10-install-progress] | pl |
| installer-done.png | Windows installer: installation completed and verified | uidemo [12-install-final-success] | en |
| installer-done-pl.png | Windows installer: installation completed and verified | uidemo `-lang pl` [12-install-final-success] | pl |

Note: the Polish answer-screen run reports check failures (the harness matches English
screen titles), but every screenshot it took is a normal capture; its edition steps are skipped in Polish,
so there is no Polish shot of the "Wygląd i dodatki" section heading itself.
