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
| `\USOS-KEY.cer` | the same certificate at the ESP root, so MokManager's file browser needs one step (USOS_ESP -> USOS-KEY.cer); in the installer payload, checked equal by `verify_release_consistency.ps1` | - |
| `\EFI\USOS\ENROLL-README.txt` | enrollment steps (EN, PL + 6 machine-translated) | - |
| `\EFI\USOS\secure-boot.ini` | `signed=1/0`, shim version, certificate SHA-256, `certificate_root=USOS-KEY.cer` (informational: the ESP-root copy for MokManager) | - |
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
firmware setup to use it". They stay selectable (arrows, pad, wheel,
touch) so the badge and the help panel can be read; only starting them is
blocked, with the same text as a notice. The start summary checks the
backend again (`backendRequiresSecureBootOff`) and shows a notice instead of
starting. BIOS-only entries (Windows 2000/98/DOS...) are shown the same way
with the badge "Requires BIOS" (since 2026-09-24; before that the UEFI list
skipped them, so nothing below Windows XP could be reached). All strings exist in the 27 locales
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

The USOS key has to be trusted once per computer. MokManager's
physical-presence confirmation cannot be bypassed while Secure Boot is on,
so USOS offers three ways, easiest first. None needs a password (steps in
`EFI\USOS\ENROLL-README.txt`, in the installer guide and in the USOS menu
Tools -> Secure Boot -> "Add the key with Secure Boot on").

**Way 1: USOS saves the key itself while Secure Boot is off (no
MokManager).** Details in the next section. With Secure Boot off and a
platform key installed, the USOS home screen shows "USOS cannot find its
Secure Boot key on this computer. Add it?" ("Nie wykryto klucza Secure Boot
potrzebnego do uruchamiania USOS. Dodać go?") with **Add / Not now / Don't
ask again**. Add asks "Do you agree to save the USOS key in this computer's
memory?" (**No** preselected), writes MokList, reads it back and says "Key
saved. You can now turn Secure Boot on in the BIOS settings." with **Open
BIOS settings** (OsIndications `EFI_OS_INDICATIONS_BOOT_TO_FW_UI`, only when
`OsIndicationsSupported` has it). In Windows the installer's guide offers
"Restart into BIOS settings" (`shutdown /r /fw /t 0`) for turning Secure Boot
off first.

**Way 2: Secure Boot stays on, MokManager "Enroll key from disk".** Boot
the stick; shim shows "Verification failed: (0x1A) Security Violation"; tap
Enter once; **Enroll key from disk** -> USOS_ESP -> `USOS-KEY.cer` (ESP
root, new) -> **Continue** -> **Yes** -> **Reboot**. No password, so arrows
and Enter (D-pad and A) are enough. The installer's "Prepare (one time)"
only writes `MokTimeout` = -1 (see below), so MokManager shows its menu at
once and waits instead of the 10 s countdown a held button can skip.

**Way 3 (advanced, command line only): a MokNew request.**
`"USOS Installer.exe" -prepare-mok-enrollment -mok-password P` writes the
`mokutil --import` equivalent (`installer/internal/mokenroll`, vendor GUID
`605dab50-e046-4300-abb6-3dd810dd8b23`, attributes NV|BS|RT = 7, via
`SetFirmwareEnvironmentVariableExW` with `SeSystemEnvironmentPrivilege`):

- `MokNew`: one `EFI_SIGNATURE_LIST`, type `EFI_CERT_X509_GUID`
  (`a5c059a1-94e4-4aa7-87b5-ab155c2bf072`), `SignatureListSize` =
  28 + 16 + DER length, header size 0, `SignatureSize` = 16 + DER length,
  owner = the shim GUID, then the DER certificate (exactly what
  `mokutil --import` builds in `issue_mok_request`).
- `MokAuth`: mokutil's packed `pw_crypt_t` (172 bytes): `u16 method` = 4
  (SHA512_BASED), `u64 iter_count` = 5000, `u16 salt_size` = 16,
  `salt[32]` (16 chars of `[./0-9A-Za-z]`), `hash[128]` = the raw 64-byte
  SHA-512-crypt (`$6$`) digest of the ASCII password.

shim's `check_mok_request` then starts MokManager before the second stage:
one key, **Enroll MOK** -> **Continue** -> **Yes**, the password (a USB
keyboard is needed: MokManager takes printable characters only), **Reboot**.
It is no longer in the window: a password is one more thing to know or
forget, and the password-free ways above cover every case.

