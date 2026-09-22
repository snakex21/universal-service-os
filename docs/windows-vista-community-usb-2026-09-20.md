# Vista community USB method — v11 hardware success

## Current status: user-confirmed desktop and USB

After the v11 physical boot, the user reports that both USB mouse and keyboard
started, the automatic pre-Setup mechanism continued, and Vista reached the
desktop on Ryzen 7 5700X / ASRock X470 / RX 560 with CSM enabled. This confirms
working input and desktop access for this installation. It does not establish
pure UEFI support, every USB port/controller, clean unattended installation,
or completion of the pending CBS transaction.

OOBE spent a long time on the performance-assessment screen. The user powered
off, then reports creating a second user and reaching the desktop after
"Preparing your desktop". Therefore an uninterrupted OOBE pass is NOT confirmed.
The reported approximately 2 GB RAM use is not a measured leak or established
driver defect; process/commit/cache data were not supplied.

Next work is a reproducible installation from the USOS USB stick: image
deployment, image-appropriate drive-letter mapping, complete BCD, KB2864202,
the v10 catalog trust chain, and v11 direct device installation before Setup.
The current Intel deployment was prepared offline from a technician Windows
host, not by the production USB ISO menu. Keep the working installation as a
reference and do not blindly re-arm its Setup hook or reset servicing state.

The entries below preserve the diagnostic history, including failed approaches;
their "pending" statements describe the state at that historical step.

Prepared on 2026-09-20 for the existing Intel SSD installation (M: on the
technician host, D: when Vista boots). The USB stick, partition layout, BCD and
offline registry were not changed. The existing v4 pre-Setup hook remains armed.

## Sources and validation

Community sequence: install KB2864202/KMDF, then the Windows 8 USB-stack backport:
https://msfn.org/board/topic/181697-usb-3xxhci-generic-driver-for-win7-and-vista/
Its old MediaFire link returned 404. The alternative MSFN attachment returned
403, so neither was downloaded or presented as the package used.

Actual unmodified USB package used:
https://github.com/marie-systems/win7-sp2/tree/3e6b67ca6e1d77972ba82c6c55d9e296ec724eac/patches/drivers/USB3/XHCI/x64
The INF has a Vista amd64 target. All imports in ucx01000.sys, usbd8.sys,
usbhub3.sys and usbxhci.sys resolve against original Vista SP2 plus the Microsoft
KB2864202 files. This is a static compatibility check, not proof of hardware
operation. SignTool /pa verified all five INF/SYS catalog memberships and
signatures with exit 0. The original Riolin publisher and intermediate
certificates are installed only in target TrustedPublisher/CA stores, not as
new root authorities. No SYS, INF or CAT content was altered.

Microsoft Update Catalog update ID:
`6b1b8a34-db7e-4f4b-9ed4-c0003bf61a5d`.
Downloaded Vista x64 MSU SHA256 matches Microsoft's published value:
`d7afa8d43bea9fff12485962ff23c048a2bc916785457947805f45784c62989a`.
The target's existing Wdf01000 version is 1.7.6001.0; the KB package contains
1.11.9200.16648 and WdfLdr with the missing class-library exports.
The extracted complete CAB hash is embedded into the prerequisite executable
and retained with source URLs in `community-driver-manifest.json`.

## What happens on the next hardware boot

1. `D:\USOS\usb.exe` launches `usos-vista-kmdf.exe` before windeploy.
2. On Vista build 6002 only, it verifies the CAB hash, records a one-attempt
   marker, and runs Vista's own Pkgmgr to install the complete KB2864202 CAB.
   It waits for process completion and preserves the exit code/log.
3. Exit 0 or 3010 requests a restart before any USB installation. The pre-Setup
   entry is preserved. After reboot the actual framework file version must
   show at least 1.11; an unsuccessful previous attempt blocks automatic retry.
4. The USB helper adds the original catalog publisher/intermediates, stages
   GenericVista/USBXHCI.inf, and binds detected AMD 43D0 and 149C controllers.
5. Windeploy starts only if a controller, HID mouse and HID keyboard report
   started devnodes without problem codes. Actual input still requires the user
   to verify it. Failure keeps the diagnostic screen instead of falling through.

