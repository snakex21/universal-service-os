# Display from an answer profile — 2026-10-20

Implemented on `codex/rozdzielczosc-z-profilu`, base
`c76b56926fab66777ef044dfc1ab3a417b50ec97`. Status: host tested; all target
families need X470 validation. NT 3.5 additionally needs a miniport rebuild.
Nothing was deployed, pushed or merged. No full Windows installation was run.

## Profile and defaults

`display=auto|1024x768|1280x1024|1920x1080` and
`display_bpp=auto|32|16`. The old resolution enum is deliberately retained;
`800x600` remains an invalid profile value. This avoids changing XP/2003 parsing
or their display output. Depth is ignored outside the new legacy targets.

No `display` request means the previous defaults, byte for byte. An explicit
`display=auto` differs from omission for the supported legacy systems. A depth
alone also requests selection (`auto` resolution). An empty `display=` clears
the explicit flag. In the editor, **Unchanged** clears the request and depth;
**Auto** requests the highest available resolution up to 1920x1080. Editing a
profile from another system preserves its hidden depth/explicit-auto settings.
English/Polish labels are generated from the normal translation catalogues;
other languages use the existing English fallback.

The same C selector (`tools/display_policy.h`) serves the target tool and
compiled host tests. For a fixed request it tries exact dimensions at the
requested depth (auto prefers 32), exact dimensions at 16, then the largest
bounded mode at the preferred depth, then at 16. Auto prioritizes area, then
depth. If none qualifies: offered 1024x768x16, otherwise current mode unchanged.
Modes must have valid dimensions and 16/32 bpp. Win32 also excludes interlaced
and non-default/non-60 Hz modes. No GOP/EDID size is guessed.

## Hardware execution

`USOSRES.EXE` is a windowless own-code GPL-3.0-or-later Win32 tool, no CRT.
It keeps `DISPLAY.TXT`, `USOSRES.LOG`, `DISPLAY.BAK`, `DISPLAY.DONE` beside its
executable. Registry writes are only the requested OS display configuration
and its startup registration. Logs/configuration are not stored in the profile.

It enumerates the current mode (required for rollback), then available modes.
For each selected candidate it calls `ChangeDisplaySettingsA(CDS_TEST)` before
any apply. A failed test rejects that candidate and tries the next. Saving
the old mode to DISPLAY.BAK is mandatory. Failed apply attempts restore both
the active and persisted old mode, with the rollback result logged. A successful
request or an exhausted list creates and flushes DISPLAY.DONE before removing
its Run registration/disabling its own service. An inability to log or back up
leaves the display unchanged. VM deferral retains the startup registration.

The production transaction in `display_apply.h` is exercised with fake display
callbacks: no apply after failed tests, no apply after backup failure, rollback
after an apply failure, and the restart-required result.

| Family | Channel / trigger | Status |
| --- | --- | --- |
| 2000 Pro/Server x86 | NT5 settings → C:\USOS\W2K; VESA setup-end script imports Run registration | host-tested, needs-X470 |
| NT4 WS/Server/Enterprise/TSE | `;USOS-DISPLAY=` → C:\USOS\NT4; VESA.REG imported by POST.CMD | host-tested, needs-X470 |
| NT 3.51 WS/Server | comment → C:\USOS\NT3; usosnt3 registers the interactive `usosdisplay` service | host-tested, needs-X470 |
| NT 3.5 WS/Server | same service; validated miniport list → DefaultSettings.* → one automatic restart | source/consumer host-tested, needs-rebuild, needs-X470 |
| 95/98 FE/98 SE/Me | comment → C:\USOS9X; MSBATCH [Install] AddReg creates persistent Run entry | host-tested, needs-X470 |

2000's initial VESA settings remain 1024x768x16 and `vesa-off.txt` still skips
everything. NT4 POST.CMD and NT3's original usosnt3 post service run in the
installation VM. The new helper checks the CPUID hypervisor flag before any
mode selection and defers. A CPUID-only SeaBIOS/TCG probe confirmed that the
existing `-cpu pentium3` model exposes that flag. No Windows VM was booted.
A VM configured deliberately to hide that flag is not covered by this check.

## NT 3.5 versus 3.51

Names-only export lists were generated read-only from the user's original
NT3.5/NT3.51/NT4 RTM media. `user32.dll` NT3.51 and NT4 RTM export both A/W
forms of EnumDisplaySettings and ChangeDisplaySettings; NT3.5 exports neither.
The tool looks up these APIs dynamically; every static import of it and the
rebuilt usosnt3 resolves on all three original media lists. This is stricter
for the NT4 static imports than requiring SP6a alone; an SP6a user32 dump was
not generated. Fixtures: `tools/tests/data/nt{35,351,4rtm}_display_exports.txt`.

Only the NT3 miniport source publishes its validated modes as `Device0\UsosVbeModes`:
versioned **REG_BINARY**, magic UDM1, DWORD count, count records of three DWORDs
(width/height/depth), no pointers. VideoPortSetRegistryParameters stores binary
data, so the brief's proposed REG_SZ would be incorrect. FindAdapter clears
the prior list; queries publish the current list. The consumer requires that
the driver is running, checks type/magic/count/exact length, and never writes
an unlisted mode. It snapshots all three DefaultSettings DWORDs and backs up
the old mode before writing. Partial write failure restores all three values.
An already matching mode requires no restart. Missing evidence retains the
safe mode and logs the deferred request.

The NT4 driver binary is untouched. `build-nt3.cmd` copies the shared handoff
header into its build directory. WDK 7.1 was not present in the supplied tools
locations, so the NT3 miniport was **not** rebuilt. Its existing binary cannot
publish the new list: NT3.5 remains safe but cannot apply a requested new mode
until the reviewer builds it. NT3.51 uses the available Win32 APIs instead.
NT3.1 receives no request or new startup helper.

