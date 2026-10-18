# File-backed Vista/2008 desktop trials

Experimental test harness, GPL-3.0-or-later. This is not an installer for a
physical PC and does not establish X470 support. It exposes no physical disks.
Default trials expose no NIC; the explicit RDP trial has a restricted virtual
NIC and one loopback-only forwarding port. Supply an existing local Windows ISO;
the script does not download Windows or use a product key.

Dependencies used: Python 3.13, pycdlib 1.21.0, Pillow 10.4.0, the repository's
QEMU and pinned Zig 0.16.0. All generated files, temporary files and caches go
under the new `--out` directory. Existing output folders are rejected.

```powershell
python -I -B tools/tests/usoswm_vm/run.py vista --media <Vista-SP2-x64.iso> --tool-root <repo-tools> --component <own-component-build> --out zig-out/watermark/vista-new
python -I -B tools/tests/usoswm_vm/run.py server2008 --media <2008-SP2-x64.iso> --tool-root <repo-tools> --component <own-component-build> --out zig-out/watermark/2008-new
```

The disposable target has a 24 GiB virtual size. Its answer wipes only that
new file-backed QEMU disk. A fixed dummy password belongs solely to this
isolated test account, with no network access. It is not a product key or a
credential for the host. An event-driven WinPE helper chooses the normal
optional installation without a key if that page appears. Activation,
licensing checks and time limits remain untouched.

`--control` omits the component and does not set TESTSIGNING. It also supports
`--arch x86` and the `win7`/`server2008r2` labels. These labels select a test
description, not evidence that an operating system has passed.

The host blocks on serial messages sent by the guest. Each requested evidence
stage is captured once and acknowledged; no periodic screen, QMP, process or
log queries collect progress. A timeout captures the terminal failure screen
before closing only the QEMU process created by this script. The default
deadline is one hour, configurable through `--limit-seconds` (minimum 300).

The first-logon command sends a short readiness notification and exits.
The longer probe starts later through normal Win+R outside the profile setup
job. UAC is accepted normally in the lab; its policy is never disabled.
Automatic clicks require the inspected fixed 800x600 fixture and an explicit
`--consent-action`. Neither a click nor a completed build is GUI acceptance.

Current probe stages: baseline desktop/winver, manual component start,
resolution change, Explorer restart, opt-out and restoration, two registration
attempts, lock screen and native shutdown. `probe.log` and `bcd.txt` stay in
the guest's `C:\USOS\WMTEST`; the application lives in `C:\USOS\usoswm`.
Registration return codes must be read, not assumed to be success. Screens
labelled FILTERED are measurement requests, not automatic PASS verdicts.

`resume.py` adds a second measured cold boot and a theme-change attempt.
It requires a completed first trial, makes a qcow2 overlay, and uses the
repository's micro-Linux donor to replace only our files under `C:\USOS`.
It preserves Microsoft files/hives/BCD and the original completed image.
The probe invoked through Win+R does not manually start the application
before its first post-boot screenshot. Actual screenshots/logs must prove
that Startup worked. A theme attempt without a changed API result is labelled
UNCONFIRMED/UNCHANGED, never PASS. The current Classic fixture copies the local
OS theme into its private folder and proves an actual background colour change.
Aero hardware and another user's desktop need additional coverage.

`replay_setup.py` requires a closed, failed --gate-native fixture and its
private offline inspection. It rearms only known setup fields in a new overlay,
then captures the native pre-deploy desktop and the own setup background. This
is a deliberately rearmed checkpoint, never a fresh-install PASS. `--baseline`
keeps the opt-out marker; `--lifecycle` explicitly ends setup in the fixture and
waits on the background process handle before reporting completion. All COM
checkpoints and lifecycle controls are absent from production gate builds.

For RDP, build `build_native.py --tool-root <pinned-tools> --out <private-out>`
and pass its `native-client.exe` to `resume.py --native-rdp <exe>`. The host must
already have Microsoft's MsRdpClient9 ActiveX runtime (Windows 8.1 or newer).
No runtime DLL is copied. Persistent bitmap caching and redirected devices
are disabled; the peer is always a QEMU loopback port. Host OS security/UAC/TLS
policy is unchanged. Only the disposable guest enables its normal RDP access.

RDP instrumentation reuses the existing Startup link through an explicit
lab-only wrapper. It launches the canonical launcher byte-for-byte under
`usoswm-real.exe` beside the unchanged DLL. This wrapper is never installed by
the product. A WTS remote-connect event handles reconnection of the existing
console session; the wrapper handles a newly created remote session. The
standard user sends evidence through a same-user-only ephemeral named pipe
to the already elevated lab broker, without changing serial-port ACLs.

Acceptance requires native OnLoginComplete, a nonzero remote-session metric,
TESTSIGNING from the guest query, successful GDI captures inside that session,
and native Windows shutdown. `extract_rdp.py --trial <completed-trial>
--tool-root <pinned-tools> --linux-root <micro-linux>` retrieves only the two
own screenshots read-only after shutdown. Inspect them: protocol completion
alone is not visual PASS. Off-screen ActiveX PrintWindow is not an accepted
remote screenshot source.

The normal installation accepts the already approved one common
Startup shortcut; the harness adds no other Startup entry.

Keep target images, Microsoft files and support ISOs private. Export only own
sources, hashes, logs and inspected screenshots; delete disposable images and
caches after completing the trials.