**The KB has only been staged, not installed yet.** Native package servicing
during this early Vista startup and USB operation on X470 still require the
physical boot. This is not claimed to be an exact reproduction of the Reddit
5700X report, which omitted the board and package version.

## Checks and recovery

All three helpers compiled successfully using Zig for Vista x64. Their imports
resolve against original Vista SP2 exports. No VM/E2E was run. The guarded
deployment verified disk GUID, model, size, partition identity, startup-hook
registry state and all copied file hashes. Offline SYSTEM/SOFTWARE/COMPONENTS
hashes stayed unchanged. Final NTFS state was NOT Dirty.

Backup: `zig-out/vista/community-deploy-20260920-220241` (previous USOS files,
Panther, SYSTEM/SOFTWARE/COMPONENTS and WDF binaries). These are diagnostic and
file-deployment backups, **not a full-image rollback for a later CBS update**.
The deployment script can roll back its copied files; do not roll back only
hives after native package servicing has changed the component store.

Tools: `tools/windows_vista_kmdf.c`, `tools/windows_vista_firstboot.c`,
`tools/windows_vista_usb_bootstrap.c`, `tools/deploy_vista_community_usb.ps1`.
Target logs are beside the helper under `D:\USOS\Vista`: `kmdf-before-setup.log`,
`kmdf-pkgmgr.log*`, `firstboot-usb.log`, SetupAPI snapshots. Bootstrap log is
`D:\USOS\usb-bootstrap.log`. Do not delete the attempt marker blindly after an
error; inspect servicing logs first.

## Hardware follow-up: resume v6

The user reached the Vista "Other user" logon screen without USB. Readback
confirmed Pkgmgr exit 3010 and an accepted restart request. Wdf01000.sys is now
1.11.9200.16648 and WdfLdr.sys is 1.11.9200.16384. This confirms updated framework
files, not completion of Windows account/OOBE setup. `pending.xml` still exists;
no pending servicing state was deleted or declared complete.

There was no v5 USB-helper entry in its log. SYSTEM still had the correct
`D:\USOS\usb.exe` CmdLine and SystemSetupInProgress=1, but SetupType was 0,
explaining why the pre-Setup sequence did not resume. The exact writer that
reset the flag was not identified. The bootstrap now explicitly re-arms it
after successful package servicing and when stopping on a USB error.

The guarded resume script prepared and deployed the SYSTEM change from the
current, post-servicing hive, preserving every other registry value. It copied
the newly compiled bootstrap and checked readback hashes. SOFTWARE, COMPONENTS
and both WDF files remained byte-for-byte unchanged. Backup:
`zig-out/vista/resume-usb-v6-20260920-221607`.
No VM/E2E or further hardware boot was performed. Actual community USB-driver
installation remains pending the next boot; the updated KMDF should be detected
and skipped rather than installed again.

## Hardware follow-up: certificate chain v7

The next physical boot reached the v6 console gate. KMDF check returned 0,
but the USB helper returned `0xe0000247` from SetupCopyOEMInf. The preserved
SetupAPI snapshot reports catalog signature failures `0x800b0109` (untrusted
root) and `0x800b010a` (cannot build chain). No successful USB driver start was
observed. NTFS was dirty after power-off; guarded chkdsk /f /x repaired it
(exit 1, then NOT Dirty) before the complete diagnostic snapshot was read.

Read-only inspection of the target SOFTWARE hive found no self-signed DigiCert
Assured ID Root CA in ROOT, AuthRoot or CA. The previous helper imported its
Microsoft-cross-signed counterpart only into CA. The genuine root was fetched
from https://cacerts.digicert.com/DigiCertAssuredIDRootCA.crt and pinned against
the fingerprint published at
https://knowledge.digicert.com/general-information/digicert-trusted-root-authority-certificates:
`3e9099b5015e8f486c00bcea9d111ee721faba355a89bcf1df69561e3dc6325c`.
Its self-signature, CA constraint, and issuer signatures for the catalog signer
and timestamp chains were verified during header generation. This is not a
runtime Vista Authenticode-policy test.

