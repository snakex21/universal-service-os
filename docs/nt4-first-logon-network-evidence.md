# NT4 first-logon and network evidence in QEMU

This opt-in fixture tests the actual installed NT4 target. NT4 does not
support the generic USOS `user_script` option, and POST disables ATAPI;
the observer therefore lives in `C:\USOS\Coverage` on the target.

The test-only overlay preserves the frozen initrd's current scripts. It
stages the pinned own logger and GUI helper, installs the two exact own
RunOnce/Run entries after SP6a and DONE.REG, and creates ARMED.TXT only
after the internal installer VM exits successfully and target checks pass.
At native logon, the helper removes both entries and the arm file before
running the hidden first-logon script. Duplicate invocations preserve the
previous status and cannot emit a second token. Failed staging or cleanup
cannot produce a first-logon token.

The operator explicitly starts `NT4OBS.EXE /testnet` after the desktop.
It runs release/renew and the strict own logger without a console and waits
for completion. Logs/status remain beside the helper. TESTNET_DONE is a
completion status, not proof of a working connection.

After QEMU exits, the collector attaches only the owned stopped target
read-only. It exports a closed ASCII grammar of the two own NET logs, a
fixed observer-status enum and the hash of the installed own NDIS driver.
It excludes Windows Setup/registry/process dumps, keys and raw binaries.
Strict gzip/tar bounds, names and grammar are checked before host writes.

The passive localhost mirror stores only DHCP for the pinned virtual igb
after the actual first-logon token, capped at 8 MiB. DHCP needs complete
DORA. Gateway and DNS results must match that lease and successful guest
echo/DNS checks. The exact installed driver hash and TESTNET_DONE are also
required. File presence and registry configuration are insufficient.

A reset between complete mirror frames is accepted only if shutdown was
marked before QMP quit and QEMU then exited normally with status 0. Partial
headers/payloads and resets observed before that boundary remain errors.
Historical captures without this evidence are not reclassified.

Pinned own inputs:

- Logger: `ff2585043a882065f9598628ac31afdaba356a3d91f3e55d93a36e313e3983b7`.
- GUI observer: `37e7a0f69846d9bab18a718f7d66c3fd937f0f35913d2b0eb22f2d7ce4eae0e9`.
- Installed NDIS4: `4f2eb16b71753baab740302025b9e8ba02c38a676670b13626c757bdb3700f8d`.

Validation: 102 coverage host tests passed after integration, including
the real compiled C state machine, repeated invocations and localhost
FIN/RST/truncation cases. Rebuilding the GUI helper from integrated sources
produced the exact pinned hash. These are host results, not NT4 runtime.

The next desktop/LAN fixture keeps i8042/PS/2 enabled. It cannot prove USB
HID routing. The stopped target must be retained before cleanup for a
separate test that excludes functioning PS/2 input. Frozen MSC testing is
also separate; HID and MSC results from different payloads cannot be
combined. All resulting runtime claims remain QEMU only, not X470 PASS.
