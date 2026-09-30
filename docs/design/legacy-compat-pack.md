# Legacy Compatibility / Post-Install Pack (Windows 95, 98, 98 SE, Me, NT 4.0)

Status: **design + manifest + runner, branch `feature/legacy-compat-pack`,
2026-09-30.** Not yet wired into the 9x DOS Setup path (branch
`feature/win9x-modern`) or an NT4 flow (not built yet).

Goal: after an install through USOS the user ticks *Pełny pakiet zgodności
Windows 98 SE* (or 95 / 98 / Me / NT 4.0) and gets a usable system: the
runtimes, updates and components a bare old Windows lacks today, installed in
the right order, silently, with the restarts they need, from files verified
by SHA-256. Strictly optional extras (Movie Maker, Speech SDK, KernelEx,
ASPI, ...) are separate checkboxes, also officially supported.

Pieces:

| Piece | Where |
|---|---|
| Manifest (source of truth, one per pack) | `src/addons/legacy-pack.ini` |
| Post-install runner `USOSADD.EXE` (Win32, runs on 95/98/Me/NT4) | `src/platform/win32_legacy/usosadd/` |
| Host tools: validation, plan preview, staging from the user's files | `tools/addons/` |
| Build (OpenWatcom 2.0, pinned snapshot) | `tools/build_usosadd.py` |
| Tests | `tools/tests/addons/` |
| Licence decisions | this document §3, `docs/LICENSES-AUDIT.md` §8, `tools/release/third-party.json` |

## 1. Inventory of the user's add-on folder

Source: `C:\Users\ASRock\Desktop\Universal_Service_OS\łatki` (read-only):
five archives `Win95.zip`, `Win98.zip`, `WinME.zip`, `WinNT.zip`,
`Win9x.zip`. The `WinNT4` and `WinNT4_WinSPatcher_NT` folders are inside
`WinNT.zip`. Every file was hashed from the archives; installer types come
from the PE resources (IExpress `RUNPROGRAM`/`ADMQCMD`/`REBOOT`, version
info) and from the archive listings, not from file names. The complete
per-file SHA-256 list is in the manifest (`fileN=` lines) and, for files
the manifest does not use, in §1.4.