The v7 helper imports that genuine self-signed root into target ROOT and also
adds the catalog's timestamp CA intermediate to CA. Publisher and cross-signed
certificates are never promoted to roots. SetupAPI snapshots are explicitly
flushed after copying. The driver INF/SYS/CAT files remain unchanged.

Zig compilation exited 0. All 38 imports of the updated helper resolve against
original Vista SP2 x64 binaries. Guarded deployment copied only the updated
USB helper and its provenance manifest, verified both hashes, and confirmed
the startup gate remains armed. SYSTEM, SOFTWARE, COMPONENTS, WDF binaries,
USB driver files, bootstrap and prerequisite helper remained unchanged.
The certificate import will occur on the next target boot, not on the host.
Backup: `zig-out/vista/usb-cert-v7-20260920-223033`.
Helper SHA256: `f2ca2c2382115cceafa4d4f4560c579340defa5bf44395e0ab409677e632ab71`.
No VM or E2E was run. USB functionality remains unconfirmed until physical boot.

## Next user-reported failure and Windows 7 package comparison

The user confirms another failed boot after v7 deployment. Readback still finds
the exact v7 executable hash on the Intel, but neither its version marker in the
USB log nor its DigiCert root in offline ROOT/AuthRoot. Bootstrap and SetupAPI
logs also contain only the previously observed attempt. Consequently the new
failure cannot be assigned the previous signature error without fresh evidence.
The volume was dirty again. Guarded chkdsk completed with exit 1, no bad sectors,
and a subsequent NOT Dirty status. The recovered logs still do not show v7.
A photograph of the current console is needed to identify the actual stop.

Static comparison against the current Vista kernel and updated WDF confirms
that the repository's Win7 USB_Generic 6.2.9200.24610 package cannot simply be
copied over: its INF targets NTamd64.6.1, and its SYS imports require missing
Vista kernel exports, including KeGetCurrentProcessorNumberEx,
KeQueryActiveProcessorCountEx, KeGetProcessorIndexFromNumber,
KeQueryHighestNodeNumber, ObfReferenceObjectWithTag and
ObfDereferenceObjectWithTag. Editing the INF cannot supply those functions.
The community 6.2.9200.22453 package targets NTamd64.6.0; all its imported
symbols resolve against Vista plus its own companion USBD8.SYS and updated WDF.
This establishes only static compatibility, not successful driver initialization.
No driver package, helper or registry was replaced during this comparison.

## Photo and fresh logs: publisher trust v8

The user's console photo and newly readable v7 log confirm `0xe0000242`, not
the previous `0xe0000247`. SetupAPI now records "Success: File is signed in
Authenticode(tm) catalog", followed by an untrusted/unknown publisher rejection.
Both controllers still report problem 0x1c and no HID devices are started.
Microsoft documents this code as publisher trust not yet established:
https://learn.microsoft.com/en-us/windows-hardware/drivers/install/troubleshooting-driver-signing-installation
Silent driver installation requires the signer in the machine TrustedPublisher
store: https://learn.microsoft.com/en-us/windows-hardware/drivers/install/trusted-publishers-certificate-store

The exact reason SetupAPI failed to see trust is not yet proved. Earlier code
only verified the added certificate through its own open physical-store handle.
V8 replaces that inadequate check with explicit machine registry persistence
using CERT_STORE_PROV_REG, independent exact-DER readback of the registry Blob,
and RegFlushKey. This happens in a separate Vista-only trust helper. The fresh
driver-helper process must then find every expected certificate through the
logical machine stores before opening SetupAPI and staging the driver. Any
write/readback error stops the sequence with its actual code. No interactive
publisher prompt, blanket signature-policy change, or synthetic trust root was
introduced. Original driver and certificate contents remain unchanged.