### Why a password-less MokNew is impossible (shim 16.1 source)

`MokManager.c`: `enter_mok_menu` shows **Enroll MOK** when `MokNew` exists and
calls `mok_enrollment_prompt(MokNew, size, auth = TRUE, FALSE)`; after
**Continue** and "Enroll the key(s)?" **Yes**, `store_keys(..., authenticate =
TRUE)` reads `MokAuth` and, when it is missing or has the wrong size
(neither `SHA256_DIGEST_SIZE` nor `PASSWORD_CRYPT_SIZE`), prints "Failed to
get MokAuth" and returns the error ("Failed to enroll keys"). There is no
branch that skips `match_password`, which requires 1..256 characters
(`PASSWORD_MIN` = 1, so an empty password is refused too). `check_mok_request`
deletes `MokNew` when it reads it, so such a request is also used up.
"Enroll key from disk" is password-free because it calls
`mok_enrollment_prompt(..., auth = FALSE)`: physical presence is the
confirmation. QEMU scenario `noauth` confirms this behaviour.

### MokTimeout (shim 16.1 source)

`MokManager.c` `draw_countdown()`: reads `MokTimeout` (shim GUID, packed
`INT32 Timeout`), deletes it right after reading, and uses it instead of
the default 10 s. A negative value returns at once without a countdown, so
`enter_mok_menu` shows the menu and waits for a key; 0 would skip the menu
entirely (`draw_countdown() == 0` -> `goto out`). `mokutil --timeout` writes
the same variable. `MokTimeout` alone does not start MokManager; shim starts
it after the second stage fails verification, which is exactly the first
start of the stick on a computer without the key. Being single-use, nothing
has to be restored afterwards. The installer writes `MokTimeout` = -1
(`ff ff ff ff`, NV|BS|RT, read back) and nothing else; `-check-mok` reports
`mokmanager_wait=true` while it is pending. QEMU scenario `wait`.

## Saving the key without MokManager (Secure Boot off)

shim 16.1 `mok.c`, table `mok_state_variables`, entry `MokList` (mirrored as
`MokListRT`): `yes_attr` = `EFI_VARIABLE_NON_VOLATILE |
EFI_VARIABLE_BOOTSERVICE_ACCESS`, `no_attr` = `EFI_VARIABLE_RUNTIME_ACCESS`,
flags `MOK_MIRROR_KEYDB | MOK_MIRROR_DELETE_FIRST | MOK_VARIABLE_LOG`, PCR 14.
`import_one_mok_state()` reads the variable with its attributes and, when a
required bit is missing or `RUNTIME_ACCESS` is set, logs "Variable MokList has
incorrect attribute" and deletes it. A variable without runtime access can
only be created before `ExitBootServices`, i.e. by the firmware setup, a
pre-OS application or MokManager, which is why shim trusts it. The content is
parsed as a sequence of `EFI_SIGNATURE_LIST`s (a zero `SignatureListSize` or
`SignatureSize` stops the walk). `import_mok_state()` does the same whether
Secure Boot is on or off (mirroring is unconditional). MokManager itself
enrolls by `SetVariable("MokList", NV | BS | APPEND_WRITE, <one X.509 list>)`.
Related variables: `MokListX` is the deny list with the same attribute rules
(USOS reports if its certificate is in it); `MokSBState` only disables
validation and `MokListTrusted` only controls kernel keyring trust, neither is
needed. SBAT applies to the images, not to the list (grubx64.efi carries
`usos,1`). shim measures MokList into PCR 14, not the PCR 7/11 BitLocker uses.

USOS therefore does what MokManager does, from its own menu, when:

- USOS was started by shim (the `SHIM_LOCK` protocol is installed) and the
  `SecureBoot` variable is not 1: Secure Boot off with a PK, **Setup Mode**
  (`SetupMode` = 1, no PK: the "Custom"/no-keys state ASRock/AMI boards ship
  until "Install default Secure Boot keys"), CSM on, or no `SecureBoot`
  variable at all. MokList is a plain NV|BS variable under the shim GUID,
  not an authenticated one: writing it needs neither a PK nor db, and shim
  honours it once Secure Boot is on. Never while Secure Boot is enforcing
  (`SecureBoot` = 1), and never when `SecureBoot` cannot be read for any
  reason other than `EFI_NOT_FOUND` (`src/flow/mok_list.zig`
  `saveRefusal`/`canSave`/`shouldOffer`, unit-tested including the X470
  state). With Secure Boot off anyone at the keyboard can run any code
  anyway, so this adds no new trust path;
