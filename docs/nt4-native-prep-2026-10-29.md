<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# NT4 native preparation, 2026-10-29

Preparation and host tests, **not an X470 installation PASS**. Base:
`claude/nt-native` at `2d7f2a238b5c663f083f8e5285c75adfc36689ac`.
Native Workstation/Server only; TSE and the VM/default routes retain their
previous selection. No merge, deployment, physical disk access or QEMU run.

## Portability audit

| NT351 mechanism | NT4 conclusion / implementation | Evidence and limitation |
|---|---|---|
| E820 filtering / RAM | Keep existing resident hook and sector-2 dump. Native NT4 sets hook byte 508 to 64 (16 MiB units = 1 GiB), byte 509 to 1 (PCI BIOS visible). Keep `/MAXMEM=1024` in native boot options. | NT4 `su.asm`, `eisac.c`, `memory.c` use legacy sizing and E820. `parsboot.c` handles installed-loader MAXMEM. 1 GiB is a conservative test cap, not a proven maximum for RTM/SP6a; text loader use of answer-file MAXMEM is not assumed. |
| VGA reservation | Retain common F0000–FFFFF reservation filter. | `memory.c` imports reserved descriptors; `spvideo.c` names Video0/open failures. The exact old X470 STOP is not reproduced for NT4. |
| CMOS century | Retain common conditional 32h→37h copy, only with valid BCD century and unused destination. | NT4 HAL `ixcmos.asm` normally uses 32h but switches to 37h when the ISA CMOS checksum is invalid; MPS includes the common implementation. Exact SP6a binary equivalence is not newly established. |
| MSZIP stored NLEN | Do not transplant the NT351 fixed-Huffman requirement. | NT4 `nfmdeco.c` and `mdi.nt/sources` enable LARGE_STORED_BLOCKS and read NLEN normally. The native kernel patch already stages expanded PE data, not a rewritten Microsoft CAB. |
| USB early | New NT4 helper `/early` registers existing usosusb Start=1, verifies SYS copy, Type/Start and Kbdclass/Mouclass ConnectMultiplePorts. Runs after SETUP.REG in late GUI CMDLINES. | Imports of helper and existing USB driver match original NT4 RTM media. This prepares the **first installed-system boot**; it does **not** establish HID availability earlier in GUI Setup. That remains an X470 qualification/integration gap. No i8042prt group-order rewrite. |
| BOOT.INI / cleanup | New `/finish` reuses own formatter: normal entry plus `[USOS /SOS]`, `[VGA mode]`, timeout 5; retains native options, removes C-root bootstrap entry, cleans fixed Setup/syslinux leftovers. | Backup BOOT.OLD; POST.OK and USB readback required. Actual formatter exercised with fake file APIs: success, idempotence, create/flush failure. Source trees removed only after a successful flush and valid BOOT.INI. |
| Pagefile | Existing own pagefile helper invoked by NT4 finish: 64/128 MiB. | Firmware cap also limits RAM seen during Setup. Runtime pagefile size and free space remain to be checked on X470. |
| setup_watch / logon_notice | NT4 uses its existing auto-logon/POST path rather than the NT3 service/watch/notice. | Failed finish records failure and suppresses automatic restart. POST.OK resumes finish without repeating service-pack installation. No claim that an NT3 service can be transplanted unchanged. |
| Server minor-errors dialog | Separate NT4 answerer recognizes exact English warning text plus “log file”, visible dialog and enabled IDNO button. Other dialogs are recorded only. | Compiled/import-checked, not runtime-qualified on NT4 Server; localized wording can require another explicit rule. |
| autochk | Leave NT4 autochk untouched. | No demonstrated NT4 need for the NT3-specific workaround. |
| Product key | Existing `answer.render(... key orelse p.keyFor(...))` feeds NT4 answer generation. Existing optional key gate is preserved. | Host tests use an unformatted placeholder and assert presence-only output; no product key included. |

## NT4 network isolation

The new candidate is `tools/nt/usosnet/bin/nt4/i386/usosnet4.sys`, compiled
with `USOSNET_NATIVE4`. Shared `bin/i386/usosnet4.sys` stays byte-identical,
including Windows 95 users. Only native NT4 staging selects the candidate.