Fresh failure evidence was copied to `zig-out/vista/before-v8-20260920-225102`
before servicing the dirty volume. Guarded chkdsk returned 0, then NOT Dirty.
Four helpers compiled successfully using Zig; imports resolve against Vista SP2
x64 (bootstrap 30, USB helper 37, prerequisite 33, trust helper 26). No helper
was executed on the host and no VM/E2E was run.
Guarded deployment verified the Intel disk/partition identities, copied v8 trust,
USB helper and bootstrap, checked hashes, and confirmed the pre-Setup gate.
Offline SYSTEM/SOFTWARE/COMPONENTS, KMDF and driver package bytes stayed unchanged.
Backup: `zig-out/vista/usb-cert-v8-20260920-225129`.
V8's effectiveness and USB functionality remain pending the next physical boot.

## Confirmed v8 failure; local catalog trial v9

The next physical boot ran v8. Every certificate write and fresh-process logical
store readback returned 0, including TrustedPublisher, but SetupCopyOEMInf still
returned `0xe0000242`. Offline SOFTWARE inspection now also finds the exact
Riolin certificate bytes in machine TrustedPublisher. Thus missing persistence
or inability to read that store does not explain the remaining rejection.
No USB controller or HID input has started. The precise remaining Authenticode
publisher-policy failure is unresolved; certificate expiry is not asserted as
its cause.

V9 is a separate local test-signing experiment, following the supported test
catalog mechanism documented at:
https://learn.microsoft.com/en-us/windows-hardware/drivers/install/test-signing-driver-packages
It re-signs a COPY of the existing community catalog using the already-created
project-local USOS test certificate. The original source package is preserved.
OpenSSL smime verifies the new signature against that pinned certificate; the
decoded catalog content is byte-identical to the original, and all five INF/SYS
files remain byte-identical. Only the CAT signature is replaced. No timestamp
server or new download was used. Private key/PFX stay in the project, and the
technician host trust stores are untouched. The target already runs in test
signing mode, visibly confirmed by the user's photo.

The existing v8 trust persistence/readback mechanism now imports the explicit
local test certificate to target ROOT and TrustedPublisher. The USB helper then
uses `Drivers/LocalTestVista/USBXHCI.inf`. This is selected only with the explicit
build option `--local-signature`; ordinary builds retain the community package.
Deployment refuses a helper/signature-mode mismatch and checks source hashes.
The bootstrap still blocks Setup until controller, mouse and keyboard devnodes
report started. The v9 marker is `V9 LOCAL TEST CATALOG` in the helper log.

Build exited 0. Static imports of all four helpers resolve against Vista SP2.
The latest v8 evidence was saved at `zig-out/vista/before-v8-20260920-230008`.
Guarded chkdsk on the dirty target returned 0, then NOT Dirty. Guarded deployment
copied the trial directory and helpers, verified every file hash, confirmed the
armed boot hook, and preserved offline hives, KMDF and original driver files.
Backup: `zig-out/vista/local-catalog-v9-20260920-230031`.
No VM/E2E or target helper execution was performed by the agent. V9 is staged
for physical verification; it is not a confirmed USB fix.

## Independent review: v9 Basic Constraints defect and v10 correction

The user's independent review identified an error in our v9 signing certificate.
Confirmed directly in the preserved SetupAPI log: the Authenticode verification
failed with `0x80096019`, wrapped by the staging failure `0xe0000247`.
The v9 certificate used as the catalog signer has critical BasicConstraints
CA=TRUE and KeyUsage keyCertSign. Earlier OpenSSL verification with purpose=any
checked cryptographic validity but did not reject this inappropriate signer.
This was a defect introduced by the agent's v9 package preparation.

V10 uses a distinct test root and end-entity publisher. Root: CA=TRUE, pathlen=0,
keyCertSign/cRLSign, installed only in ROOT. Publisher: CA=FALSE, no path length,
digitalSignature only, EKU codeSigning, signed by the root, installed only in
TrustedPublisher. Only the publisher's private key is in the signing PFX.
Both private keys remain inside the project. The copied CAT is signed by the
publisher; all INF/SYS bytes and decoded catalog content remain unchanged.

A short host Windows CryptoAPI regression check uses memory stores only.
With explicit end-entity Basic Constraints policy, the old v9 certificate returns
0x80096019; the new v10 leaf returns 0. The separate Authenticode chain-policy
check returns 0 for v10 too. Unknown CA is allowed only inside this isolated
test to avoid changing host trust. This is not a Vista installation/driver-load
test. The test deliberately does not ignore invalid Basic Constraints.
`tools/tests/check_vista_certificate_policy.py` exited 0.

