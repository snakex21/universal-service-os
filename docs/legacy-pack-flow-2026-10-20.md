# Legacy pack in the 1.0 install flows

Branch `codex/pakiet-zgodnosci`, base
`9ca9d9a6a85dbed7a52c3c68cd75f6aac6cffd7d`. This port uses the existing
ten legacy-pack commits. Their historical Windows VM results are not new
validation of these flows. Current verification is host-only; X470 remains
the acceptance target. No Windows installer or release asset was executed,
built, downloaded or deployed as part of the inventory.

## Selection and startup

95 OSR2/2.1/2.5, 98 FE, 98 SE, Me and NT4 WS/Server/Enterprise default to
`addons_preset=praca`. `retro`, `minimal` and `none` are supported;
`addons_options` and `addons_exclude` are comma-separated package IDs. They
are advanced profile keys, preserved by the UEFI editor without new UI
questions. KernelEx, RDP and DSClient stay optional. `none` emits the
previous answer bytes and stages no package. It does not uninstall an
existing pack. Custom answer files without USOS addon metadata retain
their own behavior. The stock no-profile MSBATCH explicitly requests praca.

MSBATCH invokes `[USOS.Addons]` through its existing `[Install] AddReg list;
the value goes into **HKLM Run**, not RunOnce. NT4 registers the same Run
value at the end of POST.CMD, after its existing service-pack step. The
runner defers a VM invocation and retains Run for hardware. An early call
without a desktop/with unfinished Setup also defers to the next normal
logon. It does not restart Windows Setup to force readiness.

NT4 CMDLINES uses XCOPY /E /I and a COPY.OK completion marker; a failed
copy can be retried. No COPY /Y or XCOPY /Y is assumed: those overwrite
switches are documented as a Windows 2000 change in the original
[Microsoft Q240268](https://www.betaarchive.com/wiki/index.php/Microsoft_KB_Archive/240268).
The staging log is appended with TYPE, so it does not replace copy errors.

Once ready, the existing resumable package chain, installed checks,
answers to package dialogs, accepted exit codes and restart state are
retained. `STATE.INI`, package working files and child-process TEMP/TMP
stay under `C:\USOS\ADDONS`. There is no profile-directory fallback for
the runner's temporary data. OS component installations still install
their system files in the locations required by those components.

## Native micro-Linux staging

`legacy_addons.sh` runs only after the existing target guard and chosen
disk preparation. There is no disk discovery, mounting or formatting in
this library. It reads DATA/Addons and the build's optional bundled files,
and writes only into the selected target tree.

`legacy-stage-plan` is a static x64 Linux executable linked from the same
`ini.c`, `str.c`, `detect.c` and `plan.c` used by USOSADD and the Python/C
comparison tests. Python is not added to the initramfs. Both ANSI manifest
variants and the own runner are staged by build_micro_linux.py.

The planner chooses one system/language. The 95 target is the union of
OSR2, OSR2.1 and OSR2.5; USOSADD decides the actual OSR after boot and again
after updates. This flow does not add FAT16 95 RTM/OSR1 or NT4 TSE support.
9x source language is taken from SETUP.TXT's RTF language or the recognized
PL/EN README heading. It is not taken from UI language or SETUPCOR.EXE:
the latter reports English even on the supplied Polish CDs. Unrecognized
source language is XX, selecting neutral packages only. NT4 uses the
existing TXTSETUP.SIF language detection. SELECT.INI records that source
language; a later keyboard/locale choice does not switch package language.

Flat files, nested ZIP/SFX ZIP files and ISO9660 containers are searched by
size and SHA-256, not by their folder names. Only matching inputs are used;
flat target copies are verified again. Known ZIP containers are unpacked
into private scratch first, allowing only safe 8.3 destination components.
The bounded native ISO reader handles the short root names used by the IE
offline set and can scan nested directories for pinned input sizes. It
does not implement UDF, Joliet or links. Scratch is deleted after successful
staging; a failed operation leaves its private files for diagnosis.

Inno containers use the existing host import tool. Micro-Linux does not
gain an unpinned Inno extractor in this port: such containers are logged,
and the pinned flat members produced by host import are supported. If
they have not been imported, the packages are missing and Windows Setup
continues. This limitation is distinct from the inventory, which used the
already-local pinned Windows innoextract to verify those members read-only.

Missing files, unsupported containers, known missing-source packages and
groups are not presented as installed. PLAN.TXT and the automatic log show
the staging result; the runtime still reports actual installed/present/
failed/skipped packages. Disk/write/readback errors remain fatal preparation
errors rather than permission to stage an unverified file.

## Target layouts

9x: the existing target script writes `C:\USOS\ADDONS` after copying the
chosen MSBATCH. If the runner is absent from a build, its own Run value is
removed from the staged answer; no missing-executable popup is introduced.

NT4: `I386\$OEM$\$1\USOS\ADDONS` holds the selected package. CMDLINES calls
own ADDONS.CMD to copy it to C: explicitly. NT4's drive-letter OEM behavior
is not assumed to implement the NT5 `$1` mapping. The original two
CMDLINES locations are retained; both reference the one package source.
The new registration at POST.CMD's end checks that the runner and REG file
were copied. NT4's existing POST service pack is treated as the source of
SP6a: staging resolves at 6a and the runtime's installed check also prevents
reinstallation. No second service-pack installer is launched by the pack
when SP6a is already present. NT4 TSE keeps its existing separate SP6 flow.

Original Microsoft deployment references: [Q167364](https://ftp.zx.net.nz/pub/archive/ftp.microsoft.com/MISC/KB/en-us/167/364.HTM),
[Q168814](https://www.betaarchive.com/wiki/index.php/Microsoft_KB_Archive/168814),
[Q143171](https://www.betaarchive.com/wiki/index.php/Microsoft_KB_Archive/143171).
README detection is backed by the supplied PL media and the Microsoft
[95 README](https://jeffpar.github.io/kbarchive/kb/305/Q305710/) and
[Me README](https://www.betaarchive.com/wiki/index.php/Microsoft_KB_Archive/271240).

During NT4 Setup the OEM source and C: copy coexist, so add roughly one
additional payload copy to the inventory estimate. Source files, installed
components and package caches also need space. This task did not measure
full-pack copy time on a physical disk.

## Network and display integration

DUN package IDs are excluded unless `;USOS-DIALUP=on` comes from the network
profile. Me always excludes them. The public manifest retains their pinning
and release classification; policy exclusion is recorded in SELECT.INI.
After package restarts and at final completion, USOSADD schedules the network
task's USOSLAN.EXE when present, and launches it at completion. It reuses
that component's NETCFG.INI, preserving the requested homepage and LAN
preferences after IE or network component installation. No network wait,
new driver, IRQ/ELCR setting or PollMode change is added here.

usosnet is already present in the current project for 98/98 SE/Me and 2000
(I211/I210/82576 family); 95/NT4 NDIS4 is separate work. The pack does not
make an unsupported NIC usable. The 9x auto-logon mechanism retained from
the original runner still supports its restart chain; disabling default
DUN does not justify removing it before hardware verification.

Display mode belongs to `codex/rozdzielczosc-z-profilu`. The old uncommitted
`display` builtin and `display-mode` package were not adopted. USOSCHK was
read for the handoff report only and is not built or staged here.

The three task branches must be integrated by preserving all profile fields,
all AddReg sections, independent staging calls, build entries and POST hooks.
Do not replace whole renderer or target blocks with one branch's version.

## Inventory and release policy

The per-system/language/file table, hashes, sizes and source classifications
are in [the refreshed inventory](legacy-compat-inventory-2026-10-20.md) and
[full metadata TSV](legacy-compat-inventory-2026-10-20.tsv). It verifies 99
hashes in the five supplied archives. A missing row means not verified in
those archives, not proof that no copy exists elsewhere on the machine.
The inventory read/hash pass took about 23 seconds on this host; this is
not a full staging or installation time.

IE, DCOM, DUN, WMP, SP6a and SRP now join the existing Microsoft release-asset
class under the maintainer's 2026-10-20 decision, recorded per package.
Their binaries remain outside Git. No MS asset was built in this task.
Classifications record that decision and the previous license notes; they
are not an independent legal determination. Other user-file classifications
and the MSCONFIG/WinMeDOS replacement roadmap remain.

The public manifest has no download addresses, including notes/comments;
validation rejects HTTP(S) URLs. Unknown future keys remain ignored by the
runner/parser. The format remains 1. KernelEx is an optional bundled class
with `status=missing`: the local set has the 4.0 Final2 binary but no matching
source in the checked project/vendor locations. No binary is bundled until
source and notices are supplied. Missing English NT4 post-SRP updates and
Speech SDK language pack remain outside 1.0; no search/download was started
for them. OEM 98 SE `accept_eula` automation remains after 1.0.

## Hardware acceptance still required

After Claude integrates the branches, use fresh 98 SE on the intended test
disk, with the normal flow and no extra UI steps. Check that all three
components coexist: display profile, LAN defaults and the full package.
Observe automatic `C:\USOS9X\LOGS\ADDONS.LOG` and NETSETUP/USOSLOG, plus
STATE.INI; confirm package counts, restart/resume and final browser behavior.
Repeat for 95 OSR2, 98 FE and Me. For NT4, confirm OEM copy before POST ends,
no second SP6a, VM deferral and execution on the hardware desktop.

Existing Me can receive the staged C:\USOS\ADDONS tree and its ADDONS.REG
through Claude's existing in-place mechanism. It needs no new MSBATCH file.
The same automatic summary/log distinguishes missing files from install
failures. No tool or DIAG command is required from the user. Runtime time
for .NET and real restarts remains a hardware measurement; the old QEMU
times are historical evidence only.

## Verification of this port

Host checks passed: 561 Zig tests and the x64 UEFI build; the original
legacy-pack C selftest and 1404 C/Python plan comparisons; 17 new flow
tests; 68 existing NT4/9x/time-zone tests using fake processes; all 25 Go
test packages, including components, i18n and UI. Answer regression is
ALL PASS, with intentional changes only to the 9x/NT4 options goldens and
their matrix. Routing and XP/2003/NT6 goldens are unchanged.

The final own USOSADD build is 32768 bytes, i386 PE32 GUI/subsystem 4.0,
without CRT, importing only kernel32/user32/advapi32. The Linux planner
is static ELF without PT_INTERP. Synthetic fixtures are own files; none
of these results establishes that real package installers and their
restart chain have passed on X470.
