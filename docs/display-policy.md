# Display resolution policy, every family (2026-10-21)

Branch `feat/nt6-display` (base `test/x470-98se-qemu` f28a3fd8). Status:
host-tested (Zig unit tests, answer goldens, compiled selector test, shell
tests, full build). X470 2026-10-21: Vista SP2 PL x64 (CSMWrap) runs 1920x1080
when set manually; the **automatic** choice via USOSRES is **not yet tested on
hardware**; nothing else here has run on the X470. Merged into
`test/x470-98se-qemu`. Earlier details: docs/display-from-profile-2026-10-20.md
(USOSRES, the 9x/NT4/NT3/2000 transport).

## Policy

`display=auto` (and no request in a USOS-made answer) means:

1. the monitor's **native** mode, i.e. the EDID preferred timing (first
   detailed timing descriptor), at 32 bpp, else 16 bpp at that size;
2. the native size is known but the driver lacks it: the largest mode
   that fits inside it ("below-native");
3. no EDID: the **highest** mode the driver lists (no 1920x1080 cap any
   more), 32 bpp preferred;
4. only progressive 60 Hz or driver-default modes; CDS_TEST before every
   apply, DISPLAY.BAK + rollback, DISPLAY.DONE; deferred in a VM.

A fixed profile value (`1024x768`, `1280x1024`, `1920x1080`) is unchanged:
that size, or the next smaller one.

**Windows 9x keeps a 1920x1080 cap** on auto (native or highest,
`USOS_DISPLAY_AUTO_MAX_*` in the 9x USOSRES build). The 9x path is
vmdisp9x (VESA VxD + DIB engine) with double buffering: every candidate
must already pass the VBE list, the INF MODES list and
`2 * pitch * height <= min(VBE memory, VRAMLimit 128 MiB)`, but larger
modes were never run on hardware, 9x GDI/DIB code and old applications
have known limits with very large surfaces, and a wrong VBE timing gives a
black screen that CDS_TEST cannot detect. Lifting the cap needs one X470
run with a 1440p monitor first.

### Where the native size comes from

- **Prep time (all micro-Linux families):** the UEFI menu reads EDID
  (`EFI_EDID_ACTIVE_PROTOCOL`, else `EFI_EDID_DISCOVERED_PROTOCOL`) right
  before it starts the micro-Linux (xp_preparation.zig and
  vista_preparation.zig, which cover XP/2000/2003, Vista/7/2008 CSMWrap,
  9x, NT4, NT3 and the DOS/Win 3.x flow). Reader:
  **`src/platform/uefi/display_native.zig`** (`nativeSize()`, reusable,
  e.g. by the Win7 x64 UefiSeven GOP work on feat/w7x64-native-res; no
  UefiSeven file was touched), pure parser `src/flow/display_edid.zig`.
  It writes `\EFI\USOS\display-native.txt` (`2560x1440\r\n`) or deletes it
  when there is no EDID, so a value from another monitor never stays.
- **Staging:** `usos_display_stage` (tools/display_profile.sh) appends
  `native=WxH` to DISPLAY.TXT when that file is valid (same bounds as the
  parser: 320x200..8192x8192).
- **On the target, NT5 / 6.x fallback:** without `native=`, USOSRES reads
  `HKLM\SYSTEM\CurrentControlSet\Enum\DISPLAY\<id>\<instance>\Device
  Parameters\EDID` and uses it only when every EDID found names the same
  size (tools/display_edid.h, same rules as the Zig parser). It needs a
  driver that does DDC; usosvbe/framebuf and the XDDM VGA driver may not
  fill it, which is why the prep-time value comes first.

USOSRES logs `DISPLAY request=autoxauto native=2560x1440|unknown modes=N`,
`DISPLAY registry EDID found=...`, `DISPLAY selected=WxHxB
reason=native|below-native|highest|exact|smaller|depth16|safe1024`.

## Per family