All four helper builds and static Vista SP2 import checks passed. Latest failure
logs were saved in `zig-out/vista/before-v8-20260920-232657` (legacy directory
prefix). Guarded chkdsk returned 0 and the target became NOT Dirty. Guarded v10
deployment verified file hashes, startup gate and preservation of offline
SYSTEM/SOFTWARE/COMPONENTS, KMDF and original driver package. Backup:
`zig-out/vista/local-catalog-v10-20260920-232705`.
V10 CAT SHA256: `a18cdf1fba15cf355d0bb7f9c247ce8e84b34ac1e57653d0f7c02e6fd1386e74`.

The independent claim that v8 only lacked publisher-store membership is not
established: v8 had successful logical-store readback and persisted exact DER.
That older rejection remains distinct from the confirmed v9 certificate defect.
No pending.xml or COMPONENTS state was cleared; CBS completion and working USB
remain unconfirmed. No VM/E2E was performed. Next physical boot uses v10.

## Hardware follow-up: v10 trusted, device installation deferred; v11 trial

The next physical boot accepted the v10 catalog: staging returned 0, and
SetupAPI selected Generic.Install with signer USOS Vista USB Test Publisher v10.
The package was published as oem3.inf. Both Newdev installation calls returned
0, but SetupAPI explicitly logged `Installation deferred (too early)` and
`Installation will be processed asynchronously`. The two AMD PCI devnodes had
no Service/Driver binding and still reported Code 28. The helper correctly
returned ERROR_NOT_READY (21) rather than starting Setup without input.
This is evidence of a pre-Setup installation deferral, not another observed
catalog-signature failure. The old v8 publisher-policy issue is unrelated.

V11 replaces UpdateDriverForPlugAndPlayDevices with the class-installer DIF
sequence: build/select a compatible driver, verify a non-null selection,
register coinstallers, install interfaces, and DIF_INSTALLDEVICE. Applications
call SetupDiCallClassInstaller rather than the default SetupDiInstallDevice
handler directly, following Microsoft's documented API contract:
https://learn.microsoft.com/en-us/windows/win32/api/setupapi/nf-setupapi-setupdiinstalldevice
The pinned INF is used for AMD 149C/43D0 and compatible USB3 hubs. Inbox/installed
drivers are selected for composite and HID descendants of those controllers.
Unrelated device trees are excluded. Existing started devices and installed
devices with load/start failures are not repeatedly reinstalled. Eight bounded
enumeration passes allow newly created hubs/input nodes to be discovered.
Any installation failure is logged with its instance ID and exact DIF stage.
Successful API calls still do not count as working USB: controller, mouse and
keyboard must report started devnodes before the existing gate opens.

The v10 certificates, CAT, INF and SYS files are unchanged. No offline registry,
Setup-progress flags or pending CBS transaction were edited. Runtime DIF calls
will perform the normal device/service registration on the target Vista system.
Marker: `V11 direct pre-Setup USB device installation` in firstboot-usb.log.

Four helper builds returned 0. Static import checks against original Vista SP2
passed (USB helper 45 imports, bootstrap 30, prerequisite 33, trust helper 26).
No helper was executed on the host; no VM/E2E was run. Fresh logs were preserved
before filesystem repair at `zig-out/vista/before-v8-20260920-233846` (legacy
prefix). Guarded chkdsk returned 0 and M: became NOT Dirty.
Guarded deployment returned `VISTA_DEPLOYED=direct-usb-v11; READBACK=PASS`,
verified the armed startup gate and preserved offline hives/KMDF/original drivers.
Backup: `zig-out/vista/direct-usb-v11-20260920-233928`.
USB helper SHA256:
`07e7c37da805eaee08c95fbbcb15348f74e00f17f35d96c99b47a3f24514519e`.
Whether this DIF sequence starts the backported USB stack during Vista Setup
remains unverified until the next physical boot. CBS completion and OOBE also
remain unconfirmed.
