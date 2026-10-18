# File-backed Vista/2008 desktop trials

Experimental test harness, GPL-3.0-or-later. This is not an installer for a
physical PC and does not establish X470 support. It exposes no physical disks
or network devices to QEMU. Supply an existing local, original Windows ISO;
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
UNCONFIRMED/UNCHANGED, never PASS. Aero hardware, switching users and RDP need
additional coverage. Do not describe those as covered by this probe.

The normal installation accepts the already approved one common
Startup shortcut; the harness adds no other Startup entry.

Keep target images, Microsoft files and support ISOs private. Export only own
sources, hashes, logs and inspected screenshots; delete disposable images and
caches after completing the trials.