| Family | Driver USOS uses | Before | After | X470 check |
| --- | --- | --- | --- | --- |
| Windows 1.x / 2.x | Setup's CGA/EGA/VGA drivers (2.03 via USOSV10 stack fix) | 640x480 / EGA / CGA, fixed | unchanged: no VESA driver for 1.x/2.x exists (post-1.0 idea only) | no |
| Windows 3.0a | VGA.DRV | 640x480x16 | unchanged (no SVGA driver on its media) | no |
| Windows 3.1 / WfW 3.11 | VGA.DRV (SUPERVGA.DRV 800x600x16 from the media researched, not wired) | 640x480x16 | unchanged; VBESVGA.DRV below = proposal, user-supplied | proposal only |
| NT 3.1 | VGA | 640x480x16 | unchanged | no |
| NT 3.5 | usosvbe (NT3 build) + framebuf, registry DefaultSettings | 1024x768x16; display only on request | request auto now = native/highest **from the miniport list**; needs the miniport rebuild (as before) | yes, after rebuild |
| NT 3.51 | usosvbe + framebuf, USOSRES service | 1024x768x16; display only on request | request auto = native/highest; still explicit only (3.x hardware regression risk: STOP C0000143 without a valid mode) | yes |
| NT 4.0 WS/Server/EE/TSE | usosvbe + framebuf, USOSRES at first logon | default auto = highest up to 1920x1080 | default auto = **native (prep EDID) / highest** | yes |
| Windows 2000 Pro/Server | usosvbe + framebuf (vesa.cmd), USOSRES | default auto = highest up to 1920x1080 | default auto = **native (prep EDID, else registry EDID) / highest** | yes |
| XP x86 (incl. CSMWrap/PAE, MCE, Tablet) / XP x64 / 2003 x86+x64 | no USOS display driver; Windows' or the driver bundle's driver | Full HD on X470 (user, 2026-10-17); profile value -> WINNT.SIF [Display] | **USOSRES at the first logon** (user decision 2026-10-21): native (prep EDID, else registry EDID) / highest; **nothing when the driver already runs that mode** | yes |
| 95 / 98 / 98 SE / Me | vmdisp9x VESA (USOSVESA.INF) + USOSRES 9x | default auto = highest up to 1920x1080 | default auto = **native up to 1920x1080**, else highest up to 1920x1080 | yes |
| Vista / 7 / 2008 / 2008 R2 CSMWrap | Standard VGA (vgapnp, XDDM) on the CSMWrap VBE | 800x600 | default auto = **native (prep EDID, else registry EDID) / highest**; USOSRES at the first sign-in (below) | yes |
| 8.1 / 10 x86 CSMWrap | Microsoft Basic Display | Windows' choice | unchanged (open) | no |
| Win7 x64 UefiSeven | UefiSeven VBE shim | 1024x768 fullscreen | **stays 1024x768** (user decision 2026-10-22); opt-in two-mode + USOSRES with `Systems\Windows\Windows 7\Unattended\native-res-on.txt` (X470 PASS 2026-10-21, centred-window cosmetics rejected, off by default); no CSMWrap route (reserves 1 logical CPU); full resolution = user's AMD/NVIDIA driver in `DATA\Drivers` (`docs/w7x64-native-res-2026-10-21.md`) | opt-in only |
| Native UEFI Win8+ | GOP / WDDM | Windows' choice | unchanged; a fixed profile value -> `<Display>` | no |

### XP / Server 2003 (user decision 2026-10-21)

