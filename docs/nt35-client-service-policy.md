# NT35 client-only service policy — experimental QEMU qualification

A bounded read of the completed NT35 USB regression finds Browser and
LanmanServer Start2, alongside the functional client/TCPIP. IRQ/LAN and
HID success therefore do not prove client-without-file-sharing policy.

`tools/nt3/clientcfg/` builds a dedicated GUI helper, without rebuilding
any network or USB driver. The finite policy and native SCM adapter are
adapted from our NT31 commit2064ae00; exact own-source provenance is
recorded. The frontend accepts only NT3.5, explicit `/apply` or `/check`,
and an adjacent `CLNT35.ON` fixture marker. Logs stay beside the EXE.
It stops Browser first, then existing LanmanServer, changes both to
Disabled, and verifies Workstation/TCPIP remain RUNNING. Unexpected active
dependents, API errors or incompatible Browser dependencies refuse the
operation. Native NET is hidden and waited to completion, without a
progress-query loop. This changes only required OS service configuration;
application data is never written to the profile or registry.

Build02:5632B, SHA256
`4a927eecb1a6c602f92c0a92c14bd7b56f684238735d36f8218d5bfcb5e3204a`.
PE3.10 GUI,21 imports verified against actual installed NT35 KERNEL32
and ADVAPI32 bytes in RAM. Twelve actual-C policy cases and two actual
host OS refusals pass. Host refusal never opens a serial device.

Stopped preparation adds only `USOS/NT3/CLNT35.EXE` and `CLNT35.ON`.
All920 original file contents, including SYSTEM and both own SYS files,
are byte-identical. Whole-disk scratch stays on G and is removed after
independent FAT readback and raw/overlay comparison; no Microsoft module
or hive is exported. SYSd94/USB2d455/i8042prtStart4 remain pinned.

The first run apply01 reaches the login screen, then fails because the
operator stdin pipe closes. No helper action was sent and no policy PASS
is claimed. The exact failure/preflight/source archives remain in
`artifacts/coverage/vm/nt35-client-apply01/` and `artifacts/nt35-client/apply/`.
The corrected launcher refuses redirected stdin before any VM start;
its actual headless-launch regression is tested. Apply02 uses a fresh
preparation from the unchanged clean parent and a live PTY, but Windows
stops with C000021A/C0000005 before any operator/helper invocation. The
own helper log is absent in stopped readback; the failed disk is unchanged
during that read and whole-disk scratch is removed. This is not a helper
or policy runtime PASS. An unchanged clean-parent cold control baseline01,
without adding any files, is running to isolate the startup failure.
Runtime qualification and a separate cold-boot policy check remain open.

The own helper emits a completion marker to virtual COM1 only inside
the explicitly marked NT35 fixture. The runner writes an atomic completion
JSON, and the operator waits for its exact filesystem event. No active
log, QMP status or screenshot is polled for progress. No physical media,
hub code, Windows module or frozen cache is modified.