- the certificate is on the stick (`\USOS-KEY.cer`, else
  `\EFI\USOS\ENROLL_THIS_KEY_IN_MOKMANAGER.cer`) and not yet in MokList;
- the existing MokList (if any) has trusted attributes.

`src/platform/uefi/mok_key.zig` `save()`: `SetVariable(MokList, shim GUID,
NV | BS | APPEND_WRITE, <EFI_SIGNATURE_LIST: EFI_CERT_X509_GUID, owner
SHIM_LOCK_GUID, DER>)`; if the firmware refuses append, it writes the merged
list (existing + ours) with NV | BS. Other keys are kept, ours is never
added twice. Then it re-reads MokList and requires NV|BS without RT and the
certificate inside (`VerifyFailed` otherwise).

UI (`manual_secure_boot.zig`, strings `boot.sbkey.*`/`boot.sbinfo.*` in all 27
locales, all but English machine-translated or marked):

- Home screen: a selectable banner under the category cards (Down from the
  last row, touch, click) with the offer. "Not now" hides it until the next
  start; "Don't ask again" writes `secure_boot_key_prompt=0` into
  `EFI\USOS\usos-settings.ini` (kept by the installer's settings merge) and
  says "You can add the key later in Tools -> Secure Boot".
- Tools -> **Secure Boot** (first row, shield icon, badge Saved/Missing): the
  help panel shows the key state, Secure Boot on/off/setup mode/unsupported,
  whether Secure Boot can be turned on (PK present), a deny-list warning, and
  when the key is saved how to remove it (MokManager "Delete MOK"; a Secure
  Boot key reset keeps it, only an NVRAM reset removes it; no removal button). Rows: **Add the key** (enabled only
  when saving is allowed; otherwise the reason), **Open BIOS settings**,
  **Remind on the home screen** On/Off (undoes "Don't ask again"), **Add the
  key with Secure Boot on** (the MokManager steps).
- At every UEFI start USOS writes `EFI\USOS\Logs\secure-boot-<SMBIOS
  UUID>.ini` (`secure_boot=`, `usos_key=saved|missing|unknown`, `shim=`,
  build) when its content changed; the installer reads it.

Previews: `zig build ui-preview`, screens `09`..`14`
(artifacts/boot-ui/secure-boot). QEMU scenarios `direct` and `setupmode`.

### The X470 report (2026-09-24): no offer in Setup Mode

Until build B260924-181530 the gate was `state == .disabled`, i.e.
`SecureBoot` = 0 **and** `SetupMode` = 0. The ASRock X470 (AMI Aptio) had
no platform key: `EFI\USOS\Logs\secure-boot-2E4F2079-...ini` on the stick
said `secure_boot=setup_mode usos_key=missing shim=yes`, and drivers.txt
`secure_boot=setup mode` (the same with CSM on and off; a second ASRock
board, D8A8A887-..., reported the same). The variables were read fine; the
gate refused Setup Mode on purpose ("Secure Boot cannot be turned on without
a PK"), which is wrong: the user turns Secure Boot on and installs the
default keys afterwards, and MokList is independent of PK/db. Now:

- the banner and "Add the key" appear in every state except `SecureBoot` = 1
  or no shim (and "Don't ask again");
- the Secure Boot page and the confirmation show the raw state
  (`SecureBoot=0  SetupMode=1  PK: Missing`, Microsoft UEFI CA 2011/2023 in
  db, shim, key in MokList/MokListX) and the guidance: in Setup Mode or
  without a PK "after turning Secure Boot on in the BIOS, install the
  default keys (Install default Secure Boot keys / Factory keys), including
  the Microsoft UEFI CA"; when CSM looks enabled (the CSM's
  `EFI_LEGACY_BIOS_PROTOCOL` is installed, or BootOrder has BBS/legacy
  entries) "on many boards Secure Boot needs CSM turned off"; with a PK but
  no Microsoft UEFI CA in db, that shim will not start; and while the key
  can be saved "add the key now, before turning Secure Boot on";
- `drivers.txt` and `input-devices.txt` get a `[SECURE BOOT]` section at
  every start: `SecureBoot`, `SetupMode`, `AuditMode`, `DeployedMode` (value,
  `absent` or `error:<EFI status>`), PK/KEK/db/dbx (GetVariable status, size,
  attributes), the Microsoft UEFI CAs in db, `shim_lock`/`shim_loader`,
  MokList/MokListRT/MokListX (status, size, attributes, whether the USOS
  key is in each), MokTimeout, the CSM evidence, and the gate
  (`can_save`, `refusal`, `remind`, `banner`) and guidance flags. The
  per-machine `secure-boot-<UUID>.ini` also carries `secure_boot_var`,
  `setup_mode_var`, `pk`, `mok_list`, `mok_list_rt`, `mok_list_x`,
  `csm_likely` and `can_save`.

**Confirmed on ASRock X470 hardware 2026-09-24, build B260924-202302**
(B260924-202302-7ED55EB2): the board was in Setup Mode (no PK). With Secure
Boot off USOS offered the key, saved it through this path, and with Secure
Boot then turned on shim started USOS directly, with no MokManager and no
"Verification failed". The MokManager file-enroll path (Enroll key from
disk -> USOS_ESP -> USOS-KEY.cer) was confirmed earlier the same day on
the ROG Ally RC71L.

### Does "Install default keys" / "Clear keys" remove the USOS key?

Normally not. AMI's "Install default Secure Boot keys"/"Restore Factory
Keys", "Clear Secure Boot keys"/"Reset To Setup Mode" and the Secure Boot
on/off switch rewrite PK, KEK, db and dbx (the authenticated variables under
the EFI global and image-security GUIDs). MokList is a separate,
non-authenticated NV variable under the shim GUID
(605dab50-e046-4300-abb6-3dd810dd8b23) that those operations do not touch.
It is lost on an NVRAM reset: CMOS clear, a BIOS update that reinitialises
NVRAM, or on some boards "Load UEFI defaults". If a key disappears, compare
the `[SECURE BOOT]` sections of two drivers.txt/input-devices.txt copies:
`MokList: status=not_found` with an unchanged PK means MokList itself was
wiped; `MokListRT` is only a volatile copy shim makes at each start. The
UI says the same (`boot.sbinfo.remove_hint`, `boot.sbkey.confirm_line2`):
remove the key with MokManager "Delete MOK"; a Secure Boot key reset keeps
it, only an NVRAM reset removes it.

### shim's clipped "Verification failed" box (X470 + BenQ over HDMI)

After Secure Boot was turned on (without the key) shim showed its
"Verification failed" box with the frame at the left edge and only "Ver"
visible at the far right. shim 16.1 `lib/console.c`: `console_select()`
takes `co->QueryMode(co, co->Mode->Mode, &cols, &rows)`, draws the title box
at column 0 across `cols` x `rows-1`, and centres the text on `cols`; it
never looks at GOP. `pe.c` `console_error(L"Verification failed", ...)`
leads there. shim.c and fallback.c never call `SetMode`; MokManager calls
`console_mode_handle()` (SetMode only above 1920x1080 with more than 200x100
cells) and `console_reset()` (`Reset` + `SetMode(0)`) on exit. So the box is
laid out for the firmware's text mode, and when that mode is wider than what
the monitor shows (a text mode for another resolution, or HDMI overscan
cropping the edges), the box is cut off. The Ally draws it fine. There is no
UEFI or shim variable that selects the text mode for the next boot (a
`SetMode` by USOS does not persist; `SHIM_VERBOSE` only switches shim to
plain-text messages plus debug output), so USOS changes nothing here.
Mitigation: add the key through USOS **before** turning Secure Boot on (the
box then never appears); otherwise turn off overscan on the monitor ("Just
Scan", "1:1", "Screen fit") and "Full Screen Logo" in the BIOS. To see the
mismatch, input-devices.txt now lists every GOP mode (current marked),
ConOut's current text mode with the pixels it needs at 8x19 per cell against
the GOP resolution, and every text mode.

## Installer: proactive card

At startup, after the drive detection and after every install, update or
repair, the installer (`secure_boot_card_windows.go`) checks, read-only:
UEFI or legacy BIOS, `SecureBoot`, `MokListRT` (visible only when Windows was
itself started through shim), `MokTimeout`, and whether the key is known to
be on this computer from

- `%APPDATA%\USOS\mok-enrolled-<SMBIOS UUID>`, written when a source below
  confirmed the key or the user clicked **Already done**;
- the per-machine report on any detected USOS drive
  (`EFI\USOS\Logs\secure-boot-<UUID>.ini`, `usos_key=saved`), matched by the
  SMBIOS system UUID (`GetSystemFirmwareTable('RSMB')`, formatted like
  Win32_ComputerSystemProduct and like USOS).

When the computer starts in UEFI with Secure Boot on and the key is not known
to be here, the home screen (and the final screen of an operation) shows
"Ten komputer ma włączony Secure Boot. Aby uruchamiać USOS bez wyłączania
Secure Boot, trzeba raz dodać klucz USOS. Kliknij Przygotuj (jednorazowo)."
with **Przygotuj (jednorazowo)** and **Już zrobione**. Prepare opens the guide:
way 1 with **Uruchom ponownie do ustawień BIOS**, way 2 with **Przygotuj**
(MokTimeout) and then **Uruchom ponownie teraz**, and seven drawn MokManager
screens (blue console, selection bar, captions): "Verification failed" ->
Enroll key from disk -> USOS_ESP -> USOS-KEY.cer -> Continue -> Yes ->
Reboot, plus "tap each button once, do not hold it". Screenshots:
`usos-installer-uidemo -shots` (artifacts/installer-ui/secure-boot). The demo
uses a fake firmware, a fixed UUID, a temporary marker directory and fake
restarts, so it never touches the PC it runs on.

## Why the Ally went straight to Windows (2026-09-24)

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

Run 2026-09-24 afternoon (build B260924-121942-ABFC5366), all 24 checks
passed, with three new scenarios:

| Scenario | Result |
| --- | --- |
| `timeout`: signed USOS, empty MOK, one Enter, then no key | MokManager countdown shown; after 10 s shim retries `grubx64.efi` (second refusal) and gives up |
| `repeat`: four Enters 120 ms apart | dialog, countdown and a second refusal all consumed, shim returns to the firmware (informational: the Ally symptom) |
| `helper`: NVRAM seeded (virt-firmware `--set-json`) with `MokNew`/`MokAuth` from `usos-efisign mok-request -password usos` (the installer's code) | MokManager opens by itself before any verification; Enroll MOK, Continue, Yes, password `usos`, Reboot; MokManager accepts the hash and the MOK-signed USOS starts |

The helper scenario needs `virt-firmware` without dependencies in
`tools/cache/secure-boot/pylib` (`pip install --target ... --no-deps
virt-firmware`; its `crypt_r` dependency does not build on Windows and is not
needed for `--set-json`).

Run 2026-09-24 evening (build B260924-132627-E7C8C649, key design without
passwords), all 41 checks passed (`artifacts/sb-qemu-20260924-key.log`,
screenshots in `artifacts/boot-ui/secure-boot/qemu`), with three new
scenarios:

| Scenario | Result |
| --- | --- |
| `noauth`: NVRAM with `MokNew` (the USOS certificate) and no `MokAuth` | MokManager opens by itself, Enroll MOK -> Continue -> Yes -> "ERROR Failed to get MokAuth: (0xE) Not Found"; nothing enrolled, USOS still refused |
| `wait`: NVRAM with `MokTimeout` = `ff ff ff ff` (the installer's Prepare) | after one Enter on "Verification failed" MokManager shows its menu with no countdown and is still waiting 15 s later (no second refusal); Enroll key from disk -> volume -> `USOS-KEY.cer` (second entry of the ESP root) -> Continue -> Yes -> Reboot; USOS starts under Secure Boot |
| `direct`: Microsoft PK/KEK/db, `SecureBootEnable` = 0, MokList (NV\|BS) holding a throwaway "Some Other Distribution MOK" certificate; second stage = the signed probe, which calls `mok_key.save()` | `[SB_PROBE] begin state=off`, `mok-save before key=missing lists=1 cert=yes can_save=yes`, `mok-save PASS key=saved lists=2`, a second save refused (`NotAllowed`, still 2 lists); the NVRAM file (virt-firmware JSON) has MokList attr 0x3 (NV\|BS, no RT) with both certificates. Same NVRAM with `SecureBootEnable` = 1 and the release USOS: no "Verification failed", no MokManager, `[SECURE_BOOT] state=on shim_lock=yes shim_loader=yes` |

The home-screen offer itself needs a DATA volume (the catalog opens before
the home screen), so the `direct` scenario drives the same `mok_key.save()`
through the probe; the screens are covered by `zig build ui-preview`.

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

- Each computer needs the key once (USOS with Secure Boot off or in Setup
  Mode, or MokManager). An NVRAM reset (CMOS clear, some "Load UEFI defaults",
  BIOS updates) removes it; resetting only the Secure Boot keys normally
  does not (MOK lives in shim's own NVRAM variables, see above).
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