`prepare_xp_ntfs_target.sh` (`usos_nt52_display_stage`): with a USOS
settings file (profile or usos-xp.ini; not with the user's own WINNT.SIF)
it stages `USOSRES.EXE` + `DISPLAY.TXT` into the setup folder
(`USOS\XP` on the XP x86 path incl. CSMWrap/PAE, MCE and Tablet, which
route as XP; `USOS\<setup dir>` for Server 2003 and XP x64) and adds
`reg add HKLM\...\Run /v USOSDisplay` to usos-users.cmd before its
`exit /b 0` (run at setup end: by pae.exe on XP x86, by usos-setup.cmd on
the others). Request: a fixed profile `display=WxH` (WINNT.SIF [Display]
still sets it too) as `WxHxauto`, else `autoxauto`, plus `native=` from
the prep EDID. USOSRES on NT5 uses CDS_GLOBAL (the setup-end user is an
administrator) and, before any test/apply, **exits with
`DISPLAY already at the selected mode; unchanged`** when the driver
already runs the chosen mode (the X470 Full HD case with a 1080p
monitor). On the VGA driver (4 bpp) the request stays registered until a
real driver is there. POSReady 2009 (its own VM-install flow,
`\USOS\POSR`) is **not** covered yet.

## Vista / 7 / 2008 CSMWrap chain (commit 1b6fea70)

1. **Answer** (`autounattend.zig`): Vista / 7 / 2008 / 2008 R2 answers get
   two specialize commands guarded by
   `if exist "%SystemDrive%\USOS\NT6\USOSRES.EXE"`: `icacls ... /reset`
   and a Default-hive `HKCU\...\Run USOSDisplay`. A profile request adds
   `<!-- USOS-DISPLAY=WxHxbpp -->` before `<unattend>`.
2. **Staging** (`vista_csmwrap_target.sh` 2b): after mkntfs, when the answer
   has the registration, `\USOS\NT6\USOSRES.EXE` + `DISPLAY.TXT` (request
   or `autoxauto`, plus `native=`) go onto the Windows partition; Setup
   installs into it (InstallTo, no format). A user's own answer file or no
   answer: nothing. Failures are logged and never stop the preparation.
3. **First sign-in**: USOSRES (no CDS_GLOBAL on 6.x), removes its HKCU Run
   value; later users exit at DISPLAY.DONE. Log `C:\USOS\NT6\USOSRES.LOG`.

A fixed profile value renders Shell-Setup `Display` (specialize) for every
6.x+ version; Windows ignores a mode the adapter lacks. Auto writes no
`<Display>`.

## Windows 3.x: VBESVGA.DRV (PluMGMK) evaluation

- **Licence:** the repository has **no LICENSE file**, and the README says
  it is based on the Video 7 SVGA driver of the Win16 DDK (building needs
  the DDK). No redistribution right can be shown, so USOS **must not
  bundle it** (not in git, not as a release asset, not in the compat
  pack). It can only be a **user-supplied** file, like other files whose
  licence does not allow bundling (DATA\Drivers).
- **Modes:** any VBE graphics mode with 1/2/3/4 bytes per pixel
  (8 / 15 / 16 / 24 bit; 24 bit is the default), linear framebuffer when
  available, else banked; its OEMSETUP.INF offers 640x480 .. 1024x768 or
  "Automatic" (the monitor's preferred mode, fallback 1024x768).
- **Requirements:** VBE BIOS (CSMWrap's SeaBIOS passes the card's VBIOS
  VBE through; the RX 560 VBIOS lists LFB modes); `VDDVBE.386` for 386
  enhanced mode (windowed DOS); standard mode with EMM386 needs its
  DOSX.EXE workaround. Author develops on an RX 5500 XT (works); one
  report of an RX 7000 enhanced-mode failure. RX 560 not reported: needs
  an X470 run.
- **Configuration:** SYSTEM.INI `[boot] display.drv=vbesvga.drv`,
  `[386Enh] display=vddvbe.386`, section `[VBESVGA.DRV]` with `Width=`,
  `Height=`, `Depth=` (plus `SwapBuffersInterval`, `fontsize`, ...).
- **Planned integration (not implemented):** if the user puts
  `VBESVGA.DRV` + `VDDVBE.386` (+ fonts) into
  `DATA\Drivers\Windows 3.x\vbesvga\`, dos_csmwrap_target.sh copies them
  to C:\WINDOWS\SYSTEM and edits SYSTEM.INI after Setup:
  `Width/Height` = the prep-time `display-native.txt` (or the profile's
  value), `Depth=24` (16 when 24-bit is missing), no file -> the driver's
  own "Automatic"; VGA.DRV stays as the menu's fallback entry
  (WINMENU.BAT item "VGA"). Windows 1.x / 2.x: no VESA driver exists;
  documentation only (post-1.0 idea).

## Changed files (this round)

- `tools/display_policy.h` (native field, highest without cap, 9x cap macro),
  `tools/display_edid.h` (new), `tools/windows_usos_res.c` (registry EDID,
  log), `tools/tests/display_policy_test.c`.
- `src/flow/display_edid.zig` (new, parser + tests), `src/root.zig`,
  `src/platform/uefi/display_native.zig` (new, EDID reader),
  `xp_preparation.zig` / `vista_preparation.zig` (one call each).
- `tools/display_profile.sh` (`usos_display_native`, native= line),
  comments in nt4/w2k/w9x/vista staging, `tools/tests/test_display_profile.py`.
- en/pl help texts; regenerated boot strings.

## Risks for the X470 runs

- "Highest" without EDID can pick a mode the monitor does not show (no
  EDID on the X470 is unlikely: the RX 560 GOP exposes it; check
  `[DISPLAY_NATIVE]` on the serial log / display-native.txt on the ESP).
- The vgapnp / framebuf mode lists must report 60 Hz or default refresh.
- NT 3.5 needs the rebuilt miniport; NT 3.x stays explicit.
- X470 checks: Vista x64 (Micron) fresh install with a profile; 2000 Pro;
  NT4 WS; 98 SE. Expected `native=1920x1080` with the current monitor,
  `reason=native`, then `DISPLAY applied`.
