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
| Windows Embedded POSReady 2009 (NT 5.1 core) | the XP x86 X470 driver set (community ACPI, GenAHCI, USB3 xHCI) | VGA 640x480 after FBA until a mode is chosen | **USOSRES at the first logon** (same NT52 contract, `\USOS\POSR`): native (prep EDID, else registry EDID) / highest; **nothing when the driver already runs that mode** | no (host tests only) |
| 95 / 98 / 98 SE / Me | vmdisp9x VESA (USOSVESA.INF) + USOSRES 9x | default auto = highest up to 1920x1080 | default auto = **native up to 1920x1080**, else highest up to 1920x1080 | yes |
| Vista / 7 / 2008 / 2008 R2 CSMWrap | Standard VGA (vgapnp, XDDM) on the CSMWrap VBE | 800x600 | default auto = **native (prep EDID, else registry EDID) / highest**; USOSRES at the first sign-in (below) | yes |
| 8 / 8.1 / 10 x86 CSMWrap (win-x86-uefi-csmwrap) | Microsoft Basic Display on the card's real VBIOS VBE (CSMWrap) | 1024x768 (X470 2026-10-22, Embedded 8.1 Industry Pro x86, NVMe; 1280x1024 / 1920x1080 listed, manual switch works) | default auto = **native (prep EDID, else registry EDID) / highest of the driver's own list**, fullscreen VBIOS modes only; USOSRES at the first sign-in (below) | yes |
| Win7 x64 UefiSeven | UefiSeven VBE shim | 1024x768 fullscreen | **stays 1024x768** (user decision 2026-10-22); opt-in two-mode + USOSRES with `Systems\Windows\Windows 7\Unattended\native-res-on.txt` (X470 PASS 2026-10-21, centred-window cosmetics rejected, off by default); no CSMWrap route (reserves 1 logical CPU); full resolution = user's AMD/NVIDIA driver in `DATA\Drivers` (`docs/w7x64-native-res-2026-10-21.md`) | opt-in only |
| Native UEFI Win8+ | GOP / WDDM | Windows' choice | unchanged; a fixed profile value -> `<Display>` | no |

### XP / Server 2003 (user decision 2026-10-21)

`prepare_xp_ntfs_target.sh` (`usos_nt52_display_stage`): on **every**
install (user decision 2026-10-22: with a USOS settings file, profile or
usos-xp.ini, also without one and with the user's own WINNT.SIF) it
stages `USOSRES.EXE` + `DISPLAY.TXT` into the setup folder
(`USOS\XP` on the XP x86 path incl. CSMWrap/PAE, MCE and Tablet, which
route as XP; `USOS\<setup dir>` for Server 2003 and XP x64) and adds
`reg add HKLM\...\Run /v USOSDisplay` to usos-users.cmd before its
`exit /b 0` (run at setup end: by pae.exe on XP x86, by usos-setup.cmd on
the others). Without usos-xp.ini accounts (no settings file, or a user's
.sif) usos-users.cmd holds only that line (`usos_nt52_display_only_cmd`);
the setup-end hook is USOS's in every case (`[SetupParams] UserExecute`
is a protected key of the .sif merge). Request: a fixed profile
`display=WxH` (WINNT.SIF [Display] still sets it too) as `WxHxauto`, else
`autoxauto`, plus `native=` from the prep EDID. A user's .sif whose
`[Display]` sets `XResolution` keeps its own mode: nothing is staged
(`usos_display_sif_fixed`). Windows 2000 is unchanged (its `vesa.cmd`
already registers auto without settings). USOSRES on NT5 uses CDS_GLOBAL (the setup-end user is an
administrator) and, before any test/apply, **exits with
`DISPLAY already at the selected mode; unchanged`** when the driver
already runs the chosen mode (the X470 Full HD case with a 1080p
monitor). On the VGA driver (4 bpp) the request stays registered until a
real driver is there. POSReady 2009 (its own VM-install flow,
`\USOS\POSR`) is covered below.

### Windows Embedded POSReady 2009 (2026-10-22)

POSReady 2009 is the NT 5.1 core (XP SP3 Embedded), so it uses the XP /
Server 2003 USOSRES contract unchanged, under `\USOS\POSR` instead of
`\USOS\XP` (its own VM-install flow: Windows PE + Setup on partition 1,
`posready_after_setup` copies the folder to `C:\USOS\POSR`):

1. **Staging** (`posready_csmwrap_target.sh`, `usos_posr_display_stage`):
   `USOSRES.EXE` + `DISPLAY.TXT` go into `\USOS\POSR` on the PE partition
   through the same shared helper as the NT52 path
   (`tools/display_profile.sh` `usos_display_stage`), read back from the
   FAT16 image (`mdir`), and read back again after the copy to the Windows
   partition (`posready_after_setup`). Request: `autoxauto` plus `native=`
   from the prep EDID record - POSReady's own answer carries no display
   request (`POSR.SIF` holds `[UserData]` only and the XML has no display
   section). A build without `USOSRES.EXE` logs `DISPLAY USOSRES.EXE
   missing in this build; display unchanged` and continues.