## 9x decision and memory checks

The requested DOS selector was replaced by a read-only **Win16 VBE collector**
invoked by the windowless Win32 helper. This covers Me's lack of AUTOEXEC.BAT
execution. It uses DPMI 0300h to call VBE 4F00/4F01, never 4F02/4F07. No
unverified mode is written into Config\0001 or INF DEFAULT before hardware
enumeration. Existing VESA95 binding and the INF startup mode stay intact.

Each candidate must appear in all three lists: fresh VBE results, Win32 driver
enumeration, and USOSVESA.INF MODES. The collector checks LFB/direct colour,
planes, 565/888 masks and pitch. VBE 3 linear fields are used when available.
The helper rejects stale/truncated output and a missing/duplicate/invalid
VRAMLimit. The shared selector enforces
`2 * pitch * height <= min(VBE TotalMemory * 64 KiB, INF VRAMLimit, 128 MiB)`
without multiplication overflow. Duplicate VBE modes use the worst pitch and
smallest memory. No valid evidence means no change. This path is built and
host-tested, but the Win16 VBE call from a running 9x desktop still needs a
hardware test; a QEMU VBE list would not establish RX 560 support.

## Build / test / handoff

With USOS_ZIG and USOS_WATCOM pointing at existing toolchains, run
`python -I -B tools/build_windows_usos_res.py`. It builds the NT helper, updated
USOSNT3.EXE, 9x helper and Win16 USOSVBI.EXE under zig-out. All caches and temp
files stay there or in tools/cache. No implicit compiler download. The micro
Linux builder stages those builds instead of an old usosnt3 binary. The NT3
miniport separately needs `build-nt3.cmd` and WDKROOT.

Validation: 562 Zig tests + x86_64 UEFI build; 137 Python tests covering new
logic and existing W2K/NT/9x paths; the expanded final display suite has 11
tests including the CPUID-only probe. Answer-render matrix passed, with only
the 2000 display golden and its matrix rows added. XP/2003 goldens and all
default-profile goldens remain byte-identical. No full initramfs/payload,
Windows installation or UEFI click-through VM was run.

Review/integration first, then one X470/Micron 3400 run each for 2000 Pro,
NT4 WS, NT3.51, 98 SE, Me and 95, using `display=1920x1080` and
`display_bpp=auto`. Expected local log: `DISPLAY request=1920x1080xauto modes=...`,
`selected=... reason=exact|depth16|smaller|safe1024 test=0`, then `DISPLAY applied`
or `DISPLAY saved; restart required`. 9x additionally logs VBE memory/INF cap
and `buffers=2`. Setup logs identify hardware-logon/service staging. The next
boot must preserve the mode and stop processing via DISPLAY.DONE. NT3.5 follows
only after the miniport rebuild; expect `DISPLAY registry selected=...`, one
restart, then the chosen mode. No additional user prompt or photo is required.

Remaining limits: CDS_TEST cannot prove that a monitor will display a timing
without EDID. A driver can fail rollback too; that result and DISPLAY.BAK are
preserved, and NT's existing [VGA mode] entry remains the recovery route.
Never directly set framebuf defaults without an exact validated mode:
NT3 framebuf can STOP C0000143. 9x's double-buffer check is required for
vmdisp9x 119's 4F07 fallback. All hardware behaviour is still unconfirmed.

Default auto is a proposal only; code preserves defaults. Before enabling it
globally, confirm the X470 monitor's native size and hardware test results.

Sources: existing USOS VBE/Win16 tools and miniport, public VBE 3.0 interface,
the pinned vmdisp9x 119 configuration/readme, original-media export names, and
Microsoft's [EnumDisplaySettings](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-enumdisplaysettingsa),
[ChangeDisplaySettings](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-changedisplaysettingsa)
and [VideoPortSetRegistryParameters](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/video/nf-video-videoportsetregistryparameters)
documentation. No NT5 leaked source was used for this change. No Microsoft
binaries or product keys were added.
# Review corrections, 2026-10-20

All 27 installer catalogs now contain the legacy display help and color-depth
label; the boot-font coverage test also passes. The depth row is hidden when
the legacy UI selection is Unchanged. The unused schema wrapper was removed.

The old USER32 adapter uses DEVMODE sizes 124/148/156 according to the OS,
with bounded fallback attempts. CDS_GLOBAL is used only on NT5, and a
BADFLAGS response retries without it. If ENUM_CURRENT_SETTINGS is unavailable,
read-only GetDeviceCaps values must match a real enumerated mode before it can
be used as the rollback mode. VGA below 16 bpp and permission failures retain
the request and Run/service registration. Negative result codes are signed.

The 9x target transforms the staged MSBATCH, preserving LAN/addons edits made
earlier. Tests execute the actual 9x/NT3/NT4 target blocks against own files,
including preservation of removed Run rows and existing VESA.REG content.
Windows 2000 logs the DISPLAY.REG import in usos-setup.log.

NT3 uses the Zig build option from review B2(b). build_nt3 is shared by the
package, import/PE tests, NVMe test and optional VM overlay builder; they no
longer inspect the old WDK binary while shipping another file. Hardware
regression still needs **NT 3.1 and NT 3.51 without a display profile**, before
accepting this compiler change. NT3.5 display selection additionally needs
the separately rebuilt miniport; it safely retains a request without its list.

Automatic mode remains an **explicit profile request**, not a new default.
No EDID/native monitor limit is claimed; CDS_TEST alone cannot prove monitor
support. Expanding beta-family support is deferred until those flows are
validated. The current staging paths still assume the existing C: layout.
