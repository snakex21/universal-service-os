# Windows Server 2008 to 2025 (2026-09-25)

Status: **experimental**. Every Server route shows `[EXPERIMENTAL]` in the
method list (`src/flow/backend_validation.zig`): the routes are the client
ones, but no Server ISO has been started through them in QEMU or on hardware
yet. Windows Server 2003 and 2000 need the NT5 staging and come later; they
have no catalog entry and no DATA folder.

## Menu and DATA folders

The Windows category lists the client versions first, then a non-selectable
**Windows Server** header (UEFI menu) and the Server entries, newest first:
2025, 2022, 2019, 2016, 2012 R2, 2012, 2008 R2, 2008
(`src/catalog/windows_server.zig`). The BIOS Core menu lists the same entries
after the client versions, without a header.

The folders mirror the client convention. Install and **Update USOS** create
them (`installer/internal/winhost/data_layout.go`):

```
Systems\Windows\Windows Server <version>\Images\        ISO (or WIM/VHD)
Systems\Windows\Windows Server <version>\Unattended\    autounattend.xml / unattend.xml
Drivers\Windows Server <version>\Storage\ USB\ Other\   INF packages (docs/drivers.md)
```

## Which path each version takes

Each Server entry is routed exactly like the client release that shares its
Setup (`route_as` in `src/catalog/os_profiles.zig`); only the folders differ.
The golden table (`src/flow/testdata/routing_golden.tsv`) pins the result.

| Server | Routed as | UEFI | BIOS |
|---|---|---|---|
| 2016, 2019, 2022, 2025 | Windows 10 | native wimboot start from the ISO (the ISO's own WinPE, ESP guard and finalizer) | Core native wimboot start (Windows 10 path) |
| 2012 R2 | Windows 8.1 | WORK copy + chainload | WORK copy + chainload |
| 2012 | Windows 8 | WORK copy + chainload | WORK copy + chainload |
| 2008 R2 | Windows 7 | native start: PE7 hybrid or the PE10 donor; Secure Boot off | micro-Linux Windows 7 request with `usos.legacy_folder_hex` |
| 2008 | Vista | native start through the PE10 donor (SP2 x64 only); Secure Boot off | Core native wimboot start (Vista path) |

Notes:

* 2008 R2 gets the bundled Windows 7 x64 driver library
  (`Systems\Windows\Windows 7\Drivers\x64`) plus `Drivers\Windows Server 2008 R2`;
  the Windows 7 SP1 NVMe packages are added for 2008 R2 SP1 media too.
* 2008, like Vista, gets no user drivers and refuses an answer file on UEFI.
* On the BIOS path of 2008 R2 the Core adds `usos.legacy_folder_hex=<hex>` to
  the Windows 7 request; `tools/legacy_windows_request.sh` accepts exactly
  `Windows Server 2008 R2` (windows7-iso) and `Windows Server 2008`
  (windows-vista-iso) and records the Server id as `selected_system`. The
  client command lines are unchanged.

## What the menu reads from the ISO

`src/image_probe/windows_media.zig` reads the XML metadata of
`sources/install.wim|esd|swm` (never decompressed) for each ISO of a Windows
folder, next to the architecture checks:

* **Server or client**: `INSTALLATIONTYPE` (`Server`, `Server Core`, `Client`)
  and `EDITIONID` (`ServerStandard`, `ServerDatacenterCore`,
  `ServerDatacenterEval`, `ServerHyperCore`, ...). `Client` wins, so Windows
  10 Enterprise multi-session (`ServerRdsh`) stays a client edition.
* **Editions**: the summary lists them as Setup will offer them, for example
  `Standard (Core), Standard (Desktop Experience), Datacenter (Core), ...`
  (Polish: `z pulpitem`). The image list says `Windows Server Setup`.
* **Folder hint**: Server media in a client folder, or client media in a
  Server folder, gets "belongs in Systems\Windows\<folder>" in the image list
  and a note on the summary. The folder comes from the version of the first
  image (6.0 = 2008 ... 10.0.26100 = 2025). The image can still be started.
* **IA64**: an Itanium image (`efi/boot/bootia64.efi`, `ARCH` 6 in boot.wim or
  install.wim) is blocked with a message on every firmware, like 32-bit media
  on 64-bit UEFI.
* **x86 Server 2008**: the same gate as Vista x86: blocked on 64-bit UEFI,
  allowed on BIOS/CSM and 32-bit UEFI.
* **2012 without NVMe**: Windows Server 2012 (not R2) Setup has no inbox NVMe
  driver. When the PC has an NVMe controller (PCI class 01h/08h, read through
  `EFI_PCI_IO_PROTOCOL` in `src/platform/uefi/uefi_drivers.zig`) and
  `Drivers\Windows Server 2012\Storage` is empty, the summary says to put the
  NVMe driver there. It is a hint, not a block.

## Answer files for Server

The existing answer-file handling is used unchanged (UEFI native starts:
`usos-unattend.xml` from `Systems\Windows\<folder>\Unattended`; WORK paths:
the file is copied next to Setup). Server-specific points:

* **Administrator password.** Server Setup has no user-account page; it stops
  at the Administrator password screen unless the answer file sets
  `Microsoft-Windows-Shell-Setup` / `UserAccounts` / `AdministratorPassword`
  in the `oobeSystem` pass. Remember that the file is stored in plain text
  (or base64 with `PlainText=false`, which is not encryption) on DATA.
* **Edition choice.** Each Server edition exists twice, as Server Core and
  with the Desktop Experience, so a product key alone does not pick one image.
  Select the image in `Microsoft-Windows-Setup` / `ImageInstall` / `OSImage` /
  `InstallFrom` / `MetaData` with `Key` `/IMAGE/INDEX` (the number shown by
  `dism /Get-WimInfo`) or `/IMAGE/NAME` (for example
  `Windows Server 2022 SERVERDATACENTER`). The usual order on 2012 to 2025
  media is 1 Standard Core, 2 Standard Desktop, 3 Datacenter Core,
  4 Datacenter Desktop, but check the ISO: evaluation and multi-edition media
  differ.
* **Product key.** Retail and volume media ask for a key unless
  `Microsoft-Windows-Setup` / `UserData` / `ProductKey` / `Key` is set
  (the generic KMS client setup key of the edition works for installation);
  evaluation media need none.
* **2008** (Vista path) refuses answer files, like Vista.

## Tests

* `zig build test`: routing golden (new rows only), Server edition detection
  from the fixture metadata in `src/image_probe/testdata/`
  (`install-server-2022.xml`, `install-server-2008-r2.xml`, the IA64,
  eval/Hyper-V and client fixtures), the Server wimboot plans and the BIOS
  command line with `usos.legacy_folder_hex`.
* `python tools/tests/test_windows_setup_media.py`: Server driver folders in
  `extract.sh` and the BIOS request folder check.
* `go test ./...` in `installer`: the DATA folders.

Open: no Server ISO has been run in the `windows_native` QEMU harness yet
(none is available locally); the staged payload golden
(`tools/tests/golden/staged_payloads.tsv`) must be regenerated after the next
micro-Linux build, because `micro_linux_init.sh`,
`legacy_windows_request.sh` and `windows_setup_media.sh` changed.