2. **Registration** (`posready_logon.cmd`, the first logon's RunOnce, the
   `usos-users.cmd` analogue):
   `if exist "%S%USOSRES.EXE" reg add HKLM\...\Run /v USOSDisplay ...`
   with `%SystemDrive%\USOS\POSR\USOSRES.EXE` (REG_SZ, same value name as
   XP), logged in `FIRST.LOG` next to the other first-logon lines.
3. **First sign-in**: USOSRES on NT 5.1 uses CDS_GLOBAL, picks only modes
   from the driver's list, full screen, and exits with `DISPLAY already at
   the selected mode; unchanged` when the driver already runs it
   (`display_policy.h` / `display_apply.h`, unchanged by this path). Log
   `C:\USOS\POSR\USOSRES.LOG`.

Status: host-tested only (`tools/tests/test_display_posready.py`: the
staging function on a scratch folder incl. the `native=` record, the
missing-helper path, byte-identical DISPLAY.TXT with the NT52 helper, and
the wiring of the target script, `posready_after_setup` and
`posready_logon.cmd`). No QEMU/X470 POSReady install ran with it; the
actual mode choice is the same code already exercised on XP.

## Vista / 7 / 2008 / 8.x / 10 x86 CSMWrap chain (commit 1b6fea70; 8.x / 10 x86: feat/x86-modern-display)

1. **Answer** (`autounattend.zig`): Vista / 7 / 2008 / 2008 R2 answers and
   Windows 8 / 8.1 / 10 client answers (x86 and amd64: the x86 WinPE
   retargets an amd64-rendered answer, windows_installto.h; not arm64, not
   Windows 11, not Server 2012+, which have no 32-bit release) get
   two specialize commands guarded by
   `if exist "%SystemDrive%\USOS\NT6\USOSRES.EXE"`: `icacls ... /reset`
   and a Default-hive `HKCU\...\Run USOSDisplay`. A profile request adds
   `<!-- USOS-DISPLAY=WxHxbpp -->` before `<unattend>`.
2. **Staging** (`vista_csmwrap_target.sh` 2b): after mkntfs, on **every**
   install (user decision 2026-10-22), `\USOS\NT6\USOSRES.EXE` +
   `DISPLAY.TXT` go onto the Windows partition; Setup installs into it
   (InstallTo, no format). Request: a USOS answer's
   `<!-- USOS-DISPLAY=... -->`, else `autoxauto` (also with no answer and
   with a user's own answer), plus `native=`. A user's own answer with
   `<HorizontalResolution>` (and without the USOS registration) keeps its
   mode: nothing staged (`usos_display_xml_fixed`). Failures are logged and
   never stop the preparation.
2b. **Registration for every answer** (WinPE, after Setup returned, before
   the first boot; `tools/windows_display_register.h`): when `\USOS\NT6`
   holds USOSRES.EXE + DISPLAY.TXT, the installed
   `Users\Default\NTUSER.DAT` is loaded (RegLoadKey) and gets
   `Software\Microsoft\Windows\CurrentVersion\Run USOSDisplay =
   %SystemDrive%\USOS\NT6\USOSRES.EXE` (REG_EXPAND_SZ, read back), and
   `\USOS\NT6` + both files get an explicit DACL (SYSTEM / Administrators
   full, Authenticated Users modify), so the unelevated helper writes its
   log and markers (a USOS answer's `icacls /reset` replaces it later).
   x86 paths (Vista / 7 / 2008 / 8.x / 10 x86): `usos-x86-csmwrap.exe
   display` (cmd step 3g, after usosmpart, before hideesp); Vista / 2008
   x64: `usos-vista-install.exe` on the CSMWrap path, after hideesp. A USOS
   answer's specialize command later writes the same value name again
   (harmless). Never fatal; startup-log lines `display: ...` (x86) /
   `Display: ...` (x64). Why the Default hive and not HKLM Run / RunOnce /
   Active Setup: every profile (the OOBE account, a user answer's built-in
   Administrator, later users) is copied from it; the first sign-in runs
   with the filtered UAC token, which can delete its own HKCU value (USOSRES
   does) but not an HKLM one; later users exit at DISPLAY.DONE and remove
   their own value.
3. **First sign-in**: USOSRES (no CDS_GLOBAL on 6.x), removes its HKCU Run
   value; later users exit at DISPLAY.DONE; a driver already at the chosen
   mode gives `DISPLAY already at the selected mode; unchanged`. Log
   `C:\USOS\NT6\USOSRES.LOG`.

Status of the answer-less registration (2026-10-22, branch
`feat/res-without-answer`): **host-tested only**
(`tools/tests/test_display_register.py`: the helper's display-test on a
scratch HKCU key incl. DACL and idempotence, the 2b block and the NT5
staging as shell tests; `test_display_profile.py` updated). No QEMU or X470
run yet; the offline load of NTUSER.DAT in the WinPE is the same
RegLoadKey pattern as hideesp's SYSTEM hive but not yet exercised on a real
install. Win7 x64 UefiSeven and native UEFI Win8+ are unchanged.

### 8 / 8.1 / 10 x86 (win-x86-uefi-csmwrap, 2026-10-22)

The path runs the same `vista_csmwrap_target.sh` (X86_SELF=1) and the same
prep-time EDID record (`vista_preparation.zig`, before the micro-Linux), so
steps 2-3 were already path-neutral; only the answer lacked the
registration. On NT 6.2 / 6.3 / 10 USOSRES behaves as on 6.0 / 6.1
(`display_compat.h` `usos_display_flags` / `usos_display_user_run`, host
test for 6.2, 6.3, 10 reported as 6.2 without a manifest and as 10.0):
`CDS_UPDATEREGISTRY` without `CDS_GLOBAL` (the first sign-in runs with the
filtered UAC token; display settings are per machine), the user's own
HKCU Run value is removed, and it exits with `DISPLAY already at the
selected mode; unchanged` when the chosen mode is the current one
(`display_apply.h` `usos_display_already`). `C:\USOS` is reset to
inherited ACLs in specialize (Authenticated Users: modify), so the
unmanifested 32-bit helper writes its log and markers without UAC file
virtualization.

**Modes: only the driver's own list, fullscreen.** On this path the
card's real VBIOS switches modes (CSMWrap passes its VBE through) and
Microsoft Basic Display lists exactly those modes. USOSRES picks only from
`EnumDisplaySettings` and applies with `ChangeDisplaySettings`: no
synthetic mode, no centred-window ("square") mode, nothing of the Win7
x64 UefiSeven two-mode handler (user constraint 2026-10-22). A native size
the list lacks gives the largest listed mode inside it (`below-native`),
never an invented one.

X470 expectation (BenQ GL2250H, 1080p): `native=1920x1080` in DISPLAY.TXT,
`DISPLAY selected=1920x1080x32 reason=native test=0`, `DISPLAY applied`.
X470 2026-10-22 (fresh Win10 22H2 x86, Micron NVMe, answer=none): the
registration worked (Default hive Run, first sign-in of the OOBE user,
its HKCU value removed) but USOSRES logged `native=1920x1080 modes=15`
and `DISPLAY no tested mode; current retained` with no `selected=` line:
every listed mode failed the 60 Hz / default-refresh filter before
CDS_TEST (CCD stored VSyncFreq NOTSPECIFIED for 1024x768). Fix: a driver
that reports one refresh value for its whole progressive list sets no
timing of its own, so that value counts (`display_compat.h`
`usos_display_uniform_refresh` / `usos_display_refresh_ok`); lists with
several refresh values keep the strict rule. Every family now logs
`DISPLAY active=WxHxB@Hz refresh=uniform@N|mixed` and one `DISPLAY mode
WxHxB@Hz ok|rejected` line per mode. Host tests only; X470 recheck open.

X470 2026-10-22 (fresh Win7 SP1 PL x86, route win-nt6-x86-uefi-csmwrap,
Micron NVMe, answer=none, build B261022-161932): registration, staging and
the refresh rule worked (`active=800x600x32@1 refresh=uniform@1`, 22 modes
`ok`, `native=1920x1080`), but **every** CDS_TEST returned -1
(DISP_CHANGE_FAILED), the running 800x600x32 too: `no tested mode`,
DISPLAY.DONE, 800x600; a manual 1920x1080 worked. -1 for a listed mode is
win32k refusing the caller (mode change from a desktop that is not the
input desktop: the first-sign-in Run value can start while Winlogon still
shows its screen), not the mode (a missing mode is BADMODE, -2). Fix
(fix/w7x86-res): on NT 6.x+ USOSRES waits up to 120 s until its desktop is
the input desktop (`DISPLAY input desktop ready|not ready after 120
s|check unavailable`); when every test still returns -1 it logs `DISPLAY
every test failed (-1): not the input desktop; request retained for the
next sign-in` and exits without DISPLAY.DONE (HKCU Run kept). **X470
hardware PASS 2026-10-22**: Win7 SP1 x86 without a profile (answer=none)
switched 800x600 -> 1920x1080 a few seconds after logon.
Existing installs (done before this change) have no `\USOS\NT6`: only a
fresh preparation gets it.

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
