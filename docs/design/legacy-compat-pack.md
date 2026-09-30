# Legacy Compatibility / Post-Install Pack (Windows 95, 98, 98 SE, Me, NT 4.0)

Status: **design + manifest + runner + MS release asset + installer
component, branch `feature/legacy-compat-pack`, 2026-09-30.** Not yet wired into the 9x DOS Setup path (branch
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
| Microsoft redistributables asset | `tools/addons/legacy_ms_asset.py`, `tools/release/assemble_release.py`, `make_release.ps1 -LegacyAddons` |
| Installer component (Components screen) | `installer/internal/components/legacy.go` |
| QEMU test helper (98 SE) | `tools/tests/addons/win98se_vm.py`, `fat_image.py` |

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
| WinSPatcher 98 v1.0 (98 FE PL, 20050817) | **Inno Setup** 5.0.4 (innoextract 1.9) | `app\wpsetup.dat` lists every item with its silent switch: 21 security updates (`upd_c`, `/Q:A /R:N`, some through its wrapper `wpaicc.exe`), Windows Update client pieces, IE 6 SP1 PL, DirectX 9.0c, MS Agent + PL, JScript 5.6, MSI 2.0, .NET 1.1 + SP1 + PL (unpacked), WMP 7.1 (unpacked), JRE 1.5.0_04, two registry tweaks | its 13 updates that no other package carries (same SHA-256 = duplicate: 9 are the help disc's) became group `hotfixes-98-pl-extra` (98 FE only) via `tools/addons/import_winspatcher.py`; each item installs individually and silently |
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
| WinSPatcher NT v1.0 (NT4 Workstation PL, 20070409) | `WinSPatcher_NT_v1.0.exe` (134 MB), **Inno Setup** 5.1.10 | `SP6I386.EXE` (identical to the PL SP6a CD's), the PL SRP (identical to `POLQ299444i.exe`), 31 post-SRP updates with their switches in `wpsetup.dat` (NT hotfix installers `-m -z -q -o`, IExpress `/Q:A /R:N`), IE 6 SP1 PL (NT set), MS Agent, .NET 1.1 + SP1 + PL (identical to the user's), MS VM update | 28 updates not carried otherwise became group `hotfixes-nt4-pl` (after the SRP, in *full*); each has its Hotfix registry check where the file names a KB/Q number | batched |

NT4 order (preset `full` on NT4): SP6a (PL or EN by system language) →
restart → SRP (PL or EN) → restart → IE 6 SP1 (PL or EN) → restart → MSI
2.0 → MDAC 2.8 SP1 (PL) → restart → VB6, VC6 → .NET 1.1 → PL pack → SP1 →
28 post-SRP updates (PL) → restart. DirectX: none
beyond the DirectX 3.0a that SP3+ already carries. Options: RDP, DSClient,
WMP 6.4, ASPI, USB (Inside Out), HP printing. Found on 2026-09-30 (user-approved
downloads, §1.5): the English SRP and an English IE 6 SP1 set; English
post-SRP hotfixes are still missing (the WinSPatcher NT ones are Polish).

### 1.5 Downloaded on 2026-09-30 (user approval)

All outside git (scratchpad / `tools/cache`), SHA-256 pinned in the manifest;
the user puts them into `DATA\Addons` like the rest (found by hash).

| File | Size | SHA-256 | Source | Check | Package |
|---|---|---|---|---|---|
| `w95ws2setup.exe` (Winsock 2 for 95) | 986,400 | `48c82825...4d4922` | archive.org/details/w95ws2setup | Authenticode Microsoft Corporation, valid; SHA-1 as listed | `ws2-95` |
| `Q299444i.exe` (NT4 SRP, English) | 14,883,736 | `92386543...dafd843c` | archive.org/details/Q299444 | Authenticode Microsoft Windows 2000 Publisher, valid; SHA-1 as listed | `nt4-srp-en` |
| IE 6 SP1 English offline ISO | 82,536,448 | `9e6c3ea3...4cbf4a` | archive.org/details/microsoft-internet-explorer-6-sp1-iso | SHA-1 as listed; `iesetup.cif` LBASE=EN, 6.0.2800.1106 | `ie6sp1-en-9x`, `ie6sp1-en-nt4` (`unpack=iso`) |
| `SpeechSDK51.exe` | 71,278,472 | `826ba6df...386ba` | Microsoft Download Center (still live) | Authenticode Microsoft Corporation, valid | `speechsdk51` (MSI + Data.Cab taken out of the WinZip SFX) |
| `SpeechSDK51LangPack.exe` | 85,498,776 | `346afc3a...99256` | Microsoft Download Center | Authenticode Microsoft Corporation, valid | `speechsdk51-langpack` (`status=missing` until its long cabinet names are handled) |
| `innoextract-1.9-windows.zip` + source `.tar.gz` | 520,705 / 206,931 | `6989342c...93065` / `6344a69f...88126` | github.com/dscharrer/innoextract 1.9 | zip hash = the one published by the author; Zlib licence | build kit (`buildkit.lock.json`) |

Not found: a Polish DUN 1.4 for Windows 95 (Microsoft released it in
English only), so the English package is an option on a Polish 95
(`dun14-95-en-on-pl`).

### 1.6 Files the pack does not use

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

### 2.3 Presets, full pack and options

The user picks **one preset** instead of a long checkbox list (details
expandable); the manifest's `[presets]` / `[preset:<id>]` sections define
them, `SELECT.INI` carries `preset=`, extra `options=` and `exclude=`:

| Preset | Contents |
|---|---|
| **Do pracy** (default for every 9x/NT4 install, user can untick) | the full pack (`tier=full`) of the detected system |
| **Retro gry** | DirectX, VB6/VC6 runtimes, MSLU, MSI, ASPI (CD images, period copy protection), Me real DOS mode, USB sticks (NUSB), the period Windows Media Player |
| **Minimalny** | NT4 SP6a + SRP, USB sticks (NUSB), the 98 security updates |

- **Full pack** (*Pełny pakiet zgodności Windows <version>*) = every package
  with `tier=full` whose `os`/`lang`/`ntsp` fit the detected system, plus
  everything their `needs` pull in. Per system (Polish system):
  - 95: DCOM95, Winsock 2, IE 5.5 SP2 + Q810847, MSI 2.0, DirectX 8.0, VB6
    SP6, VC6 SP6, MSLU (DUN 1.4 is English-only: in *full* on English 95, an
    option on Polish 95, since Microsoft released no other language).
  - 98: IE 6 SP1, DCOM98, DUN 1.4, MSI 2.0, DirectX 9.0c, MDAC 2.8 SP1,
    VB6, VC6, MSLU, WMP 7.1, .NET 2.0 + PL, NUSB 3.3a, 13 hotfixes.
  - 98 SE: as 98 with DUN 1.4 SE + Q243199, WMP 9 + KB819639.
  - Me: IE 6 SP1, MSI 2.0, DirectX 9.0c, MDAC 2.8 SP1, VB6, VC6, MSLU,
    WMP 9, .NET 2.0 + PL (no DUN: Me has 1.4 built in; user decision).
  - NT4: SP6a, SRP, IE 6 SP1, MSI 2.0, MDAC 2.8 SP1, VB6, VC6, .NET 1.1 +
    PL + SP1.
- **Options** (`tier=option`, checkboxes under *Szczegóły*): KernelEx, Movie
  Maker, Speech SDK, RDP client, DSClient, ASPI, HP IP printing, MSCONFIG
  (95), DCOMCNFG, WMP 6.4, WMP 9 skin, Me real DOS mode, NT4 USB, extra 98
  updates (IE/OE cumulative, MSXML, MS VM, IDE cache, storage). Split
  confirmed by the user on 2026-09-30.
- `exclude=` removes a package; it is never pulled back in as a
  dependency, its dependents are dropped with the reason instead.
- The resolver (`plan.c`, mirrored in `tools/addons/legacy_manifest.py`,
  cross-checked by the tests for every system × language × NT SP level ×
  option/exclude sets and every preset): candidates → add providers for
  unmet `needs` → drop inapplicable ones and those whose needs stay unmet
  (logged with the reason) → sort by `order`.

### 2.4 Files on the stick

Three sources, all matched by size + SHA-256 (nothing is renamed by hand):

1. **USOS's own files** (`source=bundled`): `USOSADD.EXE`, the manifest.
2. **Microsoft redistributables** (`source=release`, 13 packages: DirectX
   8.0/9.0c, MSI 2.0 A/W, MDAC 2.8 SP1, VB6/VC6 runtimes, MSLU, .NET 2.0 +
   PL, .NET 1.1 + PL + SP1): one release asset
   `USOS-<version>-Legacy-pack-MS.zip` (~148 MB,
   `tools/addons/legacy_ms_asset.py`), built by `make_release.ps1
   -LegacyAddons <folder>` from the maintainer's local copy, **never in
   git**. It follows the existing two-installer model exactly like the WinPE
   and XP components: SHA-256 in `SHA256SUMS` and compiled into the
   installer (`buildinfo.ComponentSHA256`), embedded in the full installer,
   downloaded by the online installer from the USOS release; the Components
   screen card *Pakiet zgodności Windows 95/98/Me/NT 4.0* unpacks it to
   `DATA\Addons\USOS\MS\<dir>\<8.3 file>` (every file re-checked against
   `legacy-ms.json`). An archive.org copy may be added later only as an
   extra fallback; the primary source is our own release.
3. **The user's files** (`source=user`): copied **in any layout** to
   `DATA\Addons\` (e.g. the whole `łatki` folder, archives unpacked or not);
   found inside `.zip` and `.iso` containers named in `fileN` too.

Staging (`tools/addons/stage_legacy_pack.py` is the reference
implementation, used by the tests and the QEMU run; the installer / Legacy
Core port follows) writes the target tree of §2.5 for the chosen system.

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
6. fault tolerance: a failing package is marked `failed` with its reason
   (exit code, "not installed" when its check stays false, "interrupted
   twice") and the chain goes on; packages that need what it provides are
   skipped with the reason ("wymaga msi:2.0"), missing files as "brak
   pliku"; reasons persist in `STATE.INI` `[why]` across restarts;
7. when nothing is left (after the last pending restart): the summary
   *Pakiet zgodności USOS: zainstalowano X/Y, błędy: F, pominięto: Z* with
   one line per failed/skipped package and its reason, in the log and in a
   message box; RunOnce is not registered again.

A small window shows `USOS: instalowanie dodatków (3/14): DirectX 9.0c`
(English on non-Polish systems). The log (append) holds date/time, system
detection, the plan, every command line with its exit code and every state
change. Switches: `/dry` (detect and log the plan only; `/dry /as:98SE,PL[,6a]`
logs the plan another system would get), `/reset` (forget `STATE.INI`).

### 2.7 UI

- Answer profile (`docs/answer-profiles.md`), group *Wygląd i dodatki*:
  `addons_preset=praca|retro|minimal|none` (default `praca` for 9x/NT4),
  `addons_options=kernelex,rdp51-pl,...`, `addons_exclude=...`. The UEFI
  menu's profile page shows one line per preset (*Do pracy (pełny pakiet
  zgodności)* preselected, *Retro gry*, *Minimalny*, *Bez dodatków*) and an
  expandable *Szczegóły* list with the packages the preset gives this
  system plus the options applicable to it; greyed out with *brak pliku*
  when the file is neither on DATA nor in the MS asset, *wymaga nagrania
  odpowiedzi* for `needs-iss`.
- Installer, Components screen: the card *Pakiet zgodności Windows
  95/98/Me/NT 4.0* (embedded / download / local file / skip, like WinPE and
  XP; implemented, `installer/internal/components/legacy.go`).

### 2.8 Integration with the 9x agent's work

`feature/win9x-modern` has the DOS Setup path, `msbatch.zig` and the
`windows-9x` profile group, but no post-install hook yet (its §6 note was
written from the component list only; this document replaces it). This
branch is based on `master` and touches no file of that branch, so it
merges before or after it without conflicts; the hook (one MSBATCH line +
the C: seeding step) is a small follow-up once both are in. The QEMU run
(§6) uses exactly that hook: C: seeded by the host, the RunOnce line in
MSBATCH.

### 2.9 Later

- Hotfix layers for 95 / 98 SE / Me / NT4 from the WinSPatcher sets
  (inventory of the Inno Setup ones with innoextract, pending the user's
  download approval): each hotfix becomes a `tier=none` member of a
  `hotfixes-<os>` group, as done for the Win98 help disc.
- Clean-room replacements for the two bridges: MSCONFIG for 95 and the Me
  real DOS mode patch.

## 3. Redistribution decisions (per package)

Rule: bundle when the licence clearly allows it; Microsoft runtime
redistributables are shipped by **maintainer decision (2026-09-30)** in the
separate MS asset (their terms allow redistribution *with an application*,
which a stand-alone pack does not clearly meet; the user decided to ship
them anyway, at the maintainer's own risk, because original downloads are
gone and archives may disappear). For Microsoft runtimes the shipped or
user-supplied file is the **permanent** source (a clean-room DirectX, MDAC,
.NET or IE is not a sensible goal), so they are not bridges.

| Package | Terms | Decision |
|---|---|---|
| DirectX 8.0 / 9.0c redist | DirectX redistributable: unmodified, with *your application* | **MS asset** (maintainer decision 2026-09-30) |
| VB6 runtime, VC6 runtime | VB6/VS6 redistributable code, with applications built with them | **MS asset** (decision) |
| MSI 2.0 (InstMsiA/W) | Windows Installer redistributable, with applications | **MS asset** (decision) |
| MDAC 2.8 SP1 | MDAC redistributable, with applications | **MS asset** (decision) |
| MSLU | Platform SDK redistributable, with your application | **MS asset** (decision) |
| .NET 1.1 / 2.0 + langpacks, .NET 1.1 SP1 | .NET redistributable, with your application | **MS asset** (decision) |
| DCOM95 / DCOM98, DUN 1.4, WMP, RDP client, DSClient, IE, hotfixes, SP6a, SRP | end-user EULAs / download terms; no redistribution grant | **user file** (not part of the 2026-09-30 decision, which covers the redistributables; extending it is one manifest line per package) |
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

## 4. User decisions (2026-09-30) and what is still open

Answered: (1) the full/option split stays as designed; (2) no DUN 1.4 on
Me; (3) ship the Microsoft redistributables in a release asset under the
maintainer's own-risk decision, not in git (done, §2.4); (4) primary
download source is our own release, archive.org only an extra fallback;
(5) look for the full Speech SDK (found: Microsoft still hosts
`SpeechSDK51.exe` and `SpeechSDK51LangPack.exe`), wrapper MSI only as a
last resort; (6) innoextract into the build kit (it is zlib-licensed, not
GPL); (7) look for the missing files: found on archive.org `Q299444i.exe`
(English SRP, 14,883,736 B) and `w95ws2setup.exe` (Winsock 2 for 95,
986,400 B), an English IE 6 SP1 offline ISO (82,536,448 B); a Polish DUN
1.4 for 95 does not exist (Microsoft made only English). The full pack is
the default for 9x/NT4 installs.

Done: the downloads of (5)-(7) were approved by the user, pinned and
checked (§1.5); WinSPatcher 98/NT inventoried with innoextract (§1.2, 1.3).

### 4.1 OEM licence page (product item)

Windows 98 SE OEM media ignore `ShowEula=0`: the first-boot wizard always
shows *Umowa Licencyjna* (and asks for user name and key again, prefilled
from MSBATCH). Unattended installs therefore stop there. Design: the user
accepts the Windows licence **once, consciously, in USOS** (the answer
profile field `accept_eula=yes`, shown as a checkbox *Akceptuję umowę
licencyjną systemu Windows (wymagane przy nośnikach OEM)* on the
profile/confirmation screen, never preselected); only then USOS answers the
wizard for the user: the MSBATCH `[Setup]` keys that OEM mode honours are
set, and the remaining wizard pages are closed by a tiny first-boot helper
(the same RunOnce slot as USOSADD) that presses *Dalej / Akceptuję /
Zakończ* on the wizard windows by their class and control IDs; without the
acceptance the wizard is left to the user. QEMU run of 2026-09-30: the
agent accepted it by hand with the user's explicit approval.

## 5. Verification (host)

`tools/tests/addons/test_legacy_pack.py`: manifest validation; the
runner's pure C built with `zig cc` for the host (INI parser, versions,
detection table, variables, builtins, checks, state incl. reasons); 1248
plan comparisons C vs Python over every system × language × NT SP level ×
option/exclude sets and every preset; preset selection C vs Python;
expected full packs; staging on a synthetic folder; the OpenWatcom target
build with its PE checks; wired into `tools/tests/run.ps1`. Go:
`internal/components` (asset name, extraction with hash checks, bad names,
status), `internal/i18n` (the three new strings in all 27 catalogs).

## 6. Usability acceptance (per system) and QEMU results

"Sama instalacja to połowa sukcesu": after USOS the system must be ready
for work. Checklist, checked automatically in QEMU where the emulated
hardware allows it, and by hand on the X470 (RX 560, USB-only input):

| Check | 95 | 98 FE | 98 SE | Me | NT4 | How (QEMU) | X470 |
|---|---|---|---|---|---|---|---|
| Desktop reached without questions (after key/licence pages) | | | | | | screenshot | by hand |
| Resolution >= 1024x768, 32-bit if possible | | | | | | Cirrus 5446 driver (QEMU); vmdisp9x VESA on 9x (win9x branch) | RX 560 VESA modes |
| USB keyboard / mouse | | | | | | usb-kbd/usb-tablet | CSMWrap bridge (98/98 SE), none on Me/95 |
| USB stick readable | | | | | | usb-storage + NUSB (98) | NUSB on 98, native on Me |
| Network | | | | | | rtl8139/ne2k_pci (98 has drivers) | no 9x driver for the onboard NIC (gap) |
| Sound | | | | | | sb16 (98 driver) | no HD Audio driver on 9x (gap) |
| Clean shutdown / restart | | | | | | ACPI power-off in QEMU | by hand |
| Period apps start: IE 6, WMP, a DirectX app (dxdiag), a VB6 app, a .NET 2.0 app | | | | | | USOS test apps (to write) | by hand |
| Pack summary: `zainstalowano X/Y` with reasons | | | | | | `C:\USOS\addons.log`, message box | by hand |

QEMU results: see §6.1 (98 SE PL run of 2026-09-30).

### 6.1 QEMU 98 SE PL, 2026-09-30

Setup: `tools/tests/addons/win98se_vm.py` (fresh 4 GiB disk seeded on the
host: C:\WIN98 from the user's 98 SE PL OEM ISO, MSBATCH.INF with the
USOSADD RunOnce line, C:\USOS\ADDONS staged for preset *Do pracy* +
KernelEx + RDP; the CD's startup floppy with FDISK /MBR, SYS C:, SETUP;
QEMU 11.1 i440FX TCG, Pentium III, 256 MiB, Cirrus, no network). Product
key from a local file outside the repository; the VM disk was deleted
after the run. Results: pending (the run stops at the OEM first-boot
licence page until the user approves accepting it).

## 7. Known usability gaps (future work, not implemented)

- **Network on modern PCs**: no Windows 9x/NT4 driver for current Realtek
  (RTL8111/8125) or Intel (I211/I219/I225) NICs; options: a USB-to-Ethernet
  adapter with a 9x driver (e.g. old ASIX/Pegasus chips), a PCI(e) card
  with a period chip (RTL8139, Intel PRO/100), or an own NDIS driver.
- **Sound**: no HD Audio driver for 9x (only community experiments);
  options: a PCI sound card with a 9x driver, USB audio (Me/98 SE with a
  USB audio class driver), or nothing.
- **Modern web**: IE 6 cannot open today's HTTPS sites (TLS 1.2/1.3, SNI,
  SHA-2 certificates). Options: a period-compatible browser build (e.g.
  community forks for 9x through KernelEx), or a local HTTPS proxy on
  another machine / the USOS micro-Linux that terminates modern TLS.
- **Storage**: AHCI only through MS-DOS compatibility mode on 9x (slow);
  an own IOS port driver is future work (win9x doc §2).
- **USB 3 (xHCI)** on 9x: none; on NT4: none; USB 2 only through NUSB/EHCI
  when the board still has EHCI (the X470 has only xHCI).
- **Display acceleration**: VESA only (vmdisp9x), no 3D; NT4: VGA / VESA
  through a community driver (to evaluate).
- **Windows 95**: no USB input under CSMWrap in Setup phase 1 (licence/COA
  pages), see the win9x doc.
