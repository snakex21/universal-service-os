# Windows Vista SP2: BIOS installation through USOS

## Result and scope

Release `B260910-221344-DA435DDB` changes Vista to a direct handoff after 5/5,
without an intervening firmware restart. In VirtualBox with 2 GB RAM, a fresh
USOS menu selection prepared the original Vista ISO, entered Windows Setup,
accepted a blank 32 GiB target and began expanding Windows. The first restart
occurred later, during Windows installation, and returned to the normal USOS
menu without repeating preparation. The virtual source was then disconnected;
the target booted by itself and reached Vista's account-creation page. The VM
was shut down there; the direct test did not complete OOBE to the desktop.

The preceding release `B260910-211112-5903750E` used a preparation restart and
passed a complete Vista Business SP2 x64 installation to the desktop in a VM.
That earlier result does not establish the direct handoff on physical hardware.

The identity-checked Kingston was updated again on 2026-09-11 to
`B260911-125329-F4F2C97D` after the first physical direct-handoff attempt reached
the wimboot 2.9.0 banner and then stopped. That observation proves the no-reboot
Core -> Linux -> kexec -> wimboot transition itself executes on MS-7100, but not
that the subsequent firmware callbacks are safe. The new ordered payload adds an
INT 15h/e820 bridge: wimboot receives the Linux bzImage `boot_params` E820 map
instead of re-entering the legacy firmware for that call after Linux has run.
Non-E820 INT 15h calls still chain to firmware, and the existing INT13 disk-order
and geometry hooks remain unchanged. The protected-mode vendor wimboot payload
remains byte-for-byte unchanged from offset 0x0a00 onward.

The direct Athlon 64 X2 4200+/MS-7100 test of this new bridge remains pending.
VM/unit success must not be reported as proof that the physical transition is
fixed. These tests do not establish Vista x86, Vista UEFI or Windows 8/10/11 BIOS
installation support. The VM exposes the host CPU; it is not an exact Athlon
hardware emulation.

## Source

- File: `pl_windows_vista_with_sp2_x64_dvd_x15-36359.iso`
- ISO size: 3702233088 bytes
- SHA-256: `9b84e486b7979e3880e52cd7ab4c1f3211eee0b38e2bc0a886727ba7a5cb389f`
- Original Setup boot image: index 2, architecture 9, Windows 6.0.6002,
  SP build 18005; no replacement with a newer Windows PE.
- `sources/install.wim`: 3350651798 bytes.
- USB location: `Systems/Windows/Windows Vista/Images/`.

The installed language and edition come from the selected ISO and Windows
Setup. USOS's BIOS interface remains English.

## User flow

Choose Windows, Windows Vista, the ISO, Automatic, and None for unattended
configuration unless an answer file is intentionally selected. USOS prepares
its own WORK partition and copies the source there. Disk selection and
installation partitioning remain in the normal Vista Setup window.

After stage 5/5, keep the USB connected and wait for Vista Setup. The direct
handoff loads Windows PE into memory and enters wimboot without rebooting the
firmware or returning to Core. No automatic native boot marker is armed. A
subsequent boot from USB returns to the USOS menu.

After Vista copies/expands Windows and performs its own first restart, boot
the installation target. In the VM the source was detached at that point;
the rest of Setup and the desktop worked without it. On physical hardware,
select the Intel in the firmware boot menu or change boot priority as needed.

## Implementation and compatibility fix

The `windows-vista-iso` request uses the existing guarded ESP/DATA/WORK
preparation backend. It selects the Vista source folder and explicitly exports
the direct handoff, ordered BIOS entry and source-Setup settings. Its Linux
command line enables kexec just as the Win7 request does. Other system IDs are
rejected by this request path. Win7 retains its existing request behavior.

`windows_bios_handoff.sh` uses a separate ordered kexec payload for Vista. The
entry restores the PIC/PIT/IVT setup and text display, installs the existing
geometry fallback, then executes the same temporary disk-order hook as the
native Win7 fix. The two resident hooks occupy separate blocks below wimboot's
BSS. The observed BIOS USB drive is validated and patched into a RAM copy;
target sectors and firmware settings are not changed by these hooks. The
vendor protected-mode Windows loader payload is unchanged.

The native restart route remains available internally, but is not the Vista
default. Merely changing its progress label or using an already-prepared cache
would not satisfy the requested fresh menu -> 5/5 -> Setup flow.

