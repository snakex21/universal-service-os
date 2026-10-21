# Scoped NT3.5 installed-system evidence collection

The optional `collect_nt35_success` / `capture_nt35_network` plan fields
are separate from NT3.51 and NT4 policies. Combining those policies is
rejected before launch. Capture requires the NT3.5 own-file collector and
the single source-supported igb/8086:10C9 device.

The collector accepts only literal keyless metadata for `Windows NT 3.5`
or `Windows NT 3.5 Server`, an owned collection `_vm` target, explicit
frozen `_assets`, and coverage artifacts as output. It runs after the
target writer has exited and before exact target cleanup. The disposable
target is attached read-only. It exports only five fixed own diagnostics:
NET35.STATUS, NET35.ON, USABILITY.TXT, POST.LOG, USOSNET35.SHA256; the
installed own driver is hashed in RAM rather than exported. Registry
hives and Windows modules are not collected.

Expected experimental own `usosnet35.sys` input:16384B, SHA256
`e1aa69a3ec8e3da802013131abbb6fefc9f466da6f4eeb66fe15ec47e60421c5`.
Its build/source remain in the separate `fix/nt35-net` worktree; this
runner change does not merge or deploy that driver.

Transport uses the already verified quoted noninteractive shell wrapper,
strict base64 and bounded gzip/tar validation. Paths, member types,
duplicates, sizes, text encoding and the readback digest are checked
before any diagnostic file is written. File/status/hash presence never
sets installed_runtime_pass=true. The bounded passive network mirror is
also not a substitute for actual guest DHCP, ping and DNS evidence.

Validation:114 coverage tests PASS in26.728s, including eight NT3.5
tests against the actual integrated runner preflight. The actual own
candidate pin was checked via explicit `USOSNET35_TEST_DRIVER` pointing
to the separate worktree. Future runs without a build input skip only
that pin test with an explicit missing-proof reason. No NT3.5 Windows
runtime PASS resulted from these host tests.