HAL PCI/resource translation remains through NDIS/NdisMMapIoSpace. There is
no new direct-map fallback to conceal a resource conflict. The existing 20 ms
timer and IRQ watchdog remain; hardware IRQ delivery and I211 DMA have not
been newly proved. In NT4 `ndis40/mini.h` the optional enable/disable callbacks
dereference the interrupt object. The polling case can have no registered
object, so the native NT4 variant registers NULL callbacks, like the existing
NT351 configuration. ISR/handling functions retain chip masking/re-enabling.
NDIS's serialized timer may indicate packets; this does not permit registry
I/O at DISPATCH_LEVEL.

Breadcrumbs use DriverEntry RegistryPath + `Parameters\NativeDiag`, usually
`Services\NDISLoop\Parameters\NativeDiag`. Initialization writes are at
PASSIVE_LEVEL. Timer samples at approximately 1/2/5/10 s use four distinct
one-shot work items, own snapshots/events and a mutex; ZwFlushKey runs only
in the PASSIVE worker. Halt drains queued samples. This is a diagnostic
singleton for the existing one-adapter path, not a new multi-NIC guarantee.
Values include version, sequence, point, stage/error, alive seconds,
ISR/timer/RX/TX/poll/link/IRQ status. ISR itself never flushes the registry.

Protected `usosnet351n.sys` SHA-256:
`e52edc18170249741f0490f17c085cff4eee5f2269a4b7263dca9d43baaed095`.
NT351 preprocessed input before/after (nonempty lines, whitespace normalized)
is identical: `67f10301b7ef0d94da0b3aba77d9a45769caab9b7f89c3e573d323351c7fed00`.
NT351 sources/build351/INF/registry/network tests were not changed or rebuilt.

## Evidence and offline hardware test

Build through `build.bat` with explicit `USOS_NT_NATIVE_PREP=4`, external WDK
and Zig paths and fresh `USOS_NT_NATIVE_OUT` under own artifacts. The default
release build is unchanged. The build exercises six actual formatter checks
with an in-memory file model. Nine preparation tests and forty existing NT4
flow tests pass; import audit checks three new executables/drivers and the
existing USB SYS against original RTM exports. Emulator execution of the
unchanged hook covers both 64 MiB and 1 GiB caps (Unicorn, not QEMU).

Claude's hardware test should record yes/no for: text→GUI, USB input in GUI
(especially before CMDLINES), first desktop, USB replug/storage, DHCP/ping/
DNS/HTTP, restart and cold boot. Offline collect `C:\setup.log` when present,
`C:\USOS\NT4\USOSANS.TXT`, `POST.LOG`, `NATIVE.LOG`, `BOOT.OLD`, final
BOOT.INI, CSDVersion (expected SP6a 0x600), SYSTEM hive NativeDiag values and
raw sector 2 E820. Check the log for failed finish before retrying. Installer
network waits or all Server dialog variants are not certified by host tests.

## Source provenance

Own C/Python/shell implementation, with NT4 mechanisms established from local
`doors/Microsoft source code/windows_nt_4_source_code.7z`, paths relative to
`nt4/`:

- `private/ntos/boot/startup/i386/{su.asm,eisac.c}`;
  `private/ntos/boot/lib/i386/memory.c`;
  `private/ntos/boot/bldr/i386/parsboot.c`.
- `private/ntos/nthals/{halx86,halmps}/i386/ixcmos.asm`.
- `private/ntos/ndis/ndis40/{mini.h,timerm.c,configm.c}`;
  `private/ntos/ndis/ndis30/wrapper.c` (architecture context only).
- `private/windows/diamond/mszip/{nfmdeco.c,mdi.nt/sources}`.
- `private/windows/setup/textmode/kernel/{spboot.c,spvideo.c}`.

No Microsoft source/binary was added to git or outputs. Original CD checks
produce only hashes, export names and resource facts. Full local reports,
times, source hashes and patches are in the requested NT-NATIVE-PREP outputs.
No Internet used. Both tasks share original base; later Claude changes must
be reviewed manually before integration, especially shared usosnt3 and the
target shell script. STOP after report.