The iPXE project's [wimboot documentation](https://ipxe.org/wimboot) describes
starting WinPE from a boot loader; its [architecture guide](https://ipxe.org/appnote/wimboot_architecture)
describes the CPIO -> bootmgr -> winload handoff. Neither is evidence that an
arbitrary motherboard supports returning to its BIOS services after Linux.

The first Vista VM attempt launched `X:\sources\setup.exe /installfrom:...`.
Despite WORK and the full WIM being accessible, Setup then displayed the
missing-CD/DVD-driver page. Launching the ISO's `WORK:\sources\setup.exe`
with the same explicit WIM path passed that page and completed installation.
Vista now uses this source executable, with its adjacent installation files.
Its existence is checked before WORK preparation. Win7 keeps its tested
RAM-resident Setup launch behavior.

The native source reader and quiet launcher are built for the Vista Windows
target without a C runtime. The launcher hides the preparation console and
retains visible diagnostics on failure. For removable USB, the existing signed
ImDisk reader maps only the identity-checked WORK range read-only inside
temporary Windows PE. Application logs remain beside the injected helper.

## Direct-handoff validation (2026-09-11 local time)

Evidence under `zig-out/vista-bios/`:

- `build-direct-load.log`: complete release build, Go checks, BIOS ISA audit
  and release/payload consistency passed.
- `ordered-kexec-tests.log`: eight real-assembly tests (four combined-entry,
  four native-hook controls) passed; `kexec-tests.log`: six existing entry
  tests passed. Tests cover return flags, geometry without a firmware probe,
  USB rotation, EDD results, memory separation and unchanged vendor payload.
- `direct-final-serial.log`: fresh production menu flow, all preparation stages,
  `handoff=direct` and `DIRECT HANDOFF PASS`. No native one-shot was used to
  reach Setup. The fixture started with the ISO and an empty WORK partition.
- `direct-final-setup.png`, `direct-final-page2.png`, `direct-final-disk2.png`,
  `direct-final-target-next.png`, `direct-final-installing.png`: original Vista
  Setup, product-key page, blank target selection and Windows expansion.
- `direct-target-only.png`: Vista account creation after source-free target
  boot. The first Windows installation phase and continuation completed.
- VM: `USOS-Vista-Final-Flow`, BIOS, 2 GB RAM, two host-profile CPUs, no network,
  source ahead of the separate target in BIOS order. Only file-backed disks.

## Initial report clarification and native reader improvement

The user initially reported a black screen, restart and a startup progress bar.
Readback found successful preparation and `ready=1` still waiting. The user then
clarified that the machine was powered off as soon as `LOADING STARTUP FILES`
appeared; no stall percentage or waiting period was observed. This is not
evidence of a failed Vista boot. The actual requested correction was to remove
the preparation restart.

The exact physical boot area and ESP were captured read-only in
`physical-retry-20260910-234208/boot-only.raw`. Its production Core matched the
delivered release and its CPIO booted Vista PE in VirtualBox. WORK was deliberately
omitted from this diagnostic clone, so the later missing-source dialog was
expected and is not an installation pass.

Native full-archive loading now caches FAT sectors and combines FAT-verified
contiguous clusters. Reading the captured 158379052-byte CPIO took 2889 reader
calls instead of 77341; both paths produced identical bytes and SHA-256
`2d6c0c16daa45e4ba4dc29d3d72fb0d3a7ac6f4b3fb42e9a4eebd69544db9e30`
(`fat-read-comparison.log`). Four new reader tests cover batching, fragmentation,
partial sectors, malformed chains, I/O errors and 64-KiB clusters. Native errors
now remain visible until ESC instead of disappearing behind the menu. This
optimization applies to the retained native path, not the new direct transition.

## Earlier native-handoff validation evidence

Evidence is in `zig-out/vista-bios/`:

- `build-final.log`: complete release build, unit/Go checks, BIOS ISA audit,
  packaging checks and release/installer payload consistency passed.
- `source-reader-tests.log`: all 14 existing reader tests passed for both
  architectures, including invalid GPT/CRC/range/identity cases and unchanged
  input verification.
- `serial.log`: initial complete menu/preparation/native restart flow.
- `target-start.png`, `install-progress.png`, `target-only-boot.png`,
  `desktop2.png`: blank 64 GiB target selection, installation, source-free
  continuation and Vista Business desktop in `USOS-Vista-BIOS`.
- `final-flow-serial.log`, `final-source-pass.png`: a second fresh preparation
  with the final release reached Vista's product-key page without a source
  error. `USOS-Vista-Final-Flow` used a separate blank target; Setup was stopped
  before selecting or modifying that target.
- Both VirtualBox runs used legacy BIOS, IDE disks, 2 GB RAM, two virtual CPUs,
  no network and the USOS source ahead of the target in BIOS boot order.
- `usb/driver-pass.png`, `usb/full-read-pass.png`: Vista's original Windows PE
  booted from its DVD in QEMU with a three-partition USB exposed as removable.
  The production helper mounted WORK read-only and read all 3350651798 WIM
  bytes successfully. QEMU reported zero writes and zero read failures on the
  virtual USB. This is a source-access test, not a QEMU wimboot boot test.

Only project-local virtual disk files were used for installation. No physical
Intel or host system disk was attached to a VM or modified.

## Kingston deployment

The updater revalidated USB model `Kingston DataTraveler 3.0`, size 61991813632
and disk GUID `31c644bf-74dd-4807-9cb2-46745adeadd4`, then verified the Core and
payload by readback. GPT identities, partition offsets and sizes were preserved.
The observed disk number was 8; subsequent work must resolve identity again.

`kingston-iso.txt` records the copied ISO's matching SHA-256. The earlier native
deployment is recorded in `kingston-update.log` and `kingston-final-check.log`.

`kingston-direct-update.log` records the update to `B260910-221344-DA435DDB`,
including readback and unchanged GPT identities and partition boundaries.
Core SHA-256: `01f1733f598301ff113d0289e6ce2915df013b331926bc280949fa4ddb0dc222`.
Initramfs SHA-256: `7162f8715ad4392e604ef7c3af9c0d68f574cd3626b2cabaa87a5d6bb98c7b11`.
`kingston-direct-final-check.log` confirms matching initramfs and disarmed native
one-shot. The old Win7 diagnostic switch was removed with a project-local backup.
The prepared Vista CPIO was verified unchanged. The next USB boot opens the
USOS menu; selecting Vista runs the new direct preparation flow.
