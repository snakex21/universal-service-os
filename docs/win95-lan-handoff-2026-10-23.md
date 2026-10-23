# Source950 LAN policy after the native handoff

`USOSLAN` previously returned before its desktop notification wait whenever
CPUID identified a VM. Consequently a completed RTM/OSR1 installation running
in native QEMU never applied browser defaults or created the favorite, even
after the phase1 installation had finished. The Run value remained present.

For Win9x build950 only, a VM can now pass that early guard if both checks
succeed:

- `PHASE1.OK` beside the helper contains exactly the phase1 postprocessor's
  `phase1=qemu elapsed=<digits>\r\n` record.
- Opening the real `HKLM\Software\Microsoft\Windows\CurrentVersion\RunOnce\Setup`
  returns `ERROR_FILE_NOT_FOUND`. An existing key or an access/query error
  defers the helper and preserves its Run value.

The existing event driven desktop wait still runs before policy changes.
The completion boundary is checked again after that wait. Nested phase1
Setup has no postprocessor marker and continues to defer. Other source
versions retain their VM deferral; the NT compilation retains its previous
branch. Physical machine behavior is unchanged.

The postprocessor writes its marker after `w9x_phase1_patch_c`, before its
final unmount and filesystem verification. The marker alone therefore does
not prove successful verification or final GUI Setup. The normal caller
still blocks a failed preparation, and this helper additionally requires
Setup's own pending key to be absent and the desktop to be ready.

Validation: five selected `test_network_defaults.py` host tests pass,
including the actual C policy test with synthetic adjacent markers and a
stubbed Setup registry query. Cases cover no marker, malformed/trailing
data, pending Setup, query denial, source/OS mismatches and a valid handoff.
The target entry and desktop/registry policy are not run on the host.

This is not runtime PASS for browser settings. The installed IE version,
real Favorites path and actual browser behavior still require a test on a
new installed overlay. An IE package refresh must continue to use the
existing explicit `/refresh` so an already completed policy step is not
silently retried or a user's later changes overwritten.
