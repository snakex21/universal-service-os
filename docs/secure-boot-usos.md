# Secure Boot: shim + MOK chain (2026-09-24)

USOS boots with Secure Boot **on** after the USOS key is enrolled once per
computer in MokManager, the same model Ventoy uses. Motivation: an ASUS ROG
Ally with Secure Boot on refused the unsigned `BOOTX64.EFI` with "Secure Boot
Violation - Invalid signature detected".

## Chain on the ESP

| Path | Content | Trusted by |
| --- | --- | --- |
| `\EFI\BOOT\BOOTX64.EFI` | shim 16.1 (Fedora `shim-x64-16.1-7`) | firmware db: Microsoft UEFI CA 2011 **and** 2023 (two signatures) |
| `\EFI\BOOT\mmx64.efi` | MokManager from the same package | Fedora CA built into that shim |
| `\EFI\BOOT\grubx64.efi` | USOS (the Zig UEFI app) + `.sbat` section | USOS key, enrolled in MOK |
| `\EFI\USOS\ENROLL_THIS_KEY_IN_MOKMANAGER.cer` | USOS public certificate (DER) | - |
| `\EFI\USOS\ENROLL-README.txt` | enrollment steps (EN, PL + 6 machine-translated) | - |
| `\EFI\USOS\secure-boot.ini` | `signed=1/0`, shim version, certificate SHA-256 | - |
| `\EFI\USOS\licenses\shim\` | shim licence and provenance | - |

shim starts `grubx64.efi` from its own directory. If that fails verification
(first boot, key not enrolled) it shows "Verification failed: (0x1A) Security
Violation" and starts `mmx64.efi`. There is no `fbx64.efi` on purpose: shim on
the removable path would otherwise run the fallback loader.

With Secure Boot off shim does not verify anything and simply starts USOS, so
the same layout works on every UEFI machine. Legacy BIOS boot is unchanged.

## Shim provenance and choice

- Package: `shim-x64-16.1-7.x86_64.rpm`, Fedora Koji build of upstream shim
  16.1 (commit `afc49558b34548644c1cd0ad1b6526a9470182ed`),
  <https://kojipkgs.fedoraproject.org/packages/shim/16.1/7/x86_64/shim-x64-16.1-7.x86_64.rpm>,
  RPM SHA-256 `0a119f3488e5da27ca55c1864ee8e131afa5ecf27689385ba09b805eb00dd608`.
- `shimx64.efi` SHA-256 `351e131d3c4a636704e9cae7d1296baf8a05beca9922cfebbfa48933c9bf1ad3`
  (1 036 008 bytes), `mmx64.efi` SHA-256
  `ed4442fa88cccba3a9e6a32d21a8f4c56bf5aab184f1fb9aadde8d3a9d04dc27`.
- SBAT: `shim,4`, `shim.rh,3`, `shim.redhat,3`, `shim.fedora,3`. Every SbatLevel
  published so far (latest `sbat,1,2025112400 shim,4 grub,6`) requires `shim,4`
  (15.8+), so this build is not revoked. Ubuntu still ships 15.8; Debian ships
  16.1 but without MokManager in the same package; Fedora 16.1-6+ adds the
  Microsoft UEFI CA 2023 signature, which matters for machines whose db only
  trusts the 2023 CA (the 2011 CA stops signing in 2026).
- Ventoy (1.1.14+) ships a Rocky Linux build of the same shim 16.1 for the same
  dual-signature reason, but then patches shim at hard-coded offsets to disable
  verification of everything it boots. USOS does not do that: everything it
  starts is verified by shim (MOK or db).
- Vendored under `tools/vendor/shim/16.1-7/` with `manifest.json` (pinned
  hashes checked by the build). It is a data asset, not a build dependency.
- Licence: shim is BSD-style (`COPYRIGHT` of shim 16.1, copied as `LICENSE`).
  Redistributing the distribution-signed binary is common practice.

Side effect worth knowing: like every current distro shim, it writes the
`SbatLevel` variable on first Secure Boot start (automatic level
`sbat,1,2024040900 shim,4 grub,4 grub.peimage,2`). That revokes old GRUB
builds (SBAT `grub` < 4) on that computer for all boot media, e.g. very old
Linux ISOs. Current distributions are not affected.

## Signing

`installer/cmd/usos-efisign` (Go standard library only, no new dependency;
signtool/osslsigncode/sbsign are not installed here and not needed):

- `internal/efisign/pe.go`: PE/COFF parsing, Authenticode SHA-256 hash (headers
  without CheckSum and the certificate directory entry, sections in file
  order, trailing data without the certificate table), stripping a signature,
  appending a section (`.sbat`), 8-byte padding and the `WIN_CERTIFICATE`.
- `internal/efisign/pkcs7.go` + `der.go`: hand-written DER for the PKCS#7
  `SignedData` with `SpcIndirectDataContent` (digest last, as EDK2's
  `AuthenticodeVerify` in shim expects), signed attributes (contentType,
  messageDigest, SpcSpOpusInfo, SpcStatementType), RSA PKCS#1 v1.5/SHA-256.
  Signing is deterministic. A parser/verifier is included for tests and for
  checking vendor signatures.
- Tests (`go test ./internal/efisign`): our hash equals the digest inside the
  Microsoft signatures of the vendored wimboot, the vendored shim and the
  local `C:\Windows\Boot\EFI\bootmgfw.efi`; sign/verify round trip; tamper,
  wrong-key and determinism checks; `.sbat` insertion; key round trip. The
  signed USOS was also checked with PowerShell `Get-AuthenticodeSignature`
  (status `UnknownError` = untrusted self-signed root, i.e. the hash and the
  PKCS#7 are valid; a broken hash reports `HashMismatch`).

What is signed with the USOS key by `build.bat` (step `usos-efisign release`,
after the Windows/DOS native support and before the Legacy BIOS checks):

| File | How |
| --- | --- |
| `EFI\BOOT\grubx64.efi` | USOS from `zig-out/manual-usb/EFI/BOOT/BOOTX64.EFI` + `.sbat` (`assets/secure-boot/usos.sbat.csv`: `usos,1`) |
| `EFI\USOS\micro-linux\vmlinuz-virt` | Alpine 6.18 LTS EFI-stub kernel, signed in place |
| `EFI\USOS\systemd-bootx64.efi` | Alpine systemd-boot 260 (already has `.sbat`), signed in place |
| `EFI\USOS\ntfs_x64.efi` | efifs 1.12 NTFS driver, signed in place |

Not re-signed: `wimboot` 2.9.0 is already signed by the Microsoft UEFI CA
(2011 + 2023) and keeps that signature. UefiSeven (`int10.efi`), CSMWrap and
the XP package are Secure Boot incompatible paths and stay unsigned.

`tools/verify_release_consistency.ps1` now checks that `BOOTX64.EFI` is the
pinned shim, that `grubx64.efi` is exactly the manual-test USOS binary plus
`.sbat`, padding and signature (`derive-check`), and that the four files
verify against the certificate on the stick.

Without a key the build still produces the same layout but **unsigned**, with
a boxed `[WARN] UNSIGNED BUILD` message and `signed=0` in `secure-boot.ini`.
Such a stick boots only with Secure Boot off.

## Key custody

- Key: RSA-2048, self-signed X.509, EKU codeSigning, digital-signature key
  usage, not a CA, valid 30 years. Subject `CN=USOS Secure Boot Signing 2026,
  O=Universal Service OS`, certificate SHA-256
  `1039d6f0c8cddf1769f13766edaaac4a30daf55986654655f9d41d6ea517d230`.
- Created once with `go run ./cmd/usos-efisign keygen`; stored in
  `%APPDATA%\USOS\signing\usos-secure-boot.key` (PKCS#8 PEM) and
  `usos-secure-boot.cer`. `USOS_SIGNING_DIR` overrides the directory. keygen
  refuses to overwrite an existing key.
- The private key never enters the repository: `.gitignore` ignores `*.key`,
  `*.pfx`, `*.p12` and `/signing/`. Only the public certificate is tracked
  (`assets/secure-boot/usos-secure-boot.cer`); the build warns when the local
  key does not match it.
- Back it up offline (e.g. an encrypted copy on separate media). If it is
  lost, a new key means every computer has to enroll the new certificate; the
  old one stays trusted until removed. If it leaks, anyone can sign code that
  those computers will trust: remove the certificate with MokManager ("Delete
  MOK") or `mokutil --delete ENROLL_THIS_KEY_IN_MOKMANAGER.cer` and rotate.

## Loading the next stages under Secure Boot

`src/platform/uefi/verified_image.zig` is used for every EFI file USOS starts
from its ESP (`esp_image_start.zig`, `e2e_flow.zig` systemd-boot,
`xp_preparation.zig`, `windows_native_iso.zig` wimboot) and for the NTFS
driver (`ntfs_driver.zig`). `secure_boot.zig` reads `SecureBoot`/`SetupMode`
and finds shim's `SHIM_LOCK` (605dab50-...) and `SHIM_IMAGE_LOADER`
(1f492041-...) protocols.

- Secure Boot off, or no shim: plain `LoadImage`, exactly as before.
- shim 16 (what USOS ships): in Secure Boot mode shim replaces
  `gBS->LoadImage/StartImage` with its own loader, which checks db, dbx, MOK,
  MokListX and SBAT (a missing `.sbat` is accepted for images loaded this way).
  USOS detects the hook (boot services pointer equals the loader protocol's
  `LoadImage`) and simply calls `LoadImage`: the MOK-signed systemd-boot and
  kernel, the Microsoft-signed wimboot and Windows boot managers all load.
  systemd-boot 260 recognises shim 16 and also uses the hooked `LoadImage` for
  the kernel.
- shim 16's loader frees an image as soon as its entry point returns, which
  would unload a boot-service driver. The NTFS driver is therefore verified
  with `SHIM_LOCK->Verify` and loaded by USOS itself (`image_probe/pe_loader.zig`:
  copy sections into boot-services code pages, apply DIR64 relocations, clear
  XP through `EFI_MEMORY_ATTRIBUTE_PROTOCOL` when present, install a
  `LoadedImage` on a new handle, call the entry point).
- shim 15.x fallback (not shipped, kept for robustness): the file is read,
  verified with `SHIM_LOCK->Verify` (System V ABI on x86_64) and loaded from
  the buffer while `EFI_SECURITY_ARCH`/`EFI_SECURITY2_ARCH` are overridden for
  exactly that buffer, the method systemd-boot uses for shim < 16.
- `verified_image.start()` replaces std's `startImage` everywhere USOS starts
  an image. std leaves the exit-data size uninitialised and trusts the callee;
  shim 16's `StartImage` hook writes it only when the image calls `Exit()`, so
  an EFI program that simply returns crashed USOS (NULL dereference found in
  QEMU with the OVMF debug log). The wrapper zero-initialises both outputs.
- A refusal becomes `error.SecureBootRejected`, shown as "Secure Boot rejected
  the file: it is not signed by Microsoft or by an enrolled key."

The chain of trust ends at the kernel: the initramfs and the kernel command
line (systemd-boot Type #1 entry written by the installer) are not verified,
as with most distributions that do not use unified kernel images.

## Linux lockdown impact

Alpine `linux-lts` 6.18 (config of 6.18.53 checked, same series as the
pinned 6.18.35): `CONFIG_SECURITY_LOCKDOWN_LSM=y` but
`CONFIG_LOCK_DOWN_KERNEL_FORCE_NONE=y`, and Alpine does not carry the
Fedora/Ubuntu patch that locks the kernel down when booted under Secure Boot;
mainline has no such code. `CONFIG_MODULE_SIG=y`, `CONFIG_MODULE_SIG_ALL=y`,
`CONFIG_MODULE_SIG_FORCE` unset, `CONFIG_KEXEC_FILE`/`KEXEC_SIG` unset, IMA off,
no kernel `.sbat`.

Result: under Secure Boot the micro-Linux runs **without lockdown**, so none
of its flows change. For reference, what a locked-down kernel
(`lockdown=integrity`) would affect in USOS:

- raw disk writes, `mkfs`, `sfdisk`, NTFS/FAT mounts, `smartctl` (SG_IO): allowed;
- modules: all come from Alpine's own build and are signed with the key built
  into that kernel, so `modprobe`/`insmod` keep working;
- `dmidecode` in the hardware panel: reads `/sys/firmware/dmi/tables` first
  (allowed); its `/dev/mem` fallback would be blocked;
- `kexec -l` (Windows BIOS handoff, `windows_bios_handoff.sh`): blocked, but it
  only runs in Legacy BIOS where Secure Boot does not exist;
- `/dev/mem`, `/dev/port`, `iopl`/`ioperm`, MSR writes, ACPI table overrides,
  unsigned modules: blocked; USOS does not use them in UEFI flows.

Open point: because the kernel is not locked down and the initramfs is not
verified, a person with physical access can use the USOS-signed kernel to run
arbitrary code as root on a machine that has enrolled the USOS key (for
example `kexec` another kernel). Ventoy's model has the same property (in a
stronger form). Closing it needs a kernel built with forced lockdown plus a
signed unified kernel image (kernel + initramfs + command line); not done yet.

## Entries that require Secure Boot off

`src/flow/secure_boot_policy.zig` (tested) marks, only when Secure Boot is
enforcing (`SecureBoot=1`, `SetupMode=0`):

- **Windows XP** (UEFI): CSM/CSMWrap path;
- **Windows 7**: UefiSeven/int10 and pre-Secure-Boot boot managers;
- **Windows Vista**: same reasons.

In the system list those rows get the badge "Requires Secure Boot off"
("Wymaga wyłączenia Secure Boot") and the detail "Turn Secure Boot off in the
firmware setup to use it", and cannot be opened. The start summary checks the
backend again (`backendRequiresSecureBootOff`) and shows a notice instead of
starting. BIOS-only entries (Windows 98/2000/DOS...) are already hidden by
the firmware-mode check. All strings exist in the 27 locales
(`boot.summary.secure_boot_*`, `boot.error.secure_boot_rejected`,
`installer.secure_boot.enroll_note`); every locale except English is marked
machine-translated (Polish via `machine_translated_prefixes`).

Old Windows boot managers revoked by DBX (BlackLotus, KB5025885): once a
computer applies the "Windows Production PCA 2011 in DBX" step, Windows
media whose boot manager is signed by that CA (Windows 7/8/10 and older 11
media) will not start with Secure Boot on. This cannot be predicted per
image, so it is not a menu badge: the failure is reported as
`SecureBootRejected` and the fix is newer media (Windows UEFI CA 2023 boot
manager) or Secure Boot off.

## First boot on a Secure Boot machine (ROG Ally)

Two ways to enroll the key (both in `EFI\USOS\ENROLL-README.txt`; the
installer shows the same instructions after an install, update or repair).

**Method A: prepare it in Windows** (the `mokutil --import` equivalent,
recommended for handhelds). In Windows on that computer, the installer's
Secure Boot note has "Prepare key enrollment on this computer" ("Przygotuj
rejestrację klucza na tym komputerze"). It writes two shim variables
(vendor GUID `605dab50-e046-4300-abb6-3dd810dd8b23`, attributes
NV|BS|RT = 7) with `SetFirmwareEnvironmentVariableExW` after enabling
`SeSystemEnvironmentPrivilege`:

- `MokNew`: one `EFI_SIGNATURE_LIST`, type `EFI_CERT_X509_GUID`
  (`a5c059a1-94e4-4aa7-87b5-ab155c2bf072`), `SignatureListSize` =
  28 + 16 + DER length, header size 0, `SignatureSize` = 16 + DER length,
  owner = the shim GUID, then the DER certificate (exactly what
  `mokutil --import` builds in `issue_mok_request`).
- `MokAuth`: mokutil's packed `pw_crypt_t` (172 bytes): `u16 method` = 4
  (SHA512_BASED), `u64 iter_count` = 5000, `u16 salt_size` = 16,
  `salt[32]` (16 chars of `[./0-9A-Za-z]`), `hash[128]` = the raw 64-byte
  SHA-512-crypt (`$6$`) digest of the ASCII password. MokManager
  (`store_keys` -> `match_password` -> `password_crypt`) recomputes it from
  the typed password.

On the next start of the stick shim's `import_mok_state` ->
`check_mok_request` sees `MokNew` and starts MokManager before the second
stage, so there is no "Verification failed" dialog first. MokManager deletes
`MokNew` as soon as it reads it and `MokAuth` when it exits, so the request is
single-use: if the 10 s countdown passes, run the helper again. The user
presses one key, **Enroll MOK** -> **Continue** -> **Yes**, types the
password (a USB keyboard is needed: MokManager takes printable characters
only, which a handheld's pad cannot produce), then **Reboot**. The helper
does not change anything else (no MokTimeout, no Boot#### entries).

**Method B: from the stick.** Boot the stick; shim shows "Verification
failed: (0x1A) Security Violation"; tap Enter once; MokManager's 10 s
countdown; any key; **Enroll key from disk** -> USOS ESP -> `EFI` -> `USOS`
-> `ENROLL_THIS_KEY_IN_MOKMANAGER.cer` -> **Continue** -> **Yes** ->
**Reboot**. No password, so arrows and Enter (D-pad and A) are enough.

### Why the Ally went straight to Windows (2026-09-24)

User report: Secure Boot on, the blue "Verification failed (0x1A)" dialog,
OK, then Windows 11 at once; no MokManager, no countdown. Checked:

- The stick has exactly the vendored files: `BOOTX64.EFI` = shim 16.1-7
  (`351e131d...`), `\EFI\BOOT\mmx64.efi` = MokManager from the same RPM
  (`ed4442fa...`), `grubx64.efi` = the release USOS (`57994856...`), same as
  `zig-out/usb`. No `fbx64.efi`, so `should_use_fallback()` is false.
- shim 16.1 `init_grub()`: `start_image(second_stage)`; on
  `EFI_SECURITY_VIOLATION`/`EFI_ACCESS_DENIED` it runs
  `start_image(MOK_MANAGER)` (`\mmx64.efi` joined to shim's own directory,
  the same path logic that found `grubx64.efi`), then retries the second
  stage once. If that fails again shim prints `start_image() returned
  Security Policy Violation`, waits 2 s and returns; the firmware then boots
  the next boot option (Windows Boot Manager).
- MokManager without a pending request shows a 10 s countdown
  (`console_countdown`, `WaitForKey`); any key opens the menu whose first
  item is **Continue boot**.
- QEMU with these exact files (`run_qemu_secure_boot.py --only timeout`):
  one Enter -> countdown shown -> after 10 s a second "Verification failed"
  -> shim gives up. The Fedora-signed MokManager loads fine under shim's
  vendor certificate.
- QEMU with four Enter presses 120 ms apart (`--only repeat`, what a held
  button or keyboard auto-repeat produces): dialog dismissed, countdown
  skipped by the 2nd key, **Continue boot** chosen by the 3rd, the second
  refusal dismissed by the 4th, shim returns and OVMF moves on. On screen it
  looks exactly like the Ally report. The Ally's pad reaches the firmware as
  a USB keyboard (ASUS MCU `0b05:1abe`, HID boot keyboard bound by AMI's
  driver, see `artifacts/ally-logs/input-devices.txt`), with the firmware's
  typematic repeat.

Most likely cause: repeated/held key events from the pad's keyboard
emulation. Not proven on the hardware; other causes that would also end in
Windows (MokManager failing to load, e.g. a dbx entry for the Fedora signer)
would show a second "Verification failed" or a `start_image() returned`
line for 2 s. Method A avoids the dialog entirely; method B works when the
first key is a short tap.

## QEMU verification

`tools/tests/secure_boot/run_qemu_secure_boot.py` (after `build.bat` with the
key) uses Fedora's SMM OVMF with Microsoft keys enrolled
(`fetch_ovmf_secboot.py`, `edk2-ovmf-20260812-8.fc44`, RPM SHA-256
`4edaeca4129f0680d3cba6d9ff17806ba3ee5ca0f5fcede4849ad0b4dfcdd243`) and a
read-only vvfat ESP. Results are recorded below.

Run 2026-09-24 (QEMU 11.1, q35 + SMM, TCG), all 17 checks passed:

| Scenario | Result |
| --- | --- |
| unsigned `grubx64.efi`, empty MOK | shim: "Verification failed: (0x1A) Security Violation"; USOS never starts |
| signed USOS, empty MOK | MokManager opens; enrollment driven with keystrokes (Enter, Space, Enroll key from disk, volume, `EFI/`, `USOS/`, the `.cer`, Continue, Yes, Reboot) |
| after enrollment | shim starts USOS; serial `[SECURE_BOOT] state=on shim_lock=yes shim_loader=yes` |
| unsigned `grubx64.efi`, key enrolled | still refused |
| probe as second stage | MOK-signed child EFI starts and returns safely; unsigned child rejected (`SecureBootRejected`); MOK-signed NTFS driver starts through the USOS PE loader; Microsoft-signed wimboot loads; MOK-signed kernel and systemd-boot load; systemd-boot boots the kernel and micro-Linux reaches its hardware panel (`[HARDWARE] READ-ONLY SESSION READY`) |

`tools/tests/secure_boot/check_authenticode.ps1`: Windows reports the four
USOS-signed files as `UnknownError` (self-signed root not trusted, hash and
PKCS#7 valid) and a one-byte-modified copy as `HashMismatch`.

Not covered in QEMU: the full install flow with DATA/WORK and the Windows
boot manager handoff under Secure Boot, and the menu badge rendering
(needs a DATA volume); the policy is unit-tested.

## Boot-time cost and what the screen shows (QEMU, 2026-09-24)

Measured in QEMU/TCG (q35, Fedora SMM OVMF 20260812, vvfat ESP, build
B260924-110301-FE1189E5), host timestamps on a live serial socket, 3 runs
each. "Handoff" is OVMF's `BdsDxe: loading Boot0002`.

| layout | handoff -> firmware StartImage | StartImage -> USOS entry | handoff -> USOS entry |
| --- | --- | --- | --- |
| USOS as BOOTX64.EFI (old), SB off | 13 ms | 1 ms | 14 ms |
| shim -> grubx64.efi, SB off | 12 ms | 249-265 ms | ~270 ms |
| shim -> grubx64.efi, SB on (MOK enrolled) | 168-181 ms (firmware checks shim's Microsoft signature) | 337-346 ms | ~515 ms |

After USOS entry nothing changes: the splash starts 3 ms later and the first
menu frame is presented ~59 ms after entry in every layout. On-launch
verification (secure_boot_probe, `esp_image_start.load` of the 14.5 MB
signed kernel and of wimboot): kernel 1316-1358 ms with SB on vs 144-151 ms
with SB off (+~1.2 s), wimboot 131-137 vs 42-44 ms (+~90 ms). TCG runs the
hashing far slower than hardware (shim's OpenSSL, no SHA-NI; on a Zen 3 the
kernel hash is in the tens of ms), so these are upper bounds, not hardware
numbers; reading grubx64.efi (971 KB) from a slow stick adds its own time.

Screen: shim 16.1 does not touch the console on a normal boot. `setup_verbosity()`
only queries the ConsoleControl mode (`setup_console(-1)` returns before any
SetMode); ClearScreen/SetMode are reached only through `console_print` /
`console_reset` (error messages, MokManager, `SHIM_VERBOSE`, "Booting in
insecure mode" when MokSBState disables validation). Frames sampled every
~100 ms show the firmware logo (plus OVMF's own `BdsDxe:` lines) unchanged
from handoff until the USOS splash, SB off and on: no black gap caused by
shim. Nothing needs changing (shim's binary must not be modified; its
Microsoft signature would break).
## Limitations and risks

- Each computer needs the one-time MokManager enrollment; a firmware reset of
  Secure Boot keys removes it (MOK lives in shim's NVRAM variables).
- Machines with the Microsoft third-party UEFI CA disabled (some Secured-core
  PCs) do not trust any distro shim; enable "3rd party UEFI CA" in the setup.
- Windows 7, Vista and XP still need Secure Boot off.
- The shim 15.x override path is implemented but only exercised by code
  review; USOS ships shim 16.1.
- wimboot and the Windows boot manager run under shim 16's loader when
  Secure Boot is on (the same mechanism distributions use to chainload
  Windows); tested in QEMU up to the loader, not yet on the Ally.
- Kernel not locked down, initramfs not verified (see above).
- `deploy_xp_uefi_csm_trial.ps1` accepts only the shim layout: the ESP must
  already have the vendored shim/MokManager and a USOS grubx64.efi; modes that
  copy EFI\BOOT take all three from a verified release tree (shim and
  MokManager hashes, derive-check of grubx64.efi), all other modes protect them.
- `deploy_csmwrap_trial.ps1` refuses to replace the new shim entry (its hash
  check no longer matches); the CSMWrap trial needs Secure Boot off anyway.