Switch legend: IExpress (WEXTRACT) packages take `/Q` (quiet, runs the
package's *quiet* command), `/Q:A` (accept everything), `/R:N` (no restart),
`/T:<dir> /C` (extract only), `/C:"<cmd>"` (replace the command).
"Reboot flag" is the IExpress `REBOOT` resource (1 = always, 3 = if needed,
5 = none/forced by the program).

### 1.1 Windows 9x components (`Win9x.zip`)

| Package (manifest id) | File, version, language | Installer type, silent command | Reboot | Target OS | Depends on |
|---|---|---|---|---|---|
| DCOM95 1.3 (`dcom95`) | `dcom95.exe` 1.3, EN | IExpress 4.71, `install.exe` + `dcom95.inf`; `/Q:A /R:N` | yes (flag 1) | 95 all | - |
| DCOM98 1.3 (`dcom98`) | `DCOM98.EXE` 1.3, EN | IExpress 4.71, `install.exe -n`; `/Q:A /R:N` | yes | 98 FE/SE (Me has 1.3) | - |
| DCOM config tool (`dcomcnfg9x`) | `dcm9xCfg.exe` 1.3, EN | IExpress, `install.exe -c`; `/Q:A /R:N` | yes | 95, 98 | DCOM 1.3 |
| DUN 1.4 for 95 (`dun14-95-en`) | `DUN14-95.EXE`, EN | IExpress, quiet cmd `dunsetup.exe /q /m`; `/Q:A /R:N` | yes | 95 (EN only) | Winsock 2 (to verify: the 1.9 MB package may carry it) |
| DUN 1.4 for 98 (`dun14-98-en`, `dun14-98-pl`) | `DUN14-98.EXE` EN, `dun14-98pl.exe` PL, 4.10.2002 | IExpress, `dunsetup.exe /I`; `/Q:A /R:N` | yes | 98 FE | - |
| DUN 1.4 for 98 SE (`dun14-98se-en`, `dun14-98se-pl`) | `DUN14-SE.EXE` EN, `dun14-SEpl.exe` PL, 4.10.2222 | same | yes | 98 SE (folder says "98SEpl_MEpl", see Q2) | - |
| Q243199 NDIS update (`q243199-98se-pl`) | `243199POL8.EXE`, PL | IExpress, `243199up.inf` + `CSETUP.exe`; `/Q:A /R:N` | if needed (3) | 98 SE PL | DUN 1.4 and its restart (user's note) |
| DirectX 5 / 6 | `dx5pol.exe`, `dx6pol.exe`, PL | IExpress, own setup (forces restart) | forced | 95/98 | **not used** (superseded) |
| DirectX 8.0 (`dx80-pl`) | `DX80pol.exe` 4.08.00.0400, PL | IExpress cabpack, `DXSetup.exe /packageinstall`; `/Q /T:dir /C` then `DXSETUP.EXE /silent` | yes | 95 (8.0a is the last for 95; this is 8.0) | - |
| DirectX 8.1 | `DX81pol.exe` 4.08.01.0881, PL | same | yes | 98/Me | **not used** (DX 9.0c replaces it) |
| DirectX 8.1 NT | `DX81NTpol.exe` 5.1.2600.881, PL | same | yes | Windows 2000 only | **not used** (NT4 has no DX beyond 3.0a from SP3+) |
| DirectX 9.0c Dec 2006 (`dx9c`) | `directx_dec2006_redist.exe` (DXSETUP 9.0c, 4.09.00.0904), multilingual | IExpress with **no** command: `/Q /T:dir /C` then `DXSETUP.EXE /silent` | yes | 98 FE/SE, Me (last release for them) | - |
| IE 4.01 CD | `MSIE4_01.iso` (533 MB; EN+PL, i386+Alpha, NT4 SP3 folders) | IE4 Active Setup | - | 95, NT4 | **not used** (IE 5.5/6 replace it; kept as archive) |
| IE 5.5 SP2 PL (`ie55sp2-pl`) | `ie55_pl_SP2.zip` → `ie5setup.exe` + 60 CABs (5.50.4807.2300; also carries `DCOM95.EXE`) | Active Setup: `ie5setup.exe /Q:A /R:N /C:"ie5wzd /S:""#E"" /Q:A /R:N"` (batch mode, to verify) | yes | 95 (last IE for 95) | DCOM95 |
| IE 5.5 SP2 cumulative (`ie55sp2-q810847-pl`) | `q810847(2).exe` 5.50.4134.600, PL | IExpress, `Q810847.inf`; `/Q:A /R:N` | yes | 95 with IE 5.5 SP2 PL | IE 5.5 SP2 |
| IE 6 SP1 PL for 9x (`ie6sp1-pl-9x`) | `IE6PLSP1W9x.zip` → `ie6setup.exe` + 42 CABs (6.0.2800.1106) | Active Setup: `ie6setup.exe /Q:A /R:N /C:"ie6wzd /S:""#E"" /Q:A /R:N"` | yes | 98 FE/SE, Me | - |
| Windows Installer 2.0 (`msi20-9x`) | `InstMsiA.exe` 2.0.2600.2 | IExpress; `/Q` runs `msiinst.exe /i instmsi.msi REBOOT=REALLYSUPRESS MSIEXECREG=1 /m /q` | yes (suppressed, USOS restarts) | 95, 98, Me | - |
| MDAC 2.8 SP1 PL (`mdac28sp1-pl`) | `MDAC_TYP.EXE`, PL | IExpress, `dasetup.exe`; `/Q:A /C:"dasetup /Q /N"` | yes | 98, Me, NT4 (95 not supported by 2.8) | IE 4.01+ |
| MDAC MS04-003 fix | `PLK_Q832483_MDAC_x86.EXE`, PL | IExpress, `dahotfix.exe` | - | MDAC 2.5-2.8 | **not used** (in 2.8 SP1 already) |
| MSLU (`mslu`) | `UNICOWS.EXE` 1.1.3790.0 | IExpress with no command (extracts `unicows.dll`); USOS copies it to `SYSTEM` | no | 95, 98, Me | - |
| KernelEx (`kernelex`) | `KernelEx-4.0-Final2.exe` | NSIS, `/S` | yes | 98 FE/SE, Me | - |
| VB6 runtime SP6 (`vbrun6sp6`) | `vbrun60sp6.exe` (MSVBVM60 6.0.97.82) | IExpress; `/Q` | if files in use | 95, 98, Me, NT4 | - |
| VB6 runtime SP5 | `vbrun60sp5.exe` | IExpress, `vbrun60.inf` | - | same | **not used** (SP6 replaces it) |
| VC++ 6.0 SP6 runtime (`vcredist6sp6`) | `VCREDIST.EXE` | IExpress 4.71, `VCRedist.inf`; `/Q:A /R:N` | if needed (3) | 95, 98, Me, NT4 | - |
| Visual Studio 6.0 Professional | `Microsoft Visual Studio 6.0 Professional.7z` (399 MB) | - | - | - | **not part of the pack** (development suite, commercial) |
| .NET 2.0 (`dotnet20`) | `DOTNETFX.EXE` 2.0.50727.42 | IExpress, `Install.exe`; `/Q:A /C:"install.exe /q"` | maybe | 98 FE/SE, Me (last .NET for them) | MSI 2.0, IE 5.01 |
| .NET 2.0 PL language pack (`dotnet20-pl`) | `LANGPACK.EXE` 2.0.50727.42, PL | same | maybe | same, PL | .NET 2.0 |
| .NET 2.0 SP1 / SP2 | `NetFx20SP1_x86.exe`, `NetFx20SP2_x86.exe` (sfxcab) | - | - | 2000 SP4 / XP / 2003 only | **not used on 9x** (their own requirements) |
| NUSB 3.3a PL (`nusb33-pl`) | `NUSBPL.EXE` (Maximus Decim) | IExpress, `_NUSB.INF`, licence page; `/Q:A /R:N` | if needed (3) | 98 FE/SE (Me has USB storage) | - |
| WMP 6.4 (`wmp64`) | `mpfull.exe` 6.4.07.1110, EN | IExpress, quiet cmd `quiet.inf`; `/Q:A /R:N` | yes | 95, NT4 (last player there) | - |
| WMP 7.1 PL (`wmp71-pl`) | `mp71.exe` 7.01.00.3055, PL | IExpress, quiet `setup_wm.exe /Quiet`; `/Q:A /R:N` | yes | 98 FE | - |
| WMP 9 PL (`wmp9-pl`) | `MPsetup.exe` 9.00.00.2980, PL (same file as on the Win98 help disc) | IExpress, quiet `setup_wm.exe /Quiet /P:#e`; `/Q:A /R:N` | yes | 98 SE, Me | - |
| WMP 9 classic skin (`wmp9-classic-skin`) | `MediaPlayerClassicCompact-5.wmz` | file copy to `Skins` | no | 98 SE, Me | WMP 9 |
| Movie Maker for 98 (`moviemaker98`) | `wmm98_build1.exe` (community repack of Me's WMM) | IExpress, `wmm98.inf`; `/Q:A /R:N` | yes | 98 FE/SE | WMP 7+ |
| Speech SDK 5.1 (`speechsdk51`) | `SpeechSDK51MSM.exe` (ZIP SFX: merge modules EN/JA/ZH, 138 MB) | merge modules need a host MSI | - | 98, Me, NT4 SP6a | **blocked**, see Q5 |
| Adaptec ASPI 4.71a2 (`aspi471`) | `aspi_471a2.exe` (16-bit ZIP SFX) → `ASPIINST.EXE` | unpacked on the host; `ASPIINST.EXE` (console, silent) | yes | 98, Me, NT4 (95 not listed) | - |
| DSClient 9x (`dsclient9x`) | `dsclient9x.msi`, EN (1033) | MSI: `msiexec /i dsclient9x.msi /qn REBOOT=ReallySuppress` | yes | 95, 98 (Me: to verify) | MSI 2.0, IE 4.01 |
| DSClient NT4 (`dsclient-nt4-pl`) | `DSCLIENT.EXE` 5.50.4522.1800, PL | IExpress, quiet cmd `setup.exe /q`; `/Q:A /R:N` | yes | NT4 SP6a | IE 4.01 |
| RDP client 5.1 PL (`rdp51-pl`) | `msrdpcli.exe` 5.1.2600.2180, PL | IExpress around an MSI: `/Q:A /R:N /C:"msiexec /i msrdpcli.msi /qn ALLUSERS=1"` | no | 95, 98, Me, NT4 | MSI 2.0 |
| MSCONFIG for 95 (`msconfig95`) | `WIN95\MSCONFIG.EXE` = Windows 98's 4.10.1998 | file copy to `%WINDIR%` | no | 95 | - |
| MSCONFIG for 2000 | `WIN2K\MSCONFIG.EXE` 5.1.2600.0 (XP) + CHM | - | - | 2000 | **out of scope** (not a 9x/NT4 item) |
| HP IP printing (`hp-ipprint`) | `JA255EN.EXE` HP Install Network Printer Wizard v3.0, EN | InstallShield 5: `-s -f1<response.iss>` (response file to record) | maybe | 95, 98, Me, NT4 | - |
| Me Real DOS mode (`winmedos`) | `mfddme13.zip` → `WINMEDOS.COM` 1.3 (Reines/MFD) | DOS patcher on copies of `IO.SYS`, `COMMAND.COM`, `REGENV32.EXE`, then copy back + `CONFIG.SYS`/`AUTOEXEC.BAT` lines (runner builtins) | yes | Me 4.90.3000 | - |
| Win98 help disc (`hotfixes-98-pl` + `hf98-*`) | `Pomoc techniczna.iso` (138 MB): `update\pre` (IE6 SP1 PL, DX9 files, MDAC 2.8, WMP9), `update\post` (20 hotfixes), `update\add` (5 extras), with `setup_post.bat` | each hotfix IExpress; the disc's own switches (`/Q /R:N`, `/Q:A /R:N`, `/q:a /c:"dahotfix.exe /q /n"`) | batched | 98 (PL) | IE 6 for IE items, WMP 9 for KB819639 |

### 1.2 Per-version update bundles (`Win95.zip`, `Win98.zip`, `WinME.zip`)

| Bundle | Type | Contents | Use in the pack |
|---|---|---|---|
| WinSPatcher 95 v1.0a (G. Skulimowski, freeware) | IExpress (`setup.exe`), 95 MB | 121 files: IE 5.5 set + `IE5SETUP.EXE`, `DCOM95.EXE`, `InstMsiA.exe`, `dx8.EXE`, `wmp71_95.EXE`, `w95y2k.exe`, `w95euro.exe`, `amdk6upd.exe`, `pccardupd.exe`, MS Agent, ~15 hotfixes | not run as a whole (own UI, installs "only on genuine copies"); a future hotfix source for 95 (§2.9) |
| WinSPatcher 98 v1.0 | **Inno Setup** | not listable without innoextract | not used (Q6) |
| WinSPatcher 98 SE v1.0 | IExpress (`setup.exe`), 96 MB | 96 files: IE 6 SP1 PL set, DirectX 9 files, `MPsetup.exe`, `msjavwu.exe`, `KB837009`, `KB885492`, `KB891711`, `KB891781`, 10 Q-hotfixes, `rootsupd`, `WUCrtUp` | as above, hotfix source for 98 SE |
| WinSPatcher Me v1.1 | IExpress (`wsetup.exe`), 135 MB | 79 files: IE 6 SP1 PL set, ~30 Me/IE/WMP hotfixes (KB891711, KB918547, KB908519, KB896358, KB904706 DX9, ...), .NET 1.1 and 2.0 (`dotnetfx.exe`, `dotnetfx2.exe`, langpacks), JRE 1.5.0_07, TweakUI 1.33 | as above, hotfix source for Me (no other Me hotfixes in the set) |
| Service Pack Plus 4.8r / 5.0b (98 SE, unofficial, PL) | RAR archives: `INFEX.EXE` + `SP.cab`, `FixIR.reg` first | IE 5-only; needs `C:\WINDOWS` and a `G:` drive for its System Restore | **not combined with the pack** (conflicts with IE 6; modifies shell) |

### 1.3 NT 4.0 inventory (`WinNT.zip`)

| Item | File, version, language | What it is | Fits | Silent install | Reboot |
|---|---|---|---|---|---|
| SP6a EN (`nt4-sp6a-en`) | `WinNT4_sp6a_EN_i386.exe` (35.7 MB, self-extracting CAB 1.10 → `update.exe`) | Service Pack 6a, English | NT4 EN, any SP below 6a | `-u -n -o -z` (unattended, no uninstall folder, overwrite OEM files, no restart) | yes |
| SP6a PL CD | `NT4SP6APL.iso` (605 MB) | **the Polish SP6a CD**, not an NT4 install CD: `SP6I386.EXE` (38.9 MB), the expanded `I386` tree with `UPDATE\UPDATE.EXE` (PL, 4.00), Alpha files, `SUPPORT` (IAS, MSMQ 9x SP6, debug symbols, WINNT32), `VALUEADD\MSIE5` | NT4 PL | the manifest uses the member `SP6I386.EXE` (`nt4-sp6a-pl`), `-u -n -o -z` | yes |
| Post-SP6a SRP PL (`nt4-srp-pl`) | `POLQ299444i.exe` (14.9 MB, self-extracting CAB) | Security Rollup Package Q299444: all fixes after SP6a up to its date | NT4 PL SP6a (Workstation, Server, Enterprise) | `-u -n -z` | yes |
| IE 6 SP1 PL (`ie6sp1-pl-nt4`) | `MS InternetExplorer 6 sp1 PL.zip` (full set incl. NT and 2000 CABs; same `ie6setup.exe` as the 9x set) | IE 6 SP1 | NT4 SP6a | as 9x | yes |
| Windows Installer 2.0 (`msi20-nt4`) | `InstMsiW.exe` 2.0.2600.2 (Unicode) | MSI 2.0 | NT4 SP6 | `/Q` | yes (batched) |
| .NET 1.1 (`dotnet11`) + PL (`dotnet11-pl`) + SP1 (`dotnet11-sp1`) | `DOTNETFX.EXE` 1.1.4322.573, `LANGPACK.EXE` PL, `NDP1.1sp1-KB867460-X86.exe` | .NET 1.1 (the newest for NT4; 2.0 does not support NT4) | NT4 SP6a | `/Q:A /C:"install /q"`, `/Q:A /C:"inst /q"`, `/Q` | batched |
| USB for NT4 (`usb-nt4-ionetworks`) | `USB_NT4.zip`: Inside Out Networks USB 1.x driver 2.32, Dell A00 (Latitude D400/D600), EN | NT4 has no USB stack; this commercial OEM driver adds one | NT4 | InstallShield 6: `setup.exe -s -f1<iss>` after recording a response file | yes |
| DSClient NT4 (`dsclient-nt4-pl`) | from `Win9x.zip` (above) | AD client | NT4 SP6a, IE 4.01+ | `/Q:A /R:N` | yes |
| RDP client, VB6, VC6, MDAC 2.8 SP1, ASPI | from `Win9x.zip` | shared with 9x | NT4 | as above | |
| WinSPatcher NT v1.0 | `WinSPatcher_NT_v1.0.exe` (134 MB), **Inno Setup** | Polish NT4 update bundle (freeware) | NT4 PL | Inno's `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` applies only to the outer installer; contents unknown without innoextract | - |

NT4 order (preset `full` on NT4): SP6a (PL or EN by system language) →
restart → SRP (PL) → restart → IE 6 SP1 → restart → MSI 2.0 → MDAC 2.8 SP1
→ restart → VB6, VC6 → .NET 1.1 → PL pack → SP1 → restart. DirectX: none
beyond the DirectX 3.0a that SP3+ already carries. Options: RDP, DSClient,
WMP 6.4, ASPI, USB (Inside Out), HP printing. Missing locally: the English
SRP, an English IE 6 SP1 set, post-SRP hotfixes (perhaps inside WinSPatcher
NT), a Y2K/DST update check (SP6a + SRP cover Y2K).

### 1.4 Files the pack does not use

DirectX 5, 6, 8.1 and 8.1 NT, the IE 4.01 CD, `vbrun60sp5.exe`,
`PLK_Q832483_MDAC_x86.EXE`, `NetFx20SP1_x86.exe`, `NetFx20SP2_x86.exe`,
`WIN2K\MSCONFIG.EXE`, the Visual Studio 6.0 archive, Service Pack Plus
(`Sp48r.rar`, `Sp50b.rar`) and the five WinSPatcher executables (reasons in
the tables above). The SHA-256 of every file of the add-on folder, used or
not, is in `tools/addons/inventory-2026-09-30.tsv`.

## 2. Design

### 2.1 Manifest

`src/addons/legacy-pack.ini`, an INI file (format 1). Chosen over JSON/TOML
because the same file is read by the 9x runner (a small hand-written parser,
no CRT), by Python host tools and later by the Zig menu without an allocator;
the key reference is at the top of the file. One `[pkg:<id>]` section per
package:

- identity: `name_pl`, `name_en`, `dir` (8.3), `fileN = staged 8.3 name |
  original name (or container!member) | sha256 | size`, `unpack=zip`;
- applicability: `os` (tokens `95RTM 95OSR1 95OSR2 95OSR21 95OSR25 98FE 98SE
  ME NT4`, groups `95 98 9X`), `lang` (`PL`, `EN`, `*`), `ntsp` (`6a+`,
  `<6a`);
- selection: `tier` (`full` / `option` / `group` / `none`), `needs` /
  `provides` (capabilities with versions, e.g. `msi:2.0`, `ie:5.01`),
  `order` (phase number);
- action: `runN` commands with `%PKG% %TMP% %WIN% %SYS% %PF% %ADD%` and the
  builtins `copy`, `force`, `attrib`, `append`, `cd`, `inf`, `msi`;
  `codes` (accepted exit codes); `reboot` (`now` / `end` / `no`); `check`
  (already-installed test: file version, registry string version, registry
  value, registry DWORD, NT SP level);
- provenance: `source` (`bundled` / `user`), `redist`, `license`, `bridge`,
  `status` (`missing`, `needs-iss`), `verify`, `note`.

`[os:<token>]` sections list what each system already provides (IE 4.01 on
98, IE 5.0 on 98 SE, IE 5.5 + MSI 1.2 + WMP 7 + USB storage on Me, ...), so
`needs=ie:5.01` is satisfied by the OS or by an earlier package.

### 2.2 Detecting the system (never install blindly)

The runner detects the installed system itself before every run:

| Token | Rule (GetVersionEx + registry + files) |
|---|---|
| 95RTM | platform 9x, 4.00, build 950, CSD empty |
| 95OSR1 | 4.00.950, CSD `A` |
| 95OSR2 | 4.00.1111, CSD `B`, `SYSTEM\VMM32\NTKERN.VXD` < 4.03 |
| 95OSR21 | as OSR2 but `NTKERN.VXD` >= 4.03 (USB supplement 4.03.1212/1214) |
| 95OSR25 | 4.00.1111, CSD `C` |
| 98FE | 4.10.1998 |
| 98SE | 4.10.2222 (CSD `A`) |
| ME | 4.90.3000 |
| NT4 | platform NT, 4.0; SP level from `CSDVersion`, 6a = SP6 + `Hotfix\Q246009` (SRP: `Hotfix\Q299444`) |

Language: `GetSystemDefaultLangID()` primary language (0x15 PL, 0x09 EN;
others match only `lang=*`). The host passes what it expects (`expect=` in
`SELECT.INI`, from the ISO identification); a mismatch is logged and the
runner trusts the detected system. Detection is pure code
(`detect.c`, host-tested); the OSR2.1 rule is to be confirmed on the
user's 95 OSR2.1 PL ISO in QEMU.

### 2.3 Presets and options

- **Pełny pakiet zgodności Windows <version>** = every package with
  `tier=full` whose `os`/`lang`/`ntsp` fit the detected system, plus
  everything their `needs` pull in. Per system this gives (Polish system):
  - 95: DCOM95, (Winsock 2: file missing), IE 5.5 SP2 + Q810847, MSI 2.0,
    DirectX 8.0, VB6 SP6, VC6 SP6, MSLU (DUN 1.4 only on English 95).
  - 98: IE 6 SP1, DCOM98, DUN 1.4, MSI 2.0, DirectX 9.0c, MDAC 2.8 SP1,
    VB6, VC6, MSLU, WMP 7.1, .NET 2.0 + PL, NUSB 3.3a, 13 hotfixes.
  - 98 SE: as 98 with DUN 1.4 SE + Q243199, WMP 9 + KB819639.
  - Me: IE 6 SP1, MSI 2.0, DirectX 9.0c, MDAC 2.8 SP1, VB6, VC6, MSLU,
    WMP 9, .NET 2.0 + PL.
  - NT4: SP6a, SRP, IE 6 SP1, MSI 2.0, MDAC 2.8 SP1, VB6, VC6, .NET 1.1 +
    PL + SP1.
- **Options** (`tier=option`, separate checkboxes): KernelEx, Movie Maker,
  Speech SDK, RDP client, DSClient, ASPI, HP IP printing, MSCONFIG (95),
  DCOMCNFG, WMP 6.4, WMP 9 skin, Me real DOS mode, NT4 USB, extra 98
  updates (IE/OE cumulative, MSXML, MS VM, IDE cache, storage).
- The resolver (`plan.c`, mirrored in `tools/addons/legacy_manifest.py` and
  cross-checked by the tests for every system × language): candidates →
  add providers for unmet `needs` → drop inapplicable ones and those whose
  needs stay unmet (logged with the reason) → sort by `order`.

### 2.4 Files on the stick

- The user copies the add-on files **in any layout** to `DATA\Addons\`
  (e.g. the whole `łatki` folder, archives unpacked or not). Nothing is
  renamed by hand: the staging step finds each manifest file by size +
  SHA-256, also inside `.zip` and `.iso` containers named in `fileN`.
- Staging writes `DATA\Addons\.usos\store\<dir>\<8.3 files>` and
  `store.ini` (what is present, verified). Proposed owner: the Go installer
  (*Aktualizuj USOS* and the Components screen), on the Windows host where
  zip/ISO reading and hashing are cheap. `tools/addons/stage_legacy_pack.py`
  is the reference implementation (used by the tests and the QEMU run).
- Bundled items (today: only USOS's own `USOSADD.EXE` and the manifest)
  come from the USOS payload as a component zip, `legacy-pack.zip`.

### 2.5 From the stick to the target

The target gets `C:\USOS\ADDONS\`: `USOSADD.EXE`, `LEGACY.INI` (manifest in
the ANSI code page), `SELECT.INI` (the user's choice), `PKG\<dir>\...` (only
the packages of the plan for the expected system, a superset for 95 where
the OSR is only known on the target), `ISS\` (response files); the runner
writes `STATE.INI`, `TMP\` and the log `C:\USOS\addons.log`.

- **9x DOS Setup path** (`feature/win9x-modern`): the Legacy Core already
  reads DATA (NTFS) and writes the target's MBR + FAT32. Two ways, in order
  of preference: (a) a small FAT32 seeding writer in the Core
  (`dos_fat32_seed.zig`, like the existing `dos_fat16_seed.zig`) writes
  `C:\USOS\ADDONS` right after formatting, with 8.3 names only; (b)
  interim: the Core adds the store to the 256 MiB RAM disk and
  `INSTALL.BAT` copies it (`XCOPY` is on the startup floppy; the RAM disk
  would need about 150 MB more for a full 98 SE pack). The answer file:
  the MSBATCH renderer (`src/flow/answer/msbatch.zig`) adds one line to its
  `[USOS.RunOnce]` section when addons are selected:
  `HKLM,"Software\Microsoft\Windows\CurrentVersion\RunOnce",USOSAddons,,"C:\USOS\ADDONS\USOSADD.EXE"`.
  The static default `msbatch.inf` stays without addons.
- **NT4 flow** (future): `$OEM$\$1\USOS\ADDONS` (8.3 names) with
  `OemPreinstall=Yes`, and `[GuiRunOnce]` `"C:\USOS\ADDONS\USOSADD.EXE"`
  in `UNATTEND.TXT`.
- An existing system: the user can run `USOSADD.EXE` from a copied folder;
  `/dry` only logs the plan.

### 2.6 The runner (`USOSADD.EXE`)

Plain Win32 (kernel32, user32, advapi32 only; `version.dll` and the NT
token functions are loaded at run time), built with OpenWatcom 2.0 without
its C library (own entry point, no CRT), PE subsystem 4.0, i386: loads on
95 RTM through NT4. Per start:

1. read `LEGACY.INI`, `SELECT.INI`, `STATE.INI`; detect the system;
2. resolve the plan (§2.3); log it on the first start;
3. for each package not done: skip when `status` is set, files are missing,
   or `check` says installed (`present`); else run its commands in order,
   exit codes checked against `codes`; after the run the `check` decides
   (when there is one), otherwise the exit code;
4. state is written **before** each package starts (`running`) and after it
   ends (`done` / `failed` / `present` / `skipped`), so a package that
   restarts the PC on its own is resumed: `running` + check true = done,
   `running` twice = failed, move on;
5. `reboot=now` → re-register itself in `HKLM\...\RunOnce`, restart
   (`ExitWindowsEx(EWX_REBOOT)`, on NT after `SeShutdownPrivilege`);
   `reboot=end` restarts are collected and done once before the next
   `now` package or at the end;
6. when nothing is left: final log line, `TMP` removed, RunOnce not
   re-registered. A failed package never stops the chain; packages that
   need what it provides are skipped with the reason.

A small window shows `USOS: instalowanie dodatków (3/14): DirectX 9.0c`
(English on non-Polish systems). The log (append) holds date/time, system
detection, the plan, every command line with its exit code and every state
change. Switches: `/dry` (detect and log the plan only; `/dry /as:98SE,PL[,6a]`
logs the plan another system would get), `/reset` (forget `STATE.INI`).

### 2.7 UI

- Answer profile (`docs/answer-profiles.md`), group *Wygląd i dodatki*:
  `addons=full` / `none`, `addons_options=kernelex,rdp51-pl,...`. The UEFI
  menu's profile page shows *Pełny pakiet zgodności Windows 98 SE* (the
  chosen system's name) and one checkbox per option applicable to that
  system; greyed out with *brak pliku w DATA\Addons* when the store does
  not have the files, *wymaga nagrania odpowiedzi* for `needs-iss`.
- Installer, Components screen: a row *Pakiet zgodności dla starszych
  Windows (95/98/Me/NT4)* installs `legacy-pack.zip` (runner + manifest) and
  a button *Sprawdź pliki w DATA\Addons* that runs the staging and lists
  found / missing per system.

### 2.8 Integration with the 9x agent's work

`feature/win9x-modern` has the DOS Setup path, `msbatch.zig` and the
`windows-9x` profile group, but no post-install hook yet (its §6 note was
written from the component list only; this document replaces it). This
branch is based on `master` and touches no file of that branch, so it
merges before or after it without conflicts; the hook (one MSBATCH line +
the copy step) is a small follow-up once both are in.

### 2.9 Later

- Hotfix layers for 95 / 98 SE / Me / NT4 from the WinSPatcher sets:
  the IExpress containers can be unpacked on the host like the zips; each
  hotfix then becomes a `tier=none` member of a `hotfixes-<os>` group, as
  done for the Win98 help disc.
- Clean-room replacements for the two bridges: MSCONFIG for 95 and the Me
  real DOS mode patch.

## 3. Redistribution decisions (per package)

Rule: bundle only when the licence clearly allows it for USOS's use (a
separate tool that installs them into another system, not "your
application" using them); otherwise the user's file or a pinned download
(SHA-256 from the user's copy). For Microsoft runtimes the user's file or a
download is the **permanent** source: a clean-room DirectX, MDAC, .NET or
IE is not a sensible goal, so they are not marked as bridges.

| Package | Terms | Decision |
|---|---|---|
| DirectX 8.0 / 9.0c redist | DirectX SDK redistributable terms: redistribute unmodified with *your application*, under an EULA as protective | conditional: not satisfied by a stand-alone pack; **user file** |
| VB6 runtime, VC6 runtime | VB6/VS6 redistributable code: only as part of an application built with them | conditional; **user file** |
| MSI 2.0 (InstMsiA/W) | Windows Installer redistributable, with applications that use it | conditional; **user file** |
| MDAC 2.8 SP1 | MDAC redistributable, with applications | conditional; **user file** |
| MSLU | Platform SDK redistributable (1.1.3790 fixed the "ambiguous EULA"): with your application | conditional; **user file** |
| .NET 1.1 / 2.0 + langpacks | .NET Framework redistributable, with your application | conditional; **user file** |
| DCOM95 / DCOM98, DUN 1.4, WMP, RDP client, DSClient, IE, hotfixes, SP6a, SRP | end-user EULAs / download terms; no redistribution grant | **user file** |
| IE 5.5 / 6 sets | IE EULA; redistribution only through IEAK licensing | **user file** |
| Movie Maker 98, NUSB 3.3a | community repacks of Microsoft binaries, no licence | **user file** only |
| KernelEx 4.0 Final 2 | GPL-2.0 (its `License.txt`) | **may be bundled** once the matching source is vendored (`tools/vendor/kernelex/4.0-final2` + SOURCES.txt); until then user file |
| ASPI 4.71a2 | Adaptec; freely downloadable, no redistribution grant found | **user file** |
| HP IP printing wizard | HP freeware download terms | **user file** |
| WinMeDOS 1.3 | freeware (MFD), no licence text; patches Microsoft files | **user file**, bridge |
| MSCONFIG (98's) on 95 | Microsoft OS file | **user file**, bridge |
| WMP classic skin | unknown author/licence | **user file** |
| USB for NT4 (Inside Out/Dell) | commercial OEM driver | **user file** |
| USOSADD.EXE, manifest, response files, docs | USOS, GPL-3.0-or-later | **bundled** |

Downloads: the manifest has room for a pinned `download=` URL, but none is
filled in: the original `download.microsoft.com` links of these packages
are gone, and archive copies must be checked one by one against the pinned
SHA-256 before they are listed (Q4). The staging tool never downloads by
itself.

Precedent: the maintainer decided on 2026-09-28 to ship some Microsoft
update files in the payload at the maintainer's own risk (LICENSES-AUDIT
§5). This pack does **not** extend that decision on its own (Q3).

## 4. Open questions for the user

1. **Full vs option**: is the split in §2.3 right? In particular KernelEx
   (option now, it changes system behaviour), RDP client and DSClient
   (options), WMP upgrade (in *full*), the Win98 help disc hotfixes (in
   *full*, Polish only).
2. `Dial_up_networking_v14\Win98SEpl_MEpl`: Me already has DUN 1.4; should
   the 98 SE PL package really be offered on Me?
3. Should any Microsoft redistributable (DirectX, VB6/VC6, MSI, MDAC, MSLU,
   .NET) ship in the USOS release under the same maintainer decision as the
   Windows 7/Vista update files, or stay user-supplied (current design)?
4. Pinned archive downloads (e.g. archive.org copies of the original
   Microsoft URLs): wanted? They need a network check per file.
5. Speech SDK 5.1: the local file has only merge modules. Provide the full
   `SpeechSDK51.exe`, or should USOS build a wrapper MSI from the modules
   at build time?
6. WinSPatcher 98 (FE) and NT are Inno Setup installers; listing them needs
   `innoextract` (GPL, a download). OK to add it to the build kit?
7. Missing files: Winsock 2 for 95 (`W95ws2setup.exe`), English IE 5.5/6 and
   SRP for English systems, a Polish DUN 1.4 for 95.
8. The 95 preset on a Polish 95 has no DUN (only an English package):
   acceptable?

## 5. Verification

Host: `tools/tests/addons/test_legacy_pack.py` (manifest validation; the
runner's pure C built with `zig cc` for the host: INI parser, versions,
detection table, variables, builtins, checks, state; 390 plan comparisons
C vs Python over every system × language × NT SP level × option sets;
expected presets; staging on a synthetic folder; the OpenWatcom target
build with its PE checks), wired into `tools/tests/run.ps1`. VM: QEMU 98 SE PL (the 9x agent's image and helpers)
with the store of the 98 SE plan; results in §6 once run.
